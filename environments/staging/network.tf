# Same layout as production, two Availability Zones instead of three (the load
# balancer's minimum): public subnets for the load balancer and every Fargate
# task, private subnets for RDS and Valkey, no NAT gateway. The tasks reach the
# internet (social APIs, R2, image registries) through their own public IP;
# their security groups take nothing from the internet.
module "network" {
  source = "../../modules/network"

  name     = local.name
  region   = var.region
  cidr     = var.vpc_cidr
  az_count = 2
}

# postiz.internal: temporal-frontend and backend resolve here.
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

# With client certificates, anyone may start a connection and the load balancer
# ends it unless a certificate of the staging CA comes with it (alb.tf). Without
# them, only the listed addresses get this far.
resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = toset(var.client_certificates_required ? ["0.0.0.0/0"] : var.open_to_cidrs)

  security_group_id = aws_security_group.alb.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
  description       = var.client_certificates_required ? "HTTPS, client certificate required" : "HTTPS from an allowed address"
}

resource "aws_vpc_security_group_ingress_rule" "alb_stripe" {
  for_each = toset(var.stripe_webhook_ips)

  security_group_id = aws_security_group.alb.id
  ip_protocol       = "tcp"
  from_port         = 8443
  to_port           = 8443
  cidr_ipv4         = "${each.value}/32"
  description       = "Stripe webhooks"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_vpc" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "tcp"
  from_port         = 0
  to_port           = 65535
  cidr_ipv4         = var.vpc_cidr
  description       = "Targets inside the VPC"
}

# frontend, backend, worker and the one-off tasks (db push, db init)
resource "aws_security_group" "apps" {
  name        = "${local.name}-apps"
  description = "Postiz Fargate tasks"
  vpc_id      = module.network.vpc_id
  tags        = { Name = "${local.name}-apps" }
}

resource "aws_vpc_security_group_ingress_rule" "apps_from_alb" {
  for_each = { backend = 8080, frontend = 4200 }

  security_group_id            = aws_security_group.apps.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  description                  = "Load balancer to ${each.key}"
}

resource "aws_vpc_security_group_ingress_rule" "apps_to_backend" {
  security_group_id            = aws_security_group.apps.id
  referenced_security_group_id = aws_security_group.apps.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  description                  = "Frontend server pages and workers to the backend (BACKEND_INTERNAL_URL)"
}

resource "aws_vpc_security_group_egress_rule" "apps_all" {
  security_group_id = aws_security_group.apps.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Social APIs, R2, image registries, AWS APIs, RDS, Valkey, Temporal"
}

# The one Temporal task (server and UI)
resource "aws_security_group" "temporal" {
  name        = "${local.name}-temporal"
  description = "Temporal server and UI task"
  vpc_id      = module.network.vpc_id
  tags        = { Name = "${local.name}-temporal" }
}

resource "aws_vpc_security_group_ingress_rule" "temporal_from_apps" {
  security_group_id            = aws_security_group.temporal.id
  referenced_security_group_id = aws_security_group.apps.id
  ip_protocol                  = "tcp"
  from_port                    = 7233
  to_port                      = 7233
  description                  = "Temporal frontend gRPC from Postiz backend and workers"
}

resource "aws_vpc_security_group_egress_rule" "temporal_all" {
  security_group_id = aws_security_group.temporal.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Docker Hub image pulls, AWS APIs, RDS"
}
