variable "project_name" {
  description = "Name of the project, used in resource naming"
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod)"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC where security groups will be created"
  type        = string
}

variable "allowed_ssh_cidrs" {
  description = "List of CIDR blocks allowed to SSH into the EC2 instance"
  type        = list(string)
  default     = []
}

variable "vllm_port" {
  description = "Port on which the vLLM inference server listens"
  type        = number
  default     = 8000
}

variable "webui_port" {
  description = "Port on which the web UI listens"
  type        = number
  default     = 3000
}
