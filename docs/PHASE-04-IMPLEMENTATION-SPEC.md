## OPS Phase 4 Implementation Spec

Muc tieu: bien `Phase 4` thanh spec cho cac integration dai han, giu chung o vai tro optional va khong pha tinh gon nhe cua OPS.

Phase 4 tap trung vao:

- cloud API integrations co kiem soat
- snapshot/backup provider integrations
- cloud-aware DNS, domain, SSL workflows
- Codex-assisted runbook automation

Khong bao gom trong Phase 4:

- bien OPS thanh managed SaaS platform
- agent tu dong thao tac production khong co gate
- multi-tenant orchestration
- secret sync khong co inventory/rotation model
- plugin marketplace rong mo

---

## 1) Phase 4 entry conditions

Chi nen bat dau Phase 4 khi:

1. `Phase 1` va `Phase 2` da on dinh tren runtime that.
2. `Phase 3` da co abstraction du de tach cloud provider logic va integration hooks.
3. Da co nhu cau thuc te cho:
   - DNS automation
   - snapshot APIs
   - certificate/domain workflows co provider awareness
   - Codex-assisted runbooks
4. Da chot ro safety model:
   - secret storage
   - opt-in prompts
   - audit logging
   - rollback expectations

Neu chua co 4 dieu kien nay, Phase 4 rat de tro thanh integration-heavy nhung kho maintain.

---

## 2) Phase 4 architecture contract

Tat ca implementers phai coi nhung diem sau la fixed contract:

1. Moi cloud integration phai la optional.
2. Core OPS van phai hoat dong duoc khi khong bat ky cloud provider nao.
3. Secrets cho cloud integrations phai co source-of-truth va permission model ro rang.
4. Bat ky action nao co the thay doi ha tang tu xa phai:
   - explain side effects
   - require explicit opt-in
   - log operation
   - define rollback toi thieu
5. Codex-assisted automation khong duoc tu y vuot qua human approval boundaries neu action la high-impact.
6. Cloud-specific logic phai nam o layer/module rieng, khong duoc ro ri vao core layer.
7. Moi provider support phai co support policy:
   - supported
   - experimental
   - not supported

---

## 3) Phase 4 deliverables

### A. Cloud provider abstraction

- provider contract docs
- DNS provider abstraction
- snapshot/backup provider abstraction
- credential/state layout cho providers

### B. Cloud-aware app/domain workflows

- DNS create/update/remove helpers
- cloud-aware SSL/domain verification helpers
- optional provider-assisted bootstrap flows

### C. Snapshot and backup provider integration

- provider snapshot create/list/delete hooks
- retention policy docs
- rollback expectations docs

### D. Codex-assisted runbook automation

- machine-readable runbook inputs/outputs
- guardrails cho auto-suggested actions
- approval checkpoints cho high-impact flows

### E. Integration docs and support matrix

- provider support matrix
- provider setup guides
- secret rotation notes
- failure and rollback notes

---

## 4) Implementation order trong Phase 4

Lam theo thu tu nay:

1. `P4-01` provider abstraction audit
2. `P4-02` DNS provider abstraction
3. `P4-03` snapshot/backup provider abstraction
4. `P4-04` cloud-aware SSL and domain workflows
5. `P4-05` secret and credential handling model
6. `P4-06` Codex-assisted runbook automation design
7. `P4-07` provider support matrix and docs
8. `P4-08` phase acceptance and docs sync

Ly do:

- phai chot abstraction provider truoc khi viet flow cu the
- secret model phai ro truoc khi support provider that
- Codex automation phai dua tren runbook contract va provider state da ro

---

## 5) Detailed tasks

### P4-01 Provider abstraction audit

**Muc tieu**

- xac dinh ranh gioi giua core OPS va provider-specific logic

**Tasks**

1. audit cac use cases can provider support:
   - DNS records
   - snapshots
   - provider-aware SSL/domain checks
2. xac dinh abstraction points:
   - auth
   - list resources
   - create/update/delete
   - rollback hints
3. xac dinh phan nao can remain manual

**Output**

- provider abstraction note lam co so cho cac task tiep theo

**Verify**

- moi provider workflow co the map ve 1 contract chung

**Review checklist**

- khong cho provider logic ro ri vao core modules
- abstraction khong qua ly thuyet

---

### P4-02 DNS provider abstraction

**Muc tieu**

- support DNS automation theo provider contract

**Tasks**

1. define DNS provider contract:
   - auth
   - list zones
   - create/update/delete record
   - propagation check note
2. xac dinh provider dau tien neu co:
   - vi du Cloudflare
3. map domain workflows cua OPS vao DNS actions
4. document source-of-truth cho DNS state va provider config

**Output**

- DNS abstraction docs
- target module design cho provider-specific implementations

**Verify**

- 1 domain flow co the mo ta ro:
   - create record
   - verify propagation note
   - rollback record

**Review checklist**

- DNS automation la opt-in
- rollback xoa/sua record ro rang

---

### P4-03 Snapshot and backup provider abstraction

**Muc tieu**

- support provider-based backup/snapshot hooks ma khong pha backup helpers local

**Tasks**

