terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# -----------------------------------------------------------------------------
# Application Load Balancer
# -----------------------------------------------------------------------------

resource "aws_lb" "this" {
  name               = "${var.project_name}-${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_security_group_id]
  subnets            = var.public_subnet_ids

  tags = {
    Name        = "${var.project_name}-${var.environment}-alb"
    Environment = var.environment
    Project     = var.project_name
  }
}

# -----------------------------------------------------------------------------
# Target Groups
# -----------------------------------------------------------------------------

resource "aws_lb_target_group" "vllm" {
  name        = "${var.project_name}-${var.environment}-vllm-tg"
  port        = var.vllm_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    path                = "/health"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-vllm-tg"
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_lb_target_group" "webui" {
  name        = "${var.project_name}-${var.environment}-webui-tg"
  port        = var.webui_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    path     = "/"
    interval = 30
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-webui-tg"
    Environment = var.environment
    Project     = var.project_name
  }
}

# -----------------------------------------------------------------------------
# Listeners
# -----------------------------------------------------------------------------

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.webui.arn
  }
}

resource "aws_lb_listener_rule" "api" {
  listener_arn = aws_lb_listener.https.arn

  condition {
    path_pattern {
      values = ["/v1/*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.vllm.arn
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}
