# One public ALB for api, mcp, platform (behind CloudFront) and, with
# temporal_ui_public, the Temporal UI.

resource "aws_acm_certificate" "alb" {
  domain_name = var.api_domain
  # The Temporal UI is covered by the wildcard, not by its own name: certificate
  # transparency logs publish every name on a certificate, and it stays unlisted.
  subject_alternative_names = concat([var.mcp_domain, var.frontend_domain], var.temporal_ui_public ? ["*.${var.cloudflare_zone_name}"] : [])
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "alb" {
  certificate_arn = aws_acm_certificate.alb.arn
  depends_on      = [cloudflare_dns_record.acm_validation]
}

# --- access logs ------------------------------------------------------------------------

data "aws_elb_service_account" "this" {}

resource "aws_s3_bucket" "alb_logs" {
  bucket        = "${local.name}-alb-logs-${var.aws_account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = 30
    }
  }
}

data "aws_iam_policy_document" "alb_logs" {
  statement {
    sid       = "ElbLogDelivery"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.alb_logs.arn}/alb/AWSLogs/${var.aws_account_id}/*"]
    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.this.arn]
    }
  }
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.alb_logs.arn,
      "${aws_s3_bucket.alb_logs.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket     = aws_s3_bucket.alb_logs.id
  policy     = data.aws_iam_policy_document.alb_logs.json
  depends_on = [aws_s3_bucket_public_access_block.alb_logs]
}

# --- load balancer ------------------------------------------------------------------------

resource "aws_lb" "main" {
  name               = local.name
  load_balancer_type = "application"
  internal           = false
  subnets            = module.network.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]

  # uploads up to ~900 MB and MCP streams stay open a long time
  idle_timeout = 900
  # true would drop any header with an underscore; Railway passes them, and a
  # third-party webhook or API client silently losing one is hard to debug
  drop_invalid_header_fields = false
  enable_deletion_protection = true

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = "alb"
    enabled = true
  }

  depends_on = [aws_s3_bucket_policy.alb_logs]
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.alb.certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not found"
      status_code  = "404"
    }
  }
}

# --- target groups ---------------------------------------------------------------------------

locals {
  # host => target group settings. Bridge-mode services register instances on
  # dynamic ports, the awsvpc Temporal UI registers its task IP.
  alb_targets = merge({
    backend = {
      host         = var.api_domain
      port         = 8080
      target_type  = "instance"
      health_path  = "/"
      priority     = 10
      deregister_s = 120 # let in-flight uploads finish during deploys
    }
    mcp = {
      host         = var.mcp_domain
      port         = 8080
      target_type  = "instance"
      health_path  = "/"
      priority     = 20
      deregister_s = 120
    }
    frontend = {
      host         = var.frontend_domain
      port         = 4200
      target_type  = "instance"
      health_path  = "/favicon.ico"
      priority     = 30
      deregister_s = 30
    }
    }, var.temporal_ui_public ? {
    temporal-ui = {
      host         = var.temporal_ui_domain
      port         = 8081
      target_type  = "ip"
      health_path  = "/healthz"
      priority     = 40
      deregister_s = 15
    }
  } : {})
}

resource "aws_lb_target_group" "app" {
  for_each = local.alb_targets

  name                          = "${local.name}-${each.key}"
  port                          = each.value.port
  protocol                      = "HTTP"
  target_type                   = each.value.target_type
  vpc_id                        = module.network.vpc_id
  deregistration_delay          = each.value.deregister_s
  load_balancing_algorithm_type = "least_outstanding_requests"

  health_check {
    path                = each.value.health_path
    matcher             = "200-399"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener_rule" "app" {
  for_each = local.alb_targets

  listener_arn = aws_lb_listener.https.arn
  priority     = each.value.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app[each.key].arn
  }

  condition {
    host_header {
      values = [each.value.host]
    }
  }

  # optional allowlist for the Temporal UI
  dynamic "condition" {
    for_each = each.key == "temporal-ui" && length(var.temporal_ui_allowed_cidrs) > 0 ? [1] : []
    content {
      source_ip {
        values = var.temporal_ui_allowed_cidrs
      }
    }
  }
}

# --- maintenance mode -------------------------------------------------------------------
# maintenance_mode = true answers every request to api, mcp and platform with a 503
# (JSON for the API, a page for the app); stopped clients and webhooks such as
# Stripe retry later. Requests carrying X-Postiz-Bypass: <maintenance_bypass_token>
# still reach the services, so the cutover can be verified before going live.
# The Temporal UI stays reachable. Flipping it back is one apply, seconds.

resource "random_password" "maintenance_bypass" {
  length  = 32
  special = false
}

locals {
  maintenance_hosts = { backend = 1, mcp = 2, frontend = 3 }

  maintenance_json = jsonencode({
    error   = "maintenance"
    message = "Postiz is moving to new infrastructure and will be back shortly. Please retry in a few minutes."
  })

  maintenance_html = <<-EOT
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Postiz maintenance</title></head>
    <body style="margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#0e0e0e;color:#fff;font-family:system-ui,sans-serif;text-align:center">
    <div style="max-width:480px;padding:24px"><h1 style="font-size:28px">Postiz is getting an upgrade</h1>
    <p style="color:#bbb;line-height:1.5">We are moving to new infrastructure and will be back shortly. Scheduled posts are kept and go out when we are back.</p></div></body></html>
  EOT
}

resource "aws_lb_listener_rule" "maintenance_bypass" {
  for_each = var.maintenance_mode ? local.maintenance_hosts : {}

  listener_arn = aws_lb_listener.https.arn
  priority     = each.value

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app[each.key].arn
  }

  condition {
    host_header {
      values = [local.alb_targets[each.key].host]
    }
  }

  condition {
    http_header {
      http_header_name = "X-Postiz-Bypass"
      values           = [random_password.maintenance_bypass.result]
    }
  }
}

resource "aws_lb_listener_rule" "maintenance_api" {
  count = var.maintenance_mode ? 1 : 0

  listener_arn = aws_lb_listener.https.arn
  priority     = 5

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      status_code  = "503"
      message_body = local.maintenance_json
    }
  }

  condition {
    host_header {
      values = [var.api_domain, var.mcp_domain]
    }
  }
}

resource "aws_lb_listener_rule" "maintenance_app" {
  count = var.maintenance_mode ? 1 : 0

  listener_arn = aws_lb_listener.https.arn
  priority     = 6

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/html"
      status_code  = "503"
      message_body = local.maintenance_html
    }
  }

  condition {
    host_header {
      values = [var.frontend_domain]
    }
  }
}
