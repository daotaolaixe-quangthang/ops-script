# OPS Roadmap & Phases

Phase overview — mục tiêu, entry conditions, và "done" criteria mỗi phase.

**Contract:** `ROADMAP.md` là overview cấp cao. Các `docs/dev/PHASE-0x-IMPLEMENTATION-SPEC.md` là source of truth cho task IDs, thứ tự, verify, và acceptance. Khi xung đột, phase spec thắng.

---

## Phase 0 - Legacy provider VPS kit

Status: **Deprecated — removed from active architecture.**

Legacy kit đã inform early docs nhưng diverge khỏi OPS direction:
- PM2-only for Node services
- shared control plane Node-first + PHP-secondary
- unified docs-first architecture

Không có active work. Không reintroduce legacy folder-level kits.

---

## Phase 1 — Core OPS Foundation

Status: **Implemented.** Gate 1 (static) + Gate 2 (shell regression) PASS. Gate 3/4 (Ubuntu runtime) chưa chạy.

Goal: VPS production stack trên Ubuntu 22.04/24.04 với:
- Installer (`curl && bash`)
- Production setup wizard
- Core menu system
- Nginx + Node.js LTS + PM2
- Multi-PHP (7.4, 8.1, 8.2, 8.3)
- MariaDB (default)
- Certbot SSL
- Basic monitoring
- CLIProxyAPI management
- Codex CLI + Claude Code CLI integration

"Done" criteria:
- Fresh Ubuntu 22.04/24.04 VPS: chạy installer one-liner, login admin user, thấy dashboard, mở menu.
- Chạy production wizard thành công.
- Tạo được Node service và PHP site.
- Install và expose CLIProxyAPI qua Nginx.
- Cấp SSL qua Certbot.

Detailed spec: `docs/dev/PHASE-01-IMPLEMENTATION-SPEC.md`

---

## Phase 2 — Advanced Monitoring and Quality of Life

Status: **Implemented.** Acceptance report chưa có (cần Ubuntu runtime).

Goal: Observability, resilience, admin UX không bloat stack.

Deliverables (P2-01 đến P2-09):
- P2-02: Advanced monitoring opt-in (Netdata)
- P2-03: Scheduled checks + Telegram alerts (cron + systemd OnFailure)
- P2-04: Unified verify stack với exit code contract
- P2-05: Backup helpers (DB dump + config archive)
- P2-06: Runtime artefact inventory expansion
- P2-07: Rollback playbooks expansion
- P2-08: Phase acceptance and docs sync
- P2-09: Advanced web controls (Cloudflare real IP, X-Powered-By, IP restrict)

Detailed spec: `docs/dev/PHASE-02-IMPLEMENTATION-SPEC.md`

---

## Phase 3 — Production Stability on Ubuntu 22.04

Status: **Not started.** Entry condition: Phase 1+2 stable, co Ubuntu 22.04 VPS that de chay acceptance tests.

Goal: dam bao OPS chay on dinh tren Ubuntu 22.04 production that, khong mo rong distro.

Deliverables:
- P3-01: Ubuntu 22.04 production runtime verification
- P3-02: Production hardening fixes
- P3-03: Template/rendering abstraction (giam duplicate, khong them framework)
- P3-04: Phase acceptance and docs sync

Khong bao gom: multi-OS support, plugin hooks, cloud integrations.

Bất kỳ work nào trong phase này phải update `docs/reference/ARCHITECTURE.md` trước.

Detailed spec: `docs/dev/PHASE-03-IMPLEMENTATION-SPEC.md`

---

## Phase 4 — Cloud Automation and Integrations

Status: **Not started.** Entry condition: Phase 1+2 stable, Phase 3 có abstraction đủ, nhu cầu thực tế.

Ideas:
- DNS provider abstraction (Cloudflare first).
- Snapshot/backup provider abstraction.
- Telegram Cloud backup transport.
- Codex-assisted runbook automation.

Task groups: provider abstraction audit, DNS provider, snapshot/backup, cloud-aware SSL, secret handling model, Codex runbook design, provider support matrix.

Features phải optional; không tăng baseline resource footprint.

Detailed spec: `docs/dev/PHASE-04-IMPLEMENTATION-SPEC.md`
