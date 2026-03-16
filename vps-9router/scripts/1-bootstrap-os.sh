#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

SSH_PORT="${SSH_PORT:-22}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
DEPLOY_PUBKEY="${DEPLOY_PUBKEY:-}"

export DEBIAN_FRONTEND=noninteractive
apt update
apt -y upgrade
apt -y install nginx ufw fail2ban git curl ca-certificates gnupg unzip software-properties-common

if ! id -u "$DEPLOY_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$DEPLOY_USER"
fi
usermod -aG sudo "$DEPLOY_USER"

install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
if [[ -n "$DEPLOY_PUBKEY" ]]; then
  AUTH_KEYS="/home/$DEPLOY_USER/.ssh/authorized_keys"
  touch "$AUTH_KEYS"
  chmod 600 "$AUTH_KEYS"
  chown "$DEPLOY_USER:$DEPLOY_USER" "$AUTH_KEYS"
  if ! grep -Fq "$DEPLOY_PUBKEY" "$AUTH_KEYS"; then
    printf '%s\n' "$DEPLOY_PUBKEY" >> "$AUTH_KEYS"
  fi
fi

SSHD_CFG="/etc/ssh/sshd_config"
cp "$SSHD_CFG" "${SSHD_CFG}.bak.$(date +%Y%m%d%H%M%S)"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CFG"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CFG"
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CFG"
if grep -q '^#\?Port ' "$SSHD_CFG"; then
  sed -i "s/^#\?Port .*/Port ${SSH_PORT}/" "$SSHD_CFG"
else
  printf '\nPort %s\n' "$SSH_PORT" >> "$SSHD_CFG"
fi
systemctl restart ssh

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

systemctl enable --now fail2ban

echo "Bootstrap done. Verify SSH access before closing your current session."
