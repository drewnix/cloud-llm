[< Previous: Multi-Environment](06-multi-environment.md) | [Home](../README.md) | [Next: GitOps Pipeline >](08-gitops-pipeline.md)

---

# Part 7: Day-Two Operations

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

Terragrunt's `feature` block lets you define toggleable flags directly in a unit template. The ec2-gpu unit uses one:

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

[< Previous: Multi-Environment](06-multi-environment.md) | [Home](../README.md) | [Next: GitOps Pipeline >](08-gitops-pipeline.md)
