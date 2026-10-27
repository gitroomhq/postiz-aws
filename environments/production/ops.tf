# One-off tasks: no service, started with `aws ecs run-task`.

# Railway's pre-deploy command. The deploy workflow pushes the new image as
# :migrate, runs this to completion, and only then moves :production.
module "db_push" {
  source = "../../modules/ecs-service"

  name                   = "db-push"
  create_service         = false
  cluster_name           = module.ecs_cluster.cluster_name
  cluster_arn            = module.ecs_cluster.cluster_arn
  capacity_provider_name = module.ecs_cluster.capacity_provider_name
  execution_role_arn     = aws_iam_role.execution.arn

  image              = local.migrate_image
  command            = ["pnpm", "run", "prisma-db-push"]
  cpu                = 512
  memory             = 3072
  memory_reservation = 1024
  secrets = {
    DATABASE_URL = local.app_secrets["backend"]["DATABASE_URL"]
  }

  log_retention_days = var.log_retention_days
}

# Migration toolbox (docker/ops.Dockerfile): PostgreSQL 16 client tools, python
# and scripts/. Started idle; you work inside it with ECS Exec. Bridge mode so
# it reaches both Railway's public TCP proxies and the private RDS/ES endpoints.
# Dumps go to /work on the host's root volume.
module "ops" {
  source = "../../modules/ecs-service"

  name                   = "ops"
  create_service         = false
  cluster_name           = module.ecs_cluster.cluster_name
  cluster_arn            = module.ecs_cluster.cluster_arn
  capacity_provider_name = module.ecs_cluster.capacity_provider_name
  execution_role_arn     = aws_iam_role.execution.arn

  image              = local.ops_image
  command            = ["sleep", "86400"]
  cpu                = 2048
  memory             = 12288
  memory_reservation = 2048
  stop_timeout       = 10

  secrets = {
    MAIN_ADMIN_URL       = "${module.postgres_main.admin_secret_arn}:url::"
    TEMPORAL_DB_PASSWORD = "${aws_secretsmanager_secret.temporal_db.arn}:password::"
    TARGET_ES_URL        = "${aws_secretsmanager_secret.elasticsearch.arn}:url::"
  }

  host_volumes = { work = "/var/lib/postiz-ops" }
  mount_points = [{ volume = "work", path = "/work", read_only = false }]

  log_retention_days = var.log_retention_days
}
