terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_availability_zones" "available" {
  state = "available"
}

# ---------------------------------------------------------------------------
# Networking: VPC with public subnet (NAT+bastion path) + private subnets
# across 2 AZs for the ES nodes.
# ---------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = "10.1.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "es-test-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "es-test-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.1.0.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]
  tags                    = { Name = "es-test-public" }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.1.${count.index + 1}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = { Name = "es-test-private-${count.index}" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "es-test-nat-eip" }
}

# NAT Gateway -- the main paid component that free-tier avoids.
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags          = { Name = "es-test-nat" }
  depends_on    = [aws_internet_gateway.igw]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "es-test-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "es-test-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ---------------------------------------------------------------------------
# Security Groups
# ---------------------------------------------------------------------------

resource "aws_security_group" "es" {
  name        = "es-test-sg"
  description = "ElasticSearch 3-node cluster: HTTP layer from allowed_cidr, transport layer node-to-node only"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "es-test-sg" }

  # NOTE: intentionally no inline ingress/egress blocks here. Mixing inline
  # ingress/egress arguments on aws_security_group with separate
  # aws_security_group_rule resources for the SAME group is an explicit
  # anti-pattern (AWS provider docs warn about this) -- Terraform's inline
  # block fully overwrites all rules on every apply that touches the group,
  # which silently deleted the transport_self rule below whenever
  # allowed_cidr changed. All rules are now separate aws_security_group_rule
  # resources so they don't stomp on each other.
}

resource "aws_security_group_rule" "es_http_ingress" {
  type              = "ingress"
  description       = "ElasticSearch HTTPS API"
  from_port         = 9200
  to_port           = 9200
  protocol          = "tcp"
  security_group_id = aws_security_group.es.id
  cidr_blocks       = [var.allowed_cidr]
}

resource "aws_security_group_rule" "es_egress_all" {
  type              = "egress"
  description       = "Allow all outbound (via NAT for repo/AWS API access)"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.es.id
  cidr_blocks       = ["0.0.0.0/0"]
}

# Self-referencing rule for transport layer (9300): only members of this SG
# can reach each other on 9300 -- never exposed externally.
resource "aws_security_group_rule" "transport_self" {
  type                     = "ingress"
  from_port                = 9300
  to_port                  = 9300
  protocol                 = "tcp"
  security_group_id        = aws_security_group.es.id
  source_security_group_id = aws_security_group.es.id
  description              = "Inter-node transport layer, self-referencing only"
}

# ---------------------------------------------------------------------------
# KMS: customer-managed CMK (paid, ~$1/mo) for EBS + Secrets Manager --
# gives us key rotation & granular CloudTrail audit vs the free AWS-managed key.
# ---------------------------------------------------------------------------

resource "aws_kms_key" "es_cmk" {
  description             = "CMK for ES es-test cluster EBS + secrets"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = { Name = "es-test-cmk" }
}

resource "aws_kms_alias" "es_cmk_alias" {
  name          = "alias/es-test-cmk"
  target_key_id = aws_kms_key.es_cmk.key_id
}

# ---------------------------------------------------------------------------
# IAM role: SSM access + scoped Secrets Manager read + KMS decrypt
# ---------------------------------------------------------------------------

resource "aws_iam_role" "es_role" {
  name = "es-test-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.es_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "read_secret" {
  name = "read-es-secret"
  role = aws_iam_role.es_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          aws_secretsmanager_secret.es_password.arn,
          aws_secretsmanager_secret.kibana_system_password.arn,
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = aws_kms_key.es_cmk.arn
      }
    ]
  })
}

resource "aws_iam_instance_profile" "es_profile" {
  name = "es-test-profile"
  role = aws_iam_role.es_role.name
}

# ---------------------------------------------------------------------------
# Secret: elastic password in Secrets Manager (supports rotation, unlike
# the SSM Parameter Store used in free-tier)
# ---------------------------------------------------------------------------

resource "random_password" "elastic_password" {
  length  = 20
  special = true
}

resource "random_password" "kibana_system_password" {
  length  = 20
  special = true
}

resource "aws_secretsmanager_secret" "es_password" {
  name       = "elasticsearch/es-test/elastic-password"
  kms_key_id = aws_kms_key.es_cmk.arn
  # 0 = force-delete immediately on destroy, no 30-day recovery window.
  # AWS's default 30-day window blocks recreating a secret with the same
  # name right after a destroy (InvalidRequestException: "already scheduled
  # for deletion"), which breaks iterative destroy/recreate workflows like
  # this take-home exercise. Fine trade-off here since this is a test/demo
  # environment, not a production secret with real audit/compliance needs.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "es_password" {
  secret_id     = aws_secretsmanager_secret.es_password.id
  secret_string = random_password.elastic_password.result
}

