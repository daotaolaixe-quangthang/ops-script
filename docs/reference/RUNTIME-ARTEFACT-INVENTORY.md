## OPS Runtime Artefact Inventory

Muc tieu: liet ke cac runtime artefacts ma OPS tao/quan ly de debug, verify, va rollback nhanh.

Luu y: day la inventory cho feature hien tai cua stable line; neu runtime tao them artefact moi thi cap nhat file nay cung luc.

## 1. Core and global state

| Artefact | Muc dich |
|---|---|
| `/opt/ops` | core install path |
| `/usr/local/bin/ops` | main entrypoint symlink |
| `/usr/local/bin/ops-dashboard` | dashboard symlink |
| `/etc/ops/ops.conf` | global config |
| `/etc/ops/capacity.conf` | VPS capacity profile (shell-sourceable key=value) |
| `/var/log/ops/ops.log` | high-level operations log |
| `/etc/logrotate.d/ops` | OPS core log rotation |
| `/etc/ops/notifications.conf` | global notification channels and policy |

## 2. Login and operator access

| Artefact | Muc dich |
|---|---|
| shell rc hook for admin user | auto run dashboard on interactive login |
| `/etc/ssh/sshd_config` | SSH port and admin access policy |
| sudo user config | non-root daily admin path |

## 3. Node and CLIProxyAPI

Node services follow the PM2 contract. CLIProxyAPI is a separate systemd-managed provider service.

**Node apps:**

| Artefact | Path | Muc dich |
|---|---|---|
| app dir | app-specific | Node source/build/runtime files |
| `.env` files | app-specific | app secrets and runtime env (0600) |
| PM2 process list | PM2 daemon state | process supervision |
| PM2 ecosystem config | `<app>/ecosystem.config.js` | declarative process config neu dung |
| PM2 app logs | `/var/log/ops/pm2-<app>-out.log`, `/var/log/ops/pm2-<app>-err.log` | stdout/stderr logs, runtime-user owned |
| `/etc/ops/apps/<app>.conf` | `/etc/ops/apps/<app>.conf` | app source of truth neu OPS tao |

**CLIProxyAPI specific:**

| Artefact | Path | Muc dich |
|---|---|---|
| Binary | `/opt/cli-proxy-api/cli-proxy-api` | Provider service executable |
| Config | `/opt/cli-proxy-api/config.yaml` | Runtime config |
| Auth dir | `~/.cli-proxy-api/` | Provider auth state |
| Logs dir | `/opt/cli-proxy-api/logs` | file logging dir khi request logging duoc bat |
| systemd service | `cli-proxy-api.service` | Service supervision |
| OPS state | `/etc/ops/cli-proxy-api.conf` | OPS-level metadata (0640) |
| Local API key | `/etc/ops/.cli-proxy-api-key` | Local client key when API key mode is enabled |
| Nginx vhost | `/etc/nginx/sites-available/cli-proxy-api.*` | Public routing |

## 4. Nginx and domains

| Artefact | Muc dich |
|---|---|
| `/etc/nginx/nginx.conf` | global Nginx config |
| `/etc/nginx/sites-available/*` | per-domain configs |
| `/etc/nginx/sites-enabled/*` | enabled site links |
| `/etc/nginx/sites-available/00-default-deny` | default deny vhost for unknown hosts |
| `/etc/logrotate.d/nginx-ops` | OPS-managed Nginx per-domain log rotation |
| `/etc/ops/domains/<domain>.conf` | domain mapping source of truth neu OPS tao |

## 5. SSL

| Artefact | Path | Muc dich |
|---|---|---|
| certbot config and renewal state | certbot-managed | ACME lifecycle |
| live cert paths | cert-specific | active cert/key material |
| Default deny self-signed cert | `/etc/nginx/ssl/ops-default.crt` | fallback cert cho default deny 443 vhost |
| Default deny self-signed key | `/etc/nginx/ssl/ops-default.key` | fallback key cho default deny 443 vhost |
| Nginx SSL snippets | Nginx-managed | TLS wiring |

## 5.1 Scheduled checks and notifications

