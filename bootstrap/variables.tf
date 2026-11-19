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

variable "github_repository_id" {
  description = <<-EOT
    Numeric id of the repository, which the deploy gate checks in the run's token
    (a renamed or re-created repository has another one):
    gh api repos/OWNER/NAME --jq .id
  EOT
  type        = string
  default     = "1436140501"

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_id))
    error_message = "Digits only."
  }
}

variable "github_repository_owner_id" {
  description = "Numeric id of the repository's owner, checked the same way: gh api repos/OWNER/NAME --jq .owner.id"
  type        = string
  default     = "128401275"

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_owner_id))
    error_message = "Digits only."
  }
}

variable "deploy_role_name" {
  description = "Name of the deploy role that environments/production creates (output deploy_role_arn). The gate hands it to runs in the \"deploy\" GitHub environment."
  type        = string
  default     = "postiz-production-github-deploy"
}

variable "deploy_gate_audience" {
  description = "Audience the workflows ask GitHub to put in the token they show the gate (scripts/gate-ci.sh). Not sts.amazonaws.com, so that token is of no use to AWS itself."
  type        = string
  default     = "postiz-deploy-gate"
}

variable "deploy_gate_repositories" {
  description = <<-EOT
    More repositories of the same owner whose workflows get their roles from the
    deploy gate, by numeric repository id (gh api repos/OWNER/NAME --jq .id).
    For each one its owner/name and, per GitHub environment of its jobs: the name
    of the role in this account the gate hands out (the role must trust the
    gate's role, see README "Deploy gate"), what the person who starts the run
    must be allowed, "deploy" or "production" (terraform apply), and how long
    one code keeps a run going. Each repository has its own trusted commit.
    For repositories that should not be named here, bootstrap/local.auto.tfvars
    is read by Terraform and ignored by git.
  EOT
  type = map(object({
    name = string
    targets = map(object({
      role_name        = string
      right            = string
      approval_seconds = optional(number, 5400)
    }))
  }))
  default = {}

  validation {
    condition     = alltrue([for id in keys(var.deploy_gate_repositories) : can(regex("^[0-9]+$", id))])
    error_message = "The keys are numeric repository ids."
  }

  validation {
    condition = alltrue(flatten([
      for repository in values(var.deploy_gate_repositories) : [for target in values(repository.targets) : contains(["deploy", "production"], target.right)]
    ]))
    error_message = "right is \"deploy\" or \"production\"."
  }

  validation {
    condition     = !contains(keys(var.deploy_gate_repositories), var.github_repository_id)
    error_message = "This repository is served already: name only the others."
  }
}
