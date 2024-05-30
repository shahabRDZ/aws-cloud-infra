###############################################################################
# cloudwatch.tf — CloudWatch Alarms, Dashboards, Log Groups, SNS Topic
#
# Architecture Decision:
#   Alarms are grouped by service tier (ECS, RDS, ALB) and routed to an SNS
#   topic so that notification channels can be changed without modifying
#   alarm definitions. The topic can have multiple subscriptions: email,
#   PagerDuty, Slack via Lambda, etc.
#
#   The CloudWatch dashboard provides a single pane of glass for operations
#   covering compute, database, and load balancer metrics.
###############################################################################

###############################################################################
# SNS Topic — alarm notifications
###############################################################################

resource "aws_sns_topic" "alarms" {
  name = "${local.name_prefix}-alarms"

  tags = {
    Name = "${local.name_prefix}-alarms"
  }
}

resource "aws_sns_topic_subscription" "alarms_email" {
  count     = var.alarm_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

###############################################################################
# CloudWatch Log Groups
###############################################################################

# app log group is declared in ecs.tf to keep it co-located with the task
# definition. This file creates additional log groups.

resource "aws_cloudwatch_log_group" "nginx" {
  name              = "/ecs/${local.name_prefix}/nginx"
  retention_in_days = 14

  tags = {
    Name = "${local.name_prefix}-nginx-logs"
  }
}

resource "aws_cloudwatch_log_group" "ecs_cluster" {
  name              = "/aws/ecs/${local.name_prefix}"
  retention_in_days = 7

  tags = {
    Name = "${local.name_prefix}-ecs-cluster-logs"
  }
}

###############################################################################
# ECS Alarms
###############################################################################

resource "aws_cloudwatch_metric_alarm" "ecs_cpu_high" {
  alarm_name          = "${local.name_prefix}-ecs-cpu-high"
  alarm_description   = "ECS service CPU utilisation exceeded ${var.cpu_alarm_threshold}% for 2 consecutive minutes"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = var.cpu_alarm_threshold

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.app.name
  }

  alarm_actions             = [aws_sns_topic.alarms.arn]
  ok_actions                = [aws_sns_topic.alarms.arn]
  insufficient_data_actions = []

  tags = {
    Name     = "${local.name_prefix}-ecs-cpu-high"
    Severity = "warning"
  }
}

resource "aws_cloudwatch_metric_alarm" "ecs_memory_high" {
  alarm_name          = "${local.name_prefix}-ecs-memory-high"
  alarm_description   = "ECS service memory utilisation exceeded ${var.memory_alarm_threshold}% for 2 consecutive minutes"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = var.memory_alarm_threshold

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.app.name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = {
    Name     = "${local.name_prefix}-ecs-memory-high"
    Severity = "warning"
  }
}

resource "aws_cloudwatch_metric_alarm" "ecs_task_count_low" {
  alarm_name          = "${local.name_prefix}-ecs-task-count-low"
  alarm_description   = "ECS service running task count fell below desired count — possible deployment failure"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "RunningTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = 60
  statistic           = "Average"
  threshold           = var.app_min_count

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.app.name
  }

  treat_missing_data = "breaching"
  alarm_actions      = [aws_sns_topic.alarms.arn]

  tags = {
    Name     = "${local.name_prefix}-ecs-task-count-low"
    Severity = "critical"
  }
}

###############################################################################
# RDS Alarms
###############################################################################

resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "${local.name_prefix}-rds-cpu-high"
  alarm_description   = "RDS CPU utilisation exceeded 75% for 5 consecutive minutes"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 5
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 75

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.postgres.identifier
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = {
    Name     = "${local.name_prefix}-rds-cpu-high"
    Severity = "warning"
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_free_storage_low" {
  alarm_name          = "${local.name_prefix}-rds-free-storage-low"
  alarm_description   = "RDS free storage fell below 5 GiB — autoscaling may not have triggered yet"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Minimum"
  threshold           = 5368709120   # 5 GiB in bytes

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.postgres.identifier
  }

  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = {
    Name     = "${local.name_prefix}-rds-free-storage-low"
    Severity = "warning"
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_connections_high" {
  alarm_name          = "${local.name_prefix}-rds-connections-high"
  alarm_description   = "RDS connection count is approaching max_connections — consider connection pooling"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 3
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 150   # 75% of max_connections = 200

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.postgres.identifier
  }

  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = {
    Name     = "${local.name_prefix}-rds-connections-high"
    Severity = "warning"
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_read_latency_high" {
  alarm_name          = "${local.name_prefix}-rds-read-latency-high"
  alarm_description   = "RDS average read latency exceeded 20ms"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 3
  metric_name         = "ReadLatency"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 0.02   # 20ms in seconds

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.postgres.identifier
  }

  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = {
    Name     = "${local.name_prefix}-rds-read-latency-high"
    Severity = "info"
  }
}

###############################################################################
# ALB Alarms
###############################################################################

resource "aws_cloudwatch_metric_alarm" "alb_5xx_high" {
  alarm_name          = "${local.name_prefix}-alb-5xx-high"
  alarm_description   = "ALB 5xx error count exceeded 10 in 1 minute — possible application crash"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = {
    Name     = "${local.name_prefix}-alb-5xx-high"
    Severity = "critical"
  }
}

resource "aws_cloudwatch_metric_alarm" "alb_4xx_high" {
  alarm_name          = "${local.name_prefix}-alb-4xx-high"
  alarm_description   = "ALB 4xx error count exceeded 100 in 1 minute — possible client or routing issue"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_Target_4XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 100
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = {
    Name     = "${local.name_prefix}-alb-4xx-high"
    Severity = "warning"
  }
}

