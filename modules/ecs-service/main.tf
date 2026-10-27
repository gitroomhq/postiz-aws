# One ECS task definition (main container + optional sidecars) and, unless
# create_service = false, the service that keeps it running.
#
# bridge mode: dynamic host ports, ALB targets are instances, egress through the
#              host's public IP (internet-facing app containers).
# awsvpc mode: own ENI in a private subnet, ALB targets are IPs, discoverable
#              through Cloud Map A records (internal-only containers).

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  family    = "${var.cluster_name}-${var.name}"
  log_group = "/ecs/${var.cluster_name}/${var.name}"
  awsvpc    = var.network_mode == "awsvpc"

  log_configuration = {
    logDriver = "awslogs"
    options = {
      awslogs-group         = local.log_group
      awslogs-region        = data.aws_region.current.region
      awslogs-stream-prefix = var.name
      mode                  = "non-blocking"
      max-buffer-size       = "25m"
    }
  }

  main_container = {
    name      = var.name
    image     = var.image
    essential = true
    # every task of a deployment runs the digest resolved when it started, and a
    # rollback returns to the previous digest even though the tag (:production) moved;
    # explicit, because with EC2 capacity providers the default can be skipped
    versionConsistency = "enabled"
    command            = var.command
    entryPoint         = var.entry_point
    cpu                = var.cpu
    memory             = var.memory
    memoryReservation  = var.memory_reservation
    stopTimeout        = var.stop_timeout
    portMappings = var.port == null ? [] : [{
      containerPort = var.port
      hostPort      = local.awsvpc ? var.port : 0
      protocol      = "tcp"
    }]
    environment      = [for k in sort(keys(var.environment)) : { name = k, value = var.environment[k] }]
    secrets          = [for k in sort(keys(var.secrets)) : { name = k, valueFrom = var.secrets[k] }]
    mountPoints      = [for m in var.mount_points : { sourceVolume = m.volume, containerPath = m.path, readOnly = m.read_only }]
    logConfiguration = local.log_configuration
    # tini as PID 1: forwards SIGTERM through `pnpm run` so shutdowns are graceful
    linuxParameters = { initProcessEnabled = true }
    healthCheck = var.health_check == null ? null : {
      command     = var.health_check.command
      interval    = var.health_check.interval
      timeout     = var.health_check.timeout
      retries     = var.health_check.retries
      startPeriod = var.health_check.start_period
    }
  }

  containers = concat(
    [{ for k, v in local.main_container : k => v if v != null }],
    [for s in var.sidecars : merge({ logConfiguration = local.log_configuration, essential = true, versionConsistency = "enabled" }, s)],
  )

  lb_container_name = coalesce(var.lb_container_name, var.name)
  lb_container_port = coalesce(var.lb_container_port, var.port, 0)
}

resource "aws_cloudwatch_log_group" "this" {
  name              = local.log_group
  retention_in_days = var.log_retention_days
}

# --- task role: what the application itself may call --------------------------

data "aws_iam_policy_document" "task_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ecs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

resource "aws_iam_role" "task" {
  name               = "${local.family}-task"
  description        = "Task role of ${local.family}"
  assume_role_policy = data.aws_iam_policy_document.task_trust.json
}

# ECS Exec (aws ecs execute-command) for debugging.
data "aws_iam_policy_document" "exec" {
  statement {
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "exec" {
  name   = "ecs-exec"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.exec.json
}

resource "aws_iam_role_policy" "extra" {
  count  = var.task_role_policy_json == null ? 0 : 1
  name   = "extra"
  role   = aws_iam_role.task.id
  policy = var.task_role_policy_json
}

# --- task definition --------------------------------------------------------------

resource "aws_ecs_task_definition" "this" {
  family                   = local.family
  network_mode             = var.network_mode
  requires_compatibilities = ["EC2"]
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = aws_iam_role.task.arn
  container_definitions    = jsonencode(local.containers)

  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  dynamic "volume" {
    for_each = var.host_volumes
    content {
      name      = volume.key
      host_path = volume.value
    }
  }
}

# --- service ------------------------------------------------------------------------

resource "aws_ecs_service" "this" {
  count = var.create_service ? 1 : 0

  name                    = var.name
  cluster                 = var.cluster_arn
  task_definition         = aws_ecs_task_definition.this.arn
  desired_count           = var.desired_count
  enable_execute_command  = true
  enable_ecs_managed_tags = true
  propagate_tags          = "SERVICE"

  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent
  deployment_maximum_percent         = var.deployment_maximum_percent
  health_check_grace_period_seconds  = var.target_group_arn == null ? null : var.health_check_grace_period

  capacity_provider_strategy {
    capacity_provider = var.capacity_provider_name
    weight            = 1
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  ordered_placement_strategy {
    type  = "spread"
    field = "attribute:ecs.availability-zone"
  }

  ordered_placement_strategy {
    type  = "spread"
    field = "instanceId"
  }

  dynamic "network_configuration" {
    for_each = local.awsvpc ? [1] : []
    content {
      subnets          = var.subnet_ids
      security_groups  = var.security_group_ids
      assign_public_ip = false
    }
  }

  dynamic "load_balancer" {
    for_each = var.target_group_arn == null ? [] : [1]
    content {
      target_group_arn = var.target_group_arn
      container_name   = local.lb_container_name
      container_port   = local.lb_container_port
    }
  }

  dynamic "service_registries" {
    for_each = var.service_registry_arn == null ? [] : [1]
    content {
      registry_arn = var.service_registry_arn
    }
  }
}

# --- CPU autoscaling (optional) ----------------------------------------------------
# Terraform owns desired_count, so an apply resets a scaled-out service to
# desired_count and autoscaling grows it back within a few minutes.

resource "aws_appautoscaling_target" "this" {
  count = var.create_service && var.autoscaling != null ? 1 : 0

  service_namespace  = "ecs"
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.this[0].name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.desired_count
  max_capacity       = var.desired_count == 0 ? 0 : var.autoscaling.max
}

resource "aws_appautoscaling_policy" "cpu" {
  count = var.create_service && var.autoscaling != null ? 1 : 0

  name               = "${local.family}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = var.autoscaling.cpu_target
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
