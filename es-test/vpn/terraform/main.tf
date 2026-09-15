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
# Reads outputs directly from the es-test ElasticSearch cluster's local
# state file. Requires: `terraform apply` already run in ../../terraform
# (the es-test 3-node ES stack) so terraform.tfstate exists there.
# ---------------------------------------------------------------------------

data "terraform_remote_state" "es" {
  backend = "local"
  config = {
    path = "${path.module}/../../terraform/terraform.tfstate"
  }
}

# ---------------------------------------------------------------------------
# Pritunl VPN server (free community edition, OpenVPN-based)
# ---------------------------------------------------------------------------

resource "aws_security_group" "vpn" {
  name        = "pritunl-vpn-sg-es-test"
  description = "Pritunl VPN server: web UI (443) + OpenVPN (udp 1194)"
  vpc_id      = data.terraform_remote_state.es.outputs.vpc_id

  ingress {
    description = "Pritunl web admin UI"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "OpenVPN client tunnel"
    from_port   = 1194
    to_port     = 1194
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"] # auth happens at the VPN layer via client profile, not network ACL
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "pritunl-vpn-sg-es-test" }
}

# Allow VPN clients to reach the ES cluster's security group on 9200.
# The es-test ES nodes all share one SG (es-test-sg), so this single
# rule covers all 3 nodes at once.
resource "aws_security_group_rule" "vpn_to_es" {
  type                     = "ingress"
  from_port                = 9200
  to_port                  = 9200
  protocol                 = "tcp"
  security_group_id        = data.terraform_remote_state.es.outputs.es_security_group_id
  source_security_group_id = aws_security_group.vpn.id
  description              = "Allow ES access from Pritunl VPN clients (es-test)"
}

resource "aws_iam_role" "vpn_role" {
  name = "pritunl-vpn-ssm-role-es-test"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "vpn_ssm" {
  role       = aws_iam_role.vpn_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "vpn_profile" {
  name = "pritunl-vpn-ssm-profile-es-test"
  role = aws_iam_role.vpn_role.name
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_instance" "pritunl" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = data.terraform_remote_state.es.outputs.public_subnet_id
  vpc_security_group_ids = [aws_security_group.vpn.id]
  iam_instance_profile   = aws_iam_instance_profile.vpn_profile.name

  root_block_device {
    volume_size = 15
    volume_type = "gp3"
    encrypted   = true
  }

  # Same amazon-ssm-agent fix as the ES nodes -- this AMI build does not
  # ship it pre-installed, confirmed during the ES cluster provisioning.
  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail
    hostnamectl set-hostname pritunl-vpn
    dnf install -y https://s3.${var.aws_region}.amazonaws.com/amazon-ssm-${var.aws_region}/latest/linux_amd64/amazon-ssm-agent.rpm || \
      yum install -y https://s3.${var.aws_region}.amazonaws.com/amazon-ssm-${var.aws_region}/latest/linux_amd64/amazon-ssm-agent.rpm
    systemctl enable amazon-ssm-agent
    systemctl restart amazon-ssm-agent
  EOF

  tags = { Name = "pritunl-vpn-server-es-test" }
}

resource "aws_eip" "pritunl" {
  domain   = "vpc"
  instance = aws_instance.pritunl.id
  tags     = { Name = "pritunl-vpn-eip-es-test" }
}
