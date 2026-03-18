server {
    listen 80;
    server_name {{DOMAIN}};

    # 9router: SSE proxy with rate limiting
    # SSE connections are long-lived — extended timeouts required.

    # Rate limiting zone must be defined in nginx.conf/http block:
    #   limit_req_zone $binary_remote_addr zone=nine_router_api:10m rate=30r/m;

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

        # SSE / long-poll support
        proxy_buffering    off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    # API endpoints: rate-limited
    location /api/ {
        limit_req        zone=nine_router_api burst=20 nodelay;
        limit_req_status 429;

        proxy_pass       http://127.0.0.1:{{NINE_ROUTER_PORT}};
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location ~ /\. {
        deny all;
    }

    access_log /var/log/nginx/nine-router.access.log;
    error_log  /var/log/nginx/nine-router.error.log;
}
