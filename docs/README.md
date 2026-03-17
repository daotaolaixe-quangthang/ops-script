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

Neu task la clone logic/control plane:

9. `PLATFORM-AGNOSTIC-CAPABILITIES.md`
10. `PORTING-MAP-NODE-FIRST.md`
11. `DESIGN-PATTERNS-EXTRACTED.md`

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
- `BUG-TRIAGE-INDEX.md`: duong vao nhanh khi fix bug.
- `SOURCE-TO-RUNTIME-TRACE.md`: map tu menu/module sang runtime state, service, verify, rollback.
- `KNOWN-RISKS-PATTERNS.md`: mau rui ro lap lai can check khi review/fix.
- `RUNBOOKS.md`: runbooks production.
- `RUNTIME-ARTEFACT-INVENTORY.md`: expected runtime artefacts and source-of-truth targets.
- `PLATFORM-AGNOSTIC-CAPABILITIES.md`: capability loi tach khoi Node/PHP/Nginx syntax.
- `PORTING-MAP-NODE-FIRST.md`: map logic OPS sang Node-first production stack co PHP phu.
- `DESIGN-PATTERNS-EXTRACTED.md`: cac pattern co the copy cho control plane moi.

## Quy uoc cap nhat docs

- Neu them/sua flow chung: cap nhat `ARCHITECTURE.md` hoac `FLOW-INSTALL.md`.
- Neu them/sua menu: cap nhat `MENU-REFERENCE.md`.
- Neu them/sua rule an toan: cap nhat `SECURITY-RULES.md` va `KNOWN-RISKS-PATTERNS.md`.
- Neu thay doi co side effects runtime: cap nhat `SOURCE-TO-RUNTIME-TRACE.md`.
- Neu thay doi lam agent triage khac di: cap nhat `BUG-TRIAGE-INDEX.md`.
- Neu thay doi lam thay doi logic clone/port: cap nhat `PLATFORM-AGNOSTIC-CAPABILITIES.md` va `PORTING-MAP-NODE-FIRST.md`.
