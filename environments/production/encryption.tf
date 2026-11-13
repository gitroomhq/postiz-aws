# Channel tokens encrypted in the Postiz database (Integration.token and
# refreshToken), postiz-app's ENCRYPTION_PROVIDER=aws-kms.
#
# The app encrypts the tokens itself with one 256-bit data key. That key is
# stored only in its encrypted form (the secret below): each service asks KMS
# to decrypt it once when it starts, with its task role, and keeps it in memory.
# So a copy of the database, or of the secrets, is not enough to read a token.
#
# Turned on with var.token_encryption, in this order:
#   1. apply with "off" (the default): creates the KMS key, the empty secret
#      and the task roles' permission
#   2. scripts/token-encryption-key.sh, once: creates the data key
#   3. "read-only": every service gets the key and reads encrypted tokens,
#      new tokens are still stored plain. Needs a postiz-app with the
#      encryption (older images ignore the variables).
#   4. "on", after all services run with step 3: new and refreshed tokens are
#      stored encrypted. Tokens stored before stay plain and keep working;
#      postiz-app's encryptTokensWorkflow encrypts them all.
# Steps 3 and 4 are separate because the services restart one at a time: with
# both at once, a restarted worker would store a token that a backend still
# running without the key cannot read.
#
# Losing the KMS key or the secret makes every encrypted token unreadable (every
# channel would have to be connected again), so both refuse terraform destroy.
# After step 4, never deploy a postiz-app from before the encryption.

resource "aws_kms_key" "token_encryption" {
  description             = "Encrypts the data key of the channel tokens in the Postiz database"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "token_encryption" {
  name          = "alias/${local.name}-token-encryption"
  target_key_id = aws_kms_key.token_encryption.key_id
}

# The data key, encrypted by the KMS key above. Filled once by
# scripts/token-encryption-key.sh: KMS only ever returns the encrypted form, so
# neither Terraform nor a person sees the key itself.
resource "aws_secretsmanager_secret" "token_encryption_data_key" {
  name                    = "${local.secret_prefix}/token-encryption-data-key"
  description             = "Data key of the channel tokens, encrypted by the ${local.name}-token-encryption KMS key"
  recovery_window_in_days = 30

  lifecycle {
    prevent_destroy = true
  }
}

data "aws_iam_policy_document" "token_decrypt" {
  statement {
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.token_encryption.arn]
  }
}

# The services that read the channel tokens (postiz.tf). A separate policy, not
# task_role_policy_json: the key's ARN is unknown until it is created, and the
# module counts on that variable.
resource "aws_iam_role_policy" "token_decrypt" {
  for_each = { for name, service in local.postiz_services : name => service if service.tokens }

  name   = "token-encryption"
  role   = module.postiz[each.key].task_role_name
  policy = data.aws_iam_policy_document.token_decrypt.json
}
