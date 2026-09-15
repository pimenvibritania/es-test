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

data "terraform_remote_state" "es" {
  backend = "local"
  config = {
    path = "${path.module}/../../terraform/terraform.tfstate"
  }
}

# ---------------------------------------------------------------------------
# SNS topic + email subscription -- single delivery pipe for every alarm
# below, whether the metric comes from native CloudWatch (EC2 host-level) or
# from the custom cron-pushed ES cluster health metric.
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name = "es-test-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
  # NOTE: SNS email subscriptions require manual confirmation -- AWS sends a
  # "Subscription Confirmation" email to alert_email with a confirm link.
  # No alarm will actually deliver until that link is clicked. This is an
  # AWS API limitation, not something Terraform/this code can automate away.
}

# ---------------------------------------------------------------------------
# Infra-level alarms (native CloudWatch, no agent needed) -- one set per ES
# node, covering CPU and instance status checks (AWS's own health check,
# catches things like hardware failure / network reachability loss).
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "es_node_cpu_high" {
  for_each = data.terraform_remote_state.es.outputs.instance_ids

  alarm_name          = "es-test-node-${each.key}-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "ES node ${each.key} CPU > 80% for 15 minutes"
  dimensions          = { InstanceId = each.value }
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "breaching" # instance stopped/unreachable should alert, not go silent
}

resource "aws_cloudwatch_metric_alarm" "es_node_status_check_failed" {
  for_each = data.terraform_remote_state.es.outputs.instance_ids

  alarm_name          = "es-test-node-${each.key}-status-check-failed"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "ES node ${each.key} failed AWS instance/system status check"
  dimensions          = { InstanceId = each.value }
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "breaching"
}

# ---------------------------------------------------------------------------
# ES-internal alarm: cluster health status.
# CloudWatch has no native visibility into ES's own health -- a custom cron
# script on each node polls _cluster/health and pushes a custom metric via
# `aws cloudwatch put-metric-data`. See ../ansible/es-metrics-cron.yml.
# Metric value: 0=green, 1=yellow, 2=red (numeric so CloudWatch can threshold it).
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "es_cluster_health_not_green" {
  alarm_name          = "es-test-cluster-health-not-green"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ClusterHealthStatus"
  namespace           = "ESPaidTier/Custom"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0 # >0 means yellow or red
  alarm_description   = "ES cluster status is yellow or red (0=green,1=yellow,2=red)"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "breaching" # no data = cron/cluster down = alert, don't go silent
}

# IAM policy so ES nodes can push the custom metric. Attached to the
# existing ES role (data source, not managed here) via a standalone policy
# resource -- this only ADDS permissions, doesn't touch the role's existing
# policies from ../../terraform.
resource "aws_iam_role_policy" "es_cloudwatch_put_metric" {
  name = "es-cloudwatch-put-metric"
  role = data.terraform_remote_state.es.outputs.es_iam_role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["cloudwatch:PutMetricData"]
      Resource = "*" # PutMetricData does not support resource-level permissions
      Condition = {
        StringEquals = {
          "cloudwatch:namespace" = "ESPaidTier/Custom"
        }
      }
    }]
  })
}
