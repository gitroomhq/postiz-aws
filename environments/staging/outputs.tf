output "alb_dns_name" {
  value = aws_lb.main.dns_name
}

output "urls" {
  value = {
    platform = "https://${var.frontend_domain}"
    api      = "https://${var.api_domain}"
    mcp      = "https://${var.mcp_domain}"
    stripe   = "https://${var.api_domain}:8443/stripe"
  }
}

output "deploy_role_arn" {
  description = "Repository variable STAGING_DEPLOY_ROLE_ARN"
  value       = aws_iam_role.deploy.arn
}

output "ecr_app_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "public_subnet_ids" {
  description = "Where deploy-staging.yml starts the one-off tasks"
  value       = module.network.public_subnet_ids
}

output "apps_security_group_id" {
  value = aws_security_group.apps.id
}

output "trust_store_arn" {
  description = "scripts/staging-certs.sh updates its revocation list"
  value       = one(aws_lb_trust_store.clients[*].arn)
}

output "trust_store_bucket" {
  value = aws_s3_bucket.trust_store.id
}

output "app_secret_names" {
  value = { for k, s in aws_secretsmanager_secret.app : k => s.name }
}

output "ses_dkim_status_hint" {
  description = "SES identity to check for DKIM SUCCESS before testing email"
  value       = aws_sesv2_email_identity.domain.email_identity
}
