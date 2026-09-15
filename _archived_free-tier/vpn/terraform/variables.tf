variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "admin_cidr" {
  description = "CIDR allowed to reach the Pritunl web admin UI (443). Set to your own IP/32."
  type        = string
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}