resource "aws_cloudwatch_metric_alarm" "alb_target_response_time_high" {
  alarm_name          = "${local.name_prefix}-alb-p99-latency-high"
  alarm_description   = "ALB target response time P99 exceeded 2 seconds"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 3
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  extended_statistic  = "p99"
  threshold           = 2.0

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = {
    Name     = "${local.name_prefix}-alb-p99-latency-high"
    Severity = "warning"
  }
}

resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_hosts" {
  alarm_name          = "${local.name_prefix}-alb-unhealthy-hosts"
  alarm_description   = "ALB reports unhealthy targets — ECS tasks may be crashing"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.app.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = {
    Name     = "${local.name_prefix}-alb-unhealthy-hosts"
    Severity = "critical"
  }
}

###############################################################################
# CloudWatch Dashboard
###############################################################################

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = local.name_prefix

  dashboard_body = jsonencode({
    widgets = [
      # Row 1: ECS metrics
      {
        type   = "metric"
        x      = 0; y = 0; width = 8; height = 6
        properties = {
          title   = "ECS CPU Utilization (%)"
          view    = "timeSeries"
          stacked = false
          period  = 60
          stat    = "Average"
          metrics = [
            ["AWS/ECS", "CPUUtilization",
              "ClusterName", aws_ecs_cluster.main.name,
              "ServiceName", aws_ecs_service.app.name,
              { label = "CPU %" }
            ]
          ]
          annotations = {
            horizontal = [{ value = var.cpu_alarm_threshold, label = "Alarm threshold", color = "#ff0000" }]
          }
        }
      },
      {
        type   = "metric"
        x      = 8; y = 0; width = 8; height = 6
        properties = {
          title   = "ECS Memory Utilization (%)"
          view    = "timeSeries"
          period  = 60
          stat    = "Average"
          metrics = [
            ["AWS/ECS", "MemoryUtilization",
              "ClusterName", aws_ecs_cluster.main.name,
              "ServiceName", aws_ecs_service.app.name
            ]
          ]
          annotations = {
            horizontal = [{ value = var.memory_alarm_threshold, label = "Alarm threshold", color = "#ff0000" }]
          }
        }
      },
      {
        type   = "metric"
        x      = 16; y = 0; width = 8; height = 6
        properties = {
          title   = "ECS Running Task Count"
          view    = "timeSeries"
          period  = 60
          stat    = "Average"
          metrics = [
            ["ECS/ContainerInsights", "RunningTaskCount",
              "ClusterName", aws_ecs_cluster.main.name,
              "ServiceName", aws_ecs_service.app.name
            ]
          ]
        }
      },
      # Row 2: ALB metrics
      {
        type   = "metric"
        x      = 0; y = 6; width = 8; height = 6
        properties = {
          title   = "ALB Request Count"
          view    = "timeSeries"
          period  = 60
          stat    = "Sum"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.main.arn_suffix]
          ]
        }
      },
      {
        type   = "metric"
        x      = 8; y = 6; width = 8; height = 6
        properties = {
          title   = "ALB HTTP Error Codes"
          view    = "timeSeries"
          period  = 60
          stat    = "Sum"
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", aws_lb.main.arn_suffix, { label = "5xx", color = "#d13212" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", "LoadBalancer", aws_lb.main.arn_suffix, { label = "4xx", color = "#ff7f0e" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 16; y = 6; width = 8; height = 6
        properties = {
          title   = "ALB Target Response Time (p99)"
          view    = "timeSeries"
          period  = 60
          stat    = "p99"
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.main.arn_suffix, { label = "p99 latency (s)" }]
          ]
        }
      },
      # Row 3: RDS metrics
      {
        type   = "metric"
        x      = 0; y = 12; width = 8; height = 6
        properties = {
          title   = "RDS CPU Utilization (%)"
          view    = "timeSeries"
          period  = 60
          stat    = "Average"
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.postgres.identifier]
          ]
        }
      },
      {
        type   = "metric"
        x      = 8; y = 12; width = 8; height = 6
        properties = {
          title   = "RDS Database Connections"
          view    = "timeSeries"
          period  = 60
          stat    = "Average"
          metrics = [
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", aws_db_instance.postgres.identifier]
          ]
        }
      },
      {
        type   = "metric"
        x      = 16; y = 12; width = 8; height = 6
        properties = {
          title   = "RDS Free Storage (GiB)"
          view    = "timeSeries"
          period  = 300
          stat    = "Minimum"
          metrics = [
            ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", aws_db_instance.postgres.identifier,
              { label = "Free storage (bytes)" }
            ]
          ]
        }
      }
    ]
  })
}

###############################################################################
# Log Metric Filters — convert log patterns to metrics for alerting
###############################################################################

resource "aws_cloudwatch_log_metric_filter" "app_errors" {
  name           = "${local.name_prefix}-app-error-count"
  log_group_name = aws_cloudwatch_log_group.app.name
  pattern        = "[timestamp, level = ERROR, ...]"

  metric_transformation {
    name          = "AppErrorCount"
    namespace     = "${var.project_name}/${var.environment}"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "app_error_rate_high" {
  alarm_name          = "${local.name_prefix}-app-error-rate-high"
  alarm_description   = "Application error log rate exceeded 10/min for 2 consecutive minutes"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "AppErrorCount"
  namespace           = "${var.project_name}/${var.environment}"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = {
    Name     = "${local.name_prefix}-app-error-rate-high"
    Severity = "warning"
  }
}
