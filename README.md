# AWS Cloud Infrastructure

Production-grade AWS cloud infrastructure using Terraform. Designed for high availability, security, and scalability.

## Architecture

```
                                    ┌─────────────────────────────────────────────────────┐
                                    │                    AWS Cloud                        │
                                    │                                                     │
                    ┌───────────┐   │   ┌──────────────────────────────────────────────┐  │
                    │  Route 53 │───┼──▶│              VPC (10.0.0.0/16)              │  │
                    └───────────┘   │   │                                              │  │
                                    │   │  ┌─────────────────────────────────────────┐ │  │
                    ┌───────────┐   │   │  │          Public Subnets                 │ │  │
                    │ CloudFront│   │   │  │  ┌──────────────┐  ┌──────────────────┐ │ │  │
                    └─────┬─────┘   │   │  │  │  AZ-a (ALB)  │  │   AZ-b (ALB)     │ │ │  │
                          │         │   │  │  └──────┬───────┘  └────────┬─────────┘ │ │  │
                          │         │   │  │         │  Application      │            │ │  │
                          │         │   │  │         ▼  Load Balancer    ▼            │ │  │
                          │         │   │  │  ┌──────────────────────────────────┐   │ │  │
                          │         │   │  │  │           ALB (HTTPS/443)        │   │ │  │
                          │         │   │  │  └──────────────────────────────────┘   │ │  │
                          │         │   │  └─────────────────────────────────────────┘ │  │
                          │         │   │                     │                         │  │
                          │         │   │  ┌──────────────────▼──────────────────────┐ │  │
                          │         │   │  │          Private Subnets                │ │  │
                          │         │   │  │  ┌──────────────┐  ┌──────────────────┐ │ │  │
                          │         │   │  │  │   ECS Fargate│  │   ECS Fargate    │ │ │  │
                          │         │   │  │  │   Task AZ-a  │  │   Task AZ-b      │ │ │  │
                          │         │   │  │  └──────┬───────┘  └────────┬─────────┘ │ │  │
                          │         │   │  │         │                   │            │ │  │
                          │         │   │  │         ▼                   ▼            │ │  │
                          │         │   │  │  ┌──────────────────────────────────┐   │ │  │
                          │         │   │  │  │  RDS PostgreSQL (Multi-AZ)       │   │ │  │
                          │         │   │  │  │  Primary       │   Standby       │   │ │  │
                          │         │   │  │  └──────────────────────────────────┘   │ │  │
                          │         │   │  └─────────────────────────────────────────┘ │  │
                          │         │   │                                              │  │
                          │         │   │  ┌─────────────────────────────────────────┐ │  │
                          ▼         │   │  │         S3 Buckets                      │ │  │
                    ┌───────────┐   │   │  │  [static-assets] [logs] [tf-state]      │ │  │
                    │  S3 Static│◀──┼───┤  └─────────────────────────────────────────┘ │  │
                    │  Assets   │   │   │                                              │  │
                    └───────────┘   │   └──────────────────────────────────────────────┘  │
                                    │                                                     │
                                    │   ┌──────────────────────────────────────────────┐  │
                                    │   │          Monitoring & Observability          │  │
                                    │   │  CloudWatch │ Prometheus │ Grafana           │  │
                                    │   └──────────────────────────────────────────────┘  │
                                    └─────────────────────────────────────────────────────┘
```

## Features

- **High Availability**: Multi-AZ deployment across 2+ availability zones
- **Security**: Private subnets for compute/data, security groups with least-privilege, secrets in AWS Secrets Manager
- **Scalability**: ECS Fargate with auto-scaling policies based on CPU/memory/request count
- **Observability**: CloudWatch dashboards, alarms, Prometheus metrics, and Grafana dashboards
- **Cost Optimization**: NAT Gateway sharing, Fargate Spot support, S3 lifecycle policies
- **CI/CD**: GitHub Actions pipelines for Terraform plan/apply and Docker build/push to ECR
- **State Management**: Remote Terraform state in S3 with DynamoDB locking

## Stack

| Component         | Technology                        |
|-------------------|-----------------------------------|
| IaC               | Terraform >= 1.6                  |
| Compute           | AWS ECS Fargate                   |
| Database          | AWS RDS PostgreSQL 15 (Multi-AZ)  |
| Load Balancing    | AWS Application Load Balancer     |
| Networking        | AWS VPC, Subnets, NAT GW, IGW     |
| Storage           | AWS S3                            |
| Container Registry| AWS ECR                           |
| Monitoring        | CloudWatch, Prometheus, Grafana   |
| Secrets           | AWS Secrets Manager               |
| DNS               | AWS Route 53 (optional)           |
| CDN               | AWS CloudFront (optional)         |

