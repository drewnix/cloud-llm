# Cloud LLM Tutorial: Building a Self-Hosted Coding LLM on AWS with Terragrunt Stacks

You want a private coding assistant -- an LLM you control, running on your own hardware, behind your own domain. No API metering, no data leaving your network, no vendor lock-in. By the end of this tutorial you will have a GPU-powered [Qwen 2.5 Coder 32B](https://huggingface.co/Qwen/Qwen2.5-Coder-32B-Instruct-AWQ) instance served by [vLLM](https://github.com/vllm-project/vllm) with an [Open WebUI](https://github.com/open-webui/open-webui) chat interface, TLS-terminated behind an ALB, addressable at `llm.yourdomain.com` -- and every piece of infrastructure defined in code with Terragrunt Stacks.

This tutorial assumes you are comfortable writing Terraform modules but have not used Terragrunt before. It focuses on what Terragrunt Stacks add -- DRY configuration, automatic remote state, dependency orchestration, and blueprint-driven environments -- by walking through a real project step by step.

---

## Table of Contents

- [Part 1: Why Terragrunt Stacks](#part-1-why-terragrunt-stacks)
  - [What Problems Terragrunt Solves](#what-problems-terragrunt-solves)
  - [What Stacks Add on Top](#what-stacks-add-on-top)
  - [Architecture Overview](#architecture-overview)
  - [The Three-Layer Architecture](#the-three-layer-architecture)
  - [Prerequisites](#prerequisites)
- [Part 2: Project Setup](#part-2-project-setup)
  - [Directory Structure](#directory-structure)
  - [The Root Configuration](#the-root-configuration)
  - [The Variable Hierarchy](#the-variable-hierarchy)
- [Part 3: Unit Templates](#part-3-unit-templates)
  - [What a Unit Template Is](#what-a-unit-template-is)
  - [VPC: The Base Layer](#vpc-the-base-layer)
  - [Security Groups: Introducing Dependencies](#security-groups-introducing-dependencies)
  - [ALB: Dependency Fan-In](#alb-dependency-fan-in)
  - [Cloudflare DNS: Multi-Provider Unit](#cloudflare-dns-multi-provider-unit)
  - [EC2 GPU: Five Dependencies](#ec2-gpu-five-dependencies)
  - [The mock_outputs Pattern](#the-mock_outputs-pattern)
- [Part 4: Stack Files](#part-4-stack-files)
  - [What a Stack File Is](#what-a-stack-file-is)
  - [Walking Through the Dev Stack](#walking-through-the-dev-stack)
  - [How Dependency Paths Flow](#how-dependency-paths-flow)
  - [How Environment Values Flow](#how-environment-values-flow)
  - [Generating and Applying](#generating-and-applying)
- [Part 5: Deploying the Full Stack](#part-5-deploying-the-full-stack)
  - [Deploy Dev](#deploy-dev)
  - [Dependency Resolution Order](#dependency-resolution-order)
  - [Testing the Deployment](#testing-the-deployment)
  - [The Bootstrap Script](#the-bootstrap-script)
- [Part 6: Multi-Environment](#part-6-multi-environment)
  - [Prod vs Dev: What Differs](#prod-vs-dev-what-differs)
  - [Deploy Prod](#deploy-prod)
  - [Creating a New Environment](#creating-a-new-environment)
  - [The DRY Payoff](#the-dry-payoff)
- [Part 7: Day-Two Operations](#part-7-day-two-operations)
  - [Swapping the LLM Model](#swapping-the-llm-model)
  - [Cost Controls](#cost-controls)
  - [Stack Commands](#stack-commands)
  - [Feature Flags](#feature-flags)
  - [Error Handling](#error-handling)
  - [Provider Cache](#provider-cache)
  - [Filtering Units](#filtering-units)
  - [Extending the Stack](#extending-the-stack)
- [Recap](#recap)

---

## Part 1: Why Terragrunt Stacks

### What Problems Terragrunt Solves

If you have shipped Terraform to production, you have probably run into these pain points:

* **Repeated backend configuration.** Every module needs a `backend "s3"` block. Copy it once, fine. Copy it across 8 modules and 2 environments and you have 16 nearly identical blocks to keep in sync.

* **Repeated provider blocks.** Same story. Every module declares `provider "aws" { region = "us-east-1" }` and you update them one at a time when something changes.

* **No dependency orchestration.** Terraform operates on one state file at a time. If your security groups need the VPC ID, you either put everything in one giant state (fragile, slow) or you glue modules together with `terraform_remote_state` data sources and hope you remember the apply order.

* **Environment drift.** Dev and prod diverge because they are separate directories with duplicated `.tf` files. A variable added in dev never makes it to prod, or worse, the wrong value does.

Terr agrunt solves all four:

| Problem | Terragrunt Solution |
|---|---|
| Repeated backends | `remote_state` block defined once in a root config, inherited by every module |
| Repeated providers | `generate` blocks write provider files automatically |
| Manual apply ordering | `dependency` blocks create an explicit DAG; Terragrunt applies in order |
| Environment drift | Shared modules with environment-specific inputs (`dev/env.hcl` vs `prod/env.hcl`) |

Terragrunt is not a replacement for Terraform. It is a thin wrapper that calls `terraform init`, `plan`, and `apply` for you after generating backend and provider files and resolving dependencies. Your Terraform modules stay standard -- anyone can `terraform plan` them independently.

### What Stacks Add on Top

Traditional Terragrunt solves the problems above, but introduces a new one: **duplicated wiring files**. Each environment needs its own copy of every `terragrunt.hcl` file. This project has 8 infrastructure components. With dev and prod, that means 16 `terragrunt.hcl` files that are nearly identical -- the only things that change between environments are VPC CIDRs and a few values coming from `env.hcl`.

Terragrunt Stacks (GA since May 2025) solve this with two concepts:

* **Unit templates** live in a shared `units/` directory. Each template defines how a module gets wired up -- its Terraform source, its dependencies, its inputs. A unit template is written once and used by every environment.

* **Stack files** (`terragrunt.stack.hcl`) are blueprints for an entire environment. A stack file says "I want these units, in this directory layout, with these values." One file replaces 8 individual `terragrunt.hcl` files.

The result: instead of 16 wiring files (8 per environment), you have 8 unit templates shared by all environments and 1 stack file per environment. Adding a new environment means writing one stack file and one `env.hcl`. No copying, no drift.

### Architecture Overview

Here is what we are building:

```
                         Internet
                            |
                     [Cloudflare DNS]
                     llm.example.com
                            |
                     [ALB + ACM cert]
                     HTTPS termination
                      /            \
                   /v1/*          /*
                    |              |
                 [vLLM]      [Open WebUI]
                  :8000         :3000
                     \          /
                   [EC2 GPU Instance]
                     g5.xlarge (A10G)
                            |
                    [S3 Model Cache]
                  via VPC Gateway Endpoint
```

The components:

- **VPC** with public and private subnets across two availability zones, internet gateway, and NAT gateway.
- **Security groups** restricting the EC2 instance to only accept traffic from the ALB, not the public internet.
- **ACM certificate** for TLS, validated via Cloudflare DNS.
- **Application Load Balancer** performing HTTPS termination and path-based routing: `/v1/*` goes to the vLLM OpenAI-compatible API, everything else goes to the Open WebUI chat interface.
- **S3 bucket** caching downloaded model weights so the instance does not re-download 18+ GB from HuggingFace on every boot. A VPC gateway endpoint makes S3 access free and fast from within the VPC.
- **IAM role** with least-privilege permissions: S3 model cache access, CloudWatch logs, and SSM Session Manager.
- **EC2 GPU instance** (g5.xlarge with NVIDIA A10G, 24 GB VRAM) running vLLM and Open WebUI in Docker. Dev uses spot instances for ~70% cost savings.
- **Cloudflare DNS** pointing `llm.example.com` at the ALB and creating ACM validation records.

### The Three-Layer Architecture

The project has three layers, each with a distinct job:

```
 ┌─────────────────────────────────────────────────┐
 │              live/  (Stack Files)                │
 │  "I want these units with these values"          │
 │  One terragrunt.stack.hcl per environment        │
 ├─────────────────────────────────────────────────┤
 │              units/  (Unit Templates)            │
 │  "Here's how to wire a module to its deps"       │
 │  Shared across all environments                  │
 ├─────────────────────────────────────────────────┤
 │              modules/  (Terraform Modules)       │
 │  "Here's how to create these resources"          │
 │  Standard .tf files, nothing Terragrunt-specific │
 └─────────────────────────────────────────────────┘
```

* **Modules** are plain Terraform. They define what resources to create. Nothing Terragrunt-specific lives here.

* **Units** are the wiring layer. Each unit template says: use this module, depend on these other units, map these values to inputs. Units reference dependency paths that the stack will provide at composition time.

* **Stacks** are the composition layer. A stack file declares which units to include, where to place them, and what values to pass. It is the blueprint for a complete environment.

Data flows downward: the stack file passes values to units, and units pass inputs to modules. Dependencies flow between units, resolved automatically by Terragrunt.

### Prerequisites

Before starting, make sure you have:

- **AWS account** with permissions to create VPCs, EC2 instances, S3 buckets, IAM roles, ALBs, and ACM certificates
- **Terraform >= 1.5** (`terraform version`)
- **Terragrunt >= 0.80** (`terragrunt --version`) -- Stacks require Terragrunt 0.80+
- **AWS CLI configured** with credentials (`aws sts get-caller-identity` should succeed)
- **Cloudflare account** with a domain managed by Cloudflare
- **Cloudflare API token** with Zone:Read and DNS:Edit permissions, exported as `CLOUDFLARE_API_TOKEN`
- **EC2 GPU quota** -- you may need to request a quota increase for `g5.xlarge` instances in your target region (the default is often 0)

---

## Part 2: Project Setup

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

**`remote_state`** replaces the `backend "s3"` block you would normally write in every module. Terragrunt generates a `backend.tf` file into each module directory before running `terraform init`. The `path_relative_to_include()` function returns the path from the root config to the child, so each component gets its own state file with a unique key. No key collisions, no manual tracking. The `use_lockfile = true` setting enables native S3 state locking, which is simpler than the older DynamoDB-based approach (no extra table to manage).

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
  use_spot      = true          # ~70% savings, acceptable for dev
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

## Part 3: Unit Templates

### What a Unit Template Is

A unit template is a `terragrunt.hcl` file that lives in `units/` and defines how to wire a Terraform module to its dependencies and inputs. It is not tied to any specific environment -- it is a reusable recipe.

Unit templates have three jobs:

1. **Point to a Terraform module** via `terraform { source }`.
2. **Declare dependencies** on other units via `dependency` blocks with paths provided through `values`.
3. **Map values to inputs** -- the stack file passes `values` to the unit, and the unit maps them (along with dependency outputs) to Terraform input variables.

The `values` keyword is the key Stacks concept. When a stack file includes a unit, it passes a `values` block. Inside the unit template, those values are accessible via the `values.` prefix. This is how data flows from the stack layer to the unit layer.

### VPC: The Base Layer

The VPC unit is the simplest -- it has no dependencies. It takes values from the stack and passes them directly to the Terraform module.

```hcl
# units/vpc/terragrunt.hcl

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
```

Let's walk through each piece.

**`include "root"`** tells Terragrunt to inherit from the root configuration. The `find_in_parent_folders("root.hcl")` call walks up the directory tree and finds `live/root.hcl`. This single line gives you the remote state config, the AWS provider block, and the common inputs (`project_name`, `environment`, `aws_region`).

**`terraform { source }`** points to the Terraform module. The `get_repo_root()` function returns the repository root, so `${get_repo_root()}/modules//vpc` resolves to the VPC module regardless of where the unit gets generated. Notice the double slash (`//`) -- this is a Terraform convention that separates the "source repository" from the "subdirectory within it."

**`inputs`** maps values from the stack to Terraform variables. The expression `values.vpc_cidr` reads the `vpc_cidr` value that the stack file passes in its `values` block. Common inputs like `project_name` and `environment` are inherited from the root config and do not need to be repeated.

### Security Groups: Introducing Dependencies

The security groups module needs the VPC ID. In plain Terraform, you would use a `terraform_remote_state` data source. In Terragrunt, you declare a `dependency`:

```hcl
# units/security-groups/terragrunt.hcl

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
```

Two new concepts here:

**`dependency "vpc"`** declares that this unit depends on the VPC unit. The `config_path` is set to `values.vpc_path` -- the stack file provides this path (typically `"../vpc"`), making the dependency wiring relative to the generated environment layout rather than hardcoded.

**`mock_outputs`** provides fake output values that Terragrunt uses when the dependency has not been applied yet. This enables `terragrunt plan` to succeed even before the VPC exists -- useful for validating configuration before any infrastructure is created. More on this pattern later.

The expression `dependency.vpc.outputs.vpc_id` reads the `vpc_id` output from the VPC's Terraform state at apply time, replacing the `terraform_remote_state` data source pattern. Terragrunt reads the state directly using the backend configuration.

### ALB: Dependency Fan-In

The ALB is the first unit with **multiple dependencies** -- it needs outputs from three different units:

```hcl
# units/alb/terragrunt.hcl

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
```

This is called **dependency fan-in** -- multiple upstream units feeding into one downstream unit. Terragrunt ensures that all three dependencies are applied before the ALB. When you deploy the stack, the VPC applies first. Then security groups and ACM can run in parallel (neither depends on the other). Once all three are done, the ALB applies.

Each dependency path (`values.vpc_path`, `values.security_groups_path`, `values.acm_path`) is provided by the stack file. The unit template never hardcodes paths -- it only knows the shape of its dependencies, not their location.

### Cloudflare DNS: Multi-Provider Unit

This unit is architecturally interesting because the underlying module uses **two providers** (Cloudflare and AWS). The AWS provider is generated by the root config. The Cloudflare provider is declared in the module's own `required_providers` block and authenticates via the `CLOUDFLARE_API_TOKEN` environment variable -- so the unit template itself does not need any special provider wiring.

```hcl
# units/cloudflare-dns/terragrunt.hcl

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
```

The `inputs` block pulls from two sources: `values` (zone name, subdomain -- provided by the stack, originating from `common.hcl`) and `dependency` outputs (ACM cert details, ALB DNS name -- resolved from Terraform state at apply time). This separation is clean: static configuration comes from values, dynamic infrastructure references come from dependencies.

### EC2 GPU: Five Dependencies

The EC2 GPU unit has the most complex wiring in the project. It depends on five other units and pulls configuration from both `env.hcl` and `common.hcl` via the stack's values:

```hcl
# units/ec2-gpu/terragrunt.hcl

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
```

The `inputs` block pulls from three distinct sources:

1. **`values.*` from `env.hcl`** (via the stack) -- instance sizing, spot config, ports. These differ between dev and prod.
2. **`values.*` from `common.hcl`** (via the stack) -- which model to run. This is the same across environments.
3. **`dependency.*.outputs.*`** -- infrastructure references from the five upstream units.

The unit template itself is completely environment-agnostic. It does not know whether it is running in dev or prod. The stack file is the only place where those distinctions are made.

### The mock_outputs Pattern

Every `dependency` block in the project includes a `mock_outputs` block. This is a practical necessity, not boilerplate.

When you run `terragrunt plan` on a unit before its dependencies have been applied, Terragrunt has no state to read outputs from. Without `mock_outputs`, the plan would fail. With them, Terragrunt substitutes the mock values, letting you validate the configuration structure even when the actual infrastructure does not exist yet.

```hcl
dependency "vpc" {
  config_path = values.vpc_path

  mock_outputs = {
    vpc_id            = "vpc-mock"
    public_subnet_ids = ["subnet-mock-1", "subnet-mock-2"]
  }
}
```

The mock values should match the **type** of the real outputs (string for string, list for list) but the actual values do not matter -- they are only used during `plan`. At `apply` time, Terragrunt reads the real outputs from state.

---

## Part 4: Stack Files

### What a Stack File Is

A `terragrunt.stack.hcl` file is a blueprint for an entire environment. It declares which unit templates to compose, where they should be generated, and what values to pass to each one.

When you run `terragrunt stack generate`, Terragrunt reads the stack file and creates a directory of `terragrunt.hcl` files -- one per unit -- in the local directory. When you run `terragrunt stack run apply`, it generates those files and then applies them all in dependency order.

Think of the stack file as a declarative manifest: "I want a VPC with these CIDRs, security groups connected to it, an ALB using these security groups and this certificate, and a GPU instance pulling it all together."

### Walking Through the Dev Stack

Here is the complete dev stack file:

```hcl
# live/dev/us-east-1/terragrunt.stack.hcl

locals {
  common_vars = read_terragrunt_config(find_in_parent_folders("common.hcl"))
  env_vars    = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

# ---------------------------------------------------------------------------
# Network Layer
# ---------------------------------------------------------------------------

unit "vpc" {
  source = "../../../units/vpc"
  path   = "vpc"

  values = {
    vpc_cidr             = "10.0.0.0/16"
    public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
    private_subnet_cidrs = ["10.0.10.0/24", "10.0.11.0/24"]
    availability_zones   = ["us-east-1a", "us-east-1b"]
  }
}

unit "security_groups" {
  source = "../../../units/security-groups"
  path   = "security-groups"

  values = {
    vpc_path          = "../vpc"
    allowed_ssh_cidrs = [] # Add your IP: ["1.2.3.4/32"]
  }
}

# ---------------------------------------------------------------------------
# Supporting Infrastructure
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# GPU Compute
# ---------------------------------------------------------------------------

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
```

Each `unit` block has three fields:

**`source`** -- path to the unit template directory in `units/`. This is where the `terragrunt.hcl` template lives.

**`path`** -- the relative directory name for this unit inside the generated `.terragrunt-stack/` directory. After `terragrunt stack generate`, you will find `.terragrunt-stack/vpc/terragrunt.hcl`, `.terragrunt-stack/alb/terragrunt.hcl`, etc.

**`values`** -- the data to pass to the unit template. Inside the unit, these are accessible as `values.vpc_cidr`, `values.vpc_path`, and so on.

### How Dependency Paths Flow

Dependency paths are the most important concept to understand in Stacks. Here is the flow for the security groups unit:

```
Stack file                              Unit template
─────────────────────                   ─────────────────────
unit "security_groups" {                dependency "vpc" {
  values = {                              config_path = values.vpc_path
    vpc_path = "../vpc"     ─────────►    ...
  }                                     }
}
```

The stack file says `vpc_path = "../vpc"`. The unit template uses `values.vpc_path` as the `config_path` in its dependency block. After generation, the resolved path is `../vpc` -- a relative path from the generated `security-groups/terragrunt.hcl` to the generated `vpc/terragrunt.hcl`.

This indirection is what makes units reusable. The unit template does not hardcode `"../vpc"` -- it says "whatever path the stack tells me." If an environment needed a different layout (maybe a shared VPC from a different directory), the stack would just pass a different path.

### How Environment Values Flow

Environment-specific values take a longer journey. Here is the path for `instance_type`:

```
env.hcl                     Stack file                         Unit template
────────────                ────────────                       ─────────────
locals {                    unit "ec2_gpu" {                   inputs = {
  instance_type               values = {                        instance_type =
    = "g5.xlarge"               instance_type =                   values.instance_type
}                                 local.env_vars                }
                                  .locals.instance_type
                              }
                            }
```

1. `dev/env.hcl` defines `instance_type = "g5.xlarge"`.
2. The stack file loads `env.hcl` into `local.env_vars` and passes `local.env_vars.locals.instance_type` as a value to the `ec2_gpu` unit.
3. The unit template reads `values.instance_type` and maps it to the `instance_type` Terraform variable.

The stack file is the bridge between the variable hierarchy (`common.hcl`, `env.hcl`, `region.hcl`) and the unit templates. Units never read `env.hcl` directly -- they receive everything through `values`.

### Generating and Applying

Two commands drive the Stacks workflow:

**`terragrunt stack generate`** reads the stack file and creates the generated `terragrunt.hcl` files locally:

```bash
cd live/dev/us-east-1
terragrunt stack generate
```

> **Important:** Always run Terragrunt commands from inside the environment directory (e.g., `live/dev/us-east-1/`), not from the repo root. Terragrunt scans downward from the current directory, so running from the root would cause it to discover the unit templates in `units/` and try to parse them as standalone configs -- which fails because `values.*` and `find_in_parent_folders` only resolve in a stack context.

After this, you will see a `.terragrunt-stack/` directory with subdirectories for each unit:

```
live/dev/us-east-1/
├── terragrunt.stack.hcl          # Your stack file (unchanged)
└── .terragrunt-stack/
    ├── vpc/
    │   ├── terragrunt.hcl        # Generated from units/vpc
    │   └── terragrunt.values.hcl # Resolved values from the stack file
    ├── security-groups/
    │   ├── terragrunt.hcl
    │   └── terragrunt.values.hcl
    ├── acm/
    │   ├── terragrunt.hcl
    │   └── terragrunt.values.hcl
    ├── alb/
    │   ├── terragrunt.hcl
    │   └── terragrunt.values.hcl
    ├── s3-model-cache/
    │   ├── terragrunt.hcl
    │   └── terragrunt.values.hcl
    ├── iam/
    │   ├── terragrunt.hcl
    │   └── terragrunt.values.hcl
    ├── cloudflare-dns/
    │   ├── terragrunt.hcl
    │   └── terragrunt.values.hcl
    └── ec2-gpu/
        ├── terragrunt.hcl
        └── terragrunt.values.hcl
```

The `.terragrunt-stack/` directory is gitignored -- it is a generated artifact. Each unit gets a `terragrunt.hcl` (the unit template with resolved sources) and a `terragrunt.values.hcl` (the concrete values from the stack file). You can inspect these to verify the wiring before applying.

**`terragrunt stack run apply`** generates and then applies all units in dependency order:

```bash
cd live/dev/us-east-1
terragrunt stack run apply
```

This is the primary command. It generates the configs, builds the dependency graph, and applies everything -- parallelizing where possible.

---

## Part 5: Deploying the Full Stack

### Deploy Dev

With all layers in place -- modules, units, stack file, and variable hierarchy -- deploying the dev environment is one command:

```bash
cd live/dev/us-east-1
terragrunt stack run apply --backend-bootstrap
```

On first run, pass `--backend-bootstrap` so Terragrunt creates the S3 state bucket (`cloud-llm-dev-terraform-state`) automatically. On subsequent runs you can omit the flag.

### Dependency Resolution Order

Terragrunt reads every `dependency` block, builds a DAG (directed acyclic graph), and applies units in topological order -- parallelizing where possible:

```
     vpc                 acm
    / | \                 |
   /  |  \                |
  sg  |  s3-model-cache   |
  |   |       |           |
  |   |      iam          |
  |   |     /             |
  |   |    /              |
  +---+---+    +----------+
  |        \  /
  |        alb
  |       / |
  |      /  |
  |     / cloudflare-dns
  |    /
  ec2-gpu

  (sg = security-groups)
```

The execution proceeds in waves:

```
[1] vpc, acm                 (no dependencies -- parallel)
[2] security-groups,          (after vpc -- parallel with each other)
    s3-model-cache
[3] iam                       (after s3-model-cache)
[4] alb                       (after vpc + security-groups + acm)
[5] cloudflare-dns            (after acm + alb)
[6] ec2-gpu                   (after vpc + security-groups + iam + alb + s3-model-cache)
```

The first deploy takes about 10-15 minutes. ACM certificate validation and model loading are the bottlenecks. Subsequent deploys are faster since the model is cached in S3.

### Testing the Deployment

Once the stack apply completes, verify everything works:

```bash
# Check the vLLM API is responding
curl https://llm.yourdomain.com/v1/models

# Expected response:
# {"object":"list","data":[{"id":"Qwen/Qwen2.5-Coder-32B-Instruct-AWQ",...}]}

# Test code generation
curl https://llm.yourdomain.com/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-Coder-32B-Instruct-AWQ",
    "prompt": "def fibonacci(n):",
    "max_tokens": 100
  }'

# Open the WebUI in your browser
open https://llm.yourdomain.com
```

The ALB routes `/v1/*` requests to vLLM (port 8000) and everything else to Open WebUI (port 3000), so both services are available on the same domain. You can use the vLLM endpoint as a drop-in replacement for the OpenAI API in your editor, scripts, or other tools.

### The Bootstrap Script

The `modules/ec2-gpu/user-data.sh` script runs on first boot. Terraform's `templatefile()` function injects variables from the Terragrunt inputs. In brief, it:

1. **Installs Docker and Docker Compose** on the Amazon Linux 2023 instance
2. **Installs NVIDIA Container Toolkit** so Docker can access the GPU
3. **Checks the S3 cache** for model weights. If found, downloads from S3 (fast and free via the VPC gateway endpoint). If not, lets vLLM download from HuggingFace on first start and caches to S3 in the background.
4. **Writes a `docker-compose.yml`** with two services: vLLM (serving the model with `--gpu-memory-utilization 0.90` and `--max-model-len 8192` to fit the quantized 32B model in the A10G's 24GB VRAM) and Open WebUI (connecting to vLLM's OpenAI-compatible API at `http://vllm:8000/v1`).
5. **Starts the stack** with `docker compose up -d`.

The health check `start_period` of 300 seconds gives vLLM five minutes to download and load the model before health checks start failing. Open WebUI's `depends_on` with `condition: service_healthy` ensures it waits until the model is ready.

---

## Part 6: Multi-Environment

### Prod vs Dev: What Differs

The prod stack file is nearly identical to dev. Place them side by side and only two things change: the VPC CIDRs and the ec2-gpu values (which come from `env.hcl`, not the stack file directly).

**VPC CIDRs (hardcoded in the stack file):**

| Value | Dev | Prod |
|---|---|---|
| `vpc_cidr` | `10.0.0.0/16` | `10.1.0.0/16` |
| `public_subnet_cidrs` | `10.0.1.0/24`, `10.0.2.0/24` | `10.1.1.0/24`, `10.1.2.0/24` |
| `private_subnet_cidrs` | `10.0.10.0/24`, `10.0.11.0/24` | `10.1.10.0/24`, `10.1.11.0/24` |

Different CIDRs prevent IP collisions if you ever peer the VPCs.

**Instance settings (from `env.hcl`):**

| Setting | Dev (`dev/env.hcl`) | Prod (`prod/env.hcl`) |
|---|---|---|
| `environment` | `"dev"` | `"prod"` |
| `instance_type` | `"g5.xlarge"` | `"g5.2xlarge"` |
| `use_spot` | `true` | `false` |
| `spot_max_price` | `"0.50"` | `""` |
| `ebs_volume_size` | `100` | `200` |

Here is `prod/env.hcl`:

```hcl
# live/prod/env.hcl

locals {
  environment    = "prod"
  instance_type  = "g5.2xlarge"  # 1x A10G GPU, 24GB VRAM, more CPU/RAM
  use_spot       = false         # On-demand for reliability
  spot_max_price = ""            # Not used

  # EBS volume for model storage
  ebs_volume_size = 200          # GB - more headroom for production
  ebs_volume_type = "gp3"

  # Open WebUI settings
  webui_port = 3000
  vllm_port  = 8000
}
```

Everything else -- the unit templates, the dependency graph, the module source, the model configuration, the provider setup -- is shared. The prod stack file references the same `units/` directory as dev.

### Deploy Prod

```bash
cd live/prod/us-east-1
terragrunt stack run apply --backend-bootstrap
```

Terragrunt creates a separate state bucket (`cloud-llm-prod-terraform-state`), separate resources with `Environment = prod` tags, and a separate VPC in the `10.1.0.0/16` CIDR range. Same command, completely isolated infrastructure.

### Creating a New Environment

If you wanted a staging environment, here is everything you would do:

```bash
# 1. Create the directory structure
mkdir -p live/staging/us-east-1

# 2. Write env.hcl
cat > live/staging/env.hcl << 'EOF'
locals {
  environment    = "staging"
  instance_type  = "g5.xlarge"
  use_spot       = true
  spot_max_price = "0.60"
  ebs_volume_size = 100
  ebs_volume_type = "gp3"
  webui_port = 3000
  vllm_port  = 8000
}
EOF

# 3. Write region.hcl
cat > live/staging/us-east-1/region.hcl << 'EOF'
locals {
  aws_region = "us-east-1"
}
EOF

# 4. Copy the stack file and adjust VPC CIDRs
cp live/dev/us-east-1/terragrunt.stack.hcl live/staging/us-east-1/
# Edit terragrunt.stack.hcl: change 10.0.x.x to 10.2.x.x

# 5. Deploy
cd live/staging/us-east-1
terragrunt stack run apply
```

Three files: `env.hcl`, `region.hcl`, and `terragrunt.stack.hcl`. That is it. No copying 8 individual `terragrunt.hcl` files. No risk of forgetting one or introducing a typo.

### The DRY Payoff

Here is the accounting:

**Pre-Stacks (traditional Terragrunt):**
- 8 module configs per environment, copied identically between dev and prod
- 16 total `terragrunt.hcl` files for 2 environments
- Adding a third environment means copying 8 more files

**With Stacks:**
- 8 unit templates in `units/`, shared by all environments
- 1 `terragrunt.stack.hcl` per environment
- Adding a third environment means writing 1 stack file + 1 `env.hcl`

The unit templates are write-once. They encode the dependency graph and the wiring logic. The stack files are lightweight blueprints that compose units with environment-specific values. The module configs that used to be duplicated across environments now exist in exactly one place.

---

## Part 7: Day-Two Operations

### Swapping the LLM Model

One of the advantages of this architecture: swapping the model is a one-line change. Edit `live/common.hcl`:

```hcl
locals {
  # Change from the 32B quantized model...
  # model_id           = "Qwen/Qwen2.5-Coder-32B-Instruct-AWQ"
  # model_name         = "qwen2.5-coder-32b"

  # ...to the smaller 7B model (faster inference, fits easily in VRAM)
  model_id           = "Qwen/Qwen2.5-Coder-7B-Instruct"
  model_name         = "qwen2.5-coder-7b"
  model_quantization = "none"
}
```

Then apply just the EC2 GPU unit (the model config does not affect other units):

```bash
cd live/dev/us-east-1
terragrunt stack run apply  # Terragrunt detects only ec2-gpu has changes
```

This replaces the instance (the user data changes because the model ID is different). The new instance boots, downloads the 7B model, and starts serving. Since `common.hcl` is shared, applying in prod would deploy the same model there.

### Cost Controls

For a learning project, you do not want to run a GPU instance 24/7.

**Stop the instance (keep the infrastructure):**
```bash
aws ec2 stop-instances --instance-ids $(
  cd live/dev/us-east-1/.terragrunt-stack/ec2-gpu && \
  terragrunt output -raw instance_id
)
```

**Start it back up:**
```bash
aws ec2 start-instances --instance-ids $(
  cd live/dev/us-east-1/.terragrunt-stack/ec2-gpu && \
  terragrunt output -raw instance_id
)
```

**Tear down just the GPU instance (keep networking + ALB):**
```bash
cd live/dev/us-east-1/.terragrunt-stack/ec2-gpu
terragrunt destroy
```

When you want it back, `terragrunt apply` in that directory re-creates it. The S3 model cache means the new instance does not have to re-download from HuggingFace.

**Destroy the entire dev environment:**
```bash
cd live/dev/us-east-1
terragrunt stack run destroy
```

Terragrunt destroys in reverse dependency order: ec2-gpu first, then cloudflare-dns and alb, then the supporting modules, and vpc last.

### Stack Commands

The Stacks feature adds three commands to Terragrunt:

**`terragrunt stack generate`** -- Reads the stack file and creates the generated `terragrunt.hcl` files locally without applying anything. Useful for inspecting what would be generated.

```bash
cd live/dev/us-east-1
terragrunt stack generate
```

**`terragrunt stack run <command>`** -- Generates and then runs a Terraform command across all units in the stack, respecting dependency order. The most common uses:

```bash
terragrunt stack run plan      # Preview changes across the entire stack
terragrunt stack run apply     # Apply changes to the entire stack
terragrunt stack run destroy   # Tear down the entire stack
terragrunt stack run output    # Show outputs from all units
```

**Working with individual units** -- After generation, you can still `cd` into a unit's generated directory and run Terragrunt directly. This is useful for targeted operations:

```bash
cd live/dev/us-east-1/.terragrunt-stack/alb
terragrunt plan    # Plan just the ALB
terragrunt apply   # Apply just the ALB
terragrunt output  # Show ALB outputs
```

### Feature Flags

The GPU instance is the most expensive resource in the stack (~$1/hr on-demand). Sometimes you want to plan or operate the networking and supporting infrastructure without the GPU -- maybe you are iterating on ALB rules, or you just want to keep costs down between coding sessions.

Terragrunt's `feature` block (available since v0.90) lets you define toggleable flags directly in a unit template. The ec2-gpu unit uses one:

```hcl
# units/ec2-gpu/terragrunt.hcl

feature "deploy" {
  default = true
}

exclude {
  if      = !feature.deploy.value
  actions = ["apply", "destroy", "plan"]
}
```

The `feature "deploy"` block declares a boolean flag that defaults to `true`. The `exclude` block checks its value -- when `deploy` is `false`, Terragrunt skips the unit entirely for `apply`, `destroy`, and `plan` actions.

Override it from the CLI:

```bash
# Plan the full stack WITHOUT the GPU instance
cd live/dev/us-east-1
terragrunt stack run plan --feature deploy=false

# Apply everything except ec2-gpu
terragrunt stack run apply --feature deploy=false

# Normal deploy (GPU included, since default = true)
terragrunt stack run apply
```

This is more ergonomic than `cd`-ing into the ec2-gpu directory and running `terragrunt destroy` -- the feature flag operates at the stack level, so you can plan the entire environment with or without the GPU in a single command. The networking, ALB, DNS, and model cache all stay up, so re-enabling the GPU later is fast (no re-creating the VPC or waiting for ACM validation).

### Error Handling

When Terragrunt applies 8 units in parallel, they all hit the AWS API simultaneously. AWS responds to burst traffic with throttling errors like `RequestLimitExceeded` and `ThrottlingException`. Without retry logic, these transient errors cause the deploy to fail even though nothing is actually wrong.

The `errors` block in `root.hcl` handles this:

```hcl
# live/root.hcl

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
```

Each pattern is a regex matched against the error message. When a match hits, Terragrunt waits `sleep_interval_sec` seconds and retries the operation, up to `max_attempts` times. Since this block is in `root.hcl`, every unit inherits it via `include "root"` -- no per-unit configuration needed.

The `connection reset by peer` and `TLS handshake timeout` patterns catch transient network issues that occasionally surface during long-running Terraform applies, especially in regions with higher latency.

### Provider Cache

Each of the 8 units in the stack downloads its own copy of the AWS provider during `terraform init`. The AWS provider binary is roughly 100 MB, so a full `stack run apply` downloads ~800 MB of identical binaries.

The `--provider-cache` flag tells Terragrunt to cache provider binaries and share them across all units:

```bash
cd live/dev/us-east-1
terragrunt stack run apply --provider-cache
```

This downloads the AWS provider once and symlinks it into each unit's `.terraform/` directory. No configuration changes needed -- it is purely a CLI flag. On a slow connection, this cuts `init` time from minutes to seconds.

You can also set it permanently with an environment variable:

```bash
export TG_PROVIDER_CACHE=1
terragrunt stack run apply
```

### Filtering Units

When you want to target specific units without `cd`-ing into generated directories, use the `--filter` flag:

```bash
cd live/dev/us-east-1

# Plan only the ALB unit
terragrunt stack run plan --filter='./us-east-1/.terragrunt-stack/alb'

# Apply only ec2-gpu and its dependencies
terragrunt stack run apply --filter='./us-east-1/.terragrunt-stack/ec2-gpu'
```

Filters accept path patterns relative to the stack directory. This is more convenient than navigating into `.terragrunt-stack/` subdirectories, especially when you want to run a command across a subset of units.

For CI/CD pipelines, `--filter-affected` is particularly useful -- it compares against a base branch and only runs units that have changed:

```bash
# In CI: only plan/apply units affected by the current PR
terragrunt stack run plan --filter-affected
```

### Extending the Stack

Adding a new component to the stack is a three-step process:

1. **Write the Terraform module** in `modules/`. Standard `.tf` files.
2. **Write the unit template** in `units/`. Define the `terraform` source, `dependency` blocks, and `inputs` mapping.
3. **Add a `unit` block** to each stack file in `live/`. Provide the `source`, `path`, and `values`.

For example, to add a CloudWatch dashboard:

```hcl
# In units/monitoring/terragrunt.hcl
include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/modules//monitoring"
}

dependency "ec2_gpu" {
  config_path = values.ec2_gpu_path
  mock_outputs = {
    instance_id = "i-mock"
  }
}

inputs = {
  instance_id = dependency.ec2_gpu.outputs.instance_id
}
```

```hcl
# Add to each terragrunt.stack.hcl
unit "monitoring" {
  source = "../../../units/monitoring"
  path   = "monitoring"

  values = {
    ec2_gpu_path = "../ec2-gpu"
  }
}
```

The unit template is written once. Every stack file that includes it gets the monitoring dashboard with a single `unit` block.

---

## Recap

Here is what you built and the Stacks concepts each piece demonstrated:

| Concept | Where You Used It |
|---|---|
| **Modules** (Terraform) | `modules/` -- 8 standard Terraform modules that know nothing about Terragrunt |
| **Root config** (`root.hcl`) | `live/root.hcl` -- single source of truth for state backend, providers, common inputs |
| **Variable hierarchy** | `common.hcl` -> `env.hcl` -> `region.hcl` -- configuration flows from general to specific |
| **Unit templates** (`units/`) | `units/vpc/`, `units/alb/`, etc. -- reusable wiring between modules and dependencies |
| **`values` passing** | Stack files pass `values` to units; units read them as `values.vpc_cidr`, `values.vpc_path` |
| **`dependency` blocks** | Unit templates declare dependencies with paths from `values`, enabling reuse |
| **`mock_outputs`** | Every dependency block -- enables `plan` before dependencies are applied |
| **`get_repo_root()`** | Unit templates use it so `terraform { source }` works from any generated location |
| **Stack files** (`terragrunt.stack.hcl`) | `live/dev/us-east-1/` and `live/prod/us-east-1/` -- one blueprint per environment |
| **`terragrunt stack run`** | Deploy or destroy an entire environment with one command |
| **Multi-environment** | Dev and prod share all 8 unit templates, differ only in stack values and `env.hcl` |
| **Multi-provider** | Cloudflare DNS module declares its own provider; AWS provider is generated globally |
| **`feature` + `exclude`** | ec2-gpu unit -- toggle GPU deployment with `--feature deploy=false` |
| **`errors` block** | `root.hcl` -- automatic retry for transient AWS API errors during parallel deploys |
| **`--provider-cache`** | CLI flag -- deduplicates provider downloads across all 8 units |
| **`--filter`** | CLI flag -- target specific units without `cd`-ing into generated directories |

The infrastructure itself -- a GPU instance running a quantized Qwen 2.5 Coder 32B behind an ALB with TLS, automated DNS, and model caching -- is production-grade. But the real takeaway is the Stacks pattern: modules define resources, units define wiring, stacks define environments. Write the unit once, compose it everywhere. When you internalize this three-layer architecture, you can apply it to any infrastructure project and never duplicate a wiring file again.

---

## Part 8: GitOps Pipeline

### Why a Pipeline

Up to this point, every `terragrunt stack run apply` has happened from your laptop. That works when you are the only person touching the infrastructure and you remember to run `plan` before `apply` and you never accidentally paste the wrong value into a terminal. In other words, it works until it does not. The moment a second engineer joins the project -- or you come back to it after three weeks and forget which environment you last applied -- manual deploys become a liability. There is no audit trail, no review of plan output before changes hit AWS, and no guarantee that two people are not applying conflicting changes at the same time.

The deeper problem is visibility. When someone opens a pull request that changes a VPC CIDR or swaps the instance type from `g5.xlarge` to `g6.2xlarge`, the code reviewer sees the HCL diff but not what it will actually do. Will it recreate the instance? Will it tear down the NAT gateway and rebuild it? Without running `plan` against the real state, you are approving changes blind. A GitOps pipeline solves this by running `terragrunt stack run plan` automatically on every PR and posting the output as a comment. The reviewer sees exactly what will happen before clicking Merge.

Then there is drift. Someone uses the AWS console to add an inbound rule to a security group. An auto-scaling event changes a tag. A provider upgrade shifts a default timeout. None of these show up in your HCL files, and without periodic detection you will not know until something breaks in production. A scheduled drift workflow runs `plan` on a cron, and if the plan is non-empty -- meaning real infrastructure has diverged from your code -- it opens an issue so you can decide whether to fix the code or re-apply.

Part 8 covers the four GitHub Actions workflows that turn this repo into a proper GitOps pipeline: **PR validation** (lint, security scan, plan, cost estimate), **deploy** (auto-apply to dev on merge, gated apply to prod), **drift detection** (scheduled plan with issue creation), and a **power switch** (manual on/off for GPU instances to save costs). All four share a **composite action** for tool installation, and the validation layer uses four static analysis tools that run without AWS credentials.

```
.github/
├── workflows/
│   ├── pr.yml              # Validation + plan on pull requests
│   ├── deploy.yml          # Apply on merge (dev auto, prod gated)
│   ├── drift.yml           # Scheduled drift detection
│   └── power.yml           # Manual infrastructure on/off switch
└── actions/
    └── terragrunt-setup/
        └── action.yml      # Composite action: shared tool installation
```

### Prerequisites (CI/CD)

Before the workflows can run, you need to wire up authentication, environments, and a couple of external services. This section covers the one-time setup.

**OIDC Federation** -- The workflows need AWS credentials, but you should never store long-lived access keys as GitHub secrets. OIDC (OpenID Connect) federation lets GitHub Actions request short-lived credentials directly from AWS. Each workflow run gets a temporary token that expires in an hour, there are no secrets to rotate, and if someone forks your repo, their workflows cannot assume your role because the trust policy is scoped to your repository.

Set it up in three steps:

1. **Create the OIDC identity provider** in IAM. Go to IAM > Identity providers > Add provider. Select OpenID Connect, enter `token.actions.githubusercontent.com` as the provider URL, and `sts.amazonaws.com` as the audience.

2. **Create an IAM role** with a trust policy that allows your repository to assume it:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:OWNER/cloud-llm:*"
      }
    }
  }]
}
```

Replace `ACCOUNT_ID` with your 12-digit AWS account ID and `OWNER` with your GitHub username or organization. The `StringLike` condition with the wildcard means any branch, tag, or environment in that repository can assume the role. If you want to restrict it further -- for example, only allowing the `main` branch -- change the `sub` pattern to `repo:OWNER/cloud-llm:ref:refs/heads/main`.

3. **Attach permissions** to the role. The role needs the same AWS permissions you used for manual deploys -- at minimum, the ability to manage VPCs, EC2, S3, IAM, ALBs, ACM, and CloudWatch. If you already have a policy from your manual setup, attach it to this role.

**GitHub Environments** -- Go to your repository's Settings > Environments and create two environments:

- **`dev`**: No protection rules. Add a variable `AWS_ROLE_ARN` set to the ARN of the IAM role you created above (e.g., `arn:aws:iam::123456789012:role/cloud-llm-ci`). Add a variable `GPU_ENABLED` set to `true`.
- **`prod`**: Add a **required reviewer** -- this gates production deploys so that merging to `main` does not immediately apply to prod. Someone must approve the deployment in the GitHub UI. Add the same `AWS_ROLE_ARN` and `GPU_ENABLED` variables, pointing to the appropriate prod role if you use separate roles per environment.

The deploy workflow references these environments by name. When a job specifies `environment: dev`, GitHub injects that environment's variables and enforces its protection rules. This is how the pipeline achieves "auto-deploy to dev, gated deploy to prod" without any conditional logic in the workflow itself.

**Infracost** -- [Infracost](https://www.infracost.io/) estimates the cost impact of infrastructure changes and posts it as a PR comment. Sign up at infracost.io (the free tier covers open-source and small teams), generate an API key, and add it as a repository secret named `INFRACOST_API_KEY`. The PR workflow uses it to show a before/after cost breakdown so reviewers can see that changing an instance type from `g5.xlarge` to `g6.2xlarge` adds $X/month.

**GitHub Labels** -- Create three labels in your repository: `drift`, `dev`, and `prod`. The drift detection workflow uses these to label auto-created issues so you can filter and triage them. Go to Issues > Labels > New label, or use the CLI:

```bash
gh label create drift --color "d73a4a" --description "Infrastructure drift detected"
gh label create dev   --color "0e8a16" --description "Dev environment"
gh label create prod  --color "fbca04" --description "Prod environment"
```

### The Composite Action

Every workflow in the pipeline needs the same set of tools: Terraform, Terragrunt, tflint, and checkov. You could copy the installation steps into each workflow, but that defeats the DRY principle you have been applying throughout this project. Instead, you write a **composite action** -- a reusable set of steps that other workflows call like a function.

```yaml
# .github/actions/terragrunt-setup/action.yml

name: 'Terragrunt Setup'
description: 'Install Terraform, Terragrunt, tflint, and checkov for CI pipelines'

inputs:
  terraform-version:
    description: 'Terraform version to install'
    required: false
    default: '1.12.1'
  terragrunt-version:
    description: 'Terragrunt version to install'
    required: false
    default: '0.80.6'
  tflint-version:
    description: 'tflint version to install'
    required: false
    default: '0.55.1'

runs:
  using: 'composite'
  steps:
    - name: Install Terraform
      uses: hashicorp/setup-terraform@v3
      with:
        terraform_version: ${{ inputs.terraform-version }}
        terraform_wrapper: false

    - name: Install Terragrunt
      uses: gruntwork-io/setup-terragrunt@v1
      with:
        terragrunt_version: ${{ inputs.terragrunt-version }}

    - name: Install tflint
      uses: terraform-linters/setup-tflint@v4
      with:
        tflint_version: "v${{ inputs.tflint-version }}"

    - name: Install checkov
      shell: bash
      run: pip install checkov
```

Let's walk through the key decisions:

**`using: 'composite'`** makes this a composite action -- a sequence of steps that gets inlined into the calling workflow's job. Unlike a Docker-based action, composite actions run directly on the runner, so they are fast and have access to the same filesystem. Every workflow calls it with `uses: ./.github/actions/terragrunt-setup`, and all four installation steps run as if they were written inline.

**`terraform_wrapper: false`** is critical. The `hashicorp/setup-terraform` action installs a wrapper script by default that intercepts Terraform's stdout and stderr to expose them as step outputs. This sounds helpful, but it breaks Terragrunt. Terragrunt parses Terraform's output to extract plan summaries, dependency outputs, and error messages. The wrapper mangles that output, causing silent failures or garbled plan comments. Always disable it when using Terragrunt.

**Version pinning via inputs** -- Each tool version has a default value but can be overridden by the calling workflow. This gives you reproducible builds (everyone runs the same versions) and easy upgrades (change the default in one file, all workflows pick it up). If you need to test a Terragrunt pre-release, you can pass `terragrunt-version: '0.81.0-rc1'` in a single workflow without affecting the others.

**`pip install checkov`** -- Unlike the other tools, checkov does not have an official GitHub Actions setup action. It is a Python package, and `ubuntu-latest` runners come with Python and pip pre-installed, so a direct `pip install` is the simplest approach. If you want to pin the version for reproducibility, change it to `pip install checkov==3.2.x`.

This is the same DRY pattern you applied in the infrastructure code: unit templates are written once and composed by every stack file; this composite action is written once and used by every workflow. Write the tooling once, reference it everywhere.

### Validation & Linting

Before a `plan` ever touches the cloud, four static analysis tools catch entire categories of errors locally. They run without AWS credentials -- no IAM role needed, no OIDC setup, no cost. This is why validation is a separate job in the PR workflow: it executes fast, in parallel with plan jobs, and fails the PR early if it finds problems.

| Tool | What It Catches | Example |
|---|---|---|
| `terragrunt hclfmt` | Style inconsistencies in `.hcl` files | Misaligned `=` signs, wrong indentation |
| `tflint` | Terraform-specific errors `validate` misses | Invalid instance type `g5.xbig`, deprecated syntax |
| `checkov` | Security misconfigurations | S3 bucket without encryption, overly permissive security group |
| `terragrunt validate-inputs` | Wiring bugs between stack/unit/module | Stack passes `vpc_cidr` but module expects `cidr_block` |

**`terragrunt hclfmt --check`** is the HCL formatter, analogous to `gofmt` or `black`. It enforces consistent whitespace, alignment, and indentation across every `.hcl` file in the repo. The `--check` flag makes it exit non-zero if any file would change, which is what you want in CI -- the developer runs `terragrunt hclfmt` locally to fix issues, CI just verifies they did.

**`tflint`** goes deeper than `terraform validate`. Where `validate` only checks syntax and internal consistency, tflint uses provider-specific rulesets to check whether the values you are passing actually make sense. If you set `instance_type = "g5.xbig"`, `terraform validate` says "looks fine, it's a string." tflint says "that instance type does not exist in AWS." It catches typos, deprecated resource attributes, and provider-specific anti-patterns that would otherwise surface only at `apply` time. It needs a configuration file to know which rulesets to load:

```hcl
# .tflint.hcl

plugin "aws" {
  enabled = true
  version = "0.36.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
```

This enables the AWS ruleset, which knows about every EC2 instance type, every RDS engine version, and every S3 configuration option. When AWS releases new instance types or deprecates old ones, you update the ruleset version.

**`checkov`** is a static security scanner. It evaluates your Terraform modules against hundreds of built-in policies: is the S3 bucket encrypted? Is the security group open to `0.0.0.0/0`? Is the IAM policy using `*` resources? It runs against the `.tf` files directly, no state required. In the PR workflow, checkov scans every module directory and reports findings as annotations on the PR. It is not a replacement for a thorough security review, but it catches the low-hanging fruit that is easy to miss in code review.

**`terragrunt validate-inputs`** checks the wiring layer. Remember the three-layer architecture: stacks pass `values` to units, units map those values to module `inputs`. If the stack passes `vpc_cidr` but the module expects a variable named `cidr_block`, Terraform will not catch this until `plan` time -- and even then, the error message can be cryptic. `validate-inputs` compares what the unit is sending against what the module declares and flags mismatches immediately. This is especially valuable when you add a new variable to a module and forget to update one of the unit templates.

All four tools run without AWS credentials -- they are pure static analysis. This is why validation is a separate job in the PR workflow: it runs fast, costs nothing, and catches entire categories of errors before a plan ever touches the cloud.
