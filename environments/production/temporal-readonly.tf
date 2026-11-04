# Read-only Temporal for the team (postiz-team-readonly, bootstrap/).
#
# The frontend has no authorization: whoever reaches temporal-frontend:7233 can
# terminate, reset or delete any workflow. So the team never reaches it. They reach
# temporal-readonly.postiz.internal:7233, a Caddy proxy that forwards an exact list
# of read calls to the frontend and refuses everything else with 403 (Forbidden).
# The refusal happens here, on the server side, whatever client connects.
#
# The only way in is the Session Manager tunnel postiz-team-temporal-readonly
# (team-tunnels.tf), whose host and port are fixed, relayed by an ECS host.
# scripts/temporal-cli.sh sends reads this way for everyone; --write still goes
# straight to the frontend and needs an admin sign-in.

locals {
  temporal_readonly_host = "temporal-readonly.${local.internal_domain}"

  # Exact gRPC methods the proxy passes. Reads only: list, describe, get, count and
  # scan, queries (answered by a worker from history, never changing it) and waiting
  # on an update's outcome. Left out on purpose: every call that starts, signals,
  # updates, resets, pauses, terminates or deletes; the Poll*TaskQueue calls workers
  # use, since one would take a task away from a real worker; and all of AdminService.
  # Listed from the server's own reflection; a method an older server lacks just
  # answers Unimplemented.
  temporal_readonly_methods = {
    "temporal.api.workflowservice.v1.WorkflowService" = [
      "CountActivityExecutions", "CountWorkflowExecutions",
      "DescribeActivityExecution", "DescribeBatchOperation", "DescribeDeployment", "DescribeNamespace",
      "DescribeSchedule", "DescribeTaskQueue", "DescribeWorker", "DescribeWorkerDeployment",
      "DescribeWorkerDeploymentVersion", "DescribeWorkflowExecution", "DescribeWorkflowRule",
      "GetClusterInfo", "GetCurrentDeployment", "GetDeploymentReachability", "GetSearchAttributes",
      "GetSystemInfo", "GetWorkerBuildIdCompatibility", "GetWorkerTaskReachability",
      "GetWorkerVersioningRules", "GetWorkflowExecutionHistory", "GetWorkflowExecutionHistoryReverse",
      "ListActivityExecutions", "ListArchivedWorkflowExecutions", "ListBatchOperations",
      "ListClosedWorkflowExecutions", "ListDeployments", "ListNamespaces", "ListOpenWorkflowExecutions",
      "ListScheduleMatchingTimes", "ListSchedules", "ListTaskQueuePartitions", "ListWorkerDeployments",
      "ListWorkers", "ListWorkflowExecutions", "ListWorkflowRules",
      "PollWorkflowExecutionUpdate", "QueryWorkflow", "ScanWorkflowExecutions",
    ]
    "temporal.api.operatorservice.v1.OperatorService" = [
      "GetNexusEndpoint", "ListClusters", "ListNexusEndpoints", "ListSearchAttributes",
    ]
    "grpc.health.v1.Health" = ["Check"]
  }

  temporal_readonly_paths = flatten([
    for service, methods in local.temporal_readonly_methods : [for m in methods : "/${service}/${m}"]
  ])

  # gRPC is HTTP/2 without TLS here (h2c), on both sides. A refused call gets HTTP
  # 403, which the Temporal CLI prints as "unexpected HTTP status code received from
  # server: 403 (Forbidden)", and the access log records its method.
  # TEMPORAL_FRONTEND is read when Caddy starts.
  temporal_readonly_caddyfile = <<-EOT
    {
    	admin off
    	servers {
    		protocols h1 h2c
    	}
    }

    :7233 {
    	log
    	log_skip /healthz
    	@read path ${join(" ", local.temporal_readonly_paths)}
    	handle @read {
    		reverse_proxy h2c://{$TEMPORAL_FRONTEND} {
    			flush_interval -1
    		}
    	}
    	handle /healthz {
    		respond 200
    	}
    	handle {
    		respond "temporal-readonly passes only read calls" 403
    	}
    }
  EOT

  temporal_readonly_start = <<-EOT
    set -e
    printf '%s\n' "$CADDYFILE" > /etc/caddy/Caddyfile
    exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
  EOT
}

# temporal-readonly.postiz.internal -> proxy task IP
resource "aws_service_discovery_service" "temporal_readonly" {
  name = "temporal-readonly"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.internal.id
    routing_policy = "MULTIVALUE"
    dns_records {
      type = "A"
      ttl  = 10
    }
  }

  # see temporal_frontend: AWS always uses 1, an empty block replaced it every plan
  health_check_custom_config {
    failure_threshold = 1
  }
}

module "temporal_readonly" {
  source = "../../modules/ecs-service"

  name                   = "temporal-readonly"
  cluster_name           = module.ecs_cluster.cluster_name
  cluster_arn            = module.ecs_cluster.cluster_arn
  capacity_provider_name = module.ecs_cluster.capacity_provider_name
  execution_role_arn     = aws_iam_role.execution.arn
  network_mode           = "awsvpc"
  subnet_ids             = module.network.private_subnet_ids
  # The Temporal group: it reaches the frontend (temporal_self), and the ECS hosts,
  # where the Session Manager tunnel comes out, reach it on 7233 (temporal_from_apps).
  security_group_ids = [aws_security_group.temporal.id]

  image              = local.caddy_image
  entry_point        = ["/bin/sh", "-c"]
  command            = [local.temporal_readonly_start]
  cpu                = 64
  memory             = 128
  memory_reservation = 64
  port               = 7233
  environment = {
    CADDYFILE         = local.temporal_readonly_caddyfile
    TEMPORAL_FRONTEND = local.temporal_address
  }

  health_check = {
    command      = ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:7233/healthz || exit 1"]
    interval     = 30
    timeout      = 5
    retries      = 3
    start_period = 10
  }

  service_registry_arn = aws_service_discovery_service.temporal_readonly.arn
  desired_count        = var.apps_enabled ? 1 : 0

  log_retention_days = var.log_retention_days
}

