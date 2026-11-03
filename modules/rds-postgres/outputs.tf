output "address" {
  value = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "identifier" {
  value = aws_db_instance.this.identifier
}

output "resource_id" {
  description = "DbiResourceId, the instance's part of rds-db:connect ARNs (IAM sign-in)"
  value       = aws_db_instance.this.resource_id
}

output "security_group_id" {
  value = aws_security_group.this.id
}

output "admin_secret_arn" {
  description = "JSON: username, password, host, port, dbname, url"
  value       = aws_secretsmanager_secret.admin.arn
}
