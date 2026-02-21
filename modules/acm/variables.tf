variable "project_name" {
  description = "The name of the project"
  type        = string
}

variable "environment" {
  description = "The deployment environment (e.g. dev, staging, prod)"
  type        = string
}

variable "domain_name" {
  description = "The fully qualified domain name for the certificate, e.g. llm.example.com"
  type        = string
}
