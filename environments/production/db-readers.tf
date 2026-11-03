# Read-only SQL for the team, without opening the database to anything outside
# the VPC: no public endpoint, no tunnel. Members of the team's read-only group
# (bootstrap/: postiz-team-readonly, granted through account access manager) open
# CloudShell inside the VPC and run psql as the PostgreSQL role "readonly". They
# sign in with a 15-minute IAM token (aws rds generate-db-auth-token), so that
# role has no password to hand out, leak or rotate.
#
# What "readonly" may read is set inside PostgreSQL, where Terraform cannot
# reach: `migrate-postgres.sh readonly-role` in the ops task creates the role and
# grants SELECT on every table except the columns that hold credentials, with
# read-only transactions, a statement timeout and a connection cap.
# README: "Query the database (read-only)".

locals {
  db_reader_role = "readonly"
  private_subnet_arns = [
    for id in module.network.private_subnet_ids : "arn:aws:ec2:${var.region}:${var.aws_account_id}:subnet/${id}"
  ]
}

# The network interface of a CloudShell VPC environment: PostgreSQL out, nothing in.
resource "aws_security_group" "db_readers" {
  name        = "${local.name}-db-readers"
  description = "CloudShell VPC environments of the read-only team"
  vpc_id      = module.network.vpc_id
  tags        = { Name = "${local.name}-db-readers" }
}

resource "aws_vpc_security_group_egress_rule" "db_readers_postgres" {
  security_group_id            = aws_security_group.db_readers.id
  referenced_security_group_id = module.postgres_main.security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL on ${module.postgres_main.identifier}"
}

# Added to the team's role, which bootstrap/ creates with ReadOnlyAccess and no
# secret values. Attached from here because it names this stack's resources.
data "aws_iam_policy_document" "team_db_query" {
  statement {
    sid       = "CloudShell"
    actions   = ["cloudshell:*"]
    resources = ["*"]
  }

  # A VPC environment only in this VPC, in a private subnet, with the db-readers
  # group alone. One statement per key: a statement denies only when all of its
  # conditions match. Environments outside any VPC carry none of these keys.
  statement {
    sid       = "CloudShellOnlyInThisVpc"
    effect    = "Deny"
    actions   = ["cloudshell:CreateEnvironment"]
    resources = ["*"]
    condition {
      test     = "ForAnyValue:StringNotEquals"
      variable = "cloudshell:VpcIds"
      values   = [module.network.vpc_id]
    }
  }

  statement {
    sid       = "CloudShellOnlyInPrivateSubnets"
    effect    = "Deny"
    actions   = ["cloudshell:CreateEnvironment"]
    resources = ["*"]
    condition {
      test     = "ForAnyValue:StringNotEquals"
      variable = "cloudshell:SubnetIds"
      values   = module.network.private_subnet_ids
    }
  }

  statement {
    sid       = "CloudShellOnlyWithDbReadersGroup"
    effect    = "Deny"
    actions   = ["cloudshell:CreateEnvironment"]
    resources = ["*"]
    condition {
      test     = "ForAnyValue:StringNotEquals"
      variable = "cloudshell:SecurityGroupIds"
      values   = [aws_security_group.db_readers.id]
    }
  }

  # CloudShell creates the VPC environment's network interface with the caller's
  # permissions (ReadOnlyAccess already has the ec2:Describe* it needs).
  statement {
    sid     = "CloudShellNetworkInterface"
    actions = ["ec2:CreateNetworkInterface"]
    resources = concat(
      ["arn:aws:ec2:${var.region}:${var.aws_account_id}:network-interface/*"],
      local.private_subnet_arns,
      [aws_security_group.db_readers.arn],
    )
  }

  statement {
    sid       = "CloudShellNetworkInterfaceTagsOnCreate"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:aws:ec2:${var.region}:${var.aws_account_id}:network-interface/*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["CreateNetworkInterface"]
    }
  }

  # Attach permission for CloudShell (only AWS-authorized accounts can use one),
  # tags, and the cleanup when the environment goes away.
  statement {
    sid = "CloudShellNetworkInterfaceUpkeep"
    actions = [
      "ec2:CreateTags",
      "ec2:CreateNetworkInterfacePermission",
      "ec2:DeleteNetworkInterface",
    ]
    resources = ["arn:aws:ec2:${var.region}:${var.aws_account_id}:network-interface/*"]
    condition {
      test     = "ArnEquals"
      variable = "ec2:Subnet"
      values   = local.private_subnet_arns
    }
  }

  statement {
    sid       = "SignInAsReadonly"
    actions   = ["rds-db:connect"]
    resources = ["arn:aws:rds-db:${var.region}:${var.aws_account_id}:dbuser:${module.postgres_main.resource_id}/${local.db_reader_role}"]
  }

  # ReadOnlyAccess includes rds:Download*, and the PostgreSQL log holds every
  # statement slower than log_min_duration_statement with its bind parameters:
  # the tokens the readonly role is kept from reading.
  statement {
    sid       = "NoDatabaseLogFiles"
    effect    = "Deny"
    actions   = ["rds:DownloadDBLogFilePortion", "rds:DownloadCompleteDBLogFile"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "team_db_query" {
  name   = "query-database-readonly"
  role   = var.team_readonly_role_name
  policy = data.aws_iam_policy_document.team_db_query.json
}
