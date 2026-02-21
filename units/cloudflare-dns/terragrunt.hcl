# -----------------------------------------------------------------------------
# Unit: Cloudflare DNS
# -----------------------------------------------------------------------------
# Multi-provider unit: creates ACM validation records and subdomain CNAME in Cloudflare.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/modules//cloudflare-dns"
}

dependency "acm" {
  config_path = values.acm_path

  mock_outputs = {
    certificate_arn           = "arn:aws:acm:us-east-1:000000000000:certificate/mock"
    domain_validation_options = []
  }
}

dependency "alb" {
  config_path = values.alb_path

  mock_outputs = {
    alb_dns_name = "mock-alb.us-east-1.elb.amazonaws.com"
    alb_zone_id  = "Z00000000000"
  }
}

inputs = {
  zone_name                     = values.zone_name
  subdomain                     = values.subdomain
  certificate_arn               = dependency.acm.outputs.certificate_arn
  acm_domain_validation_options = dependency.acm.outputs.domain_validation_options
  alb_dns_name                  = dependency.alb.outputs.alb_dns_name
  alb_zone_id                   = dependency.alb.outputs.alb_zone_id
}
