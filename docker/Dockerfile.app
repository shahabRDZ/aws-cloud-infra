# =============================================================================
# Dockerfile.app — Multi-stage build for the application container
#
# Stage 1 (builder): Install dependencies and compile/prepare artifacts
# Stage 2 (runtime): Minimal production image — no build tools, no dev deps
#
# Security practices:
#   - Non-root user (uid 1001) — reduces privilege if container is compromised
#   - Pinned base image tag for reproducible builds
#   - No secrets in image layers (injected at runtime via ECS secrets)
#   - Minimal OS package surface (only curl + tini added)
#   - Tini as PID 1 for proper signal handling and zombie reaping
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Builder — install all deps and compile application
# ---------------------------------------------------------------------------
FROM python:3.12-slim AS builder

WORKDIR /app

# Install build-time OS dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy dependency manifest first — cached unless requirements change
COPY requirements.txt .

# Install Python packages into a prefix so we can copy cleanly into runtime
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ---------------------------------------------------------------------------
# Stage 2: Runtime — minimal image with only production artifacts
# ---------------------------------------------------------------------------
FROM python:3.12-slim AS runtime

# OCI image labels
LABEL org.opencontainers.image.title="myapp" \
      org.opencontainers.image.description="Production application container" \
      org.opencontainers.image.source="https://github.com/your-org/aws-cloud-infra"

# Install runtime OS dependencies only
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    curl \
    tini \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user and group
RUN groupadd --system --gid 1001 appgroup && \
    useradd  --system --uid  1001 --gid appgroup --no-create-home appuser

WORKDIR /app

# Copy installed Python packages from builder stage
COPY --from=builder /install /usr/local

# Copy application source
COPY --chown=appuser:appgroup . .

# Create writable directories the app needs at runtime
RUN mkdir -p /app/logs /tmp/app && \
    chown -R appuser:appgroup /app/logs /tmp/app

# Set Python runtime environment
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app \
    PORT=8080

# Switch to non-root user
USER appuser

# Application port (non-privileged)
EXPOSE 8080

# Use tini as the init process for proper SIGTERM handling and zombie reaping
ENTRYPOINT ["/usr/bin/tini", "--"]

# Health check — ECS health check grace period is 60s, so start-period matches
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -sf http://localhost:8080/health || exit 1

# Gunicorn with threaded workers for I/O-bound workloads
CMD ["gunicorn", \
     "--bind", "0.0.0.0:8080", \
     "--workers", "2", \
     "--threads", "4", \
     "--worker-class", "gthread", \
     "--timeout", "120", \
     "--keep-alive", "5", \
     "--access-logfile", "-", \
     "--error-logfile", "-", \
     "--log-level", "info", \
     "--forwarded-allow-ips", "*", \
     "app:create_app()"]
