#!/usr/bin/env bash
# =============================================================================
# health-check.sh — Comprehensive health checks for deployed services
#
# Checks:
#   1. ALB health endpoint responds with HTTP 200
#   2. ECS service has the expected number of running tasks
#   3. RDS instance is in 'available' state
#   4. All ECS tasks are passing their health checks
#
# Usage:
#   ./scripts/health-check.sh [OPTIONS]
#
# Options:
#   -e, --environment  Target environment (default: production)
#   -u, --url          ALB URL to check (default: read from Terraform output)
#   -t, --timeout      Max seconds to wait for health (default: 300)
#   -r, --region       AWS region (default: us-east-1)
#   -h, --help         Show this help
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
ENVIRONMENT="${ENVIRONMENT:-production}"
PROJECT_NAME="${PROJECT_NAME:-myapp}"
AWS_REGION="${AWS_REGION:-us-east-1}"
MAX_WAIT="${MAX_WAIT:-300}"
RETRY_INTERVAL=10
ALB_URL="${ALB_URL:-}"

PASS=0; WARN=0; FAIL=0

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--environment) ENVIRONMENT="$2"; shift 2 ;;
    -u|--url)         ALB_URL="$2";     shift 2 ;;
    -t|--timeout)     MAX_WAIT="$2";    shift 2 ;;
    -r|--region)      AWS_REGION="$2";  shift 2 ;;
    -h|--help) grep '^#' "$0" | grep -E '^\# ' | sed 's/^# //'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Colour helpers (disabled when not a TTY)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; RESET=''
fi

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
pass() { ((PASS++));  log "${GREEN}PASS${RESET}  $*"; }
warn() { ((WARN++));  log "${YELLOW}WARN${RESET}  $*" >&2; }
fail() { ((FAIL++));  log "${RED}FAIL${RESET}  $*" >&2; }

ECS_CLUSTER="${PROJECT_NAME}-${ENVIRONMENT}"
ECS_SERVICE="${PROJECT_NAME}-${ENVIRONMENT}-app"

# ---------------------------------------------------------------------------
# Check 1: Resolve ALB URL from Terraform output if not provided
# ---------------------------------------------------------------------------
resolve_alb_url() {
  if [[ -z "$ALB_URL" ]]; then
    log "Resolving ALB URL from Terraform outputs..."
    ALB_DNS=$(aws elbv2 describe-load-balancers \
      --region "$AWS_REGION" \
      --query "LoadBalancers[?contains(LoadBalancerName, '${PROJECT_NAME}-${ENVIRONMENT}')].DNSName" \
      --output text 2>/dev/null | head -1)

    if [[ -n "$ALB_DNS" ]]; then
      ALB_URL="http://${ALB_DNS}"
      log "  ALB URL: $ALB_URL"
    else
      warn "Could not resolve ALB URL — skipping HTTP health check"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Check 2: HTTP health endpoint
# ---------------------------------------------------------------------------
check_http_health() {
  if [[ -z "$ALB_URL" ]]; then
    warn "ALB URL not set — skipping HTTP health check"
    return
  fi

  local url="${ALB_URL}/health"
  log "Checking HTTP health: $url"
  local attempts=0
  local max_attempts=$(( MAX_WAIT / RETRY_INTERVAL ))

  while (( attempts < max_attempts )); do
    HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
      --max-time 10 --connect-timeout 5 "$url" 2>/dev/null || echo "000")

    if [[ "$HTTP_CODE" == "200" ]]; then
      pass "HTTP health check: $url returned $HTTP_CODE"
      return
    fi

    ((attempts++))
    log "  Attempt $attempts/$max_attempts — got HTTP $HTTP_CODE, retrying in ${RETRY_INTERVAL}s..."
    sleep "$RETRY_INTERVAL"
  done

  fail "HTTP health check: $url did not return 200 after ${MAX_WAIT}s (last code: $HTTP_CODE)"
}

# ---------------------------------------------------------------------------
# Check 3: ECS service running task count
# ---------------------------------------------------------------------------
check_ecs_tasks() {
  log "Checking ECS service task count..."

  SERVICE_INFO=$(aws ecs describe-services \
    --cluster "$ECS_CLUSTER" \
    --services "$ECS_SERVICE" \
    --region "$AWS_REGION" \
    --output json 2>/dev/null) || { fail "Could not describe ECS service $ECS_SERVICE"; return; }

  DESIRED=$(echo "$SERVICE_INFO" | jq -r '.services[0].desiredCount')
  RUNNING=$(echo "$SERVICE_INFO" | jq -r '.services[0].runningCount')
  PENDING=$(echo "$SERVICE_INFO" | jq -r '.services[0].pendingCount')
  STATUS=$(echo  "$SERVICE_INFO" | jq -r '.services[0].status')

  log "  Service status: $STATUS | Desired: $DESIRED | Running: $RUNNING | Pending: $PENDING"

  if [[ "$STATUS" != "ACTIVE" ]]; then
    fail "ECS service status is $STATUS (expected ACTIVE)"
  elif (( RUNNING < DESIRED )); then
    fail "ECS running tasks ($RUNNING) is less than desired ($DESIRED)"
  elif (( PENDING > 0 )); then
    warn "ECS has $PENDING pending tasks"
  else
    pass "ECS service: $RUNNING/$DESIRED tasks running"
  fi
}

