# -----------------------------------------------------------------------------
# Unit: ACM Certificate
# -----------------------------------------------------------------------------
# Requests a TLS certificate. DNS validation is handled by the cloudflare-dns unit.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/modules//acm"
}

inputs = {
  domain_name = values.domain_name
}
