# One-off tasks, started by deploy-staging.yml with `aws ecs run-task` on regular
# Fargate (not Spot: an interrupted schema change is worse than a few cents).

# prisma db push, as in production: :migrate is the new schema's image
module "db_push" {
  source = "../../modules/ecs-service"

  name               = "db-push"
  create_service     = false
  cluster_name       = aws_ecs_cluster.main.name
  cluster_arn        = aws_ecs_cluster.main.arn
  launch_type        = "fargate"
  network_mode       = "awsvpc"
  execution_role_arn = aws_iam_role.execution.arn

  image              = local.migrate_image
  cpu                = 1024
  memory             = 3072
  memory_reservation = 1024
  secrets = {
    DATABASE_URL = local.database_urls["api"]
  }

  log_retention_days = var.log_retention_days
}

# Roles and databases on a new (or reset) instance: production's
# migrate-postgres.sh init (api owns postiz; worker and the unused mcp act as api;
# temporal owns temporal), plus temporal_visibility for Temporal's SQL
# visibility. Idempotent, and it sets the passwords to the current secrets, so it
# is also the second half of a password rotation.
module "db_init" {
  source = "../../modules/ecs-service"

  name               = "db-init"
  create_service     = false
  cluster_name       = aws_ecs_cluster.main.name
  cluster_arn        = aws_ecs_cluster.main.arn
  launch_type        = "fargate"
  network_mode       = "awsvpc"
  execution_role_arn = aws_iam_role.execution.arn

  image       = local.ops_image
  entry_point = ["/bin/bash", "-c"]
  command = [<<-EOT
    set -euo pipefail
    migrate-postgres.sh init
    if [ -z "$(psql "$MAIN_ADMIN_URL" -X -v ON_ERROR_STOP=1 -tAc "select 1 from pg_database where datname = 'temporal_visibility'")" ]; then
      psql "$MAIN_ADMIN_URL" -X -v ON_ERROR_STOP=1 -qc "create database temporal_visibility owner temporal"
    fi
    echo "database temporal_visibility ready"
  EOT
  ]
  cpu                = 256
  memory             = 512
  memory_reservation = 256
  stop_timeout       = 10

  secrets = {
    MAIN_ADMIN_URL       = "${module.postgres.admin_secret_arn}:url::"
    TEMPORAL_DB_PASSWORD = "${aws_secretsmanager_secret.temporal_db.arn}:password::"
    API_DB_PASSWORD      = "${aws_secretsmanager_secret.app_db.arn}:api_password::"
    WORKER_DB_PASSWORD   = "${aws_secretsmanager_secret.app_db.arn}:worker_password::"
    # production's script also creates "mcp"; nothing logs in with it here
    MCP_DB_PASSWORD = "${aws_secretsmanager_secret.app_db.arn}:mcp_password::"
  }

  log_retention_days = var.log_retention_days
}
