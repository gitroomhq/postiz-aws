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
# environments/production adds the inline policies query-database-readonly
# (db-readers.tf): CloudShell inside the VPC and the database's readonly sign-in;
# and session-manager-tunnels (team-tunnels.tf): Session Manager tunnels to the
# read-only Temporal proxy and to PostgreSQL. The small internal apps' roots
# (Fargate tasks in the same cluster) may add a tunnel of their own the same way:
# a postiz-team-* document and an inline policy naming their task.
# Until 2026-11-18 the role can also read the values of the Postiz app's five
# service secrets (team_secret_values below).

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

# `aws login` (console credentials for the CLI) needs signin OAuth2 actions that
# ReadOnlyAccess doesn't include; without them the browser approval step fails.
resource "aws_iam_role_policy_attachment" "team_readonly_cli_login" {
  role       = aws_iam_role.team_readonly.name
  policy_arn = "arn:aws:iam::aws:policy/SignInLocalDevelopmentAccess"
}

# Secret values for a limited time. The team has to copy some keys out of the
# Postiz app's service secrets, so until the moment below (UTC) the role may read
# those five secrets and no other. IAM compares the date with the clock on every
# request, so the access ends by itself, with no apply, also for someone who
# signed in before. Reading ends then; a key that was copied stays copied until
# it is rotated.
#
# Once the date has passed, delete these locals and team_secret_values below, and
# in no_secret_values replace the three GetSecretValue statements by
# "secretsmanager:GetSecretValue" in NoSecretValues.
locals {
  team_secret_values_until = "2026-11-18T23:59:59Z"

  # Secrets Manager ends every ARN with a hyphen and six random characters.
  team_secret_values_arns = [
    for service in ["backend", "mcp", "frontend", "worker", "worker-2"] :
    "arn:aws:secretsmanager:${var.region}:${var.aws_account_id}:secret:postiz/production/${service}-??????"
  ]
}

data "aws_iam_policy_document" "team_secret_values" {
  statement {
    sid       = "AppSecretValuesUntilTheDate"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = local.team_secret_values_arns
    condition {
      test     = "DateLessThan"
      variable = "aws:CurrentTime"
      values   = [local.team_secret_values_until]
    }
  }
}

resource "aws_iam_role_policy" "team_secret_values" {
  name   = "app-secret-values-until-${substr(local.team_secret_values_until, 0, 10)}"
  role   = aws_iam_role.team_readonly.id
  policy = data.aws_iam_policy_document.team_secret_values.json
}

data "aws_iam_policy_document" "no_secret_values" {
  statement {
    sid    = "NoSecretValues"
    effect = "Deny"
    actions = [
      "secretsmanager:BatchGetSecretValue",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "ecs:ExecuteCommand",
    ]
    resources = ["*"]
  }

  # secretsmanager:GetSecretValue while the window above is open: never for a
  # secret outside the list (the generated database, Valkey and Elasticsearch
  # passwords, the internal apps), never from the date on, whatever else allows
  # it, and never through Amazon Q chat, which calls AWS as the person signed in.
  statement {
    sid           = "NoOtherSecretValues"
    effect        = "Deny"
    actions       = ["secretsmanager:GetSecretValue"]
    not_resources = local.team_secret_values_arns
  }

  statement {
    sid       = "NoSecretValuesFromTheDateOn"
    effect    = "Deny"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["*"]
    condition {
      test     = "DateGreaterThanEquals"
      variable = "aws:CurrentTime"
      values   = [local.team_secret_values_until]
    }
  }

  statement {
    sid       = "NoSecretValuesThroughAmazonQ"
    effect    = "Deny"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["*"]
    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "aws:CalledVia"
      values   = ["q.amazonaws.com"]
    }
  }

  # Session Manager only with the team's own session documents, postiz-team-*,
  # which environments/production creates with host and port fixed inside
  # (team-tunnels.tf: the read-only Temporal proxy, PostgreSQL for the readonly
  # role), as may an internal app's root for its own task. Every other document is
  # denied: the default shell (SSM-SessionManagerRunShell, which a session without
  # --document-name uses), AWS-StartPortForwardingSession*, interactive commands.
  # Targets are left to the allows: environments/production names only the ECS
  # hosts, and an ECS task (a session through its ECS Exec agent) needs an allow
  # naming it, by the task's tags. With the documents above, a session into a task
  # forwards one fixed port and opens no shell; aws ecs execute-command stays
  # denied (NoSecretValues). The agent role above still denies Session Manager
  # entirely.
  statement {
    sid     = "SessionManagerOnlyTeamDocuments"
    effect  = "Deny"
    actions = ["ssm:StartSession"]
    not_resources = [
      "arn:aws:ssm:${var.region}:${var.aws_account_id}:document/postiz-team-*",
      "arn:aws:ec2:${var.region}:${var.aws_account_id}:instance/*",
      "arn:aws:ecs:${var.region}:${var.aws_account_id}:task/*",
    ]
  }
}

resource "aws_iam_role_policy" "team_readonly" {
  name   = "no-secret-values"
  role   = aws_iam_role.team_readonly.id
  policy = data.aws_iam_policy_document.no_secret_values.json
}
