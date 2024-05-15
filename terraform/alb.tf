###############################################################################
# alb.tf — Application Load Balancer, Listeners, Target Groups
#
# Architecture Decision:
#   ALB is placed in public subnets to terminate TLS and route traffic to
#   ECS tasks in private subnets. HTTP (port 80) is permanently redirected
#   to HTTPS (port 443) at the ALB layer, so no plaintext traffic reaches
#   the application containers.
#
#   ALB access logs are sent to S3 for security analysis and cost auditing.
###############################################################################

###############################################################################
# Security Group — ALB
###############################################################################

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "Allow HTTPS/HTTP from internet; deny everything else inbound"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP from internet (redirected to HTTPS at ALB)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound to VPC (to ECS tasks)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name = "${local.name_prefix}-alb-sg"
  }
}

###############################################################################
# Application Load Balancer
###############################################################################

resource "aws_lb" "main" {
  name               = "${local.name_prefix}-alb"
  internal           = false          # Public-facing ALB
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  # Enable access logs to S3 for audit/cost analysis
  access_logs {
    bucket  = aws_s3_bucket.logs.bucket
    prefix  = "alb-access-logs"
    enabled = true
  }

  # Drop invalid HTTP headers to block header injection attacks
  drop_invalid_header_fields = true

  # Do not enable deletion protection in non-prod; enable in production
  enable_deletion_protection = var.environment == "production" ? true : false

  idle_timeout = 60

  tags = {
    Name = "${local.name_prefix}-alb"
  }

  depends_on = [aws_s3_bucket_policy.logs]
}

###############################################################################
# Target Group
###############################################################################

resource "aws_lb_target_group" "app" {
  name        = "${local.name_prefix}-tg"
  port        = var.app_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"   # Required for Fargate (tasks use IP addresses, not instance IDs)

  health_check {
    enabled             = true
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200-299"
    protocol            = "HTTP"
    port                = "traffic-port"
  }

  # Deregistration delay: allow in-flight requests to complete before
  # a task is removed from the target group (e.g. during deployments)
  deregistration_delay = 30

  stickiness {
    type    = "lb_cookie"
    enabled = false   # Stateless app — no stickiness needed
  }

  tags = {
    Name = "${local.name_prefix}-tg"
  }

  lifecycle {
    create_before_destroy = true   # Zero-downtime replacement during updates
  }
}

###############################################################################
# Listeners
###############################################################################

# HTTP listener — redirect all traffic to HTTPS
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
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

  tags = {
    Name = "${local.name_prefix}-http-listener"
  }
}

# HTTPS listener — forward to target group
# Falls back to HTTP when no certificate_arn is provided (for dev/test)
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = var.certificate_arn != "" ? 443 : 8443
  protocol          = var.certificate_arn != "" ? "HTTPS" : "HTTP"
  ssl_policy        = var.certificate_arn != "" ? "ELBSecurityPolicy-TLS13-1-2-2021-06" : null
  certificate_arn   = var.certificate_arn != "" ? var.certificate_arn : null

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  tags = {
    Name = "${local.name_prefix}-https-listener"
  }
}

###############################################################################
# Listener Rules (path-based routing examples)
###############################################################################

# Route /api/* to the app target group (same group here, but ready for split)
resource "aws_lb_listener_rule" "api" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  condition {
    path_pattern {
      values = ["/api/*"]
    }
  }

  tags = {
    Name = "${local.name_prefix}-api-rule"
  }
}

# Fixed 503 response for maintenance mode — flip priority to activate
resource "aws_lb_listener_rule" "maintenance" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 999   # Lowest priority — only matches if all others miss

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      message_body = "{\"error\": \"Service temporarily unavailable. Please try again shortly.\"}"
      status_code  = "503"
    }
  }

  condition {
    http_header {
      http_header_name = "X-Maintenance-Mode"
      values           = ["true"]
    }
  }

  tags = {
    Name = "${local.name_prefix}-maintenance-rule"
  }
}
