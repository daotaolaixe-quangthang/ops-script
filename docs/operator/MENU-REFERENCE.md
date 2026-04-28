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
5. **CLIProxyAPI Management**
6. **PHP / PHP-FPM Management**
7. **Database Management**
8. **AI Agent Integration**
9. **System & Monitoring**
s. **Security Management**
0. **Exit**

Source of truth: `bin/ops` (dispatch table). This list matches the current implementation.

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

> **SSH lockout guard (chot):** The Security Baseline step (1>1) checks whether the admin user has at
> least one SSH public key in `~/.ssh/authorized_keys` before allowing `PasswordAuthentication` to be
> disabled. If no key is present, the prompt is suppressed and `PasswordAuthentication` stays `yes`.
> Operators must add a key first via **Security -> Manage SSH Keys** (option 8).

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
- "App" here means a long-running Node.js application managed by PM2. CLIProxyAPI is managed separately by systemd.
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
7. **Advanced web controls** -> submenu (xem chi tiet ben duoi)
8. **Apply security baseline** — server_tokens off, TLS headers
0. **Back to main menu**

**Advanced web controls submenu (da implement):**

1. Enable Cloudflare real IP logging — snippet `/etc/nginx/snippets/cloudflare-real-ip.conf`
2. Remove Cloudflare real IP snippet
3. Add custom X-Powered-By header — snippet `/etc/nginx/snippets/custom-powered-by.conf`
4. Remove custom X-Powered-By snippet
5. Enable Cloudflare IP restrict — block non-CF traffic via geo{} block (opt-in only; use when all domains are Orange Cloud)
6. Refresh Cloudflare IP list — re-download from cloudflare.com/ips
7. Remove Cloudflare IP restrict
0. Back

> Note: "Block direct http://IP access" is handled automatically by the default deny server block (`00-default-deny`) which Nginx applies to all unmatched hosts. No separate menu action is needed.

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
- After SSL is issued for a CLIProxyAPI domain: auto re-render the provider vhost so Nginx keeps HTTPS termination and proxying to `127.0.0.1:8317`.
- Status view should clearly show:
  - Domains with valid certificates.
  - Expiry dates.
  - Any domains without SSL configured.

---

### 6. CLIProxyAPI Management

Entry: `5) CLIProxyAPI Management`

**Status dashboard (hiển thị tự động khi vào menu):**

Ngay khi vào menu `5) CLIProxyAPI Management`, OPS hiển thị status block của CLIProxyAPI:

```
CLIProxyAPI Management

  Installation  : Installed (/opt/cli-proxy-api) v<version>
  Local address  : 127.0.0.1:8317
  Domain         : proxy.example.com (SSL)
  Service        : active
  API Key        : disabled
  Request logs   : disabled
```

| Trường | Nguồn dữ liệu | Fallback khi chưa cài |
|---|---|---|
| Installation | `[[ -x /opt/cli-proxy-api/cli-proxy-api ]]` | `Not installed` |
| Local address | Hằng `CLIPROXYAPI_PORT=8317` | Luôn hiện |
| Domain | `ops_conf_get cli-proxy-api.conf CLIPROXYAPI_DOMAIN` | `not configured` |
| Service | `systemctl is-active cli-proxy-api` | `inactive` |
| API Key | `ops_conf_get cli-proxy-api.conf CLIPROXYAPI_REQUIRE_API_KEY` | `disabled` |
| Request logs | `ops_conf_get cli-proxy-api.conf CLIPROXYAPI_REQUEST_LOGS` | `disabled` |

**Submenu:**

1. **Install CLIProxyAPI**
2. **Update CLIProxyAPI**
3. **Link CLIProxyAPI to a domain**
4. **Start CLIProxyAPI**
5. **Stop CLIProxyAPI**
6. **Restart CLIProxyAPI**
7. **View CLIProxyAPI logs**
8. **Enable API key requirement**
9. **Disable API key requirement**
10. **Enable request logging**
11. **Disable request logging**
12. **Verify CLIProxyAPI** - systemd active, `/v1/models` returns JSON, UFW port 8317 closed
0. **Back to main menu**

Notes:

- **Install CLIProxyAPI**:
  - Download release metadata from `https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest`.
  - Extract binary into `/opt/cli-proxy-api` and create `cli-proxy-api.service`.
  - Write `/opt/cli-proxy-api/config.yaml` with loopback bind `127.0.0.1:8317`.
  - Keep auth material under runtime user home `~/.cli-proxy-api`.
- **Update CLIProxyAPI**:
  - Download latest matching release archive.
  - Preserve `config.yaml` and OPS state.
  - Restart service by systemd.
- **Link CLIProxyAPI to a domain**:
  - Tạo Nginx vhost với `proxy_buffering off`.
  - Nginx la public entrypoint duy nhat; proxy toi `127.0.0.1:8317`.
  - Sau khi issue SSL, OPS tu re-render provider vhost de tiep tuc dung HTTPS o Nginx.
- **Enable/Disable API key requirement**:
  - Rewrite `api-keys:` trong `config.yaml`.
  - Restart `cli-proxy-api.service`.
  - Local client key duoc luu tai `/etc/ops/.cli-proxy-api-key`.
