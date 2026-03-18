# ssl_snippet.tpl
# Include this snippet inside SSL server blocks.
# Managed by OPS — do not edit manually.
# Deploy to: /etc/nginx/snippets/ops-ssl.conf
#
# Certbot will auto-manage the certificate paths below.

ssl_certificate     {{SSL_CERT_PATH}};
ssl_certificate_key {{SSL_KEY_PATH}};

ssl_protocols       TLSv1.2 TLSv1.3;
ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
ssl_prefer_server_ciphers off;

ssl_session_timeout 1d;
ssl_session_cache   shared:MozSSL:10m;
ssl_session_tickets off;

# HSTS (uncomment after verifying HTTPS works)
# add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

# OCSP Stapling
ssl_stapling        on;
ssl_stapling_verify on;
resolver 8.8.8.8 8.8.4.4 valid=300s;
resolver_timeout    5s;
