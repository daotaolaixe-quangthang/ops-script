#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

DEPLOY_USER="${DEPLOY_USER:-deploy}"
APP_DIR="${APP_DIR:-/opt/apps/9router}"
ENV_FILE="${ENV_FILE:-/etc/9router/9router.env}"
DATA_DIR="${DATA_DIR:-/var/lib/9router}"
GIT_REPO="${GIT_REPO:-https://github.com/decolua/9router.git}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR%/scripts}/templates"

install -d -m 755 -o "$DEPLOY_USER" -g "$DEPLOY_USER" /opt/apps
if [[ ! -d "$APP_DIR/.git" ]]; then
  sudo -u "$DEPLOY_USER" git clone "$GIT_REPO" "$APP_DIR"
else
  sudo -u "$DEPLOY_USER" git -C "$APP_DIR" pull --ff-only
fi

sudo -u "$DEPLOY_USER" bash -lc "
  cd '$APP_DIR'
  if [[ -f package-lock.json ]]; then
    npm ci
  else
    npm install
  fi
  npm run build
"

install -d -m 750 /etc/9router
install -d -m 750 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$DATA_DIR"

if [[ ! -f "$ENV_FILE" ]]; then
  cp "${TEMPLATE_DIR}/9router.env.example" "$ENV_FILE"
fi
chmod 600 "$ENV_FILE"
chown root:root "$ENV_FILE"

install -m 644 "${TEMPLATE_DIR}/9router.service" /etc/systemd/system/9router.service
sed -i "s/^User=.*/User=${DEPLOY_USER}/" /etc/systemd/system/9router.service
sed -i "s/^Group=.*/Group=${DEPLOY_USER}/" /etc/systemd/system/9router.service
sed -i "s|^WorkingDirectory=.*|WorkingDirectory=${APP_DIR}|" /etc/systemd/system/9router.service
systemctl daemon-reload
systemctl enable --now 9router

sleep 2
systemctl --no-pager --full status 9router || true

echo "9router deployment done. Edit $ENV_FILE before production usage."
