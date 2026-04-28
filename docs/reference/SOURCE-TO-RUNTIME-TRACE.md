## OPS Source To Runtime Trace

Muc tieu: map nhanh tu menu/module sang runtime files, service, verify, rollback.

Model chung:

`installer/bin/ops` -> `core helpers` -> `modules/*` -> runtime files/services -> verify -> rollback

## Runtime truth du kien

- Core install: `/opt/ops`
- Config: `/etc/ops/*`
- Logs: `/var/log/ops/*`
- Public proxy: `/etc/nginx/*`
- Node apps: app dirs + PM2 state
- PHP: `/etc/php/*`, PHP-FPM pools, Nginx fastcgi wiring
- DB: MySQL/MariaDB config + users + data

## Trace theo cum chuc nang

### Installer / first-run

- **Entrypoints**:
  - `install/ops-install.sh`
  - `bin/ops-setup.sh`
  - `bin/ops-dashboard`
- **Runtime state**:
  - `/opt/ops`
  - `/usr/local/bin/ops`
  - `/usr/local/bin/ops-dashboard`
  - `/etc/ops/ops.conf`
  - login shell rc hooks
- **Verify**:
  - symlink dung
  - dashboard hien sau login
- **Rollback**:
  - remove symlink/hook, rerun setup

### Main menu / module dispatch

- **Entrypoint**:
  - `bin/ops`
- **Source lien quan**:
  - `core/ui.sh`
  - `modules/*.sh`
- **Runtime state**:
  - khong nhat thiet co state rieng; day la control plane
- **Verify**:
  - menu labels dung spec
  - vao dung module/action
- **Rollback**:
  - revert menu mapping

### Node.js services

- **Modules du kien**:
  - `modules/node.sh`
  - `modules/nine-router.sh`
- **Runtime state — Node apps**:
  - app directories
  - `.env` (0600)
  - PM2 process list and ecosystem config
  - `/etc/ops/apps/*.conf` neu tao state file
- **Runtime state — 9router specific**:
  - `/opt/9router/` (source + build)
  - `/opt/9router/.env` (0600: JWT_SECRET, INITIAL_PASSWORD, API keys)
  - `/var/lib/9router/db.json` (providers, combos, API keys)
  - `/etc/ops/nine-router.conf` (OPS state: installed, domain, ssl flag)
  - `/etc/ops/.nine-router-password` (0600: dashboard password)
  - `~/.9router/usage.json` (usage stats)
  - `/var/log/ops/nine-router.{out,err}.log`
- **Public path**:
  - Nginx reverse proxy -> localhost:20128 (9router)
  - Nginx reverse proxy -> localhost:<port> (Node apps)
- **Verify**:
  - `pm2 status`
  - `curl -s http://127.0.0.1:20128/v1/models` (9router)
  - `ufw status | grep 20128` (must return empty)
  - domain proxy request
- **Rollback**:
  - revert ecosystem/service config, rollback Nginx target


### Domains & Nginx

- **Modules du kien**:
  - `modules/nginx.sh`
- **Runtime state**:
  - `/etc/nginx/nginx.conf`
  - `/etc/nginx/sites-available/*`
  - `/etc/nginx/sites-enabled/*`
  - `/etc/ops/domains/*.conf` neu co domain manifest
- **Verify**:
  - `nginx -t`
  - `systemctl reload nginx`
  - `curl -I`
- **Rollback**:
  - disable/revert site config, reload Nginx

### SSL

- **Modules du kien**:
  - `modules/nginx.sh` hoac module SSL tach rieng trong tuong lai
- **Runtime state**:
  - certbot config
  - live cert paths
  - Nginx ssl config snippets
- **Verify**:
  - cert expiry/status
  - HTTPS request
- **Rollback**:
  - revert Nginx SSL wiring, tra lai cert path cu

### PHP / PHP-FPM

- **Modules du kien**:
  - `modules/php.sh`
- **Runtime state**:
  - `/etc/php/<ver>/fpm/php.ini`
  - `/etc/php/<ver>/fpm/pool.d/*.conf`
  - PHP CLI alternatives
  - Nginx fastcgi mapping
- **Verify**:
  - `php -v`
  - `php-fpm` service status
  - phpinfo/test request
