variable "project_name" {
  description = "Name of the project, used for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. dev, staging, prod)"
  type        = string
}

variable "aws_region" {
  description = "AWS region for the S3 bucket and VPC endpoint"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for the S3 VPC endpoint"
  type        = string
}

variable "private_route_table_ids" {
  description = "Route table IDs for the S3 VPC endpoint"
  type        = list(string)
}