# ---------------------------------------------------------------------------
# Check 4: ECS task health status
# ---------------------------------------------------------------------------
check_ecs_task_health() {
  log "Checking ECS task health statuses..."

  TASK_ARNS=$(aws ecs list-tasks \
    --cluster "$ECS_CLUSTER" \
    --service-name "$ECS_SERVICE" \
    --desired-status RUNNING \
    --region "$AWS_REGION" \
    --query "taskArns" \
    --output text 2>/dev/null)

  if [[ -z "$TASK_ARNS" ]]; then
    fail "No running tasks found in service $ECS_SERVICE"
    return
  fi

  TASKS=$(aws ecs describe-tasks \
    --cluster "$ECS_CLUSTER" \
    --tasks $TASK_ARNS \
    --region "$AWS_REGION" \
    --output json 2>/dev/null)

  UNHEALTHY=$(echo "$TASKS" | jq '[.tasks[] | select(.healthStatus != "HEALTHY")] | length')
  TOTAL=$(echo "$TASKS" | jq '.tasks | length')

  if (( UNHEALTHY > 0 )); then
    fail "ECS task health: $UNHEALTHY/$TOTAL tasks are not HEALTHY"
    echo "$TASKS" | jq -r '.tasks[] | select(.healthStatus != "HEALTHY") | "  Task \(.taskArn | split("/")[-1]): \(.healthStatus)"'
  else
    pass "ECS task health: $TOTAL/$TOTAL tasks are HEALTHY"
  fi
}

# ---------------------------------------------------------------------------
# Check 5: RDS instance status
# ---------------------------------------------------------------------------
check_rds() {
  log "Checking RDS instance status..."

  DB_IDENTIFIER="${PROJECT_NAME}-${ENVIRONMENT}-postgres"
  RDS_STATUS=$(aws rds describe-db-instances \
    --db-instance-identifier "$DB_IDENTIFIER" \
    --region "$AWS_REGION" \
    --query "DBInstances[0].DBInstanceStatus" \
    --output text 2>/dev/null) || { warn "Could not describe RDS instance $DB_IDENTIFIER"; return; }

  if [[ "$RDS_STATUS" == "available" ]]; then
    pass "RDS instance $DB_IDENTIFIER: $RDS_STATUS"
  elif [[ "$RDS_STATUS" == "backing-up" ]]; then
    warn "RDS instance $DB_IDENTIFIER: $RDS_STATUS (backup in progress — this is normal)"
  else
    fail "RDS instance $DB_IDENTIFIER: $RDS_STATUS (expected 'available')"
  fi
}

# ---------------------------------------------------------------------------
# Check 6: ALB target group health
# ---------------------------------------------------------------------------
check_alb_targets() {
  log "Checking ALB target group health..."

  TG_ARN=$(aws elbv2 describe-target-groups \
    --region "$AWS_REGION" \
    --query "TargetGroups[?contains(TargetGroupName, '${PROJECT_NAME}-${ENVIRONMENT}')].TargetGroupArn" \
    --output text 2>/dev/null | head -1)

  if [[ -z "$TG_ARN" ]]; then
    warn "Could not find target group for ${PROJECT_NAME}-${ENVIRONMENT}"
    return
  fi

  HEALTH=$(aws elbv2 describe-target-health \
    --target-group-arn "$TG_ARN" \
    --region "$AWS_REGION" \
    --output json 2>/dev/null)

  HEALTHY_COUNT=$(echo "$HEALTH" | jq '[.TargetHealthDescriptions[] | select(.TargetHealth.State == "healthy")] | length')
  TOTAL_COUNT=$(echo "$HEALTH" | jq '.TargetHealthDescriptions | length')
  UNHEALTHY_COUNT=$(( TOTAL_COUNT - HEALTHY_COUNT ))

  if (( UNHEALTHY_COUNT > 0 )); then
    fail "ALB target group: $UNHEALTHY_COUNT/$TOTAL_COUNT targets are unhealthy"
    echo "$HEALTH" | jq -r '.TargetHealthDescriptions[] | select(.TargetHealth.State != "healthy") | "  Target \(.Target.Id):\(.Target.Port) — \(.TargetHealth.State): \(.TargetHealth.Description)"'
  else
    pass "ALB target group: $HEALTHY_COUNT/$TOTAL_COUNT targets healthy"
  fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
  echo ""
  echo "============================================"
  echo "  Health Check Summary"
  echo "============================================"
  echo "  ${GREEN}PASS${RESET}: $PASS"
  echo "  ${YELLOW}WARN${RESET}: $WARN"
  echo "  ${RED}FAIL${RESET}: $FAIL"
  echo "============================================"

  if (( FAIL > 0 )); then
    echo ""
    echo "  Health check FAILED. Review failures above."
    echo ""
    echo "  Useful commands:"
    echo "    aws logs tail /ecs/${ECS_CLUSTER}/app --follow --region $AWS_REGION"
    echo "    aws ecs describe-services --cluster $ECS_CLUSTER --services $ECS_SERVICE --region $AWS_REGION"
    exit 1
  else
    echo ""
    echo "  All critical checks passed."
    exit 0
  fi
}

# ---------------------------------------------------------------------------
# Run all checks
# ---------------------------------------------------------------------------
log "=== Health Check: ${PROJECT_NAME} / ${ENVIRONMENT} ==="
echo ""

resolve_alb_url
check_http_health
check_ecs_tasks
check_ecs_task_health
check_rds
check_alb_targets
print_summary
