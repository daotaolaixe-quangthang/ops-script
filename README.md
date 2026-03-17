## OPS – VPS Production Setup & Webserver Manager

OPS is a Bash-based toolkit that turns a fresh Ubuntu VPS into a production-ready webserver stack (Nginx, multi‑PHP, Node.js + PM2, MySQL/MariaDB, Certbot, security hardening, monitoring, Codex CLI integration) and then provides an interactive TUI menu to manage Node.js apps and 9router.

This README gives a high‑level overview for humans; detailed flows and rules for AI agents live in the `docs/`, `rules/`, and `agents/` folders.

### Goals

- **One‑line install**: `curl -sO <public-url>/ops-install.sh && bash ops-install.sh`
- **Safe, opinionated production defaults** for Ubuntu 22.04/24.04.
- **Menu‑driven operations** for Node.js apps, 9router, domains, SSL, PHP, DB.
- **AI‑friendly structure** so agents can safely extend and maintain the toolkit.

### High‑level responsibilities

- **Installer**: bootstrap OS checks, SSH/user hardening, clone OPS core, wire login dashboard.
- **Production wizard**: first‑time stack setup (security, Nginx, Node/PM2, PHP‑FPM, DB, logging).
- **Menu system**: daily operations (create/manage Node apps, 9router, domains, SSL, PHP, DB, Codex CLI, monitoring).

### Documentation map

- `docs/README.md` – recommended reading order and docs update contract.
- `docs/FLOW-INSTALL.md` – full end-to-end installation and first-time run flow.
- `docs/MENU-REFERENCE.md` – all menus and submenus, in English.
- `docs/ARCHITECTURE.md` – internal structure and module boundaries.
- `docs/SECURITY-RULES.md` – security invariants that must never be broken.
- `docs/PERF-TUNING.md` – RAM/CPU → tuning tables for Nginx, PHP-FPM, DB, Node.
- `docs/BUG-TRIAGE-INDEX.md` – bug triage by impact layer.
- `docs/SOURCE-TO-RUNTIME-TRACE.md` – map from menus/modules to runtime state and rollback.
- `docs/KNOWN-RISKS-PATTERNS.md` – production risk patterns for reviews and bugfixes.
- `docs/RUNBOOKS.md` – rollback-first operational runbooks for risky changes.
- `docs/RUNTIME-ARTEFACT-INVENTORY.md` – expected runtime artefacts and source-of-truth targets.
- `docs/PLATFORM-AGNOSTIC-CAPABILITIES.md` – extracted capabilities independent of stack syntax.
- `docs/PORTING-MAP-NODE-FIRST.md` – how to apply OPS logic to a Node-first production stack with PHP as secondary.
- `docs/DESIGN-PATTERNS-EXTRACTED.md` – reusable control-plane patterns.
- `rules/` – coding & project rules for contributors and AI agents.
- `agents/OPS-AI-GUIDE.md` – how AI agents should work on this project.

Humans and AI agents must **read the relevant docs in `docs/` and `rules/` before writing scripts** to avoid accidental security or performance regressions.

