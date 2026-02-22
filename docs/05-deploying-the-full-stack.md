[< Previous: Stack Files](04-stack-files.md) | [Home](../README.md) | [Next: Multi-Environment >](06-multi-environment.md)

---

# Part 5: Deploying the Full Stack

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

[< Previous: Stack Files](04-stack-files.md) | [Home](../README.md) | [Next: Multi-Environment >](06-multi-environment.md)
