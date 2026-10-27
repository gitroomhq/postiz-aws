output "cluster_name" {
  value = module.ecs_cluster.cluster_name
}

output "alb_dns_name" {
  value = aws_lb.main.dns_name
}

output "cloudfront_domain" {
  value = aws_cloudfront_distribution.frontend.domain_name
}

output "ecr_app_repository" {
  value = aws_ecr_repository.app.repository_url
}

output "ecr_ops_repository" {
  value = aws_ecr_repository.ops.repository_url
}

output "main_db_address" {
  value = module.postgres_main.address
}

output "redis_primary_endpoint" {
  value = aws_elasticache_replication_group.redis.primary_endpoint_address
}

output "elasticsearch_private_ip" {
  value = aws_instance.elasticsearch.private_ip
}

output "app_secret_arns" {
  description = "Filled by scripts/railway-env-to-secrets.py"
  value       = { for k, s in aws_secretsmanager_secret.app : k => s.arn }
}

output "managed_secret_arns" {
  description = "Written by Terraform (passwords, REDIS_URL)"
  value = {
    main_db       = module.postgres_main.admin_secret_arn
    temporal_db   = aws_secretsmanager_secret.temporal_db.arn
    redis         = aws_secretsmanager_secret.redis.arn
    elasticsearch = aws_secretsmanager_secret.elasticsearch.arn
  }
}

output "service_names" {
  value = concat(
    [for k, m in module.postiz : m.service_name],
    [for k, m in module.temporal : m.service_name],
    [module.temporal_ui.service_name],
  )
}

output "task_definition_families" {
  value = {
    db_push = module.db_push.task_definition_family
    ops     = module.ops.task_definition_family
  }
}

output "deploy_role_arn" {
  description = "GitHub variable AWS_DEPLOY_ROLE_ARN"
  value       = aws_iam_role.deploy.arn
}

output "public_subnet_ids" {
  value = module.network.public_subnet_ids
}

output "temporal_ui_url" {
  description = "Temporal UI behind basic auth (user and password: secret postiz/production/temporal-ui-auth); null when private, see scripts/temporal-ui-tunnel.sh"
  value       = var.temporal_ui_public ? "https://${var.temporal_ui_domain}" : null
  sensitive   = true
}

output "maintenance_bypass_token" {
  description = "Header X-Postiz-Bypass: <token> reaches the services while maintenance_mode is on"
  value       = random_password.maintenance_bypass.result
  sensitive   = true
}
