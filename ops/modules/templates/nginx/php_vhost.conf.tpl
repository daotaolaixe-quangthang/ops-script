server {
    listen 80;
    listen [::]:80;
    server_name {{DOMAIN}};

    root {{WEBROOT}};
    index index.php index.html;

{{SSL_HTTP_BLOCK}}
    # Deny hidden files
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    location / {
        limit_req  zone=ops_req burst=200 nodelay;
        limit_conn zone=ops_conn 30;
        try_files $uri $uri/ /index.php?$query_string;
    }

    # PHP-FPM handler
    location ~ \.php$ {
        include        snippets/fastcgi-php.conf;
        fastcgi_pass   unix:/run/php/php{{PHP_VERSION}}-fpm.sock;
        fastcgi_param  SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        include        fastcgi_params;

        fastcgi_connect_timeout 60s;
        fastcgi_read_timeout    120s;
    }

    # Static file caching
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff2?)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }

    access_log  /var/log/nginx/{{DOMAIN}}.access.log main_ext;
    error_log   /var/log/nginx/{{DOMAIN}}.error.log;
}

{{SSL_HTTPS_BLOCK}}

