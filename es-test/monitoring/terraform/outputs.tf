output "instance_id" {
  value = aws_instance.kibana.id
}

output "private_ip" {
  value = aws_instance.kibana.private_ip
}

output "kibana_security_group_id" {
  value = aws_security_group.kibana.id
}
