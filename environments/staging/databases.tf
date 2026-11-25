# One small RDS instance, two databases, as in production:
#   postiz    the app. backend and worker log in with their own roles (api, worker),
#             created by the db init task (ops.tf, scripts/migrate-postgres.sh init)
#   temporal  Temporal persistence, role "temporal"; temporal_visibility next to
#             it, because staging keeps Temporal's visibility in Postgres
#             (temporal.tf), not in Elasticsearch.
#
# Single-AZ db.t4g.micro (1 GiB): a restart or an AZ outage means minutes of
# downtime, fine for staging. Its ~85 connections are split by the pool sizes:
# Prisma's connection_limit=5 per app task (plus Mastra's pool), Temporal 10 per
# store. If FreeableMemory runs low, move to db.t4g.small (variable).
module "postgres" {
  source = "../../modules/rds-postgres"

  identifier            = "${local.name}-main"
  engine_version        = var.postgres_engine_version
  instance_class        = var.db_instance_class
  multi_az              = false
  db_name               = "postiz"
  username              = "postgres"
  password_version      = var.main_db_password_version
  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = 100
  backup_retention_days = 3

  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.private_subnet_ids
  allowed_security_group_ids = {
    apps     = aws_security_group.apps.id
    temporal = aws_security_group.temporal.id
  }

  # Who connected, when and from where: during a pentest, the record of what
  # reached the database. Kept 90 days in /aws/rds/instance/<identifier>/postgresql.
  cloudwatch_logs_exports = ["postgresql"]

  parameters = {
    log_connections            = { value = "1", apply_method = "immediate" }
    log_disconnections         = { value = "1", apply_method = "immediate" }
    log_min_duration_statement = { value = "1000", apply_method = "immediate" }
    # As in production (databases.tf there): Mastra's node-postgres only uses TLS
    # when the URL asks for it, and treats sslmode=require as verify-full.
    "rds.force_ssl" = { value = "0", apply_method = "pending-reboot" }
  }

  performance_insights        = false
  free_storage_alarm_gib      = 4
  freeable_memory_alarm_mib   = 64
  connections_alarm_threshold = 70

  secret_prefix   = local.secret_prefix
  alarm_topic_arn = aws_sns_topic.alerts.arn
}

# --- logins ------------------------------------------------------------------------------
# Terraform cannot reach the database: it writes the passwords here, the db init
# task creates the roles with them, and the services read their DATABASE_URL from
# here. To rotate: bump the version, apply, deploy with init_database, roll the
# services (temporal too, for its own).

ephemeral "random_password" "api_db" {
  length  = 40
  special = false
}

ephemeral "random_password" "worker_db" {
  length  = 40
  special = false
}

ephemeral "random_password" "mcp_db" {
  length  = 40
  special = false
}

resource "aws_secretsmanager_secret" "app_db" {
  name        = "${local.secret_prefix}/managed/app-db"
  description = "Logins of the api, worker and mcp roles on ${local.name}-main, written by Terraform"
}

resource "aws_secretsmanager_secret_version" "app_db" {
  secret_id = aws_secretsmanager_secret.app_db.id
  secret_string_wo = jsonencode({
    api_password    = ephemeral.random_password.api_db.result
    worker_password = ephemeral.random_password.worker_db.result
    mcp_password    = ephemeral.random_password.mcp_db.result
    api_url         = "postgresql://api:${ephemeral.random_password.api_db.result}@${module.postgres.address}:5432/postiz?connection_limit=5&application_name=api"
    worker_url      = "postgresql://worker:${ephemeral.random_password.worker_db.result}@${module.postgres.address}:5432/postiz?connection_limit=5&application_name=worker"
  })
  secret_string_wo_version = var.app_db_password_version
}

ephemeral "random_password" "temporal_db" {
  length  = 40
  special = false
}

resource "aws_secretsmanager_secret" "temporal_db" {
  name        = "${local.secret_prefix}/managed/temporal-db"
  description = "Login of the temporal role on ${local.name}-main, written by Terraform"
}

resource "aws_secretsmanager_secret_version" "temporal_db" {
  secret_id = aws_secretsmanager_secret.temporal_db.id
  secret_string_wo = jsonencode({
    username = "temporal"
    password = ephemeral.random_password.temporal_db.result
    host     = module.postgres.address
    dbname   = "temporal"
  })
  secret_string_wo_version = var.temporal_db_password_version
}

locals {
  database_urls = {
    api    = "${aws_secretsmanager_secret.app_db.arn}:api_url::"
    worker = "${aws_secretsmanager_secret.app_db.arn}:worker_url::"
  }
}
