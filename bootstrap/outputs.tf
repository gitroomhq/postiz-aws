output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "github_oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}

output "plan_role_arn" {
  description = "GitHub variable AWS_PLAN_ROLE_ARN"
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "GitHub variable AWS_APPLY_ROLE_ARN"
  value       = aws_iam_role.apply.arn
}

output "agent_readonly_role_arn" {
  description = "Add to ~/.aws/config as a profile whose source_profile is your admin profile"
  value       = aws_iam_role.agent_readonly.arn
}

output "team_readonly_role_arn" {
  description = "Role to grant team members in account access manager (create-entitlement)"
  value       = aws_iam_role.team_readonly.arn
}
