# -----------------------------------------------------------------------------
# Unit: Security Groups
# -----------------------------------------------------------------------------
# ALB and EC2 security groups. EC2 only accepts traffic from the ALB.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/modules//security-groups"
}

dependency "vpc" {
  config_path = values.vpc_path

  mock_outputs = {
    vpc_id = "vpc-mock"
  }
}

inputs = {
  vpc_id            = dependency.vpc.outputs.vpc_id
  allowed_ssh_cidrs = values.allowed_ssh_cidrs
}
