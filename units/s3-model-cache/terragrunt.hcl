# -----------------------------------------------------------------------------
# Unit: S3 Model Cache
# -----------------------------------------------------------------------------
# S3 bucket for caching LLM model weights with a VPC gateway endpoint.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/modules//s3-model-cache"
}

dependency "vpc" {
  config_path = values.vpc_path

  mock_outputs = {
    vpc_id                = "vpc-mock"
    private_route_table_ids = ["rtb-mock"]
  }
}

inputs = {
  vpc_id                  = dependency.vpc.outputs.vpc_id
  private_route_table_ids = dependency.vpc.outputs.private_route_table_ids
}
