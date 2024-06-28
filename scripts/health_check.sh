#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# health_check.sh — Verify application health after deployment
###############################################################################

ENDPOINT="${HEALTH_CHECK_URL:-http://localhost:8000/health}"
MAX_RETRIES="${MAX_RETRIES:-10}"
RETRY_INTERVAL="${RETRY_INTERVAL:-10}"

echo "==> Running health check against: $ENDPOINT"

for i in $(seq 1 "$MAX_RETRIES"); do
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$ENDPOINT" || true)

  if [ "$HTTP_STATUS" -eq 200 ]; then
    echo "==> Health check passed (attempt $i/$MAX_RETRIES) — HTTP $HTTP_STATUS"
    exit 0
  fi

  echo "    Attempt $i/$MAX_RETRIES failed (HTTP $HTTP_STATUS). Retrying in ${RETRY_INTERVAL}s..."
  sleep "$RETRY_INTERVAL"
done

echo "ERROR: Health check failed after $MAX_RETRIES attempts." >&2
exit 1
