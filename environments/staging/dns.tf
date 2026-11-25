# getpostiz.com is on Cloudflare. Records are DNS-only (grey cloud): Cloudflare's
# proxy would end TLS itself and could not pass a client certificate on.
#
# Before the first apply, delete the old platform and api records of the zone by
# hand (proxied CNAMEs to a Railway app that no longer exists): a name can only
# have one CNAME, and those would make the records below fail.

data "cloudflare_zone" "main" {
  filter = {
    name = var.cloudflare_zone_name
  }
}

locals {
  acm_validation_records = {
    for dvo in aws_acm_certificate.alb.domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }

  public_names = toset([var.api_domain, var.mcp_domain, var.frontend_domain])
}

resource "cloudflare_dns_record" "acm_validation" {
  for_each = local.acm_validation_records

  zone_id = data.cloudflare_zone.main.id
  name    = trimsuffix(each.value.name, ".")
  type    = each.value.type
  content = trimsuffix(each.value.value, ".")
  ttl     = 1
  proxied = false
  comment = "ACM validation for ${each.key}, managed by postiz-aws (staging)"
}

resource "cloudflare_dns_record" "public" {
  for_each = local.public_names

  zone_id = data.cloudflare_zone.main.id
  name    = each.key
  type    = "CNAME"
  content = aws_lb.main.dns_name
  ttl     = 60
  proxied = false
  comment = "Postiz staging, managed by postiz-aws"
}
