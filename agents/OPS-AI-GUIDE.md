# OPS AI Agent Guide

This guide explains how AI agents should work on the OPS project so that changes stay safe, consistent, and aligned with the agreed architecture.

## 1. Before making any changes

When a task involves the `ops/` directory, AI agents must first read:

- `README.md`
- `docs/README.md`
- `docs/reference/ARCHITECTURE.md`
- `docs/operator/FLOW-INSTALL.md`
- `docs/operator/SECURITY-RULES.md`
- `docs/operator/PERF-TUNING.md`
- `docs/reference/BUG-TRIAGE-INDEX.md` when fixing bugs or reviewing risk
- `docs/reference/SOURCE-TO-RUNTIME-TRACE.md` when touching runtime state/configs
- `docs/reference/KNOWN-RISKS-PATTERNS.md` for production-safe changes
- **`docs/dev/CODE-SKELETON-GUIDE.md`** before writing any module — contains coding spine, helpers pattern, convention cheat sheet
- `rules/PROJECT-RULES.md`
- `rules/BASH-STYLE.md`

When the task is implementation planning or execution by phase, also read the corresponding phase spec:

- `docs/dev/PHASE-01-IMPLEMENTATION-SPEC.md` — contains technology decisions (Node method, PHP PPA, Certbot, MariaDB, etc.)
- `docs/dev/PHASE-02-IMPLEMENTATION-SPEC.md`
- `docs/dev/PHASE-03-IMPLEMENTATION-SPEC.md`
- `docs/dev/PHASE-04-IMPLEMENTATION-SPEC.md`

When the task involves **CLIProxyAPI**, **Codex CLI**, or **Claude Code CLI**:

- `docs/reference/CLI-PROXY-API-SPEC.md` - CLIProxyAPI provider spec: release install, `config.yaml`, systemd, Nginx proxy, security contract
- `docs/reference/CODEX-CLI-SPEC.md` - install, configure (CLIProxyAPI mode / API key), menu actions, secret file paths
- `docs/reference/CLAUDE-CODE-SPEC.md` - install, configure, Vietnamese fix, Telegram bot, config paths, security rules, rollback

Do not skip this step; these documents contain project-level contracts.

## 2. Docs directory layout (3 tiers)

```
docs/
  README.md              <- index (read this first)
  operator/              <- human operators, day-to-day reference
  reference/             <- AI agents + maintainers, authority sources
  dev/                   <- build-phase specs, prompts, porting guides
```

When updating docs after a code change, put the file in the correct tier:
- Runtime contract or architecture change -> `reference/`
- Operator-facing flow or security rule -> `operator/`
- Phase spec or dev scaffold -> `dev/`

## 3. Working with installer and setup wizard

- Keep `install/ops-install.sh` small; delegate logic to `core/` and `modules/`.
- Ensure flows match `docs/operator/FLOW-INSTALL.md`, including:
  - SSH port change and transition.
  - Non-root admin user creation.
  - Capacity estimation and storage.
  - Final prompt to close port 22 and reboot.

## 4. Working with modules

- Each module under `modules/` should:
  - Provide well-named functions for menu actions.
  - Use helpers in `core/env.sh`, `core/ui.sh`, and `core/utils.sh`.
- When adding or updating a module:
  - Keep user prompts in English.
  - Ensure new options appear in `docs/operator/MENU-REFERENCE.md`.
  - Respect security and tuning rules.
  - Document impact layer, source of truth, verify steps, and rollback minimum.

## 5. Safety, backups, and testing

- Before modifying critical configs (Nginx, PHP-FPM, DB, systemd units), always:
  - Create backups.
  - Validate configs before reload (e.g. `nginx -t`).
- For Node services, PM2 is the process manager contract. Do not introduce parallel systemd service ownership for Node apps unless the architecture docs are updated first.
- Where possible, add or reuse verification commands (e.g. `verify_stack` functions).
- Never print secrets to logs or commit them into the repo.

## 6. Documentation-driven changes

- For any non-trivial change:
  - Update or extend docs in `docs/` first (or alongside code) to describe the new behaviour.
  - Only then modify scripts to match the updated spec.
- If a requested change conflicts with existing docs, clarify in the docs and then implement the new direction.
- For phase execution:
  - treat `docs/dev/ROADMAP.md` as overview only
  - treat the corresponding `docs/dev/PHASE-0x-IMPLEMENTATION-SPEC.md` as the source of truth for task IDs, order, verify, and acceptance
- If the task is about cloning or porting OPS logic to another stack, also read:
  - `docs/dev/PLATFORM-AGNOSTIC-CAPABILITIES.md`
  - `docs/dev/PORTING-MAP-NODE-FIRST.md`
  - `docs/dev/DESIGN-PATTERNS-EXTRACTED.md`
- If the task touches future optional features such as notifications, external backup transports, or advanced web controls, also read:
  - `docs/reference/FEATURE-EXPANSION-SPEC.md`
  - `docs/operator/RUNBOOKS.md`
  - `docs/reference/RUNTIME-ARTEFACT-INVENTORY.md`

## 7. Coding style

- Follow `rules/BASH-STYLE.md` for all Bash scripts.
- Prefer small, composable functions and avoid deeply nested conditionals.
- Keep comments focused on intent and trade-offs, not line-by-line narration.

## 8. Interaction with other parts of the repo

- OPS is designed to deploy and manage CLIProxyAPI and other Node/PHP apps, but:
  - It should not embed application-specific logic beyond what is necessary to install and run them.
  - Keep OPS generic and modular; legacy folder-specific kits should not become hidden architecture dependencies.

This guide may be extended as new workflows and tools are added to the project.
