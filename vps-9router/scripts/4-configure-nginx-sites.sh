#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

AI_DOMAIN="${AI_DOMAIN:-router.example.com}"
API_DOMAIN="${API_DOMAIN:-api.example.com}"
WEB_DOMAIN="${WEB_DOMAIN:-www.example.com}"
PHP_DOMAIN="${PHP_DOMAIN:-php.example.com}"
PHP_VERSION="${PHP_VERSION:-8.3}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR%/scripts}/templates/nginx"

install -m 644 "${TEMPLATE_DIR}/default-deny.conf" /etc/nginx/sites-available/000-default-deny
install -m 644 "${TEMPLATE_DIR}/9router.conf" /etc/nginx/sites-available/9router
install -m 644 "${TEMPLATE_DIR}/node-api.conf" /etc/nginx/sites-available/node-api
install -m 644 "${TEMPLATE_DIR}/node-web.conf" /etc/nginx/sites-available/node-web
install -m 644 "${TEMPLATE_DIR}/php-site.conf" /etc/nginx/sites-available/php-site

sed -i "s/__AI_DOMAIN__/${AI_DOMAIN}/g" /etc/nginx/sites-available/9router
sed -i "s/__API_DOMAIN__/${API_DOMAIN}/g" /etc/nginx/sites-available/node-api
sed -i "s/__WEB_DOMAIN__/${WEB_DOMAIN}/g" /etc/nginx/sites-available/node-web
sed -i "s/__PHP_DOMAIN__/${PHP_DOMAIN}/g" /etc/nginx/sites-available/php-site
sed -i "s/__PHP_VERSION__/${PHP_VERSION}/g" /etc/nginx/sites-available/php-site

ln -sf /etc/nginx/sites-available/000-default-deny /etc/nginx/sites-enabled/000-default-deny
ln -sf /etc/nginx/sites-available/9router /etc/nginx/sites-enabled/9router
ln -sf /etc/nginx/sites-available/node-api /etc/nginx/sites-enabled/node-api
ln -sf /etc/nginx/sites-available/node-web /etc/nginx/sites-enabled/node-web
ln -sf /etc/nginx/sites-available/php-site /etc/nginx/sites-enabled/php-site

rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx

echo "Nginx configuration done. Configure TLS certs (Let's Encrypt or Cloudflare origin cert) next."
