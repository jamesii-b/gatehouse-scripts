# =============================================================================
# Gatehouse UI — Frontend Dockerfile
# Multi-stage: Node builder → nginx:alpine runtime.
# Nginx runs as non-root user 'nginx' (uid 101) on port 3000.
# Proxies /api/ and /auth/ to the backend service on the Docker network.
# =============================================================================

ARG NODE_VERSION=18
ARG NGINX_VERSION=alpine

# ── Stage 1: builder ──────────────────────────────────────────────────────────
FROM node:${NODE_VERSION}-alpine AS builder

ARG REPO_URL=https://github.com/CoryHawkless/gatehouse-ui.git
ARG BRANCH=main

RUN apk add --no-cache git

WORKDIR /build

RUN git clone --depth=1 --branch "$BRANCH" "$REPO_URL" .

# Install deps and build — ci install for reproducible lockfile
RUN npm ci --prefer-offline --no-audit \
    && npm run build

# ── Stage 2: runtime ──────────────────────────────────────────────────────────
FROM nginx:${NGINX_VERSION} AS runtime

LABEL org.opencontainers.image.title="gatehouse-frontend" \
      org.opencontainers.image.description="Gatehouse UI (React + Vite → nginx)" \
      org.opencontainers.image.source="https://github.com/CoryHawkless/gatehouse-ui"

RUN apk add --no-cache curl

# Copy built assets
COPY --from=builder /build/dist /app/dist

# Nginx main config
RUN cat > /etc/nginx/nginx.conf << 'EOF'
user nginx;
worker_processes auto;
pid /tmp/nginx.pid;
error_log /var/log/nginx/error.log warn;

events {
    worker_connections 1024;
    use epoll;
    multi_accept on;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format main '$remote_addr - [$time_local] "$request" $status $body_bytes_sent '
                    '"$http_referer" "$http_user_agent" rt=$request_time';
    access_log /var/log/nginx/access.log main;

    sendfile           on;
    tcp_nopush         on;
    tcp_nodelay        on;
    keepalive_timeout  65;
    server_tokens      off;

    client_max_body_size   20M;
    client_body_timeout    30s;
    client_header_timeout  30s;

    gzip              on;
    gzip_vary         on;
    gzip_proxied      any;
    gzip_comp_level   5;
    gzip_min_length   256;
    gzip_types        text/plain text/css text/xml text/javascript
                      application/json application/javascript
                      application/xml image/svg+xml;

    include /etc/nginx/conf.d/*.conf;
}
EOF

# Site config
RUN cat > /etc/nginx/conf.d/default.conf << 'EOF'
server {
    listen      3000 default_server;
    listen [::]:3000 default_server;
    server_name _;
    root        /app/dist;

    # Security headers
    add_header X-Frame-Options           "SAMEORIGIN"              always;
    add_header X-Content-Type-Options    "nosniff"                 always;
    add_header X-XSS-Protection          "1; mode=block"           always;
    add_header Referrer-Policy           "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy        "camera=(), microphone=(), geolocation=()" always;

    # Health probe (no logs)
    location = /health {
        access_log off;
        return 200 "ok\n";
        add_header Content-Type text/plain;
    }

    # API proxy → backend container
    location /api/ {
        proxy_pass         http://backend:5000/api/;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout    300s;
        proxy_connect_timeout  10s;
        proxy_send_timeout     60s;
    }

    # Auth proxy → backend container
    location /auth/ {
        proxy_pass         http://backend:5000/auth/;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout    300s;
        proxy_connect_timeout  10s;
        proxy_send_timeout     60s;
    }

    # Static assets — aggressive caching (content-hashed filenames)
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires            1y;
        add_header         Cache-Control "public, immutable";
        access_log         off;
    }

    # SPA fallback
    location / {
        try_files $uri $uri/ /index.html;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
    }

    # Block hidden files
    location ~ /\. { deny all; access_log off; log_not_found off; }
}
EOF

# nginx writes tmp files to /tmp; allow non-root to write logs
RUN chown -R nginx:nginx /var/cache/nginx /var/log/nginx \
    && touch /tmp/nginx.pid && chown nginx:nginx /tmp/nginx.pid

USER nginx

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:3000/health || exit 1

CMD ["nginx", "-g", "daemon off;"]


RUN mkdir -p /etc/nginx/conf.d /var/log/nginx

# Nginx main config
RUN cat > /etc/nginx/nginx.conf << 'NGINX_EOF'
user nginx;
worker_processes auto;
pid /var/run/nginx.pid;
error_log /var/log/nginx/error.log warn;
events { worker_connections 1024; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    log_format main '$remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent';
    access_log /var/log/nginx/access.log main;
    sendfile on;
    keepalive_timeout 65;
    client_max_body_size 20M;
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml text/javascript application/json application/javascript image/svg+xml;
    include /etc/nginx/conf.d/*.conf;
}
NGINX_EOF

# Site config — backend hostname resolved via Docker network DNS
RUN cat > /etc/nginx/conf.d/default.conf << 'SITE_EOF'
server {
    listen 3000 default_server;
    listen [::]:3000 default_server;
    server_name _;
    root /app/dist;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;

    location /health {
        access_log off;
        return 200 "ok\n";
        add_header Content-Type text/plain;
    }

    location /api/ {
        proxy_pass http://backend:5000/api/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 300s;
        proxy_connect_timeout 10s;
    }

    location /auth/ {
        proxy_pass http://backend:5000/auth/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 300s;
        proxy_connect_timeout 10s;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    location / {
        try_files $uri $uri/ /index.html;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
    }

    location ~ /\. { deny all; }
}
SITE_EOF

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:3000/health || exit 1

CMD ["nginx", "-g", "daemon off;"]
