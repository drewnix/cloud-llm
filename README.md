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
- [Part 8: GitOps Pipeline](#part-8-gitops-pipeline)
  - [Why a Pipeline](#why-a-pipeline)
  - [Prerequisites (CI/CD)](#prerequisites-cicd)
  - [The Composite Action](#the-composite-action)
  - [Validation & Linting](#validation--linting)
  - [The PR Workflow](#the-pr-workflow)
  - [The Deploy Workflow](#the-deploy-workflow)
  - [Drift Detection](#drift-detection)
  - [Infrastructure Power Switch](#infrastructure-power-switch)
  - [Pipeline Best Practices](#pipeline-best-practices)
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
| **Composite action** | `.github/actions/terragrunt-setup/` -- DRY tool installation across all workflows |
| **PR validation** | `pr.yml` -- hclfmt, tflint, checkov, validate-inputs, plan, cost estimate |
| **Environment gates** | `deploy.yml` -- auto-apply dev, reviewer approval for prod via GitHub Environments |
| **Drift detection** | `drift.yml` -- scheduled plan with GitHub Issue reporting |
| **Power switch** | `power.yml` -- full-on / standby / full-off via workflow dispatch |
| **OIDC federation** | Short-lived AWS credentials from GitHub Actions, no stored keys |
| **`--filter-affected` (CI)** | PR and deploy workflows plan/apply only units affected by the change |

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

### The PR Workflow

The PR workflow is the heaviest workflow in the pipeline -- it is where all validation happens before code reaches `main`. If something is wrong with your change, the PR workflow should catch it here, not after a merge. Reviewers should never have to approve a PR that has a red CI status.

The workflow runs in two phases. The first phase, **validate**, is fast and needs no AWS credentials. It runs `terragrunt hclfmt`, tflint, checkov, and `validate-inputs` -- the same four tools from the section above. The second phase, **plan**, needs AWS credentials (obtained via OIDC) and runs once per environment in the matrix. It generates a Terraform plan and a cost estimate, then posts both as a PR comment so reviewers can see exactly what the change will do to infrastructure and what it will cost.

This two-phase design means the cheap checks happen first. If you have a formatting issue or a security misconfiguration, you find out in under a minute -- before the plan job ever requests AWS credentials or runs `terraform init`. The plan job depends on validate (`needs: validate`), so it only runs if the static checks pass.

```
PR opened/updated
    |
    +-- Job: validate (no AWS creds)
    |   +-- terragrunt hclfmt --check
    |   +-- tflint (all modules/)
    |   +-- checkov (all modules/)
    |   +-- terragrunt validate-inputs
    |
    +-- Job: plan (OIDC creds, per environment)
        +-- terragrunt stack run plan --filter-affected
        +-- infracost diff
        +-- Post PR comment (plan + cost)
```

Here is the full workflow file:

```yaml
# .github/workflows/pr.yml

name: PR Validation & Plan

on:
  pull_request:
    branches: [main]
    paths:
      - 'modules/**'
      - 'units/**'
      - 'live/**'

permissions:
  id-token: write
  contents: read
  pull-requests: write

env:
  TG_PROVIDER_CACHE: "1"

jobs:
  # -------------------------------------------------------
  # Job 1: Static validation (no AWS credentials needed)
  # -------------------------------------------------------
  validate:
    name: Validate
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup tools
        uses: ./.github/actions/terragrunt-setup

      - name: Check HCL formatting
        run: terragrunt hclfmt --check

      - name: Init tflint
        run: tflint --init --config "$GITHUB_WORKSPACE/.tflint.hcl"

      - name: Lint Terraform modules
        run: |
          exit_code=0
          for dir in modules/*/; do
            echo "::group::tflint - $dir"
            if ! tflint --config "$GITHUB_WORKSPACE/.tflint.hcl" "$dir"; then
              exit_code=1
            fi
            echo "::endgroup::"
          done
          exit $exit_code

      - name: Security scan
        run: checkov -d modules/ --framework terraform --quiet --compact

  # -------------------------------------------------------
  # Job 2: Plan per environment (needs AWS credentials)
  # -------------------------------------------------------
  plan:
    name: Plan (${{ matrix.environment }})
    runs-on: ubuntu-latest
    needs: validate
    strategy:
      fail-fast: false
      matrix:
        include:
          - environment: dev
            working_directory: live/dev/us-east-1
          - environment: prod
            working_directory: live/prod/us-east-1
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup tools
        uses: ./.github/actions/terragrunt-setup

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_ROLE_ARN }}
          aws-region: us-east-1

      - name: Terragrunt plan
        id: plan
        working-directory: ${{ matrix.working_directory }}
        continue-on-error: true
        run: |
          set -o pipefail
          terragrunt stack run plan --filter-affected -no-color 2>&1 | tee plan.txt
          echo "exitcode=${PIPESTATUS[0]}" >> "$GITHUB_OUTPUT"

      - name: Setup Infracost
        uses: infracost/actions/setup@v3
        with:
          api-key: ${{ secrets.INFRACOST_API_KEY }}

      - name: Generate cost estimate
        id: infracost
        working-directory: ${{ matrix.working_directory }}
        continue-on-error: true
        run: |
          infracost breakdown \
            --path ".terragrunt-stack" \
            --format json \
            --out-file infracost.json
          infracost output \
            --path infracost.json \
            --format github-comment \
            --out-file infracost-comment.txt

      - name: Build PR comment
        id: comment
        run: |
          {
            echo "### Terragrunt Plan: \`${{ matrix.environment }}\`"
            echo ""
            echo "<details>"
            echo "<summary>Plan output (click to expand)</summary>"
            echo ""
            echo '```'
            cat "${{ matrix.working_directory }}/plan.txt"
            echo '```'
            echo ""
            echo "</details>"
            echo ""
            if [ -f "${{ matrix.working_directory }}/infracost-comment.txt" ]; then
              echo "#### Cost Estimate"
              echo ""
              cat "${{ matrix.working_directory }}/infracost-comment.txt"
            fi
          } > comment.md

      - name: Post PR comment
        uses: marocchino/sticky-pull-request-comment@v2
        with:
          header: plan-${{ matrix.environment }}
          path: comment.md

      - name: Fail if plan errored
        if: steps.plan.outputs.exitcode == '1'
        run: exit 1
```

Let's walk through the key pieces.

**`on.pull_request.paths`** -- The workflow only triggers when files under `modules/`, `units/`, or `live/` change. A README edit, a CI script tweak, or a documentation update does not spin up the pipeline. This saves CI minutes and reduces noise -- your team does not get pinged with plan comments on a typo fix.

**`permissions`** -- Three permissions, each for a specific purpose. `id-token: write` enables OIDC authentication -- the workflow proves its identity to AWS without storing long-lived access keys as secrets. This is the same authentication pattern described in the Prerequisites section. `contents: read` allows checking out the repository code. `pull-requests: write` allows the workflow to post plan comments on the PR. If you forget `pull-requests: write`, the plan runs fine but the comment step fails silently.

**`TG_PROVIDER_CACHE: "1"`** -- This is the environment variable equivalent of the `--provider-cache` flag from Part 7's Provider Cache section. Setting it as a workflow-level environment variable means every Terragrunt command in every job gets provider caching automatically. Without it, each unit in the stack would download its own copy of the AWS provider plugin, wasting time and bandwidth. With it, the provider is downloaded once and shared across all units.

**The validate job** runs without AWS credentials -- it never calls `aws-actions/configure-aws-credentials`. Each step catches a different category of error: formatting (hclfmt), Terraform-specific issues (tflint), security misconfigurations (checkov). The `for dir in modules/*/` loop runs tflint against each module independently rather than as a single invocation. This means a lint error in the VPC module does not prevent linting the ALB module. The `::group::` and `::endgroup::` markers create collapsible sections in the GitHub Actions log, so the output stays organized even with 8 modules.

**The plan job matrix** uses `fail-fast: false`, which means both environments get planned even if one fails. This is important: a failure in the dev plan should not prevent you from seeing the prod plan. During early development especially, one environment might fail (maybe the VPC does not exist yet) while the other succeeds. The matrix includes both the environment name (for display in the job title and PR comment header) and the working directory (for the Terragrunt commands). The `needs: validate` dependency ensures plans only run after static validation passes.

**`continue-on-error: true` on the plan step** lets the workflow continue to the comment-posting steps even when the plan itself fails. This is a deliberate design choice. Without it, a plan failure would skip the PR comment steps, and the reviewer would have to dig through the raw workflow logs to understand what went wrong. With `continue-on-error`, the plan failure gets captured in `plan.txt`, packaged into a formatted PR comment, and posted for the reviewer to read directly on the PR. The explicit "Fail if plan errored" step at the end of the job checks `steps.plan.outputs.exitcode` and exits non-zero, so the job still reports failure in the GitHub status check. You get the best of both worlds: the reviewer sees the error inline, and the PR shows a red check.

**The Infracost steps** generate a cost estimate alongside the plan. `infracost breakdown` reads the plan files from the `.terragrunt-stack` directory (where Terragrunt generates its working files) and produces a JSON cost estimate. `infracost output` converts that JSON into a GitHub-flavored markdown comment. The cost estimate appears in the PR comment alongside the plan, so reviewers see both what changes and what it costs. If you change an instance type from `g5.xlarge` to `g5.2xlarge`, the cost estimate shows the monthly delta. The `continue-on-error: true` on this step means a missing Infracost API key or a parsing error does not block the plan comment from posting -- cost is informational, not a gate.

**`marocchino/sticky-pull-request-comment`** is the action that posts the PR comment. The `header` parameter (`plan-dev` or `plan-prod`) is the key: it tells the action to update the same comment on each push to the PR rather than creating a new one. Without this, every push would create a new comment, and a PR with 10 pushes would have 20 plan comments (one dev + one prod per push), burying the conversation in noise. The sticky behavior means there are always exactly two plan comments on the PR -- one for dev, one for prod -- and they always show the latest plan.

**Required status checks** -- The validate job should be configured as a required status check in your repository's branch protection rules (Settings > Branches > Branch protection rules > Require status checks). This prevents merging a PR that has formatting issues, lint errors, or security findings. The plan job is informational -- it posts output for reviewers but should not block merge. During early development, before all dependencies exist, plan failures are expected. A new module might reference a VPC that has not been created yet. The plan comment helps reviewers understand the scope of the change; the validate check ensures code quality.

### The Deploy Workflow

Once a PR is merged, the deploy workflow takes over. It applies changes to dev automatically and gates prod behind a reviewer approval. There is no manual `terragrunt apply` from someone's laptop -- the merge to `main` is the trigger, and every deployment is traceable to a specific commit and PR in the git history.

This is the core of the GitOps model you have been building toward. The infrastructure code is the source of truth. A pull request proposes a change, the PR workflow shows the plan, reviewers approve, the merge triggers the deploy. If something breaks, you revert the commit. If you want to know what changed and when, you read the git log. No more "who ran apply and from where?"

The two-job structure -- dev then prod -- means dev always gets changes first. If something breaks in dev, prod is protected. The `needs: deploy-dev` dependency enforces this ordering: prod never runs unless dev succeeds. This is a lightweight soak period -- your changes prove themselves in dev before reaching production.

```
Push to main
    |
    +-- Job: deploy-dev
    |   +-- environment: dev (no approval gate)
    |   +-- terragrunt stack run plan --filter-affected
    |   +-- terragrunt stack run apply --filter-affected
    |
    +-- Job: deploy-prod
        +-- environment: prod (required reviewer)
        +-- Workflow pauses -> reviewer gets notification
        +-- Reviewer approves in GitHub UI
        +-- terragrunt stack run plan --filter-affected
        +-- terragrunt stack run apply --filter-affected
```

Here is the full workflow file:

```yaml
# .github/workflows/deploy.yml

name: Deploy

on:
  push:
    branches: [main]
    paths:
      - 'modules/**'
      - 'units/**'
      - 'live/**'

permissions:
  id-token: write
  contents: read

env:
  TG_PROVIDER_CACHE: "1"

jobs:
  # -------------------------------------------------------
  # Job 1: Deploy to dev (no approval gate)
  # -------------------------------------------------------
  deploy-dev:
    name: Deploy Dev
    runs-on: ubuntu-latest
    environment: dev
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup tools
        uses: ./.github/actions/terragrunt-setup

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_ROLE_ARN }}
          aws-region: us-east-1

      - name: Plan
        working-directory: live/dev/us-east-1
        run: |
          terragrunt stack run plan \
            --filter-affected \
            --feature deploy=${{ vars.GPU_ENABLED || 'true' }} \
            -no-color

      - name: Apply
        working-directory: live/dev/us-east-1
        run: |
          terragrunt stack run apply \
            --filter-affected \
            --feature deploy=${{ vars.GPU_ENABLED || 'true' }} \
            -auto-approve

  # -------------------------------------------------------
  # Job 2: Deploy to prod (requires reviewer approval)
  # -------------------------------------------------------
  deploy-prod:
    name: Deploy Prod
    runs-on: ubuntu-latest
    needs: deploy-dev
    environment: prod
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup tools
        uses: ./.github/actions/terragrunt-setup

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_ROLE_ARN }}
          aws-region: us-east-1

      - name: Plan
        working-directory: live/prod/us-east-1
        run: |
          terragrunt stack run plan \
            --filter-affected \
            --feature deploy=${{ vars.GPU_ENABLED || 'true' }} \
            -no-color

      - name: Apply
        working-directory: live/prod/us-east-1
        run: |
          terragrunt stack run apply \
            --filter-affected \
            --feature deploy=${{ vars.GPU_ENABLED || 'true' }} \
            -auto-approve
```

Let's walk through the key pieces.

**`on.push.branches: [main]`** -- The workflow triggers on pushes to `main`, which means merges from pull requests. It does not run on feature branches. The same `paths` filter from the PR workflow is here too: only changes to `modules/`, `units/`, or `live/` trigger a deploy. This means merging a documentation-only PR does not kick off an unnecessary apply cycle.

**`environment: dev` and `environment: prod`** -- These link each job to the GitHub Environments you configured in the Prerequisites section. When a job specifies `environment: dev`, GitHub does two things: it injects that environment's variables (like `AWS_ROLE_ARN` and `GPU_ENABLED`) and it enforces that environment's protection rules. The `dev` environment has no protection rules, so `deploy-dev` runs immediately after checkout. The `prod` environment has a required reviewer, so `deploy-prod` pauses the moment it starts and sends a notification to the designated reviewer. The workflow does not contain any conditional logic to implement this gate -- the environment protection rule handles it entirely.

**`needs: deploy-dev`** -- Prod depends on dev succeeding. If `deploy-dev` fails, `deploy-prod` never runs. This is the soak step: changes prove themselves in dev before reaching prod. If a module change causes an apply error in dev (maybe a new resource conflicts with an existing one, or an API call fails), prod is protected. You fix the issue, push another commit, and the pipeline runs again.

**`${{ vars.GPU_ENABLED || 'true' }}`** -- This reads the `GPU_ENABLED` variable from the GitHub Environment. It defaults to `true` if the variable is not set. This ties directly into the power switch workflow you will see later: if you set `GPU_ENABLED=false` in the environment settings, deploys will skip the GPU instance. The `--feature deploy=...` flag maps to the `feature "deploy"` block in the ec2-gpu unit template from Part 3. When `deploy` is `false`, the ec2-gpu unit is excluded from the stack -- no instance is created, no cost is incurred. When `deploy` is `true` (the default), the full stack deploys including the GPU instance.

**Plan before apply** -- Each job runs `terragrunt stack run plan` before `terragrunt stack run apply`. The plan step is not strictly required (apply would generate a plan internally), but running it explicitly serves two purposes. First, the plan output appears in the workflow logs, giving anyone reviewing the deployment visibility into exactly what was applied. Second, if something looks wrong in the plan, the reviewer who approved the prod deployment can cancel the workflow run before the apply step starts.

**`-auto-approve`** -- Terraform's `apply` command normally prompts "Do you want to perform these actions?" and waits for you to type `yes`. In CI, there is no interactive terminal, so `-auto-approve` skips that prompt. This is safe because the approval gate is not the Terraform prompt -- it is the GitHub Environment protection rule. For dev, the gate is the PR review (you merged to main, so someone already reviewed the change). For prod, the gate is the environment reviewer who must explicitly approve the deployment in the GitHub UI.

**The reviewer experience** -- Here is what happens from the reviewer's perspective when a PR is merged. The deploy workflow starts. `deploy-dev` runs immediately -- it plans and applies to dev. If it succeeds, `deploy-prod` starts, but immediately pauses because the `prod` environment has a required reviewer. The designated reviewer gets a GitHub notification (email, mobile, or in the GitHub UI depending on their settings). They click through to the workflow run, where they can see the `deploy-dev` logs (including the plan and apply output) to verify the change worked in dev. The `deploy-prod` job shows a yellow "Waiting" badge. The reviewer clicks "Review deployments", selects the `prod` environment, and clicks "Approve and deploy." The job resumes, runs the prod plan and apply, and the deployment is complete. If something looks wrong in the dev logs, the reviewer clicks "Reject" instead, and prod is never touched.

### Drift Detection

Infrastructure drift happens when the real state of your resources diverges from what the code defines. The causes are varied and sometimes subtle: someone logs into the AWS console and tweaks a security group rule to fix an urgent issue, an auto-scaling event modifies a resource outside of Terraform's control, or a provider upgrade changes default behavior on a resource you thought was stable. Any of these scenarios leaves your infrastructure in a state that no longer matches the code on `main`.

Without active detection, drift is invisible. Everything looks fine in your repository -- the code has not changed, the last deploy succeeded, the PR history is clean. Then one day you run `terragrunt plan` and discover 14 unexpected changes, and you have no idea when they happened or why. A nightly plan is a smoke alarm. It runs against your live infrastructure on a schedule and tells you the moment reality stops matching your code. You find out about drift in a GitHub Issue the next morning, not during a production incident three weeks later.

The drift workflow runs `terragrunt stack run plan` against every unit in an environment. If the plan shows changes -- meaning the real infrastructure differs from what the code defines -- the workflow opens a GitHub Issue with the plan output so the team can investigate. If no changes are detected, the workflow exits silently. You only hear about problems.

Here is the full workflow file:

```yaml
# .github/workflows/drift.yml

name: Drift Detection

on:
  schedule:
    - cron: '0 6 * * *'   # Daily at 6am UTC
  workflow_dispatch:        # Allow manual trigger

permissions:
  id-token: write
  contents: read
  issues: write

env:
  TG_PROVIDER_CACHE: "1"

jobs:
  detect-drift:
    name: Drift Check (${{ matrix.environment }})
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        include:
          - environment: dev
            working_directory: live/dev/us-east-1
          - environment: prod
            working_directory: live/prod/us-east-1
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup tools
        uses: ./.github/actions/terragrunt-setup

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_ROLE_ARN }}
          aws-region: us-east-1

      - name: Terragrunt plan (detect drift)
        id: plan
        working-directory: ${{ matrix.working_directory }}
        continue-on-error: true
        run: |
          set -o pipefail
          terragrunt stack run plan -no-color -detailed-exitcode 2>&1 | tee plan.txt
          echo "exitcode=${PIPESTATUS[0]}" >> "$GITHUB_OUTPUT"

      # Exit code 0 = no changes, 1 = error, 2 = changes detected (drift)
      - name: Open or update drift issue
        if: steps.plan.outputs.exitcode == '2'
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          ENV_NAME: ${{ matrix.environment }}
          WORKING_DIR: ${{ matrix.working_directory }}
        run: |
          DATE=$(date +%Y-%m-%d)
          TITLE="Drift detected in ${ENV_NAME} - ${DATE}"

          # Build issue body with plan output
          PLAN_OUTPUT=$(cat plan.txt)
          BODY="## Drift Detected

          Infrastructure state in the **${ENV_NAME}** environment does not match the code on \`main\` as of ${DATE}.

          <details>
          <summary>Plan output (click to expand)</summary>

          \`\`\`
          ${PLAN_OUTPUT}
          \`\`\`

          </details>

          **Next steps:**
          - If the drift is intentional (e.g., manual scaling), update the code to match.
          - If unintentional, re-apply from the Infrastructure Power workflow or run:
            \`\`\`
            cd ${WORKING_DIR} && terragrunt stack run apply
            \`\`\`"

          # Check for existing open drift issue for this environment
          EXISTING=$(gh issue list \
            --label "drift,${ENV_NAME}" \
            --state open \
            --limit 1 \
            --json number \
            -q '.[0].number')

          if [ -n "$EXISTING" ]; then
            echo "Updating existing drift issue #${EXISTING}"
            gh issue comment "$EXISTING" --body "$BODY"
          else
            echo "Creating new drift issue"
            gh issue create \
              --title "$TITLE" \
              --body "$BODY" \
              --label "drift,${ENV_NAME}"
          fi

      - name: No drift detected
        if: steps.plan.outputs.exitcode == '0'
        run: echo "No drift detected in ${{ matrix.environment }}"

      - name: Plan error
        if: steps.plan.outputs.exitcode == '1'
        run: |
          echo "::error::Plan failed for ${{ matrix.environment }} -- check logs"
          exit 1
```

Let's walk through the key pieces.

**`schedule` and `workflow_dispatch`** -- The workflow runs on a cron schedule: daily at 6am UTC. This means every morning when you check GitHub, any drift that occurred overnight is already waiting as an issue. The `workflow_dispatch` trigger lets you run it manually at any time. This is useful after a known console change -- if someone manually adjusted a security group rule to unblock a deployment, you can immediately check whether the fix introduced drift and then update the code to match.

**No `--filter-affected`** -- Notice that this workflow runs a plain `terragrunt stack run plan` without the `--filter-affected` flag you saw in the PR and deploy workflows. This is deliberate. The `--filter-affected` flag limits the plan to units affected by recent code changes. But drift detection is not about code changes -- it is about catching changes that happened *outside* of code. Someone modifying a security group in the AWS console would never show up in `--filter-affected` because no `.hcl` or `.tf` file changed. Drift detection needs to plan against everything.

**`-detailed-exitcode`** -- Terraform uses exit codes to communicate plan results: `0` means no changes (infrastructure matches code exactly), `1` means an error occurred (authentication failure, API error, invalid configuration), and `2` means changes were detected (drift). This is how the workflow distinguishes between "everything is fine" and "something changed." The `continue-on-error: true` on the plan step prevents the workflow from stopping on exit code 2, and the `PIPESTATUS[0]` captures the real exit code through the `tee` pipe so the subsequent steps can branch on it.

**The issue creation logic** -- When drift is detected (exit code 2), the workflow uses `gh issue list` to check for an existing open issue labeled with both `drift` and the environment name (e.g., `drift,dev`). If one exists, it adds a comment with the new plan output -- this avoids creating duplicate issues when drift persists across multiple runs. If no existing issue is found, it creates a new one. The plan output is wrapped in a `<details>` block so it does not overwhelm the issue tracker with hundreds of lines of Terraform output. Readers click to expand when they want the details.

**The error handling step** -- Exit code 1 (plan error) gets its own step that emits a `::error::` annotation and exits non-zero. This marks the workflow run as failed in the GitHub Actions UI, which is distinct from drift detection. Drift (exit code 2) is an expected outcome that creates an issue; an error (exit code 1) is something wrong with the plan itself -- maybe the OIDC credentials expired, or a provider API is down. You want to know about both, but through different channels.

**Tuning the schedule** -- The daily cron (`'0 6 * * *'`) suits active development where infrastructure changes frequently. For stable production environments that rarely change, a weekly check may be enough. Adjust the cron expression to match your needs: `'0 6 * * 1'` for Mondays only, `'0 6 * * 1-5'` for weekdays, or `'0 6 1 * *'` for the first day of each month. You can also set different schedules per environment by splitting the matrix into separate jobs with separate cron triggers.

### Infrastructure Power Switch

GPU instances cost roughly $1 per hour on-demand. For a tutorial project that you use a few hours a week, leaving infrastructure running 24/7 wastes hundreds of dollars a month. You need a way to turn things on and off without SSH-ing into a machine or running Terragrunt commands from your laptop.

The power switch is a `workflow_dispatch` workflow with dropdown menus in the GitHub Actions UI. You navigate to Actions, select the "Infrastructure Power" workflow, pick an environment from one dropdown, pick an action from another, and click "Run workflow." No CLI, no AWS console, no Terraform knowledge required. Anyone on the team can manage infrastructure costs.

Three power tiers map to different cost profiles:

| Mode | What Happens | Ongoing Cost | Restart Time |
|---|---|---|---|
| **full-on** | Everything running, GPU active | ~$1/hr+ | -- |
| **standby** | GPU destroyed, networking stays | ~$50/mo | ~5 min |
| **full-off** | Entire environment destroyed | $0 | ~10-15 min |

For tutorial readers, **full-off is the recommended default**. When you are done working for the day, run `full-off` and your ongoing cost drops to zero. Standby is useful during active development days when you are iterating on the model serving configuration and want fast GPU restarts without waiting for the VPC, ALB, and DNS to recreate. Full-on is for when you are actively using the infrastructure.

Here is the full workflow file:

```yaml
# .github/workflows/power.yml

name: Infrastructure Power

on:
  workflow_dispatch:
    inputs:
      environment:
        description: 'Target environment'
        required: true
        type: choice
        options:
          - dev
          - prod
      action:
        description: 'Power action'
        required: true
        type: choice
        options:
          - plan-only
          - full-on
          - standby
          - full-off

permissions:
  id-token: write
  contents: read

env:
  TG_PROVIDER_CACHE: "1"

jobs:
  power:
    name: "${{ inputs.action }} (${{ inputs.environment }})"
    runs-on: ubuntu-latest
    environment: ${{ inputs.environment }}
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup tools
        uses: ./.github/actions/terragrunt-setup

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_ROLE_ARN }}
          aws-region: us-east-1

      - name: Set working directory
        id: dir
        run: echo "path=live/${{ inputs.environment }}/us-east-1" >> "$GITHUB_OUTPUT"

      # ---- Plan Only ----
      - name: Plan
        if: inputs.action == 'plan-only'
        working-directory: ${{ steps.dir.outputs.path }}
        run: terragrunt stack run plan -no-color

      # ---- Full On: apply entire stack with GPU ----
      - name: Full On
        if: inputs.action == 'full-on'
        working-directory: ${{ steps.dir.outputs.path }}
        run: |
          terragrunt stack run apply \
            --feature deploy=true \
            -auto-approve

      # ---- Standby: GPU off, networking stays ----
      - name: Standby
        if: inputs.action == 'standby'
        working-directory: ${{ steps.dir.outputs.path }}
        run: |
          terragrunt stack run apply \
            --feature deploy=false \
            -auto-approve

      # ---- Full Off: destroy entire environment ----
      - name: Full Off
        if: inputs.action == 'full-off'
        working-directory: ${{ steps.dir.outputs.path }}
        run: |
          terragrunt stack run destroy -auto-approve

      - name: Summary
        run: |
          echo "## Infrastructure Power: ${{ inputs.action }}" >> "$GITHUB_STEP_SUMMARY"
          echo "" >> "$GITHUB_STEP_SUMMARY"
          echo "**Environment:** ${{ inputs.environment }}" >> "$GITHUB_STEP_SUMMARY"
          echo "**Action:** ${{ inputs.action }}" >> "$GITHUB_STEP_SUMMARY"
          echo "" >> "$GITHUB_STEP_SUMMARY"
          case "${{ inputs.action }}" in
            full-on)  echo "All infrastructure is running. GPU instance is active." >> "$GITHUB_STEP_SUMMARY" ;;
            standby)  echo "GPU instance destroyed. Networking, ALB, DNS remain (~\$50/mo)." >> "$GITHUB_STEP_SUMMARY" ;;
            full-off) echo "All infrastructure destroyed. Zero ongoing cost." >> "$GITHUB_STEP_SUMMARY" ;;
            plan-only) echo "No changes applied. Review the plan output above." >> "$GITHUB_STEP_SUMMARY" ;;
          esac
```

Let's walk through the key pieces.

**`workflow_dispatch.inputs`** -- The `type: choice` parameter creates dropdown menus in the GitHub Actions UI. When you click "Run workflow" on this workflow, you see two dropdowns instead of free-text fields. This prevents typos -- you cannot accidentally type "devv" or "prod " with a trailing space. Notice that `plan-only` is listed first in the action options, which makes it the default selection. This is a safety measure: if you click "Run workflow" without changing the action dropdown, you get a plan preview rather than accidentally destroying production.

**`environment: ${{ inputs.environment }}`** -- The job targets whichever environment you select from the dropdown. This is the same `environment` mechanism from the deploy workflow, and it carries the same implications. If your `prod` environment has required reviewers configured in GitHub's environment protection rules, even the power switch requires approval before it touches prod. You cannot accidentally destroy production -- the reviewer gate applies to every workflow that references the environment, not just the deploy workflow.

**Conditional steps** -- Each `if: inputs.action == '...'` guard ensures only the matching step runs. The four actions map to different Terragrunt commands:

- **`full-on`** runs `terragrunt stack run apply --feature deploy=true`, which applies the entire stack including the GPU instance. The `--feature deploy=true` flag maps to the same `feature "deploy"` block in the ec2-gpu unit template that the deploy workflow uses. Everything comes up.
- **`standby`** runs `terragrunt stack run apply --feature deploy=false`. This is the feature flag from Part 7's ec2-gpu unit -- when `deploy` is `false`, the ec2-gpu unit is excluded from the stack. The GPU instance is destroyed, but the VPC, security groups, ALB, DNS, and all other networking infrastructure stays in place. Restarting from standby only needs to create the EC2 instance and its associated resources, which takes about 5 minutes instead of the 10-15 minutes required to rebuild everything from scratch.
- **`full-off`** runs `terragrunt stack run destroy`, which tears down every resource in the environment. Your ongoing cost drops to zero. The S3 model cache bucket may remain if it has objects in it (Terraform will not destroy a non-empty bucket by default), but the compute and networking costs disappear entirely.
- **`plan-only`** runs `terragrunt stack run plan`, which shows what would happen without making any changes. Use this to verify the current state before taking action.

**`$GITHUB_STEP_SUMMARY`** -- The Summary step writes a markdown block to the workflow run's summary page. After the workflow finishes, you see a clean summary at the top of the run page: the environment, the action, and a human-readable description of what happened. This saves you from scrolling through raw Terraform logs to answer "did it work?"

**Scheduled power management** -- For teams that want automatic cost savings, you can add a cron-triggered variant of this workflow. The idea is straightforward: destroy the dev environment every evening and recreate it every morning.

```yaml
# Example: scheduled power management
on:
  schedule:
    - cron: '0 22 * * 1-5'  # Off at 10pm UTC weeknights
    - cron: '0 13 * * 1-5'  # On at 1pm UTC (9am ET) weekdays
```

This is left as an exercise for the reader. Duplicate the power workflow, replace `workflow_dispatch` with a `schedule` trigger, and hardcode the inputs (environment and action) based on which cron expression fired. The savings are significant: running a GPU instance only during business hours cuts your compute cost by roughly 65%.

### Pipeline Best Practices

The four workflows -- PR validation, deploy, drift detection, and power switch -- form a complete GitOps pipeline. Here are practical recommendations for hardening it.

**OIDC Over Static Keys** -- The OIDC authentication you configured in the Prerequisites section is not just convenient, it is a security boundary. OIDC credentials are scoped to a single workflow run and expire when the run finishes. There are no long-lived AWS access keys to rotate, no risk of a leaked key granting permanent access to your account. If you must store secrets (like the Infracost API key), use GitHub's encrypted secrets and reference them with `${{ secrets.SECRET_NAME }}` -- never hardcode credentials in workflow files or commit them to the repository.

**Fork PR Security** -- GitHub requires maintainer approval before running workflows on pull requests from first-time contributors. Keep this default enabled (Settings > Actions > General > "Require approval for first-time contributors"). Fork PRs never get access to your repository secrets or OIDC credentials, even on public repositories. This means a malicious fork cannot modify a workflow file to exfiltrate your AWS credentials -- the workflow simply will not run until a maintainer approves it.

**Branch Protection** -- Enable branch protection on `main`: require pull request reviews, require the `Validate` status check to pass, and prevent direct pushes (Settings > Branches > Add rule). This ensures every infrastructure change goes through the validation pipeline. No one can push a broken HCL format, a lint violation, or a security misconfiguration directly to `main`. The PR workflow catches it, the reviewer evaluates it, and only clean code gets merged.

**CODEOWNERS** -- A `CODEOWNERS` file lets you require specific reviewers for sensitive paths. For example:

```
# .github/CODEOWNERS
/live/prod/ @your-github-username
```

With this file in place and "Require review from Code Owners" enabled in branch protection, any PR that touches files under `live/prod/` requires explicit approval from the designated owner. Changes to dev can be reviewed by anyone on the team, but production changes need sign-off from the person responsible. This is especially valuable as your team grows.

**Required Status Checks** -- Configure the `Validate` job as a required status check in your branch protection rules. This means a PR cannot be merged if formatting, linting, or security scanning fails. The `Plan` job should remain non-required -- plans can legitimately fail before dependencies exist. When you add a new unit whose VPC dependency has not been applied yet, the plan will fail, but that is expected. The plan comment helps reviewers understand the scope of the change; the validate check ensures code quality. Making the plan required would block legitimate PRs during early development.
