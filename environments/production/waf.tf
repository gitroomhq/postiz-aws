# AWS WAF in front of the ALB. Every rule starts in count mode: it records what it
# would have blocked and lets the request through. A rule only blocks once its
# name is in waf_blocking_rules, so each one is switched on (and back off) on its
# own, after its counts have been read.
#
# What WAF sees on an ALB: the whole request line and headers, but only the first
# 8 KB of a body (fixed). Larger bodies pass through uninspected past that point.
#
# The rules that look at the client address (ip-reputation, the two limits) only
# mean something for hosts that clients reach directly (api, mcp). platform comes
# through CloudFront and several internal apps through Cloudflare, so there the
# address is the edge's.

locals {
  waf_rules    = ["ip-reputation", "known-bad-inputs", "core-rules", "flood-limit", "login-limit"]
  waf_blocking = { for r in local.waf_rules : r => contains(var.waf_blocking_rules, r) }

  # Core rules that match legitimate traffic here (ALB access logs, 2026-11-12).
  # They keep counting even when core-rules blocks.
  waf_core_rules_count_only = [
    "SizeRestrictions_BODY",     # any body over 8 KB: media uploads, long posts, Intercom and Stripe webhooks
    "NoUserAgent_HEADER",        # about a quarter of the public API's requests carry no User-Agent
    "GenericRFI_QUERYARGUMENTS", # OAuth for MCP and CLI clients redirects to http://127.0.0.1:<port>
    "GenericRFI_BODY",           # the same loopback redirect URIs in /oauth/register and /oauth/token
    "SizeRestrictions_URIPATH",  # /auth/activate/<token> links are longer than 1,024 bytes
  ]

  # Requests per client address in 5 minutes. The busiest single address measured
  # was 17,260 on the public API, and 10 on the sign-in endpoints.
  waf_flood_limit = 20000
  waf_login_limit = 100

  # Credentials never reach the WAF logs or the sampled requests. API keys inside
  # a URL (/mcp/<key>) do, exactly as they already do in the ALB access logs.
  waf_secret_headers = ["authorization", "cookie", "auth"]
}

