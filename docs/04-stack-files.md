[< Previous: Unit Templates](03-unit-templates.md) | [Home](../README.md) | [Next: Deploying the Full Stack >](05-deploying-the-full-stack.md)

---

# Part 4: Stack Files

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

[< Previous: Unit Templates](03-unit-templates.md) | [Home](../README.md) | [Next: Deploying the Full Stack >](05-deploying-the-full-stack.md)
