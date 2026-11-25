# Amazon SES in the staging account, left in the sandbox on purpose: it only
# sends to verified addresses (var.ses_test_recipients, 200 a day), so nothing
# staging does can email a real user. Mail goes out as getpostiz.com, signed with
# Easy DKIM. Sign-ups need no email to activate while no provider is configured,
# but with this one they do: verify the testers' addresses first.

resource "aws_sesv2_email_identity" "domain" {
  email_identity = var.cloudflare_zone_name

  dkim_signing_attributes {
    next_signing_key_length = "RSA_2048_BIT"
  }
}

# Easy DKIM always issues three tokens; count, because they are unknown until the identity exists
resource "cloudflare_dns_record" "ses_dkim" {
  count = 3

  zone_id = data.cloudflare_zone.main.id
  name    = "${aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens[count.index]}._domainkey.${var.cloudflare_zone_name}"
  type    = "CNAME"
  content = "${aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens[count.index]}.dkim.amazonses.com"
  ttl     = 1
  proxied = false
  comment = "SES DKIM for ${var.cloudflare_zone_name}, managed by postiz-aws (staging)"
}

# each gets a verification email after the apply; count, not for_each: sensitive values cannot be keys
resource "aws_sesv2_email_identity" "recipient" {
  count          = nonsensitive(length(var.ses_test_recipients))
  email_identity = var.ses_test_recipients[count.index]
}

# In the sandbox SES checks the recipients' identities too, so the sending
# services may use every identity of this account (only staging's live here),
# but only with a From address of getpostiz.com: never as a tester's address.
data "aws_iam_policy_document" "ses_send" {
  statement {
    actions   = ["ses:SendEmail"]
    resources = ["arn:aws:ses:${var.region}:${var.aws_account_id}:identity/*"]
    condition {
      test     = "StringLike"
      variable = "ses:FromAddress"
      values   = ["*@${var.cloudflare_zone_name}"]
    }
  }
}
