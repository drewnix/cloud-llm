terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }
}

# -----------------------------------------------------------------------------
# Random ID for bucket name uniqueness
# -----------------------------------------------------------------------------

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# -----------------------------------------------------------------------------
# S3 Bucket - Model Weight Cache
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "model_cache" {
  bucket = "${var.project_name}-${var.environment}-model-cache-${random_id.bucket_suffix.hex}"

  tags = {
    Name        = "${var.project_name}-${var.environment}-model-cache"
    Environment = var.environment
    Project     = var.project_name
  }
}

# -----------------------------------------------------------------------------
# Versioning - Disabled (model weights don't need versioning)
# -----------------------------------------------------------------------------

resource "aws_s3_bucket_versioning" "model_cache" {
  bucket = aws_s3_bucket.model_cache.id

  versioning_configuration {
    status = "Disabled"
  }
}

# -----------------------------------------------------------------------------
# Lifecycle - Transition to Intelligent-Tiering after 30 days
# -----------------------------------------------------------------------------

resource "aws_s3_bucket_lifecycle_configuration" "model_cache" {
  bucket = aws_s3_bucket.model_cache.id

  rule {
    id     = "transition-to-intelligent-tiering"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "INTELLIGENT_TIERING"
    }
  }
}

# -----------------------------------------------------------------------------
# Public Access Block - Block all public access
# -----------------------------------------------------------------------------

resource "aws_s3_bucket_public_access_block" "model_cache" {
  bucket = aws_s3_bucket.model_cache.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -----------------------------------------------------------------------------
# Server-Side Encryption - AES256
# -----------------------------------------------------------------------------

resource "aws_s3_bucket_server_side_encryption_configuration" "model_cache" {
  bucket = aws_s3_bucket.model_cache.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# -----------------------------------------------------------------------------
# VPC Endpoint for S3 (Gateway) - Fast, free access from private subnets
# -----------------------------------------------------------------------------

resource "aws_vpc_endpoint" "s3" {
  vpc_id          = var.vpc_id
  service_name    = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids = var.private_route_table_ids

  tags = {
    Name        = "${var.project_name}-${var.environment}-s3-endpoint"
    Environment = var.environment
    Project     = var.project_name
  }
}
