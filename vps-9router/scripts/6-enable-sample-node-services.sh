#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

DEPLOY_USER="${DEPLOY_USER:-deploy}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR%/scripts}/templates"

install -m 644 "${TEMPLATE_DIR}/api-service-a.service" /etc/systemd/system/api-service-a.service
install -m 644 "${TEMPLATE_DIR}/web-node-b.service" /etc/systemd/system/web-node-b.service

sed -i "s/^User=.*/User=${DEPLOY_USER}/" /etc/systemd/system/api-service-a.service
sed -i "s/^Group=.*/Group=${DEPLOY_USER}/" /etc/systemd/system/api-service-a.service
sed -i "s/^User=.*/User=${DEPLOY_USER}/" /etc/systemd/system/web-node-b.service
sed -i "s/^Group=.*/Group=${DEPLOY_USER}/" /etc/systemd/system/web-node-b.service

systemctl daemon-reload
systemctl enable --now api-service-a || true
systemctl enable --now web-node-b || true

echo "Sample services installed. Ensure app code exists in /opt/apps/api-service-a and /opt/apps/web-node-b."
