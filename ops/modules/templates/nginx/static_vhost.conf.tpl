server {
    listen 80;
    listen [::]:80;
    server_name {{DOMAIN}};

    root  {{WEBROOT}};
    index index.html index.htm;

{{SSL_HTTP_BLOCK}}
    # Strict static: no PHP, no proxy
    location / {
        limit_req  zone=ops_req burst=200 nodelay;
        limit_conn zone=ops_conn 30;
        try_files $uri $uri/ =404;
    }

    # Static asset caching
    location ~* \.(jpg|jpeg|png|gif|ico|svg|css|js|woff2?|ttf|eot)$ {
        expires     30d;
        add_header  Cache-Control "public, immutable";
        access_log  off;
    }

    # Deny hidden files and sensitive paths
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    location ~ \.(env|log|sh|conf)$ {
        deny all;
    }

    access_log  /var/log/nginx/{{DOMAIN}}.access.log main_ext;
    error_log   /var/log/nginx/{{DOMAIN}}.error.log;
}

{{SSL_HTTPS_BLOCK}}
