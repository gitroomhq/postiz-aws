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
  # known at plan time, so the services' target groups can be checked
  mock_resource "aws_lb_target_group" {
    override_during = plan
    defaults        = { arn = "arn:aws:elasticloadbalancing:us-east-2:123456789012:targetgroup/postiz-production-app/0123456789abcdef" }
  }
  # known at plan time (the instance exists), so the team's database tunnel can be checked
  mock_resource "aws_db_instance" {
    override_during = plan
    defaults        = { address = "postiz-production-main.abcdefghijkl.us-east-2.rds.amazonaws.com", port = 5432 }
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

  # terraform.tfvars holds the live switches, which are past the cutover now
  variables {
    dns_cutover = false
  }

  assert {
    condition     = keys(cloudflare_dns_record.public) == ["temporal-0123456789ab.postiz.com"]
    error_message = "before the cutover the only public record is the Temporal UI's"
  }

  assert {
    condition     = aws_route53_zone.api_inside_vpc.name == "api.postiz.com" && aws_route53_record.api_inside_vpc.name == "api.postiz.com"
    error_message = "inside the VPC the API's public name must lead to this stack before the cutover too"
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

  assert {
    condition     = length(data.aws_ecr_image.app) == 3
    error_message = "with the apps on, the plan checks that each app's release tag exists"
  }
}

run "apps_off" {
  command = plan

  variables {
    apps_enabled = false
  }

  assert {
    condition     = length(data.aws_ecr_image.app) == 0
    error_message = "with the apps off (a new environment), the plan needs no image"
  }
}

run "cutover_window" {
  command = plan

  variables {
    apps_enabled     = true
    workers_enabled  = false
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

run "temporal_ui_google_login" {
  command = plan

  variables {
    temporal_ui_google_client_id     = "1234567890-abc.apps.googleusercontent.com"
    temporal_ui_google_client_secret = "test-secret"
  }

  assert {
    condition     = [for a in aws_lb_listener_rule.app["temporal-ui"].action : a.type] == ["authenticate-oidc", "forward"]
    error_message = "the Temporal UI rule sends people to Google's sign-in before the UI"
  }

  assert {
    condition     = aws_lb_listener_rule.app["temporal-ui"].action[0].authenticate_oidc[0].authentication_request_extra_params["hd"] == "postiz.com"
    error_message = "Google's sign-in page should offer the postiz.com account"
  }

  assert {
    condition     = alltrue([for k, r in aws_lb_listener_rule.app : length(r.action) == 1 if k != "temporal-ui"])
    error_message = "api, mcp and platform get no sign-in step"
  }

  assert {
    condition     = alltrue([for k, tg in aws_lb_target_group.app : local.alb_target_group_arns[k] == tg.arn])
    error_message = "each service takes its rule's forward target group, not the sign-in step's (which has none)"
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.alb_to_idp) == 1 && aws_vpc_security_group_egress_rule.alb_to_idp[0].from_port == 443
    error_message = "the load balancer needs HTTPS out to reach Google's token and user info endpoints"
  }
}

# CI passes an empty string for a secret that is not set
run "temporal_ui_google_login_unset_in_ci" {
  command = plan

  variables {
    temporal_ui_google_client_id     = ""
    temporal_ui_google_client_secret = ""
  }

  assert {
    condition     = length(aws_lb_listener_rule.app["temporal-ui"].action) == 1 && length(aws_vpc_security_group_egress_rule.alb_to_idp) == 0
    error_message = "without a Google client the Temporal UI keeps basic auth only and the load balancer gets no way out"
  }
}

run "temporal_ui_google_login_needs_the_secret" {
  command = plan

  variables {
    temporal_ui_google_client_id = "1234567890-abc.apps.googleusercontent.com"
    # CI exports TF_VAR_temporal_ui_google_client_secret; this run needs it unset
    temporal_ui_google_client_secret = ""
  }

  expect_failures = [var.temporal_ui_google_client_secret]
}

run "temporal_ui_private" {
  command = plan

  variables {
    temporal_ui_public = false
    temporal_ui_domain = null
    dns_cutover        = false
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

run "team_database_access" {
  command = plan

  assert {
    condition     = aws_iam_role_policy.team_db_query.role == "postiz-team-readonly"
    error_message = "the team's read-only role gets CloudShell inside the VPC and the readonly database sign-in"
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.db_readers_postgres.from_port == 5432 && aws_vpc_security_group_egress_rule.db_readers_postgres.to_port == 5432
    error_message = "the team's CloudShell environments reach PostgreSQL and nothing else"
  }
}

run "ses" {
  command = plan

  assert {
    condition     = aws_sesv2_email_identity.domain.email_identity == "postiz.com" && length(cloudflare_dns_record.ses_dkim) == 3
    error_message = "SES sends as the postiz.com domain, signed with Easy DKIM (three CNAMEs)"
  }

  assert {
    condition     = aws_sesv2_email_identity_mail_from_attributes.domain.mail_from_domain == "ses-mail.postiz.com" && cloudflare_dns_record.ses_mail_from_mx.content == "feedback-smtp.us-east-2.amazonses.com"
    error_message = "the MAIL FROM is its own subdomain (send.postiz.com is Resend's) with an MX in the sending region"
  }

  assert {
    condition     = aws_sesv2_dedicated_ip_pool.main.scaling_mode == "MANAGED" && aws_sesv2_configuration_set.main.delivery_options[0].sending_pool_name == "postiz-production"
    error_message = "mail goes out through the managed dedicated IP pool, set on the identity's default configuration set"
  }
}

run "ses_sending_enabled" {
  command = plan

  variables {
    ses_sending_enabled = true
  }

  assert {
    condition     = length(module.postiz) == 5
    error_message = "switching EMAIL_PROVIDER to ses still plans every Postiz service"
  }
}

run "team_tunnels" {
  command = plan

  variables {
    apps_enabled = true
  }

  assert {
    condition = alltrue([
      for d in aws_ssm_document.team_tunnel :
      startswith(d.name, "postiz-team-") &&
      d.document_type == "Session" &&
      jsondecode(d.content).sessionType == "Port" &&
      jsondecode(d.content).properties.type == "LocalPortForwarding" &&
      keys(jsondecode(d.content).parameters) == ["localPortNumber"]
    ])
    error_message = "every team tunnel is named postiz-team-* (the only documents bootstrap/ lets the team use) and forwards to a host and port fixed in the document: the local port is its only parameter"
  }

  assert {
    condition = (
      jsondecode(aws_ssm_document.team_tunnel["temporal-readonly"].content).properties.host == "temporal-readonly.postiz.internal" &&
      jsondecode(aws_ssm_document.team_tunnel["temporal-readonly"].content).properties.portNumber == "7233"
    )
    error_message = "the Temporal tunnel reaches the read-only proxy, never the frontend"
  }

  assert {
    condition = (
      jsondecode(aws_ssm_document.team_tunnel["postgres-readonly"].content).properties.host == "postiz-production-main.abcdefghijkl.us-east-2.rds.amazonaws.com" &&
      jsondecode(aws_ssm_document.team_tunnel["postgres-readonly"].content).properties.portNumber == "5432"
    )
    error_message = "the database tunnel reaches the main RDS instance's PostgreSQL port and nothing else"
  }

  assert {
    condition     = keys(aws_ssm_document.team_tunnel) == ["postgres-readonly", "temporal-readonly"]
    error_message = "a new team tunnel needs a review: the team's role can open every document in team-tunnels.tf"
  }

  assert {
    condition = alltrue([
      for p in local.temporal_readonly_paths : can(regex(
        "^/(temporal\\.api\\.(workflowservice\\.v1\\.WorkflowService|operatorservice\\.v1\\.OperatorService)/(List|Describe|Get|Count|Scan)[A-Za-z]+|temporal\\.api\\.workflowservice\\.v1\\.WorkflowService/(QueryWorkflow|PollWorkflowExecutionUpdate)|grpc\\.health\\.v1\\.Health/Check)$",
        p
      ))
    ])
    error_message = "the read-only proxy may pass only read calls (List, Describe, Get, Count, Scan, QueryWorkflow, PollWorkflowExecutionUpdate, health)"
  }

  assert {
    condition     = !anytrue([for p in local.temporal_readonly_paths : can(regex("TaskQueue$|AdminService", p)) && !can(regex("/(Describe|ListTaskQueuePartitions)", p))])
    error_message = "no worker polls (Poll*TaskQueue would take tasks from real workers) and nothing from AdminService"
  }

  assert {
    condition     = module.temporal_readonly.service_name == "temporal-readonly"
    error_message = "the read-only proxy runs as its own service"
  }
}

run "fargate_for_other_apps" {
  command = plan

  assert {
    condition     = contains(module.ecs_cluster.capacity_providers, "FARGATE") && module.ecs_cluster.capacity_provider_name == "postiz-production-ec2"
    error_message = "the cluster offers FARGATE to other apps while Postiz keeps the EC2 provider as the default"
  }

  assert {
    condition = toset(one([for st in data.aws_iam_policy_document.deploy.statement : st.resources if st.sid == "RollServices"])) == toset([
      for s in ["backend", "frontend", "mcp", "worker", "worker-2"] : "arn:aws:ecs:us-east-2:123456789012:service/postiz-production/${s}"
    ])
    error_message = "the Postiz deploy role restarts only the Postiz services, not other apps in the cluster"
  }
}

run "waf_counts_only" {
  command = plan

  variables {
    waf_enabled        = true
    waf_blocking_rules = []
  }

  assert {
    condition     = length(aws_wafv2_web_acl_association.alb) == 1 && aws_lb.main.enable_waf_fail_open
    error_message = "the web ACL is attached, and the load balancer keeps routing if WAF cannot be reached"
  }

  assert {
    condition     = length(aws_wafv2_web_acl.alb[0].default_action[0].allow) == 1 && length(aws_wafv2_web_acl.alb[0].rule) == 5
    error_message = "the web ACL allows by default and carries the five rules"
  }

  assert {
    condition = alltrue([
      for r in aws_wafv2_web_acl.alb[0].rule :
      alltrue([for a in r.action : length(a.block) == 0 && length(a.count) == 1]) &&
      alltrue([for o in r.override_action : length(o.none) == 0 && length(o.count) == 1])
    ])
    error_message = "with waf_blocking_rules empty, every rule counts and none blocks"
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.waf_blocked) == 1
    error_message = "while everything counts, any blocked request raises an alarm"
  }

  assert {
    condition     = aws_cloudwatch_log_group.waf[0].name == "aws-waf-logs-postiz-production" && length(aws_wafv2_web_acl_logging_configuration.alb[0].redacted_fields) == 3
    error_message = "WAF logs go to an aws-waf-logs- group with the credential headers redacted"
  }
}

run "waf_one_rule_blocking" {
  command = plan

  variables {
    waf_enabled        = true
    waf_blocking_rules = ["login-limit", "core-rules"]
  }

  assert {
    condition = alltrue([
      for r in aws_wafv2_web_acl.alb[0].rule :
      alltrue([for a in r.action : length(a.block) == (r.name == "login-limit" ? 1 : 0)]) &&
      alltrue([for o in r.override_action : length(o.none) == (r.name == "core-rules" ? 1 : 0)])
    ])
    error_message = "only the rules named in waf_blocking_rules block"
  }

  assert {
    condition = alltrue([
      for r in aws_wafv2_web_acl.alb[0].rule :
      length(r.statement[0].managed_rule_group_statement[0].rule_action_override) == 5
      if r.name == "core-rules"
    ])
    error_message = "the core rules that match real traffic keep counting when core-rules blocks"
  }
}

run "waf_off" {
  command = plan

  variables {
    waf_enabled = false
  }

  assert {
    condition     = length(aws_wafv2_web_acl.alb) == 0 && length(aws_wafv2_web_acl_association.alb) == 0 && length(aws_cloudwatch_log_group.waf) == 0
    error_message = "without waf_enabled there is no web ACL, association or log group"
  }
}

run "waf_unknown_rule" {
  command = plan

  variables {
    waf_enabled        = true
    waf_blocking_rules = ["everything"]
  }

  expect_failures = [var.waf_blocking_rules]
}
