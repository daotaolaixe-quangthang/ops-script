#!/usr/bin/env bash
# ops-log-rotation.sh — Apply all OPS log rotation optimizations
# Run as root. Idempotent.
set -euo pipefail

echo "[1/6] logrotate: /var/log/ops/ops.log"
cat > /etc/logrotate.d/ops-log << 'EOF'
/var/log/ops/ops.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    maxsize 50M
}
EOF

echo "[2/6] logrotate: nginx (fix signal + add maxsize)"
cat > /etc/logrotate.d/nginx-ops << 'EOF'
/var/log/nginx/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    maxsize 100M
    sharedscripts
    postrotate
        if [ -f /run/nginx.pid ] && kill -0 $(cat /run/nginx.pid) 2>/dev/null; then
            nginx -s reopen
        fi
    endscript
}
EOF

echo "[3/6] logrotate: ufw.log — daily instead of weekly"
cat > /etc/logrotate.d/ufw << 'EOF'
/var/log/ufw.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    maxsize 20M
    sharedscripts
    postrotate
        [ -x /usr/lib/rsyslog/rsyslog-rotate ] && /usr/lib/rsyslog/rsyslog-rotate || true
    endscript
}
EOF

echo "[4/6] logrotate: rsyslog — daily + maxsize guard"
cat > /etc/logrotate.d/rsyslog << 'EOF'
/var/log/syslog
/var/log/kern.log
/var/log/auth.log
/var/log/mail.info
/var/log/mail.warn
/var/log/mail.err
/var/log/mail.log
/var/log/daemon.log
/var/log/user.log
/var/log/lpr.log
/var/log/cron.log
/var/log/debug
/var/log/messages
{
    daily
    rotate 7
    maxsize 50M
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate
    endscript
}
EOF

echo "[5/6] journald: cap SystemMaxUse=100M and keep max 7 days"
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/ops-limits.conf << 'EOF'
[Journal]
# OPS: cap journal disk usage
SystemMaxUse=100M
SystemKeepFree=500M
MaxRetentionSec=7day
MaxFileSec=1day
EOF
systemctl restart systemd-journald
journalctl --disk-usage

echo "[6/6] Clean accumulated sshd backup files in sshd_config.d/"
removed=0
for f in /etc/ssh/sshd_config.d/*; do
    bname=$(basename "$f")
    [[ "$bname" == "99-ops-hardening.conf" ]] && continue
    [[ "$bname" == "50-cloud-init.conf" ]] && continue
    [[ "$bname" == "60-cloudimg-settings.conf" ]] && continue
    [[ "$bname" == *".bak."* ]] && rm -f "$f" && echo "  Removed: $bname" && ((removed++)) || true
done
echo "  Removed ${removed} backup files from sshd_config.d/"
sshd -t && echo "  sshd config OK" || echo "  WARNING: sshd -t failed after cleanup"

echo ""
echo "=== Verifying logrotate syntax ==="
logrotate -d /etc/logrotate.d/ops-log 2>&1 | grep -E 'error|warning' | head -5 || true
logrotate -d /etc/logrotate.d/nginx-ops 2>&1 | grep -E 'error|warning' | head -5 || true
logrotate -d /etc/logrotate.d/ufw 2>&1 | grep -E 'error|warning' | head -5 || true

echo ""
echo "ALL DONE. Run 'logrotate -f /etc/logrotate.conf' to force rotate now."
