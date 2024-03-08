###############################################################################
# outputs.tf — Output values exposed after `terraform apply`
#
# These are used by:
#   - deploy.sh scripts to resolve dynamic ARNs/URLs
#   - CI/CD pipelines to parameterise deployment steps
#   - Operators running ad-hoc AWS CLI commands
###############################################################################

###############################################################################
# Networking
###############################################################################

output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of public subnets (ALB, NAT GW)."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of private subnets (ECS tasks)."
  value       = aws_subnet.private[*].id
}

output "database_subnet_ids" {
  description = "IDs of isolated database subnets (RDS)."
  value       = aws_subnet.database[*].id
}

output "nat_gateway_ips" {
  description = "Elastic IP addresses of NAT Gateways (whitelist these in partner firewalls)."
  value       = aws_eip.nat[*].public_ip
}

###############################################################################
# ALB
###############################################################################

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer."
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "Hosted zone ID of the ALB (for Route 53 alias records)."
  value       = aws_lb.main.zone_id
}

output "alb_arn" {
  description = "ARN of the Application Load Balancer."
  value       = aws_lb.main.arn
}

output "alb_security_group_id" {
  description = "Security group ID attached to the ALB."
  value       = aws_security_group.alb.id
}

###############################################################################
# ECS
###############################################################################

output "ecs_cluster_id" {
  description = "ID of the ECS cluster."
  value       = aws_ecs_cluster.main.id
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster."
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "Name of the ECS service."
  value       = aws_ecs_service.app.name
}

output "ecs_task_definition_arn" {
  description = "ARN of the latest active ECS task definition."
  value       = aws_ecs_task_definition.app.arn
}

output "ecr_repository_url" {
  description = "URL of the ECR repository. Push images here."
  value       = aws_ecr_repository.app.repository_url
}

###############################################################################
# RDS
###############################################################################

output "rds_endpoint" {
  description = "RDS instance endpoint (host:port)."
  value       = aws_db_instance.postgres.endpoint
  sensitive   = true
}

output "rds_port" {
  description = "RDS instance port."
  value       = aws_db_instance.postgres.port
}

output "rds_db_name" {
  description = "Name of the database created in RDS."
  value       = aws_db_instance.postgres.db_name
}

output "rds_secret_arn" {
  description = "ARN of the Secrets Manager secret containing DB credentials."
  value       = aws_secretsmanager_secret.rds_credentials.arn
  sensitive   = true
}

###############################################################################
# S3
###############################################################################

output "s3_static_assets_bucket" {
  description = "Name of the S3 bucket for static assets."
  value       = aws_s3_bucket.static_assets.bucket
}

output "s3_logs_bucket" {
  description = "Name of the S3 bucket for access logs."
  value       = aws_s3_bucket.logs.bucket
}

###############################################################################
# IAM
###############################################################################

output "ecs_task_execution_role_arn" {
  description = "ARN of the ECS task execution IAM role."
  value       = aws_iam_role.ecs_task_execution.arn
}

output "ecs_task_role_arn" {
  description = "ARN of the ECS task IAM role (application runtime permissions)."
  value       = aws_iam_role.ecs_task.arn
}

###############################################################################
# Monitoring
###############################################################################

output "cloudwatch_log_group_app" {
  description = "Name of the CloudWatch log group for application logs."
  value       = aws_cloudwatch_log_group.app.name
}

output "cloudwatch_dashboard_url" {
  description = "URL to the CloudWatch operations dashboard."
  value       = "https://${local.region}.console.aws.amazon.com/cloudwatch/home?region=${local.region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}

###############################################################################
# Convenience summary
###############################################################################

output "deployment_summary" {
  description = "Key URLs and identifiers for quick reference."
  value = {
    app_url        = "https://${aws_lb.main.dns_name}"
    ecr_repo       = aws_ecr_repository.app.repository_url
    ecs_cluster    = aws_ecs_cluster.main.name
    rds_identifier = aws_db_instance.postgres.identifier
    region         = local.region
    account_id     = local.account_id
  }
}
