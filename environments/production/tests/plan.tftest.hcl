# Offline plan with mocked providers: catches broken references, type errors and
# for_each over unknown values without AWS or Cloudflare credentials.
#   terraform -chdir=environments/production init -backend=false
#   terraform -chdir=environments/production test

variables {
  aws_account_id     = "123456789012"
  temporal_ui_domain = "temporal-0123456789ab.postiz.com"
}

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-2a", "us-east-2b", "us-east-2c"] }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { insecure_value = "ami-0123456789abcdef0", value = "ami-0123456789abcdef0" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-2" }
  }
  mock_data "aws_elb_service_account" {
    defaults = { arn = "arn:aws:iam::033677994240:root" }
  }
  mock_data "aws_cloudfront_cache_policy" {
    defaults = { id = "658327ea-f89d-4fab-a63d-7e88639e58f6" }
  }
  mock_data "aws_cloudfront_origin_request_policy" {
    defaults = { id = "216adef6-5c7f-47e4-b989-5492eafa07d3" }
  }
  # the real provider knows domain_validation_options[*].domain_name at plan time
  mock_resource "aws_acm_certificate" {
    override_during = plan
    defaults = {
      arn = "arn:aws:acm:us-east-2:123456789012:certificate/00000000-0000-0000-0000-000000000000"
      domain_validation_options = [
        for d in ["api.postiz.com", "mcp.postiz.com", "platform.postiz.com", "*.postiz.com"] : {
          domain_name           = d
          resource_record_name  = "_abc.${trimprefix(d, "*.")}." # a wildcard validates on its parent
          resource_record_type  = "CNAME"
          resource_record_value = "_def.acm-validations.aws."
        }
      ]
    }
  }
}

mock_provider "aws" {
  alias = "us_east_1"
  mock_resource "aws_acm_certificate" {
    override_during = plan
    defaults = {
      arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000001"
      domain_validation_options = [{
        domain_name           = "platform.postiz.com"
        resource_record_name  = "_abc.platform.postiz.com."
        resource_record_type  = "CNAME"
        resource_record_value = "_def.acm-validations.aws."
      }]
    }
  }
}

mock_provider "cloudflare" {
  mock_data "cloudflare_zone" {
    defaults = { id = "0123456789abcdef0123456789abcdef" }
  }
}

# random stays real: it is local, and the generated passwords must pass AWS validation

run "before_cutover" {
  command = plan

  assert {
    condition     = keys(cloudflare_dns_record.public) == ["temporal-0123456789ab.postiz.com"]
    error_message = "before the cutover the only public record is the Temporal UI's"
  }

  assert {
    condition     = contains(aws_acm_certificate.alb.subject_alternative_names, "*.postiz.com") && !contains(aws_acm_certificate.alb.subject_alternative_names, "temporal-0123456789ab.postiz.com")
    error_message = "the Temporal UI is covered by the wildcard, its unlisted name must not be on the certificate (certificate transparency logs are public)"
  }

  assert {
    condition     = cloudflare_dns_record.acm_validation["*.postiz.com"].name == "_abc.postiz.com"
    error_message = "the wildcard's validation record lives on the zone itself"
  }

  assert {
    condition     = length(aws_lb_listener_rule.app) == 4 && length(aws_vpc_security_group_ingress_rule.temporal_ui_from_alb) == 1
    error_message = "the public Temporal UI gets a load balancer rule and is reachable from the load balancer"
  }

  assert {
    condition     = alltrue([for k, m in module.postiz : m.service_name != null])
    error_message = "every Postiz service should be planned"
  }
}

run "after_cutover" {
  command = plan

  variables {
    apps_enabled    = true
    workers_enabled = true
    dns_cutover     = true
    alert_emails    = ["ops@example.com"]
  }

  assert {
    condition     = length(cloudflare_dns_record.public) == 4
    error_message = "api, mcp and platform should point at AWS after the cutover, next to the Temporal UI"
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.service_down) == 6
    error_message = "workers and the four Temporal roles should be watched"
  }

  assert {
    condition     = length(aws_sns_topic_subscription.email) == 1
    error_message = "one subscription per alert email"
  }
}

run "cutover_window" {
  command = plan

  variables {
    apps_enabled     = true
    dns_cutover      = true
    maintenance_mode = true
  }

  assert {
    condition     = length(aws_lb_listener_rule.maintenance_bypass) == 3 && length(aws_lb_listener_rule.maintenance_api) == 1 && length(aws_lb_listener_rule.maintenance_app) == 1
    error_message = "maintenance mode should add the 503 rules and a bypass rule for api, mcp and platform"
  }

  assert {
    condition     = length(aws_lb_listener_rule.app) == 4
    error_message = "the normal routing rules stay in place underneath, the Temporal UI's included"
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.service_down) == 4
    error_message = "workers are still off behind the maintenance page, only Temporal is watched"
  }
}

run "temporal_ui_allowlist" {
  command = plan

  variables {
    temporal_ui_allowed_cidrs = ["203.0.113.0/24"]
  }

  assert {
    condition     = anytrue([for c in aws_lb_listener_rule.app["temporal-ui"].condition : length(c.source_ip) > 0])
    error_message = "temporal_ui_allowed_cidrs should add a source IP condition to the Temporal UI rule"
  }
}

run "temporal_ui_private" {
  command = plan

  variables {
    temporal_ui_public = false
    temporal_ui_domain = null
  }

  assert {
    condition     = length(cloudflare_dns_record.public) == 0 && length(aws_lb_listener_rule.app) == 3
    error_message = "a private Temporal UI has no public record and no load balancer rule"
  }

  assert {
    condition     = !contains(aws_acm_certificate.alb.subject_alternative_names, "*.postiz.com") && length(aws_vpc_security_group_ingress_rule.temporal_ui_from_alb) == 0
    error_message = "a private Temporal UI needs no wildcard and is not reachable from the load balancer"
  }
}

run "temporal_ui_public_needs_a_domain" {
  command = plan

  variables {
    temporal_ui_domain = null
  }

  expect_failures = [var.temporal_ui_domain]
}
