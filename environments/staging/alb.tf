# One public load balancer, two doors:
#   443   platform, api and mcp. With client_certificates_required, mutual TLS in
#         verify mode: the load balancer ends every connection that does not
#         present a certificate signed by the staging CA (client_ca_file,
#         scripts/staging-certs.sh), before any request reaches the app. The app
#         behind it behaves as production's does, which has no such door.
#   8443  Stripe's webhooks only: no certificate (Stripe has none to give), only
#         Stripe's addresses (network.tf), only POST /stripe on the API's name;
#         the app still checks Stripe's signature.
# No CloudFront in front of the frontend, unlike production: it cannot present a
# client certificate to the load balancer.

resource "aws_acm_certificate" "alb" {
  domain_name               = var.api_domain
  subject_alternative_names = [var.mcp_domain, var.frontend_domain]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "alb" {
  certificate_arn = aws_acm_certificate.alb.arn
  depends_on      = [cloudflare_dns_record.acm_validation]
}

# --- logs: every request, and every TLS connection with its client certificate ---------
# The connection log names the certificate (subject, serial) of each connection and
# why one was refused: who was in, during a pentest or after a lost laptop.

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
      days = 90
    }
  }
}

data "aws_iam_policy_document" "alb_logs" {
  statement {
    sid       = "ElbLogDelivery"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.alb_logs.arn}/*/AWSLogs/${var.aws_account_id}/*"]
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

# --- the client certificate authority ------------------------------------------------------
# Only the CA's certificate is here (public by nature, committed as
# client_ca_file). Its private key is in Secrets Manager under
# postiz/staging-admin/client-ca, which no task can read; scripts/staging-certs.sh
# issues and revokes certificates with it and uploads the revocation list to this
# bucket (revocations are the script's, not Terraform's).

resource "aws_s3_bucket" "trust_store" {
  bucket        = "${local.name}-trust-store-${var.aws_account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "trust_store" {
  bucket = aws_s3_bucket.trust_store.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "trust_store" {
  bucket                  = aws_s3_bucket.trust_store.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "trust_store" {
  bucket = aws_s3_bucket.trust_store.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# the trust store names the object's version, so a new CA file reaches it
resource "aws_s3_bucket_versioning" "trust_store" {
  bucket = aws_s3_bucket.trust_store.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_object" "client_ca" {
  count = var.client_certificates_required ? 1 : 0

  bucket       = aws_s3_bucket.trust_store.id
  key          = "client-ca.pem"
  source       = "${path.module}/${var.client_ca_file}"
  etag         = fileexists("${path.module}/${var.client_ca_file}") ? filemd5("${path.module}/${var.client_ca_file}") : null
  content_type = "application/x-pem-file"

  depends_on = [aws_s3_bucket_versioning.trust_store]

  lifecycle {
    precondition {
      condition     = fileexists("${path.module}/${var.client_ca_file}")
      error_message = "No client CA in environments/staging/${var.client_ca_file}: run scripts/staging-certs.sh init and commit the file it writes (docs/staging.md)."
    }
  }
}

resource "aws_lb_trust_store" "clients" {
  count = var.client_certificates_required ? 1 : 0

  name                                     = "${local.name}-clients"
  ca_certificates_bundle_s3_bucket         = aws_s3_bucket.trust_store.id
  ca_certificates_bundle_s3_key            = aws_s3_object.client_ca[0].key
  ca_certificates_bundle_s3_object_version = aws_s3_object.client_ca[0].version_id
}

# --- load balancer ------------------------------------------------------------------------

resource "aws_lb" "main" {
  name               = local.name
  load_balancer_type = "application"
  internal           = false
  subnets            = module.network.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]

  # as in production: long uploads and MCP streams, underscore headers kept
  idle_timeout               = 900
  drop_invalid_header_fields = false
  enable_deletion_protection = false

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = "alb"
    enabled = true
  }

  connection_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = "connections"
    enabled = true
  }

  depends_on = [aws_s3_bucket_policy.alb_logs]

  lifecycle {
    precondition {
      condition     = var.client_certificates_required || length(var.open_to_cidrs) > 0
      error_message = "Without client certificates, open_to_cidrs must name who may connect."
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.alb.certificate_arn

  mutual_authentication {
    mode                             = var.client_certificates_required ? "verify" : "off"
    trust_store_arn                  = var.client_certificates_required ? aws_lb_trust_store.clients[0].arn : null
    ignore_client_certificate_expiry = var.client_certificates_required ? false : null
    # browsers then offer only certificates of this CA
    advertise_trust_store_ca_names = var.client_certificates_required ? "on" : null
  }

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not found"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener" "stripe" {
  load_balancer_arn = aws_lb.main.arn
  port              = 8443
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
  alb_targets = {
    backend = {
      hosts        = [var.api_domain, var.mcp_domain]
      port         = 8080
      health_path  = "/"
      priority     = 10
      deregister_s = 60
    }
    frontend = {
      hosts        = [var.frontend_domain]
      port         = 4200
      health_path  = "/favicon.ico"
      priority     = 20
      deregister_s = 30
    }
  }
}

resource "aws_lb_target_group" "app" {
  for_each = local.alb_targets

  name                          = "${local.name}-${each.key}"
  port                          = each.value.port
  protocol                      = "HTTP"
  target_type                   = "ip"
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
      values = each.value.hosts
    }
  }
}

resource "aws_lb_listener_rule" "stripe" {
  listener_arn = aws_lb_listener.stripe.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app["backend"].arn
  }

  condition {
    host_header {
      values = [var.api_domain]
    }
  }

  # apps/backend/src/api/routes/stripe.controller.ts: @Controller('/stripe'), @Post('/')
  condition {
    path_pattern {
      values = ["/stripe", "/stripe/"]
    }
  }

  condition {
    http_request_method {
      values = ["POST"]
    }
  }
}

# The target group each service uses, read through its rule: ECS refuses a target
# group that is not on a load balancer yet.
locals {
  alb_target_group_arns = {
    for k, rule in aws_lb_listener_rule.app : k => one([for a in rule.action : a.target_group_arn if a.type == "forward"])
  }
}
