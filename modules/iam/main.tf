terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# -----------------------------------------------------------------------------
# IAM Role for GPU Instance
# -----------------------------------------------------------------------------

resource "aws_iam_role" "gpu_instance" {
  name = "${var.project_name}-${var.environment}-gpu-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-${var.environment}-gpu-instance-role"
  }
}

# -----------------------------------------------------------------------------
# Instance Profile
# -----------------------------------------------------------------------------

resource "aws_iam_instance_profile" "gpu_instance" {
  name = "${var.project_name}-${var.environment}-gpu-instance-profile"
  role = aws_iam_role.gpu_instance.name

  tags = {
    Name = "${var.project_name}-${var.environment}-gpu-instance-profile"
  }
}

# -----------------------------------------------------------------------------
# S3 Model Cache Access Policy
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy" "s3_model_cache" {
  name = "${var.project_name}-${var.environment}-s3-model-cache"
  role = aws_iam_role.gpu_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          var.model_cache_bucket_arn,
          "${var.model_cache_bucket_arn}/*"
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# CloudWatch Agent Policy
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.gpu_instance.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# -----------------------------------------------------------------------------
# SSM Access Policy (Session Manager as SSH alternative)
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy" "ssm_access" {
  name = "${var.project_name}-${var.environment}-ssm-access"
  role = aws_iam_role.gpu_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:UpdateInstanceInformation",
          "ssmmessages:*",
          "ec2messages:*"
        ]
        Resource = "*"
      }
    ]
  })
}
