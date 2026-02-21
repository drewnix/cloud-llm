# -----------------------------------------------------------------------------
# Region Variables
# -----------------------------------------------------------------------------
# Region-specific settings. To deploy in a new region, create a new directory
# with its own region.hcl and copy the module terragrunt.hcl files.

locals {
  aws_region = "us-east-1"
}
