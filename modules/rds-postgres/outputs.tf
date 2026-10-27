output "address" {
  value = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "identifier" {
  value = aws_db_instance.this.identifier
}

output "security_group_id" {
  value = aws_security_group.this.id
}

output "admin_secret_arn" {
  description = "JSON: username, password, host, port, dbname, url"
  value       = aws_secretsmanager_secret.admin.arn
}
