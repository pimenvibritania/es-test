variable "aws_region" {
  type    = string
  default = "ap-southeast-3" # Jakarta -- must match the paid-tier ES cluster's region
}

variable "alert_email" {
  description = "Email address to receive SNS alarm notifications. Requires manual confirmation via the link AWS emails after apply."
  type        = string
}
