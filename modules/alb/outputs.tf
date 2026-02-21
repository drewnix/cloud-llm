output "alb_arn" {
  description = "ARN of the Application Load Balancer"
  value       = aws_lb.this.arn
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  description = "Canonical hosted zone ID of the ALB (for Route53/Cloudflare alias records)"
  value       = aws_lb.this.zone_id
}

output "vllm_target_group_arn" {
  description = "ARN of the vLLM API target group"
  value       = aws_lb_target_group.vllm.arn
}

output "webui_target_group_arn" {
  description = "ARN of the Open WebUI target group"
  value       = aws_lb_target_group.webui.arn
}

output "https_listener_arn" {
  description = "ARN of the HTTPS listener"
  value       = aws_lb_listener.https.arn
}
