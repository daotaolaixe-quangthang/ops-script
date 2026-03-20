## OPS Menu Reference

This document defines all user-facing menus and submenus. Menu labels must remain in English as specified here so that documentation and automation stay in sync.

---

### 0. SSH Login Dashboard & Menu Entry

After a successful SSH login as the admin user, OPS automatically shows a **login dashboard** (`ops-dashboard`) that displays system info, resources, and service status.

At the bottom of the dashboard, the following prompt appears:

```
  Press 1 to open OPS menu, or Enter to continue to the shell:
```

**How to access the OPS menu:**

| Method | Command / Action |
|---|---|
| From the login dashboard | Press `1` then Enter |
| From any shell session | Run `ops` |

Both methods launch the same main OPS menu.

**Technical note on the login hook (`~/.bash_profile`):**
The hook uses `SSH_CONNECTION` (always set by `sshd` for interactive SSH sessions) as the login guard, **not** `SSH_TTY` (which some SSH clients may leave unset). This ensures the dashboard reliably appears on every SSH login.

```bash
# OPS login hook — ~/.bash_profile
if [[ $- == *i* ]] && [[ -n "${SSH_CONNECTION:-}" ]]; then
    if command -v ops-dashboard &>/dev/null; then
        ops-dashboard
    fi
fi
```

> If the dashboard doesn't appear after SSH login, verify your `~/.bash_profile` uses `SSH_CONNECTION` (not `SSH_TTY`). Re-run `ops-setup.sh` to regenerate the hook.

---

### 1. Main menu (`ops`)

Suggested layout:

1. **Production Setup Wizard**
2. **Node.js Services**
3. **Domains & Nginx**
4. **SSL Management**
5. **9router Management**
6. **PHP / PHP-FPM Management**
7. **Database Management**
8. **Codex CLI Integration**
9. **System & Monitoring**
0. **Exit**

Each item maps to a module or group of modules as described below.

---

### 2. Production Setup Wizard

Entry: `1) Production Setup Wizard`

- Guides the user through first-time production stack setup.
- Orchestrates:
  - Security & firewall
  - Nginx install & tuning
  - Node.js + PM2
  - PHP-FPM (multi-version)
  - Database (MariaDB default)
  - Logging & basic monitoring

The wizard itself is covered in detail in `FLOW-INSTALL.md`.

---

### 3. Node.js Services

Entry: `2) Node.js Services`

Submenu:

1. **List Node.js apps (PM2)** — show PM2 process list + registered apps in `/etc/ops/apps/`
2. **Add Node.js app** — register app, create `ecosystem.config.js`, start via PM2
3. **Remove Node.js app** — delete PM2 process + registry entry, backup conf
4. **Restart app** — `pm2 restart <pm2_name>`
5. **Show app logs** — `pm2 logs <pm2_name> --lines N --nostream`
0. **Back to main menu**

Notes:

- Implementation uses **PM2** for all Node.js services. `systemd` remains for OS-level services only.
- "App" here means a long-running Node.js application (including but not limited to 9router).
- **Installing Node.js LTS and PM2 is done via the Production Setup Wizard** (`1) Production Setup Wizard → 5) Install Node.js LTS & PM2`), not from this menu.
- Apps are registered in `/etc/ops/apps/<appname>.conf`; runtime user is derived from `ops.conf`.

---

### 4. Domains & Nginx

Entry: `3) Domains & Nginx`

Submenu:

1. **List domains**
2. **Add new domain**
3. **Edit domain**
4. **Remove domain**
5. **Test Nginx config & reload**
6. **Install / update Nginx** — install from apt, apply global tuning (worker, TLS, security headers)
7. **Advanced web controls** → submenu (Cloudflare real IP, custom X-Powered-By)
0. **Back to main menu**

**Add new domain flow (chốt):**

1. Ask for domain name (e.g. `example.com`).
2. Ask for backend type:
   - `1) Node.js` — reverse proxy to an existing PM2 service (select from list) or manual port.
   - `2) PHP site` — via PHP-FPM socket (select PHP version + pool name).
   - `3) Static site` — serve files only.
3. Render Nginx vhost from template, enable site, `nginx -t && reload`.
4. Create OPS state file `/etc/ops/domains/<domain>.conf`.
5. **SSL is NOT issued here** — operator issues SSL separately via `SSL Management` menu.

**Web root convention (chốt):**

| Backend | Web root |
|---|---|
| Node.js | `/var/www/<appname>` (operator deploys; OPS does not create or delete) |
| PHP site | `/var/www/<domain>` (OPS creates with correct ownership) |
| Static | `/var/www/<domain>` (OPS creates with correct ownership) |

Ownership khi OPS tạo: `chown -R $ADMIN_USER:www-data /var/www/<domain> && chmod 755 /var/www/<domain>`

**Remove domain flow (chốt):**

Khi operator chọn `Remove domain`, OPS phải:

