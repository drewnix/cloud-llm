[< Previous: Why Terragrunt Stacks](01-why-terragrunt-stacks.md) | [Home](../README.md) | [Next: Unit Templates >](03-unit-templates.md)

---

# Part 2: Project Setup

### Directory Structure

The project has three top-level directories, each corresponding to a layer:

```
cloud-llm/
├── modules/                              # Layer 1: Terraform modules
│   ├── vpc/                              #   Standard .tf files
│   ├── security-groups/
│   ├── acm/
│   ├── alb/
│   ├── s3-model-cache/
│   ├── iam/
│   ├── ec2-gpu/
│   │   └── user-data.sh                 #   EC2 bootstrap script (templatefile)
│   └── cloudflare-dns/
├── units/                                # Layer 2: Unit templates
│   ├── vpc/terragrunt.hcl               #   Wiring: module + deps + inputs
│   ├── security-groups/terragrunt.hcl
│   ├── acm/terragrunt.hcl
│   ├── alb/terragrunt.hcl
│   ├── s3-model-cache/terragrunt.hcl
│   ├── iam/terragrunt.hcl
│   ├── ec2-gpu/terragrunt.hcl
│   └── cloudflare-dns/terragrunt.hcl
├── live/                                 # Layer 3: Stacks + config hierarchy
│   ├── root.hcl                          #   Root config: backend, providers
│   ├── common.hcl                        #   Project-wide variables
│   ├── dev/
│   │   ├── env.hcl                       #   Dev-specific variables
│   │   └── us-east-1/
│   │       ├── region.hcl                #   Region variable
│   │       └── terragrunt.stack.hcl      #   Dev stack blueprint
│   └── prod/
│       ├── env.hcl                       #   Prod-specific variables
│       └── us-east-1/
│           ├── region.hcl
│           └── terragrunt.stack.hcl      #   Prod stack blueprint
└── docs/
    └── tutorial.md
```

Compare this to the pre-Stacks approach: dev and prod would each have 8 subdirectories under `us-east-1/`, each containing its own `terragrunt.hcl` file. That is 16 wiring files. Now there are 8 unit templates (shared) and 2 stack files (one per environment). The `units/` directory is the key addition -- it holds the templates that both stacks reference.

**Why this separation matters:** The VPC module is written once in `modules/`. The VPC unit template is written once in `units/`. Dev and prod both compose the VPC unit via their stack files but pass different values (different CIDRs). If you fix a bug in the VPC module or change how it is wired, every environment gets the fix. No copy-paste, no drift.

### The Root Configuration

The root configuration lives at `live/root.hcl`. Every unit template inherits from it via `include "root"`. This is where you define things that are true for every component in every environment.

```hcl
# live/root.hcl

# Load the hierarchy of variable files
locals {
  common_vars = read_terragrunt_config(find_in_parent_folders("common.hcl"))
  env_vars    = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  region_vars = read_terragrunt_config(find_in_parent_folders("region.hcl"))

  project_name = local.common_vars.locals.project_name
  environment  = local.env_vars.locals.environment
  aws_region   = local.region_vars.locals.aws_region
}

# --- Remote State ---
# S3 backend with native state locking (no DynamoDB table needed).
# On first run, use --backend-bootstrap to create the S3 bucket.
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

# --- Error Handling ---
# Retry logic for transient AWS API errors during parallel deploys.
errors {
  retry "transient_aws" {
    retryable_errors = [
      ".*RequestLimitExceeded.*",
      ".*ThrottlingException.*",
      ".*connection reset by peer.*",
      ".*TLS handshake timeout.*",
    ]
    max_attempts       = 3
    sleep_interval_sec = 10
  }
}

# --- AWS Provider ---
# Generated into every module directory as provider.tf
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

# --- Common Inputs ---
# Every module receives these. Unit templates merge their own inputs on top.
inputs = {
  project_name = local.project_name
  environment  = local.environment
  aws_region   = local.aws_region
}
```

