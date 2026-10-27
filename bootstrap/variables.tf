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