1. Confirm: `"Remove domain <domain>? This will delete Nginx config. [y/N]:"`
2. Xóa: `/etc/nginx/sites-enabled/<domain>` (symlink)
3. Xóa: `/etc/nginx/sites-available/<domain>`
4. Xóa: `/etc/ops/domains/<domain>.conf`
5. `nginx -t && reload`
6. In rõ: `"Web root /var/www/<domain> was NOT deleted. Remove it manually if needed."`

> **Không được tự xóa web root** `/var/www/<domain>` — dữ liệu có thể quan trọng.
> Không được tự xóa SSL cert (Certbot quản lý riêng).

**Edit domain** may allow:

- Changing backend type or target.
- Enabling/disabling HTTP→HTTPS redirect (if SSL is available via Certbot).

---

### 5. SSL Management

Entry: `4) SSL Management`

Submenu:

1. **Issue SSL certificate for a domain**
2. **Renew all certificates**
3. **Show certificate status**
4. **Install / repair Certbot (snap)**
0. **Back to main menu**

Guidelines:

- Use Certbot as the primary ACME client (snap install).
- Certificates should be integrated into the Nginx vhosts generated by the Domains menu.
- After SSL is issued for a 9router domain: auto-set `AUTH_COOKIE_SECURE=true` in `/opt/9router/.env` and restart.
- Status view should clearly show:
  - Domains with valid certificates.
  - Expiry dates.
  - Any domains without SSL configured.

---

### 6. 9router Management

Entry: `5) 9router Management`

**Status dashboard (hiển thị tự động khi vào menu):**

Ngay khi vào menu `5) 9router Management`, OPS hiển thị một status block tóm tắt trạng thái hiện tại của 9router:

```
━━━ 9router Management ━━━

  📦 Installation  : ✓ Installed  (/opt/9router)
  🌐 Local address  : 127.0.0.1:20128
  🔗 Domain         : proxy.example.com  (SSL ✓)
  🚦 PM2 Status     : ✓ online
  🔄 Restarts       : 3
  🔑 API Key        : disabled
  📋 Log lines      : 1452
```

| Trường | Nguồn dữ liệu | Fallback khi chưa cài |
|---|---|---|
| Installation | `[[ -d /opt/9router/.git ]]` | `✗ Not installed` (đỏ) |
| Local address | Hằng `NINE_ROUTER_PORT=20128` | Luôn hiện |
| Domain | `ops_conf_get nine-router.conf NINE_ROUTER_DOMAIN` | `— (not configured)` |
| PM2 Status | `pm2 jlist` JSON parse (field `status`) | `— (not registered)` |
| Restarts | `pm2 jlist` JSON parse (field `restart_time`) | `—` |
| API Key | `ops_conf_get nine-router.conf NINE_ROUTER_REQUIRE_API_KEY` | `—` |
| Log lines | `wc -l` cộng `nine-router.out.log` + `nine-router.err.log` | `0` |

Màu sắc: xanh = tốt / hoạt động, vàng = cần chú ý / disabled, đỏ = lỗi / chưa cài. Nếu 9router chưa cài, mọi trường PM2-related hiện `—` thay vì crash.

**Submenu:**

1. **Install 9router**
2. **Update 9router** (git pull + npm build + pm2 restart)
3. **Link 9router to a domain**
4. **Start 9router**
5. **Stop 9router**
6. **Restart 9router**
7. **View 9router logs**
8. **Enable API key requirement** *(REQUIRE_API_KEY=true)*
9. **Disable API key requirement** *(REQUIRE_API_KEY=false)*
10. **Verify 9router** — PM2 online, `/v1/models` returns JSON, UFW port 20128 closed
0. **Back to main menu**

Notes:

- **Install 9router**:
  - Clone from `https://github.com/daotaolaixe-quangthang/9routervps` (chốt URL).
  - Hỏi operator nhập INITIAL_PASSWORD; lưu tại `/etc/ops/.nine-router-password` (0600).
  - Generate JWT_SECRET, API_KEY_SECRET, MACHINE_ID_SALT tự động bằng `openssl rand`.
  - `npm install && npm run build`.
  - Đăng ký PM2 process `nine-router`.
- **Link 9router to a domain**:
  - Tạo Nginx vhost với `proxy_buffering off` (bắt buộc cho SSE).
  - Nếu domain đã có SSL: tự động set `AUTH_COOKIE_SECURE=true` trong `.env` và restart.
- **Enable/Disable API key requirement** (toggle):
  - Cập nhật `REQUIRE_API_KEY=true|false` trong `/opt/9router/.env`.
  - `pm2 restart nine-router`.
  - Cập nhật `/etc/ops/nine-router.conf`: `NINE_ROUTER_REQUIRE_API_KEY="yes"|"no"`.
  - Khi bật: chỉ clients có API key từ dashboard mới được dùng endpoint `/v1`.

---

### 7. PHP / PHP-FPM Management

Entry: `6) PHP / PHP-FPM Management`

Submenu:

