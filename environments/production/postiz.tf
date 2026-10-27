# The Postiz group from Railway: Backend (2 replicas), MCP, Frontend, Worker,
# Worker 2. Same start commands as Railway, one image built from postiz-app.
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
      command      = ["pnpm", "run", "start:prod:backend"]
      port         = 8080
      cpu          = 1024
      memory       = 9216
      reservation  = 4608
      desired      = var.backend_count
      autoscaling  = { max = var.backend_max_count, cpu_target = 60 }
      target_group = "backend"
      temporal     = true
      redis        = true
      health_check = null
      publishes    = false
    }
    mcp = {
      command      = ["pnpm", "run", "start:prod:backend"]
      port         = 8080
      cpu          = 512
      memory       = 6144
      reservation  = 2560
      desired      = 1
      autoscaling  = null
      target_group = "mcp"
      temporal     = true
      redis        = true
      health_check = null
      publishes    = false
    }
    frontend = {
      command      = ["pnpm", "run", "start:prod:frontend"]
      port         = 4200
      cpu          = 256
      memory       = 2048
      reservation  = 1024
      desired      = var.frontend_count
      autoscaling  = null
      target_group = "frontend"
      temporal     = false
      redis        = false
      health_check = null
      publishes    = false
    }
    worker = {
      command      = ["pnpm", "run", "start:prod:orchestrator"]
      port         = null
      cpu          = 512
      memory       = 7168
      reservation  = 4096
      desired      = 1
      autoscaling  = null
      target_group = null
      temporal     = true
      redis        = true
      health_check = local.worker_health_check
      publishes    = true
    }
    # its EXCLUDE_QUEUE comes with its secret, like on Railway
    worker-2 = {
      command      = ["pnpm", "run", "start:prod:orchestrator"]
      port         = null
      cpu          = 512
      memory       = 7168
      reservation  = 3584
      desired      = 1
      autoscaling  = null
      target_group = null
      temporal     = true
      redis        = true
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

  image              = local.app_image
  command            = each.value.command
  cpu                = each.value.cpu
  memory             = each.value.memory
  memory_reservation = each.value.reservation
  port               = each.value.port
  stop_timeout       = 120

  environment = merge(
    each.value.port != null && each.key != "frontend" ? { PORT = tostring(each.value.port) } : {},
    each.value.temporal ? { TEMPORAL_ADDRESS = local.temporal_address } : {},
  )
  secrets = merge(
    local.app_secrets[each.key],
    each.value.redis ? local.redis_url_secret : {},
  )

  health_check = each.value.health_check
  # the workers publish posts, so they also wait for workers_enabled (go-live)
  desired_count = var.apps_enabled && (var.workers_enabled || !each.value.publishes) ? each.value.desired : 0
  autoscaling   = each.value.autoscaling
  # read through the listener rule: ECS refuses a target group that is not on a load balancer yet
  target_group_arn = each.value.target_group == null ? null : aws_lb_listener_rule.app[each.value.target_group].action[0].target_group_arn

  log_retention_days = var.log_retention_days
}
