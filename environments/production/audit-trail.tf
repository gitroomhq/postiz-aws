# The record of what was done to the account: every management API call, from
# every Region, kept for over a year, and an alert on the calls that open a way
# in or hide one. security.tf has the topic the alerts go to.
#
# Without a trail AWS keeps 90 days per Region and can alert on none of it:
# event rules see API calls only while a trail is logging.
#
# Two kinds of alert, by where AWS records the call:
#   event rules      (local.api_alerts) for calls made in this Region. The email
#                    says who, from where and on what.
#   metric filters   (local.trail_alerts) for IAM calls and for calls in any other
#                    Region. IAM is recorded in us-east-1, where the organization's
#                    policy lets this account create neither a rule nor a topic,
#                    but the trail copies every Region into one log group here.
#                    The alarm's email only names the alarm: the call itself is in
#                    the log group.
#
# A change that comes through the deploy gate was approved with a code, so the
# roles only the gate hands out (var.gated_apply_role_names) do not alert, and
# neither does AWS's own housekeeping (its service-linked roles). An alert
# therefore means: changed by hand, or by someone else.

locals {
  trail_name = local.name
  trail_arn  = "arn:aws:cloudtrail:${var.region}:${var.aws_account_id}:trail/${local.trail_name}"

  # The bucket answers "what did they touch" months later. The log group is the
  # copy the alarms read and Logs Insights searches.
  trail_bucket_days = 400
  trail_log_days    = 90
}

# --- the record ------------------------------------------------------------------------------

resource "aws_s3_bucket" "cloudtrail" {
  bucket = "${local.name}-cloudtrail-${var.aws_account_id}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket                  = aws_s3_bucket.cloudtrail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# A deleted or overwritten log file stays for 30 days as an old version, and
# the trail's digest files (enable_log_file_validation) show that it was.
resource "aws_s3_bucket_versioning" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = local.trail_bucket_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.cloudtrail]
}

data "aws_iam_policy_document" "cloudtrail_bucket" {
  statement {
    sid       = "TrailChecksTheBucket"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.cloudtrail.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid       = "TrailWritesItsLogs"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${var.aws_account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.cloudtrail.arn,
      "${aws_s3_bucket.cloudtrail.arn}/*",
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

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket     = aws_s3_bucket.cloudtrail.id
  policy     = data.aws_iam_policy_document.cloudtrail_bucket.json
  depends_on = [aws_s3_bucket_public_access_block.cloudtrail]
}

resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/aws/cloudtrail/${local.name}"
  retention_in_days = local.trail_log_days
}

data "aws_iam_policy_document" "cloudtrail_logs_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }
}

data "aws_iam_policy_document" "cloudtrail_logs" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.cloudtrail.arn}:*"]
  }
}

resource "aws_iam_role" "cloudtrail_logs" {
  name               = "${local.name}-cloudtrail-logs"
  description        = "CloudTrail: copies the trail of ${local.name} into its log group"
  assume_role_policy = data.aws_iam_policy_document.cloudtrail_logs_trust.json
}

resource "aws_iam_role_policy" "cloudtrail_logs" {
  name   = "write-log-group"
  role   = aws_iam_role.cloudtrail_logs.id
  policy = data.aws_iam_policy_document.cloudtrail_logs.json
}

# Management events only (the default): what was created, changed, deleted or
# listed. Not the reads and writes of objects inside S3, which are billed per
# event and are GuardDuty's to watch (S3_DATA_EVENTS, security.tf). The first
# trail's management events are free, the log group's copy is not.
resource "aws_cloudtrail" "main" {
  name           = local.trail_name
  s3_bucket_name = aws_s3_bucket.cloudtrail.id

  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_logs.arn

  depends_on = [aws_s3_bucket_policy.cloudtrail, aws_iam_role_policy.cloudtrail_logs]
}

# --- alerts on calls in this Region ----------------------------------------------------------