resource "aws_secretsmanager_secret" "kibana_system_password" {
  name                    = "elasticsearch/es-test/kibana-system-password"
  kms_key_id              = aws_kms_key.es_cmk.arn
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "kibana_system_password" {
  secret_id     = aws_secretsmanager_secret.kibana_system_password.id
  secret_string = random_password.kibana_system_password.result
}

# ---------------------------------------------------------------------------
# Shared CA for node-to-node transport TLS (self-signed, generated by
# Terraform's tls provider so every node shares the same trust root).
# ---------------------------------------------------------------------------

resource "tls_private_key" "ca_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "ca_cert" {
  private_key_pem = tls_private_key.ca_key.private_key_pem
  subject {
    common_name  = "es-test-ca"
    organization = "internal"
  }
  validity_period_hours = 8760
  is_ca_certificate     = true
  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "digital_signature",
    "key_encipherment",
  ]
}

# Store CA cert + key in Secrets Manager so every node can fetch it at boot
# and generate its own node certificate signed by the same CA.
resource "aws_secretsmanager_secret" "ca_bundle" {
  name                    = "elasticsearch/es-test/ca-bundle"
  kms_key_id              = aws_kms_key.es_cmk.arn
  recovery_window_in_days = 0 # see comment on es_password above
}

resource "aws_secretsmanager_secret_version" "ca_bundle" {
  secret_id = aws_secretsmanager_secret.ca_bundle.id
  secret_string = jsonencode({
    ca_cert = tls_self_signed_cert.ca_cert.cert_pem
    ca_key  = tls_private_key.ca_key.private_key_pem
  })
}

resource "aws_iam_role_policy" "read_ca_bundle" {
  name = "read-ca-bundle"
  role = aws_iam_role.es_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.ca_bundle.arn
    }]
  })
}

# Required for the community.aws.aws_ssm Ansible connection plugin, which
# uses an S3 bucket as a file-transfer relay (no SSH, pure SSM API calls).
resource "aws_s3_bucket" "ansible_ssm_transfer" {
  bucket        = "es-test-ansible-transfer-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = { Name = "es-test-ansible-ssm-transfer" }
}

resource "aws_s3_bucket_public_access_block" "ansible_ssm_transfer" {
  bucket                  = aws_s3_bucket.ansible_ssm_transfer.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_role_policy" "ansible_ssm_transfer" {
  name = "ansible-ssm-s3-transfer"
  role = aws_iam_role.es_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject", "s3:GetEncryptionConfiguration"]
      Resource = "${aws_s3_bucket.ansible_ssm_transfer.arn}/*"
    }]
  })
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# 3x EC2 nodes across 2 AZs (for_each so it's trivial to scale node_count)
# ---------------------------------------------------------------------------

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_instance" "es_node" {
  for_each = toset([for i in range(var.node_count) : tostring(i)])

  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private[tonumber(each.key) % 2].id
  vpc_security_group_ids = [aws_security_group.es.id]
  iam_instance_profile   = aws_iam_instance_profile.es_profile.name

  root_block_device {
    volume_size = 15
    volume_type = "gp3"
    encrypted   = true
    kms_key_id  = aws_kms_key.es_cmk.arn
  }

  # Deliberately minimal: no ElasticSearch install/config here. All app-level
  # provisioning (yum install, vm.max_map_count, TLS certs, discovery seed
  # hosts, service start) is handled by the Ansible playbook in ../ansible/
  # via SSM Session Manager -- same access pattern as the VPN role. This lets
  # Ansible see every node's private IP up front and populate a *correct*
  # discovery-file peer list, which the old inline user_data script could not
  # do (each node only knew its own IP at boot time).
  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail
    hostnamectl set-hostname "${each.key == "0" ? "es-node-0" : each.key == "1" ? "es-node-1" : "es-node-2"}"
    echo "es-node-${each.key} ready for Ansible provisioning via SSM." > /etc/motd
    # This AMI build does NOT ship amazon-ssm-agent pre-installed (confirmed:
    # "Unit amazon-ssm-agent.service not found" on first boot) -- install it
    # explicitly via the official RPM, since it's required for SSM-based
    # Ansible provisioning (no SSH keys anywhere in this design).
    dnf install -y https://s3.${var.aws_region}.amazonaws.com/amazon-ssm-${var.aws_region}/latest/linux_amd64/amazon-ssm-agent.rpm || \
      yum install -y https://s3.${var.aws_region}.amazonaws.com/amazon-ssm-${var.aws_region}/latest/linux_amd64/amazon-ssm-agent.rpm
    systemctl enable amazon-ssm-agent
    systemctl restart amazon-ssm-agent
  EOF

  tags = { Name = "es-test-node-${each.key}" }
}
