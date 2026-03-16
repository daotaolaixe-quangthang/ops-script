#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

INSTALL_PHP="${INSTALL_PHP:-true}"
PHP_VERSION="${PHP_VERSION:-8.3}"

curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt -y install nodejs build-essential

node -v
npm -v

if [[ "$INSTALL_PHP" == "true" ]]; then
  add-apt-repository -y ppa:ondrej/php
  apt update
  apt -y install \
    "php${PHP_VERSION}-fpm" \
    "php${PHP_VERSION}-cli" \
    "php${PHP_VERSION}-mbstring" \
    "php${PHP_VERSION}-xml" \
    "php${PHP_VERSION}-curl" \
    "php${PHP_VERSION}-zip" \
    "php${PHP_VERSION}-mysql" \
    "php${PHP_VERSION}-intl" \
    "php${PHP_VERSION}-opcache"
fi

install -d -m 755 /opt/apps
install -d -m 755 /opt/apps/api-service-a
install -d -m 755 /opt/apps/web-node-b
install -d -m 755 /var/www/php-site-c

echo "Runtime installation done."
