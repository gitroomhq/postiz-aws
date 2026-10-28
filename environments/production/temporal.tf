# The Temporal group from Railway: frontend, history, matching and worker as
# separate services (temporalio/auto-setup, same version and the same
# "broadcast my own address" start command), the UI behind basic auth,
# Elasticsearch visibility (elasticsearch.tf) and Postgres persistence (the
# "temporal" database on the main RDS instance, databases.tf).
#
# Railway ran one task per role. Here frontend, history and matching run two
# each, spread across hosts and AZs: losing a host no longer pauses every
# scheduled post until a replacement starts. The 4 history shards split 2/2.
#
# awsvpc networking: every task gets its own private IP, which Temporal needs
# for cluster membership. These tasks never talk to the internet.
#
# The whole cutover (pg_dump/restore, schema_version rename, index copy, this
# start command) was rehearsed with these exact images, see
# docs/migration-runbook.md.

locals {
  temporal_image    = var.temporal_image
  temporal_ui_image = var.temporal_ui_image
  caddy_image       = "caddy:2.10.2-alpine"

  # Railway computes TEMPORAL_BROADCAST_ADDRESS from its IPv6 address; here it
  # is the task's IPv4 (the source address of the default route).
  temporal_start = <<-EOT
    export TEMPORAL_BROADCAST_ADDRESS="$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    exec /etc/temporal/entrypoint.sh autosetup
  EOT

  temporal_env = {
    DB                 = "postgres12"
    DB_PORT            = "5432"
    POSTGRES_SEEDS     = module.postgres_main.address
    POSTGRES_USER      = "temporal"
    DBNAME             = "temporal"
    VISIBILITY_DBNAME  = "temporal_visibility"
    NUM_HISTORY_SHARDS = tostring(var.temporal_num_history_shards)

    # RDS forces TLS; the RDS CA is not in the image, so encrypt without verifying
    SQL_TLS_ENABLED                        = "true"
    SQL_HOST_VERIFICATION                  = "false"
    POSTGRES_TLS_ENABLED                   = "true"
    POSTGRES_TLS_DISABLE_HOST_VERIFICATION = "true"

    ENABLE_ES    = "true"
    ES_SEEDS     = local.elasticsearch_host
    ES_PORT      = "9200"
    ES_SCHEME    = "http"
    ES_VERSION   = "v7"
    ES_USER      = "elastic"
    ES_VIS_INDEX = "temporal_visibility_v1_dev"

    BIND_ON_IP              = "0.0.0.0"
    TEMPORAL_ADDRESS        = local.temporal_address
    TEMPORAL_CLI_ADDRESS    = local.temporal_address
    PUBLIC_FRONTEND_ADDRESS = local.temporal_address

    # organizationId/postId already exist; the sample attributes auto-setup adds
    # by default are noise (and would not fit the 3 Text slots of SQL visibility)
    SKIP_ADD_CUSTOM_SEARCH_ATTRIBUTES = "true"
  }

  temporal_secrets = {
    POSTGRES_PWD = "${aws_secretsmanager_secret.temporal_db.arn}:password::"
    ES_PWD       = "${aws_secretsmanager_secret.elasticsearch.arn}:password::"
  }

  # Sized from Railway's memory metrics: history holds the shard caches and needs the most
  temporal_roles = {
    frontend = { cpu = 256, memory = 1024, reservation = 512, schema = true }
    history  = { cpu = 512, memory = 4096, reservation = 3072, schema = false }
    matching = { cpu = 256, memory = 1024, reservation = 512, schema = false }
    worker   = { cpu = 128, memory = 512, reservation = 256, schema = false }
  }
}

# temporal-frontend.postiz.internal -> frontend task IPs
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

  # ECS reports task health (the frontend's container health check) to Cloud Map.
  # failure_threshold is deprecated (AWS always uses 1), but with an empty block
  # every plan replaced this service.
  health_check_custom_config {
    failure_threshold = 1
  }
}

module "temporal" {
  source   = "../../modules/ecs-service"
  for_each = local.temporal_roles

  name                   = "temporal-${each.key}"
  cluster_name           = module.ecs_cluster.cluster_name
  cluster_arn            = module.ecs_cluster.cluster_arn
  capacity_provider_name = module.ecs_cluster.capacity_provider_name
  execution_role_arn     = aws_iam_role.execution.arn
  network_mode           = "awsvpc"
  subnet_ids             = module.network.private_subnet_ids
  security_group_ids     = [aws_security_group.temporal.id]