- **Rollback**:
  - revert pool/php.ini/config version wiring

### Database

- **Modules du kien**:
  - `modules/database.sh`
- **Runtime state**:
  - DB service config
  - DB/users
  - `/etc/ops/database.conf` neu co global config
- **Verify**:
  - login DB
  - service status
  - app ket noi duoc
- **Rollback**:
  - revert config/tuning, remove wrong users/dbs, restart DB

### Security / SSH / firewall

- **Modules du kien**:
  - `modules/security.sh`
- **Runtime state**:
  - `/etc/ssh/sshd_config`
  - UFW rules
  - `/etc/fail2ban/*`
  - shell rc hooks cho dashboard/admin experience
- **Verify**:
  - `sshd -t`
  - current firewall rules
  - fail2ban status
- **Rollback**:
  - mo duong SSH truoc, revert security rules sau

### Monitoring / logs / Codex CLI

- **Modules du kien**:
  - `modules/monitoring.sh`
  - `modules/codex-cli.sh`
- **Runtime state**:
  - `/var/log/ops/ops.log`
  - logrotate rules
  - `/etc/ops/codex-cli.conf` (mode, endpoint, model, version)
  - `/etc/ops/.codex-api-key` (0600: API key)
  - `~/.codex/config.toml` (0600: endpoint + model config)
- **Verify**:
  - quick logs menu
  - service status screen
  - `codex --version`
  - `curl -s http://127.0.0.1:20128/v1/models` (neu dung 9router mode)
- **Rollback**:
  - `disable_codex_auto_env` de xoa export OPENAI_API_KEY khoi ~/.bash_profile
  - `rm ~/.codex/config.toml /etc/ops/.codex-api-key`
  - `npm uninstall -g @openai/codex`


### Notifications / scheduled checks (future optional)

- **Modules du kien**:
  - notification/check module hoac expansion trong `modules/monitoring.sh`
- **Runtime state**:
  - `/etc/ops/notifications.conf`
  - `/etc/ops/checks/*`
  - scheduler artefacts
- **Verify**:
  - test notification
  - scheduler state
  - generated check output/logs
- **Rollback**:
  - disable checks
  - remove scheduler entries

### Advanced web controls (future optional)

- **Modules du kien**:
  - `modules/nginx.sh` hoac module web-control tach rieng
- **Runtime state**:
  - Nginx snippets/site config
  - PHP-secondary `.htaccess` file neu co
- **Verify**:
  - `nginx -t`
  - header/log/request behavior tests
- **Rollback**:
  - revert snippets/config backups

### Remote uploads backup transport (future optional)

- **Modules du kien**:
  - backup remote module trong Phase 4
- **Runtime state**:
  - `/etc/ops/backups/telegram.conf`
  - `/etc/ops/backups/uploads/*`
  - local staging and metadata files
  - scheduler artefacts neu auto backup duoc bat
- **Verify**:
  - upload/download flow
  - metadata state
- **Rollback**:
  - disable schedule
  - remove local config/meta moi

## Fast trace by artefact

| Runtime artefact | Thuong quay nguoc ve dau |
|---|---|
| `/etc/ops/ops.conf` | installer, `ops-setup.sh`, global architecture |
| `~/.bash_profile` (login hook) | dashboard/login flow, security/user experience |
| `/etc/nginx/sites-available/*` | Domains & Nginx, SSL |
| PM2 app state | Node.js Services, 9router (`nine-router`) |
| `/opt/9router/.env` | nine-router.sh install flow |
| `/var/lib/9router/db.json` | 9router dashboard state |
| `/etc/ops/.nine-router-password` | nine-router.sh install (0600) |
| `/etc/ops/.db-root-password` | database.sh install (0600) |
| `/etc/ops/.codex-api-key` | codex-cli.sh configure (0600) |
| `~/.codex/config.toml` | codex-cli.sh configure (0600) |
| `/etc/php/*/fpm/*` | PHP management |
| **MariaDB** config (default) | Database management |
| UFW/fail2ban/sshd config | Security module |
| `/var/log/ops/ops.log` | monitoring/audit flow |


## Rule

Neu docs va runtime mau thuan nhau tren VPS that, runtime la uu tien so 1.
