# =============================================================================
# Makefile — Common commands for the aws-cloud-infra project
#
# Usage: make <target> [VAR=value ...]
#
# Examples:
#   make init
#   make plan
#   make apply
#   make build TAG=v1.2.3
#   make deploy ENVIRONMENT=staging
#   make health
# =============================================================================

# ---------------------------------------------------------------------------
# Configuration (overridable via environment or CLI)
# ---------------------------------------------------------------------------
PROJECT_NAME  ?= myapp
ENVIRONMENT   ?= production
AWS_REGION    ?= us-east-1
TF_DIR        := terraform
DOCKER_DIR    := docker
SCRIPTS_DIR   := scripts

# Derive from git if not set
IMAGE_TAG     ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "latest")
AWS_ACCOUNT   ?= $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)
ECR_REGISTRY  := $(AWS_ACCOUNT).dkr.ecr.$(AWS_REGION).amazonaws.com
REPO_NAME     := $(PROJECT_NAME)-$(ENVIRONMENT)/app
IMAGE_URI     := $(ECR_REGISTRY)/$(REPO_NAME):$(IMAGE_TAG)

# Terraform vars file (warn if missing)
TF_VARS_FILE  := $(TF_DIR)/terraform.tfvars

# Colours
GREEN  := \033[0;32m
YELLOW := \033[1;33m
RED    := \033[0;31m
RESET  := \033[0m

# ---------------------------------------------------------------------------
# Default target
# ---------------------------------------------------------------------------
.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help message
	@echo ""
	@echo "$(GREEN)aws-cloud-infra$(RESET) — Available targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  $(YELLOW)%-20s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "Variables (current values):"
	@echo "  PROJECT_NAME  = $(PROJECT_NAME)"
	@echo "  ENVIRONMENT   = $(ENVIRONMENT)"
	@echo "  AWS_REGION    = $(AWS_REGION)"
	@echo "  IMAGE_TAG     = $(IMAGE_TAG)"
	@echo ""

# ---------------------------------------------------------------------------
# Terraform targets
# ---------------------------------------------------------------------------

.PHONY: init
init: _check-tfvars ## Initialize Terraform with remote backend
	@echo "$(GREEN)>> terraform init$(RESET)"
	cd $(TF_DIR) && terraform init -upgrade

.PHONY: fmt
fmt: ## Format all Terraform files in-place
	@echo "$(GREEN)>> terraform fmt$(RESET)"
	cd $(TF_DIR) && terraform fmt -recursive

.PHONY: fmt-check
fmt-check: ## Check Terraform formatting (non-destructive)
	@echo "$(GREEN)>> terraform fmt -check$(RESET)"
	cd $(TF_DIR) && terraform fmt -check -recursive

.PHONY: validate
validate: init ## Validate Terraform configuration syntax
	@echo "$(GREEN)>> terraform validate$(RESET)"
	cd $(TF_DIR) && terraform validate

.PHONY: lint
lint: ## Run tflint on Terraform code
	@command -v tflint >/dev/null 2>&1 || { echo "$(RED)tflint not found. Install: https://github.com/terraform-linters/tflint$(RESET)"; exit 1; }
	@echo "$(GREEN)>> tflint$(RESET)"
	cd $(TF_DIR) && tflint --init && tflint

.PHONY: plan
plan: init ## Generate and display Terraform execution plan
	@echo "$(GREEN)>> terraform plan$(RESET)"
	cd $(TF_DIR) && terraform plan \
		-var="project_name=$(PROJECT_NAME)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="aws_region=$(AWS_REGION)" \
		-var="app_image_tag=$(IMAGE_TAG)" \
		-out=tfplan

.PHONY: apply
apply: plan ## Apply Terraform changes (requires confirmation)
	@echo "$(YELLOW)>> terraform apply$(RESET)"
	@read -p "Apply changes to $(ENVIRONMENT)? [y/N] " confirm && \
		[ "$$confirm" = "y" ] || { echo "Aborted."; exit 1; }
	cd $(TF_DIR) && terraform apply tfplan

.PHONY: apply-auto
apply-auto: plan ## Apply Terraform changes without confirmation (CI use only)
	@echo "$(GREEN)>> terraform apply -auto-approve$(RESET)"
	cd $(TF_DIR) && terraform apply -auto-approve tfplan

.PHONY: destroy
destroy: ## DANGER: Destroy all infrastructure (interactive confirmation required)
	@echo "$(RED)WARNING: This will destroy ALL infrastructure in $(ENVIRONMENT)!$(RESET)"
	@read -p "Type the environment name to confirm: " confirm && \
		[ "$$confirm" = "$(ENVIRONMENT)" ] || { echo "Aborted. Wrong confirmation."; exit 1; }
	cd $(TF_DIR) && terraform destroy \
		-var="project_name=$(PROJECT_NAME)" \
		-var="environment=$(ENVIRONMENT)" \
		-var="aws_region=$(AWS_REGION)"

.PHONY: output
output: ## Show Terraform outputs
	@echo "$(GREEN)>> terraform output$(RESET)"
	cd $(TF_DIR) && terraform output

.PHONY: state-list
state-list: ## List all resources in Terraform state
	cd $(TF_DIR) && terraform state list

# ---------------------------------------------------------------------------
# Docker targets
# ---------------------------------------------------------------------------

.PHONY: ecr-login
ecr-login: ## Authenticate Docker with ECR
	@echo "$(GREEN)>> ECR login$(RESET)"
	aws ecr get-login-password --region $(AWS_REGION) \
		| docker login --username AWS --password-stdin $(ECR_REGISTRY)

.PHONY: build
build: ## Build the application Docker image
	@echo "$(GREEN)>> docker build (tag: $(IMAGE_TAG))$(RESET)"
	docker build \
		--file $(DOCKER_DIR)/Dockerfile.app \
		--tag $(IMAGE_URI) \
		--tag $(ECR_REGISTRY)/$(REPO_NAME):latest \
		--build-arg GIT_COMMIT=$(IMAGE_TAG) \
		--cache-from $(ECR_REGISTRY)/$(REPO_NAME):latest \
		.

.PHONY: build-nginx
build-nginx: ## Build the Nginx Docker image
	@echo "$(GREEN)>> docker build nginx$(RESET)"
	docker build \
		--file $(DOCKER_DIR)/Dockerfile.nginx \
		--tag $(ECR_REGISTRY)/$(PROJECT_NAME)-$(ENVIRONMENT)/nginx:$(IMAGE_TAG) \
		.

.PHONY: push
push: ecr-login ## Push Docker image to ECR
	@echo "$(GREEN)>> docker push$(RESET)"
	docker push $(IMAGE_URI)
	docker push $(ECR_REGISTRY)/$(REPO_NAME):latest

.PHONY: build-push
build-push: build push ## Build and push Docker image in one step

.PHONY: scan
scan: ## Scan Docker image for vulnerabilities with Trivy
	@command -v trivy >/dev/null 2>&1 || { echo "$(RED)trivy not found. Install: https://aquasecurity.github.io/trivy$(RESET)"; exit 1; }
	@echo "$(GREEN)>> trivy image scan$(RESET)"
	trivy image --severity HIGH,CRITICAL $(IMAGE_URI)

# ---------------------------------------------------------------------------
# Deployment targets
# ---------------------------------------------------------------------------

.PHONY: deploy
deploy: ## Deploy the application to ECS (uses scripts/deploy.sh)
	@echo "$(GREEN)>> deploy $(ENVIRONMENT) tag=$(IMAGE_TAG)$(RESET)"
	chmod +x $(SCRIPTS_DIR)/deploy.sh
	PROJECT_NAME=$(PROJECT_NAME) \
	ENVIRONMENT=$(ENVIRONMENT) \
	AWS_REGION=$(AWS_REGION) \
	IMAGE_TAG=$(IMAGE_TAG) \
		$(SCRIPTS_DIR)/deploy.sh

.PHONY: deploy-skip-build
deploy-skip-build: ## Deploy without rebuilding (promote existing image)
	PROJECT_NAME=$(PROJECT_NAME) \
	ENVIRONMENT=$(ENVIRONMENT) \
	AWS_REGION=$(AWS_REGION) \
	IMAGE_TAG=$(IMAGE_TAG) \
	SKIP_BUILD=true \
		$(SCRIPTS_DIR)/deploy.sh

.PHONY: health
health: ## Run health checks against the deployed environment
	@echo "$(GREEN)>> health check $(ENVIRONMENT)$(RESET)"
	chmod +x $(SCRIPTS_DIR)/health-check.sh
	PROJECT_NAME=$(PROJECT_NAME) \
	ENVIRONMENT=$(ENVIRONMENT) \
	AWS_REGION=$(AWS_REGION) \
		$(SCRIPTS_DIR)/health-check.sh

# ---------------------------------------------------------------------------
# Operational helpers
# ---------------------------------------------------------------------------

.PHONY: logs
logs: ## Tail ECS application logs from CloudWatch (Ctrl+C to stop)
	@echo "$(GREEN)>> CloudWatch logs /ecs/$(PROJECT_NAME)-$(ENVIRONMENT)/app$(RESET)"
	aws logs tail /ecs/$(PROJECT_NAME)-$(ENVIRONMENT)/app \
		--follow \
		--region $(AWS_REGION)

.PHONY: ecs-status
ecs-status: ## Show current ECS service status
	@echo "$(GREEN)>> ECS service status$(RESET)"
	aws ecs describe-services \
		--cluster $(PROJECT_NAME)-$(ENVIRONMENT) \
		--services $(PROJECT_NAME)-$(ENVIRONMENT)-app \
		--region $(AWS_REGION) \
		--output table \
		--query "services[0].{Name:serviceName,Status:status,Desired:desiredCount,Running:runningCount,Pending:pendingCount}"

.PHONY: rds-status
rds-status: ## Show RDS instance status
	@echo "$(GREEN)>> RDS status$(RESET)"
	aws rds describe-db-instances \
		--db-instance-identifier $(PROJECT_NAME)-$(ENVIRONMENT)-postgres \
		--region $(AWS_REGION) \
		--output table \
		--query "DBInstances[0].{ID:DBInstanceIdentifier,Status:DBInstanceStatus,Class:DBInstanceClass,Engine:Engine,Version:EngineVersion}"

.PHONY: secrets
secrets: ## List Secrets Manager secrets for this project
	aws secretsmanager list-secrets \
		--region $(AWS_REGION) \
		--query "SecretList[?starts_with(Name,'$(PROJECT_NAME)-$(ENVIRONMENT)')].{Name:Name,ARN:ARN}" \
		--output table

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
.PHONY: _check-tfvars
_check-tfvars:
	@if [ ! -f "$(TF_VARS_FILE)" ]; then \
		echo "$(YELLOW)WARNING: $(TF_VARS_FILE) not found.$(RESET)"; \
		echo "         Copy the example: cp terraform/terraform.tfvars.example terraform/terraform.tfvars"; \
		echo "         Then edit it with your values."; \
		echo ""; \
	fi

.PHONY: _check-aws
_check-aws:
	@aws sts get-caller-identity > /dev/null 2>&1 || \
		{ echo "$(RED)ERROR: AWS credentials not configured or expired.$(RESET)"; exit 1; }
	@echo "$(GREEN)AWS identity: $(shell aws sts get-caller-identity --query 'Arn' --output text)$(RESET)"

.PHONY: preflight
preflight: _check-aws _check-tfvars ## Run all pre-flight checks
	@for tool in terraform docker aws jq git; do \
		command -v $$tool >/dev/null 2>&1 \
			&& echo "  $(GREEN)✓$(RESET) $$tool" \
			|| echo "  $(RED)✗ $$tool (not found)$(RESET)"; \
	done
