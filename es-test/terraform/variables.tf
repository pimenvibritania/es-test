variable "aws_region" {
  type    = string
  default = "ap-southeast-3" # Jakarta
}

variable "allowed_cidr" {
  description = "CIDR allowed to reach the ES HTTPS API (9200) via the public path (e.g. through a VPN/bastion)."
  type        = string
}

variable "node_count" {
  description = "Number of ElasticSearch nodes in the cluster (3 recommended for quorum)."
  type        = number
  default     = 3
}

variable "instance_type" {
  type    = string
  default = "t3.small" # t3.micro is undersized for a 3-node cluster with real workloads
}
