# default-deny.conf.tpl
# Default server block — denies all requests that don't match a known vhost.
# Deploy to: /etc/nginx/sites-available/00-default-deny
# Enable:    ln -s .../00-default-deny /etc/nginx/sites-enabled/

server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name _;

    # Return 444 (connection closed without response) for unknown hosts
    return 444;

    access_log off;
    error_log  /var/log/nginx/default-deny.error.log;
}

server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;

    server_name _;

    # Self-signed cert required to avoid nginx startup failure.
    # OPS generates this during setup.
    ssl_certificate     {{SELF_SIGNED_CERT}};
    ssl_certificate_key {{SELF_SIGNED_KEY}};

    return 444;

    access_log off;
}
