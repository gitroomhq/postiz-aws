# Moving the data without exposing the Railway databases: a temporary toolbox
# inside the Railway project dumps them over Railway's private network and
# uploads the dumps here with short-lived, write-only keys (the upload role);
# the ops task downloads and restores them (scripts/migration-transfer.sh).
# Nothing listens on the internet on either side. Dumps expire after a week.

locals {
  migration_bucket = "${local.name}-migration-${var.aws_account_id}"
  # Built from the name rather than read from the bucket, so the ops task's
  # policy is known at plan time: the ecs-service module counts on it being null
  # or not, and a bucket's arn is unknown until the bucket exists.
  migration_bucket_arn = "arn:aws:s3:::${local.migration_bucket}"
}

resource "aws_s3_bucket" "migration" {
  bucket        = local.migration_bucket
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "migration" {
  bucket = aws_s3_bucket.migration.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "migration" {
  bucket                  = aws_s3_bucket.migration.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "migration" {
  bucket = aws_s3_bucket.migration.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "migration" {
  bucket = aws_s3_bucket.migration.id
  rule {
    id     = "expire-dumps"
    status = "Enabled"
    filter {}
    expiration {
      days = 7
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "migration_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [local.migration_bucket_arn, "${local.migration_bucket_arn}/*"]
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

  # The dumps are the whole production database. ReadOnlyAccess (the plan and
  # agent roles) allows s3:Get* on every bucket, so only the ops task may read them.
  statement {
    sid       = "OnlyOpsTaskReads"
    effect    = "Deny"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${local.migration_bucket_arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = [module.ops.task_role_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "migration" {
  bucket     = aws_s3_bucket.migration.id
  policy     = data.aws_iam_policy_document.migration_bucket.json
  depends_on = [aws_s3_bucket_public_access_block.migration]
}

# Assumed from your machine right before an export (scripts/migration-transfer.sh
# keys); its temporary keys go into the Railway toolbox's variables. They can only
# upload: whoever holds them cannot read, list or delete a dump, and a file they
# overwrite fails the import's checks.
data "aws_iam_policy_document" "migration_upload_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.aws_account_id}:root"]
    }
  }
}

resource "aws_iam_role" "migration_upload" {
  name               = "${local.name}-migration-upload"
  description        = "Write-only uploads of the Railway dumps from the Railway toolbox"
  assume_role_policy = data.aws_iam_policy_document.migration_upload_trust.json
}

data "aws_iam_policy_document" "migration_upload" {
  statement {
    actions   = ["s3:PutObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
    resources = ["${local.migration_bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "migration_upload" {
  name   = "upload-only"
  role   = aws_iam_role.migration_upload.id
  policy = data.aws_iam_policy_document.migration_upload.json
}
