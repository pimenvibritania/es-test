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
  }
}

provider "aws" {
  region = var.aws_region
}

# ---------------------------------------------------------------------------
# Networking: single public subnet, NO NAT Gateway (keeps cost at $0)
# ---------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "es-freetier-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "es-freetier-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]
  tags                    = { Name = "es-freetier-public-subnet" }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "es-freetier-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# Security Group: least privilege. No SSH (22) open — access via SSM only.
# ---------------------------------------------------------------------------

resource "aws_security_group" "es" {
  name        = "es-freetier-sg"
  description = "ElasticSearch single node - HTTPS only from allowed_cidr"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "ElasticSearch HTTPS API"
    from_port   = 9200
    to_port     = 9200
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  egress {
    description = "Allow all outbound (yum/apt repos, AWS API via IGW)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "es-freetier-sg" }
}

# ---------------------------------------------------------------------------
# IAM role for SSM Session Manager access (no SSH key pair needed)
# ---------------------------------------------------------------------------

resource "aws_iam_role" "ssm_role" {
  name = "es-freetier-ssm-role"
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
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Scoped policy: allow reading only the ES password parameter, nothing else
resource "aws_iam_role_policy" "read_es_password" {
  name = "read-es-password-param"
  role = aws_iam_role.ssm_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = aws_ssm_parameter.es_password.arn
    }]
  })
}

resource "aws_iam_instance_profile" "ssm_profile" {
  name = "es-freetier-ssm-profile"
  role = aws_iam_role.ssm_role.name
}

# ---------------------------------------------------------------------------
# Secret: elastic user password, generated randomly, stored encrypted.
# Uses AWS-managed KMS key (alias/aws/ssm) -> $0 cost (vs customer-managed CMK).
# ---------------------------------------------------------------------------

resource "random_password" "elastic_password" {
  length  = 20
  special = true
}

resource "aws_ssm_parameter" "es_password" {
  name  = "/elasticsearch/free-tier/elastic-password"
  type  = "SecureString"
  value = random_password.elastic_password.result
  # no key_id specified -> uses AWS-managed key alias/aws/ssm, free of charge
}

# ---------------------------------------------------------------------------
# EC2 instance: t3.micro (free-tier eligible), encrypted EBS (AWS-managed key)
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
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.es.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm_profile.name

  root_block_device {
    volume_size = 10
    volume_type = "gp3"
    encrypted   = true # AWS-managed key, no extra cost
  }

  user_data = templatefile("${path.module}/../scripts/bootstrap-elasticsearch.sh", {
    ssm_param_name = aws_ssm_parameter.es_password.name
    aws_region     = var.aws_region
  })

  tags = { Name = "es-freetier-node" }
}
