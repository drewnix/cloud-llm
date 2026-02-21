# -----------------------------------------------------------------------------
# Unit: ALB
# -----------------------------------------------------------------------------
# Internet-facing load balancer with HTTPS. Routes /v1/* to vLLM, rest to WebUI.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/modules//alb"
}

dependency "vpc" {
  config_path = values.vpc_path

  mock_outputs = {
    vpc_id            = "vpc-mock"
    public_subnet_ids = ["subnet-mock-1", "subnet-mock-2"]
  }
}

dependency "security_groups" {
  config_path = values.security_groups_path

  mock_outputs = {
    alb_security_group_id = "sg-mock"
  }
}

dependency "acm" {
  config_path = values.acm_path

  mock_outputs = {
    certificate_arn = "arn:aws:acm:us-east-1:000000000000:certificate/mock"
  }
}

inputs = {
  vpc_id                = dependency.vpc.outputs.vpc_id
  public_subnet_ids     = dependency.vpc.outputs.public_subnet_ids
  alb_security_group_id = dependency.security_groups.outputs.alb_security_group_id
  certificate_arn       = dependency.acm.outputs.certificate_arn
}
