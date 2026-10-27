# ECS cluster on Graviton EC2 hosts behind an Auto Scaling group capacity provider.
#
# - Hosts run the ECS-optimized Amazon Linux 2023 arm64 AMI, resolved from SSM at
#   launch time, and are replaced every max_instance_lifetime_days, so they pick up
#   new AMIs (OS patches, new ECS agent) without anyone touching Terraform.
# - Managed scaling adds hosts when tasks cannot be placed; min_size is the
#   availability floor. Managed draining moves tasks off a host before it goes away.
# - IMDSv2 with hop limit 1: bridge-mode containers cannot reach the host role.

# Lets each host carry up to 20 awsvpc tasks (r8g.xlarge) instead of 3.
# Account-wide default for this region; hosts must register after it is set.
resource "aws_ecs_account_setting_default" "trunking" {
  count = var.enable_awsvpc_trunking ? 1 : 0
  name  = "awsvpcTrunking"
  value = "enabled"
}

resource "aws_ecs_cluster" "this" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = var.container_insights
  }
}

# --- host IAM ----------------------------------------------------------------

data "aws_iam_policy_document" "instance_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${var.name}-ecs-host"
  description        = "ECS container hosts of ${var.name}"
  assume_role_policy = data.aws_iam_policy_document.instance_trust.json
}

resource "aws_iam_role_policy_attachment" "instance_ecs" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

# Session Manager instead of SSH: no inbound port on the hosts.
resource "aws_iam_role_policy_attachment" "instance_ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name}-ecs-host"
  role = aws_iam_role.instance.name
}

# --- host network --------------------------------------------------------------

resource "aws_security_group" "instance" {
  name        = "${var.name}-ecs-hosts"
  description = "ECS hosts, bridge-mode tasks"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-ecs-hosts" }
}

# Bridge mode maps every container port to a random host port in this range.
resource "aws_vpc_security_group_ingress_rule" "instance_from_alb" {
  security_group_id            = aws_security_group.instance.id
  referenced_security_group_id = var.alb_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 32768
  to_port                      = 65535
  description                  = "ALB to dynamic container ports"
}

resource "aws_vpc_security_group_egress_rule" "instance_all" {
  security_group_id = aws_security_group.instance.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Social APIs, Cloudflare R2, RunPod, image registries"
}

# --- launch template + Auto Scaling group ------------------------------------

resource "aws_launch_template" "this" {
  name_prefix = "${var.name}-ecs-"
  image_id    = "resolve:ssm:/aws/service/ecs/optimized-ami/amazon-linux-2023/arm64/recommended/image_id"

  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.instance.arn
  }

  network_interfaces {
    associate_public_ip_address = true
    delete_on_termination       = true
    security_groups             = [aws_security_group.instance.id]
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_type           = "gp3"
      volume_size           = var.root_volume_size
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(<<-EOT
    #!/bin/bash
    cat >> /etc/ecs/ecs.config <<'EOF'
    ECS_CLUSTER=${var.name}
    ECS_ENABLE_TASK_IAM_ROLE=true
    ECS_AWSVPC_BLOCK_IMDS=true
    ECS_ENABLE_CONTAINER_METADATA=true
    ECS_CONTAINER_STOP_TIMEOUT=60s
    ECS_RESERVED_MEMORY=512
    ECS_ENGINE_TASK_CLEANUP_WAIT_DURATION=1h
    ECS_IMAGE_CLEANUP_INTERVAL=30m
    ECS_NUM_IMAGES_DELETE_PER_CYCLE=10
    EOF
    EOT
  )

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.name}-ecs-host" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "${var.name}-ecs-host" })
  }

  update_default_version = true
}

resource "aws_autoscaling_group" "this" {
  name                  = "${var.name}-ecs"
  vpc_zone_identifier   = var.subnet_ids
  min_size              = var.min_size
  max_size              = var.max_size
  max_instance_lifetime = var.max_instance_lifetime_days * 86400
  health_check_type     = "EC2"

  launch_template {
    id      = aws_launch_template.this.id
    version = aws_launch_template.this.latest_version
  }

  # Replacements come up before the old host is drained and terminated.
  instance_maintenance_policy {
    min_healthy_percentage = 100
    max_healthy_percentage = 200
  }

  # A launch template change rolls the hosts the same way.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 100
      max_healthy_percentage = 200
      instance_warmup        = 300
      skip_matching          = true
    }
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = var.tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    # owned by the capacity provider's managed scaling
    ignore_changes = [desired_capacity]
  }

  depends_on = [aws_ecs_account_setting_default.trunking]
}

resource "aws_ecs_capacity_provider" "this" {
  name = "${var.name}-ec2"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.this.arn
    managed_termination_protection = "DISABLED"
    managed_draining               = "ENABLED"

    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 100
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 1
      instance_warmup_period    = 180
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = [aws_ecs_capacity_provider.this.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.this.name
    weight            = 1
  }
}
