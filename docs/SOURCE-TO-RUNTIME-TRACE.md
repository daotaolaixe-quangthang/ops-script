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
- **Runtime state**:
  - app directories
  - `.env`
  - PM2 process list and ecosystem config
  - `/etc/ops/apps/*.conf` neu tao state file
- **Public path**:
  - Nginx reverse proxy -> localhost app
- **Verify**:
  - process manager status
  - localhost health endpoint
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
  - `/etc/ops/codex-cli.conf`
- **Verify**:
  - quick logs menu
  - service status screen
  - Codex CLI test
- **Rollback**:
  - revert config/hook and disable integration if broken

## Fast trace by artefact

| Runtime artefact | Thuong quay nguoc ve dau |
|---|---|
| `/etc/ops/ops.conf` | installer, `ops-setup.sh`, global architecture |
| shell rc hook | dashboard/login flow, security/user experience |
| `/etc/nginx/sites-available/*` | Domains & Nginx, SSL |
| PM2 app state | Node.js Services, 9router |
| `/etc/php/*/fpm/*` | PHP management |
| MySQL/MariaDB config | Database management |
| UFW/fail2ban/sshd config | Security module |
| `/var/log/ops/ops.log` | monitoring/audit flow |

## Rule

Neu docs va runtime mau thuan nhau tren VPS that, runtime la uu tien so 1.
