# postiz.com stays on Cloudflare. Records are DNS-only (grey cloud), like today.

data "cloudflare_zone" "main" {
  filter = {
    name = var.cloudflare_zone_name
  }
}

locals {
  # ACM uses the same validation record for a name in every certificate,
  # so platform.postiz.com (ALB + CloudFront certs) yields one record.
  acm_validation_records = merge(
    {
      for dvo in aws_acm_certificate.alb.domain_validation_options : dvo.domain_name => {
        name  = dvo.resource_record_name
        type  = dvo.resource_record_type
        value = dvo.resource_record_value
      }
    },
    {
      for dvo in aws_acm_certificate.cloudfront.domain_validation_options : dvo.domain_name => {
        name  = dvo.resource_record_name
        type  = dvo.resource_record_type
        value = dvo.resource_record_value
      }
    },
  )

  # The Temporal UI's unlisted name (only when public) exists from day one. The
  # three live names only move when dns_cutover = true.
  public_records = merge(
    var.temporal_ui_public ? { (var.temporal_ui_domain) = aws_lb.main.dns_name } : {},
    var.dns_cutover ? {
      (var.api_domain)      = aws_lb.main.dns_name
      (var.mcp_domain)      = aws_lb.main.dns_name
      (var.frontend_domain) = aws_cloudfront_distribution.frontend.domain_name
    } : {},
  )
}

resource "cloudflare_dns_record" "acm_validation" {
  for_each = local.acm_validation_records

  zone_id = data.cloudflare_zone.main.id
  name    = trimsuffix(each.value.name, ".")
  type    = each.value.type
  content = trimsuffix(each.value.value, ".")
  ttl     = 1
  proxied = false
  comment = "ACM validation for ${each.key}, managed by postiz-aws"
}

resource "cloudflare_dns_record" "public" {
  for_each = local.public_records

  zone_id = data.cloudflare_zone.main.id
  name    = each.key
  type    = "CNAME"
  content = each.value
  ttl     = 60
  proxied = false
  comment = "Postiz on AWS, managed by postiz-aws"
}
