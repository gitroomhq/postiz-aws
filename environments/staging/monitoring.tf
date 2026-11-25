# The "is it up" alarms (RDS's, from its module) go here, apart from the
# security topic. Staging keeps few: it is allowed to be down.
resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

# count, not for_each: sensitive values cannot become resource keys
resource "aws_sns_topic_subscription" "email" {
  count     = nonsensitive(length(var.alert_emails))
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_emails[count.index]
}
