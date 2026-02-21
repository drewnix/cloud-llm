terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# -----------------------------------------------------------------------------
# Look up the Cloudflare zone by name
# -----------------------------------------------------------------------------
data "cloudflare_zones" "this" {
  filter {
    name = var.zone_name
  }
}

locals {
  zone_id = data.cloudflare_zones.this.zones[0].id
}

# -----------------------------------------------------------------------------
# ACM Certificate DNS Validation Records
# -----------------------------------------------------------------------------
# These records prove to AWS that we own the domain so the ACM certificate
# can be issued. They MUST be proxied = false (grey cloud / DNS only) so that
# AWS can read the raw DNS values during validation.
# -----------------------------------------------------------------------------
resource "cloudflare_record" "acm_validation" {
  for_each = {
    for opt in var.acm_domain_validation_options : opt.domain_name => opt
  }

  zone_id = local.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  value   = trimsuffix(each.value.resource_record_value, ".")
  ttl     = 60
  proxied = false
}

# -----------------------------------------------------------------------------
# Wait for ACM certificate to be validated
# -----------------------------------------------------------------------------
resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = var.certificate_arn
  validation_record_fqdns = [for record in cloudflare_record.acm_validation : record.hostname]

  depends_on = [cloudflare_record.acm_validation]
}

# -----------------------------------------------------------------------------
# Subdomain CNAME pointing to the ALB
# -----------------------------------------------------------------------------
# proxied = false (DNS only) so that the ALB handles TLS termination with
# the ACM certificate. Cloudflare CNAME flattening is not needed here since
# this is a subdomain, not the apex.
# -----------------------------------------------------------------------------
resource "cloudflare_record" "subdomain" {
  zone_id = local.zone_id
  name    = var.subdomain
  type    = "CNAME"
  value   = var.alb_dns_name
  ttl     = 1
  proxied = false
}