locals {
  # userIdentity.arn of a session: arn:aws:sts::<account>:assumed-role/<role>/<session name>
  expected_callers = concat(
    [for role in var.gated_apply_role_names : "arn:aws:sts::${var.aws_account_id}:assumed-role/${role}/"],
    ["arn:aws:sts::${var.aws_account_id}:assumed-role/AWSServiceRoleFor"],
  )
  not_an_expected_caller = { arn = [{ "anything-but" = { prefix = local.expected_callers } }] }
  not_the_ecs_service    = { arn = [{ "anything-but" = { prefix = ["arn:aws:sts::${var.aws_account_id}:assumed-role/AWSServiceRoleForECS/"] } }] }

  # what = the email's first line. paths and lines = what the call was made on,
  # added to the lines every alert has (local.api_alert_lines).
  api_alerts = {
    # ECS Exec, and Session Manager sessions that are not one of the tunnels
    # (var.quiet_session_documents): a session with no document is a shell.
    # What was typed is not recorded anywhere. For an ECS Exec, ECS starts the
    # session itself with its service role: that second event says nothing the
    # ExecuteCommand did not, so only a session someone started alerts.
    shell-session = {
      what = "a shell was opened on a host or in a container"
      detail = jsonencode({
        "$or" = [
          { eventSource = ["ecs.amazonaws.com"], eventName = ["ExecuteCommand"] },
          {
            eventSource       = ["ssm.amazonaws.com"], eventName = ["StartSession"], userIdentity = local.not_the_ecs_service
            requestParameters = { documentName = [{ exists = false }] }
          },
          {
            eventSource       = ["ssm.amazonaws.com"], eventName = ["StartSession"], userIdentity = local.not_the_ecs_service
            requestParameters = { documentName = [{ "anything-but" = { prefix = var.quiet_session_documents } }] }
          },
        ]
      })
      paths = {
        target    = "$.detail.requestParameters.target"
        document  = "$.detail.requestParameters.documentName"
        cluster   = "$.detail.requestParameters.cluster"
        task      = "$.detail.requestParameters.task"
        container = "$.detail.requestParameters.container"
      }
      lines = [
        "Session Manager: target <target>, document <document>",
        "ECS Exec: cluster <cluster>, task <task>, container <container>",
      ]
    }

    # The ways to copy a database out or to open it: a snapshot shared with
    # another account, exported or copied, a second instance restored from one, a
    # new master password or a public address (both ModifyDBInstance), logging
    # turned off in the parameters.
    database-change = {
      what = "a database was changed, copied or restored outside the deploy gate"
      detail = jsonencode({
        eventSource = ["rds.amazonaws.com"]
        eventName = [
          "ModifyDBInstance", "ModifyDBParameterGroup", "DeleteDBInstance", "CreateDBInstanceReadReplica",
          "ModifyDBSnapshotAttribute", "ModifyDBClusterSnapshotAttribute", "CopyDBSnapshot", "StartExportTask",
          "RestoreDBInstanceFromDBSnapshot", "RestoreDBInstanceToPointInTime",
        ]
        userIdentity = local.not_an_expected_caller
      })
      paths = {
        database  = "$.detail.requestParameters.dBInstanceIdentifier"
        snapshot  = "$.detail.requestParameters.dBSnapshotIdentifier"
        parameter = "$.detail.requestParameters.dBParameterGroupName"
      }
      lines = ["Database <database>, snapshot <snapshot>, parameter group <parameter>"]
    }

    network-opened = {
      what = "a security group was opened outside the deploy gate"
      detail = jsonencode({
        eventSource  = ["ec2.amazonaws.com"]
        eventName    = ["AuthorizeSecurityGroupIngress", "ModifySecurityGroupRules"]
        userIdentity = local.not_an_expected_caller
      })
      paths = { group = "$.detail.requestParameters.groupId" }
      lines = ["Security group <group>"]
    }

    # Turning off what would tell: the trail, GuardDuty (also a filter or a
    # trusted address list that silences findings), these rules, the alarms, the
    # topic. Someone with admin rights can still do it, and the alert for it may
    # be the last one sent.
    detection-changed = {
      what = "the audit trail, GuardDuty or an alert was changed outside the deploy gate"
      detail = jsonencode({
        eventSource = ["cloudtrail.amazonaws.com", "guardduty.amazonaws.com", "events.amazonaws.com", "monitoring.amazonaws.com", "logs.amazonaws.com", "sns.amazonaws.com"]
        eventName = [
          "StopLogging", "DeleteTrail", "UpdateTrail", "PutEventSelectors",
          "DeleteDetector", "UpdateDetector", "CreateFilter", "UpdateFilter", "CreateIPSet", "UpdateIPSet",
          "DisableRule", "DeleteRule", "RemoveTargets",
          "DeleteAlarms", "DisableAlarmActions", "DeleteMetricFilter", "DeleteLogGroup",
          "DeleteTopic", "Unsubscribe",
        ]
        userIdentity = local.not_an_expected_caller
      })
      paths = {}
      lines = []
    }
  }

  # One quoted line per line of the email. EventBridge does not escape what it
  # puts into a template, and a value with a double quote in it would make the
  # alert undeliverable: only ids and names that cannot hold one, so never the
  # command of an ECS Exec or an error message. <error> is empty for a call that
  # went through.
  api_alert_paths = {
    name   = "$.detail.eventName"
    source = "$.detail.eventSource"
    region = "$.detail.awsRegion"
    time   = "$.detail.eventTime"
    who    = "$.detail.userIdentity.arn"
    ip     = "$.detail.sourceIPAddress"
    error  = "$.detail.errorCode"
    id     = "$.detail.eventID"
  }
  api_alert_lines = {
    for key, alert in local.api_alerts : key => concat(
      [
        "SECURITY ${local.name}: ${alert.what}",
        "<name> (<source>) in <region> at <time>",
        "By: <who>",
        "From: <ip>",
      ],
      alert.lines,
      [
        "Refused with: <error>",
        "The whole call: CloudTrail, Event history, event ID <id>",
        "Not you or the team? README, Security alerts.",
      ],
    )
  }
}

