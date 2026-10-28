variable "aws_account_id" {
  description = "The only AWS account these stacks may touch (TF_VAR_aws_account_id)."
  type        = string
}

variable "region" {
  description = "Home region."
  type        = string
  default     = "us-east-2"
}

variable "github_repository" {
  description = "owner/name of the GitHub repository holding this code."
  type        = string
  default     = "gitroomhq/postiz-aws"
}

variable "github_oidc_subject" {
  description = <<-EOT
    Start of the sub claim in this repository's GitHub OIDC tokens, printed by
    gh api repos/OWNER/NAME/actions/oidc/customization/sub --jq .sub_claim_prefix
    Repositories created since July 2026 carry the owner and repository ids
    (repo:owner@id/name@id), older ones repo:owner/name.
  EOT
  type        = string
  default     = "repo:gitroomhq@128401275/postiz-aws@1436140501"

  validation {
    condition     = can(regex("^repo:[^:]+$", var.github_oidc_subject))
    error_message = "Only the prefix, for example repo:owner@123/name@456 (no :ref: or :environment: part)."
  }
}
