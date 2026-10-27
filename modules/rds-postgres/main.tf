# RDS for PostgreSQL with the admin password kept out of Terraform state:
# an ephemeral random password goes write-only into the instance and into a
# Secrets Manager secret (<secret_prefix>/managed/<identifier>-admin).
#
# To rotate it, bump password_version: both the instance and the secret are
# rewritten in the same apply. Never bump only one of them.

ephemeral "random_password" "admin" {
  length  = 40
  special = false
}

resource "aws_db_subnet_group" "this" {
  name       = var.identifier
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "this" {
  name        = "${var.identifier}-rds"
  description = "PostgreSQL ${var.identifier}"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.identifier}-rds" }
}

resource "aws_vpc_security_group_ingress_rule" "clients" {
  for_each = var.allowed_security_group_ids

  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL from ${each.key}"
}

resource "aws_db_parameter_group" "this" {
  name        = var.identifier
  family      = "postgres${split(".", var.engine_version)[0]}"
  description = "Parameters for ${var.identifier}"

  dynamic "parameter" {
    for_each = var.parameters
    content {
      name         = parameter.key
      value        = parameter.value.value
      apply_method = parameter.value.apply_method
    }
  }
}

resource "aws_db_instance" "this" {
  identifier     = var.identifier
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class
  multi_az       = var.multi_az

  db_name             = var.db_name
  username            = var.username
  password_wo         = ephemeral.random_password.admin.result
  password_wo_version = var.password_version

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  publicly_accessible    = false
  parameter_group_name   = aws_db_parameter_group.this.name

  backup_retention_period  = var.backup_retention_days
  backup_window            = "07:00-07:45"
  maintenance_window       = "sun:08:00-sun:09:00"
  copy_tags_to_snapshot    = true
  delete_automated_backups = false

  auto_minor_version_upgrade   = true
  allow_major_version_upgrade  = false
  apply_immediately            = false
  performance_insights_enabled = true

  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.identifier}-final"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret" "admin" {
  name        = "${var.secret_prefix}/managed/${var.identifier}-admin"
  description = "Admin login of RDS ${var.identifier}, written by Terraform"
}

resource "aws_secretsmanager_secret_version" "admin" {
  secret_id = aws_secretsmanager_secret.admin.id
  secret_string_wo = jsonencode({
    username = var.username
    password = ephemeral.random_password.admin.result
    host     = aws_db_instance.this.address
    port     = aws_db_instance.this.port
    dbname   = var.db_name
    url      = "postgresql://${var.username}:${ephemeral.random_password.admin.result}@${aws_db_instance.this.address}:${aws_db_instance.this.port}/${var.db_name}?sslmode=require"
  })
  secret_string_wo_version = var.password_version
}

# --- alarms -----------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "cpu" {
  alarm_name          = "${var.identifier}-cpu-high"
  alarm_description   = "RDS ${var.identifier} CPU above 80% for 15 minutes"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.this.identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "storage" {
  alarm_name          = "${var.identifier}-free-storage-low"
  alarm_description   = "RDS ${var.identifier} has less than 10 GiB free (storage autoscaling may be maxed out)"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.this.identifier }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 10 * 1024 * 1024 * 1024
  comparison_operator = "LessThanThreshold"
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "memory" {
  alarm_name          = "${var.identifier}-freeable-memory-low"
  alarm_description   = "RDS ${var.identifier} freeable memory under 512 MiB"
  namespace           = "AWS/RDS"
  metric_name         = "FreeableMemory"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.this.identifier }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 3
  threshold           = 512 * 1024 * 1024
  comparison_operator = "LessThanThreshold"
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]
}

# The trigger for adding a connection pooler (RDS Proxy first): set it well
# below the instance's max_connections (db.r8g.large: ~1700).
resource "aws_cloudwatch_metric_alarm" "connections" {
  alarm_name          = "${var.identifier}-connections-high"
  alarm_description   = "RDS ${var.identifier} above ${var.connections_alarm_threshold} connections for 15 minutes: time to add RDS Proxy or lower pool sizes"
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.this.identifier }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.connections_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]
}
