output "validated_certificate_arn" {
  description = "ARN of the validated ACM certificate"
  value       = aws_acm_certificate_validation.this.certificate_arn
}

output "fqdn" {
  description = "Fully qualified domain name of the subdomain (e.g. llm.example.com)"
  value       = "${var.subdomain}.${var.zone_name}"
}
