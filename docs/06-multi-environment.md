[< Previous: Deploying the Full Stack](05-deploying-the-full-stack.md) | [Home](../README.md) | [Next: Day-Two Operations >](07-day-two-operations.md)

---

# Part 6: Multi-Environment

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

[< Previous: Deploying the Full Stack](05-deploying-the-full-stack.md) | [Home](../README.md) | [Next: Day-Two Operations >](07-day-two-operations.md)
