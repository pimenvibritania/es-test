variable "aws_region" {
  type    = string
  default = "ap-southeast-3" # Jakarta -- must match the es-test ES cluster's region
}

variable "admin_cidr" {
  description = "CIDR allowed to reach the Pritunl web admin UI (443). Set to your own IP/32."
  type        = string
}

variable "instance_type" {
  type    = string
  # t3.micro (1GB RAM) was OOM-killing yum mid-transaction while installing
  # MongoDB + Pritunl (422MB installed size) -- confirmed via `free -h`
  # during a hung install (913MB total, ~400MB free at the time). t3.small
  # gives enough headroom for the install AND for MongoDB running normally
  # afterwards.
  default = "t3.small"
}