Let's unpack the key concepts:

**`remote_state`** replaces the `backend "s3"` block you would normally write in every module. Terragrunt generates a `backend.tf` file into each module directory before running `terraform init`. The `path_relative_to_include()` function returns the path from the root config to the child, so each component gets its own state file with a unique key. No key collisions, no manual tracking. The `use_lockfile = true` setting enables native S3 state locking (available since Terraform 1.10, stable in 1.11), which is simpler than the older DynamoDB-based approach (no extra table to manage). DynamoDB-based locking is now deprecated and will be removed in a future Terraform release.

**`generate`** blocks write files into the module directory. The AWS provider block is generated once here and every component gets it. When you change the region or add a tag, you change one line and every component picks it up.

**`inputs`** is the Terragrunt equivalent of `-var` flags. Values defined here are passed to every module's Terraform variables. Unit templates can add more inputs or override these.

**The `root.hcl` naming convention:** Notice the file is named `root.hcl`, not `terragrunt.hcl`. This is intentional. In a Stacks project, `terragrunt.hcl` files live inside unit templates, and the root config needs a distinct name so that `find_in_parent_folders("root.hcl")` finds the right file. Each unit template includes it with `find_in_parent_folders("root.hcl")`.

### The Variable Hierarchy

Terragrunt does not have a built-in variable inheritance system, but the pattern of `read_terragrunt_config` + `find_in_parent_folders` gives you one. Here is how the three layers work:

```
live/
├── common.hcl          <-- Project-wide: model name, domain, project name
├── dev/
│   ├── env.hcl         <-- Environment: instance type, spot config, volume sizes
│   └── us-east-1/
│       └── region.hcl  <-- Region: AWS region string
```

**`common.hcl`** -- Values that are the same everywhere: the project name, the model to serve, the domain name. You change the model here and every environment updates.

```hcl
# live/common.hcl

locals {
  project_name = "cloud-llm"
  owner        = "your-name"

  # LLM Configuration
  # Change these to swap the model across all environments
  model_id           = "Qwen/Qwen2.5-Coder-32B-Instruct-AWQ"
  model_name         = "qwen2.5-coder-32b"
  model_quantization = "awq"

  # Cloudflare
  cloudflare_zone_name = "example.com"  # Replace with your domain
  subdomain            = "llm"          # Creates llm.example.com
}
```

**`dev/env.hcl`** -- Environment-specific settings. Dev uses a cheaper instance type and spot pricing.

```hcl
# live/dev/env.hcl

locals {
  environment   = "dev"
  instance_type = "g5.xlarge"   # 1x A10G GPU, 24GB VRAM - ~$1.01/hr on-demand
  use_spot      = true          # ~60% savings, acceptable for dev
  spot_max_price = "0.50"       # Cap spot price at $0.50/hr

  # EBS volume for model storage (models are ~18-20GB)
  ebs_volume_size = 100         # GB - enough for model + Docker images
  ebs_volume_type = "gp3"

  # Open WebUI settings
  webui_port = 3000
  vllm_port  = 8000
}
```

**`dev/us-east-1/region.hcl`** -- Just the region. To deploy in `eu-west-1`, create a `dev/eu-west-1/` directory with its own `region.hcl` and stack file.

```hcl
# live/dev/us-east-1/region.hcl

locals {
  aws_region = "us-east-1"
}
```

**How `find_in_parent_folders` works:** When Terragrunt processes a unit that has been generated into `live/dev/us-east-1/vpc/`, the call `find_in_parent_folders("env.hcl")` walks up the directory tree -- from `vpc/` to `us-east-1/` to `dev/` -- and returns the path to the first `env.hcl` it finds. That is `live/dev/env.hcl`. The same call from `live/prod/us-east-1/vpc/` finds `live/prod/env.hcl`. Same code, different values.

---

[< Previous: Why Terragrunt Stacks](01-why-terragrunt-stacks.md) | [Home](../README.md) | [Next: Unit Templates >](03-unit-templates.md)
