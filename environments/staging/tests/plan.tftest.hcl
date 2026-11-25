# Offline plan with mocked providers: catches broken references, type errors and
# for_each over unknown values without AWS or Cloudflare credentials.
#   terraform -chdir=environments/staging init -backend=false
#   terraform -chdir=environments/staging test

variables {
  aws_account_id = "210987654321"
  client_ca_file = "tests/test-ca.pem"
}

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-2a", "us-east-2b", "us-east-2c"] }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "210987654321" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-2" }
  }
  mock_data "aws_elb_service_account" {
    defaults = { arn = "arn:aws:iam::033677994240:root" }
  }
  # known at plan time, so the services' target groups can be checked
  mock_resource "aws_lb_target_group" {
    override_during = plan
    defaults        = { arn = "arn:aws:elasticloadbalancing:us-east-2:210987654321:targetgroup/postiz-staging-app/0123456789abcdef" }
  }
  mock_resource "aws_acm_certificate" {
    override_during = plan
    defaults = {
      arn = "arn:aws:acm:us-east-2:210987654321:certificate/00000000-0000-0000-0000-000000000000"
      domain_validation_options = [
        for d in ["api.getpostiz.com", "mcp.getpostiz.com", "platform.getpostiz.com"] : {
          domain_name           = d
          resource_record_name  = "_abc.${d}."
          resource_record_type  = "CNAME"
          resource_record_value = "_def.acm-validations.aws."
        }
      ]
    }
  }
}

mock_provider "cloudflare" {
  mock_data "cloudflare_zone" {
    defaults = { id = "0123456789abcdef0123456789abcdef" }
  }
}

run "new_environment" {
  command = plan

  # terraform.tfvars has the apps on now; a new environment starts with them off
  variables {
    apps_enabled = false
  }

  assert {
    condition     = length(data.aws_ecr_image.app) == 0 && alltrue([for k, m in module.postiz : m.service_name != null])
    error_message = "with the apps off (a new environment), the plan needs no image and still plans every service"
  }

  assert {
    condition     = aws_lb_listener.https.mutual_authentication[0].mode == "verify"
    error_message = "port 443 must ask every connection for a client certificate"
  }

  assert {
    condition     = keys(aws_vpc_security_group_ingress_rule.alb_https) == ["0.0.0.0/0"]
    error_message = "with client certificates, the certificate is the check, not the address"
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.alb_stripe) == 15 && alltrue([for r in aws_vpc_security_group_ingress_rule.alb_stripe : r.from_port == 8443 && endswith(r.cidr_ipv4, "/32")])
    error_message = "port 8443 is open to Stripe's webhook addresses only"
  }

  assert {
    condition     = length(aws_lb_listener_rule.stripe.condition) == 3
    error_message = "the Stripe door forwards only POST /stripe on the API's name"
  }

  assert {
    condition     = toset(keys(cloudflare_dns_record.public)) == toset(["api.getpostiz.com", "mcp.getpostiz.com", "platform.getpostiz.com"])
    error_message = "platform, api and mcp point at the staging load balancer"
  }

  assert {
    condition     = alltrue([for r in cloudflare_dns_record.public : r.proxied == false])
    error_message = "Cloudflare's proxy would end TLS and drop the client certificate"
  }

  assert {
    condition     = contains([for s in aws_ecs_cluster_capacity_providers.main.default_capacity_provider_strategy : s.capacity_provider], "FARGATE_SPOT")
    error_message = "staging runs on Fargate Spot by default"
  }

  assert {
    condition     = !contains(flatten(values(local.app_env_keys)), "DATABASE_URL") && !contains(flatten(values(local.app_env_keys)), "MCP_ONLY") && !contains(flatten(values(local.app_env_keys)), "EXCLUDE_QUEUE")
    error_message = "DATABASE_URL comes from the managed secret, and staging runs no MCP-only or second worker"
  }

  assert {
    condition     = aws_iam_role.deploy.name == "postiz-staging-github-deploy"
    error_message = "the deploy role keeps the name the workflow's variable is set to"
  }
}

run "apps_on" {
  command = plan

  variables {
    apps_enabled = true
    alert_emails = ["ops@example.com"]
  }

  assert {
    condition     = length(data.aws_ecr_image.app) == 3
    error_message = "with the apps on, the plan checks that each app's release tag exists"
  }

  assert {
    condition     = length(aws_sns_topic_subscription.email) == 1 && length(aws_sns_topic_subscription.security_email) == 1
    error_message = "one subscription per alert email, on both topics"
  }
}

run "pentest_without_certificates" {
  command = plan

  variables {
    client_certificates_required = false
    open_to_cidrs                = ["198.51.100.7/32"]
  }

  assert {
    condition     = aws_lb_listener.https.mutual_authentication[0].mode == "off" && aws_lb_trust_store.clients.name == "postiz-staging-clients"
    error_message = "without certificates no check, but the trust store and its revocations stay for when they come back"
  }

  assert {
    condition     = keys(aws_vpc_security_group_ingress_rule.alb_https) == ["198.51.100.7/32"]
    error_message = "without certificates, only the listed addresses reach port 443"
  }
}

run "never_open_to_everyone" {
  command = plan

  variables {
    client_certificates_required = false
    open_to_cidrs                = []
  }

  expect_failures = [aws_lb.main]
}

run "never_a_wide_allowlist" {
  command = plan

  variables {
    client_certificates_required = false
    open_to_cidrs                = ["0.0.0.0/1", "128.0.0.0/1"]
  }

  expect_failures = [var.open_to_cidrs]
}