  image              = local.temporal_image
  entry_point        = ["/bin/sh", "-c"]
  command            = [local.temporal_start]
  cpu                = each.value.cpu
  memory             = each.value.memory
  memory_reservation = each.value.reservation

  # Only the frontend runs schema checks and namespace setup, like a single
  # auto-setup would; the other roles just start the server.
  environment = merge(
    local.temporal_env,
    { SERVICES = each.key },
    each.value.schema ? {} : {
      SKIP_SCHEMA_SETUP               = "true"
      SKIP_DEFAULT_NAMESPACE_CREATION = "true"
    },
  )
  secrets = local.temporal_secrets

  health_check = each.key == "frontend" ? {
    command      = ["CMD-SHELL", "temporal operator cluster health --address 127.0.0.1:7233 | grep -q SERVING || exit 1"]
    interval     = 30
    timeout      = 10
    retries      = 3
    start_period = 180
  } : null

  service_registry_arn = each.key == "frontend" ? aws_service_discovery_service.temporal_frontend.arn : null
  desired_count        = var.apps_enabled ? var.temporal_task_counts[each.key] : 0

  log_retention_days = var.log_retention_days
}

# --- UI ------------------------------------------------------------------------------------
# Same as Railway: temporalio/ui behind a Caddy basic-auth proxy. The
# USERNAME/PASSWORD pair is copied from Railway's "Temporal Basic Auth" service.
# Private by default: scripts/temporal-ui-tunnel.sh forwards localhost:8081 to it
# through Session Manager; temporal_ui_public puts it behind the ALB instead.

locals {
  basic_auth_proxy = <<-EOT
    set -e
    HASH="$(caddy hash-password --plaintext "$PASSWORD")"
    cat > /etc/caddy/Caddyfile <<CADDY
    {
    	admin off
    }
    :8081 {
    	@protected not path /healthz
    	basic_auth @protected {
    		$USERNAME $HASH
    	}
    	respond /healthz 200
    	reverse_proxy 127.0.0.1:8080
    }
    CADDY
    exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
  EOT
}

module "temporal_ui" {
  source = "../../modules/ecs-service"

  name                   = "temporal-ui"
  cluster_name           = module.ecs_cluster.cluster_name
  cluster_arn            = module.ecs_cluster.cluster_arn
  capacity_provider_name = module.ecs_cluster.capacity_provider_name
  execution_role_arn     = aws_iam_role.execution.arn
  network_mode           = "awsvpc"
  subnet_ids             = module.network.private_subnet_ids
  security_group_ids     = [aws_security_group.temporal.id]

  image              = local.temporal_ui_image
  cpu                = 128
  memory             = 512
  memory_reservation = 256
  environment = {
    TEMPORAL_ADDRESS      = local.temporal_address
    TEMPORAL_UI_PORT      = "8080"
    TEMPORAL_CORS_ORIGINS = var.temporal_ui_public ? "https://${var.temporal_ui_domain}" : "http://localhost:8081"
    TEMPORAL_AUTH_ENABLED = "false"
  }

  sidecars = [{
    name              = "basic-auth"
    image             = local.caddy_image
    cpu               = 64
    memory            = 128
    memoryReservation = 64
    entryPoint        = ["/bin/sh", "-c"]
    command           = [local.basic_auth_proxy]
    portMappings      = [{ containerPort = 8081, hostPort = 8081, protocol = "tcp" }]
    # deploys wait for Caddy's /healthz also when no load balancer checks it
    healthCheck = {
      command     = ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:8081/healthz || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 10
    }
    secrets = [
      { name = "USERNAME", valueFrom = "${aws_secretsmanager_secret.app["temporal-ui-auth"].arn}:USERNAME::" },
      { name = "PASSWORD", valueFrom = "${aws_secretsmanager_secret.app["temporal-ui-auth"].arn}:PASSWORD::" },
    ]
  }]

  target_group_arn  = var.temporal_ui_public ? aws_lb_listener_rule.app["temporal-ui"].action[0].target_group_arn : null
  lb_container_name = "basic-auth"
  lb_container_port = 8081
  desired_count     = var.apps_enabled ? 1 : 0

  log_retention_days = var.log_retention_days
}
