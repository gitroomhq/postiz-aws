# Finding out that someone got in. Nothing in this file or in audit-trail.tf
# blocks anything (the security groups, the web ACL in waf.tf and the deploy
# gate do that): it tells, on one topic of its own, apart from the "is it up"
# alarms of monitoring.tf.
#
#   GuardDuty        AWS's threat detection. Reads the account's API calls, DNS
#                    lookups and network flows for known attack patterns, watches
#                    the processes on the hosts (crypto miners, reverse shells) and
#                    the sign-ins and reads on the databases.
#   audit-trail.tf   The record of every API call, kept for over a year, and an
#                    alert on the calls that open a way in or hide one.
#   Cost anomaly     Someone running machines on this account shows on the bill
#                    before anywhere else.
#
# What none of it sees: a break-in through Postiz itself (a stolen admin login,
# an API abused within its limits), and someone reading the database slowly with
# an app's own credentials from the app's own container. Both look like the app.

# --- where the alerts go ---------------------------------------------------------------------

resource "aws_sns_topic" "security" {
  name = "${local.name}-security"
  # the sender of the emails, so they stand out and a mail filter can catch them
  display_name = "${title(var.project)} SECURITY"
}

# Same people as the alarms. Each address gets a confirmation email after the
# apply, and receives nothing until its link is opened.
resource "aws_sns_topic_subscription" "security_email" {
  count     = nonsensitive(length(var.alert_emails))
  topic_arn = aws_sns_topic.security.arn
  protocol  = "email"
  endpoint  = var.alert_emails[count.index]
}

data "aws_iam_policy_document" "security_topic" {
  # what a topic without a policy of its own allows, and how the alarms of
  # monitoring.tf reach theirs
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
    sid       = "CostAnomalyDetection"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.security.arn]
    principals {
      type        = "Service"
      identifiers = ["costalerts.amazonaws.com"]
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

# The event rules publish with this role, not through the topic's policy, and
# the rules in the other Regions use it to hand their findings to this one.
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

locals {
  home_event_bus_arn = "arn:aws:events:${var.region}:${var.aws_account_id}:event-bus/default"
}

data "aws_iam_policy_document" "security_events" {
  statement {
    sid       = "PublishAlerts"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.security.arn]
  }

  statement {
    sid       = "FindingsFromOtherRegions"
    actions   = ["events:PutEvents"]
    resources = [local.home_event_bus_arn]
  }
}

resource "aws_iam_role" "security_events" {
  name               = "${local.name}-security-events"
  description        = "EventBridge: publishes the security alerts of ${local.name}, and brings GuardDuty findings from the other Regions"
  assume_role_policy = data.aws_iam_policy_document.security_events_trust.json
}

resource "aws_iam_role_policy" "security_events" {
  name   = "alerts"
  role   = aws_iam_role.security_events.id
  policy = data.aws_iam_policy_document.security_events.json
}

# --- GuardDuty -------------------------------------------------------------------------------

locals {
  # Billed by what they analyze. Lambda: the deploy gate and the deploy webhooks.
  guardduty_features = {
    S3_DATA_EVENTS         = { status = "ENABLED" }
    EBS_MALWARE_PROTECTION = { status = "ENABLED" } # scans a host's disk only after a finding on it
    RDS_LOGIN_EVENTS       = { status = "ENABLED" }
    LAMBDA_NETWORK_LOGS    = { status = "ENABLED" }
    EKS_AUDIT_LOGS         = { status = "DISABLED" } # no Kubernetes here
  }

  guardduty_runtime = var.guardduty_runtime_monitoring ? "ENABLED" : "DISABLED"

  guardduty_forward = {
    event_bus_arn = local.home_event_bus_arn
    role_arn      = aws_iam_role.security_events.arn
  }
}

module "guardduty" {
  source = "../../modules/guardduty"

