# -----------------------------------------------------------------------------
# Root Terragrunt Configuration
# -----------------------------------------------------------------------------
# This is the root config that all unit templates inherit from via include.
# It configures:
#   1. Remote state storage (S3 with native locking)
#   2. AWS provider generation
#   3. Common input variables (tags, project name)
# -----------------------------------------------------------------------------

# Load the hierarchy of variable files
locals {
  common_vars = read_terragrunt_config(find_in_parent_folders("common.hcl"))
  env_vars    = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  region_vars = read_terragrunt_config(find_in_parent_folders("region.hcl"))

  project_name = local.common_vars.locals.project_name
  environment  = local.env_vars.locals.environment
  aws_region   = local.region_vars.locals.aws_region
}

# -----------------------------------------------------------------------------
# Remote State Configuration
# -----------------------------------------------------------------------------
# S3 backend with native state locking (no DynamoDB table needed).
# The state path mirrors the directory structure so each module gets its own
# state file. On first run, use --backend-bootstrap to create the S3 bucket.
remote_state {
  backend = "s3"
  config = {
    encrypt      = true
    bucket       = "${local.project_name}-${local.environment}-terraform-state"
    key          = "${path_relative_to_include()}/terraform.tfstate"
    region       = local.aws_region
    use_lockfile = true
  }
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}

# -----------------------------------------------------------------------------
# AWS Provider Generation
# -----------------------------------------------------------------------------
# Generate an AWS provider block in every module. The region comes from the
# hierarchy (region.hcl), so moving to a new region is just a config change.
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "aws" {
      region = "${local.aws_region}"

      default_tags {
        tags = {
          Project     = "${local.project_name}"
          Environment = "${local.environment}"
          ManagedBy   = "terragrunt"
        }
      }
    }
  EOF
}

# -----------------------------------------------------------------------------
# Common Inputs
# -----------------------------------------------------------------------------
# These inputs are available to every module. Individual module terragrunt.hcl
# files merge their own inputs on top of these.
inputs = {
  project_name = local.project_name
  environment  = local.environment
  aws_region   = local.aws_region
}
