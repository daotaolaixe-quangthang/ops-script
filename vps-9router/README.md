# 9router VPS Implementation Kit (Ubuntu 24.04 + systemd + Nginx + Cloudflare Access)

This kit implements the agreed architecture:
- `9router` runs locally on `127.0.0.1:20128` via `systemd`.
- Nginx is the only public entrypoint (`80/443`).
- `router.<your-domain>` is protected by Cloudflare Access.
- Other Node/PHP services can run simultaneously on the same VPS.

## Folder layout
- `scripts/1-bootstrap-os.sh`: base OS hardening.
- `scripts/2-install-runtime.sh`: Node.js 20 + optional PHP-FPM.
- `scripts/3-deploy-9router-native.sh`: clone/build/start 9router.
- `scripts/4-configure-nginx-sites.sh`: configure Nginx virtual hosts.
- `scripts/5-verify-stack.sh`: post-deploy checks.
- `scripts/6-enable-sample-node-services.sh`: install sample systemd units for Node services.
- `templates/`: env, systemd, nginx templates.
- `docs/cloudflare-access-checklist.md`: Cloudflare Access configuration.
- `docs/operations-checklist.md`: backup/update/ops routine.

## Preconditions
1. Fresh VPS with Ubuntu 24.04.
2. You have sudo/root.
3. Domain is managed in Cloudflare.

## Step-by-step install
1. Copy this folder to VPS (or clone the repo).
2. Run base hardening:
```bash
sudo SSH_PORT=22 DEPLOY_USER=deploy DEPLOY_PUBKEY='ssh-ed25519 AAAA... your-key' \
  bash ops/vps-9router/scripts/1-bootstrap-os.sh
```
3. Install runtime:
```bash
sudo INSTALL_PHP=true PHP_VERSION=8.3 \
  bash ops/vps-9router/scripts/2-install-runtime.sh
```
4. Deploy 9router:
```bash
sudo DEPLOY_USER=deploy APP_DIR=/opt/apps/9router \
  bash ops/vps-9router/scripts/3-deploy-9router-native.sh
```
5. Edit secrets:
```bash
sudo nano /etc/9router/9router.env
sudo systemctl restart 9router
```
Generate secrets with:
```bash
openssl rand -hex 32
```
6. Configure Nginx routes:
```bash
sudo AI_DOMAIN=router.yourdomain.com API_DOMAIN=api.yourdomain.com WEB_DOMAIN=www.yourdomain.com \
  PHP_DOMAIN=php.yourdomain.com PHP_VERSION=8.3 \
  bash ops/vps-9router/scripts/4-configure-nginx-sites.sh
```
Optional: enable sample Node services:
```bash
sudo DEPLOY_USER=deploy bash ops/vps-9router/scripts/6-enable-sample-node-services.sh
```
7. Configure TLS certs (Let's Encrypt or Cloudflare Origin cert).
8. Configure Cloudflare Access for `router.yourdomain.com`:
- Follow `docs/cloudflare-access-checklist.md`.
9. Verify deployment:
```bash
sudo AI_DOMAIN=router.yourdomain.com bash ops/vps-9router/scripts/5-verify-stack.sh
```

## Important security defaults
1. `20128` must not be opened in firewall.
2. Keep `REQUIRE_API_KEY=true`.
3. Keep backend services bound to loopback only.
4. Do not expose `dashboard` on any public subdomain except protected `router.<domain>`.

## Running other services on same VPS
1. Node API example port: `127.0.0.1:3001` + `templates/api-service-a.service`.
2. Node web example port: `127.0.0.1:3002` + `templates/web-node-b.service`.
3. PHP site example via `/run/php/php8.3-fpm.sock` + `templates/nginx/php-site.conf`.

## Notes
- This kit does not auto-configure Cloudflare APIs.
- This kit assumes your app-specific build/start commands are valid.
