## OPS Feature Expansion Spec

Muc tieu: map cac tinh nang mo rong duoc yeu cau vao phase, menu, impact layer, runtime state, verify, va rollback de khong bi "treo y tuong" trong docs.

Luu y:

- Day la docs mapping cho future implementation.
- Khong thay doi Phase 1 contract.
- Cac tinh nang duoc xep vao `Phase 2` hoac `Phase 4` tuy muc do local-only hay external integration.

---

## 1) Feature mapping table

| Tinh nang | Phase chinh | Menu du kien | Impact layers chinh |
|---|---|---|---|
| Bat/tat kiem tra uptime va downtime website + Telegram/Email | Phase 2 | Notifications & Checks | monitoring, scheduler, notifications |
| Bat/tat thong bao han SSL + Telegram/Email | Phase 2 | Notifications & Checks / SSL | SSL, scheduler, notifications |
| Bat/tat thong bao han domain + Telegram/Email | Phase 2 | Notifications & Checks / Domains | domain metadata, scheduler, notifications |
| Sao luu uploads len Telegram Cloud | Phase 4 | Remote Upload Backups | backup staging, remote integration, secrets |
| Download backup tu Telegram Cloud | Phase 4 | Remote Upload Backups | remote integration, local restore staging |
| Bat auto backup uploads len Telegram Cloud | Phase 4 | Remote Upload Backups | scheduler, remote integration, secrets |
| Huy auto backup uploads len Telegram Cloud | Phase 4 | Remote Upload Backups | scheduler, remote integration |
| Quet lo hong bao mat dinh ky | Phase 2 | Notifications & Checks / Security | scheduler, scanning, notifications |
| Factory reset `.htaccess` website | Phase 2 | Advanced Web Controls | PHP-secondary compatibility, app files |
| Hien thi IP log real bypass Cloudflare CDN | Phase 2 | Advanced Web Controls | Nginx, real IP, Cloudflare-aware logging |
| Tuy bien `X-Powered-By` HTTP | Phase 2 | Advanced Web Controls | Nginx headers, app/proxy branding |
| Chan truy cap truc tiep `http://IP` | Phase 2 | Advanced Web Controls | Nginx default server, host validation |

---

## 2) Feature groups

### A. Notifications & Checks (Phase 2)

Bao gom:

- website uptime/downtime checks
- SSL expiry checks
- domain expiry checks
- Telegram + Email notifications
- periodic security scan

**Muc tieu**

- cung cap canh bao operational nhe
- giup operator phat hien su co som
- giu alerting la opt-in va co spam control

**Runtime state du kien**

- `/etc/ops/notifications.conf`
- `/etc/ops/checks/uptime/*.conf`
- `/etc/ops/checks/ssl-expiry/*.conf`
- `/etc/ops/checks/domain-expiry/*.conf`
- `/etc/ops/checks/security-scan/*.conf`
- scheduler artefacts (cron hoac timer)

**Verify**

- 1 website/check mau trigger va gui thong bao dung kenh
- disable 1 check thi scheduler khong chay nua

**Rollback**

- disable check
- remove scheduler artefact
- khoi phuc config truoc do neu can

### B. Remote Upload Backups via Telegram Cloud (Phase 4)

Bao gom:

- manual upload uploads backup
- manual download uploads backup
- enable auto backup uploads
- disable auto backup uploads

**Muc tieu**

- co remote transport free-tier cho uploads backups
- chi dung cho optional backup transport, khong thay the local backup hygiene

**Runtime state du kien**

- `/etc/ops/backups/telegram.conf`
- `/etc/ops/backups/uploads/*.conf`
- local staging dir cho archive uploads
- scheduler artefacts cho auto backups
- metadata map backup name <-> Telegram file/message id

**Verify**

- upload thanh cong va co metadata local
- download thanh cong tu metadata da luu
- auto backup chay dung lich

**Rollback**

- disable scheduler
- remove local config/meta
- khong xoa remote artefact neu chua xac nhan operator

### C. Advanced Web Controls (Phase 2)

Bao gom:

- factory reset `.htaccess`
- Cloudflare real IP logging
- custom `X-Powered-By`
- block direct IP access

**Muc tieu**

- bo sung bo utility cho edge/web behavior
- giup PHP-secondary va Nginx edge controls de manage hon

**Runtime state du kien**

- Nginx snippets/managed site config
- `/etc/ops/domains/<domain>.conf`
- PHP-secondary app file paths neu co `.htaccess`

**Verify**

- Nginx syntax pass
- request logs hien IP real dung khi di qua Cloudflare
- direct `http://IP` bi chan
- `X-Powered-By` header dung nhu mong doi

**Rollback**

- bo snippet/header/rule moi
- khoi phuc `.htaccess` backup

---

## 3) Important compatibility note: `.htaccess`

OPS dung Nginx, khong dung Apache.

Vi vay:

- `.htaccess` khong phai runtime config file cua Nginx.
- Feature `Factory reset .htaccess website` chi hop le cho:
  - PHP-secondary websites co ship `.htaccess` cho app-level compatibility
  - migration/cleanup utility
- Khong duoc mo ta nhu mot edge control chinh cua OPS.

Edge controls chinh cua OPS van phai nam o:

- Nginx site config
- Nginx snippets
- PHP-FPM wiring

---

## 4) Planned menu placement

Khong thay doi Phase 1 main menu contract. Cac nhom nay la future extensions:

- `Notifications & Checks`
- `Remote Upload Backups`
- `Advanced Web Controls`

Co the duoc dat:

- trong `System & Monitoring`, `SSL Management`, `Domains & Nginx`
- hoac tach thanh submenu rieng o phase sau

Quyet dinh cuoi cung phai giu:

- menu khong qua phinh
- operator tim duoc tinh nang theo impact layer hop ly

---

## 5) Review rules cho cac feature nay

Truoc khi code bat ky feature nao trong danh sach nay, phai tra loi:

1. Feature nay thuoc Phase 2 hay Phase 4?
2. Runtime source of truth la file/config/state nao?
3. Scheduler artefact nao se duoc tao?
4. Kenh notification/secrets nam o dau?
5. Verify thanh cong bang dau hieu nao?
6. Disable/rollback co clean khong?
