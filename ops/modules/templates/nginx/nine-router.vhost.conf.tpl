# /etc/nginx/sites-available/nine-router.{{DOMAIN}}
# Managed by OPS - do not edit manually.
# Rate limiting is handled by Cloudflare at the edge.

server {
    listen 80;
    server_name {{DOMAIN}};

    access_log /var/log/nginx/nine-router.access.log;
    error_log  /var/log/nginx/nine-router.error.log;

    # ── Security headers (vhost-level override) ──────────────────────────────
    # NOTE: When add_header is used in a server{} block in Nginx, headers from
    # the parent http{} block are NOT inherited. We must re-declare all security
    # headers here + relax style-src / font-src for Google Fonts used by the
    # 9router dashboard UI.
    # S3-1 fix: HSTS is NOT set here (plain-HTTP server block). Per RFC 6797
    # §7.2 browsers ignore HSTS headers sent over HTTP. HSTS is emitted only
    # by the SSL server block generated at vhost-render time (listen 443).
    add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' https:; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; img-src 'self' data: https:; font-src 'self' data: https://fonts.gstatic.com; connect-src 'self' https:; frame-ancestors 'none'" always;
    add_header Permissions-Policy        "geolocation=(), microphone=(), camera=(), payment=(), usb=()" always;
    add_header X-XSS-Protection          "1; mode=block" always;
    add_header Referrer-Policy           "strict-origin-when-cross-origin" always;
    add_header X-Content-Type-Options    "nosniff" always;
    add_header X-Frame-Options           "SAMEORIGIN" always;

{{SSL_HTTP_BLOCK}}
    location / {
        proxy_pass         http://127.0.0.1:{{NINE_ROUTER_PORT}};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade $http_upgrade;
        proxy_set_header   Connection 'upgrade';
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;

        proxy_connect_timeout 10s;
        proxy_read_timeout    120s;
        proxy_send_timeout    60s;
        proxy_buffering       off;
    }
}

{{SSL_HTTPS_BLOCK}}
