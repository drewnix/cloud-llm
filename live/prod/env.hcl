# -----------------------------------------------------------------------------
# Prod Environment Variables
# -----------------------------------------------------------------------------
# Production-grade settings with on-demand instances for reliability.

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
