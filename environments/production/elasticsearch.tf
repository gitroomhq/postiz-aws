# Temporal visibility store (Railway "Elasticsearch", ES 8.19.10).
#
# Why not Postgres visibility or Amazon OpenSearch yet:
#   - Postiz finds a post's running workflow with
#     workflow.list('postId="..." AND ExecutionStatus="Running"') before deleting
#     or re-scheduling it (posts.service.ts deletePost / startWorkflow).
#   - Switching an existing cluster to SQL visibility leaves already-running
#     workflows unlisted, and `tdbg workflow refresh-tasks` does not rebuild them
#     on 1.28 (tested), so deleted or drafted posts could still publish.
#   - Amazon OpenSearch is only supported from Temporal 1.30.1.
# So the index moves as-is (scripts/es-copy-index.py) onto one EC2 host with a
# separate EBS data volume and daily snapshots.

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

ephemeral "random_password" "elasticsearch" {
  length  = 40
  special = false
}

locals {
  es_az = module.network.azs[0]
}

resource "aws_secretsmanager_secret" "elasticsearch" {
  name        = "${local.secret_prefix}/managed/elasticsearch"
  description = "Elasticsearch elastic user, written by Terraform"
}

resource "aws_secretsmanager_secret_version" "elasticsearch" {
  secret_id = aws_secretsmanager_secret.elasticsearch.id
  secret_string_wo = jsonencode({
    username = "elastic"
    password = ephemeral.random_password.elasticsearch.result
    url      = "http://elastic:${ephemeral.random_password.elasticsearch.result}@${local.elasticsearch_host}:9200"
  })
  secret_string_wo_version = var.elasticsearch_password_version
}

resource "aws_cloudwatch_log_group" "elasticsearch" {
  name              = "/ec2/${local.name}/elasticsearch"
  retention_in_days = var.log_retention_days
}

resource "aws_security_group" "elasticsearch" {
  name        = "${local.name}-elasticsearch"
  description = "Elasticsearch for Temporal visibility"
  vpc_id      = module.network.vpc_id
  tags        = { Name = "${local.name}-elasticsearch" }
}

resource "aws_vpc_security_group_ingress_rule" "es_from_temporal" {
  security_group_id            = aws_security_group.elasticsearch.id
  referenced_security_group_id = aws_security_group.temporal.id
  ip_protocol                  = "tcp"
  from_port                    = 9200
  to_port                      = 9200
  description                  = "Temporal visibility"
}

resource "aws_vpc_security_group_ingress_rule" "es_from_ops" {
  security_group_id            = aws_security_group.elasticsearch.id
  referenced_security_group_id = module.ecs_cluster.instance_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 9200
  to_port                      = 9200
  description                  = "Migration toolbox copying the Railway index"
}

resource "aws_vpc_security_group_egress_rule" "es_all" {
  security_group_id = aws_security_group.elasticsearch.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Image pulls, OS updates, Secrets Manager, CloudWatch, SSM"
}

# --- host IAM -------------------------------------------------------------------------

data "aws_iam_policy_document" "es_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "elasticsearch" {
  name               = "${local.name}-elasticsearch"
  description        = "Elasticsearch host of ${local.name}"
  assume_role_policy = data.aws_iam_policy_document.es_trust.json
}

resource "aws_iam_role_policy_attachment" "es_ssm" {
  role       = aws_iam_role.elasticsearch.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "es_host" {
  statement {
    sid       = "ReadOwnPassword"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.elasticsearch.arn]
  }
  statement {
    sid       = "ContainerLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["${aws_cloudwatch_log_group.elasticsearch.arn}:*"]
  }
}

resource "aws_iam_role_policy" "es_host" {
  name   = "elasticsearch-host"
  role   = aws_iam_role.elasticsearch.id
  policy = data.aws_iam_policy_document.es_host.json
}

resource "aws_iam_instance_profile" "elasticsearch" {
  name = "${local.name}-elasticsearch"
  role = aws_iam_role.elasticsearch.name
}

# --- host + data volume ---------------------------------------------------------------

resource "aws_ebs_volume" "elasticsearch" {
  availability_zone = local.es_az
  size              = var.elasticsearch_volume_size
  type              = "gp3"
  encrypted         = true

  tags = {
    Name     = "${local.name}-elasticsearch-data"
    Snapshot = "${local.name}-elasticsearch"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_instance" "elasticsearch" {
  ami                         = data.aws_ssm_parameter.al2023_arm64.insecure_value
  instance_type               = var.elasticsearch_instance_type
  subnet_id                   = module.network.public_subnet_ids_by_az[local.es_az]
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.elasticsearch.id]
  iam_instance_profile        = aws_iam_instance_profile.elasticsearch.name
  disable_api_termination     = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  maintenance_options {
    auto_recovery = "default"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  user_data = templatefile("${path.module}/elasticsearch-user-data.sh.tftpl", {
    region         = var.region
    volume_id      = aws_ebs_volume.elasticsearch.id
    secret_arn     = aws_secretsmanager_secret.elasticsearch.arn
    log_group      = aws_cloudwatch_log_group.elasticsearch.name
    es_version     = var.elasticsearch_version
    es_heap        = var.elasticsearch_heap
    secret_version = var.elasticsearch_password_version
    # referenced so the password exists before the host first boots and reads it
    secret_resource = aws_secretsmanager_secret_version.elasticsearch.id
  })

  tags = { Name = "${local.name}-elasticsearch" }

  lifecycle {
    # a newer AMI or edited boot script must not silently replace the host;
    # replace it on purpose with: terraform apply -replace=aws_instance.elasticsearch
    ignore_changes = [ami, user_data]
  }
}

resource "aws_volume_attachment" "elasticsearch" {
  device_name                    = "/dev/sdf"
  volume_id                      = aws_ebs_volume.elasticsearch.id
  instance_id                    = aws_instance.elasticsearch.id
  stop_instance_before_detaching = true
}

# elasticsearch.postiz.internal -> host private IP
resource "aws_service_discovery_service" "elasticsearch" {
  name = "elasticsearch"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.internal.id
    routing_policy = "MULTIVALUE"
    dns_records {
      type = "A"
      ttl  = 60
    }
  }
}

resource "aws_service_discovery_instance" "elasticsearch" {
  instance_id = "elasticsearch-1"
  service_id  = aws_service_discovery_service.elasticsearch.id
  attributes = {
    AWS_INSTANCE_IPV4 = aws_instance.elasticsearch.private_ip
  }
}

# --- daily snapshots of the data volume, 7 kept ------------------------------------------

data "aws_iam_policy_document" "dlm_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.aws_account_id]
    }
  }
}

resource "aws_iam_role" "dlm" {
  name               = "${local.name}-dlm"
  description        = "Data Lifecycle Manager snapshots for ${local.name}"
  assume_role_policy = data.aws_iam_policy_document.dlm_trust.json
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "elasticsearch" {
  description        = "Daily snapshots of the Elasticsearch data volume"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags = {
      Snapshot = "${local.name}-elasticsearch"
    }

    schedule {
      name      = "daily"
      copy_tags = true

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["05:00"]
      }

      retain_rule {
        count = 7
      }
    }
  }
}
