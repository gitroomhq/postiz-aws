# The staging account only: allowed_account_ids stops a plan or apply that runs
# with production's credentials by mistake.
provider "aws" {
  region              = var.region
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = local.tags
  }
}

# Reads CLOUDFLARE_API_TOKEN (Zone > Zone > Read for the zone lookup, Zone > DNS > Edit;
# both on the getpostiz.com zone only, a token separate from production's).
provider "cloudflare" {}
