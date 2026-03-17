## OPS Phase 3 Implementation Spec

Muc tieu: bien `Phase 3` thanh spec mo rong co kiem soat cho `extensibility` va `multi-OS support`, sau khi `Phase 1` va `Phase 2` da on dinh.

Phase 3 tap trung vao:

- distro abstraction
- plugin/module hooks co kiem soat
- rendering/template abstraction tot hon
- compatibility va migration docs khi them distro hoac extension points

Khong bao gom trong Phase 3:

- cloud API automation
- managed backup providers
- DNS/cloud integrations
- full remote orchestration platform
- marketplace/module ecosystem mo khong kiem soat

---

## 1) Phase 3 entry conditions

Chi nen bat dau Phase 3 khi:

1. `Phase 1` da on dinh va duoc su dung thuc te tren Ubuntu 22.04/24.04.
2. `Phase 2` da xong hoac it nhat da xac dinh ro runtime artefacts, verify stack, runbooks.
3. Da co bang chung ro rang ve nhu cau:
   - ho tro distro moi
   - them module moi tu ben thu ba
   - giam duplicate template/rendering logic
4. Docs va code hien tai du ro de tach abstraction ma khong lam mo control plane.

Neu chua co nhu cau that, Phase 3 de tro thanh over-engineering.

---

## 2) Phase 3 architecture contract

Tat ca implementers phai coi nhung diem sau la fixed contract:

1. Extensibility khong duoc lam mat tinh de audit cua OPS.
2. Plugin hooks phai bi rang buoc boi contract ro, khong cho module ngoai chen side effects tuy y.
3. Support distro moi chi duoc them sau khi tách ro:
   - package manager logic
   - service names
   - config paths
   - security assumptions
4. Template abstraction phai lam code ro hon, khong tao them framework phuc tap.
5. Multi-OS support khong duoc pha contract Node-first, Nginx-first, PM2-only cho Node services neu chua cap nhat docs goc.
6. Moi abstraction moi phai co:
   - source of truth
   - verify
   - rollback
   - compatibility note

---

## 3) Phase 3 deliverables

### A. Distro abstraction layer

- abstraction docs cho package/service/path differences
- helpers tach rieng nhung cho OS-specific
- compatibility matrix cho Ubuntu va distro moi neu co

### B. Plugin or extension hook contract

- diem hook ro rang cho menus/modules/templates
- allowlist/contract cho plugin modules
- docs cho side effects va loading order

### C. Template and rendering abstraction

- helper render templates tot hon
- convention ro cho placeholders, defaults, validation
- giam duplicate giua Node, PHP, SSL, Nginx configs

### D. Compatibility and migration docs

- migration notes khi support distro moi
- plugin authoring rules
- backward compatibility notes cho runtime installs cu

---

## 4) Implementation order trong Phase 3

Lam theo thu tu nay:

1. `P3-01` distro abstraction audit
2. `P3-02` compatibility matrix and path/service mapping
3. `P3-03` plugin hook design
4. `P3-04` plugin loading safety contract
5. `P3-05` template/rendering abstraction
6. `P3-06` migration and compatibility docs
7. `P3-07` phase acceptance and docs sync

Ly do:

- phai biet cai gi OS-specific truoc khi tao abstraction
- plugin hooks phai duoc thiet ke sau khi ranh gioi core/module da ro
- template abstraction nen dua tren cases that, khong nen viet truoc ly thuyet

---

## 5) Detailed tasks

### P3-01 Distro abstraction audit

**Muc tieu**

- liet ke chinh xac nhung diem OPS hien dang phu thuoc Ubuntu

**Tasks**

1. audit:
   - `apt`
   - package names
   - service names
   - config paths
   - log paths
   - default users/groups
2. tach thanh:
   - truly generic logic
   - Ubuntu-specific logic
   - assumptions can document but chua abstraction ngay
3. xac dinh minimum viable distro tiep theo neu co

**Output**

- audit note hoac docs patch lam co so cho `P3-02`

**Verify**

- moi layer chinh deu biet phan nao OS-specific

**Review checklist**

- khong abstraction mo ho
- khong promise support distro moi neu chua xac minh

---

### P3-02 Compatibility matrix and path/service mapping

**Muc tieu**

- tao matrix ro rang cho OS/package/service/path differences

**Tasks**

1. define compatibility matrix:
   - OS version
   - package sources
   - package names
   - service names
   - config paths
2. decide helper surface trong `core/system.sh` va `core/env.sh`
3. document unsupported combinations ro rang

**Output**

- compatibility matrix docs
- target helper changes de support abstraction

**Verify**

- 1 feature co the tra loi ro:
   - package nao
   - service nao
   - config path nao tren tung distro duoc support

**Review checklist**

- matrix de maintainer va AI Agent doc nhanh
- khong tron "supported" va "planned"

---

