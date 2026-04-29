## OPS Phase 3 Implementation Spec

Muc tieu: dam bao OPS chay on dinh tren `Ubuntu 22.04` production thuc te, sau khi `Phase 1` va `Phase 2` da on dinh.

Phase 3 tap trung vao:

- production hardening tren Ubuntu 22.04
- on dinh hoa stack hien tai: Nginx, Node.js, PM2, PHP, MariaDB, Certbot
- verify end-to-end tren moi truong production that
- giam duplicate trong template/rendering de duy tri long-term

Khong bao gom trong Phase 3:

- ho tro distro moi (Debian, CentOS, ...)
- multi-OS abstraction
- plugin/extension hooks cho third-party
- cloud API automation
- managed backup providers
- DNS/cloud integrations
- full remote orchestration platform

---

## 1) Phase 3 entry conditions

Chi nen bat dau Phase 3 khi:

1. `Phase 1` da on dinh va duoc su dung thuc te tren Ubuntu 22.04/24.04.
2. `Phase 2` da xong hoac it nhat da xac dinh ro runtime artefacts, verify stack, runbooks.
3. Da co Ubuntu 22.04 VPS that de chay acceptance tests.
4. Docs va code hien tai du ro, khong con nhung gia dinh mo ho ve moi truong runtime.

---

## 2) Phase 3 architecture contract

Tat ca implementers phai coi nhung diem sau la fixed contract:

1. Ubuntu 22.04 la target duy nhat cua Phase 3. Khong mo rong sang distro khac.
2. Stack contract khong doi: Node-first, Nginx-first, PM2-only cho Node services.
3. Template abstraction phai lam code ro hon, khong tao them framework phuc tap.
4. Moi thay doi hardening phai co:
   - source of truth
   - verify step
   - rollback path
   - acceptance note
5. Khong them tinh nang moi vuot qua scope Phase 1+2 da xac dinh.

---

## 3) Phase 3 deliverables

### A. Production runtime verification

- chay full acceptance test tren Ubuntu 22.04 VPS that
- verify tung thanh phan: Nginx, Node.js LTS, PM2, PHP 7.4/8.1/8.2/8.3, MariaDB, Certbot
- ghi lai ket qua trong acceptance report

### B. Production hardening

- review va fix nhung diem de failure tren moi truong production that
- hardening cho permissions, service restarts, log rotation
- toi gian hoa installer one-liner flow

### C. Template and rendering abstraction

- giam duplicate giua Node, PHP, SSL, Nginx config templates
- convention ro cho placeholders, defaults, validation
- helper render templates on dinh, idempotent, de diff

### D. Acceptance and docs sync

- Phase 3 acceptance report
- cap nhat ARCHITECTURE.md, README.md, ROADMAP.md neu can

---

## 4) Implementation order trong Phase 3

Lam theo thu tu nay:

1. `P3-01` Ubuntu 22.04 production runtime verification
2. `P3-02` Production hardening fixes
3. `P3-03` Template and rendering abstraction
4. `P3-04` Phase acceptance and docs sync

Ly do:

- phai chay tren runtime that truoc de biet dung diem nao can hardening
- template abstraction dua tren cases that, khong viet ly thuyet truoc

---

## 5) Detailed tasks

### P3-01 Ubuntu 22.04 production runtime verification

**Muc tieu**

- xac minh toan bo stack chay on dinh tren Ubuntu 22.04 VPS that

**Tasks**

1. setup fresh Ubuntu 22.04 VPS
2. chay installer one-liner
3. verify:
   - dashboard va menu hien thi dung
   - production wizard chay thanh cong
   - tao Node service thanh cong
   - tao PHP site thanh cong
   - CLIProxyAPI expose qua Nginx
   - Certbot cap SSL thanh cong
   - PM2 tu restart khi reboot
   - MariaDB on dinh
4. ghi lai ket qua va loi neu co

**Output**

- runtime verification report lam co so cho `P3-02`

**Verify**

- toan bo checklist Phase 1 "done" criteria deu PASS

**Review checklist**

- test tren fresh VPS, khong test tren may da setup san
- ghi ro version Ubuntu, kernel, va package versions duoc dung

---

### P3-02 Production hardening fixes

**Muc tieu**

- fix nhung van de phat hien tu P3-01 tren production that

**Tasks**

1. fix loi hoac edge cases phat hien tu verification
2. review permissions: web root, PM2 user, log dirs
3. review service restart policies (systemd, PM2)
4. review log rotation cho Nginx, PM2, MariaDB
5. toi gian hoa flow: installer, wizard, SSL provisioning

**Output**

- hardening patches voi rollback notes

**Verify**

- re-run verification checklist sau fix, tat ca PASS

**Review checklist**

- moi fix phai co rollback path ro
- khong them tinh nang moi ngoai scope hardening

---

### P3-03 Template and rendering abstraction

**Muc tieu**

- giam duplicate trong render config files va helper generation

**Tasks**

1. audit templates hien co:
   - Nginx
   - PM2
   - SSL snippets
   - PHP pools
2. define rendering conventions:
   - placeholder naming
   - defaults
   - required vars
   - validation before write
3. define helper API cho render templates
4. xac dinh phan nao giu template text don gian, phan nao can render helper

**Output**

- rendering abstraction docs + target helper contract

**Verify**

- 1 template co the render repeatable, idempotent, de diff

**Review checklist**

- khong tao mini-template-engine qua phuc tap
- uu tien Bash-safe, de debug

---

### P3-04 Phase acceptance and docs sync

**Muc tieu**

- chot Phase 3 bang acceptance report va docs update

**Tasks**

1. review toan bo hardening changes
2. review template abstraction contract
3. cap nhat `ARCHITECTURE.md`, `README.md`, `ROADMAP.md`, `OPS-AI-GUIDE.md` neu can
4. viet Phase 3 acceptance report

**Output**

- Phase 3 acceptance report

**Verify**

- moi thay doi co source of truth, verify, rollback ro

**Review checklist**

- khong lech sang Phase 4 cloud scope
- khong over-engineer

---

## 6) Phase 3 test strategy

### Test levels

1. **Production runtime tests**
   - chay tren Ubuntu 22.04 VPS that
   - verify tung thanh phan stack
2. **Hardening regression tests**
   - sau moi fix, re-run verification checklist
3. **Template rendering review tests**
   - render output on dinh, diff-friendly, verify-friendly

### Minimum pass gate cho moi task

Moi task chi duoc xem la xong khi co:

- docs/spec ro
- verify path ro
- rollback/disable path ro
- khong tang complexity vo ich

---

## 7) Cach review Phase 3

Khi review phase, dung form nay:

1. Fix nay giai quyet van de that hay chi dep code?
2. Co lam OPS kho debug hon tren production khong?
3. Co tao them hidden assumptions ve moi truong khong?
4. Rollback path co ro khong?
5. Co dang truot sang Phase 4 integrations khong?

---

## 8) Suggested working mode

Phase 3 nen lam theo vong:

1. verify tren runtime that
2. phat hien van de
3. fix voi rollback note
4. verify lai
5. docs sync

Thu tu khuyen nghi:

1. `P3-01`
2. `P3-02`
3. `P3-03`
4. `P3-04`

Ly do:

- phai biet production that can gi truoc khi abstraction
