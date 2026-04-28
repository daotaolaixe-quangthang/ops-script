## OPS Runtime Artefact Inventory

Muc tieu: liet ke cac runtime artefacts ma OPS tao/quan ly de debug, verify, va rollback nhanh.

Luu y: day la target inventory cho script production; mot so artefact se xuat hien day du hon khi implementation hoan chinh.

## 1. Core and global state

| Artefact | Muc dich |
|---|---|
| `/opt/ops` | core install path |
| `/usr/local/bin/ops` | main entrypoint symlink |
| `/usr/local/bin/ops-dashboard` | dashboard symlink |
| `/etc/ops/ops.conf` | global config |
| `/etc/ops/capacity.conf` or JSON | VPS capacity profile |
| `/var/log/ops/ops.log` | high-level operations log |
| `/etc/ops/notifications.conf` | global notification channels and policy (future optional) |

## 2. Login and operator access

| Artefact | Muc dich |
|---|---|
| shell rc hook for admin user | auto run dashboard on interactive login |
| `/etc/ssh/sshd_config` | SSH port and admin access policy |
| sudo user config | non-root daily admin path |

## 3. Node and 9router

Node services va 9router deu theo PM2 contract:

**Node apps:**

| Artefact | Muc dich |
|---|---|
| app dir | Node source/build/runtime files |
| `.env` files | app secrets and runtime env (0600) |
| PM2 process list | process supervision |
| PM2 ecosystem config | declarative process config neu dung |
| `/etc/ops/apps/<app>.conf` | app source of truth neu OPS tao |

**9router specific:**

| Artefact | Path | Muc dich |
|---|---|---|
| Source + build | `/opt/9router` | Next.js app code |
| Env config | `/opt/9router/.env` | Secrets + runtime (0600) |
| DB state | `/var/lib/9router/db.json` | Providers, combos, API keys |
| Usage history | `~/.9router/usage.json` | Per-admin quota stats *(app-managed, OPS does not create)* |
| PM2 process | `nine-router` | PM2-managed duy nhat |
| OPS state | `/etc/ops/nine-router.conf` | OPS-level metadata (0640) |
| Nginx vhost | `/etc/nginx/sites-available/nine-router.*` | Public routing |
| App log | `/var/log/ops/nine-router.{out,err}.log` | PM2 logs |

## 4. Nginx and domains

| Artefact | Muc dich |
|---|---|
| `/etc/nginx/nginx.conf` | global Nginx config |
| `/etc/nginx/sites-available/*` | per-domain configs |
| `/etc/nginx/sites-enabled/*` | enabled site links |
| default deny server | reject unknown hosts |
| `/etc/ops/domains/<domain>.conf` | domain mapping source of truth neu OPS tao |

## 5. SSL

| Artefact | Muc dich |
|---|---|
| certbot config and renewal state | ACME lifecycle |
| live cert paths | active cert/key material |
| Nginx SSL snippets | TLS wiring |

## 5.1 Scheduled checks and notifications

| Artefact | Path | Source module | Verify | Permission |
|---|---|---|---|---|
| Cron file | `/etc/cron.d/ops-checks` | `modules/checks.sh` — `checks_install_cron` | `cat /etc/cron.d/ops-checks` | 0644 |
| Check dispatcher | `bin/ops-check` | `modules/checks.sh` — `_checks_write_dispatcher` | `bash -n bin/ops-check` | 0755 |
| Alert cooldown | `/tmp/ops-alert-<type>-<id>.cooldown` | runtime (per check run) | `ls /tmp/ops-alert-*` | 0644 |
| Check log | `/var/log/ops/checks.log` | cron redirect | `tail /var/log/ops/checks.log` | 0644 |
| Checks config override | `/etc/ops/checks.conf` | operator-created (optional) | `cat /etc/ops/checks.conf` | 0600 |
| Telegram token | `/etc/ops/.telegram-bot-token` | `modules/monitoring.sh` | exists + 0600 | 0600 |
| Telegram config | `/etc/ops/ops.conf` (TELEGRAM_ENABLED, TELEGRAM_CHAT_ID) | `modules/monitoring.sh` | `grep TELEGRAM /etc/ops/ops.conf` | 0600 |

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
| `/etc/ops/database.conf` | global DB config for OPS (engine, version) |


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
| `/opt/9router/.env` | JWT_SECRET, INITIAL_PASSWORD, API_KEY_SECRET, MACHINE_ID_SALT |
| `/etc/ops/.nine-router-password` | 9router dashboard initial password |
| `/etc/ops/.db-root-password` | MariaDB/MySQL root password |
| `/etc/ops/.codex-api-key` | Codex CLI / 9router API key |
| `~/.codex/config.toml` | Codex CLI config with inline API key |

