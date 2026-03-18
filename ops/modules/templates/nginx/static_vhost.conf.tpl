server {
    listen 80;
    server_name {{DOMAIN}};

    root  {{WEBROOT}};
    index index.html index.htm;

    # Strict static: no PHP, no proxy
    location / {
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

    access_log  /var/log/nginx/{{DOMAIN}}.access.log;
    error_log   /var/log/nginx/{{DOMAIN}}.error.log;
}
