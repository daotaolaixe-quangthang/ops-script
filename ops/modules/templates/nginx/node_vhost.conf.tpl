server {
    listen 80;
    server_name {{DOMAIN}};

    # Redirect all HTTP to HTTPS (uncomment after SSL is issued)
    # return 301 https://$host$request_uri;

    location / {
        proxy_pass         http://127.0.0.1:{{PORT}};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade $http_upgrade;
        proxy_set_header   Connection 'upgrade';
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;

        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout    60s;
        proxy_read_timeout    60s;
    }

    # Deny hidden files
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}

# HTTPS block (managed by Certbot / ops ssl module)
# Uncomment and adjust after certificate is issued.
# server {
#     listen 443 ssl http2;
#     server_name {{DOMAIN}};
#
#     include /etc/nginx/snippets/ops-ssl.conf;
#
#     location / {
#         proxy_pass         http://127.0.0.1:{{PORT}};
#         proxy_http_version 1.1;
#         proxy_set_header   Upgrade $http_upgrade;
#         proxy_set_header   Connection 'upgrade';
#         proxy_set_header   Host $host;
#         proxy_set_header   X-Real-IP $remote_addr;
#         proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
#         proxy_set_header   X-Forwarded-Proto $scheme;
#         proxy_cache_bypass $http_upgrade;
#     }
# }
