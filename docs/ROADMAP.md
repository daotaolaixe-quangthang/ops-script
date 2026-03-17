## OPS Roadmap & Phases

This document describes the planned phases for OPS and the major tasks in each phase. It helps humans and AI agents know what is in scope now and what is planned for later.

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
- MySQL/MariaDB.
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
     - MySQL/MariaDB install + secure setup.
     - Logging & basic monitoring.

5. **Feature modules**
   - `modules/nginx.sh` – vhost and global config management.
   - `modules/node.sh` – Node services / PM2 integration.
   - `modules/nine-router.sh` – 9router install and control.
   - `modules/php.sh` – PHP‑FPM (7.4, 8.1, 8.2, 8.3).
   - `modules/database.sh` – MySQL/MariaDB.
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
     - Dump MySQL/MariaDB databases.
     - Archive Nginx and OPS configs.
   - Restore guidance (manual but scripted support where reasonable).

Phase 2 is optional and can be scoped per actual needs.

Additional Phase 2 docs/ops tasks:

1. **Runtime artefact inventory**
   - Document cron, timer, systemd, and login-hook artefacts once implementation exists.
2. **Unified verify stack**
   - Add one action to verify SSH, Nginx, Node, PHP, DB, SSL, and monitoring paths.
3. **Rollback playbooks**
   - Add concise rollback-first runbooks for SSH, Nginx, Node process manager, PHP-FPM, DB, and firewall changes.

---

### Phase 3 – Extensibility and multi‑OS support (future)

Goal: Make OPS more portable and flexible.

Ideas (not committed):

- Add support for another Linux distribution (e.g. Debian).
- Create plugin hooks so third‑party modules can add menus safely.
- Add templating helpers for more complex app deployments.

Any work in this phase must first update `ARCHITECTURE.md` and rules to account for multi‑OS behaviour.

---

### Phase 4 – Cloud automation and integrations (future)

Long‑term ideas:

- Optional integration with cloud APIs (DNS management, snapshots, etc.).
- Deeper Codex CLI integration for automated runbooks.

These features should remain optional and not increase the baseline resource footprint significantly.

