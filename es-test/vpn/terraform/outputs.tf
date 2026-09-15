output "instance_id" {
  value = aws_instance.pritunl.id
}

output "public_ip" {
  value = aws_eip.pritunl.public_ip
}

output "vpn_security_group_id" {
  value = aws_security_group.vpn.id
}
