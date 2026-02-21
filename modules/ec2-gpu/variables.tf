# -----------------------------------------------------------------------------
# EC2 GPU Module - Variables
# -----------------------------------------------------------------------------

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. dev, prod)"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for the GPU instance"
  type        = string
  default     = "g5.xlarge"
}

variable "use_spot" {
  description = "Whether to use spot instances for cost savings"
  type        = bool
  default     = false
}

variable "spot_max_price" {
  description = "Maximum spot price per hour"
  type        = string
  default     = ""
}

variable "subnet_id" {
  description = "Public subnet ID to launch in"
  type        = string
}

variable "ec2_security_group_id" {
  description = "Security group ID for the EC2 instance"
  type        = string
}

variable "instance_profile_name" {
  description = "IAM instance profile name to attach to the instance"
  type        = string
}

variable "ebs_volume_size" {
  description = "Size of the root EBS volume in GB"
  type        = number
  default     = 100
}

variable "ebs_volume_type" {
  description = "Type of the root EBS volume"
  type        = string
  default     = "gp3"
}

variable "model_id" {
  description = "HuggingFace model ID e.g. Qwen/Qwen2.5-Coder-32B-Instruct-AWQ"
  type        = string
}

variable "model_name" {
  description = "Short model name for tagging"
  type        = string
}

variable "model_cache_bucket" {
  description = "S3 bucket name for model weight caching"
  type        = string
}

variable "vllm_port" {
  description = "Port for the vLLM API server"
  type        = number
  default     = 8000
}

variable "webui_port" {
  description = "Port for the Open WebUI server"
  type        = number
  default     = 3000
}

variable "vllm_target_group_arn" {
  description = "Target group ARN for vLLM"
  type        = string
}

variable "webui_target_group_arn" {
  description = "Target group ARN for Open WebUI"
  type        = string
}

variable "aws_region" {
  description = "AWS region for resource deployment"
  type        = string
}
