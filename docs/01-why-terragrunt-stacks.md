[Home](../README.md) | [Next: Project Setup >](02-project-setup.md)

---

# Part 1: Why Terragrunt Stacks

### What Problems Terragrunt Solves

If you have shipped Terraform to production, you have probably run into these pain points:

* **Repeated backend configuration.** Every module needs a `backend "s3"` block. Copy it once, fine. Copy it across 8 modules and 2 environments and you have 16 nearly identical blocks to keep in sync.

* **Repeated provider blocks.** Same story. Every module declares `provider "aws" { region = "us-east-1" }` and you update them one at a time when something changes.

* **No dependency orchestration.** Terraform operates on one state file at a time. If your security groups need the VPC ID, you either put everything in one giant state (fragile, slow) or you glue modules together with `terraform_remote_state` data sources and hope you remember the apply order.

* **Environment drift.** Dev and prod diverge because they are separate directories with duplicated `.tf` files. A variable added in dev never makes it to prod, or worse, the wrong value does.

Terragrunt solves all four:

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

[Home](../README.md) | [Next: Project Setup >](02-project-setup.md)
