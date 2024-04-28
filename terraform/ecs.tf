###############################################################################
# ecs.tf — ECS Cluster, Task Definition, Service, ECR, Auto Scaling
#
# Architecture Decision:
#   Using Fargate (serverless compute) rather than EC2 launch type to
#   eliminate node management overhead. Fargate Spot can be enabled for
#   non-production environments to achieve ~70% cost savings.
#
#   Capacity provider strategy mixes ON_DEMAND (base=1) + SPOT (weight=4)
#   when Spot is enabled, providing cost efficiency while keeping at least
#   one task running on stable capacity at all times.
###############################################################################

###############################################################################
# ECR Repository
###############################################################################

resource "aws_ecr_repository" "app" {
  name                 = "${local.name_prefix}/app"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true   # Detect CVEs before tasks can pull the image
  }

  encryption_configuration {
    encryption_type = "KMS"   # Encrypt images at rest with AWS-managed KMS key
  }

  tags = {
    Name = "${local.name_prefix}-ecr"
  }
}

# Lifecycle policy: keep last 30 tagged images, purge untagged after 1 day
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Remove untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 30 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "release", "main"]
          countType     = "imageCountMoreThan"
          countNumber   = 30
        }
        action = { type = "expire" }
      }
    ]
  })
}

###############################################################################
# ECS Cluster
###############################################################################

resource "aws_ecs_cluster" "main" {
  name = local.name_prefix

  setting {
    name  = "containerInsights"
    value = "enabled"   # Enhanced CloudWatch metrics for tasks/services
  }

  tags = {
    Name = "${local.name_prefix}-cluster"
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name = aws_ecs_cluster.main.name

  capacity_providers = var.enable_fargate_spot ? [
    "FARGATE",
    "FARGATE_SPOT"
  ] : ["FARGATE"]

  default_capacity_provider_strategy {
    base              = 1             # At least 1 task on stable FARGATE
    weight            = 1
    capacity_provider = "FARGATE"
  }

  dynamic "default_capacity_provider_strategy" {
    for_each = var.enable_fargate_spot ? [1] : []
    content {
      base              = 0
      weight            = 4           # 4:1 ratio favours Spot for remaining tasks
      capacity_provider = "FARGATE_SPOT"
    }
  }
}

###############################################################################
# CloudWatch Log Group for application container logs
###############################################################################

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.name_prefix}/app"
  retention_in_days = 30

  tags = {
    Name = "${local.name_prefix}-app-logs"
  }
}

###############################################################################
# ECS Task Definition
###############################################################################

resource "aws_ecs_task_definition" "app" {
  family                   = "${local.name_prefix}-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"   # Required for Fargate; each task gets its own ENI
  cpu                      = var.ecs_task_cpu
  memory                   = var.ecs_task_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = "${aws_ecr_repository.app.repository_url}:${var.app_image_tag}"
      essential = true

      portMappings = [
        {
          containerPort = var.app_port
          protocol      = "tcp"
        }
      ]

      # Environment variables — non-sensitive values only.
      # Secrets are injected via secrets[] from Secrets Manager.
      environment = [
        { name = "APP_ENV",  value = var.environment },
        { name = "APP_PORT", value = tostring(var.app_port) },
        { name = "AWS_REGION", value = var.aws_region }
      ]

      secrets = [
        {
          name      = "DATABASE_URL"
          valueFrom = "${aws_secretsmanager_secret.rds_credentials.arn}:url::"
        },
        {
          name      = "DB_PASSWORD"
          valueFrom = "${aws_secretsmanager_secret.rds_credentials.arn}:password::"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "app"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "curl -sf http://localhost:${var.app_port}/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60   # Grace period for slow-starting apps
      }

      # Resource limits prevent a runaway container from starving the task
      ulimits = [
        {
          name      = "nofile"
          softLimit = 65536
          hardLimit = 65536
        }
      ]
    }
  ])

  tags = {
    Name = "${local.name_prefix}-task-def"
  }
}

###############################################################################
# Security Group — ECS Tasks
###############################################################################

resource "aws_security_group" "ecs_tasks" {
  name        = "${local.name_prefix}-ecs-tasks-sg"
  description = "Allow inbound from ALB only; allow all outbound for package downloads and AWS API calls"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTP from ALB"
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "All outbound (HTTPS to ECR, Secrets Manager, CloudWatch)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-ecs-tasks-sg"
  }
}

###############################################################################
# ECS Service
###############################################################################

resource "aws_ecs_service" "app" {
  name            = "${local.name_prefix}-app"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.app_desired_count

  # Use capacity provider strategy instead of launch_type when Spot is enabled
  dynamic "capacity_provider_strategy" {
    for_each = var.enable_fargate_spot ? [1] : []
    content {
      capacity_provider = "FARGATE"
      base              = 1
      weight            = 1
    }
  }

  dynamic "capacity_provider_strategy" {
    for_each = var.enable_fargate_spot ? [1] : []
    content {
      capacity_provider = "FARGATE_SPOT"
      base              = 0
      weight            = 4
    }
  }

  # Use plain FARGATE when Spot is not enabled
  launch_type = var.enable_fargate_spot ? null : "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false   # Tasks are in private subnets; use NAT for outbound
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = var.app_port
  }

  # Rolling deployment: ensure at least 100% healthy before stopping old tasks
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true    # Automatically roll back on deployment failure
    rollback = true
  }

  health_check_grace_period_seconds = 60

  # Service discovery via AWS Cloud Map (optional — enables service-to-service
  # calls using DNS rather than going through the ALB)
  # Uncomment to enable:
  # service_registries {
  #   registry_arn = aws_service_discovery_service.app.arn
  # }

  # Ignore task definition changes made outside Terraform (e.g. by deploy.sh)
  # to prevent Terraform from rolling back manual hotfixes.
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_lb_listener.https, aws_iam_role_policy_attachment.ecs_task_execution]

  tags = {
    Name = "${local.name_prefix}-ecs-service"
  }
}

###############################################################################
# Auto Scaling
###############################################################################

resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = var.app_max_count
  min_capacity       = var.app_min_count
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

# Scale out on high CPU — add tasks when average CPU > threshold
resource "aws_appautoscaling_policy" "ecs_cpu" {
  name               = "${local.name_prefix}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = 70.0   # Scale when CPU hits 70%; allows headroom before 80% alarm
    scale_in_cooldown  = 300    # Wait 5 min before scaling in (prevent thrashing)
    scale_out_cooldown = 60     # Scale out quickly when needed

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

# Scale out on high memory
resource "aws_appautoscaling_policy" "ecs_memory" {
  name               = "${local.name_prefix}-memory-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = 75.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
  }
}

# Scale out based on ALB request count per target
resource "aws_appautoscaling_policy" "ecs_requests" {
  name               = "${local.name_prefix}-requests-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = 1000   # Target 1000 requests/min per task
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.main.arn_suffix}/${aws_lb_target_group.app.arn_suffix}"
    }
  }
}
