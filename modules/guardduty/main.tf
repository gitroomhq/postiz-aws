# GuardDuty in one Region: the detector, the protection plans named in
# var.features, and optionally a rule that sends the Region's findings to the
# Region where the alerts are.
#
# GuardDuty only tells: it never blocks or changes anything. A detector reads
# what AWS already records (API calls, DNS lookups, network flows), so turning it
# on touches no workload. The one plan that installs something is
# RUNTIME_MONITORING with EC2_AGENT_MANAGEMENT: GuardDuty then puts its agent on
# every EC2 instance Systems Manager manages, and creates a VPC endpoint for it.
#
# Billed by what it analyzes, so a Region where nothing runs costs close to
# nothing. The first 30 days of every plan are free, and the console's Usage page
# shows what each plan would cost.

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

resource "aws_guardduty_detector" "this" {
  enable = true
  # how often a finding that keeps happening is sent again; a new finding is
  # always sent within minutes
  finding_publishing_frequency = "FIFTEEN_MINUTES"
}

resource "aws_guardduty_detector_feature" "this" {
  for_each = var.features

  detector_id = aws_guardduty_detector.this.id
  name        = each.key
  status      = each.value.status

  dynamic "additional_configuration" {
    for_each = each.value.additional
    content {
      name   = additional_configuration.key
      status = additional_configuration.value
    }
  }
}

# --- findings to the Region with the alerts ---------------------------------------------

# A finding only shows up on the event bus of its own Region. Same account, so
# the role is all the other bus asks for.
resource "aws_cloudwatch_event_rule" "forward" {
  count = var.forward_findings_to == null ? 0 : 1

  name        = "${var.name}-guardduty-findings-forward"
  description = "Sends this Region's GuardDuty findings to the Region where the alerts are"
  event_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
  })
}

resource "aws_cloudwatch_event_target" "forward" {
  count = var.forward_findings_to == null ? 0 : 1

  rule      = aws_cloudwatch_event_rule.forward[0].name
  target_id = "home-region"
  arn       = var.forward_findings_to.event_bus_arn
  role_arn  = var.forward_findings_to.role_arn
}
