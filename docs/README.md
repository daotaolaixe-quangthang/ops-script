## OPS Docs Index

Muc tieu cua `docs/` la de con nguoi va AI Agent:

- hieu nhanh control plane cua OPS
- viet script production dung impact layer
- triage bug dung source of truth
- giu verify va rollback la contract bat buoc
- co the rut logic loi de port sang stack khac neu can

## Reading Order cho AI Agent

Doc theo thu tu nay truoc khi viet script:

1. `ARCHITECTURE.md`
2. `FLOW-INSTALL.md`
3. `MENU-REFERENCE.md`
4. `SECURITY-RULES.md`
5. `PERF-TUNING.md`
6. `BUG-TRIAGE-INDEX.md`
7. `SOURCE-TO-RUNTIME-TRACE.md`
8. `KNOWN-RISKS-PATTERNS.md`
9. `PHASE-01-IMPLEMENTATION-SPEC.md` when starting implementation
10. `PHASE-02-IMPLEMENTATION-SPEC.md` when preparing post-Phase-1 hardening and observability
11. `PHASE-03-IMPLEMENTATION-SPEC.md` when preparing extensibility or multi-OS work
12. `PHASE-04-IMPLEMENTATION-SPEC.md` when preparing cloud integrations or AI-assisted runbook automation

Neu task la clone logic/control plane:

13. `PLATFORM-AGNOSTIC-CAPABILITIES.md`
14. `PORTING-MAP-NODE-FIRST.md`
15. `DESIGN-PATTERNS-EXTRACTED.md`

## Docs hien co

- `ARCHITECTURE.md`: layer, runtime paths, module boundaries.
- `FLOW-INSTALL.md`: installer va first-time wizard flow.
- `MENU-REFERENCE.md`: menu contract.
- `PERF-TUNING.md`: tuning theo tai nguyen.
- `SECURITY-RULES.md`: invariants khong duoc pha.
- `RUNBOOKS.md`: pre-check, change, verify, rollback cho tac vu production nguy hiem.
- `RUNTIME-ARTEFACT-INVENTORY.md`: inventory runtime artefacts ma OPS tao/quan ly.
- `ROADMAP.md`: phase tasks va backlog.
- `PROMPTS-TEMPLATES.md`: prompt templates.
- `FEATURE-EXPANSION-SPEC.md`: map cac tinh nang mo rong vao phase, menu, state, verify, rollback.
- `BUG-TRIAGE-INDEX.md`: duong vao nhanh khi fix bug.
- `SOURCE-TO-RUNTIME-TRACE.md`: map tu menu/module sang runtime state, service, verify, rollback.
- `KNOWN-RISKS-PATTERNS.md`: mau rui ro lap lai can check khi review/fix.
- `PHASE-01-IMPLEMENTATION-SPEC.md`: task-level implementation spec de code va review Phase 1.
- `PHASE-02-IMPLEMENTATION-SPEC.md`: task-level implementation spec de code va review Phase 2.
- `PHASE-03-IMPLEMENTATION-SPEC.md`: task-level implementation spec de code va review Phase 3.
- `PHASE-04-IMPLEMENTATION-SPEC.md`: task-level implementation spec de code va review Phase 4.
- `PLATFORM-AGNOSTIC-CAPABILITIES.md`: capability loi tach khoi Node/PHP/Nginx syntax.
- `PORTING-MAP-NODE-FIRST.md`: map logic OPS sang Node-first production stack co PHP phu.
- `DESIGN-PATTERNS-EXTRACTED.md`: cac pattern co the copy cho control plane moi.

## Quy uoc cap nhat docs

Rule quan trong:

- `ROADMAP.md` la overview phase va sequencing cap cao.
- `PHASE-01-IMPLEMENTATION-SPEC.md` den `PHASE-04-IMPLEMENTATION-SPEC.md` la source of truth cho:
  - task IDs
  - implementation order
  - verify gates
  - review checklist
  - acceptance logic
- Neu `ROADMAP.md` va phase spec mau thuan nhau, phase spec uu tien.

- Neu them/sua flow chung: cap nhat `ARCHITECTURE.md` hoac `FLOW-INSTALL.md`.
- Neu them/sua menu: cap nhat `MENU-REFERENCE.md`.
- Neu them/sua rule an toan: cap nhat `SECURITY-RULES.md` va `KNOWN-RISKS-PATTERNS.md`.
- Neu thay doi co side effects runtime: cap nhat `SOURCE-TO-RUNTIME-TRACE.md`.
- Neu thay doi lam agent triage khac di: cap nhat `BUG-TRIAGE-INDEX.md`.
- Neu thay doi lam thay doi logic clone/port: cap nhat `PLATFORM-AGNOSTIC-CAPABILITIES.md` va `PORTING-MAP-NODE-FIRST.md`.
- Neu thay doi/add future optional features: cap nhat `FEATURE-EXPANSION-SPEC.md`, phase spec tuong ung, `RUNBOOKS.md`, va `RUNTIME-ARTEFACT-INVENTORY.md` neu co runtime state moi.
- Neu thay doi scope, task order, task IDs, acceptance, hoac implementation sequence cua phase:
  - cap nhat phase spec tuong ung
  - cap nhat `ROADMAP.md` neu overview phase thay doi
