# Channel tokens encrypted in the database (postiz-app's ENCRYPTION_PROVIDER=aws-kms),
# as in production, with staging's own KMS key in staging's own account: whoever
# gets into staging never holds a key that opens production's tokens.
#
# The app encrypts the tokens with one 256-bit data key, stored here only
# encrypted by the KMS key; each service decrypts it once at start with its task
# role. Staging starts with an empty database, so it is on from the first start
# (production went off, read-only, on). Create the data key once, after the first
# apply and before the services start:
#   NAME=postiz-staging SECRET=postiz/staging/token-encryption-data-key scripts/token-encryption-key.sh

resource "aws_kms_key" "token_encryption" {
  description             = "Encrypts the data key of the channel tokens in the Postiz staging database"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "token_encryption" {
  name          = "alias/${local.name}-token-encryption"
  target_key_id = aws_kms_key.token_encryption.key_id
}

resource "aws_secretsmanager_secret" "token_encryption_data_key" {
  name                    = "${local.secret_prefix}/token-encryption-data-key"
  description             = "Data key of the channel tokens, encrypted by the ${local.name}-token-encryption KMS key"
  recovery_window_in_days = 7
}

data "aws_iam_policy_document" "token_decrypt" {
  statement {
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.token_encryption.arn]
  }
}

# A separate policy, not task_role_policy_json: the key's ARN is unknown until it
# is created, and the module counts on that variable.
resource "aws_iam_role_policy" "token_decrypt" {
  for_each = { for name, service in local.postiz_services : name => service if service.tokens }

  name   = "token-encryption"
  role   = module.postiz[each.key].task_role_name
  policy = data.aws_iam_policy_document.token_decrypt.json
}
