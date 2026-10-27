terraform {
  # 1.11+ for write-only arguments (passwords never land in state)
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.70, < 7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.7, < 4.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = ">= 5.28, < 6.0"
    }
  }

  # bucket comes from -backend-config: backend.hcl locally (see backend.hcl.example),
  # vars.TF_STATE_BUCKET in CI
  backend "s3" {
    key          = "production/terraform.tfstate"
    region       = "us-east-2"
    use_lockfile = true
    encrypt      = true
  }
}
