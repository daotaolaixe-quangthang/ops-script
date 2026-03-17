## OPS Architecture

This document describes the logical architecture of OPS and how files are expected to be organised. AI agents must follow this structure unless the spec is explicitly updated.

> Target OS: **Ubuntu 22.04 / 24.04** only (for now).

### 1. High‑level layers

OPS is split into three layers:

1. **Installer layer** (entrypoint from `curl && bash`)
   - Small, self‑contained script (e.g. `ops-install.sh`) hosted at a public URL.
   - Responsibilities:
     - Detect OS version and basic VPS info (RAM, CPU, disk).
     - Ask for and configure SSH port + non‑root admin user.
     - Clone or extract OPS core to `/opt/ops`.
     - Run `ops-setup.sh` once.
     - Never contains complex business logic; it delegates to core modules.

2. **Core layer** (in `/opt/ops` in production, `ops/` in this repo)
   - Entrypoints:
     - `bin/ops` – main TUI menu.
     - `bin/ops-dashboard` – login dashboard showing system info.
     - `bin/ops-setup.sh` – one‑time post‑clone setup (symlinks, login hook, base config).
   - Shared core code:
     - `core/env.sh` – environment detection (OS, RAM/CPU, paths), global constants.
     - `core/ui.sh` – menu rendering, prompts, colours, confirmation helpers.
     - `core/utils.sh` – safe file writes, backups, logging, idempotence helpers.
     - `core/system.sh` – wrappers around apt, systemctl, ufw, etc.

3. **Module layer** (feature‑oriented scripts)
   - Each module lives under `modules/` and exposes functions that the menu calls:
     - `modules/setup-wizard.sh` – first‑time production wizard.
     - `modules/security.sh` – SSH hardening, firewall, fail2ban.
     - `modules/nginx.sh` – Nginx install, global tuning, vhost management, SSL helpers.
     - `modules/node.sh` – Node.js LTS install, PM2 setup, Node service management.
     - `modules/nine-router.sh` – 9router install, PM2 service, domain integration.
     - `modules/php.sh` – multi‑PHP (7.4, 8.1, 8.2, 8.3) install and PHP‑FPM tuning.
     - `modules/database.sh` – MySQL/MariaDB install, secure setup, tuning, DB/user management.
     - `modules/monitoring.sh` – basic + optional advanced monitoring.
     - `modules/codex-cli.sh` – Codex CLI install and configuration.
   - Modules should be **stateless** where possible, deriving state from:
     - System inspection (systemctl, ps, config files).
     - A small set of config files under `/etc/ops/` (see below).

### 2. Directory layout (in repo)

Expected layout inside this repo under `ops/`:

- `bin/`
  - `ops`
  - `ops-dashboard`
  - `ops-setup.sh`
- `install/`
  - `ops-install.sh` – the script referenced in `curl && bash`.
- `core/`
  - `env.sh`
  - `ui.sh`
  - `utils.sh`
  - `system.sh`
- `modules/`
  - `setup-wizard.sh`
  - `security.sh`
  - `nginx.sh`
  - `node.sh`
  - `nine-router.sh`
  - `php.sh`
  - `database.sh`
  - `monitoring.sh`
  - `codex-cli.sh`
  - `templates/`
    - `nginx/`
      - `node_vhost.conf.tpl`
      - `php_vhost.conf.tpl`
      - `ssl_snippet.tpl`
      - `default-deny.conf.tpl`
    - `pm2/`
      - `ecosystem.config.js.tpl`
      - `nine-router.ecosystem.config.js.tpl`
- `docs/`
  - (this file and other documentation)
- `rules/`
  - Coding and project rules.
- `agents/`
  - Guides for AI agents working on OPS.

### 3. Runtime paths on the VPS

In production, OPS is expected to use:

- **Core install path**: `/opt/ops`
- **Config path**: `/etc/ops/`
  - `ops.conf` – global config (install version, paths, defaults).
  - `capacity.json` or `.conf` – captured VPS capacity estimate.
  - Module‑specific configs (e.g. `codex-cli.conf`).
- **Log path**:
  - `/var/log/ops/ops.log` – high-level operations log.
  - Module logs as needed (or reuse system logs).

### 3.1 Suggested source-of-truth state layout

To keep the production control plane maintainable, OPS should add explicit state files rather than relying only on system inspection:

- `/etc/ops/ops.conf` - global install and defaults
- `/etc/ops/capacity.conf` or JSON - captured VPS capacity profile
- `/etc/ops/apps/<app>.conf` - Node app manifests
- `/etc/ops/domains/<domain>.conf` - domain to backend mapping
- `/etc/ops/php-sites/<site>.conf` - PHP site metadata
- `/etc/ops/codex-cli.conf` - Codex CLI integration state

If some of these are not implemented in Phase 1, they still remain the target architecture.

### 3.2 Impact layers

Every OPS change should be reasoned about by impact layer:

1. SSH and operator access
2. Nginx, proxy, and TLS
3. Node runtime and PM2
4. PHP runtime and PHP-FPM
5. Database
6. Firewall and fail2ban
7. Monitoring, logs, and login hooks

AI agents must **not** hard-code additional runtime paths without updating this document.

### 4. Responsibilities and boundaries

- **Installer**:
  - May modify SSH config, firewall, create users.
  - Must remain small and auditable.
  - Must not contain complex logic that belongs to modules.

- **Setup wizard module**:
  - Orchestrates first‑time production setup.
  - Delegates to security, nginx, node, php, database, monitoring modules.

- **Per-feature modules**:
  - Own their domain (e.g. PHP, DB, Node) and expose:
    - Functions for wizard orchestration.
    - Functions for menu actions (list, create, edit, remove, status).
  - Should always be able to state:
    - source of truth
    - verify steps
    - rollback minimum

### 5. Compatibility assumptions

- Fresh or lightly customised Ubuntu 22.04 / 24.04 with `systemd`.
- Nginx used as the only public HTTP(S) entrypoint.
- 9router runs locally and is never exposed directly to the public internet.

If future work adds support for other OSes or init systems, update this file first.

