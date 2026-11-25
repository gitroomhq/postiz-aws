# Temporal in one task: temporalio/auto-setup runs all four roles (frontend,
# history, matching, worker) in one process, same image and start command as
# production's four services, with the UI as a sidecar.
#
# Visibility lives in Postgres (database temporal_visibility), not in
# Elasticsearch: one host less. postiz-app registers its organizationId and
# postId search attributes itself at startup (temporal.register.ts), and SQL
# visibility answers the workflow.list('postId="..." AND
# ExecutionStatus="Running"') it uses before deleting or rescheduling a post.
# A difference from production to keep in mind when a bug only shows on one.
#
# The UI has no public name and no load balancer rule: open it through a Session
# Manager port forward into the task (scripts/staging-temporal-ui.sh).

locals {
  temporal_start = <<-EOT
    export TEMPORAL_BROADCAST_ADDRESS="$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    exec /etc/temporal/entrypoint.sh autosetup
  EOT

  temporal_env = {
    DB                 = "postgres12"
    DB_PORT            = "5432"
    POSTGRES_SEEDS     = module.postgres.address
    POSTGRES_USER      = "temporal"
    DBNAME             = "temporal"
    VISIBILITY_DBNAME  = "temporal_visibility"
    NUM_HISTORY_SHARDS = tostring(var.temporal_num_history_shards)
    # the db init task creates both databases, owned by temporal (which may not
    # create databases itself); auto-setup then only installs and updates schemas
    SKIP_DB_CREATE = "true"
    # 10 connections per store, two stores: room for the apps on a db.t4g.micro
    SQL_MAX_CONNS      = "10"
    SQL_MAX_IDLE_CONNS = "5"

    SQL_TLS_ENABLED                        = "true"
    SQL_HOST_VERIFICATION                  = "false"
    POSTGRES_TLS_ENABLED                   = "true"
    POSTGRES_TLS_DISABLE_HOST_VERIFICATION = "true"

    ENABLE_ES = "false"

    BIND_ON_IP              = "0.0.0.0"
    TEMPORAL_ADDRESS        = local.temporal_address
    TEMPORAL_CLI_ADDRESS    = local.temporal_address
    PUBLIC_FRONTEND_ADDRESS = local.temporal_address

    # postiz-app adds the two it uses (temporal.register.ts)
    SKIP_ADD_CUSTOM_SEARCH_ATTRIBUTES = "true"
  }
}

# temporal-frontend.postiz.internal -> the task's IP
resource "aws_service_discovery_service" "temporal_frontend" {
  name = "temporal-frontend"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.internal.id
    routing_policy = "MULTIVALUE"
    dns_records {
      type = "A"
      ttl  = 10
    }
  }

  # failure_threshold is deprecated (AWS always uses 1), but with an empty block
  # every plan replaced this service
  health_check_custom_config {
    failure_threshold = 1
  }
}

module "temporal" {
  source = "../../modules/ecs-service"

  name               = "temporal"
  cluster_name       = aws_ecs_cluster.main.name
  cluster_arn        = aws_ecs_cluster.main.arn
  launch_type        = "fargate"
  fargate_spot       = var.fargate_spot
  network_mode       = "awsvpc"
  subnet_ids         = module.network.public_subnet_ids
  security_group_ids = [aws_security_group.temporal.id]
  # Docker Hub pulls; inbound stays closed (security group)
  assign_public_ip   = true
  execution_role_arn = aws_iam_role.execution.arn

  image              = var.temporal_image
  entry_point        = ["/bin/sh", "-c"]
  command            = [local.temporal_start]
  port               = 7233
  cpu                = 512
  memory             = 2048
  memory_reservation = 1536

  environment = local.temporal_env
  secrets = {
    POSTGRES_PWD = "${aws_secretsmanager_secret.temporal_db.arn}:password::"
  }

  health_check = {
    command      = ["CMD-SHELL", "temporal operator cluster health --address 127.0.0.1:7233 | grep -q SERVING || exit 1"]
    interval     = 30
    timeout      = 10
    retries      = 3
    start_period = 180
  }

  sidecars = [{
    name              = "ui"
    image             = var.temporal_ui_image
    essential         = false
    memoryReservation = 128
    environment = [
      { name = "TEMPORAL_ADDRESS", value = "127.0.0.1:7233" },
      { name = "TEMPORAL_UI_PORT", value = "8080" },
      { name = "TEMPORAL_CORS_ORIGINS", value = "http://localhost:8080" },
      { name = "TEMPORAL_AUTH_ENABLED", value = "false" },
    ]
  }]

  service_registry_arn = aws_service_discovery_service.temporal_frontend.arn
  # never two Temporal servers on one database at once: the old task stops first
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  desired_count                      = var.apps_enabled ? 1 : 0

  log_retention_days = var.log_retention_days

  # a service on FARGATE_SPOT is refused until the cluster has that capacity provider
  depends_on = [aws_ecs_cluster_capacity_providers.main]
}
