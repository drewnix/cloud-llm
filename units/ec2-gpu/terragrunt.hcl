# -----------------------------------------------------------------------------
# Unit: EC2 GPU
# -----------------------------------------------------------------------------
# The main GPU instance running vLLM + Open WebUI. Has the most dependencies,
# demonstrating how Terragrunt Stacks handle complex dependency graphs.

feature "deploy" {
  default = true
}

exclude {
  if      = !feature.deploy.value
  actions = ["apply", "destroy", "plan"]
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/modules//ec2-gpu"
}

# Five dependencies - paths are passed in from the stack file
dependency "vpc" {
  config_path = values.vpc_path

  mock_outputs = {
    public_subnet_ids = ["subnet-mock-1", "subnet-mock-2"]
  }
}

dependency "security_groups" {
  config_path = values.security_groups_path

  mock_outputs = {
    ec2_security_group_id = "sg-mock"
  }
}

dependency "iam" {
  config_path = values.iam_path

  mock_outputs = {
    instance_profile_name = "mock-profile"
  }
}

dependency "alb" {
  config_path = values.alb_path

  mock_outputs = {
    vllm_target_group_arn  = "arn:aws:elasticloadbalancing:us-east-1:000000000000:targetgroup/mock-vllm/mock"
    webui_target_group_arn = "arn:aws:elasticloadbalancing:us-east-1:000000000000:targetgroup/mock-webui/mock"
  }
}

dependency "s3_model_cache" {
  config_path = values.s3_model_cache_path

  mock_outputs = {
    bucket_name = "mock-model-cache-bucket"
  }
}

inputs = {
  # Instance configuration (from stack values, sourced from env.hcl)
  instance_type   = values.instance_type
  use_spot        = values.use_spot
  spot_max_price  = values.spot_max_price
  ebs_volume_size = values.ebs_volume_size
  ebs_volume_type = values.ebs_volume_type
  vllm_port       = values.vllm_port
  webui_port      = values.webui_port

  # Model configuration (from stack values, sourced from common.hcl)
  model_id   = values.model_id
  model_name = values.model_name

  # Dependency outputs
  subnet_id              = dependency.vpc.outputs.public_subnet_ids[0]
  ec2_security_group_id  = dependency.security_groups.outputs.ec2_security_group_id
  instance_profile_name  = dependency.iam.outputs.instance_profile_name
  vllm_target_group_arn  = dependency.alb.outputs.vllm_target_group_arn
  webui_target_group_arn = dependency.alb.outputs.webui_target_group_arn
  model_cache_bucket     = dependency.s3_model_cache.outputs.bucket_name
}
