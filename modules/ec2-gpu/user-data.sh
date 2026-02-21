#!/bin/bash
# -----------------------------------------------------------------------------
# EC2 GPU Instance Bootstrap Script
# -----------------------------------------------------------------------------
# This script is rendered as a Terraform templatefile and runs on first boot.
# It installs Docker, sets up NVIDIA Container Toolkit, downloads the LLM
# model (using S3 cache when available), and starts vLLM + Open WebUI.
#
# Template variables (injected by Terraform):
#   - model_id:           HuggingFace model ID
#   - model_cache_bucket: S3 bucket for caching model weights
#   - vllm_port:          Port for vLLM API server
#   - webui_port:         Port for Open WebUI
#   - aws_region:         AWS region for S3 operations
# -----------------------------------------------------------------------------

set -euo pipefail
exec > >(tee /var/log/user-data.log) 2>&1

echo "========================================="
echo "Starting GPU instance bootstrap"
echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "========================================="

# ---- Configuration (injected by Terraform templatefile) ----
MODEL_ID="${model_id}"
MODEL_CACHE_BUCKET="${model_cache_bucket}"
VLLM_PORT="${vllm_port}"
WEBUI_PORT="${webui_port}"
AWS_REGION="${aws_region}"

MODEL_DIR="/opt/models"
COMPOSE_DIR="/opt/llm-stack"

# ---- Install Docker ----
echo ">>> Installing Docker..."
dnf install -y docker
systemctl enable docker
systemctl start docker
usermod -aG docker ec2-user

# ---- Install Docker Compose plugin ----
echo ">>> Installing Docker Compose..."
mkdir -p /usr/local/lib/docker/cli-plugins
curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# ---- Install NVIDIA Container Toolkit ----
echo ">>> Installing NVIDIA Container Toolkit..."
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
  | tee /etc/yum.repos.d/nvidia-container-toolkit.repo
dnf install -y nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

# ---- Verify GPU access ----
echo ">>> Verifying GPU access..."
nvidia-smi
docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi

# ---- Prepare model directory ----
echo ">>> Preparing model directory..."
mkdir -p "$MODEL_DIR"

# ---- Download model (S3 cache or HuggingFace) ----
# Convert model ID to S3-safe path (replace / with --)
S3_MODEL_KEY="models/$(echo "$MODEL_ID" | tr '/' '--')"

echo ">>> Checking S3 cache for model..."
if aws s3 ls "s3://$MODEL_CACHE_BUCKET/$S3_MODEL_KEY/" --region "$AWS_REGION" 2>/dev/null | head -1; then
  echo ">>> Model found in S3 cache. Downloading..."
  aws s3 sync "s3://$MODEL_CACHE_BUCKET/$S3_MODEL_KEY/" "$MODEL_DIR/$MODEL_ID" \
    --region "$AWS_REGION" --quiet
  echo ">>> Model downloaded from S3 cache."
else
  echo ">>> Model not in S3 cache. Downloading from HuggingFace..."
  # Use vLLM's built-in model download - it will download on first start
  # After download, we'll cache to S3 in the background
  echo ">>> Model will be downloaded by vLLM on first start."
  echo ">>> Will cache to S3 after download completes."

  # Set flag to trigger S3 upload after vLLM downloads the model
  touch /tmp/cache_model_to_s3
fi

# ---- Create Docker Compose stack ----
echo ">>> Creating Docker Compose configuration..."
mkdir -p "$COMPOSE_DIR"

cat > "$COMPOSE_DIR/docker-compose.yml" << 'COMPOSE_EOF'
services:
  vllm:
    image: vllm/vllm-openai:latest
    runtime: nvidia
    ports:
      - "${vllm_port}:8000"
    volumes:
      - model-data:/root/.cache/huggingface
      - /opt/models:/opt/models
    environment:
      - HUGGING_FACE_HUB_TOKEN=$${HF_TOKEN:-}
    command:
      - --model
      - ${model_id}
      - --host
      - "0.0.0.0"
      - --port
      - "8000"
      - --max-model-len
      - "8192"
      - --gpu-memory-utilization
      - "0.90"
      - --trust-remote-code
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 120
      start_period: 300s
    restart: unless-stopped

  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    ports:
      - "${webui_port}:8080"
    volumes:
      - webui-data:/app/backend/data
    environment:
      - OPENAI_API_BASE_URL=http://vllm:8000/v1
      - OPENAI_API_KEY=not-needed
      - WEBUI_AUTH=false
    depends_on:
      vllm:
        condition: service_healthy
    restart: unless-stopped

volumes:
  model-data:
  webui-data:
COMPOSE_EOF

# ---- Start the stack ----
echo ">>> Starting LLM stack..."
cd "$COMPOSE_DIR"
docker compose up -d

# ---- Background: Cache model to S3 after download ----
if [ -f /tmp/cache_model_to_s3 ]; then
  echo ">>> Starting background model cache job..."
  nohup bash -c '
    echo "Waiting for vLLM to finish downloading model..."
    # Wait for vLLM to become healthy (model downloaded and loaded)
    while ! curl -sf http://localhost:'"$VLLM_PORT"'/health >/dev/null 2>&1; do
      sleep 30
      echo "Still waiting for vLLM to be ready..."
    done
    echo "vLLM is healthy. Caching model to S3..."

    # Find the downloaded model in the HuggingFace cache
    HF_CACHE="/var/lib/docker/volumes/llm-stack_model-data/_data"
    MODEL_PATH=$(find "$HF_CACHE" -maxdepth 3 -name "config.json" -path "*'"$MODEL_ID"'*" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || true)

    if [ -n "$MODEL_PATH" ]; then
      S3_KEY="models/$(echo "'"$MODEL_ID"'" | tr "/" "--")"
      aws s3 sync "$MODEL_PATH" "s3://'"$MODEL_CACHE_BUCKET"'/$S3_KEY/" \
        --region "'"$AWS_REGION"'" --quiet
      echo "Model cached to S3 successfully."
    else
      echo "Could not locate model files for S3 caching."
    fi
  ' > /var/log/model-cache.log 2>&1 &
  rm /tmp/cache_model_to_s3
fi

echo "========================================="
echo "Bootstrap complete!"
echo "vLLM API:    http://localhost:$VLLM_PORT/v1"
echo "Open WebUI:  http://localhost:$WEBUI_PORT"
echo "========================================="
