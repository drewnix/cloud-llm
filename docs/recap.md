[< Previous: GitOps Pipeline](08-gitops-pipeline.md) | [Home](../README.md)

---

# Recap

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

[< Previous: GitOps Pipeline](08-gitops-pipeline.md) | [Home](../README.md)
