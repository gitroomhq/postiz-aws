# App secrets copied from Railway: one JSON secret per service, created empty
# here and filled by scripts/railway-env-to-secrets.py. Terraform never sees the
# values; task definitions reference each key (arn:...:secret:name:KEY::).
#
#   postiz/production/backend, mcp, frontend, worker, worker-2
#   postiz/production/temporal-ui-auth   (USERNAME, PASSWORD for the UI)
#
# Values Terraform generates itself (database, Valkey and Elasticsearch
# passwords) live under postiz/production/managed/ and are written write-only.

resource "aws_secretsmanager_secret" "app" {
  for_each = local.app_env_keys

  name                    = "${local.secret_prefix}/${each.key}"
  description             = "Environment of the ${each.key} service, copied from Railway"
  recovery_window_in_days = 7
}
