## OPS Phase 2 Implementation Spec

Muc tieu: chuyen `Phase 2` tu roadmap thanh spec thuc thi cho nhom nang cao, sau khi `Phase 1` da on dinh va co runtime thuc te de dua vao.

Phase 2 tap trung vao:

- observability tot hon
- health verification thong nhat
- alerts nhe, phu hop VPS
- backup helpers thuc dung
- runtime artefact inventory thuc te
- rollback playbooks sat voi implementation that

Khong bao gom trong Phase 2:

- multi-OS
- plugin architecture
- cloud API automation
- snapshot provider integrations
- full disaster recovery platform

---

## 1) Phase 2 entry conditions

Chi nen bat dau Phase 2 khi:

1. `Phase 1` da pass acceptance line.
2. Co implementation that cua:
   - installer
   - wizard
   - nginx
   - node + PM2
   - php
   - db
   - 9router
3. Co it nhat 1 VPS test hoac staging de thu runtime artefacts that.
4. `RUNBOOKS.md` va `RUNTIME-ARTEFACT-INVENTORY.md` da phan anh toi thieu Phase 1.

Neu chua co 4 dieu kien nay, Phase 2 rat de tro thanh docs/feature du doan.

---

## 2) Phase 2 architecture contract

Tat ca implementers phai coi nhung diem sau la fixed contract:

1. Phase 2 phai nhe, khong bien OPS thanh control panel nang.
2. Monitoring nang cao la opt-in.
3. Alerts mac dinh phai quiet; chi canh bao khi vuot nguong ro rang.
4. Moi verify action phai co dau ra ro, khong mo ho.
5. Backup helpers phai an toan va uu tien export/archive, khong tac dong pha huy.
6. Runtime inventory phai dua tren implementation that, khong suy doan.
7. Rollback playbooks phai map toi file/service/runtime artefact thuc te.

---

## 3) Phase 2 deliverables

### A. Monitoring va health layer

- menu advanced monitoring opt-in
- alerts threshold scripts nhe
- unified verify stack action
- deeper service checks cho Nginx, Node/PM2, PHP-FPM, DB, SSL, 9router

### B. Backup helper layer

- DB dump helpers
- archive helpers cho OPS config, Nginx config, app state manifests
- huong dan restore co script support o muc vua phai

### C. Runtime intelligence docs

- inventory runtime artefacts duoc cap nhat theo implementation that
- rollback runbooks cap nhat theo implementation that
- trace docs duoc cap nhat them cron/timers/logrotate/PM2 startup state neu co

### D. Operator UX improvements

- service status sau hon
- quick logs de dung hon
- verify summary screen co the doc nhanh

---

## 4) Implementation order trong Phase 2

Lam theo thu tu nay:

1. `P2-01` runtime observation audit
2. `P2-02` advanced monitoring integration
3. `P2-03` alerts and thresholds
4. `P2-04` unified verify stack
5. `P2-05` backup helpers
6. `P2-06` runtime artefact inventory expansion
7. `P2-07` rollback playbooks expansion
8. `P2-08` phase acceptance and docs sync

Ly do:

- phai biet runtime that truoc khi viet inventory va playbook
- monitoring va alerts nen di truoc verify UX hop nhat
- backup helpers phai dua tren state/runtime da ro

---

## 5) Detailed tasks

### P2-01 Runtime observation audit

**Muc tieu**

- quan sat implementation Phase 1 tren VPS that de chot artefacts va health signals

**Tasks**

1. liet ke runtime artefacts that:
   - PM2 startup state
   - shell login hooks
   - logrotate files
   - Nginx site files
   - PHP-FPM pool/config files
   - DB config files
   - certbot/SSL files
2. liet ke verify commands co gia tri nhat cho tung layer
3. liet ke rollback points toi thieu cho tung layer

**Output**

- audit note noi bo hoac docs patch de lam co so cho `P2-06`, `P2-07`

**Verify**

- moi runtime artefact duoc truy nguoc ve module/script tao ra no

**Review checklist**

- khong invent artefact khong ton tai
- phan biet ro target architecture va current runtime

---

### P2-02 Advanced monitoring integration

**Muc tieu**

- dua monitoring nang cao thanh option co kiem soat, khong bat buoc

**Tasks**

1. xac dinh stack monitoring nhe du kien:
   - vi du Netdata hoac giai phap tuong duong
2. them menu install/config/remove monitoring nang cao
3. define runtime state:
   - package/service
   - config path
   - service status
4. add docs and verify flow

**Output**

- co the opt-in monitoring nang cao tu menu

**Verify**

- service active sau install
- dashboard/system menu nhan ra monitoring state

**Review checklist**

- resource footprint chap nhan duoc cho VPS nho
- de tat bo va rollback

---

### P2-03 Alerts and thresholds

**Muc tieu**

- them canh bao nhe theo nguong CPU, RAM, disk, va co the service health

**Tasks**

1. chot threshold policy:
   - CPU/load
   - RAM/swap
   - disk usage
2. tao scripts check nhe
3. chot scheduler contract:
   - cron hoac systemd timer, nhung phai doc va inventory duoc
4. optional notification targets:
   - email/webhook
5. define quiet mode / spam control

