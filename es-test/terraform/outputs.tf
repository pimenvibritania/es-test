output "instance_ids" {
  value = { for k, v in aws_instance.es_node : k => v.id }
}

output "node_private_ips" {
  value = { for k, v in aws_instance.es_node : k => v.private_ip }
}

output "elastic_secret_arn" {
  value = aws_secretsmanager_secret.es_password.arn
}

output "kibana_system_secret_arn" {
  value = aws_secretsmanager_secret.kibana_system_password.arn
}

output "ansible_transfer_bucket" {
  value = aws_s3_bucket.ansible_ssm_transfer.id
}

output "ca_bundle_secret_arn" {
  value = aws_secretsmanager_secret.ca_bundle.arn
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}

output "private_subnet_ids" {
  value = [for s in aws_subnet.private : s.id]
}

output "es_security_group_id" {
  value = aws_security_group.es.id
}

output "es_cmk_arn" {
  value = aws_kms_key.es_cmk.arn
}

output "es_iam_role_name" {
  value = aws_iam_role.es_role.name
}
