output "alb_dns_name" {
  description = "ALB DNS name"
  value       = module.alb.alb_dns_name
}

output "grid_url" {
  description = "Use this in tests (-Dgrid.url)"
  value       = "http://${module.alb.alb_dns_name}"
}

output "novnc_url" {
  description = "Open this in browser for VNC"
  value       = "http://${module.alb.alb_dns_name}:7900"
}

