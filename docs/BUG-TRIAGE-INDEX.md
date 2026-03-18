## OPS Bug Triage Index

Muc tieu: cho AI Agent moi co duong vao nhanh khi fix bug trong OPS ma khong debug lan man.

Nguyen tac:

- Khoanh theo `impact layer` truoc, khong khoanh theo ten module.
- Uu tien `runtime truth` tren VPS hon assumptions tu docs.
- Moi bug phai tra loi duoc: module, state, verify, rollback.

## Thu tu triage mac dinh

1. Xac dinh bug thuoc nhom nao:
   - installer / first-run
   - menu / dispatcher
   - Node app / PM2
   - Nginx / domain / SSL
   - PHP / PHP-FPM
   - DB
   - security / SSH / firewall / fail2ban
   - notifications / scheduler / external delivery
   - advanced web controls / Cloudflare real IP / direct IP block
   - monitoring / logs / scheduler
2. Doc:
   - `ARCHITECTURE.md`
   - `FLOW-INSTALL.md`
   - section lien quan trong `MENU-REFERENCE.md`
3. Neu bug la production/runtime:
   - doc `SOURCE-TO-RUNTIME-TRACE.md`
   - doc `KNOWN-RISKS-PATTERNS.md`
4. Moi doc source va runtime state that.

## Triage theo nhom su co

### A. Installer loi, setup khong chay het, login dashboard khong len

- **Doc truoc**:
  - `FLOW-INSTALL.md`
  - `ARCHITECTURE.md`
- **Khoanh source**:
  - `install/ops-install.sh`
  - `bin/ops-setup.sh`
  - `bin/ops-dashboard`
- **Runtime state can xem**:
  - `/opt/ops`
  - `/etc/ops/ops.conf`
  - shell login hooks
- **Verify**:
  - symlink ton tai
  - dashboard hien dung sau login interactive
- **Rollback**:
  - bo login hook, restore shell rc, rerun setup

### B. Menu dispatch sai, option khong vao dung module

- **Doc truoc**:
  - `MENU-REFERENCE.md`
  - `ARCHITECTURE.md`
- **Khoanh source**:
  - `bin/ops`
  - `core/ui.sh`
  - module duoc goi
- **Verify**:
  - menu index, label, action mapping
- **Rollback**:
  - revert dispatch mapping/menu handler

### C. Node service khong len, PM2 runtime/config issue

- **Doc truoc**:
  - `ARCHITECTURE.md`
  - `SOURCE-TO-RUNTIME-TRACE.md`
  - `KNOWN-RISKS-PATTERNS.md`
- **Runtime state can xem**:
  - PM2 process list
  - app `.env` / ecosystem config
  - Nginx upstream target
- **Verify**:
  - process alive
  - app chi bind localhost
  - Nginx proxy vao duoc
- **Rollback**:
  - revert process config, stop service moi, tra lai previous target

### D. Domain/Nginx/SSL loi

- **Doc truoc**:
  - `MENU-REFERENCE.md`
  - `SECURITY-RULES.md`
  - `SOURCE-TO-RUNTIME-TRACE.md`
- **Runtime state can xem**:
  - `/etc/nginx/nginx.conf`
  - `/etc/nginx/sites-available/*`
  - `/etc/nginx/sites-enabled/*`
  - cert paths / certbot state
- **Verify**:
  - `nginx -t`
  - `curl -I`
  - cert status
- **Rollback**:
  - remove/revert vhost, disable broken site, reload Nginx

### E. PHP site loi, PHP-FPM sai version/pool

- **Doc truoc**:
  - `MENU-REFERENCE.md`
  - `PERF-TUNING.md`
  - `SOURCE-TO-RUNTIME-TRACE.md`
- **Runtime state can xem**:
  - PHP-FPM pool configs
  - selected PHP version
  - Nginx fastcgi target
  - php.ini
- **Verify**:
  - `php -v`
  - php-fpm status
  - Nginx + PHP response
- **Rollback**:
  - tra lai pool/config/version cu

### F. DB install/secure/tuning loi

- **Doc truoc**:
  - `SECURITY-RULES.md`
  - `PERF-TUNING.md`
  - `SOURCE-TO-RUNTIME-TRACE.md`
- **Runtime state can xem**:
  - MySQL/MariaDB service
  - server config
  - created DB/users
- **Verify**:
  - login DB
  - service status
  - app ket noi thanh cong
- **Rollback**:
  - revert config, restart DB, xoa user/db tao nham neu can

### G. SSH/firewall/fail2ban gay lockout

- **Doc truoc**:
  - `FLOW-INSTALL.md`
  - `SECURITY-RULES.md`
  - `KNOWN-RISKS-PATTERNS.md`
- **Runtime state can xem**:
  - `/etc/ssh/sshd_config`
  - UFW rules
  - fail2ban status
- **Verify**:
  - van SSH duoc bang port dung
  - firewall chi mo port can thiet
- **Rollback**:
  - rollback-first mo SSH path truoc, roi moi sua layer security sau

### H. Monitoring / quick logs / scheduler sai

- **Doc truoc**:
  - `MENU-REFERENCE.md`
  - `ARCHITECTURE.md`
- **Runtime state can xem**:
  - `/var/log/ops/*`
  - system logs
  - cron/systemd timers neu duoc them sau
- **Verify**:
  - log path ton tai
  - commands show dung service status
- **Rollback**:
  - tat job/service moi, khoi phuc output path cu

### I. Notifications, alerts, hoac scheduled checks sai

- **Doc truoc**:
  - `FEATURE-EXPANSION-SPEC.md`
  - `RUNBOOKS.md`
  - `RUNTIME-ARTEFACT-INVENTORY.md`
- **Runtime state can xem**:
  - `/etc/ops/notifications.conf`
  - `/etc/ops/checks/*`
  - scheduler artefacts
- **Verify**:
  - test notification
  - kiem tra disable path
- **Rollback**:
  - tat checks/scheduler moi

### J. Cloudflare real IP / direct IP block / custom header sai

- **Doc truoc**:
  - `FEATURE-EXPANSION-SPEC.md`
  - `SOURCE-TO-RUNTIME-TRACE.md`
  - `RUNBOOKS.md`
- **Runtime state can xem**:
  - Nginx snippets/site config
  - PHP-secondary `.htaccess` neu co feature reset
- **Verify**:
  - `nginx -t`
  - request/log/header tests
- **Rollback**:
  - revert snippet/config backup

## 5 cau hoi bat buoc truoc khi sua bug

- Bug nay nam o impact layer nao?
- Runtime file/service nao la source of truth?
- Menu/module nao tao ra state nay?
- Verify thanh cong bang dau hieu nao?
- Rollback toi thieu la gi neu fix sai?