| Artefact | Path | Source module | Verify | Permission |
|---|---|---|---|---|
| Cron file | `/etc/cron.d/ops-checks` | `modules/checks.sh` — `checks_install_cron` | `cat /etc/cron.d/ops-checks` | 0644 |
| Check dispatcher | `bin/ops-check` | `modules/checks.sh` — `_checks_write_dispatcher` | `bash -n bin/ops-check` | 0755 |
| Alert cooldown | `/tmp/ops-alert-<type>-<id>.cooldown` | runtime (per check run) | `ls /tmp/ops-alert-*` | 0644 |
| Check log | `/var/log/ops/checks.log` | cron redirect | `tail /var/log/ops/checks.log` | 0644 |
| Checks config override | `/etc/ops/checks.conf` | operator-created (optional) | `cat /etc/ops/checks.conf` | 0600 |
| Telegram token | `/etc/ops/.telegram-bot-token` | `modules/monitoring.sh` | exists + 0600 | 0600 |
| Telegram config | `/etc/ops/notifications.conf` (TELEGRAM_ENABLED, TELEGRAM_CHAT_ID) | `modules/monitoring.sh` | `grep TELEGRAM /etc/ops/notifications.conf` | 0640 |

**Rollback:** `checks_remove_cron` removes `/etc/cron.d/ops-checks`; delete cooldown files manually if needed.

## 6. PHP

| Artefact | Muc dich |
|---|---|
| `/etc/php/<ver>/fpm/php.ini` | PHP runtime config |
| `/etc/php/<ver>/fpm/pool.d/*.conf` | per-pool config |
| PHP CLI alternatives | default CLI version |
| `/etc/ops/php-sites/<site>.conf` | PHP site metadata neu OPS tao |

## 7. Database

| Artefact | Muc dich |
|---|---|
| **MariaDB** service config (default) | DB server tuning |
| DB users and databases | app data access |
| `/etc/ops/database.conf` | global DB config for OPS (engine, version, root auth mode) |
| `/etc/ops/db-credentials/<db>__<user>.conf` | OPS-managed per-database app credentials (0600, admin-owned) |


## 8. Security

| Artefact | Muc dich |
|---|---|
| UFW rules | inbound access policy |
| `/etc/fail2ban/*` | ban policy |
| default closed ports except approved ones | host exposure contract |

## 8.0 Secret files (0600 — non-negotiable)

Cac file sau phai luon co permission `0600` va owned by admin user:

| File | Noi dung |
|---|---|
| `/etc/ops/.cli-proxy-api-key` | CLIProxyAPI local client key |
| `/etc/ops/db-credentials/<db>__<user>.conf` | OPS-managed DB user credentials |
| `/etc/ops/.db-root-password` | Legacy/fallback MariaDB root password file |
| `/etc/ops/.codex-api-key` | Codex CLI API key cho OpenAI API / custom endpoint modes |
| `~/.claude-api-key` | Claude Code CLI API key |
| `~/claude-telegram/.env` | Claude Telegram bot secret/config env file |
| `/etc/ops/.telegram-bot-token` | Monitoring notification Telegram bot token |
| `~/.codex/config.toml` | Codex CLI config (provider/endpoint/model; khong phai canonical secret store) |

> Bat co file nao trong danh sach tren bi set khac 0600 la bug bao mat.


## 8.1 Advanced web controls

| Artefact | Path | Source | Verify | Permission |
|---|---|---|---|---|
| Cloudflare real IP snippet | `/etc/nginx/snippets/cloudflare-real-ip.conf` | `modules/nginx.sh` — `nginx_enable_cloudflare_real_ip` | `nginx -t` | 0644 |
| Custom X-Powered-By snippet | `/etc/nginx/snippets/custom-powered-by.conf` | `modules/nginx.sh` — `nginx_add_custom_powered_by` | `nginx -t` | 0644 |
| `.htaccess` backup | auto-created by `backup_file` before reset | `modules/php.sh` — `php_reset_htaccess` | backup file present | 0644 |

**Rollback:** remove snippet file, remove `include` line from site config, `nginx -t && systemctl reload nginx`.

> Snippet file alone khong thay doi traffic; no chi co hieu luc khi site config explicit `include` snippet tuong ung.


## 9. Codex CLI

| Artefact | Path | Muc dich |
|---|---|---|
| Binary | `/usr/local/bin/codex` (npm global) | Codex CLI entry |
| Config | `~/.codex/config.toml` | Provider, endpoint, model config (0600) |
| CLIProxyAPI key | `/etc/ops/.cli-proxy-api-key` | Canonical secret cho local CLIProxyAPI mode (0600) |
| Direct/custom key | `/etc/ops/.codex-api-key` | Canonical secret cho OpenAI API / custom endpoint modes (0600) |
| Loader block | admin `~/.bashrc` | Managed `CLI_PROXY_API_KEY` loader cho local mode |
| Auto env block | admin `~/.bash_profile` | Managed `OPENAI_API_KEY` loader khi operator bat auto env |
| OPS state | `/etc/ops/codex-cli.conf` | OPS metadata: mode, endpoint, version |

