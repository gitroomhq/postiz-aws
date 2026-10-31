# One-time account setup, applied by hand with admin credentials:
#   export AWS_PROFILE=<profile> TF_VAR_aws_account_id=<your account id>
#   terraform -chdir=bootstrap init && terraform -chdir=bootstrap apply
#
# Creates what every other stack needs before it can run in CI:
#   - the S3 bucket holding Terraform state (native S3 locking, no DynamoDB)
#   - the GitHub OIDC provider
#   - postiz-github-terraform-plan   read-only, used by pull requests (plans run with
#                                    -refresh=false, so it never needs a secret value; any
#                                    branch can change the workflow, so it must stay weak)
#   - postiz-github-terraform-apply  admin, only from the "production" GitHub environment
#   - postiz-agent-readonly          for AI agents and humans poking around, cannot read secret values
#   - postiz-team-readonly           for team members signing in through IAM Identity Center
#                                    (account access manager), cannot read secret values

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.70, < 7.0"
    }
  }

  # After the first apply, move this stack's own state into the bucket it created:
  #   uncomment, then: terraform -chdir=bootstrap init -migrate-state -backend-config=../environments/production/backend.hcl
  # backend "s3" {
  #   key          = "bootstrap/terraform.tfstate"
  #   region       = "us-east-2"
  #   use_lockfile = true
  #   encrypt      = true
  # }
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = {
      Project   = "postiz"
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}

locals {
  state_bucket = "postiz-terraform-state-${var.aws_account_id}"
  github_sub   = var.github_oidc_subject
}

# ---------------------------------------------------------------------------
# Terraform state bucket
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

# ---------------------------------------------------------------------------
# GitHub Actions OIDC
# ---------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "state_read" {
  statement {
    sid       = "ListStateBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }
  statement {
    sid       = "ReadState"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }
}

data "aws_iam_policy_document" "state_lock" {
  # terraform plan takes the lock too, so even the read-only plan role writes .tflock files
  statement {
    sid       = "ManageLockFiles"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*.tflock"]
  }
}

# --- plan role: pull requests and main, read-only ---------------------------

data "aws_iam_policy_document" "plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "${local.github_sub}:pull_request",
        "${local.github_sub}:ref:refs/heads/main",
      ]
    }
  }
}

resource "aws_iam_role" "plan" {
  name                 = "postiz-github-terraform-plan"
  description          = "GitHub Actions terraform plan for ${var.github_repository} (read-only)"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "plan_extra" {
  source_policy_documents = [
    data.aws_iam_policy_document.state_read.json,
    data.aws_iam_policy_document.state_lock.json,
  ]
}

resource "aws_iam_role_policy" "plan_extra" {
  name   = "terraform-state-and-refresh"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan_extra.json
}

# --- apply role: only jobs running in the protected "production" environment ---

data "aws_iam_policy_document" "apply_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.github_sub}:environment:production"]
    }
  }
}

resource "aws_iam_role" "apply" {
  name                 = "postiz-github-terraform-apply"
  description          = "GitHub Actions terraform apply for ${var.github_repository}, production environment only"
  assume_role_policy   = data.aws_iam_policy_document.apply_trust.json
  max_session_duration = 7200 # a first apply (RDS Multi-AZ, CloudFront) can pass an hour
}

# Terraform creates IAM roles, so a narrower policy would still be admin-equivalent.
# The guard is the trust policy: only reviewed jobs in the production environment.
resource "aws_iam_role_policy_attachment" "apply_admin" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# --- read-only role for AI agents and humans --------------------------------

data "aws_iam_policy_document" "agent_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.aws_account_id}:root"]
    }
  }
}

resource "aws_iam_role" "agent_readonly" {
  name                 = "postiz-agent-readonly"
  description          = "Read-only access for AI agents, no secret values"
  assume_role_policy   = data.aws_iam_policy_document.agent_trust.json
  max_session_duration = 43200
}

resource "aws_iam_role_policy_attachment" "agent_readonly" {
  role       = aws_iam_role.agent_readonly.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "agent_extra" {
  source_policy_documents = [data.aws_iam_policy_document.state_read.json]

  statement {
    sid    = "NoSecretValues"
    effect = "Deny"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:BatchGetSecretValue",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "ecs:ExecuteCommand",
      "ssm:StartSession",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "agent_extra" {
  name   = "state-read-no-secrets"
  role   = aws_iam_role.agent_readonly.id
  policy = data.aws_iam_policy_document.agent_extra.json
}

# --- read-only role for team members ------------------------------------------
# Assigned to IAM Identity Center users through account access manager (an
# entitlement in the management account), the same way AccountFullAccessRole is.
# Members sign in through the account access portal or with `aws login`.

data "aws_iam_policy_document" "team_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:SetContext"]
    principals {
      type        = "Service"
      identifiers = ["account-access.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "team_readonly" {
  name                 = "postiz-team-readonly"
  description          = "Read-only access for team members via account access manager, no secret values"
  assume_role_policy   = data.aws_iam_policy_document.team_trust.json
  max_session_duration = 43200
}

resource "aws_iam_role_policy_attachment" "team_readonly" {
  role       = aws_iam_role.team_readonly.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Amazon Q Developer chat in the console. Q acts on AWS resources with the
# caller's own permissions (q:PassRequest), so it is still limited to
# ReadOnlyAccess and the NoSecretValues deny below.
resource "aws_iam_role_policy_attachment" "team_readonly_amazon_q" {
  role       = aws_iam_role.team_readonly.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonQDeveloperAccess"
}

data "aws_iam_policy_document" "no_secret_values" {
  statement {
    sid    = "NoSecretValues"
    effect = "Deny"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:BatchGetSecretValue",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "ecs:ExecuteCommand",
      "ssm:StartSession",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "team_readonly" {
  name   = "no-secret-values"
  role   = aws_iam_role.team_readonly.id
  policy = data.aws_iam_policy_document.no_secret_values.json
}
