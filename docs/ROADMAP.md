## OPS Roadmap & Phases

This document describes the planned phases for OPS and the major tasks in each phase. It helps humans and AI agents know what is in scope now and what is planned for later.

Important contract:

- `ROADMAP.md` is the phase overview.
- `PHASE-01-IMPLEMENTATION-SPEC.md` to `PHASE-04-IMPLEMENTATION-SPEC.md` are the execution source of truth for task IDs, task order, verification, and acceptance.
- If task numbering or ordering differs, the phase implementation spec wins.

Use together with:

- `docs/PHASE-01-IMPLEMENTATION-SPEC.md`
- `docs/PHASE-02-IMPLEMENTATION-SPEC.md`
- `docs/PHASE-03-IMPLEMENTATION-SPEC.md`
- `docs/PHASE-04-IMPLEMENTATION-SPEC.md`
- `docs/RUNBOOKS.md`
- `docs/RUNTIME-ARTEFACT-INVENTORY.md`

### Phase 0 – Legacy 9router VPS kit (cleanup completed)

Status: **Deprecated and removed from active architecture**.

Purpose:

- The old kit informed early docs, but it diverged from the current OPS direction:
  - PM2-only for Node services
  - shared control plane for Node-first + PHP-secondary VPS
  - unified docs-first architecture

Tasks (no active work unless needed):

- Keep any useful knowledge in main `docs/`.
- Do not reintroduce legacy folder-level reference kits that conflict with active architecture.

---

### Phase 1 – Core OPS foundation (current focus)

Goal: Deliver a working OPS stack for Ubuntu 22.04/24.04 with:

- Installer (`curl && bash`).
- Production setup wizard.
- Core menu system.
- Nginx + Node.js LTS + PM2.
- Multi‑PHP (7.4, 8.1, 8.2, 8.3).
- MariaDB (default).
- Certbot SSL.
- Basic monitoring.
- 9router management.
- Codex CLI integration.

High‑level tasks:

1. **Scaffold file structure**
   - Create `bin/`, `install/`, `core/`, `modules/`, `templates/` with minimal skeletons.
   - Wire `ops` entrypoint to a simple main menu stub.

2. **Installer (`install/ops-install.sh`)**
   - OS detection for Ubuntu 22.04/24.04.
   - SSH port + admin user creation with capacity estimation.
   - Clone/extract OPS to `/opt/ops` and run `ops-setup.sh`.

3. **Core & dashboard**
   - Implement `core/env.sh`, `core/ui.sh`, `core/utils.sh`, `core/system.sh`.
   - Implement `bin/ops-dashboard` (login info + “press 1 to open menu”).
   - Implement `bin/ops-setup.sh` (symlinks, login hook, base config).

4. **Production Setup Wizard module**
   - Implement `modules/setup-wizard.sh` orchestrating:
     - Security & firewall.
     - Nginx install + base tuning.
     - Node.js LTS + PM2.
     - PHP‑FPM multi‑version support.
     - MariaDB (default) install + secure setup.
     - Logging & basic monitoring.

5. **Feature modules**
   - `modules/nginx.sh` – vhost and global config management.
   - `modules/node.sh` – Node services / PM2 integration.
   - `modules/nine-router.sh` – 9router install and control.
   - `modules/php.sh` – PHP‑FPM (7.4, 8.1, 8.2, 8.3).
   - `modules/database.sh` – MariaDB (default).
   - `modules/monitoring.sh` – system overview, service status, quick logs (basic).
   - `modules/codex-cli.sh` – Codex CLI install and config.

6. **SSH finalisation and reboot flow**
   - Implement menu/wizard step offering to:
     - Close port 22.
     - Keep `<NEW_PORT>` open.
     - Reboot with a clear reminder of `ssh -p <NEW_PORT> <ADMIN_USER>@...`.

7. **Docs, rules, and AI integration**
   - Keep `docs/`, `rules/`, and `agents/` in sync with implementation.
   - Provide examples and quick-start sections for end users.
   - Add AI-operational docs:
     - bug triage index
     - source-to-runtime trace
     - known risks patterns
     - platform-agnostic capabilities
     - Node-first porting map

