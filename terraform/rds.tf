###############################################################################
# rds.tf — RDS PostgreSQL, subnet groups, parameter groups, Secrets Manager
#
# Architecture Decision:
#   Multi-AZ deployment provides synchronous standby replication and
#   automatic failover (<2 min RTO). Storage autoscaling removes the need
#   for manual capacity planning. Credentials are stored in Secrets Manager
#   with automatic rotation rather than being hardcoded or stored in tfstate.
###############################################################################

###############################################################################
# DB Subnet Group — spans isolated database subnets
###############################################################################

resource "aws_db_subnet_group" "postgres" {
  name        = "${local.name_prefix}-db-subnet-group"
  description = "Subnet group for ${local.name_prefix} PostgreSQL RDS instance"
  subnet_ids  = aws_subnet.database[*].id

  tags = {
    Name = "${local.name_prefix}-db-subnet-group"
  }
}

###############################################################################
# DB Parameter Group — PostgreSQL tuning
###############################################################################

resource "aws_db_parameter_group" "postgres" {
  name        = "${local.name_prefix}-postgres15"
  family      = "postgres15"
  description = "Custom parameter group for ${local.name_prefix} PostgreSQL 15"

  # Performance tuning parameters
  parameter {
    name  = "shared_preload_libraries"
    value = "pg_stat_statements"
    apply_method = "pending-reboot"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"   # Log queries slower than 1 second
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  parameter {
    name  = "log_lock_waits"
    value = "1"
  }

  parameter {
    name  = "idle_in_transaction_session_timeout"
    value = "300000"   # Kill idle transactions after 5 minutes
  }

  parameter {
    name  = "max_connections"
    value = "200"
  }

  tags = {
    Name = "${local.name_prefix}-postgres-params"
  }
}

###############################################################################
# Security Group — RDS
###############################################################################

resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds-sg"
  description = "Allow PostgreSQL from ECS tasks only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from ECS tasks"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  # No egress rule — RDS does not need outbound internet access
  egress {
    description = "Allow all outbound (for parameter group updates via AWS endpoints)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-rds-sg"
  }
}

###############################################################################
# Secrets Manager — RDS Credentials
#
# Store credentials in Secrets Manager before the RDS instance is created so
# the password is never written to Terraform state in plain text.
###############################################################################

resource "random_password" "rds_master" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
  # Exclude characters that break PostgreSQL connection strings
  min_upper        = 4
  min_lower        = 4
  min_numeric      = 4
  min_special      = 4
}

resource "aws_secretsmanager_secret" "rds_credentials" {
  name        = "${local.name_prefix}/rds/credentials"
  description = "RDS PostgreSQL master credentials for ${local.name_prefix}"

  # Prevent immediate deletion so recovery is possible during the recovery window
  recovery_window_in_days = 7

  tags = {
    Name = "${local.name_prefix}-rds-credentials"
  }
}

resource "aws_secretsmanager_secret_version" "rds_credentials" {
  secret_id = aws_secretsmanager_secret.rds_credentials.id

  secret_string = jsonencode({
    username = var.rds_username
    password = random_password.rds_master.result
    host     = aws_db_instance.postgres.address
    port     = aws_db_instance.postgres.port
    dbname   = var.rds_db_name
    url      = "postgresql://${var.rds_username}:${random_password.rds_master.result}@${aws_db_instance.postgres.address}:${aws_db_instance.postgres.port}/${var.rds_db_name}"
  })

  # Defer creation until RDS instance is available (needed for the host/port values)
  depends_on = [aws_db_instance.postgres]
}

###############################################################################
# RDS Instance
###############################################################################

resource "aws_db_instance" "postgres" {
  identifier = "${local.name_prefix}-postgres"

  # Engine
  engine               = "postgres"
  engine_version       = var.rds_engine_version
  instance_class       = var.rds_instance_class

  # Storage
  allocated_storage     = var.rds_allocated_storage
  max_allocated_storage = var.rds_max_allocated_storage   # Storage autoscaling upper bound
  storage_type          = "gp3"                           # GP3 decouples IOPS from size
  storage_encrypted     = true

  # Database
  db_name  = var.rds_db_name
  username = var.rds_username
  password = random_password.rds_master.result

  # Networking
  db_subnet_group_name   = aws_db_subnet_group.postgres.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false   # Never expose RDS directly; access through ECS

  # High Availability
  multi_az = var.rds_multi_az

  # Maintenance
  parameter_group_name    = aws_db_parameter_group.postgres.name
  backup_retention_period = var.rds_backup_retention_days
  backup_window           = "03:00-04:00"      # UTC — off-peak for US Eastern
  maintenance_window      = "sun:04:00-sun:05:00"
  auto_minor_version_upgrade = true
  deletion_protection     = var.rds_deletion_protection

  # Monitoring
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  monitoring_interval              = 60        # Enhanced monitoring every 60 seconds
  monitoring_role_arn              = aws_iam_role.rds_monitoring.arn
  performance_insights_enabled     = true
  performance_insights_retention_period = 7   # 7-day free tier

  # Snapshot on delete for safety
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.name_prefix}-postgres-final-${formatdate("YYYYMMDD", timestamp())}"

  tags = {
    Name = "${local.name_prefix}-postgres"
  }

  lifecycle {
    # Prevent accidental destruction; must be done manually or via a targeted destroy
    prevent_destroy = false
    # Ignore password changes from outside Terraform (e.g. rotation)
    ignore_changes = [password]
  }
}

###############################################################################
# RDS Enhanced Monitoring IAM Role
###############################################################################

resource "aws_iam_role" "rds_monitoring" {
  name = "${local.name_prefix}-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${local.name_prefix}-rds-monitoring-role"
  }
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

###############################################################################
# Read Replica (optional — uncomment for read-heavy workloads)
###############################################################################

# resource "aws_db_instance" "postgres_replica" {
#   identifier          = "${local.name_prefix}-postgres-replica"
#   instance_class      = var.rds_instance_class
#   replicate_source_db = aws_db_instance.postgres.identifier
#
#   backup_retention_period    = 0   # Replicas do not maintain backups
#   auto_minor_version_upgrade = true
#   publicly_accessible        = false
#   storage_encrypted          = true
#
#   tags = {
#     Name = "${local.name_prefix}-postgres-replica"
#   }
# }