1. **List installed PHP versions**
2. **Install or remove PHP versions**
3. **Configure PHP-FPM pools**
4. **Set default PHP CLI version**
5. **Show PHP-FPM status**
0. **Back to main menu**

Key requirements:

- Support multiple versions: 7.4, 8.1, 8.2, 8.3 (via `ppa:ondrej/php`).
- PHP-FPM pool naming: `/etc/php/<ver>/fpm/pool.d/<site-name>.conf`, socket `/run/php/php<ver>-fpm-<site-name>.sock`.
- PHP-FPM pools must be tuned based on RAM/CPU using `PERF-TUNING.md`.
- Domain creation for PHP sites must allow choosing a specific PHP version.

---

### 8. Database Management

Entry: `7) Database Management`

Submenu:

1. **Install / reinstall database server**
2. **Secure and tune database**
3. **Create database and user**
4. **List databases and users**
5. **Show database server status**
0. **Back to main menu**

Constraints:

- Default engine: **MariaDB** (chốt). MySQL chỉ cài nếu operator chọn rõ.
- `bind-address = 127.0.0.1` luôn được đặt (MariaDB chỉ phục vụ nội bộ VPS).
- Secure setup equivalent to or stricter than `mysql_secure_installation`.
- Tuning values derived from `PERF-TUNING.md`.
- DB root password lưu tại `/etc/ops/.db-root-password` (0600) — không in ra terminal.

---

### 9. Codex CLI Integration

Entry: `8) Codex CLI Integration`

Submenu:

1. **Install Codex CLI**
2. **Configure Codex for this server**
3. **Enable / disable Codex CLI auto environment**
4. **Test Codex CLI**
0. **Back to main menu**

Purpose:

- Make Codex CLI a first-class tool on the server for AI-assisted operations.
- Configuration stored in `/etc/ops/codex-cli.conf`; API key at `/etc/ops/.codex-api-key` (0600).

---

### 10. System & Monitoring

Entry: `9) System & Monitoring`

Current implementation (monitoring.sh — đã full Phase 1 + Phase 2):

1. **System overview** — CPU, RAM, swap, disk, load, uptime
2. **Service status** — Nginx, PHP-FPM, MariaDB, PM2, UFW, fail2ban
3. **Quick logs — Nginx**
4. **Quick logs — PHP-FPM**
5. **Quick logs — PM2 / Node apps**
6. **Quick logs — Database (MariaDB)**
7. **OPS log (ops.log)**
8. **Login history** — `last`, `lastb`, journalctl SSH
9. **Disk usage**
10. **Setup Telegram notifications**
11. **Test Telegram notification**
12. **Verify stack health** — PASS/WARN/FAIL per component, always exit 0
13. **Advanced monitoring (Netdata opt-in)** → submenu install/remove/status
14. **Notifications & scheduled checks** → submenu (checks.sh — P2-03)
15. **Backup helpers** → submenu (backup.sh — P2-05)
16. **Update OPS from git** — download tarball, syntax check, apply
0. **Back to main menu**

**Telegram config implementation (chốt):**

- Bot token: `/etc/ops/.telegram-bot-token` (0600, owned by ADMIN_USER) — never printed to terminal
- Chat ID và `TELEGRAM_ENABLED`: lưu trong `/etc/ops/notifications.conf` — đúng theo `ARCHITECTURE.md`, `FEATURE-EXPANSION-SPEC.md`
- Migration: nếu cũ lưu trong `ops.conf`, `monitoring_setup_telegram()` tự động migrate sang `notifications.conf`


This reference must be kept in sync with the actual menu layout in `bin/ops`.

---

### 11. Planned future menu extensions (Phase 2 / Phase 4)

These do **not** change the Phase 1 menu contract. They are planned placements for future feature groups.

#### Notifications & Checks (planned, Phase 2)

Planned actions:

1. **Enable / disable website uptime-downtime checks**
2. **Enable / disable SSL expiry alerts**
3. **Enable / disable domain expiry alerts**
4. **Enable / disable periodic security scan**

> Note: Telegram config is already in Phase 1 (System & Monitoring #4).
> Phase 2 extends it with automated check triggers.

Suggested placement:

- under `System & Monitoring`
- with links from `SSL Management` and `Domains & Nginx` where relevant

#### Remote Upload Backups (planned, Phase 4)

Planned actions:

1. **Upload website uploads backup to Telegram Cloud**
2. **Download uploads backup from Telegram Cloud**
3. **Enable automatic uploads backup to Telegram Cloud**
4. **Disable automatic uploads backup to Telegram Cloud**

Suggested placement:

- separate optional submenu
- or under backup-related future actions in `System & Monitoring`

#### Advanced Web Controls (planned, Phase 2)

Planned actions:

1. **Factory reset website `.htaccess`**
2. **Show real visitor IP logging behind Cloudflare**
3. **Customize `X-Powered-By` header**
4. **Block direct `http://IP` access**

Suggested placement:

- under `Domains & Nginx`
- PHP-secondary compatibility note applies to `.htaccess`
