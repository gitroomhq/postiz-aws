# App secrets: one JSON secret per service, created empty here and filled by
# scripts/staging-secrets.sh (staging's own values, plus the few keys
# shared-keys.json says to copy from production). Terraform never sees the
# values; task definitions reference each key (arn:...:secret:name:KEY::).
#
#   postiz/staging/backend, frontend, worker
#
# Values Terraform generates itself (database logins, Valkey token) live under
# postiz/staging/managed/ and are written write-only.

resource "aws_secretsmanager_secret" "app" {
  for_each = local.app_env_keys

  name                    = "${local.secret_prefix}/${each.key}"
  description             = "Environment of the ${each.key} service (staging)"
  recovery_window_in_days = 7
}
