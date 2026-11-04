# Session Manager tunnels for the team's read-only role (postiz-team-readonly,
# bootstrap/). Each document forwards a port on the caller's machine, through an
# ECS host, to one host and port fixed in the document: neither is a parameter.
# bootstrap/ denies the role every session document not named postiz-team-*, so
# the documents here are all it can open: no shell, no free port forward, no ECS
# Exec. What each tunnel reaches still decides what the caller may do:
#
#   postiz-team-temporal-readonly  the read-only Temporal proxy, which passes only
#                                  read calls (temporal-readonly.tf)
#   postiz-team-postgres-readonly  PostgreSQL on the main RDS instance, where the team
#                                  signs in as "readonly" with an IAM token (db-readers.tf)
#
# Admins open them too: scripts/temporal-cli.sh and scripts/psql-readonly.sh.

locals {
  team_tunnels = {
    temporal-readonly = {
      what = "the read-only Temporal proxy"
      host = local.temporal_readonly_host
      port = 7233
    }
    postgres-readonly = {
      what = "PostgreSQL on the main RDS instance, for the readonly role"
      host = module.postgres_main.address
      port = 5432
    }
  }
}

# The Temporal tunnel went live as aws_ssm_document.temporal_readonly_tunnel
# (temporal-readonly.tf, 172ae69). Moved, not recreated: its name is taken while
# it exists.
moved {
  from = aws_ssm_document.temporal_readonly_tunnel
  to   = aws_ssm_document.team_tunnel["temporal-readonly"]
}

resource "aws_ssm_document" "team_tunnel" {
  for_each = local.team_tunnels

  name            = "postiz-team-${each.key}"
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "Port forward to ${each.value.what} (${each.value.host}:${each.value.port}) and nowhere else"
    sessionType   = "Port"
    parameters = {
      localPortNumber = {
        type           = "String"
        description    = "(Optional) Port on this machine. An open port is chosen at run time if not provided."
        allowedPattern = "^([0-9]|[1-9][0-9]{1,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])$"
        default        = "0"
      }
    }
    properties = {
      type            = "LocalPortForwarding"
      host            = each.value.host
      portNumber      = tostring(each.value.port)
      localPortNumber = "{{ localPortNumber }}"
    }
  })
}

# Added to the team's role like query-database-readonly (db-readers.tf).
data "aws_iam_policy_document" "team_tunnels" {
  statement {
    sid       = "TeamTunnelDocuments"
    actions   = ["ssm:StartSession"]
    resources = [for d in aws_ssm_document.team_tunnel : d.arn]
  }

  # Relayed by an ECS host: its network reaches the Temporal proxy and the database.
  statement {
    sid       = "TunnelThroughEcsHosts"
    actions   = ["ssm:StartSession"]
    resources = ["arn:aws:ec2:${var.region}:${var.aws_account_id}:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Name"
      values   = ["${local.name}-ecs-host"]
    }
  }

  # End or resume only their own sessions. Assumed-role sessions carry the tag
  # aws:ssmmessages:session-id = <role id>:<session name>, which is aws:userid.
  statement {
    sid       = "OwnSessions"
    actions   = ["ssm:TerminateSession", "ssm:ResumeSession"]
    resources = ["*"]
    condition {
      test     = "StringLike"
      variable = "ssm:resourceTag/aws:ssmmessages:session-id"
      values   = ["&{aws:userid}*"]
    }
  }

  # Newer Session Manager plugins open the data channel with the caller's
  # credentials; it also needs the session's one-time token from StartSession.
  statement {
    sid       = "TunnelDataChannel"
    actions   = ["ssmmessages:OpenDataChannel"]
    resources = ["arn:aws:ssm:${var.region}:${var.aws_account_id}:session/*"]
  }
}

resource "aws_iam_role_policy" "team_tunnels" {
  name   = "session-manager-tunnels"
  role   = var.team_readonly_role_name
  policy = data.aws_iam_policy_document.team_tunnels.json
}
