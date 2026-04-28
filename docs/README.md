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
| [PERF-TUNING.md](operator/PERF-TUNING.md) | Tier S/M/L tuning decisions and thresholds |
| [TEST-CASES.md](operator/TEST-CASES.md) | Regression test cases, smoke suite, acceptance gates |

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
| [NINE-ROUTER-SPEC.md](reference/NINE-ROUTER-SPEC.md) | 9router install, env, PM2, Nginx vhost, secrets, verify, rollback |
| [CODEX-CLI-SPEC.md](reference/CODEX-CLI-SPEC.md) | Codex CLI install, configure (9router mode), secrets, menu actions |
| [CLAUDE-CODE-SPEC.md](reference/CLAUDE-CODE-SPEC.md) | Claude Code CLI, Vietnamese fix, Telegram bot, config paths, security, rollback |
| [FEATURE-EXPANSION-SPEC.md](reference/FEATURE-EXPANSION-SPEC.md) | Feature extension map: phase, menu, state, verify, rollback |

### Reading order for AI agents writing or maintaining code

1. `reference/ARCHITECTURE.md`
2. `operator/FLOW-INSTALL.md`
3. `operator/MENU-REFERENCE.md`
4. `operator/SECURITY-RULES.md`
5. `operator/PERF-TUNING.md`
6. `reference/BUG-TRIAGE-INDEX.md`
7. `reference/SOURCE-TO-RUNTIME-TRACE.md`
8. `reference/KNOWN-RISKS-PATTERNS.md`
9. `dev/CODE-SKELETON-GUIDE.md` — read before writing any module

Then the relevant spec for the task:
- 9router work: `reference/NINE-ROUTER-SPEC.md`
- Codex CLI: `reference/CODEX-CLI-SPEC.md`
- Claude Code CLI / Telegram bot: `reference/CLAUDE-CODE-SPEC.md`
- Phase implementation: `dev/PHASE-0N-IMPLEMENTATION-SPEC.md`

---

## Tier 3 — dev/

Build-phase specs, AI agent prompts, porting guides, design patterns.
Read when building a new phase or porting OPS to another stack.

| File | Purpose |
|---|---|
| [PHASE-01-IMPLEMENTATION-SPEC.md](dev/PHASE-01-IMPLEMENTATION-SPEC.md) | Phase 1 task spec (core stack) — includes technology decisions |
| [PHASE-02-IMPLEMENTATION-SPEC.md](dev/PHASE-02-IMPLEMENTATION-SPEC.md) | Phase 2 task spec (hardening + observability) |
| [PHASE-03-IMPLEMENTATION-SPEC.md](dev/PHASE-03-IMPLEMENTATION-SPEC.md) | Phase 3 task spec (extensibility, multi-OS prep) |
| [PHASE-04-IMPLEMENTATION-SPEC.md](dev/PHASE-04-IMPLEMENTATION-SPEC.md) | Phase 4 task spec (cloud integrations, AI-assisted runbooks) |
| [CODE-SKELETON-GUIDE.md](dev/CODE-SKELETON-GUIDE.md) | Skeleton code, module pattern, convention cheat sheet |
| [DESIGN-PATTERNS-EXTRACTED.md](dev/DESIGN-PATTERNS-EXTRACTED.md) | Reusable patterns for any new control plane |
| [PLATFORM-AGNOSTIC-CAPABILITIES.md](dev/PLATFORM-AGNOSTIC-CAPABILITIES.md) | Capabilities abstracted from Node/PHP/Nginx syntax |
| [PORTING-MAP-NODE-FIRST.md](dev/PORTING-MAP-NODE-FIRST.md) | Map OPS logic to Node-first production stack |
| [PROMPTS-TEMPLATES.md](dev/PROMPTS-TEMPLATES.md) | Prompt templates for AI agent task execution |
| [PROMPTS-TASK-EXECUTION.md](dev/PROMPTS-TASK-EXECUTION.md) | Task execution prompt patterns |
| [ROADMAP.md](dev/ROADMAP.md) | High-level phase overview and backlog |
| [TASK-CHECKLIST.md](dev/TASK-CHECKLIST.md) | Build-phase task checklist (Phase 1+2) |

---

## Doc update rules

- Flow or architecture change -> update `reference/ARCHITECTURE.md` or `operator/FLOW-INSTALL.md`
- Menu change -> update `operator/MENU-REFERENCE.md`
- Security rule change -> update `operator/SECURITY-RULES.md` and `reference/KNOWN-RISKS-PATTERNS.md`
- Runtime side-effect -> update `reference/SOURCE-TO-RUNTIME-TRACE.md`
- New runtime artefact -> update `reference/RUNTIME-ARTEFACT-INVENTORY.md`
- Bug triage path change -> update `reference/BUG-TRIAGE-INDEX.md`
- Verify/regression/smoke change -> update `operator/TEST-CASES.md`
- Phase task, order, acceptance change -> update `dev/PHASE-0N-IMPLEMENTATION-SPEC.md`, then `dev/ROADMAP.md`
- New module spec -> add to `reference/`, add row to this README

If `dev/ROADMAP.md` and a phase spec conflict, the phase spec wins.
