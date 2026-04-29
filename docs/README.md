# OPS Docs

Three tiers. Read the right tier for your task.

---

## Tier 1 — operator/

For human operators managing a live VPS. Day-to-day reference.

| File | Purpose |
|---|---|
| [FLOW-INSTALL.md](operator/FLOW-INSTALL.md) | Installer flow and first-time wizard |
| [MENU-REFERENCE.md](operator/MENU-REFERENCE.md) | Every menu option with contract and notes |
| [RUNBOOKS.md](operator/RUNBOOKS.md) | Pre-check -> change -> verify -> rollback for risky operations |
| [SECURITY-RULES.md](operator/SECURITY-RULES.md) | Invariants that must never be broken |

**Also see:** `USER_GUIDE.md` at repo root for the full end-user guide.

---

## Tier 2 — reference/

For AI agents and maintainers writing or reviewing code. Authority sources.

| File | Purpose |
|---|---|
| [ARCHITECTURE.md](reference/ARCHITECTURE.md) | Layer model, directory layout, runtime paths, module boundaries |
| [RUNTIME-ARTEFACT-INVENTORY.md](reference/RUNTIME-ARTEFACT-INVENTORY.md) | Every runtime file OPS creates: path, permission, verify, rollback |
| [SOURCE-TO-RUNTIME-TRACE.md](reference/SOURCE-TO-RUNTIME-TRACE.md) | Menu/module -> runtime state -> service -> verify -> rollback map |
| [KNOWN-RISKS-PATTERNS.md](reference/KNOWN-RISKS-PATTERNS.md) | Recurring risk patterns — check before any review or fix |
| [BUG-TRIAGE-INDEX.md](reference/BUG-TRIAGE-INDEX.md) | Fast entry points for bug triage by symptom |
| [PERF-TUNING.md](reference/PERF-TUNING.md) | Tier S/M/L tuning decisions and thresholds |
| [CLI-PROXY-API-SPEC.md](reference/CLI-PROXY-API-SPEC.md) | CLIProxyAPI install, `config.yaml`, systemd, Nginx vhost, secrets, verify, rollback |
| [CODEX-CLI-SPEC.md](reference/CODEX-CLI-SPEC.md) | Codex CLI install, configure (CLIProxyAPI mode), secrets, menu actions |
| [CLAUDE-CODE-SPEC.md](reference/CLAUDE-CODE-SPEC.md) | Claude Code CLI, Vietnamese fix, Telegram bot, config paths, security, rollback |
| [TEST-CASES.md](reference/TEST-CASES.md) | Regression test cases, smoke suite, acceptance gates |

### Reading order for AI agents writing or maintaining code

1. `reference/ARCHITECTURE.md`
2. `operator/FLOW-INSTALL.md`
3. `operator/MENU-REFERENCE.md`
4. `operator/SECURITY-RULES.md`
5. `reference/PERF-TUNING.md`
6. `reference/BUG-TRIAGE-INDEX.md`
7. `reference/SOURCE-TO-RUNTIME-TRACE.md`
8. `reference/KNOWN-RISKS-PATTERNS.md`
9. `dev/CODE-SKELETON-GUIDE.md` — read before writing any module

Then the relevant spec for the task:
- CLIProxyAPI work: `reference/CLI-PROXY-API-SPEC.md`
- Codex CLI: `reference/CODEX-CLI-SPEC.md`
- Claude Code CLI / Telegram bot: `reference/CLAUDE-CODE-SPEC.md`

---

## Tier 3 — dev/

Production-freeze maintainer notes. Keep this tier minimal.
Read it only when editing scripts in the current stable line.

| File | Purpose |
|---|---|
| [CODE-SKELETON-GUIDE.md](dev/CODE-SKELETON-GUIDE.md) | Current Bash/module authoring guide for safe bugfixes and maintenance |

---

## Doc update rules

- Flow or architecture change -> update `reference/ARCHITECTURE.md` or `operator/FLOW-INSTALL.md`
- Menu change -> update `operator/MENU-REFERENCE.md`
- Security rule change -> update `operator/SECURITY-RULES.md` and `reference/KNOWN-RISKS-PATTERNS.md`
- Tuning logic change -> update `reference/PERF-TUNING.md`
- Runtime side-effect -> update `reference/SOURCE-TO-RUNTIME-TRACE.md`
- New runtime artefact -> update `reference/RUNTIME-ARTEFACT-INVENTORY.md`
- Bug triage path change -> update `reference/BUG-TRIAGE-INDEX.md`
- Verify/regression/smoke change -> update `reference/TEST-CASES.md`
- New module spec -> add to `reference/`, add row to this README
- Chi them file moi vao `dev/` neu thuc su can cho bugfix/maintenance cua stable line
