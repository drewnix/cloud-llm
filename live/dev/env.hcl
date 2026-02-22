# -----------------------------------------------------------------------------
# Dev Environment Variables
# -----------------------------------------------------------------------------
# Cost-optimized settings for development and learning.
# Uses spot instances and smaller EBS volumes.

locals {
  environment   = "dev"
  instance_type = "g5.xlarge"   # 1x A10G GPU, 24GB VRAM - ~$1.01/hr on-demand
  use_spot      = true          # ~60% savings, acceptable for dev
  spot_max_price = "0.50"       # Cap spot price at $0.50/hr

  # EBS volume for model storage (models are ~18-20GB)
  ebs_volume_size = 100         # GB - enough for model + Docker images
  ebs_volume_type = "gp3"

  # Open WebUI settings
  webui_port = 3000
  vllm_port  = 8000
}
