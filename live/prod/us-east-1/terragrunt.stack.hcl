# =============================================================================
# Prod Environment Stack - us-east-1
# =============================================================================
# Production LLM infrastructure. Same units as dev, different values.
# The only differences: VPC CIDRs (10.1.x.x) and env.hcl settings
# (on-demand instances, larger EBS, g5.2xlarge).
#
# Deploy:  cd live/prod/us-east-1 && terragrunt stack run apply
# Destroy: cd live/prod/us-east-1 && terragrunt stack run destroy
# =============================================================================

locals {
  common_vars = read_terragrunt_config(find_in_parent_folders("common.hcl"))
  env_vars    = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

# -----------------------------------------------------------------------------
# Network Layer
# -----------------------------------------------------------------------------

unit "vpc" {
  source = "../../../units/vpc"
  path   = "vpc"

  values = {
    vpc_cidr             = "10.1.0.0/16"
    public_subnet_cidrs  = ["10.1.1.0/24", "10.1.2.0/24"]
    private_subnet_cidrs = ["10.1.10.0/24", "10.1.11.0/24"]
    availability_zones   = ["us-east-1a", "us-east-1b"]
  }
}

unit "security_groups" {
  source = "../../../units/security-groups"
  path   = "security-groups"

  values = {
    vpc_path          = "../vpc"
    allowed_ssh_cidrs = []
  }
}

# -----------------------------------------------------------------------------
# Supporting Infrastructure
# -----------------------------------------------------------------------------

unit "acm" {
  source = "../../../units/acm"
  path   = "acm"

  values = {
    domain_name = "${local.common_vars.locals.subdomain}.${local.common_vars.locals.cloudflare_zone_name}"
  }
}

unit "s3_model_cache" {
  source = "../../../units/s3-model-cache"
  path   = "s3-model-cache"

  values = {
    vpc_path = "../vpc"
  }
}

unit "iam" {
  source = "../../../units/iam"
  path   = "iam"

  values = {
    s3_model_cache_path = "../s3-model-cache"
  }
}

unit "alb" {
  source = "../../../units/alb"
  path   = "alb"

  values = {
    vpc_path             = "../vpc"
    security_groups_path = "../security-groups"
    acm_path             = "../acm"
  }
}

unit "cloudflare_dns" {
  source = "../../../units/cloudflare-dns"
  path   = "cloudflare-dns"

  values = {
    zone_name = local.common_vars.locals.cloudflare_zone_name
    subdomain = local.common_vars.locals.subdomain
    acm_path  = "../acm"
    alb_path  = "../alb"
  }
}

# -----------------------------------------------------------------------------
# GPU Compute
# -----------------------------------------------------------------------------

unit "ec2_gpu" {
  source = "../../../units/ec2-gpu"
  path   = "ec2-gpu"

  values = {
    # Dependency paths
    vpc_path             = "../vpc"
    security_groups_path = "../security-groups"
    iam_path             = "../iam"
    alb_path             = "../alb"
    s3_model_cache_path  = "../s3-model-cache"

    # Instance config (from env.hcl)
    instance_type   = local.env_vars.locals.instance_type
    use_spot        = local.env_vars.locals.use_spot
    spot_max_price  = local.env_vars.locals.spot_max_price
    ebs_volume_size = local.env_vars.locals.ebs_volume_size
    ebs_volume_type = local.env_vars.locals.ebs_volume_type
    vllm_port       = local.env_vars.locals.vllm_port
    webui_port      = local.env_vars.locals.webui_port

    # Model config (from common.hcl)
    model_id   = local.common_vars.locals.model_id
    model_name = local.common_vars.locals.model_name
  }
}
