# Cloud LLM: Self-Hosted Coding LLM on AWS with Terragrunt Stacks

A private coding assistant -- an LLM you control, running on your own hardware, behind your own domain. No API metering, no data leaving your network, no vendor lock-in. A GPU-powered [Qwen 2.5 Coder 32B](https://huggingface.co/Qwen/Qwen2.5-Coder-32B-Instruct-AWQ) instance served by [vLLM](https://github.com/vllm-project/vllm) with an [Open WebUI](https://github.com/open-webui/open-webui) chat interface, TLS-terminated behind an ALB, addressable at `llm.yourdomain.com` -- and every piece of infrastructure defined in code with Terragrunt Stacks.

This tutorial assumes you are comfortable writing Terraform modules but have not used Terragrunt before. It focuses on what Terragrunt Stacks add -- DRY configuration, automatic remote state, dependency orchestration, and blueprint-driven environments -- by walking through a real project step by step.

## Architecture

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

The project uses a **three-layer architecture**: Terraform modules define resources, unit templates define wiring, and stack files define environments. Write the unit once, compose it everywhere.

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

## Prerequisites

- **Terraform >= 1.10** (1.11+ recommended) and **Terragrunt >= 0.78** (Stacks require 0.78+)
- **AWS account** with permissions for VPCs, EC2, S3, IAM, ALBs, ACM
- **AWS CLI** configured with credentials
- **Cloudflare account** with a managed domain and API token (`CLOUDFLARE_API_TOKEN`)
- **EC2 GPU quota** for `g5.xlarge` in your target region

See [Part 1](docs/01-why-terragrunt-stacks.md#prerequisites) for detailed prerequisites.

## Tutorial

### [Part 1: Why Terragrunt Stacks](docs/01-why-terragrunt-stacks.md)

What problems Terragrunt solves (repeated backends, manual apply ordering, environment drift) and what Stacks add on top. Introduces the architecture and the three-layer pattern.

- What problems Terragrunt solves
- What Stacks add on top
- Architecture overview and three-layer pattern

### [Part 2: Project Setup](docs/02-project-setup.md)

The directory structure, root configuration (`root.hcl`), and variable hierarchy (`common.hcl`, `env.hcl`, `region.hcl`). How `find_in_parent_folders` gives you configuration inheritance without Terragrunt-native variable inheritance.

- Directory structure
- Root configuration (remote state, providers, common inputs)
- Variable hierarchy

### [Part 3: Unit Templates](docs/03-unit-templates.md)

How to write unit templates that wire Terraform modules to their dependencies and inputs. Walks through all 8 units from the simplest (VPC, no dependencies) to the most complex (EC2 GPU, five dependencies).

- What a unit template is
- Dependencies, `mock_outputs`, and `values` passing
- Multi-provider units (Cloudflare DNS)

### [Part 4: Stack Files](docs/04-stack-files.md)

How stack files compose unit templates into a complete environment. Covers the dev stack file line by line, dependency path flow, environment value flow, and the generate/apply workflow.

- What a stack file is
- How dependency paths and environment values flow
- `terragrunt stack generate` and `terragrunt stack run apply`

### [Part 5: Deploying the Full Stack](docs/05-deploying-the-full-stack.md)

Deploying the dev environment with a single command. Covers dependency resolution order, testing the deployment, and the EC2 bootstrap script.

- Deploy command and `--backend-bootstrap`
- Dependency DAG and execution waves
- Testing the deployment

### [Part 6: Multi-Environment](docs/06-multi-environment.md)

How prod differs from dev (VPC CIDRs, instance settings) while sharing all unit templates. Creating a new environment in three files.

- Prod vs dev differences
- Creating a new environment
- The DRY payoff

### [Part 7: Day-Two Operations](docs/07-day-two-operations.md)

Operational tasks: swapping models, controlling costs, feature flags, error handling, provider caching, filtering units, and extending the stack with new components.

- Swapping the LLM model
- Cost controls and feature flags (`--feature deploy=false`)
- Provider cache, filtering, and extending the stack

### [Part 8: GitOps Pipeline](docs/08-gitops-pipeline.md)

Four GitHub Actions workflows that turn the repo into a GitOps pipeline: PR validation (lint, security scan, plan, cost estimate), deploy (auto-apply dev, gated prod), drift detection, and an infrastructure power switch.

- Composite action for shared tool installation
- PR workflow: hclfmt, tflint, checkov, validate-inputs, plan, Infracost
- Deploy workflow with environment gates
- Drift detection and infrastructure power switch

### [Recap](docs/recap.md)

Summary table mapping every Stacks concept to where it was used in the tutorial.

## Quick Start

```bash
# Deploy the dev environment
cd live/dev/us-east-1
terragrunt stack run apply --backend-bootstrap

# Verify the deployment
curl https://llm.yourdomain.com/v1/models

# Open the chat UI
open https://llm.yourdomain.com

# Tear down when done
terragrunt stack run destroy
```

See [Part 5](docs/05-deploying-the-full-stack.md) for the full deployment walkthrough.

## Project Structure

```
cloud-llm/
├── modules/                              # Terraform modules (8 components)
│   ├── vpc/
│   ├── security-groups/
│   ├── acm/
│   ├── alb/
│   ├── s3-model-cache/
│   ├── iam/
│   ├── ec2-gpu/
│   └── cloudflare-dns/
├── units/                                # Unit templates (shared wiring)
│   ├── vpc/terragrunt.hcl
│   ├── security-groups/terragrunt.hcl
│   ├── acm/terragrunt.hcl
│   ├── alb/terragrunt.hcl
│   ├── s3-model-cache/terragrunt.hcl
│   ├── iam/terragrunt.hcl
│   ├── ec2-gpu/terragrunt.hcl
│   └── cloudflare-dns/terragrunt.hcl
├── live/                                 # Stack files + config hierarchy
│   ├── root.hcl
│   ├── common.hcl
│   ├── dev/
│   │   ├── env.hcl
│   │   └── us-east-1/terragrunt.stack.hcl
│   └── prod/
│       ├── env.hcl
│       └── us-east-1/terragrunt.stack.hcl
├── .github/                              # GitOps pipeline
│   ├── workflows/
│   │   ├── pr.yml
│   │   ├── deploy.yml
│   │   ├── drift.yml
│   │   └── power.yml
│   └── actions/
│       └── terragrunt-setup/action.yml
└── docs/                                 # Tutorial (this guide)
    ├── 01-why-terragrunt-stacks.md
    ├── 02-project-setup.md
    ├── 03-unit-templates.md
    ├── 04-stack-files.md
    ├── 05-deploying-the-full-stack.md
    ├── 06-multi-environment.md
    ├── 07-day-two-operations.md
    ├── 08-gitops-pipeline.md
    └── recap.md
```
