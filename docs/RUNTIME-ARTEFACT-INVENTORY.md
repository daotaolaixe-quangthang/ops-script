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
| Usage history | `~/.9router/usage.json` | Per-admin quota stats |
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

## 5.1 Future checks and notifications

| Artefact | Muc dich |
|---|---|
| `/etc/ops/checks/uptime/*.conf` | website uptime/downtime checks (future optional) |
| `/etc/ops/checks/ssl-expiry/*.conf` | SSL expiry checks (future optional) |
| `/etc/ops/checks/domain-expiry/*.conf` | domain expiry checks (future optional) |
| `/etc/ops/checks/security-scan/*.conf` | scheduled security scan configs (future optional) |
| scheduler entries for checks | chay dinh ky checks/alerts |
| notification delivery config | Telegram/Email channel wiring |

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


## 8.1 Future web-control artefacts

| Artefact | Muc dich |
|---|---|
| Nginx real IP snippet | Cloudflare-aware real visitor IP logging |
| Nginx direct-IP block snippet | chan truy cap truc tiep bang IP |
| Nginx custom header snippet | custom `X-Powered-By` handling |
| PHP-secondary `.htaccess` backup/reset target | app-level compatibility reset only |

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
