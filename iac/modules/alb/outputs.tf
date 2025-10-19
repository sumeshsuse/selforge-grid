output "alb_arn" {
  value = aws_lb.alb.arn
}

output "alb_dns_name" {
  value = aws_lb.alb.dns_name
}

output "grid_tg_arn" {
  value = aws_lb_target_group.grid_tg.arn
}

output "novnc_tg_arn" {
  value = aws_lb_target_group.novnc_tg.arn
}

output "listener_80_arn" {
  value = aws_lb_listener.http_80.arn
}

output "listener_7900_arn" {
  value = aws_lb_listener.http_7900.arn
}

