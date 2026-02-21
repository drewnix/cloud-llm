variable "project_name" {
  description = "Name of the project, used in resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. dev, staging, prod)"
  type        = string
}

variable "model_cache_bucket_arn" {
  description = "ARN of the S3 bucket for model weight caching"
  type        = string
}
