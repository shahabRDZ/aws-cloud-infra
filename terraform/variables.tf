###############################################################################
# variables.tf — Input variable declarations
#
# All sensitive defaults are left empty so Terraform will prompt or fail fast
# rather than silently using a weak default.
###############################################################################

###############################################################################
# Global / project
###############################################################################

variable "project_name" {
  description = "Short name used as a prefix for all resource names. Lowercase, no spaces."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.project_name))
    error_message = "project_name must be 2-21 lowercase alphanumeric characters or hyphens, starting with a letter."
  }
}

variable "environment" {
  description = "Deployment environment (e.g. production, staging, development)."
  type        = string
  default     = "production"

  validation {
    condition     = contains(["production", "staging", "development"], var.environment)
    error_message = "environment must be one of: production, staging, development."
  }
}

variable "aws_region" {
  description = "AWS region to deploy all resources into."
  type        = string
  default     = "us-east-1"
}

###############################################################################
# Networking
###############################################################################

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ). Must be within vpc_cidr."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets hosting ECS tasks (one per AZ)."
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "database_subnet_cidrs" {
  description = "CIDR blocks for isolated database subnets (one per AZ, no route to internet)."
  type        = list(string)
  default     = ["10.0.20.0/24", "10.0.21.0/24"]
}

variable "enable_nat_gateway" {
  description = "Whether to create NAT Gateway(s) for outbound internet access from private subnets."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Use a single NAT Gateway shared across all AZs (lower cost; single point of failure). Set false for production HA."
  type        = bool
  default     = false
}

###############################################################################
# ECS / Application
###############################################################################

variable "ecs_task_cpu" {
  description = "CPU units allocated to each ECS task (1024 = 1 vCPU)."
  type        = number
  default     = 512

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096], var.ecs_task_cpu)
    error_message = "ecs_task_cpu must be a valid Fargate CPU value: 256, 512, 1024, 2048, or 4096."
  }
}

variable "ecs_task_memory" {
  description = "Memory (MiB) allocated to each ECS task."
  type        = number
  default     = 1024
}

variable "app_desired_count" {
  description = "Desired number of ECS tasks to run."
  type        = number
  default     = 2
}

variable "app_min_count" {
  description = "Minimum number of ECS tasks for auto-scaling."
  type        = number
  default     = 2
}

variable "app_max_count" {
  description = "Maximum number of ECS tasks for auto-scaling."
  type        = number
  default     = 10
}

variable "app_port" {
  description = "Port the application container listens on."
  type        = number
  default     = 8080
}

variable "app_image_tag" {
  description = "Docker image tag to deploy. Set by CI/CD pipeline."
  type        = string
  default     = "latest"
}

variable "enable_fargate_spot" {
  description = "Enable Fargate Spot capacity provider for non-critical workloads (cost saving)."
  type        = bool
  default     = false
}

###############################################################################
# RDS
###############################################################################

variable "rds_engine_version" {
  description = "PostgreSQL engine version."
  type        = string
  default     = "15.4"
}

variable "rds_instance_class" {
  description = "RDS instance type."
  type        = string
  default     = "db.t3.medium"
}

variable "rds_allocated_storage" {
  description = "Initial allocated storage in GiB."
  type        = number
  default     = 20
}

variable "rds_max_allocated_storage" {
  description = "Maximum storage autoscaling ceiling in GiB."
  type        = number
  default     = 100
}

variable "rds_multi_az" {
  description = "Enable Multi-AZ for RDS (recommended for production)."
  type        = bool
  default     = true
}

variable "rds_backup_retention_days" {
  description = "Number of days to retain automated RDS backups."
  type        = number
  default     = 7
}

variable "rds_deletion_protection" {
  description = "Prevent accidental deletion of the RDS instance."
  type        = bool
  default     = true
}

variable "rds_db_name" {
  description = "Name of the initial database to create."
  type        = string
  default     = "appdb"
}

variable "rds_username" {
  description = "Master username for the RDS instance."
  type        = string
  default     = "dbadmin"
  sensitive   = true
}

###############################################################################
# ALB / HTTPS
###############################################################################

variable "certificate_arn" {
  description = "ACM certificate ARN for the ALB HTTPS listener. Leave empty to use HTTP only."
  type        = string
  default     = ""
}

variable "enable_waf" {
  description = "Attach AWS WAF WebACL to the ALB."
  type        = bool
  default     = false
}

###############################################################################
# S3
###############################################################################

variable "s3_force_destroy" {
  description = "Allow Terraform to destroy S3 buckets even if they contain objects (use with caution)."
  type        = bool
  default     = false
}

###############################################################################
# Monitoring & Alerting
###############################################################################

variable "alarm_email" {
  description = "Email address to receive CloudWatch alarm notifications."
  type        = string
  default     = ""
}

variable "cpu_alarm_threshold" {
  description = "CPU utilisation percentage that triggers a high-CPU alarm."
  type        = number
  default     = 80
}

variable "memory_alarm_threshold" {
  description = "Memory utilisation percentage that triggers a high-memory alarm."
  type        = number
  default     = 85
}

###############################################################################
# Tagging
###############################################################################

variable "extra_tags" {
  description = "Additional tags to apply to all resources (merged with default_tags)."
  type        = map(string)
  default     = {}
}
