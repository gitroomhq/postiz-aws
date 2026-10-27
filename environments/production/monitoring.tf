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

locals {
  alarm_actions = [aws_sns_topic.alerts.arn]
}

# --- edge ----------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${local.name}-alb-5xx"
  alarm_description   = "Load balancer returned more than 50 5xx responses in 5 minutes (no healthy target, timeouts)"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  dimensions          = { LoadBalancer = aws_lb.main.arn_suffix }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 50
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  for_each = var.apps_enabled ? aws_lb_target_group.app : {}

  alarm_name          = "${local.name}-${each.key}-unhealthy"
  alarm_description   = "${each.key}: a target failed its health check for 3 minutes"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { LoadBalancer = aws_lb.main.arn_suffix, TargetGroup = each.value.arn_suffix }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# --- services without a load balancer: the Temporal roles and the workers ---------------

locals {
  watched_services = var.apps_enabled ? toset(concat(
    var.workers_enabled ? ["worker", "worker-2"] : [],
    [for role in keys(local.temporal_roles) : "temporal-${role}"],
  )) : toset([])
}

resource "aws_cloudwatch_metric_alarm" "service_down" {
  for_each = local.watched_services

  alarm_name          = "${local.name}-${each.key}-down"
  alarm_description   = "${each.key} has had no running task for 5 minutes"
  namespace           = "ECS/ContainerInsights"
  metric_name         = "RunningTaskCount"
  dimensions          = { ClusterName = module.ecs_cluster.cluster_name, ServiceName = each.key }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# --- Valkey and Elasticsearch --------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "redis_memory" {
  alarm_name          = "${local.name}-redis-memory"
  alarm_description   = "Valkey memory above 80%"
  namespace           = "AWS/ElastiCache"
  metric_name         = "DatabaseMemoryUsagePercentage"
  dimensions          = { ReplicationGroupId = aws_elasticache_replication_group.redis.id }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "elasticsearch_status" {
  alarm_name          = "${local.name}-elasticsearch-status-check"
  alarm_description   = "Elasticsearch host failed its EC2 status checks"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  dimensions          = { InstanceId = aws_instance.elasticsearch.id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}
