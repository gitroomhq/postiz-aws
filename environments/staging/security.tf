# Finding out that someone got in, in the staging account. Nothing here blocks
# anything: the client certificates (alb.tf), the security groups and the
# organization's policy on this account do that. It tells, on a topic of its own:
#
#   GuardDuty        AWS's threat detection: API calls, DNS lookups and network
#                    flows against known attack patterns, the processes inside
#                    every Fargate task (its agent as a sidecar: reverse shells,
#                    crypto miners), sign-ins on the database.
#   audit-trail.tf   Every API call, kept for over a year, and an alert on the
#                    calls that open a way in or hide one.
#   Budget, cost     A break-in that runs machines shows on the bill first.
#
# During a pentest these are expected to fire: compare them with the report, to
# learn what would have been noticed. What none of it sees: a break-in through
# Postiz itself that stays within what the app's own credentials allow.

resource "aws_sns_topic" "security" {
  name         = "${local.name}-security"
  display_name = "${title(var.project)} STAGING SECURITY"
}

resource "aws_sns_topic_subscription" "security_email" {
  count     = nonsensitive(length(var.alert_emails))
  topic_arn = aws_sns_topic.security.arn
  protocol  = "email"
  endpoint  = var.alert_emails[count.index]
}

data "aws_iam_policy_document" "security_topic" {
  statement {
    sid       = "ThisAccount"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.security.arn]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceOwner"
      values   = [var.aws_account_id]
    }
  }

  statement {
    sid       = "AlarmsOfThisAccount"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.security.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.aws_account_id]
    }
  }

  statement {
    sid       = "CostAlerts"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.security.arn]
    principals {
      type        = "Service"
      identifiers = ["costalerts.amazonaws.com", "budgets.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.aws_account_id]
    }
  }
}

resource "aws_sns_topic_policy" "security" {
  arn    = aws_sns_topic.security.arn
  policy = data.aws_iam_policy_document.security_topic.json
}

# The event rules publish with this role, not through the topic's policy
data "aws_iam_policy_document" "security_events_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.aws_account_id]
    }
  }
}

data "aws_iam_policy_document" "security_events" {
  statement {
    sid       = "PublishAlerts"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.security.arn]
  }
}

resource "aws_iam_role" "security_events" {
  name               = "${local.name}-security-events"
  description        = "EventBridge: publishes the security alerts of ${local.name}"
  assume_role_policy = data.aws_iam_policy_document.security_events_trust.json
}

resource "aws_iam_role_policy" "security_events" {
  name   = "alerts"
  role   = aws_iam_role.security_events.id
  policy = data.aws_iam_policy_document.security_events.json
}

# --- GuardDuty -------------------------------------------------------------------------------
# This Region only: the policy on the staging account (docs/staging.md) denies
# every other Region, so nothing can run anywhere else to be watched.

module "guardduty" {
  source = "../../modules/guardduty"

  name = local.name
  features = {
    S3_DATA_EVENTS         = { status = "ENABLED" }
    EBS_MALWARE_PROTECTION = { status = "DISABLED" } # no EBS volumes: Fargate only
    LAMBDA_NETWORK_LOGS    = { status = "DISABLED" } # no Lambda functions
    EKS_AUDIT_LOGS         = { status = "DISABLED" }
    RDS_LOGIN_EVENTS = {
      status     = "ENABLED"
      additional = { RDS_DATA_RISK = "ENABLED" }
    }
    # The agent joins every task as a sidecar (aws-guardduty-agent-*) when the
    # task starts, taking at most 128 MiB of the task's memory.
    RUNTIME_MONITORING = {
      status = var.guardduty_runtime_monitoring ? "ENABLED" : "DISABLED"
      additional = {
        ECS_FARGATE_AGENT_MANAGEMENT = var.guardduty_runtime_monitoring ? "ENABLED" : "DISABLED"
        EC2_AGENT_MANAGEMENT         = "DISABLED"
        EKS_ADDON_MANAGEMENT         = "DISABLED"
      }
    }
  }
}

# Severity 4 and up (medium, high, critical); under 4 is the internet's background noise
resource "aws_cloudwatch_event_rule" "guardduty_finding" {
  name        = "${local.name}-security-guardduty-finding"
  description = "GuardDuty findings of medium severity and above"
  event_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
    detail        = { severity = [{ numeric = [">=", 4] }] }
  })
}

locals {
  # One quoted line per line of the email; only values that cannot hold a double quote
  guardduty_alert_lines = [
    "SECURITY ${local.name}: GuardDuty finding, severity <severity> of 10",
    "(4 to 6.9 medium, 7 to 8.9 high, 9 and up critical)",
    "What: <type>",
    "On: <resource>, in <region>",
    "Seen <count> times, first <first>, last <last>",
    "Open it: https://<region>.console.aws.amazon.com/guardduty/home?region=<region>#/findings?fId=<id>",
    "Staging: expected during a pentest, compare with the testers' notes. Otherwise see docs/staging.md, If staging is broken into.",
  ]
}

resource "aws_cloudwatch_event_target" "guardduty_finding" {
  rule      = aws_cloudwatch_event_rule.guardduty_finding.name
  target_id = "security-topic"
  arn       = aws_sns_topic.security.arn
  role_arn  = aws_iam_role.security_events.arn

  input_transformer {
    input_paths = {
      severity = "$.detail.severity"
      type     = "$.detail.type"
      resource = "$.detail.resource.resourceType"
      region   = "$.detail.region"
      count    = "$.detail.service.count"
      first    = "$.detail.service.eventFirstSeen"
      last     = "$.detail.service.eventLastSeen"
      id       = "$.detail.id"
    }
    input_template = join("\n", [for line in local.guardduty_alert_lines : "\"${line}\""])
  }
}

# --- the bill ----------------------------------------------------------------------------------

resource "aws_budgets_budget" "monthly" {
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.security.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.security.arn]
  }

  depends_on = [aws_sns_topic_policy.security]
}

# Per AWS service, against that service's own history; one monitor of this kind per account
resource "aws_ce_anomaly_monitor" "services" {
  name              = "${local.name}-services"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

resource "aws_ce_anomaly_subscription" "security" {
  name             = "${local.name}-cost-anomaly"
  frequency        = "IMMEDIATE"
  monitor_arn_list = [aws_ce_anomaly_monitor.services.arn]

  subscriber {
    type    = "SNS"
    address = aws_sns_topic.security.arn
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.cost_anomaly_threshold_usd)]
    }
  }

  depends_on = [aws_sns_topic_policy.security]
}