## Prerequisites

- [Terraform](https://www.terraform.io/downloads) >= 1.6.0
- [AWS CLI](https://aws.amazon.com/cli/) >= 2.x configured with appropriate credentials
- [Docker](https://docs.docker.com/get-docker/) >= 24.x
- [jq](https://stedolan.github.io/jq/) for JSON processing in scripts
- AWS account with permissions for VPC, ECS, RDS, ALB, S3, IAM, CloudWatch

## Quick Start

### 1. Bootstrap Remote State (one-time)

```bash
# Create S3 bucket for Terraform state
aws s3 mb s3://your-company-terraform-state --region us-east-1
aws s3api put-bucket-versioning \
  --bucket your-company-terraform-state \
  --versioning-configuration Status=Enabled

# Create DynamoDB table for state locking
aws dynamodb create-table \
  --table-name terraform-state-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

### 2. Configure Variables

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform.tfvars with your values
```

### 3. Deploy with Make

```bash
# Initialize Terraform
make init

# Preview changes
make plan

# Deploy infrastructure
make apply

# Build and push Docker images
make build push

# Deploy application
make deploy
```

## Makefile Commands

| Command            | Description                                       |
|--------------------|---------------------------------------------------|
| `make init`        | Initialize Terraform with remote backend          |
| `make plan`        | Show Terraform execution plan                     |
| `make apply`       | Apply Terraform changes                           |
| `make destroy`     | Destroy all infrastructure (use with caution)     |
| `make build`       | Build Docker images                               |
| `make push`        | Push Docker images to ECR                         |
| `make deploy`      | Force new ECS deployment                          |
| `make health`      | Run health checks against deployed services       |
| `make logs`        | Tail ECS service logs from CloudWatch             |
| `make fmt`         | Format Terraform files                            |
| `make validate`    | Validate Terraform configuration                  |
| `make lint`        | Run tflint on Terraform code                      |

## Directory Structure

```
aws-cloud-infra/
├── terraform/
│   ├── main.tf              # Provider config, backend, data sources
│   ├── variables.tf         # Input variable declarations
│   ├── outputs.tf           # Output values
│   ├── vpc.tf               # VPC, subnets, routing, NAT/IGW
│   ├── ecs.tf               # ECS cluster, task defs, services, autoscaling
│   ├── rds.tf               # RDS PostgreSQL, parameter groups, subnet groups
│   ├── alb.tf               # ALB, listeners, target groups, WAF
│   ├── s3.tf                # S3 buckets, policies, lifecycle rules
│   ├── iam.tf               # IAM roles, policies, instance profiles
│   ├── cloudwatch.tf        # Alarms, dashboards, log groups
│   └── terraform.tfvars.example
├── docker/
│   ├── Dockerfile.app       # Application container
│   ├── Dockerfile.nginx     # Nginx reverse proxy
│   └── nginx.conf           # Nginx configuration
├── scripts/
│   ├── deploy.sh            # ECS deployment automation
│   └── health-check.sh      # Service health checks
├── monitoring/
│   ├── prometheus.yml       # Prometheus scrape config
│   └── grafana-dashboard.json
├── .github/
│   └── workflows/
│       ├── terraform.yml    # Terraform CI/CD
│       └── docker-build.yml # Docker build/push pipeline
├── Makefile
└── README.md
```

## Environment Configuration

| Variable              | Description                           | Default       |
|-----------------------|---------------------------------------|---------------|
| `project_name`        | Project name (used in resource names) | `myapp`       |
| `environment`         | Deployment environment                | `production`  |
| `aws_region`          | AWS region                            | `us-east-1`   |
| `vpc_cidr`            | VPC CIDR block                        | `10.0.0.0/16` |
| `rds_instance_class`  | RDS instance type                     | `db.t3.medium`|
| `ecs_task_cpu`        | ECS task CPU units (1024 = 1 vCPU)   | `512`         |
| `ecs_task_memory`     | ECS task memory in MB                 | `1024`        |

## Security Notes

- All database credentials are stored in AWS Secrets Manager, never in Terraform state plaintext
- ECS tasks run in private subnets with no direct internet access
- RDS instances are in isolated subnets with no internet routing
- Security groups follow least-privilege: ALB accepts 443 from 0.0.0.0/0, ECS only from ALB, RDS only from ECS
- S3 buckets have public access blocked; static assets served via CloudFront only
- IAM roles use task-level granularity with only required permissions

## Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-change`
3. Run `make fmt validate lint` before committing
4. Open a pull request — Terraform plan runs automatically on PR

## License

MIT
