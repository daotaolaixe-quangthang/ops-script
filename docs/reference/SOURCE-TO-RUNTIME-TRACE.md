## OPS Source To Runtime Trace

Muc tieu: map nhanh tu menu/module sang runtime files, service, verify, rollback.

Model chung:

`install/ops-install.sh` -> `ops/bin/ops` -> `core helpers` -> `modules/*` -> runtime files/services -> verify -> rollback

## Runtime truth hien tai

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

### Node.js services and CLIProxyAPI

- **Modules du kien**:
  - `modules/node.sh`
  - `modules/cli-proxy-api.sh`
- **Runtime state - Node apps**:
  - app directories
  - `.env` (0600)
  - PM2 process list and ecosystem config
  - `/etc/ops/apps/*.conf` neu tao state file
- **Runtime state - CLIProxyAPI specific**:
  - `/opt/cli-proxy-api/cli-proxy-api`
  - `/opt/cli-proxy-api/config.yaml`
  - `~/.cli-proxy-api/`
  - `/etc/ops/cli-proxy-api.conf`
  - `/etc/ops/.cli-proxy-api-key`
  - `cli-proxy-api.service`
- **Public path**:
  - Nginx reverse proxy -> localhost:8317 (CLIProxyAPI)
  - Nginx reverse proxy -> localhost:<port> (Node apps)
- **Verify**:
  - `pm2 status`
  - `systemctl is-active cli-proxy-api`
  - `curl -s http://127.0.0.1:8317/v1/models`
  - `ufw status | grep 8317` (must return empty)
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

### Monitoring / logs / AI integration

- **Modules du kien**:
  - `modules/monitoring.sh`
  - `modules/codex-cli.sh`
  - `modules/ai-agent.sh`
- **Runtime state**:
  - `/var/log/ops/ops.log`
  - logrotate rules
  - `/etc/ops/codex-cli.conf` (mode, endpoint, model, version)
  - `/etc/ops/.codex-api-key` (0600: API key)
  - `~/.codex/config.toml` (0600: endpoint + model config)
  - `/etc/ops/claude-code.conf`
  - admin `~/.bashrc` export block cho Claude Code
- **Verify**:
  - quick logs menu
  - service status screen
  - `codex --version`
  - Claude Code version / environment reachability
  - `curl -s http://127.0.0.1:8317/v1/models` (neu Codex dung CLIProxyAPI mode)
- **Rollback**:
  - `disable_codex_auto_env` de xoa export OPENAI_API_KEY khoi ~/.bash_profile
  - go bo Claude Code export block khoi admin `~/.bashrc` neu can
  - `rm ~/.codex/config.toml /etc/ops/.codex-api-key`
  - `npm uninstall -g @openai/codex`


### Notifications / scheduled checks

- **Modules du kien**:
  - `modules/monitoring.sh`
  - `modules/checks.sh`
- **Runtime state**:
  - `/etc/ops/notifications.conf`
  - `/etc/ops/.telegram-bot-token`
  - `/etc/cron.d/ops-checks`
  - `bin/ops-check`
  - `/etc/ops/checks.conf`
  - `/var/log/ops/checks.log`
  - cooldown files `/tmp/ops-alert-<type>-<id>.cooldown`
- **Verify**:
  - test notification
  - scheduler/cron file ton tai va khong duplicate
  - generated check output/logs
- **Rollback**:
  - disable checks
  - remove `/etc/cron.d/ops-checks`
  - xoa cooldown files/config override neu can

### Advanced web controls

- **Modules du kien**:
  - `modules/nginx.sh`
  - `modules/php.sh`
- **Runtime state**:
  - `/etc/nginx/snippets/cloudflare-real-ip.conf`
  - `/etc/nginx/snippets/custom-powered-by.conf`
  - Nginx site configs co `include` snippet neu bat
  - `.htaccess` backup files neu chay reset
- **Verify**:
  - `nginx -t`
  - header/log/request behavior tests
  - default deny van chan direct `http://IP`
- **Rollback**:
  - revert snippets/config backups
  - restore `.htaccess` backup neu da reset


## Fast trace by artefact

| Runtime artefact | Thuong quay nguoc ve dau |
|---|---|
| `/etc/ops/ops.conf` | installer, `ops-setup.sh`, global architecture |
| `~/.bash_profile` (login hook) | dashboard/login flow, security/user experience |
| `/etc/nginx/sites-available/*` | Domains & Nginx, SSL |
| PM2 app state | Node.js Services |
| `cli-proxy-api.service` | CLIProxyAPI provider lifecycle |
| `/opt/cli-proxy-api/config.yaml` | provider config rendered by `modules/cli-proxy-api.sh` |
| `/etc/ops/.cli-proxy-api-key` | local client key for CLIProxyAPI (0600) |
| `/etc/ops/.db-root-password` | database.sh install (0600) |
| `/etc/ops/.codex-api-key` | codex-cli.sh configure (0600) |
| `~/.codex/config.toml` | codex-cli.sh configure (0600) |
| `/etc/php/*/fpm/*` | PHP management |
| **MariaDB** config (default) | Database management |
| UFW/fail2ban/sshd config | Security module |
| `/var/log/ops/ops.log` | monitoring/audit flow |


## Rule

Neu docs va runtime mau thuan nhau tren VPS that, runtime la uu tien so 1.
