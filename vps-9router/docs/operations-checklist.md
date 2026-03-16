# Operations Checklist

## Daily
1. Check service state: `systemctl is-active nginx 9router`.
2. Check restart loops: `systemctl status 9router --no-pager`.
3. Check disk/RAM pressure.

## Weekly
1. Security updates: `apt update && apt -y upgrade`.
2. Review fail2ban status: `fail2ban-client status`.
3. Review nginx 4xx/5xx logs.

## Backup
1. Backup paths:
   - `/var/lib/9router`
   - `/etc/9router/9router.env` (encrypted)
   - `/etc/nginx/sites-available`
   - `/etc/systemd/system/*.service`
2. Validate restore monthly.

## Upgrade 9router
1. `sudo bash ops/vps-9router/scripts/3-deploy-9router-native.sh`
2. Verify health endpoint and dashboard.
3. Rollback with previous git revision if needed.
