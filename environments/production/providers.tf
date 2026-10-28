provider "aws" {
  region              = var.region
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = local.tags
  }
}

# CloudFront only accepts ACM certificates from us-east-1.
provider "aws" {
  alias               = "us_east_1"
  region              = "us-east-1"
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = local.tags
  }
}

# Reads CLOUDFLARE_API_TOKEN (Zone > Zone > Read for the zone lookup, Zone > DNS > Edit;
# both on the postiz.com zone only).
provider "cloudflare" {}
