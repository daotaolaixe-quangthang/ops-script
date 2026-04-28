Release / Change ID: P1-13 end-to-end verification and docs sync
Date: 2026-04-28
Reviewer / Tester: Codex
Environment:
- Ubuntu version: not executed in this pass
- VM snapshot id: not executed in this pass
- OPS branch/commit: 2f9efb99d96e08547e93a0bce9ec444e8486002f
- Host execution context: Windows + WSL Bash for static/contract regression only

Scope changed:
- files/modules: `docs/RUNBOOKS.md`, `docs/TEST-CASES.md`, `ops/tests/regression/tui-suite.sh`, `ops/tests/regression/reg-suite.sh`
- impact layers: TUI, regression harness, security contracts, installer contracts, web/node/php/db/9router/monitoring/file contract coverage, docs sync

Executed gates:
- Gate 1 Static: PASS
- Gate 2 Shell regression: PASS
- Gate 3 Smoke suite: FAIL
- Gate 4 Runtime acceptance: FAIL

Executed test IDs:
- TUI-01..TUI-10 : PASS
- REG-01..REG-15 : PASS
- SEC-01..SEC-09 : PASS
- INS-01..INS-09 : PASS
- WEB-01..WEB-10 : PASS
- NODE-01..NODE-10 : PASS
- PHP-01..PHP-06 : PASS
- DB-01..DB-06 : PASS
- NINE-01..NINE-08 : PASS
- MON-01..MON-05 : PASS
- FILE-01..FILE-04 : PASS

Evidence:
- commands run:
  - `bash -n /mnt/e/2WEBApp/ops-script/ops/tests/regression/tui-suite.sh`
  - `bash -n /mnt/e/2WEBApp/ops-script/ops/tests/regression/reg-suite.sh`
  - `bash -n /mnt/e/2WEBApp/ops-script/ops/tests/regression/run-all.sh`
  - `cd /mnt/e/2WEBApp/ops-script && bash ops/tests/regression/run-all.sh`
- key output summary:
  - `tui-suite`: 10 total, 10 passed, 0 failed
  - `reg-suite`: 82 total, 82 passed, 0 failed
  - `run-all.sh`: `[PASS] All regression suites passed`
- runtime files checked:
  - `.ops-test-reports/tui-suite.report.txt`
  - `.ops-test-reports/reg-suite.report.txt`
  - `docs/RUNBOOKS.md`
  - `docs/TEST-CASES.md`
- services checked:
  - none in this pass; no Ubuntu runtime target was exercised

Rollback checked:
- yes/no: yes
- minimum rollback path:
  - backups created in `.codex-backups/20260428-114928/`
  - restore affected files from that backup set if needed

Decision:
- BLOCKED

Blocking issues:
- Gate 3 module smoke/integration suite has not been executed on an Ubuntu 22.04/24.04 OPS target.
- Gate 4 full runtime acceptance line from Phase 1 spec has not been executed: installer, wizard, sample Node deploy, sample PHP deploy, 9router, SSL, SSH finalisation.

Notes:
- This report closes the shell-level and docs-sync portion of P1-13.
- Required next step to mark full Phase 1 acceptance `APPROVED`: run the Phase 1 smoke/runtime gate on a fresh Ubuntu snapshot and append PASS/FAIL evidence for the runtime steps above.