**Output**

- alerting baseline cho operator

**Verify**

- script check return dung status
- scheduler chay dung chu ky
- test threshold co tao canh bao mong doi

**Review checklist**

- khong spam alert
- khong tao tai nguyen nen qua nang

---

### P2-04 Unified verify stack

**Muc tieu**

- co 1 action/menu verify toan stack duoc theo format nhat quan

**Tasks**

1. tao `verify_stack` flow hoac tuong duong
2. include checks cho:
   - SSH state sanity
   - Nginx syntax + active
   - Node/PM2 services
   - 9router local binding + route
   - PHP-FPM active pools
   - DB active
   - SSL cert status
   - monitoring state neu da bat
3. define output format:
   - PASS / WARN / FAIL
   - issue summary
   - next action hint

**Output**

- menu `Verify stack health`

**Verify**

- stack tot -> PASS ro rang
- pha co chu dich 1 component -> FAIL/WARN dung component

**Review checklist**

- output de scan nhanh
- khong chi report status ma khong chi duong tiep theo

---

### P2-05 Backup helpers

**Muc tieu**

- co helper backup thuc dung cho DB va configs quan trong

**Tasks**

1. DB dump helper:
   - dump 1 DB
   - dump all DBs tuy chon
2. config archive helper:
   - `/etc/ops`
   - Nginx sites
   - selected app manifests
3. naming + retention basic
4. restore guidance:
   - huong dan clear
   - script support o muc vua phai, khong auto destructive qua muc

**Output**

- operator co the backup configs va DB truoc khi sua lon

**Verify**

- dump file tao thanh cong
- archive file tao thanh cong
- file restore guidance khop thuc te

**Review checklist**

- khong overwrite backup cu im lang
- secret files duoc backup voi permission phu hop

---

### P2-06 Runtime artefact inventory expansion

**Muc tieu**

- cap nhat inventory tu "target architecture" thanh "runtime that"

**Tasks**

1. bo sung artefacts thuc te vao `RUNTIME-ARTEFACT-INVENTORY.md`
2. neu co scheduler:
   - cron files
   - timers
   - logrotate
3. neu co PM2 startup artefacts:
   - startup hooks
   - saved process state
4. map moi artefact -> script/module -> verify -> rollback

**Output**

- inventory dung du cho debug production

**Verify**

- moi artefact docs co the tim thay tren VPS test

**Review checklist**

- khong de inventory o muc gia dinh
- neu uncertain, ghi ro `not yet verified`

---

### P2-07 Rollback playbooks expansion

**Muc tieu**

- bien `RUNBOOKS.md` thanh runbooks sat implementation hon

**Tasks**

1. update runbooks SSH, Nginx, Node/PM2, PHP-FPM, DB, SSL
2. them runbooks cho:
   - monitoring install/remove
   - alerts scheduler
   - backup helper changes neu can
3. map rollback toi file/service that

**Output**

- rollback-first docs dung cho production changes

**Verify**

- moi runbook co:
   - pre-check
   - change
   - verify
   - rollback

**Review checklist**

- rollback kha thi tren VPS production
- khong co buoc "magic" khong ro state

---

### P2-08 Phase acceptance and docs sync

**Muc tieu**

- chot Phase 2 bang test line va docs patch cuoi

**Tasks**

1. test advanced monitoring opt-in
2. test threshold alerts
3. test unified verify stack
4. test backup helpers
5. test docs inventory va runbooks doi chieu runtime
6. cap nhat docs neu implementation lech spec

**Output**

- Phase 2 acceptance report

**Verify**

- tat ca task Phase 2 pass gate

**Review checklist**

- Phase 2 van nhe
- khong lech sang cloud/plugin scope

---

## 6) Phase 2 test strategy

### Test levels

1. **Static / script checks**
   - `bash -n`
   - shellcheck neu co
2. **Runtime feature checks**
   - monitoring install/remove
   - scheduler firing
   - backup generation
3. **Health verification checks**
   - unified verify PASS/WARN/FAIL cases
4. **Docs-to-runtime checks**
   - inventory va runbooks doi chieu voi VPS test

### Minimum pass gate cho moi task

Moi task chi duoc xem la xong khi co:

- code xong
- docs khop implementation
- verify pass
- rollback minimum mo ta ro
- khong them overhead lon trai voi muc tieu VPS nho/vua

---

## 7) Cach review Phase 2

Khi review phase, dung form nay:

1. Feature nay co thuc su can cho van hanh, hay chi "nice to have"?
2. No co lam OPS nang hon dang ke khong?
3. Runtime state va inventory da ro chua?
4. Verify output co de scan va co hanh dong tiep theo khong?
5. Rollback co nhanh va ro khong?
6. Co dang len scope sang Phase 3/4 khong?

---

## 8) Suggested working mode

Lam theo tung task `P2-xx`, khong mo dong ca monitoring + alerts + backup cung luc.

Thu tu review khuyen nghi:

1. `P2-01`
2. `P2-04`
3. `P2-06`
4. `P2-07`
5. moi tiep `P2-02`, `P2-03`, `P2-05`

Ly do:

- verify/inventory/runbook la nen cho cac tinh nang quality-of-life con lai
