# Amazon SES for the app's email (EMAIL_PROVIDER=ses in postiz-app,
# libraries/nestjs-libraries/src/emails/ses.provider.ts). backend, mcp, worker and
# worker-2 send with their task role (no access keys) in var.region; the
# organization's SCP only allows SES there.
#
# Mail goes out as the postiz.com domain, so any EMAIL_FROM_ADDRESS @postiz.com
# works. postiz.com publishes DMARC p=reject, so both signals are aligned:
#   - Easy DKIM, 2048-bit: three CNAMEs <token>._domainkey.postiz.com
#   - custom MAIL FROM ses-mail.postiz.com (SPF), not send.postiz.com: that one
#     is Resend's, which sends through SES in us-east-1
#
# Before ses_sending_enabled = true: the identity must show DKIM "SUCCESS" and the
# account needs production access (a new SES account is in the sandbox: 200 mails
# a day, verified recipients only): SES console > Account dashboard > Request
# production access.

locals {
  ses_domain           = var.cloudflare_zone_name
  ses_mail_from_domain = "ses-mail.${var.cloudflare_zone_name}"
  # built from known values, so the task role policies are known at plan time
  ses_identity_arn          = "arn:aws:ses:${var.region}:${var.aws_account_id}:identity/${local.ses_domain}"
  ses_configuration_set_arn = "arn:aws:ses:${var.region}:${var.aws_account_id}:configuration-set/${local.name}"
}

# Managed dedicated IPs: SES leases, warms up (per mailbox provider) and scales the
# IPs itself, sending what the pool is not warm enough for through the shared pool.
# $15/month + $0.08 per 1,000 mails (a la carte pricing).
resource "aws_sesv2_dedicated_ip_pool" "main" {
  pool_name    = local.name
  scaling_mode = "MANAGED"
}

resource "aws_sesv2_configuration_set" "main" {
  configuration_set_name = local.name

  # every mail goes through this set (identity default), so through the pool
  delivery_options {
    sending_pool_name = aws_sesv2_dedicated_ip_pool.main.pool_name
  }
  reputation_options {
    reputation_metrics_enabled = true
  }
  sending_options {
    sending_enabled = true
  }
  suppression_options {
    suppressed_reasons = ["BOUNCE", "COMPLAINT"]
  }
}

resource "aws_sesv2_email_identity" "domain" {
  email_identity         = local.ses_domain
  configuration_set_name = aws_sesv2_configuration_set.main.configuration_set_name

  dkim_signing_attributes {
    next_signing_key_length = "RSA_2048_BIT"
  }
}

# Easy DKIM always issues three tokens; count, because they are unknown until the identity exists
resource "cloudflare_dns_record" "ses_dkim" {
  count = 3

  zone_id = data.cloudflare_zone.main.id
  name    = "${aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens[count.index]}._domainkey.${local.ses_domain}"
  type    = "CNAME"
  content = "${aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens[count.index]}.dkim.amazonses.com"
  ttl     = 1
  proxied = false
  comment = "SES DKIM for ${local.ses_domain}, managed by postiz-aws"
}

resource "aws_sesv2_email_identity_mail_from_attributes" "domain" {
  email_identity         = aws_sesv2_email_identity.domain.email_identity
  mail_from_domain       = local.ses_mail_from_domain
  behavior_on_mx_failure = "USE_DEFAULT_VALUE"
}

resource "cloudflare_dns_record" "ses_mail_from_mx" {
  zone_id  = data.cloudflare_zone.main.id
  name     = local.ses_mail_from_domain
  type     = "MX"
  content  = "feedback-smtp.${var.region}.amazonses.com"
  priority = 10
  ttl      = 1
  proxied  = false
  comment  = "SES MAIL FROM (bounces), managed by postiz-aws"
}

# also replaces the zone's wildcard "v=spf1 -all" for this name
resource "cloudflare_dns_record" "ses_mail_from_spf" {
  zone_id = data.cloudflare_zone.main.id
  name    = local.ses_mail_from_domain
  type    = "TXT"
  content = "\"v=spf1 include:amazonses.com ~all\""
  ttl     = 1
  proxied = false
  comment = "SES MAIL FROM (SPF), managed by postiz-aws"
}

# What the sending services' task roles get (postiz.tf)
data "aws_iam_policy_document" "ses_send" {
  statement {
    actions   = ["ses:SendEmail"]
    resources = [local.ses_identity_arn, local.ses_configuration_set_arn]
  }
}

# Account-wide reputation. SES reviews an account at 5% bounces / 0.1% complaints
# and may pause sending at 10% / 0.5%, so these fire at the review level.
resource "aws_cloudwatch_metric_alarm" "ses_bounce_rate" {
  alarm_name          = "${local.name}-ses-bounce-rate"
  alarm_description   = "SES bounce rate above 5%: SES reviews the account here and may pause sending at 10%"
  namespace           = "AWS/SES"
  metric_name         = "Reputation.BounceRate"
  statistic           = "Maximum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 0.05
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "ses_complaint_rate" {
  alarm_name          = "${local.name}-ses-complaint-rate"
  alarm_description   = "SES complaint rate above 0.1%: SES reviews the account here and may pause sending at 0.5%"
  namespace           = "AWS/SES"
  metric_name         = "Reputation.ComplaintRate"
  statistic           = "Maximum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 0.001
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}
