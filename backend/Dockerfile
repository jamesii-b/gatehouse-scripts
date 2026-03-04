# =============================================================================
# Gatehouse API — Backend Dockerfile
# Multi-stage: build deps in a full image, copy only the venv to slim final.
# Runs as non-root user 'gatehouse' (uid 1001).
# =============================================================================

ARG PYTHON_VERSION=3.11

# ── Stage 1: builder ──────────────────────────────────────────────────────────
FROM python:${PYTHON_VERSION}-slim AS builder

ARG REPO_URL=https://github.com/CoryHawkless/gatehouse-api.git
ARG BRANCH=main

# Build-time deps (not carried into the final image)
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        libpq-dev \
        git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN git clone --depth=1 --branch "$BRANCH" "$REPO_URL" .

# Create venv and install all Python deps inside it
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --upgrade pip --quiet \
    && /opt/venv/bin/pip install -r requirements.txt --quiet \
    && /opt/venv/bin/pip install gunicorn --quiet

# ── Stage 2: runtime ──────────────────────────────────────────────────────────
FROM python:${PYTHON_VERSION}-slim AS runtime

LABEL org.opencontainers.image.title="gatehouse-backend" \
      org.opencontainers.image.description="Gatehouse API (Flask + gunicorn)" \
      org.opencontainers.image.source="https://github.com/CoryHawkless/gatehouse-api"

# Runtime-only native libs (libpq for psycopg2, curl for health check)
RUN apt-get update && apt-get install -y --no-install-recommends \
        libpq5 \
        curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 1001 gatehouse \
    && useradd  -u 1001 -g gatehouse -s /sbin/nologin -M gatehouse

# Copy app source and pre-built venv from builder
WORKDIR /app
COPY --from=builder /build    /app
COPY --from=builder /opt/venv /opt/venv

RUN mkdir -p /app/logs && chown -R gatehouse:gatehouse /app

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    FLASK_APP=manage.py \
    FLASK_ENV=production \
    PATH="/opt/venv/bin:$PATH"

USER gatehouse

EXPOSE 5000

HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:5000/api/health || exit 1

CMD ["gunicorn", \
     "--bind", "0.0.0.0:5000", \
     "--workers", "4", \
     "--timeout", "120", \
     "--access-logfile", "-", \
     "--error-logfile", "-", \
     "--log-level", "info", \
     "wsgi:app"]

