# -----------------------------------------------------------------------------
# EC2 GPU Module - Main
# -----------------------------------------------------------------------------
# Launches a GPU-accelerated EC2 instance running vLLM and Open WebUI,
# registers it with ALB target groups, and supports optional spot pricing.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# ---------------------------------------------------------------------------
# AMI - Deep Learning Base with NVIDIA drivers pre-installed
# ---------------------------------------------------------------------------
data "aws_ami" "amazon_linux_gpu" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Deep Learning Base OSS Nvidia Driver GPU AMI (Amazon Linux 2023) *"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# ---------------------------------------------------------------------------
# Launch Template
# ---------------------------------------------------------------------------
resource "aws_launch_template" "gpu_instance" {
  name_prefix   = "${var.project_name}-${var.environment}-gpu-"
  image_id      = data.aws_ami.amazon_linux_gpu.id
  instance_type = var.instance_type

  vpc_security_group_ids = [var.ec2_security_group_id]

  iam_instance_profile {
    name = var.instance_profile_name
  }

  user_data = base64encode(templatefile("${path.module}/user-data.sh", {
    model_id           = var.model_id
    model_cache_bucket = var.model_cache_bucket
    vllm_port          = var.vllm_port
    webui_port         = var.webui_port
    aws_region         = var.aws_region
  }))

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.ebs_volume_size
      volume_type           = var.ebs_volume_type
      encrypted             = true
      delete_on_termination = true
    }
  }

  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        max_price = var.spot_max_price != "" ? var.spot_max_price : null
      }
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name  = "${var.project_name}-${var.environment}-gpu"
      Model = var.model_name
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = "${var.project_name}-${var.environment}-gpu-root"
    }
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-gpu-lt"
  }
}

# ---------------------------------------------------------------------------
# EC2 Instance
# ---------------------------------------------------------------------------
resource "aws_instance" "gpu" {
  launch_template {
    id      = aws_launch_template.gpu_instance.id
    version = "$Latest"
  }

  subnet_id = var.subnet_id

  tags = {
    Name  = "${var.project_name}-${var.environment}-gpu"
    Model = var.model_name
  }
}

# ---------------------------------------------------------------------------
# ALB Target Group Attachments
# ---------------------------------------------------------------------------
resource "aws_lb_target_group_attachment" "vllm" {
  target_group_arn = var.vllm_target_group_arn
  target_id        = aws_instance.gpu.id
  port             = var.vllm_port
}

resource "aws_lb_target_group_attachment" "webui" {
  target_group_arn = var.webui_target_group_arn
  target_id        = aws_instance.gpu.id
  port             = var.webui_port
}
