terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# -----------------------------------------------------------------------------
# ALB Security Group
# -----------------------------------------------------------------------------
# Allows inbound HTTP/HTTPS from the public internet and all outbound traffic.

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-${var.environment}-alb-sg"
  description = "Security group for the Application Load Balancer"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project_name}-${var.environment}-alb-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow HTTP from the internet"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow HTTPS from the internet"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_all_outbound" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow all outbound traffic"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# -----------------------------------------------------------------------------
# EC2 Security Group
# -----------------------------------------------------------------------------
# Allows inbound vLLM and web UI traffic only from the ALB security group.
# Optionally allows SSH from specified CIDR blocks.
# All outbound traffic is allowed (needed for model downloads, package installs).

resource "aws_security_group" "ec2" {
  name        = "${var.project_name}-${var.environment}-ec2-sg"
  description = "Security group for the GPU EC2 instance"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project_name}-${var.environment}-ec2-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "ec2_vllm_from_alb" {
  security_group_id            = aws_security_group.ec2.id
  description                  = "Allow vLLM traffic from the ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.vllm_port
  to_port                      = var.vllm_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "ec2_webui_from_alb" {
  security_group_id            = aws_security_group.ec2.id
  description                  = "Allow web UI traffic from the ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.webui_port
  to_port                      = var.webui_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "ec2_ssh" {
  for_each = toset(var.allowed_ssh_cidrs)

  security_group_id = aws_security_group.ec2.id
  description       = "Allow SSH from ${each.value}"
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "ec2_all_outbound" {
  security_group_id = aws_security_group.ec2.id
  description       = "Allow all outbound traffic"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
