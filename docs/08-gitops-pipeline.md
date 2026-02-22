[< Previous: Day-Two Operations](07-day-two-operations.md) | [Home](../README.md) | [Next: Recap >](recap.md)

---

# Part 8: GitOps Pipeline

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

The workflow runs in two phases. The first phase, **validate**, is fast and needs no AWS credentials. It runs `terragrunt hclfmt`, tflint, checkov, and `validate-inputs` -- [the same four tools from the section above](#validation--linting). The second phase, **plan**, needs AWS credentials (obtained via OIDC) and runs once per environment in the matrix. It generates a Terraform plan and a cost estimate, then posts both as a PR comment so reviewers can see exactly what the change will do to infrastructure and what it will cost.

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

      - name: Validate Terragrunt inputs
        run: |
          for dir in live/*/us-east-1/; do
            echo "::group::validate-inputs - $dir"
            cd "$GITHUB_WORKSPACE/$dir"
            terragrunt stack generate
            cd .terragrunt-stack
            terragrunt run-all validate-inputs --terragrunt-non-interactive
            cd "$GITHUB_WORKSPACE"
            echo "::endgroup::"
          done

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
        with:
          fetch-depth: 0

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

**`permissions`** -- Three permissions, each for a specific purpose. `id-token: write` enables OIDC authentication -- the workflow proves its identity to AWS without storing long-lived access keys as secrets. This is the same authentication pattern described in [Prerequisites (CI/CD)](#prerequisites-cicd). `contents: read` allows checking out the repository code. `pull-requests: write` allows the workflow to post plan comments on the PR. If you forget `pull-requests: write`, the plan runs fine but the comment step fails silently.

**`TG_PROVIDER_CACHE: "1"`** -- This is the environment variable equivalent of the `--provider-cache` flag from [Provider Cache](07-day-two-operations.md#provider-cache). Setting it as a workflow-level environment variable means every Terragrunt command in every job gets provider caching automatically. Without it, each unit in the stack would download its own copy of the AWS provider plugin, wasting time and bandwidth. With it, the provider is downloaded once and shared across all units.

**The validate job** runs without AWS credentials -- it never calls `aws-actions/configure-aws-credentials`. Each step catches a different category of error: formatting (hclfmt), Terraform-specific issues (tflint), security misconfigurations (checkov), and wiring mismatches (validate-inputs). The `for dir in modules/*/` loop runs tflint against each module independently rather than as a single invocation. This means a lint error in the VPC module does not prevent linting the ALB module. The `::group::` and `::endgroup::` markers create collapsible sections in the GitHub Actions log, so the output stays organized even with 8 modules. The final `validate-inputs` step iterates over every environment directory, generates the stack, and runs `terragrunt run-all validate-inputs` to verify that the values each unit passes match what the corresponding Terraform module expects. This catches wiring bugs -- like a stack passing `vpc_cidr` when the module expects `cidr_block` -- before a plan ever touches AWS.

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

concurrency:
  group: deploy-${{ github.ref }}
  cancel-in-progress: false

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
        with:
          fetch-depth: 0

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
            -auto-approve \
            -no-color

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
        with:
          fetch-depth: 0

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
            -auto-approve \
            -no-color
```

Let's walk through the key pieces.

**`on.push.branches: [main]`** -- The workflow triggers on pushes to `main`, which means merges from pull requests. It does not run on feature branches. The same `paths` filter from the PR workflow is here too: only changes to `modules/`, `units/`, or `live/` trigger a deploy. This means merging a documentation-only PR does not kick off an unnecessary apply cycle.

**`concurrency`** -- The `concurrency` block with `group: deploy-${{ github.ref }}` prevents parallel deploys from racing. If two PRs merge to `main` in quick succession, the second deploy workflow will wait for the first to finish rather than running simultaneously. Without this, two concurrent `terragrunt stack run apply` invocations could attempt to modify the same Terraform state at the same time, leading to state lock conflicts or, worse, interleaved resource changes that leave infrastructure in an inconsistent state. The `cancel-in-progress: false` setting ensures the first deploy runs to completion rather than being cancelled by the second -- you never want a half-applied infrastructure change.

**`environment: dev` and `environment: prod`** -- These link each job to the GitHub Environments you configured in [Prerequisites (CI/CD)](#prerequisites-cicd). When a job specifies `environment: dev`, GitHub does two things: it injects that environment's variables (like `AWS_ROLE_ARN` and `GPU_ENABLED`) and it enforces that environment's protection rules. The `dev` environment has no protection rules, so `deploy-dev` runs immediately after checkout. The `prod` environment has a required reviewer, so `deploy-prod` pauses the moment it starts and sends a notification to the designated reviewer. The workflow does not contain any conditional logic to implement this gate -- the environment protection rule handles it entirely.

**`needs: deploy-dev`** -- Prod depends on dev succeeding. If `deploy-dev` fails, `deploy-prod` never runs. This is the soak step: changes prove themselves in dev before reaching prod. If a module change causes an apply error in dev (maybe a new resource conflicts with an existing one, or an API call fails), prod is protected. You fix the issue, push another commit, and the pipeline runs again.

**`${{ vars.GPU_ENABLED || 'true' }}`** -- This reads the `GPU_ENABLED` variable from the GitHub Environment. It defaults to `true` if the variable is not set. This ties directly into the power switch workflow you will see later: if you set `GPU_ENABLED=false` in the environment settings, deploys will skip the GPU instance. The `--feature deploy=...` flag maps to the `feature "deploy"` block in the ec2-gpu unit template from [Part 3](03-unit-templates.md). When `deploy` is `false`, the ec2-gpu unit is excluded from the stack -- no instance is created, no cost is incurred. When `deploy` is `true` (the default), the full stack deploys including the GPU instance.

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
          PLAN_OUTPUT=$(cat "${{ matrix.working_directory }}/plan.txt")

          # Write body to file to avoid shell argument length limits
          cat > /tmp/issue-body.md <<ISSUE_EOF
          ## Drift Detected

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
            \`\`\`
          ISSUE_EOF

          # Strip leading whitespace from heredoc (YAML indentation)
          sed -i 's/^          //' /tmp/issue-body.md

          # Check for existing open drift issue for this environment
          EXISTING=$(gh issue list \
            --label "drift,${ENV_NAME}" \
            --state open \
            --limit 1 \
            --json number \
            -q '.[0].number')

          if [ -n "$EXISTING" ]; then
            echo "Updating existing drift issue #${EXISTING}"
            gh issue comment "$EXISTING" --body-file /tmp/issue-body.md
          else
            echo "Creating new drift issue"
            gh issue create \
              --title "$TITLE" \
              --body-file /tmp/issue-body.md \
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

**The issue creation logic** -- When drift is detected (exit code 2), the workflow uses `gh issue list` to check for an existing open issue labeled with both `drift` and the environment name (e.g., `drift,dev`). If one exists, it adds a comment with the new plan output -- this avoids creating duplicate issues when drift persists across multiple runs. If no existing issue is found, it creates a new one. The plan output is wrapped in a `<details>` block so it does not overwhelm the issue tracker with hundreds of lines of Terraform output. Readers click to expand when they want the details. The issue body is written to a temporary file (`/tmp/issue-body.md`) and passed to `gh issue create` and `gh issue comment` via `--body-file` rather than `--body`. This avoids shell argument length limits -- a large plan output with dozens of resource changes can easily exceed the maximum argument size that the shell allows, which would silently truncate the issue body or cause the command to fail entirely.

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

concurrency:
  group: power-${{ inputs.environment }}
  cancel-in-progress: false

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
- **`standby`** runs `terragrunt stack run apply --feature deploy=false`. This is the feature flag from [Feature Flags](07-day-two-operations.md#feature-flags) -- when `deploy` is `false`, the ec2-gpu unit is excluded from the stack. The GPU instance is destroyed, but the VPC, security groups, ALB, DNS, and all other networking infrastructure stays in place. Restarting from standby only needs to create the EC2 instance and its associated resources, which takes about 5 minutes instead of the 10-15 minutes required to rebuild everything from scratch.
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

**OIDC Over Static Keys** -- The OIDC authentication you configured in [Prerequisites (CI/CD)](#prerequisites-cicd) is not just convenient, it is a security boundary. OIDC credentials are scoped to a single workflow run and expire when the run finishes. There are no long-lived AWS access keys to rotate, no risk of a leaked key granting permanent access to your account. If you must store secrets (like the Infracost API key), use GitHub's encrypted secrets and reference them with `${{ secrets.SECRET_NAME }}` -- never hardcode credentials in workflow files or commit them to the repository.

**Fork PR Security** -- GitHub requires maintainer approval before running workflows on pull requests from first-time contributors. Keep this default enabled (Settings > Actions > General > "Require approval for first-time contributors"). Fork PRs never get access to your repository secrets or OIDC credentials, even on public repositories. This means a malicious fork cannot modify a workflow file to exfiltrate your AWS credentials -- the workflow simply will not run until a maintainer approves it.

**Branch Protection** -- Enable branch protection on `main`: require pull request reviews, require the `Validate` status check to pass, and prevent direct pushes (Settings > Branches > Add rule). This ensures every infrastructure change goes through the validation pipeline. No one can push a broken HCL format, a lint violation, or a security misconfiguration directly to `main`. The PR workflow catches it, the reviewer evaluates it, and only clean code gets merged.

**CODEOWNERS** -- A `CODEOWNERS` file lets you require specific reviewers for sensitive paths. For example:

```
# .github/CODEOWNERS
/live/prod/ @your-github-username
```

With this file in place and "Require review from Code Owners" enabled in branch protection, any PR that touches files under `live/prod/` requires explicit approval from the designated owner. Changes to dev can be reviewed by anyone on the team, but production changes need sign-off from the person responsible. This is especially valuable as your team grows.

**Required Status Checks** -- Configure the `Validate` job as a required status check in your branch protection rules. This means a PR cannot be merged if formatting, linting, or security scanning fails. The `Plan` job should remain non-required -- plans can legitimately fail before dependencies exist. When you add a new unit whose VPC dependency has not been applied yet, the plan will fail, but that is expected. The plan comment helps reviewers understand the scope of the change; the validate check ensures code quality. Making the plan required would block legitimate PRs during early development.

---

[< Previous: Day-Two Operations](07-day-two-operations.md) | [Home](../README.md) | [Next: Recap >](recap.md)
