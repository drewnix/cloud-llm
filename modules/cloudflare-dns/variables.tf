variable "zone_name" {
  description = "The Cloudflare zone/domain name, e.g. example.com"
  type        = string
}

variable "subdomain" {
  description = "Subdomain to create, e.g. llm for llm.example.com"
  type        = string
}

variable "alb_dns_name" {
  description = "DNS name of the ALB to point the subdomain to"
  type        = string
}

variable "alb_zone_id" {
  description = "Route53 zone ID of the ALB for alias-like records"
  type        = string
}

variable "certificate_arn" {
  description = "ARN of the ACM certificate to validate"
  type        = string
}

variable "acm_domain_validation_options" {
  description = "Domain validation options from the ACM certificate"
  type = set(object({
    domain_name            = string
    resource_record_name   = string
    resource_record_type   = string
    resource_record_value  = string
  }))
}

variable "project_name" {
  description = "Project name for resource tagging"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. dev, prod)"
  type        = string
}
