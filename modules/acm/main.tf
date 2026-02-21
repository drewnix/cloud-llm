terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# -----------------------------------------------------------------------------
# ACM Certificate
# -----------------------------------------------------------------------------
# Requests a TLS certificate for the given domain. DNS validation records are
# NOT created here — the Cloudflare DNS module is responsible for creating the
# CNAME validation records and calling aws_acm_certificate_validation. This is
# intentional to demonstrate cross-module dependencies.

resource "aws_acm_certificate" "this" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  tags = {
    Name = "${var.project_name}-${var.environment}-cert"
  }

  lifecycle {
    create_before_destroy = true
  }
}
