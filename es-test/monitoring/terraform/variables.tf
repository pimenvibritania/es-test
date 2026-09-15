variable "aws_region" {
  type    = string
  default = "ap-southeast-3" # Jakarta -- must match the paid-tier ES cluster's region
}

variable "instance_type" {
  type    = string
  default = "t3.small" # Kibana is memory-hungry; t3.micro tends to OOM under real dashboards
}
