output "vpc_id" {
  value = data.aws_vpc.default.id
}

output "subnet_ids" {
  value = data.aws_subnets.default.ids
}

output "alb_sg_id" {
  value = aws_security_group.alb_sg.id
}

output "svc_sg_id" {
  value = aws_security_group.svc_sg.id
}

