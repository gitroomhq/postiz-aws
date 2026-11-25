# One-time setup of the staging account, applied by hand with that account's
# admin credentials (docs/staging.md):
#   export AWS_PROFILE=postiz-staging TF_VAR_aws_account_id=<staging account id>
#   terraform -chdir=bootstrap/staging init && terraform -chdir=bootstrap/staging apply
#
# Creates what environments/staging needs before CI can run it:
#   - the S3 bucket holding the staging Terraform state
#   - the GitHub OIDC provider
#   - postiz-staging-github-terraform-plan   read-only, for pull requests and main
#   - postiz-staging-github-terraform-apply  admin, only for jobs in the
#                                            "staging-terraform" GitHub environment
#                                            (limited to main in the repository settings)
# The deploy role is in environments/staging (deploy.tf).
#
# Unlike production, no deploy gate: these roles reach only the staging account,
# and the organization's policy on that account (docs/staging.md) bounds what
# even its admin can do.

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.70, < 7.0"
    }
  }

  # After the first apply, move this stack's own state into the bucket it created:
  #   uncomment, then: terraform -chdir=bootstrap/staging init -migrate-state -backend-config=../../environments/staging/backend.hcl
  # backend "s3" {
  #   key          = "bootstrap/terraform.tfstate"
  #   region       = "us-east-2"
  #   use_lockfile = true
  #   encrypt      = true
  # }
}

variable "aws_account_id" {
  description = "The staging account (TF_VAR_aws_account_id)."
  type        = string
}

variable "region" {
  type    = string
  default = "us-east-2"
}

variable "github_repository" {
  type    = string
  default = "gitroomhq/postiz-aws"
}

variable "github_oidc_subject" {
  description = "Start of the sub claim in this repository's GitHub OIDC tokens (bootstrap/variables.tf explains it)."
  type        = string
  default     = "repo:gitroomhq@128401275/postiz-aws@1436140501"

  validation {
    condition     = can(regex("^repo:[^:]+$", var.github_oidc_subject))
    error_message = "Only the prefix, for example repo:owner@123/name@456 (no :ref: or :environment: part)."
  }
}

variable "apply_github_environment" {
  type    = string
  default = "staging-terraform"
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = {
      Project     = "postiz"
      Environment = "staging"
      ManagedBy   = "terraform"
      Stack       = "bootstrap-staging"
    }
  }
}

locals {
  state_bucket = "postiz-terraform-state-${var.aws_account_id}"
}

# --- Terraform state bucket ------------------------------------------------------

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
  bucket     = aws_s3_bucket.state.id
  policy     = data.aws_iam_policy_document.state_bucket.json
  depends_on = [aws_s3_bucket_public_access_block.state]
}

# --- GitHub Actions OIDC ------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "state_access" {
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
  # terraform plan takes the lock too
  statement {
    sid       = "ManageLockFiles"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*.tflock"]
  }
}

# --- plan role: pull requests and main, read-only -------------------------------------

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
        "${var.github_oidc_subject}:pull_request",
        "${var.github_oidc_subject}:ref:refs/heads/main",
      ]
    }
  }
}

resource "aws_iam_role" "plan" {
  name                 = "postiz-staging-github-terraform-plan"
  description          = "GitHub Actions terraform plan of environments/staging (read-only)"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600
}

# ReadOnlyAccess cannot read secret values; plans run with -refresh=false
resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "plan_state" {
  name   = "terraform-state"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.state_access.json
}

# --- apply role: the staging-terraform GitHub environment only ---------------------------

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
      values   = ["${var.github_oidc_subject}:environment:${var.apply_github_environment}"]
    }
  }
}

resource "aws_iam_role" "apply" {
  name                 = "postiz-staging-github-terraform-apply"
  description          = "GitHub Actions terraform apply of environments/staging (environment ${var.apply_github_environment})"
  assume_role_policy   = data.aws_iam_policy_document.apply_trust.json
  max_session_duration = 3600
}

# Terraform creates IAM roles, so a narrower policy would still be admin-equivalent.
# The guards are the trust policy (one GitHub environment, main only) and the
# organization's policy on the account.
resource "aws_iam_role_policy_attachment" "apply_admin" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "state_bucket" {
  description = "Repository variable STAGING_TF_STATE_BUCKET, and environments/staging/backend.hcl"
  value       = aws_s3_bucket.state.id
}

output "plan_role_arn" {
  description = "Repository variable STAGING_AWS_PLAN_ROLE_ARN"
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Repository variable STAGING_AWS_APPLY_ROLE_ARN"
  value       = aws_iam_role.apply.arn
}