  name = local.name
  features = merge(local.guardduty_features, {
    # Sign-ins on both databases (the main PostgreSQL, the CMS's MariaDB): a new
    # place, a guessed password. RDS_DATA_RISK, PostgreSQL only: a role reading far
    # more rows than it ever did, dropped tables. It learns for up to two weeks.
    RDS_LOGIN_EVENTS = {
      status     = "ENABLED"
      additional = { RDS_DATA_RISK = "ENABLED" }
    }
    # What runs on the machines. EC2_AGENT_MANAGEMENT: GuardDuty installs its agent
    # through Systems Manager on every EC2 instance, so on each new ECS host too,
    # and on the Elasticsearch host. The agent is capped at a tenth of the host's
    # CPU and 1 GiB of memory (256 MiB on the Elasticsearch host), and sees every
    # container on an ECS host. The agent reports over a link-local address:
    # GuardDuty adds a route for it (169.254.170.248/29 and fd00:ec2:6d00::/64,
    # target "GuardDuty") to every route table of the VPC. Those routes are
    # GuardDuty's, not Terraform's, and cannot be deleted; there is no VPC
    # endpoint. A host tagged GuardDutyManaged=false is left alone.
    # ECS_FARGATE_AGENT_MANAGEMENT: the Fargate tasks of the cluster, which are
    # the internal apps (postiz-internal-infra). GuardDuty attaches the agent as a
    # sidecar container when a task starts. It is not in the task definition, it
    # shows in the task as aws-guardduty-agent-*, it takes at most 128 MiB out of
    # the task's own memory, and a task whose sidecar cannot start runs without
    # it. A service gets it with its next deployment and not before: a running
    # task is never changed. Until every service has had one, GuardDuty's Runtime
    # coverage page lists the cluster as unhealthy and names the services left.
    RUNTIME_MONITORING = {
      status = local.guardduty_runtime
      additional = {
        EC2_AGENT_MANAGEMENT         = local.guardduty_runtime
        ECS_FARGATE_AGENT_MANAGEMENT = var.guardduty_runtime_monitoring && var.guardduty_fargate_monitoring ? "ENABLED" : "DISABLED"
        EKS_ADDON_MANAGEMENT         = "DISABLED"
      }
    }
  })
}

# The organization's policy denies every Region but this one and these two, so a
# stolen credential can start machines only here: watched too, at no cost while
# nothing runs there. A new open Region needs its provider (providers.tf) and a
# block like these.
module "guardduty_eu_west_1" {
  source    = "../../modules/guardduty"
  providers = { aws = aws.eu_west_1 }

  name                = local.name
  features            = local.guardduty_features
  forward_findings_to = local.guardduty_forward
}

module "guardduty_ap_southeast_2" {
  source    = "../../modules/guardduty"
  providers = { aws = aws.ap_southeast_2 }

  name                = local.name
  features            = local.guardduty_features
  forward_findings_to = local.guardduty_forward
}

# Severity runs from 1 to 10: under 4 is low (a port scan of a public address,
# which happens all day), 4 to 6.9 medium, 7 to 8.9 high, 9 and up critical.
resource "aws_cloudwatch_event_rule" "guardduty_finding" {
  name        = "${local.name}-security-guardduty-finding"
  description = "GuardDuty findings of medium severity and above, from every Region it runs in"
  event_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
    detail        = { severity = [{ numeric = [">=", 4] }] }
  })
}

locals {
  # One quoted line per line of the email. EventBridge does not escape what it
  # puts into a template, and a value with a double quote in it would make the
  # alert undeliverable: only ids, names and numbers that cannot hold one, so not
  # the finding's title or description.
  guardduty_alert_lines = [
    "SECURITY ${local.name}: GuardDuty finding, severity <severity> of 10",
    "(4 to 6.9 medium, 7 to 8.9 high, 9 and up critical)",
    "What: <type>",
    "On: <resource>, in <region>",
    "Seen <count> times, first <first>, last <last>",
    "Open it: https://<region>.console.aws.amazon.com/guardduty/home?region=<region>#/findings?fId=<id>",
    "What to do: README, Security alerts.",
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

# --- cost anomaly ----------------------------------------------------------------------------

# Per AWS service, against that service's own history. One monitor of this kind
# per account.
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
