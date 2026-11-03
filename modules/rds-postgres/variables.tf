variable "identifier" {
  type = string
}

variable "engine_version" {
  description = "Major version (\"16\") lets RDS pick and auto-upgrade the minor."
  type        = string
}

variable "instance_class" {
  type = string
}

variable "multi_az" {
  type = bool
}

variable "db_name" {
  type = string
}

variable "username" {
  type = string
}

variable "password_version" {
  description = "Bump to rotate the admin password (instance and secret together)."
  type        = number
  default     = 1
}

variable "allocated_storage" {
  type = number
}

variable "max_allocated_storage" {
  type = number
}

variable "backup_retention_days" {
  type    = number
  default = 14
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "allowed_security_group_ids" {
  description = "Label => security group id allowed on 5432."
  type        = map(string)
}

variable "iam_database_authentication" {
  description = <<-EOT
    Let roles granted rds_iam sign in with a 15-minute IAM token instead of a
    password; other roles keep their passwords. No downtime, but with
    apply_immediately off it waits for the maintenance window: run
    `aws rds modify-db-instance --enable-iam-database-authentication --apply-immediately` first.
  EOT
  type        = bool
  default     = false
}

variable "parameters" {
  type = map(object({
    value        = string
    apply_method = string
  }))
  default = {}
}

variable "secret_prefix" {
  type = string
}

variable "alarm_topic_arn" {
  description = "SNS topic for the CPU, storage and memory alarms."
  type        = string
}

variable "connections_alarm_threshold" {
  description = "Alarm when connections stay above this (db.r8g.large max_connections is ~1700)."
  type        = number
  default     = 1000
}
