# One RDS instance, two databases:
#   postiz    Railway "Postgres". Backend, MCP and workers connect directly with
#             their own roles (api, mcp, worker) and connection_limit=8.
#   temporal  Railway "Postgres-NlPS", Temporal persistence, role "temporal".
#
# Both are light on Railway, so a second instance would mostly idle. Sharing one Multi-AZ instance is cheaper than a separate
# Single-AZ Temporal instance, and gives Temporal Multi-AZ failover too.
# Watch FreeableMemory/ReadIOPS for the first weeks; if the two compete, move
# temporal back to its own instance (dump/restore, minutes of scheduling pause).
#
# PgBouncer is gone: it ran in session mode, so it only capped connections. The
# per-role connection limits do that now (scripts/migrate-postgres.sh), well
# below db.r8g.large's ~1700.
module "postgres_main" {
  source = "../../modules/rds-postgres"

  identifier            = "${local.name}-main"
  engine_version        = var.postgres_engine_version
  instance_class        = var.main_db_instance_class
  multi_az              = var.main_db_multi_az
  db_name               = "postiz"
  username              = "postgres"
  password_version      = var.main_db_password_version
  allocated_storage     = 100
  max_allocated_storage = 1000

  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.private_subnet_ids
  allowed_security_group_ids = {
    ecs-hosts = module.ecs_cluster.instance_security_group_id
    temporal  = aws_security_group.temporal.id
  }

  parameters = {
    log_min_duration_statement = { value = "1000", apply_method = "immediate" }
    # Prisma negotiates TLS on its own, but Mastra's PostgresStore (node-postgres,
    # same DATABASE_URL) only uses TLS when the URL asks for it, and node-postgres
    # treats sslmode=require as verify-full, which fails on the RDS CA. Same as on
    # Railway: plaintext inside the private network. To force TLS later, bake the
    # RDS CA bundle into the image (NODE_EXTRA_CA_CERTS), add sslmode=require to
    # the URLs, then remove this.
    "rds.force_ssl" = { value = "0", apply_method = "pending-reboot" }
  }

  secret_prefix   = local.secret_prefix
  alarm_topic_arn = aws_sns_topic.alerts.arn
}

# Login of the "temporal" role. Terraform cannot reach the database, so
# scripts/migrate-postgres.sh creates the role (and the temporal database it
# owns) with this password during the migration. To rotate: bump
# temporal_db_password_version, apply, run `migrate-postgres.sh temporal-password`
# in the ops task, then restart the temporal-* services.
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
    host     = module.postgres_main.address
    dbname   = "temporal"
  })
  secret_string_wo_version = var.temporal_db_password_version
}
