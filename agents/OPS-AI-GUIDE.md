## OPS AI Agent Guide

This guide explains how AI agents should work on the OPS project so that changes stay safe, consistent, and aligned with the agreed architecture.

### 1. Before making any changes

When a task involves the `ops/` directory, AI agents must first read:

- `README.md`
- `docs/ARCHITECTURE.md`
- `docs/FLOW-INSTALL.md`
- `docs/SECURITY-RULES.md`
- `docs/PERF-TUNING.md`
- `rules/PROJECT-RULES.md`
- `rules/BASH-STYLE.md`

Do not skip this step; these documents contain project‑level contracts.

### 2. Default responsibilities

AI agents can be asked to:

- Implement or extend installer and setup scripts.
- Implement core modules and menus as described in the docs.
- Fix bugs or refine security/performance according to rules.
- Extend monitoring, Codex CLI integration, or other optional modules.

AI agents must **not**:

- Weaken security defaults (e.g. opening extra ports, disabling fail2ban) without explicit user instruction and documentation updates.
- Introduce new external dependencies without justifying them and updating docs.

### 3. Working with installer and setup wizard

- Keep `install/ops-install.sh` small; delegate logic to `core/` and `modules/`.
- Ensure flows match `docs/FLOW-INSTALL.md`, including:
  - SSH port change and transition.
  - Non‑root admin user creation.
  - Capacity estimation and storage.
  - Final prompt to close port 22 and reboot.

### 4. Working with modules

- Each module under `modules/` should:
  - Provide well‑named functions for menu actions.
  - Use helpers in `core/env.sh`, `core/ui.sh`, and `core/utils.sh`.
- When adding or updating a module:
  - Keep user prompts in English.
  - Ensure new options appear in `docs/MENU-REFERENCE.md`.
  - Respect security and tuning rules.

### 5. Safety, backups, and testing

- Before modifying critical configs (Nginx, PHP‑FPM, DB, systemd units), always:
  - Create backups.
  - Validate configs before reload (e.g. `nginx -t`).
- Where possible, add or reuse verification commands (e.g. `verify_stack` functions).
- Never print secrets to logs or commit them into the repo.

### 6. Documentation‑driven changes

- For any non‑trivial change:
  - Update or extend docs in `docs/` first (or alongside code) to describe the new behaviour.
  - Only then modify scripts to match the updated spec.
- If a requested change conflicts with existing docs, clarify in the docs and then implement the new direction.

### 7. Coding style

- Follow `rules/BASH-STYLE.md` for all Bash scripts.
- Prefer small, composable functions and avoid deeply nested conditionals.
- Keep comments focused on intent and trade‑offs, not line‑by‑line narration.

### 8. Interaction with other parts of the repo

- OPS is designed to deploy and manage 9router and other Node/PHP apps, but:
  - It should not embed application‑specific logic beyond what is necessary to install and run them.
  - Reuse existing `ops/vps-9router` assets where appropriate, but keep OPS generic and modular.

This guide may be extended as new workflows and tools are added to the project.

