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
The hook uses `SSH_CONNECTION` (always set by `sshd` for interactive SSH sessions) as the login guard, **not** `SSH_TTY` (which some SSH clients may leave unset). This ensures the dashboard reliably appears on every SSH login. The hook is display-only and must not mutate SSH/firewall state.

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
  - System update & base tools
  - Security & firewall
  - Nginx install & tuning
  - Node.js + PM2
  - PHP-FPM (multi-version)
  - Database (MariaDB default)
  - Logging & basic monitoring
  - Summary & verification

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

> Note: Hai action snippet tren chi tao/cap nhat file trong `/etc/nginx/snippets/`. Chung chi co hieu luc khi site config explicit `include` snippet tuong ung.
>
> Note: "Block direct http://IP access" is handled automatically by the default deny server block (`00-default-deny`) which Nginx applies to all unmatched hosts. OPS also maintains the fallback self-signed cert/key at `/etc/nginx/ssl/ops-default.crt` and `/etc/nginx/ssl/ops-default.key` for its 443 default server. No separate menu action is needed.

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
5. **Snap housekeeping** — clean stale revisions, set retain=2
6. **Set Cloudflare API Token** — enable DNS-01 automation for proxied Cloudflare domains
7. **Issue Cloudflare Origin Certificate** — 15-year origin cert for Cloudflare proxy mode
8. **List Cloudflare Origin Certificates**
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
13. **Bootstrap auth providers** - hien submenu chon `Antigravity` / `Gemini` / `Claude Code` / `Codex`
14. **Check quota** - cai Quota Inspector neu thieu va chay quota summary nhanh
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
  - OPS hien submenu de chon account type `Antigravity` / `Gemini` / `Claude Code` / `Codex`.
  - Antigravity: `sudo -u <runtime_user> env HOME=<runtime_home> /opt/cli-proxy-api/cli-proxy-api --antigravity-login`
  - Gemini: `sudo -u <runtime_user> env HOME=<runtime_home> /opt/cli-proxy-api/cli-proxy-api --login`
  - Claude Code: `sudo -u <runtime_user> env HOME=<runtime_home> /opt/cli-proxy-api/cli-proxy-api --claude-login`
  - Codex: `sudo -u <runtime_user> env HOME=<runtime_home> /opt/cli-proxy-api/cli-proxy-api --codex-login`
- **Check quota**:
  - Neu chua co Quota Inspector, OPS se hoi cai va build binary truoc.
  - Sau khi cai, OPS tu quan ly block `cpaq()` trong `~/.bashrc` cua admin user.
  - Menu `Check quota` cung se ensure block nay ton tai tren cac may da cai tu truoc.
  - Reload shell bang `source ~/.bashrc`, sau do co the chay nhanh `cpaq`.
  - Neu CPA bat management auth, operator tu export `CPA_MANAGEMENT_KEY` truoc khi check quota.

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
6. **Reset .htaccess (PHP sites only)**
0. **Back to main menu**

Key requirements:

- Support multiple versions: 7.4, 8.1, 8.2, 8.3 (via `ppa:ondrej/php`).
- PHP domains use an **explicit pool name** contract. The add-domain flow asks for `PHP version + pool name`, defaulting the pool name to the domain.
- The same pool identity must drive all PHP state:
  - `/etc/php/<ver>/fpm/pool.d/<pool>.conf`
  - `/run/php/php<ver>-fpm-<pool>.sock`
  - `/etc/ops/php-sites/<pool>.conf`
  - `DOMAIN_PHP_POOL` in `/etc/ops/domains/<domain>.conf`
- Editing a PHP domain version must keep the stored pool name stable; only the PHP version/socket changes.
- Re-running pool configuration refreshes OPS-managed keys but preserves existing custom per-pool directives such as `env[]`, `php_admin_value`, and `php_admin_flag` entries, including when the pool is migrated to another PHP version.
- PHP add/remove domain flows are transactional: if the PHP or Nginx commit step fails, OPS restores the previous PHP pool, vhost, and domain state instead of leaving orphaned state behind.
- PHP-FPM pools must be tuned based on RAM/CPU using `docs/reference/PERF-TUNING.md`.
- Security-sensitive hardening (`disable_functions`, `allow_url_fopen = Off`, `allow_url_include = Off`, `display_errors = Off`, `expose_php = Off`, `log_errors = On`) applies to **FPM only**. CLI keeps common tuning plus `opcache.enable_cli` and is switched separately via **Set default PHP CLI version**.
- `pm.status_path` / `ping.path` are intentionally omitted from the default pool baseline. If you re-enable them, the matching Nginx location must stay restricted to `127.0.0.1` only.
- Removing a PHP version is blocked while it is still referenced by any managed domain, any `/etc/ops/php-sites/*.conf`, or the current default CLI.
- PHP verify output should show the default CLI version, the target `/usr/bin/php<ver>` version, `php-fpm<ver> -t`, the `php<ver>-fpm` service status, and domain contract checks across `DOMAIN_PHP_POOL`, pool file, socket, and `fastcgi_pass`.