resource "aws_wafv2_web_acl" "alb" {
  count = var.waf_enabled ? 1 : 0

  name        = "${local.name}-alb"
  description = "Managed rules and rate limits for the public load balancer - count only unless listed in waf_blocking_rules"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  data_protection_config {
    data_protection {
      action = "SUBSTITUTION"
      field {
        field_type = "SINGLE_HEADER"
        field_keys = local.waf_secret_headers
      }
    }
  }

  # Addresses Amazon's threat intelligence lists as attacking or scanning
  rule {
    name     = "ip-reputation"
    priority = 10

    override_action {
      dynamic "count" {
        for_each = local.waf_blocking["ip-reputation"] ? [] : [1]
        content {}
      }
      dynamic "none" {
        for_each = local.waf_blocking["ip-reputation"] ? [1] : []
        content {}
      }
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  # Known exploit requests: Log4j, Java deserialization, the React server RCE
  rule {
    name     = "known-bad-inputs"
    priority = 20

    override_action {
      dynamic "count" {
        for_each = local.waf_blocking["known-bad-inputs"] ? [] : [1]
        content {}
      }
      dynamic "none" {
        for_each = local.waf_blocking["known-bad-inputs"] ? [1] : []
        content {}
      }
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # Generic web attacks: script and file-inclusion patterns, scanner user agents
  rule {
    name     = "core-rules"
    priority = 30

    override_action {
      dynamic "count" {
        for_each = local.waf_blocking["core-rules"] ? [] : [1]
        content {}
      }
      dynamic "none" {
        for_each = local.waf_blocking["core-rules"] ? [1] : []
        content {}
      }
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"

        dynamic "rule_action_override" {
          for_each = toset(local.waf_core_rules_count_only)
          content {
            name = rule_action_override.value
            action_to_use {
              count {}
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "core-rules"
      sampled_requests_enabled   = true
    }
  }

  # One address sending more than any client has been seen to send
  rule {
    name     = "flood-limit"
    priority = 40

    action {
      dynamic "count" {
        for_each = local.waf_blocking["flood-limit"] ? [] : [1]
        content {}
      }
      dynamic "block" {
        for_each = local.waf_blocking["flood-limit"] ? [1] : []
        content {}
      }
    }

    statement {
      rate_based_statement {
        limit                 = local.waf_flood_limit
        evaluation_window_sec = 300
        aggregate_key_type    = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "flood-limit"
      sampled_requests_enabled   = true
    }
  }

  # Password guessing and sign-up floods against the app's own sign-in endpoints
  rule {
    name     = "login-limit"
    priority = 50

    action {
      dynamic "count" {
        for_each = local.waf_blocking["login-limit"] ? [] : [1]
        content {}
      }
      dynamic "block" {
        for_each = local.waf_blocking["login-limit"] ? [1] : []
        content {}
      }
    }

    statement {
      rate_based_statement {
        limit                 = local.waf_login_limit
        evaluation_window_sec = 300
        aggregate_key_type    = "IP"

        scope_down_statement {
          and_statement {
            statement {
              byte_match_statement {
                positional_constraint = "EXACTLY"
                search_string         = "POST"
                field_to_match {
                  method {}
                }
                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
            statement {
              regex_match_statement {
                regex_string = "^/auth/(login|register|forgot|forgot-return)$"
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "login-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name}-alb"
    sampled_requests_enabled   = true
  }
}

# aws_lb.main has enable_waf_fail_open, so requests keep flowing if WAF cannot be reached
resource "aws_wafv2_web_acl_association" "alb" {
  count = var.waf_enabled ? 1 : 0

  resource_arn = aws_lb.main.arn
  web_acl_arn  = aws_wafv2_web_acl.alb[0].arn
}

# --- logs ------------------------------------------------------------------------------------

# Only requests a rule counted or blocked are logged; the name must start with aws-waf-logs-
resource "aws_cloudwatch_log_group" "waf" {
  count = var.waf_enabled ? 1 : 0

  name              = "aws-waf-logs-${local.name}"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "waf_logs" {
  count = var.waf_enabled ? 1 : 0

  statement {
    sid       = "WafLogDelivery"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.waf[0].arn}:*"]
    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.aws_account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:${var.region}:${var.aws_account_id}:*"]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "waf_logs" {
  count = var.waf_enabled ? 1 : 0

  policy_name     = "${local.name}-waf-logs"
  policy_document = data.aws_iam_policy_document.waf_logs[0].json
}

resource "aws_wafv2_web_acl_logging_configuration" "alb" {
  count = var.waf_enabled ? 1 : 0

  resource_arn            = aws_wafv2_web_acl.alb[0].arn
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]

  dynamic "redacted_fields" {
    for_each = toset(local.waf_secret_headers)
    content {
      single_header {
        name = redacted_fields.value
      }
    }
  }

  logging_filter {
    default_behavior = "DROP"

    filter {
      behavior    = "KEEP"
      requirement = "MEETS_ANY"

      condition {
        action_condition {
          action = "BLOCK"
        }
      }
      condition {
        action_condition {
          action = "COUNT"
        }
      }
      condition {
        action_condition {
          action = "EXCLUDED_AS_COUNT"
        }
      }
    }
  }

  depends_on = [aws_cloudwatch_log_resource_policy.waf_logs]
}

# --- alarm -----------------------------------------------------------------------------------

# While every rule counts, a single blocked request means the configuration is wrong
resource "aws_cloudwatch_metric_alarm" "waf_blocked" {
  count = var.waf_enabled && length(var.waf_blocking_rules) == 0 ? 1 : 0

  alarm_name          = "${local.name}-waf-blocked"
  alarm_description   = "The web ACL blocked a request although every rule is set to count only"
  namespace           = "AWS/WAFV2"
  metric_name         = "BlockedRequests"
  dimensions          = { WebACL = aws_wafv2_web_acl.alb[0].name, Region = var.region, Rule = "ALL" }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}
