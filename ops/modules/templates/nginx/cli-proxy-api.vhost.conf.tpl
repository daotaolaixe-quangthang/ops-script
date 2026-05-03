# /etc/nginx/sites-available/cli-proxy-api.{{DOMAIN}}
# Managed by OPS - do not edit manually.

server {
    listen 80;
    listen [::]:80;
    server_name {{DOMAIN}};

    access_log /var/log/nginx/cli-proxy-api.access.log;
    error_log  /var/log/nginx/cli-proxy-api.error.log;

    add_header Content-Security-Policy "default-src 'self'; frame-ancestors 'none'" always;
    add_header Permissions-Policy        "geolocation=(), microphone=(), camera=(), payment=(), usb=()" always;
    add_header X-XSS-Protection          "1; mode=block" always;
    add_header Referrer-Policy           "strict-origin-when-cross-origin" always;
    add_header X-Content-Type-Options    "nosniff" always;
    add_header X-Frame-Options           "SAMEORIGIN" always;

{{SSL_HTTP_BLOCK}}
    location / {
        proxy_pass         http://127.0.0.1:{{CLIPROXYAPI_PORT}};
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
