variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "allowed_cidr" {
  description = "CIDR allowed to reach ElasticSearch HTTPS API (9200). Set to your own IP/32."
  type        = string
  # No default on purpose -- force the caller to pass their own IP explicitly.
}
