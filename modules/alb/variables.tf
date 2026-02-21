variable "project_name" {
  description = "Name of the project, used for resource naming"
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod)"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC where the ALB resources will be created"
  type        = string
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs for the ALB"
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "Security group ID to attach to the ALB"
  type        = string
}

variable "certificate_arn" {
  description = "ARN of the ACM certificate for HTTPS termination"
  type        = string
}

variable "vllm_port" {
  description = "Port on which vLLM API listens"
  type        = number
  default     = 8000
}

variable "webui_port" {
  description = "Port on which Open WebUI listens"
  type        = number
  default     = 3000
}
