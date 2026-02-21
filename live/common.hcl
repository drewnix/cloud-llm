# -----------------------------------------------------------------------------
# Common Variables
# -----------------------------------------------------------------------------
# Project-wide settings shared across all environments and regions.
# These values rarely change and define the identity of the project.

locals {
  project_name = "cloud-llm"
  owner        = "your-name"

  # LLM Configuration
  # Change these to swap the model across all environments
  model_id           = "Qwen/Qwen2.5-Coder-32B-Instruct-AWQ"
  model_name         = "qwen2.5-coder-32b"
  model_quantization = "awq"

  # Cloudflare
  cloudflare_zone_name = "example.com"  # Replace with your domain
  subdomain            = "llm"          # Creates llm.example.com
}