> Bat co file nao trong danh sach tren bi set khac 0600 la bug bao mat.


## 8.1 Advanced web controls (P2-03A)

| Artefact | Path | Source | Verify | Permission |
|---|---|---|---|---|
| Cloudflare real IP snippet | `/etc/nginx/snippets/cloudflare-real-ip.conf` | `modules/nginx.sh` — `nginx_enable_cloudflare_real_ip` | `nginx -t` | 0644 |
| Custom X-Powered-By snippet | `/etc/nginx/snippets/custom-powered-by.conf` | `modules/nginx.sh` — `nginx_add_custom_powered_by` | `nginx -t` | 0644 |
| `.htaccess` backup | auto-created by `backup_file` before reset | `modules/php.sh` — `php_reset_htaccess` | backup file present | 0644 |

**Rollback:** remove snippet file, remove `include` line from site config, `nginx -t && systemctl reload nginx`.

## 8.2 Future remote backup artefacts

| Artefact | Muc dich |
|---|---|
| `/etc/ops/backups/telegram.conf` | Telegram Cloud backup transport config |
| `/etc/ops/backups/uploads/*.conf` | uploads backup policies per app/site |
| local backup staging dir | tao archive truoc khi upload |
| backup metadata map | map local backup voi Telegram file/message identifiers |
| auto-backup scheduler entries | lich chay uploads backup tu dong |

## 9. Codex CLI

| Artefact | Path | Muc dich |
|---|---|---|
| Binary | `/usr/local/bin/codex` (npm global) | Codex CLI entry |
| Config | `~/.codex/config.toml` | Endpoint, model, API key (0600) |
| API key | `/etc/ops/.codex-api-key` | Key rieng biet (0600) |
| OPS state | `/etc/ops/codex-cli.conf` | OPS metadata: mode, endpoint, version |

## 10. Verification expectations

Moi artefact quan trong phai co:

- source script/module tao ra no
- verify command
- rollback toi thieu

Neu implementation tao artefact moi ma file nay khong cap nhat, docs dang khong theo kip runtime.

---

## 11. Scheduled check artefacts (P2-03)

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

## 12. Backup artefacts (P2-05)

> Source: `modules/backup.sh`

| Artefact | Path | Verify | Permission |
|---|---|---|---|
| DB dump (single) | `/var/backups/ops/db/<dbname>-YYYYMMDD-HHMMSS.sql.gz` | `gzip -t <file>` | 0600 |
| DB dump (all) | `/var/backups/ops/db/all-YYYYMMDD-HHMMSS.sql.gz` (per-db files) | `gzip -t <file>` | 0600 |
| Config archive | `/var/backups/ops/config/ops-config-YYYYMMDD-HHMMSS.tar.gz` | `tar -tzf <file>` | 0600 |
| Backup base dir | `/var/backups/ops/` | `ls -la /var/backups/ops/` | 0700 |

**Retention:** OPS warns when > 7 files exist in a backup subdir. Files are **never auto-deleted**.
**Restore guidance:** `menu_backup → Show restore guidance`.

---

## 13. Advanced monitoring — Netdata opt-in (P2-02)

> Source: `modules/monitoring.sh` → `monitoring_install_netdata`

| Artefact | Path | Verify | Note |
|---|---|---|---|
| Netdata package | `netdata` (apt) | `dpkg -l netdata` | install via OPS menu only |
| Netdata service | `netdata.service` | `systemctl is-active netdata` | bound to 127.0.0.1 only |
| Netdata config | `/etc/netdata/netdata.conf` | `grep 'bind to' /etc/netdata/netdata.conf` | must show 127.0.0.1 |
| Dashboard | `http://localhost:19999` | `curl -s localhost:19999/api/v1/info` | localhost only — SSH tunnel to access |

**Footprint:** ~50-80MB RAM idle. OPS warns if RAM < 512MB before install.
**Remove:** `monitoring_remove_netdata` purges package. Config remnants in `/etc/netdata` must be removed manually if needed.