1. define snapshot provider contract:
   - auth
   - list snapshots
   - create snapshot
   - delete snapshot
   - retention note
2. define relation giua snapshot provider va local backup helpers
3. document restore expectations:
   - OPS co the trigger create/list
   - restore co the van can manual approvals

**Output**

- snapshot/backup provider docs

**Verify**

- 1 snapshot workflow co the mo ta du:
   - trigger
   - identify result
   - rollback/cleanup

**Review checklist**

- khong tao ao tuong "1-click disaster recovery" neu thuc te khong dam bao

---

### P4-04 Cloud-aware SSL and domain workflows

**Muc tieu**

- bo sung cloud-aware logic cho SSL/domain khi provider co the anh huong challenge/validation path

**Tasks**

1. document provider-aware SSL concerns:
   - proxied DNS
   - strict/full modes
   - origin cert vs public cert paths
2. xac dinh when OPS can help:
   - pre-check warnings
   - DNS/provider hints
   - post-check verification
3. map rollback notes khi cloud-side settings can revert

**Output**

- SSL/domain cloud-aware docs

**Verify**

- co the phan biet ro:
   - local Nginx/Certbot issue
   - provider DNS/proxy issue

**Review checklist**

- docs khong lam user nham cloud layer voi host layer

---

### P4-05 Secret and credential handling model

**Muc tieu**

- chot model luu, phan quyen, rotate secrets cho integrations

**Tasks**

1. xac dinh config paths cho provider creds
2. xac dinh permission model
3. xac dinh log redaction rules
4. xac dinh rotation/update workflow
5. xac dinh docs requirements:
   - khong ghi secret literal
   - chi ghi location va ownership

**Output**

- provider credential handling docs

**Verify**

- moi integration support deu co secret location ro va permission model ro

**Review checklist**

- khong leak secrets qua logs/docs
- rotation co step ro rang

---

### P4-06 Codex-assisted runbook automation design

**Muc tieu**

- cho Codex co the huong dan hoac tao de xuat automation dua tren runbooks, nhung van co guardrails

**Tasks**

1. define machine-readable runbook shape:
   - inputs
   - pre-checks
   - actions
   - verify
   - rollback
2. classify action risk:
   - low
   - medium
   - high
3. define approval gates:
   - low-risk can suggest
   - high-risk phai can explicit human confirm
4. define audit/logging expectations cho AI-assisted actions

**Output**

- Codex-assisted automation design docs

**Verify**

- 1 runbook co the duoc chuyen thanh auto-suggestable flow ma van co approval boundary

**Review checklist**

- AI khong duoc tro thanh hidden operator
- human approval boundaries ro rang

---

### P4-07 Provider support matrix and docs

**Muc tieu**

- chuan hoa support matrix cho providers va integrations

**Tasks**

1. tao support matrix:
   - provider
   - feature set
   - support level
   - tested status
2. tao docs setup provider
3. tao docs failure modes va rollback notes

**Output**

- provider support docs

**Verify**

- maintainer va AI Agent co the nhin matrix de biet provider nao support that

**Review checklist**

- khong danh dau supported neu chua test
- supported / experimental / planned tach ro

---

### P4-08 Phase acceptance and docs sync

**Muc tieu**

- chot Phase 4 bang docs va support model ro rang

**Tasks**

1. review abstraction boundaries
2. review provider secret handling
3. review runbook automation guardrails
4. review provider support matrix
5. cap nhat docs index/roadmap/AI guide neu can

**Output**

- Phase 4 acceptance report

**Verify**

- integration scope van optional, co guardrails, va khong pha core OPS

**Review checklist**

- Phase 4 khong bien OPS thanh cloud control panel nang
- khong mo duong high-impact automation khong approval

---

## 6) Phase 4 test strategy

### Test levels

1. **Contract tests**
   - provider abstraction co du ro de implement khong
2. **Secret handling tests**
   - permission, path, redaction expectations
3. **Workflow simulation**
   - DNS/snapshot/runbook flows co verify/rollback ro khong
4. **Support matrix review**
   - supported vs experimental vs planned co tach ro khong

### Minimum pass gate cho moi task

Moi task chi duoc xem la xong khi co:

- docs/spec ro
- security/secret model ro
- verify path ro
- rollback/cleanup path ro
- optionality duoc giu nguyen

---

## 7) Cach review Phase 4

Khi review phase, dung form nay:

1. Integration nay co gia tri van hanh that hay chi "co the co"?
2. Core OPS co van hoat dong khi bo integration nay khong?
3. Secrets va approvals co du ro khong?
4. Rollback co kha thi khi cloud-side state thay doi khong?
5. AI automation co bi vuot qua human approval boundary khong?
6. Co dang day OPS thanh cloud control plane qua nang khong?

---

## 8) Suggested working mode

Phase 4 nen bat dau bang docs-first rat chat:

1. provider audit
2. contract docs
3. security/secret docs
4. review
5. moi code provider dau tien

Thu tu khuyen nghi:

1. `P4-01`
2. `P4-05`
3. `P4-02`
4. `P4-03`
5. `P4-04`
6. `P4-06`
7. `P4-07`
8. `P4-08`

Ly do:

- provider va secret model phai ro truoc khi code integration
