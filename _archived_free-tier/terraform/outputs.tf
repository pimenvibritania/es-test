output "instance_id" {
  value = aws_instance.es_node.id
}

output "public_ip" {
  value = aws_instance.es_node.public_ip
}

output "elastic_password_ssm_path" {
  value       = aws_ssm_parameter.es_password.name
  description = "Fetch via: aws ssm get-parameter --name <this> --with-decryption --query Parameter.Value --output text"
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}

output "es_security_group_id" {
  value = aws_security_group.es.id
}