### P3-03 Plugin hook design

**Muc tieu**

- thiet ke extension points cho modules/menu ma van giu OPS audit duoc

**Tasks**

1. xac dinh cac diem co the hook:
   - menu registration
   - module action registration
   - template injection
   - post-install hooks
2. define plugin manifest contract:
   - name
   - version
   - entrypoint
   - required capabilities
   - supported OPS versions
3. decide plugin discovery path

**Output**

- plugin hook design docs

**Verify**

- co the mo ta 1 plugin mau se gan vao menu/module the nao

**Review checklist**

- plugin khong duoc chen lung tung vao core
- side effects cua plugin co the inventory duoc

---

### P3-04 Plugin loading safety contract

**Muc tieu**

- dam bao plugin loading co guard va khong pha safety model

**Tasks**

1. define allowlist loading rules
2. define fallback neu plugin loi
3. define conflict rules:
   - duplicate menu ids
   - duplicate command names
   - unsupported OPS version
4. define docs requirements cho plugin:
   - impact layer
   - source of truth
   - verify
   - rollback

**Output**

- plugin safety contract docs

**Verify**

- plugin error khong duoc lam chet toan bo menu/core

**Review checklist**

- safety > convenience
- plugin co the bi disable cleanly

---

### P3-05 Template and rendering abstraction

**Muc tieu**

- giam duplicate trong render config files va helper generation

**Tasks**

1. audit templates hien co:
   - Nginx
   - PM2
   - SSL snippets
   - PHP pools neu them sau
2. define rendering conventions:
   - placeholder naming
   - defaults
   - required vars
   - validation before write
3. define helper API cho render templates
4. xac dinh phan nao nen giu template text don gian, phan nao nen render helper

**Output**

- rendering abstraction docs + target helper contract

**Verify**

- 1 template co the render repeatable, idempotent, de diff

**Review checklist**

- khong tao mini-template-engine qua phuc tap
- uu tien Bash-safe, de debug

---

### P3-06 Migration and compatibility docs

**Muc tieu**

- chuan hoa docs khi them distro moi, hooks moi, hoac abstraction moi

**Tasks**

1. migration doc structure:
   - current installs
   - changed assumptions
   - required operator actions
2. compatibility note structure
3. plugin authoring guide outline
4. support policy docs:
   - supported
   - experimental
   - unsupported

**Output**

- docs framework cho migration va compatibility

**Verify**

- 1 thay doi lon co the duoc document bang framework nay ma khong mo ho

**Review checklist**

- docs phan biet ro `breaking`, `non-breaking`, `experimental`

---

### P3-07 Phase acceptance and docs sync

**Muc tieu**

- chot Phase 3 bang docs, abstraction boundaries, va acceptance report

**Tasks**

1. review distro abstraction boundaries
2. review plugin contracts
3. review template abstraction contract
4. review compatibility docs
5. cap nhat `ARCHITECTURE.md`, `README.md`, `ROADMAP.md`, `OPS-AI-GUIDE.md` neu can

**Output**

- Phase 3 acceptance report

**Verify**

- abstraction boundaries de hieu va khong lam mo control plane

**Review checklist**

- khong lech sang Phase 4 cloud scope
- khong over-engineer

---

## 6) Phase 3 test strategy

### Test levels

1. **Architecture review tests**
   - abstraction co giai quyet duplicate that khong
   - abstraction co de audit khong
2. **Compatibility review tests**
   - matrix co du thong tin cho maintainer quyet dinh support/khong support
3. **Plugin safety review tests**
   - plugin loi co bi cô lap duoc khong
   - plugin conflict co duoc phat hien khong
4. **Template rendering review tests**
   - render output on dinh, diff-friendly, verify-friendly

### Minimum pass gate cho moi task

Moi task chi duoc xem la xong khi co:

- docs/spec ro
- implementation contract ro neu da code
- verify path ro
- rollback/disable path ro
- khong tang complexity vo ich

---

## 7) Cach review Phase 3

Khi review phase, dung form nay:

1. Abstraction nay giai quyet van de that hay chi dep kien truc?
2. Co lam OPS kho audit hon khong?
3. Co tao them hidden contracts khong?
4. Co tach duoc supported / experimental / future khong?
5. Plugin/distro abstraction co co che disable va fallback ro khong?
6. Co dang truot sang Phase 4 integrations khong?

---

## 8) Suggested working mode

Phase 3 khong nen code ao at. Nen lam theo vong:

1. audit
2. docs/spec
3. review
4. code abstraction toi thieu
5. review lai

Thu tu khuyen nghi:

1. `P3-01`
2. `P3-02`
3. `P3-05`
4. `P3-03`
5. `P3-04`
6. `P3-06`
7. `P3-07`

Ly do:

- phai biet abstraction thuc su can gi truoc khi mo hook cho ben ngoai
