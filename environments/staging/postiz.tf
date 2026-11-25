# Postiz on Fargate: production's images and commands, smaller.
#   backend   serves api.getpostiz.com and mcp.getpostiz.com: production runs MCP
#             as a second service of the same image with MCP_ONLY, which only
#             leaves out the other routes
#   frontend  platform.getpostiz.com
#   worker    every Temporal task queue (production splits them over worker and
#             worker-2 with EXCLUDE_QUEUE)
# One task each, in the public subnets with a public IP for their calls out;
# their security group takes requests only from the load balancer and from each
# other.
#
# Task sizes are Fargate's (cpu units / MiB): the app's NODE_OPTIONS in its secret
# must keep the heap under them (scripts/staging-secrets.sh sets 1536).

locals {
  # apps/orchestrator serves GET /health/status on ORCHESTRATOR_PORT (3002): 200 once it can reach Temporal
  worker_health_check = {
    command      = ["CMD-SHELL", "node -e \"require('http').get('http://127.0.0.1:3002/health/status', r => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))\""]
    interval     = 30
    timeout      = 15
    retries      = 5
    start_period = 120
  }

  postiz_services = {
    backend = {
      app          = "backend"
      port         = 8080
      cpu          = 512
      memory       = 2048
      reservation  = 1536
      target_group = "backend"
      database     = "api"
      temporal     = true
      redis        = true
      email        = true
      tokens       = true
      health_check = null
      discovery    = true
    }
    frontend = {
      app          = "frontend"
      port         = 4200
      cpu          = 256
      memory       = 1024
      reservation  = 768
      target_group = "frontend"
      database     = null
      temporal     = false
      redis        = false
      email        = false
      tokens       = false
      health_check = null
      discovery    = false
    }
    worker = {
      app          = "orchestrator"
      port         = null
      cpu          = 512
      memory       = 2048
      reservation  = 1536
      target_group = null
      database     = "worker"
      temporal     = true
      redis        = true
      email        = true
      tokens       = true
      health_check = local.worker_health_check
      discovery    = false
    }
  }
}

# backend.postiz.internal -> the backend task's IP (BACKEND_INTERNAL_URL)
resource "aws_service_discovery_service" "backend" {
  name = "backend"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.internal.id
    routing_policy = "MULTIVALUE"
    dns_records {
      type = "A"
      ttl  = 10
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

module "postiz" {
  source   = "../../modules/ecs-service"
  for_each = local.postiz_services

  name               = each.key
  cluster_name       = aws_ecs_cluster.main.name
  cluster_arn        = aws_ecs_cluster.main.arn
  launch_type        = "fargate"
  fargate_spot       = var.fargate_spot
  network_mode       = "awsvpc"
  subnet_ids         = module.network.public_subnet_ids
  security_group_ids = [aws_security_group.apps.id]
  assign_public_ip   = true
  execution_role_arn = aws_iam_role.execution.arn

  image              = local.app_images[each.value.app]
  cpu                = each.value.cpu
  memory             = each.value.memory
  memory_reservation = each.value.reservation
  port               = each.value.port
  # Fargate's maximum
  stop_timeout = 120

  environment = merge(
    # the frontend's standalone server reads PORT too (and binds 0.0.0.0: the image sets HOSTNAME)
    each.value.port != null ? { PORT = tostring(each.value.port) } : {},
    each.value.temporal ? { TEMPORAL_ADDRESS = local.temporal_address } : {},
    # SES through the task role (ses.tf), in the sandbox: verified recipients only
    each.value.email ? { SES_REGION = var.region, EMAIL_PROVIDER = "ses" } : {},
    # channel tokens encrypted in the database with staging's own key (encryption.tf)
    each.value.tokens ? { ENCRYPTION_PROVIDER = "aws-kms", ENCRYPTION_KMS_REGION = var.region } : {},
  )
  secrets = merge(
    local.app_secrets[each.key],
    each.value.database != null ? { DATABASE_URL = local.database_urls[each.value.database] } : {},
    each.value.redis ? local.redis_url_secret : {},
    each.value.tokens ? { ENCRYPTION_KMS_DATA_KEY = aws_secretsmanager_secret.token_encryption_data_key.arn } : {},
  )

  task_role_policy_json = each.value.email ? data.aws_iam_policy_document.ses_send.json : null

  health_check         = each.value.health_check
  desired_count        = var.apps_enabled ? 1 : 0
  service_registry_arn = each.value.discovery ? aws_service_discovery_service.backend.arn : null
  # read through the listener rule (alb.tf): ECS refuses a target group that is not on a load balancer yet
  target_group_arn = each.value.target_group == null ? null : local.alb_target_group_arns[each.value.target_group]

  log_retention_days = var.log_retention_days

  # a service on FARGATE_SPOT is refused until the cluster has that capacity provider
  depends_on = [aws_ecs_cluster_capacity_providers.main]
}