Phase 1 “done” criteria:

- A user on a fresh Ubuntu 22.04/24.04 VPS can:
  - Run the installer one‑liner.
  - Log in with the admin user, see the dashboard, open the menu.
  - Run the production wizard successfully.
  - Create at least one Node service and one PHP site.
  - Install and expose 9router behind Nginx.
  - Obtain SSL via Certbot.

Detailed execution spec:

- `docs/PHASE-01-IMPLEMENTATION-SPEC.md`

---

### Phase 2 – Advanced monitoring and quality of life

Goal: Enhance observability, resilience, and admin UX without bloating the stack.

Potential tasks:

1. **Advanced monitoring options**
   - Add optional install for tools like Netdata or similar.
   - Wire monitoring into the “System & Monitoring” menu.

2. **Alerts and health checks**
   - Lightweight scripts to check CPU/RAM/disk thresholds on cron.
   - Optional notifications (e.g. email/webhook) when thresholds are exceeded.

3. **Improved verification commands**
   - Unified “Verify stack health” menu entry.
   - Deeper checks for Nginx, PHP‑FPM, DB, Node services, 9router.

4. **Backup helpers**
   - Simple menu actions to:
     - Dump MariaDB (default) databases.
     - Archive Nginx and OPS configs.
   - Restore guidance (manual but scripted support where reasonable).

Suggested task groups:

- runtime observation and health signals
- advanced monitoring integration
- alerts, scheduled checks, and thresholds
- unified verify stack
- backup helpers
- optional web controls for Nginx/PHP-secondary
- runtime artefact inventory expansion
- rollback playbooks expansion

Phase 2 is optional and can be scoped per actual needs.

Detailed execution spec:

- `docs/PHASE-02-IMPLEMENTATION-SPEC.md`

Additional Phase 2 docs/ops tasks:

1. **Runtime artefact inventory**
   - Document cron, timer, systemd, and login-hook artefacts once implementation exists.
2. **Unified verify stack**
   - Add one action to verify SSH, Nginx, Node, PHP, DB, SSL, and monitoring paths.
3. **Rollback playbooks**
   - Add concise rollback-first runbooks for SSH, Nginx, Node process manager, PHP-FPM, DB, and firewall changes.
4. **Notifications and checks**
   - Add docs and implementation plan for:
     - website uptime/downtime checks
     - SSL expiry alerts
     - domain expiry alerts
     - Telegram/Email delivery
     - periodic security scan
5. **Advanced web controls**
   - Add docs and implementation plan for:
     - `.htaccess` factory reset (PHP-secondary only)
     - Cloudflare real IP logging
     - custom `X-Powered-By`
     - direct IP access block

---

### Phase 3 – Extensibility and multi-OS support (future)

Goal: Make OPS more portable and flexible.

Ideas (not committed):

- Add support for another Linux distribution (e.g. Debian).
- Create plugin hooks so third-party modules can add menus safely.
- Add templating helpers for more complex app deployments.

Suggested task groups:

- distro abstraction audit
- compatibility matrix and path/service mapping
- plugin hook and loading safety design
- template/rendering abstraction
- migration and compatibility docs

Detailed execution spec:

- `docs/PHASE-03-IMPLEMENTATION-SPEC.md`

Any work in this phase must first update `ARCHITECTURE.md` and rules to account for multi‑OS behaviour.

---

### Phase 4 – Cloud automation and integrations (future)

Long-term ideas:

- Optional integration with cloud APIs (DNS management, snapshots, etc.).
- Deeper Codex CLI integration for automated runbooks.

Suggested task groups:

- provider abstraction audit
- DNS provider abstraction
- snapshot/backup provider abstraction
- Telegram Cloud backup transport
- cloud-aware SSL and domain workflows
- secret and credential handling model
- Codex-assisted runbook automation
- provider support matrix and docs

Detailed execution spec:

- `docs/PHASE-04-IMPLEMENTATION-SPEC.md`

These features should remain optional and not increase the baseline resource footprint significantly.