---

### 8. Database Management

Entry: `7) Database Management`

Submenu:

1. **Install MariaDB**
2. **Secure/re-harden MariaDB**
3. **Apply tuning (by Tier)**
4. **Create database**
5. **Create database user**
6. **Drop database**
7. **List databases**
8. **Database status**
9. **Compliance audit**
0. **Back to main menu**

Constraints:

- Default engine: **MariaDB** (chốt).
- `bind-address = 127.0.0.1` luôn được đặt (MariaDB chỉ phục vụ nội bộ VPS).
- Secure setup equivalent to or stricter than `mysql_secure_installation`, voi root baseline dung `unix_socket`.
- Tuning values derived from `docs/reference/PERF-TUNING.md`.
- OPS-managed app credentials lưu tại `/etc/ops/db-credentials/<db>__<user>.conf` (`0600`, owner admin user).
- `/etc/ops/.db-root-password` chi la file legacy/fallback khi host van dung password auth cho root — không in ra terminal.

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
2. **Configure Codex for this server** — chon 1 trong 4 mode: CLIProxyAPI, OpenAI API key, ChatGPT OAuth, custom endpoint
3. **Enable / disable Codex CLI auto environment** — managed `OPENAI_API_KEY` loader block in admin `~/.bash_profile`
4. **Test Codex CLI** — version check + config path + CLIProxyAPI reachability check khi dung local mode
0. **Back**

Config state: `/etc/ops/codex-cli.conf` | Local key: `/etc/ops/.cli-proxy-api-key` | Direct/custom key: `/etc/ops/.codex-api-key` (0600)

#### 9b. Claude Code CLI submenu (`menu_claude_cli`)

1. **Install Claude Code CLI** — `npm install -g @anthropic-ai/claude-code`
2. **Configure environment Claude for this server** — `ANTHROPIC_BASE_URL` + `ANTHROPIC_MODEL` written to a managed admin `~/.bashrc` block that reads `~/.claude-api-key`
3. **Test Claude Code CLI** — version check + endpoint reachability + secret-file presence status
4. **Install Vietnamese fix for Claude Code CLI** — external repo; warns and requires confirmation before executing third-party code
5. **Claude Code Telegram Bot** -> submenu (install / configure / start / stop / status)
0. **Back**

Config state: `/etc/ops/claude-code.conf` (0640) | API key: `~/.claude-api-key` (0600) | Telegram bot dir: `~/claude-telegram/`

---

### 10. System & Monitoring

Entry: `9) System & Monitoring`

Current implementation (monitoring.sh):

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
14. **Notifications & scheduled checks** → submenu (checks.sh)
15. **Backup helpers** → submenu (backup.sh)
16. **Update OPS from git** — download tarball, syntax check, apply
17. **Refresh capacity profile (re-detect RAM/CPU tier)** — rewrite capacity.conf after VPS resize
0. **Back to main menu**

**Telegram config implementation (chốt):**

- Bot token: `/etc/ops/.telegram-bot-token` (0600, owned by ADMIN_USER) — never printed to terminal
- Chat ID và `TELEGRAM_ENABLED`: lưu trong `/etc/ops/notifications.conf` — đúng theo `ARCHITECTURE.md` và `RUNTIME-ARTEFACT-INVENTORY.md`
- Migration: nếu cũ lưu trong `ops.conf`, `monitoring_setup_telegram()` tự động migrate sang `notifications.conf`


This reference must be kept in sync with the actual menu layout in `bin/ops`.

**Menu contract note:**

- Moi `menu_*` boundary phai `return 0` khi user back hoac khi action ben trong soft-fail.
- Action-level non-zero duoc hap thu boi wrapper menu-local (`_foo_menu_run`), khong propagate len menu cha.
- `bin/ops` goi cac `menu_*` truc tiep; khong con dung `menu_x || true` nhu workaround.
- Interactive menu prompts phai doc qua `/dev/tty` helper path (`core/ui.sh`), khong doc truc tiep tu `stdin` trong TUI loops.

---

### 11. Security Management

The Security Management submenu is accessible from the main menu via **Production Setup Wizard → Security Baseline**, or by running `sudo ops` and navigating to the **Security** module directly (e.g. `sudo ops` → any sub-path that triggers `menu_security`).

Submenu:

1. **Harden SSH config** — apply SSH hardening include (port, password auth, deny root)
2. **Configure UFW firewall** — reconcile UFW to OPS-managed baseline
3. **Install & configure fail2ban** — set up fail2ban with SSH and nginx jails
4. **Show security status** — display SSH port, auth settings, TCP forwarding, ufw/fail2ban state
5. **Change SSH port** — change port with safe transition (old port kept open until verified)
6. **Finalize SSH transition (close old SSH port)** — reconcile sshd config/includes, remove the old port from managed config and UFW, refresh fail2ban, and clear transition state only after SSH, UFW, and fail2ban all apply successfully
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

