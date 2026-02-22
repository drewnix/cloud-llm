[< Previous: Project Setup](02-project-setup.md) | [Home](../README.md) | [Next: Stack Files >](04-stack-files.md)

---

# Part 3: Unit Templates

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

[< Previous: Project Setup](02-project-setup.md) | [Home](../README.md) | [Next: Stack Files >](04-stack-files.md)