- **Bootstrap auth providers**:
  - Claude: `sudo -u <runtime_user> env HOME=<runtime_home> /opt/cli-proxy-api/cli-proxy-api --claude-login`
  - Codex/OpenAI: `sudo -u <runtime_user> env HOME=<runtime_home> /opt/cli-proxy-api/cli-proxy-api --codex-login`
  - Gemini: `sudo -u <runtime_user> env HOME=<runtime_home> /opt/cli-proxy-api/cli-proxy-api --login`

CLIProxyAPI implementation authority for future agents:
- `ops/modules/cli-proxy-api.sh`
- `ops/modules/nginx.sh`
- `ops/modules/verify.sh`
- `ops/modules/templates/nginx/cli-proxy-api.vhost.conf.tpl`

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

### 9. AI Agent Integration

Entry: `8) AI Agent Integration`  
Dispatch: `menu_ai_agent` (in `modules/ai-agent.sh`)

Top-level submenu:

1. **Codex CLI Integration** -> submenu `menu_codex_cli`
2. **Claude Code CLI Integration** -> submenu `menu_claude_cli`
0. **Back to main menu**

#### 9a. Codex CLI submenu (`menu_codex_cli`)

1. **Install Codex CLI** — `npm install -g @openai/codex`
2. **Configure Codex for this server** — endpoint, API key, model
3. **Enable / disable Codex CLI auto environment** — source env on shell login
4. **Test Codex CLI** — send test query
0. **Back**

Config: `/etc/ops/codex-cli.conf` | API key: `/etc/ops/.codex-api-key` (0600)

#### 9b. Claude Code CLI submenu (`menu_claude_cli`)

1. **Install Claude Code CLI** — `npm install -g @anthropic-ai/claude-code`
2. **Configure environment Claude for this server** — `ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY`, `ANTHROPIC_MODEL` written to admin `~/.bashrc`
3. **Test Claude Code CLI** — version check + endpoint reachability
4. **Install Vietnamese fix for Claude Code CLI** — apply locale patch from external repo
5. **Claude Code Telegram Bot** -> submenu (install / configure / start / stop / status)
0. **Back**

Config state: `/etc/ops/claude-code.conf` (0640) | API key stored in admin `~/.bashrc` (not in `/etc/ops`)

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
12. **Verify stack health** — PASS/WARN/FAIL per component, always exit 0; caller menu does not use `|| true`
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

**Menu contract note:**

- Moi `menu_*` boundary phai `return 0` khi user back hoac khi action ben trong soft-fail.
- Action-level non-zero duoc hap thu boi wrapper menu-local (`_foo_menu_run`), khong propagate len menu cha.
- `bin/ops` goi cac `menu_*` truc tiep; khong con dung `menu_x || true` nhu workaround.

---

### 11. Security Management

The Security Management submenu is accessible from the main menu via **Production Setup Wizard → Security Baseline**, or by running `sudo ops` and navigating to the **Security** module directly (e.g. `sudo ops` → any sub-path that triggers `menu_security`).

Submenu:

1. **Harden SSH config** — apply SSH hardening include (port, password auth, deny root)
2. **Configure UFW firewall** — reconcile UFW to OPS-managed baseline
3. **Install & configure fail2ban** — set up fail2ban with SSH and nginx jails
4. **Show security status** — display SSH port, auth settings, TCP forwarding, ufw/fail2ban state
5. **Change SSH port** — change port with safe transition (old port kept open until verified)
6. **Finalize SSH transition (close old SSH port)** — remove old port from sshd config and UFW
7. **Apply host baseline (sysctl/swap/firewall/fail2ban)** — apply all non-SSH security baselines
8. **Manage SSH keys** — add/remove authorized_keys, toggle PasswordAuthentication
9. **TCP Forwarding (VSCode Remote SSH)** — enable or disable `AllowTcpForwarding` in sshd
10. **Auto Security Updates (unattended-upgrades)** — configure automatic OS security patching (enable/disable/status)
0. **Back**

**Option 9 — TCP Forwarding detail:**

`AllowTcpForwarding` is set to `no` by default (security-hardened). Enable it only when VSCode SSH Remote (or other SOCKS-based tools) is required. The setting is persisted in `ops.conf` as `OPS_SSH_TCP_FORWARDING` and survives future SSH port changes or hardening runs.

> [!WARNING]
> Enabling TCP Forwarding allows port tunneling through the SSH server, which increases attack surface. Only enable when needed; disable again when not in use.

---

### 12. Planned future menu extensions (Phase 2 / Phase 4)

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

#### Advanced Web Controls (implemented — Phase 2)

Status: da implement day du trong `menu_nginx_web_controls` (`modules/nginx.sh`).

Actions da co:

1. **Enable Cloudflare real IP logging** — deploy snippet `/etc/nginx/snippets/cloudflare-real-ip.conf`
2. **Remove Cloudflare real IP snippet**
3. **Add custom X-Powered-By header** — deploy snippet `/etc/nginx/snippets/custom-powered-by.conf`
4. **Remove custom X-Powered-By snippet**
5. **Enable Cloudflare IP restrict** — block non-CF traffic via live geo{} block (opt-in; all domains must be Orange Cloud)
6. **Refresh Cloudflare IP list** — re-download from cloudflare.com/ips-v4 + ips-v6
7. **Remove Cloudflare IP restrict**

**Factory reset `.htaccess`:** da implement tai `php_reset_htaccess` trong `modules/php.sh`.

**Block direct `http://IP` access:** khong can menu action rieng. Default deny server block (`00-default-deny`) tu dong tra 444 cho tat ca request toi unknown host, bao gom raw IP.
