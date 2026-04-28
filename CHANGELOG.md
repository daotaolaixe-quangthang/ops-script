# Changelog

All notable changes to OPS are documented here.

Format: [version] YYYY-MM-DD — short summary
Details: per-section breakdown of additions, changes, fixes.

---

## [0.2.0] - 2026-04-28

### Summary

Production-ready modular TUI toolkit for Ubuntu 22.04/24.04 VPS management.
This release completes Phase 1 (core stack) and Phase 2 (advanced features).

---

### Added

**Core framework**
- `bin/ops` — main TUI dispatcher with `set -euo pipefail`; all `menu_*` boundaries return 0
- `bin/ops-dashboard` — server status dashboard auto-shown on SSH login
- `bin/ops-setup.sh` — one-time post-install setup (symlinks, login hook, base config)
- `core/env.sh` — OS/RAM/CPU detection, VPS tier (S/M/L), global constants
- `core/ui.sh` — menu rendering, prompts, colour helpers, `press_enter`, `confirm`
- `core/utils.sh` — `backup_file`, `ops_conf_set`, `log_info/warn/error`, idempotence helpers
- `core/system.sh` — wrappers for apt, systemctl, ufw, pm2

**Modules**
- `modules/setup-wizard.sh` — orchestrates first-time production stack setup
- `modules/security.sh` — SSH hardening, UFW, fail2ban (`menu_security` via `s` key)
- `modules/nginx.sh` — Nginx mainline install, vhost management, Advanced Web Controls (7 actions)
- `modules/node.sh` — Node.js LTS + PM2, Node service management
- `modules/nine-router.sh` — 9router install/update/link/lifecycle
- `modules/php.sh` — multi-PHP (7.4 / 8.1 / 8.2 / 8.3 via ondrej/php), PHP-FPM pools
- `modules/database.sh` — MariaDB install/secure/tune, DB+user management; `bind-address=127.0.0.1` enforced
- `modules/monitoring.sh` — system overview, service status, Telegram notifications, Netdata opt-in, self-upgrade via tarball
- `modules/checks.sh` — scheduled checks (cron + systemd OnFailure dropins), Telegram alerts per threshold
- `modules/backup.sh` — DB dump (single/all), config archive; `/var/backups/ops/`
- `modules/codex-cli.sh` — Codex CLI install/configure/test
- `modules/ai-agent.sh` — AI Agent Integration umbrella; Claude Code CLI install/configure/test/Vietnamese-fix; Claude Telegram Bot install/configure/start/stop/status

**Nginx templates**
- `node_vhost.conf.tpl`, `php_vhost.conf.tpl`, `static_vhost.conf.tpl`
- `nine-router.vhost.conf.tpl` — SSE proxy; no per-vhost rate limiting (intentional — Cloudflare edge handles it)
- `default-deny.conf.tpl` — `server_name _;` + `return 444`; blocks direct IP access automatically
- `cloudflare-real-ip.conf.tpl`, `custom-powered-by.conf.tpl`

**PM2 templates**
- `ecosystem.config.js.tpl`, `nine-router.ecosystem.config.js.tpl`

**Install**
- `install/ops-install.sh` — one-line curl installer; tarball download (no git on VPS); SSH+UFW+admin-user setup

---

### Architecture decisions

- Install uses GitHub tarball, not git clone — VPS stays git-free
- Self-upgrade (`ops -> 9 -> 16`) uses same tarball mechanism + bash -n syntax check before apply
- Telegram config stored in `/etc/ops/notifications.conf` (TELEGRAM_ENABLED, TELEGRAM_CHAT_ID); token at `/etc/ops/.telegram-bot-token` (0600)
- Claude Code API key stored in `~/.bashrc` of admin user — NOT in `/etc/ops/` (no centralised secret exposure)
- Login hook uses `SSH_CONNECTION` guard (not `SSH_TTY`) in `~/.bash_profile`
- 9router binds `127.0.0.1:20128` only; Nginx is sole public entrypoint
- All `menu_*` functions return 0 at boundary; action functions may return non-zero for soft errors

---

### Security rules enforced

- All secret files `0600` owned by admin user (see RUNTIME-ARTEFACT-INVENTORY.md section 8.0)
- `bind-address = 127.0.0.1` always set for MariaDB; root password at `/etc/ops/.db-root-password` (0600), never printed to terminal
- UFW deny-all inbound by default; only SSH port + 80 + 443 allowed
- 9router secrets auto-generated via `openssl rand` on first install

---

### Known gates at release

| Gate | Status | Notes |
|---|---|---|
| Gate 1: static checks | PASS | shellcheck, syntax |
| Gate 2: shell regression | PASS | local bash regression suite |
| Gate 3: smoke suite | NOT RUN | requires Ubuntu 22.04 VM |
| Gate 4: runtime snapshot | NOT RUN | requires Ubuntu 22.04 VM |

> Gate 3/4 required before claiming production-ready on Ubuntu runtime.

---

*Previous versions (pre-0.2.0): not tracked.*