resource "aws_cloudwatch_event_rule" "api_alert" {
  for_each = local.api_alerts

  name        = "${local.name}-security-${each.key}"
  description = "Security alert: ${each.value.what}"
  event_pattern = jsonencode({
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail        = jsondecode(each.value.detail)
  })

  # event rules only see API calls while the trail is logging
  depends_on = [aws_cloudtrail.main]
}

resource "aws_cloudwatch_event_target" "api_alert" {
  for_each = local.api_alerts

  rule      = aws_cloudwatch_event_rule.api_alert[each.key].name
  target_id = "security-topic"
  arn       = aws_sns_topic.security.arn
  role_arn  = aws_iam_role.security_events.arn

  input_transformer {
    input_paths    = merge(local.api_alert_paths, each.value.paths)
    input_template = join("\n", [for line in local.api_alert_lines[each.key] : "\"${line}\""])
  }
}

# --- alerts on IAM and on the other Regions --------------------------------------------------

locals {
  # local.expected_callers again, in the filter syntax of CloudWatch Logs
  trail_not_an_expected_caller = join(" && ", concat(
    [for role in var.gated_apply_role_names : "($.userIdentity.arn != \"*:assumed-role/${role}/*\")"],
    ["($.userIdentity.arn != \"*:assumed-role/AWSServiceRoleFor*\")"],
  ))

  # ($.eventName = "A") || ($.eventName = "B") ...: a filter pattern takes no
  # regular expression with a group in it
  trail_iam_user_calls = "(${join(" || ", [for call in [
    "CreateUser", "CreateAccessKey", "CreateLoginProfile", "UpdateLoginProfile", "AttachUserPolicy", "PutUserPolicy", "AddUserToGroup",
  ] : "($.eventName = \"${call}\")"])})"
  trail_iam_role_calls = "(${join(" || ", [for call in [
    "CreateRole", "UpdateAssumeRolePolicy", "AttachRolePolicy", "PutRolePolicy", "CreatePolicyVersion", "SetDefaultPolicyVersion",
    "DeleteRolePermissionsBoundary", "CreateOpenIDConnectProvider", "CreateSAMLProvider", "UpdateSAMLProvider",
  ] : "($.eventName = \"${call}\")"])})"

  trail_alerts = {
    # No exception for the deploy gate: this account has no IAM users, and
    # nothing in Terraform creates one.
    iam-user-or-key = {
      what    = "An IAM user, a password or a long-lived access key was created or given permissions. This account has none, so nobody should: it is how a visitor keeps a way back in."
      pattern = "{ ($.eventSource = \"iam.amazonaws.com\") && ${local.trail_iam_user_calls} }"
    }

    iam-role-change = {
      what    = "A role, its trust or its permissions were changed outside the deploy gate, or a new sign-in provider was added: by hand, or by someone else."
      pattern = "{ ($.eventSource = \"iam.amazonaws.com\") && ${local.trail_iam_role_calls} && ${local.trail_not_an_expected_caller} }"
    }

    root-used = {
      what    = "The account's root user did something. It has no password and no keys here, so either the organization's management account acted as it, or something is very wrong."
      pattern = "{ ($.userIdentity.type = \"Root\") && ($.userIdentity.invokedBy NOT EXISTS) && ($.eventType != \"AwsServiceEvent\") }"
    }

    # Everything runs in var.region, and us-east-1 is where AWS records its
    # global services (IAM, CloudFront, Route 53). A refused attempt counts too.
    other-region = {
      what    = "Something was created or changed in a Region where nothing of ours runs, outside the deploy gate: the usual first move with a stolen credential is to start machines somewhere quiet."
      pattern = "{ ($.awsRegion != \"${var.region}\") && ($.awsRegion != \"us-east-1\") && ($.readOnly IS FALSE) && ($.eventType = \"AwsApiCall\") && ${local.trail_not_an_expected_caller} }"
    }
  }
}

resource "aws_cloudwatch_log_metric_filter" "trail_alert" {
  for_each = local.trail_alerts

  name           = "${local.name}-security-${each.key}"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = each.value.pattern

  metric_transformation {
    name      = each.key
    namespace = "${local.name}/security"
    value     = "1"
  }
}

# No ok_actions: the call happened, and five quiet minutes later is not news.
resource "aws_cloudwatch_metric_alarm" "trail_alert" {
  for_each = local.trail_alerts

  alarm_name          = "${local.name}-security-${each.key}"
  alarm_description   = "${each.value.what} Find the calls with Logs Insights on ${aws_cloudwatch_log_group.cloudtrail.name}. What to do: README, Security alerts."
  namespace           = aws_cloudwatch_log_metric_filter.trail_alert[each.key].metric_transformation[0].namespace
  metric_name         = aws_cloudwatch_log_metric_filter.trail_alert[each.key].metric_transformation[0].name
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.security.arn]
}
