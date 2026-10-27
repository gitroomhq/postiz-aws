module "network" {
  source = "../../modules/network"

  name     = local.name
  region   = var.region
  cidr     = var.vpc_cidr
  az_count = 3
}

# postiz.internal: temporal-frontend and elasticsearch resolve here.
resource "aws_service_discovery_private_dns_namespace" "internal" {
  name        = local.internal_domain
  description = "Internal service discovery for ${local.name}"
  vpc         = module.network.vpc_id
}

# --- security groups -----------------------------------------------------------------
# RDS and ElastiCache groups live with their resources. Groups created here
# lose AWS's default allow-all egress, so every egress is spelled out.

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Public load balancer"
  vpc_id      = module.network.vpc_id
  tags        = { Name = "${local.name}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
  description       = "HTTPS"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
  description       = "HTTP, redirected to HTTPS"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_vpc" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "tcp"
  from_port         = 0
  to_port           = 65535
  cidr_ipv4         = var.vpc_cidr
  description       = "Targets inside the VPC"
}

# Every Temporal task (frontend, history, matching, worker, UI).
resource "aws_security_group" "temporal" {
  name        = "${local.name}-temporal"
  description = "Temporal server and UI tasks"
  vpc_id      = module.network.vpc_id
  tags        = { Name = "${local.name}-temporal" }
}

resource "aws_vpc_security_group_ingress_rule" "temporal_self" {
  security_group_id            = aws_security_group.temporal.id
  referenced_security_group_id = aws_security_group.temporal.id
  ip_protocol                  = "tcp"
  from_port                    = 0
  to_port                      = 65535
  description                  = "Membership and gRPC between Temporal roles"
}

resource "aws_vpc_security_group_ingress_rule" "temporal_from_apps" {
  security_group_id            = aws_security_group.temporal.id
  referenced_security_group_id = module.ecs_cluster.instance_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 7233
  to_port                      = 7233
  description                  = "Temporal frontend gRPC from Postiz backend and workers"
}

resource "aws_vpc_security_group_ingress_rule" "temporal_ui_from_hosts" {
  security_group_id            = aws_security_group.temporal.id
  referenced_security_group_id = module.ecs_cluster.instance_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 8081
  to_port                      = 8081
  description                  = "Temporal UI through the Session Manager tunnel on an ECS host"
}

resource "aws_vpc_security_group_ingress_rule" "temporal_ui_from_alb" {
  count = var.temporal_ui_public ? 1 : 0

  security_group_id            = aws_security_group.temporal.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8081
  to_port                      = 8081
  description                  = "Temporal UI behind basic auth (temporal_ui_public)"
}

resource "aws_vpc_security_group_egress_rule" "temporal_to_vpc" {
  security_group_id = aws_security_group.temporal.id
  ip_protocol       = "tcp"
  from_port         = 0
  to_port           = 65535
  cidr_ipv4         = var.vpc_cidr
  description       = "RDS, Elasticsearch and other Temporal roles"
}
