## Prompt Templates for OPS AI Work

This document provides ready‑to‑use prompt templates for humans to instruct AI agents when working on OPS. The goal is to ensure agents always have the right context and follow project rules.

When using these templates, replace placeholders like `<TASK>`, `<MODULE>`, `<FILE>` with your specifics.

---

### 1. General “implement a feature” prompt

Use this when you want an AI agent to implement or extend a feature in OPS.

```text
You are working inside the `ops/` folder of the 9router repo.

Goal:
- <Short description of the feature to implement or change, e.g. "Add support in the Node.js Services menu to restart all services at once.">

Context:
- OPS is a Bash-based production setup and management toolkit for Ubuntu 22.04/24.04.
- It manages Nginx, Node.js + PM2, multi-PHP (7.4, 8.1, 8.2, 8.3), MySQL/MariaDB, SSL via Certbot, 9router, Codex CLI, and monitoring.

Before writing any code, read and respect:
- `ops/README.md`
- `ops/docs/ARCHITECTURE.md`
- `ops/docs/FLOW-INSTALL.md`
- `ops/docs/MENU-REFERENCE.md`
- `ops/docs/SECURITY-RULES.md`
- `ops/docs/PERF-TUNING.md`
- `ops/rules/PROJECT-RULES.md`
- `ops/rules/BASH-STYLE.md`

Requirements:
- Implement the feature according to the existing architecture and menus.
- Keep code idempotent and safe; follow Bash style and security rules.
- Update or extend documentation if the behaviour or menu structure changes.

Deliverables:
- Updated Bash scripts and any new files under `ops/`.
- Updated documentation where relevant.
```

---

### 2. Implementing or updating the installer

Use this when working on `install/ops-install.sh` or related installer logic.

```text
Task:
- Implement or update the OPS installer at `ops/install/ops-install.sh`.

Key requirements:
- Match the flow described in `ops/docs/FLOW-INSTALL.md`, especially:
  - OS detection for Ubuntu 22.04/24.04.
  - SSH port change with transition (keep port 22 until final confirmation).
  - Creation of a non-root admin user used for SSH and Node services.
  - Capacity estimation based on RAM and CPU, saved to `/etc/ops`.
  - Cloning or extracting OPS core into `/opt/ops`.
  - Running `ops-setup.sh`.

Constraints:
- Keep the installer small and auditable.
- Do not duplicate logic that belongs in `core/` or `modules/`.
- Do not weaken security defaults defined in `SECURITY-RULES.md`.

Update any relevant docs if behaviour changes.
```

---

### 3. Implementing or updating a module

Use this when working on a specific module such as `modules/node.sh`, `modules/php.sh`, etc.

```text
Task:
- Implement or update the `<MODULE>` module under `ops/modules/<MODULE>.sh`.

Module purpose:
- <Describe purpose, e.g. "Manage Node.js services using PM2, including listing, creating, starting, stopping, restarting, and viewing logs.">

Follow:
- Menu structure in `ops/docs/MENU-REFERENCE.md` for this module.
- Security requirements in `ops/docs/SECURITY-RULES.md`.
- Tuning guidelines in `ops/docs/PERF-TUNING.md` where relevant.
- Bash style rules in `ops/rules/BASH-STYLE.md`.

Requirements:
- Expose clear functions for each menu item.
- Use helpers from `core/env.sh`, `core/ui.sh`, and `core/utils.sh` where appropriate.
- Ensure operations are idempotent and safe to re-run.
- Validate configurations before reloading services (e.g. `nginx -t`).

If you change menu labels or behaviour, update `ops/docs/MENU-REFERENCE.md`.
```

---

### 4. Adding or changing performance tuning

Use this when adjusting how OPS tunes Nginx, PHP-FPM, or DB based on VPS resources.

```text
Task:
- Adjust performance tuning for <component> (e.g. Nginx, PHP-FPM, MySQL/MariaDB).

Steps:
1. First, update `ops/docs/PERF-TUNING.md` to describe the new tuning strategy:
   - Which parameters change per resource tier (S/M/L).
   - Rationale for the new values.
2. Then update the relevant module(s) to implement those rules.

Constraints:
- Do not oversubscribe memory for small VPS instances.
- Keep defaults conservative, optimised for stability and predictable performance.
- Preserve security and reliability; do not trade them for minor performance gains.
```

---

### 5. Working on SSH, firewall, and reboot flow

Use this when touching SSH/port/firewall logic.

```text
Task:
- Implement or adjust SSH port change and firewall/reboot flow as described in `ops/docs/FLOW-INSTALL.md` and `ops/docs/SECURITY-RULES.md`.

Key points:
- New SSH port is user-configurable with a safe default.
- Port 22 and the new port are both open during the setup transition.
- After the stack is verified, offer a clear prompt to close port 22 and reboot.
- The prompt MUST show the exact new port and admin username, e.g.:

  After reboot, you MUST use:
    ssh -p <NEW_PORT> <ADMIN_USER>@<SERVER_IP_OR_HOSTNAME>

Security:
- Never silently re-open old SSH ports.
- Ensure firewall and `sshd_config` stay in sync.
```

---

### 6. Documentation-only updates

Use this when you want an AI agent to refine or extend docs without touching code.

```text
Task:
- Update documentation in `ops/docs/` to better explain <TOPIC> (e.g. "how to use the Node.js Services menu" or "how capacity estimation works").

Constraints:
- Do not change any code.
- Keep language concise and practical.
- Ensure docs stay consistent with `ROADMAP.md`, `ARCHITECTURE.md`, and `MENU-REFERENCE.md`.
```

---

### 7. Bugfix or refactor within OPS

Use this when fixing a bug or refactoring existing code.

```text
Task:
- Fix the following bug or refactor a specific area in OPS:
  <Describe bug / refactor goal>.

Context:
- Show the current behaviour and the expected correct behaviour.
- Point to the relevant files under `ops/`.

Constraints:
- Preserve all security and performance rules.
- Do not change menu labels unless explicitly required.
- Keep changes as small and focused as possible.
- If the change affects documented behaviour, update the relevant docs.
```

These templates are starting points. When in doubt, include more context (links to specific files, snippets, or prior decisions) so the AI agent can act accurately and safely.

