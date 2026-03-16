#!/usr/bin/env bash
set -euo pipefail

AI_DOMAIN="${AI_DOMAIN:-router.example.com}"

echo "== systemd services =="
systemctl is-active nginx
systemctl is-active 9router || true

echo "== local listeners =="
ss -lntp | grep -E ':80|:443|:20128|:3001|:3002' || true

echo "== local 9router check =="
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' http://127.0.0.1:20128/dashboard || true

echo "== nginx host route check =="
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' -H "Host: ${AI_DOMAIN}" http://127.0.0.1/ || true

echo "== firewall =="
ufw status verbose || true

echo "Manual checks still required:"
echo "1) External access to :20128 must fail"
echo "2) Cloudflare Access must block unauthenticated browser"
