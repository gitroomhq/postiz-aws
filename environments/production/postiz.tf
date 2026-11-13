# The Postiz group from Railway: Backend (2 replicas), MCP (1 on Railway, 2 here),
# Frontend, Worker, Worker 2. Each runs its app's slim image (docker/postiz-app.Dockerfile) with the
# image's own command: the node process Railway's start:prod:* scripts ended in,
# without pnpm in front. The command lives in the image because it depends on the
# image's layout, so a rollback to an older image also gets that image's command.
#
# Bridge networking: containers reach the social APIs, R2 and RunPod through
# their host's public IP (no NAT gateway).
#
# Sized from Railway's memory metrics (average, p99, max) with headroom, and
# above the heap each service's NODE_OPTIONS allows.
# memory_reservation is what placement counts; memory is the kill limit.

locals {
  # apps/orchestrator serves GET /health/status on ORCHESTRATOR_PORT (3002): 200 once it
  # can reach Temporal. A new worker must pass it before the old one is stopped; five
  # failures in a row (2.5 minutes) replace the task, so a short Temporal blip does not.
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
      cpu          = 1024
      memory       = 9216
      reservation  = 4608
      desired      = var.backend_count
      autoscaling  = { max = var.backend_max_count, cpu_target = 60 }
      target_group = "backend"
      temporal     = true
      redis        = true
      email        = true
      tokens       = true
      health_check = null
      publishes    = false
    }
    # Two copies, so a crash or a lost server leaves one serving. Either copy can
    # answer any request: /mcp runs stateless (serverless: true), and OAuth tokens
    # and the self-hosted relay are looked up in the database. (Legacy SSE,
    # /sse + /message, would need one copy, but it already fails on every
    # message: postiz-app builds a new MCPServer per request.)
    mcp = {
      app          = "backend"
      port         = 8080
      cpu          = 512
      memory       = 6144
      reservation  = 2560
      desired      = 2
      autoscaling  = null
      target_group = "mcp"
      temporal     = true
      redis        = true
      email        = true
      tokens       = true
      health_check = null
      publishes    = false
    }
    frontend = {
      app          = "frontend"
      port         = 4200
      cpu          = 256
      memory       = 2048
      reservation  = 1024
      desired      = var.frontend_count
      autoscaling  = null
      target_group = "frontend"
      temporal     = false
      redis        = false
      email        = false
      tokens       = false
      health_check = null
      publishes    = false
    }
    worker = {
      app          = "orchestrator"
      port         = null
      cpu          = 512
      memory       = 7168
      reservation  = 4096
      desired      = 1
      autoscaling  = null
      target_group = null
      temporal     = true
      redis        = true
      email        = true
      tokens       = true
      health_check = local.worker_health_check
      publishes    = true
    }
    # its EXCLUDE_QUEUE comes with its secret, like on Railway
    worker-2 = {
      app          = "orchestrator"
      port         = null
      cpu          = 512
      memory       = 7168
      reservation  = 3584
      desired      = 1
      autoscaling  = null
      target_group = null
      temporal     = true
      redis        = true
      email        = true
      tokens       = true
      health_check = local.worker_health_check
      publishes    = true
    }
  }
}

module "postiz" {
  source   = "../../modules/ecs-service"
  for_each = local.postiz_services

  name                   = each.key
  cluster_name           = module.ecs_cluster.cluster_name
  cluster_arn            = module.ecs_cluster.cluster_arn
  capacity_provider_name = module.ecs_cluster.capacity_provider_name
  execution_role_arn     = aws_iam_role.execution.arn
  network_mode           = "bridge"

  image              = local.app_images[each.value.app]
  cpu                = each.value.cpu
  memory             = each.value.memory
  memory_reservation = each.value.reservation
  port               = each.value.port
  stop_timeout       = 120

  environment = merge(
    # the frontend's standalone server reads PORT too (and binds 0.0.0.0: the image sets HOSTNAME)
    each.value.port != null ? { PORT = tostring(each.value.port) } : {},
    each.value.temporal ? { TEMPORAL_ADDRESS = local.temporal_address } : {},
    # SES through the task role (ses.tf); EMAIL_PROVIDER from the secret (Railway's) until switched
    each.value.email ? { SES_REGION = var.region } : {},
    each.value.email && var.ses_sending_enabled ? { EMAIL_PROVIDER = "ses" } : {},
    # channel tokens encrypted in the database, the key through the task role (encryption.tf)
    each.value.tokens && var.token_encryption != "off" ? {
      ENCRYPTION_PROVIDER   = "aws-kms"
      ENCRYPTION_KMS_REGION = var.region
    } : {},
    each.value.tokens && var.token_encryption == "read-only" ? { ENCRYPTION_READ_ONLY = "true" } : {},
  )
  secrets = merge(
    # a name may not be both an environment variable and a secret
    {
      for k, v in local.app_secrets[each.key] : k => v
      if !(k == "EMAIL_PROVIDER" && each.value.email && var.ses_sending_enabled)
    },
    each.value.redis ? local.redis_url_secret : {},
    each.value.tokens && var.token_encryption != "off" ? {
      ENCRYPTION_KMS_DATA_KEY = aws_secretsmanager_secret.token_encryption_data_key.arn
    } : {},
  )

  task_role_policy_json = each.value.email ? data.aws_iam_policy_document.ses_send.json : null

  health_check = each.value.health_check
  # the workers publish posts, so they also wait for workers_enabled (go-live)
  desired_count = var.apps_enabled && (var.workers_enabled || !each.value.publishes) ? each.value.desired : 0
  autoscaling   = each.value.autoscaling
  # read through the listener rule (alb.tf): ECS refuses a target group that is not on a load balancer yet
  target_group_arn = each.value.target_group == null ? null : local.alb_target_group_arns[each.value.target_group]

  log_retention_days = var.log_retention_days
}
