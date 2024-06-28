#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Build, push, and deploy the application to ECS Fargate
#
# Usage:
#   ./scripts/deploy.sh [OPTIONS]
#
# Options:
#   -e, --environment  Target environment (production|staging|development)
#   -t, --tag          Docker image tag (default: git short SHA)
#   -r, --region       AWS region (default: us-east-1)
#   -s, --skip-build   Skip Docker build; deploy the existing image tag
#   -h, --help         Show this help message
#
# Environment Variables (alternative to flags):
#   PROJECT_NAME, ENVIRONMENT, AWS_REGION, IMAGE_TAG, SKIP_BUILD
#
# Examples:
#   ./scripts/deploy.sh --environment staging --tag v1.2.3
#   IMAGE_TAG=$(git rev-parse --short HEAD) ./scripts/deploy.sh
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

PROJECT_NAME="${PROJECT_NAME:-myapp}"
ENVIRONMENT="${ENVIRONMENT:-production}"
AWS_REGION="${AWS_REGION:-us-east-1}"
IMAGE_TAG="${IMAGE_TAG:-$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo "latest")}"
SKIP_BUILD="${SKIP_BUILD:-false}"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
  grep '^#' "$0" | grep -E '^\# ' | sed 's/^# //'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--environment) ENVIRONMENT="$2"; shift 2 ;;
    -t|--tag)         IMAGE_TAG="$2";   shift 2 ;;
    -r|--region)      AWS_REGION="$2";  shift 2 ;;
    -s|--skip-build)  SKIP_BUILD="true"; shift  ;;
    -h|--help)        usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Derived variables
# ---------------------------------------------------------------------------
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
REPO_NAME="${PROJECT_NAME}-${ENVIRONMENT}/app"
IMAGE_URI="${ECR_REGISTRY}/${REPO_NAME}:${IMAGE_TAG}"
ECS_CLUSTER="${PROJECT_NAME}-${ENVIRONMENT}"
ECS_SERVICE="${PROJECT_NAME}-${ENVIRONMENT}-app"
TASK_FAMILY="${PROJECT_NAME}-${ENVIRONMENT}-app"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*"; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*" >&2; }
fail() { log "ERROR $*" >&2; exit 1; }

check_deps() {
  for dep in aws docker jq git; do
    command -v "$dep" >/dev/null 2>&1 || fail "Required dependency not found: $dep"
  done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  check_deps

  info "=== ECS Deployment ==="
  info "Project     : $PROJECT_NAME"
  info "Environment : $ENVIRONMENT"
  info "Region      : $AWS_REGION"
  info "Image tag   : $IMAGE_TAG"
  info "Image URI   : $IMAGE_URI"
  info "ECS cluster : $ECS_CLUSTER"
  info "ECS service : $ECS_SERVICE"
  echo ""

  # Step 1: ECR login
  info "Step 1/5: Authenticating with ECR..."
  aws ecr get-login-password --region "$AWS_REGION" \
    | docker login --username AWS --password-stdin "$ECR_REGISTRY" \
    || fail "ECR login failed"

  # Step 2: Build Docker image
  if [[ "$SKIP_BUILD" == "false" ]]; then
    info "Step 2/5: Building Docker image..."
    docker build \
      --file "${PROJECT_ROOT}/docker/Dockerfile.app" \
      --tag "${IMAGE_URI}" \
      --tag "${ECR_REGISTRY}/${REPO_NAME}:latest" \
      --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --build-arg GIT_COMMIT="${IMAGE_TAG}" \
      --cache-from "${ECR_REGISTRY}/${REPO_NAME}:latest" \
      "${PROJECT_ROOT}" \
      || fail "Docker build failed"
  else
    info "Step 2/5: Skipping build (--skip-build)"
  fi

  # Step 3: Push to ECR
  info "Step 3/5: Pushing image to ECR..."
  docker push "${IMAGE_URI}" || fail "Docker push failed"
  [[ "$SKIP_BUILD" == "false" ]] && docker push "${ECR_REGISTRY}/${REPO_NAME}:latest"

  # Step 4: Register new task definition with updated image
  info "Step 4/5: Registering new ECS task definition..."
  CURRENT_TASK_DEF=$(aws ecs describe-task-definition \
    --task-definition "$TASK_FAMILY" \
    --region "$AWS_REGION" \
    --output json)

  NEW_TASK_DEF=$(echo "$CURRENT_TASK_DEF" | jq \
    --arg IMAGE "$IMAGE_URI" \
    '.taskDefinition
     | .containerDefinitions[0].image = $IMAGE
     | del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)')

  NEW_TASK_DEF_ARN=$(aws ecs register-task-definition \
    --cli-input-json "$NEW_TASK_DEF" \
    --region "$AWS_REGION" \
    --query "taskDefinition.taskDefinitionArn" \
    --output text) \
    || fail "Task definition registration failed"
  info "  Registered: $NEW_TASK_DEF_ARN"

  # Step 5: Update service and wait for stability
  info "Step 5/5: Updating ECS service and waiting for stability..."
  aws ecs update-service \
    --cluster "$ECS_CLUSTER" \
    --service "$ECS_SERVICE" \
    --task-definition "$NEW_TASK_DEF_ARN" \
    --region "$AWS_REGION" \
    --output json > /dev/null \
    || fail "ECS service update failed"

  info "  Waiting for deployment to complete (this may take 2-5 minutes)..."
  aws ecs wait services-stable \
    --cluster "$ECS_CLUSTER" \
    --services "$ECS_SERVICE" \
    --region "$AWS_REGION" \
    || fail "ECS service did not stabilize. Check CloudWatch logs: /ecs/${ECS_CLUSTER}/app"

  # Deployment summary
  info ""
  info "=== Deployment Successful ==="
  RUNNING_COUNT=$(aws ecs describe-services \
    --cluster "$ECS_CLUSTER" \
    --services "$ECS_SERVICE" \
    --region "$AWS_REGION" \
    --query "services[0].runningCount" \
    --output text)
  info "Running tasks : $RUNNING_COUNT"
  info "Image         : $IMAGE_URI"
  info "Task def      : $NEW_TASK_DEF_ARN"
  info ""
  info "View logs:"
  info "  aws logs tail /ecs/${ECS_CLUSTER}/app --follow --region $AWS_REGION"
}

main "$@"
