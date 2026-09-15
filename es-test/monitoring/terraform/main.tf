terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ---------------------------------------------------------------------------
# Reads outputs from both the ES cluster and the VPN stack's local state.
# Requires: `terraform apply` already run in ../../terraform (ES) AND
# ../../vpn/terraform (Pritunl VPN) so both terraform.tfstate files exist.
# ---------------------------------------------------------------------------

data "terraform_remote_state" "es" {
  backend = "local"
  config = {
    path = "${path.module}/../../terraform/terraform.tfstate"
  }
}

data "terraform_remote_state" "vpn" {
  backend = "local"
  config = {
    path = "${path.module}/../../vpn/terraform/terraform.tfstate"
  }
}

# ---------------------------------------------------------------------------
# Kibana -- reachable ONLY via the Pritunl VPN, same trust pattern as the ES
# cluster's own 9200 access rule (source_security_group_id = VPN's SG, never
# a public CIDR).
# ---------------------------------------------------------------------------

resource "aws_security_group" "kibana" {
  name        = "kibana-es-test-sg"
  description = "Kibana monitoring UI: HTTPS (5601) from VPN clients only"
  vpc_id      = data.terraform_remote_state.es.outputs.vpc_id
  tags        = { Name = "kibana-es-test-sg" }
}

resource "aws_security_group_rule" "kibana_from_vpn" {
  type                     = "ingress"
  from_port                = 5601
  to_port                  = 5601
  protocol                 = "tcp"
  security_group_id        = aws_security_group.kibana.id
  source_security_group_id = data.terraform_remote_state.vpn.outputs.vpn_security_group_id
  description              = "Kibana web UI, VPN clients only"
}

resource "aws_security_group_rule" "kibana_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.kibana.id
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Allow all outbound (via NAT for repo/AWS API/ES access)"
}

# Kibana needs to reach the ES cluster on 9200 -- add a rule to the ES SG
# trusting Kibana's SG (same self-referencing/source-SG pattern used
# elsewhere in this project, never a public CIDR).
resource "aws_security_group_rule" "es_from_kibana" {
  type                     = "ingress"
  from_port                = 9200
  to_port                  = 9200
  protocol                 = "tcp"
  security_group_id        = data.terraform_remote_state.es.outputs.es_security_group_id
  source_security_group_id = aws_security_group.kibana.id
  description              = "Allow ES access from Kibana (es-test monitoring)"
}

resource "aws_iam_role" "kibana_role" {
  name = "kibana-ssm-role-es-test"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "kibana_ssm" {
  role       = aws_iam_role.kibana_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Kibana needs the elastic user's password AND the shared CA cert
# (Secrets Manager) to authenticate against + trust the ES cluster.
resource "aws_iam_role_policy" "kibana_read_es_secret" {
  name = "kibana-read-es-secret"
  role = aws_iam_role.kibana_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          data.terraform_remote_state.es.outputs.kibana_system_secret_arn,
          data.terraform_remote_state.es.outputs.ca_bundle_secret_arn,
        ]
      },
      {
        # Both secrets above are encrypted with the ES cluster's
        # customer-managed KMS key -- decrypting the secret value also
        # requires kms:Decrypt on that key, not just secretsmanager:GetSecretValue.
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = data.terraform_remote_state.es.outputs.es_cmk_arn
      }
    ]
  })
}

resource "aws_iam_instance_profile" "kibana_profile" {
  name = "kibana-ssm-profile-es-test"
  role = aws_iam_role.kibana_role.name
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_instance" "kibana" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  # Private subnet, same as the ES nodes -- Kibana is reachable only through
  # the VPN, so it doesn't need a public IP at all.
  subnet_id              = data.terraform_remote_state.es.outputs.private_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.kibana.id]
  iam_instance_profile   = aws_iam_instance_profile.kibana_profile.name

  root_block_device {
    volume_size = 15
    volume_type = "gp3"
    encrypted   = true
  }

  # Minimal user_data, matching the ES nodes' pattern: just make sure SSM
  # agent is present and running so Ansible can reach it. All real Kibana
  # install/config happens in ../ansible/kibana.yml via SSM, not here.
  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail
    hostnamectl set-hostname kibana-es-test
    dnf install -y https://s3.${var.aws_region}.amazonaws.com/amazon-ssm-${var.aws_region}/latest/linux_amd64/amazon-ssm-agent.rpm || \
      yum install -y https://s3.${var.aws_region}.amazonaws.com/amazon-ssm-${var.aws_region}/latest/linux_amd64/amazon-ssm-agent.rpm
    systemctl enable amazon-ssm-agent
    systemctl restart amazon-ssm-agent
  EOF

  tags = { Name = "kibana-es-test" }
}
