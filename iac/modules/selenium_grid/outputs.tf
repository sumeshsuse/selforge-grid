output "instance_id" {
  value = aws_instance.grid.id
}

output "public_ip" {
  value = coalesce(try(aws_eip.grid[0].public_ip, null), aws_instance.grid.public_ip)
}

output "public_dns" {
  value = aws_instance.grid.public_dns
}

output "security_group_id" {
  value = aws_security_group.grid_sg.id
}

output "grid_url" {
  value = "http://${coalesce(try(aws_eip.grid[0].public_ip, null), aws_instance.grid.public_ip)}:4444"
}

output "novnc_url_chrome" {
  value = "http://${coalesce(try(aws_eip.grid[0].public_ip, null), aws_instance.grid.public_ip)}:7900"
}

output "route53_fqdn" {
  value       = try(aws_route53_record.grid[0].fqdn, null)
  description = "DNS name if Route53 record created"
}