## 9.1 Claude Code CLI / Telegram bot

| Artefact | Path | Muc dich |
|---|---|---|
| Binary | `/usr/local/bin/claude` (npm global) | Claude Code CLI entry |
| API key | `~/.claude-api-key` | Canonical Claude CLI secret (0600) |
| Shell env block | admin `~/.bashrc` | Managed loader block cho `ANTHROPIC_*` |
| OPS state | `/etc/ops/claude-code.conf` | OPS metadata: base URL, model, install state |
| Telegram bot dir | `~/claude-telegram/` | Bot source + virtualenv |
| Telegram bot env | `~/claude-telegram/.env` | Bot-local secret/config env file (0600) |
| Telegram bot PID | `~/claude-telegram/claude-telegram-bot.pid` | nohup fallback PID file |
| Telegram bot log | `~/claude-telegram-bot.log` | nohup fallback log |

## 10. Verification expectations

Moi artefact quan trong phai co:

- source script/module tao ra no
- verify command
- rollback toi thieu

Neu implementation tao artefact moi ma file nay khong cap nhat, docs dang khong theo kip runtime.

---

## 11. Scheduled check artefacts

> Source: `modules/checks.sh` → `checks_install_cron`

| Artefact | Path | Verify | Note |
|---|---|---|---|
| Cron schedule | `/etc/cron.d/ops-checks` | `cat /etc/cron.d/ops-checks` | 0644, managed by OPS |
| Check dispatcher | `<OPS_ROOT>/bin/ops-check` | `bash -n bin/ops-check` | 0755 |
| Check log | `/var/log/ops/checks.log` | `tail -f /var/log/ops/checks.log` | created on first run |
| Alert cooldown | `/tmp/ops-alert-<type>-<id>.cooldown` | `ls /tmp/ops-alert-*` | cleared on reboot |
| Checks config | `/etc/ops/checks.conf` (optional override) | `source /etc/ops/checks.conf` | 0600 if created |

**Default thresholds:** CPU >90%, RAM >85%, Disk >85%, SSL <14 days, Domain <30 days.
**Cooldown:** 1 hour per alert type per target (configurable via `CHECKS_COOLDOWN_SECONDS`).

---

## 12. Backup artefacts

> Source: `modules/backup.sh`

| Artefact | Path | Verify | Permission |
|---|---|---|---|
| DB dump (single) | `/var/backups/ops/db/<dbname>-YYYYMMDD-HHMMSS.sql.gz` | `gzip -t <file>` | 0600 |
| DB dump (all) | `/var/backups/ops/db/<dbname>-YYYYMMDD-HHMMSS.sql.gz` (one file per non-system database) | `gzip -t <file>` | 0600 |
| Config archive | `/var/backups/ops/config/ops-config-YYYYMMDD-HHMMSS.tar.gz` | `tar -tzf <file>` | 0600 |
| Backup base dir | `/var/backups/ops/` | `ls -la /var/backups/ops/` | 0700 |

**Retention:** OPS warns when > 7 files exist in a backup subdir. Files are **never auto-deleted**.
**Restore guidance:** `menu_backup → Show restore guidance`.

---

## 13. Advanced monitoring — Netdata opt-in

> Source: `modules/monitoring.sh` → `monitoring_install_netdata`

| Artefact | Path | Verify | Note |
|---|---|---|---|
| Netdata package | `netdata` (apt) | `dpkg -l netdata` | install via OPS menu only |
| Netdata service | `netdata.service` | `systemctl is-active netdata` | bound to 127.0.0.1 only |
| Netdata config | `/etc/netdata/netdata.conf` | `grep 'bind to' /etc/netdata/netdata.conf` | must show 127.0.0.1 |
| Dashboard | `http://localhost:19999` | `curl -s localhost:19999/api/v1/info` | localhost only — SSH tunnel to access |

**Footprint:** ~50-80MB RAM idle. OPS warns if RAM < 512MB before install.
**Remove:** `monitoring_remove_netdata` purges package. Config remnants in `/etc/netdata` must be removed manually if needed.

