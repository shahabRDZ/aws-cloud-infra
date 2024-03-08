###############################################################################
# main.tf — Provider configuration, backend, and shared data sources
#
# Architecture Decision:
#   Remote state is stored in S3 with DynamoDB locking to support team
#   collaboration and prevent concurrent state corruption. The S3 bucket
#   and DynamoDB table must be created before first `terraform init`.
###############################################################################

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }

  # Remote state backend — bucket and table must be bootstrapped before init.
  # See README.md Quick Start section for bootstrap commands.
  backend "s3" {
    bucket         = "your-company-terraform-state"
    key            = "aws-cloud-infra/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

###############################################################################
# Provider
###############################################################################

provider "aws" {
  region = var.aws_region

  # All resources created by this config will inherit these tags unless
  # overridden at the resource level.
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "aws-cloud-infra"
    }
  }
}

###############################################################################
# Data Sources
###############################################################################

# Current AWS account ID and region — used throughout for ARN construction
# and to avoid hardcoding account-specific values.
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Fetch available AZs in the configured region so subnet logic is not
# hardcoded to specific zone names.
data "aws_availability_zones" "available" {
  state = "available"
}

# Latest ECS-optimised Amazon Linux 2 AMI — used if EC2 launch type is
# needed in the future. Fargate tasks do not need this but it is useful
# for bastion or debug instances.
data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

###############################################################################
# Random suffix — appended to globally unique resource names (S3 buckets)
# to avoid collisions across accounts/regions.
###############################################################################

resource "random_id" "suffix" {
  byte_length = 4
}

###############################################################################
# Locals — computed values used across multiple files
###############################################################################

locals {
  # Short prefix for resource names: e.g. "myapp-production"
  name_prefix = "${var.project_name}-${var.environment}"

  # Common tags merged on top of provider default_tags where extra context
  # is required (e.g. cost-allocation tags per service component).
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # Account and region shortcuts
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  # AZ list — always pick first two for dual-AZ deployments
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}
