# -----------------------------------------------------------------------------
# Unit: VPC
# -----------------------------------------------------------------------------
# Network foundation - VPC, subnets, IGW, NAT gateway.
# No dependencies - this is the base layer.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/modules//vpc"
}

inputs = {
  vpc_cidr             = values.vpc_cidr
  public_subnet_cidrs  = values.public_subnet_cidrs
  private_subnet_cidrs = values.private_subnet_cidrs
  availability_zones   = values.availability_zones
}
