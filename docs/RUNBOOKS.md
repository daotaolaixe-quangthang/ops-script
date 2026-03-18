## OPS Runbooks

Muc tieu: cung cap runbook ngan theo format `pre-check -> change -> verify -> rollback` cho cac thao tac production co rui ro cao.

## 1. SSH port transition and finalisation

- **Pre-check**:
  - xac nhan admin user moi da tao
  - xac nhan port SSH moi chua bi chiem
  - mo ca port 22 va port moi tren firewall
- **Change**:
  - them port moi vao `sshd_config`
  - giu port 22 trong giai doan transition
  - verify login bang session SSH moi
  - chi dong port 22 sau khi verify xong
- **Verify**:
  - `sshd -t`
  - dang nhap bang `ssh -p <NEW_PORT> <ADMIN_USER>@host`
- **Rollback**:
  - mo lai port 22
  - khoi phuc `sshd_config`
  - restart `sshd`

## 2. Nginx domain add/edit/remove

- **Pre-check**:
  - xac dinh backend type: Node, PHP, hay static
  - backup file Nginx lien quan
- **Change**:
  - tao/sua/remove site config
  - enable/disable symlink neu dung sites-enabled
- **Verify**:
  - `nginx -t`
  - `systemctl reload nginx`
  - `curl -I` voi host dung
- **Rollback**:
  - khoi phuc config cu
  - disable broken site
  - reload Nginx

## 3. Node service deploy or update (PM2-only)

- **Pre-check**:
  - xac nhan app dir, `.env`, Node version
  - xac nhan process se bind localhost
- **Change**:
  - install/build/update app
  - register hoac update PM2 process
  - luu PM2 state neu can
- **Verify**:
  - `pm2 status`
  - log process khong crash loop
  - health endpoint localhost
  - domain proxy request neu co
- **Rollback**:
  - `pm2 stop/delete` process moi
  - restore build/env/config cu
  - tra Nginx ve target cu neu da doi

## 4. 9router deploy or relink

- **Pre-check**:
  - xac nhan 9router chi bind `127.0.0.1:20128`
  - xac nhan domain router neu co se di qua Nginx
- **Change**:
  - deploy/update 9router
  - quan ly bang PM2 nhu Node service khac
  - wire Nginx route
- **Verify**:
  - `pm2 status`
  - direct external access vao `:20128` that bai
  - domain router hoat dong qua Nginx
  - neu dung Cloudflare Access, private browser van bi challenge
- **Rollback**:
  - stop PM2 process moi
  - remove route moi
  - khoi phuc target cu

## 5. PHP version or PHP-FPM pool changes

- **Pre-check**:
  - xac nhan site nao bi anh huong
  - backup pool config va `php.ini`
- **Change**:
  - sua pool hoac doi PHP version
  - update Nginx fastcgi mapping neu can
- **Verify**:
  - service PHP-FPM active
  - response PHP ok
  - app log khong loi syntax/runtime
- **Rollback**:
  - khoi phuc pool/php.ini cu
  - reload PHP-FPM va Nginx

## 6. Database secure setup or tuning

- **Pre-check**:
  - xac nhan app nao dung DB nay
  - backup config quan trong
- **Change**:
  - secure setup hoac tuning tung nhom
- **Verify**:
  - DB service active
  - login DB thanh cong
  - app van ket noi duoc
- **Rollback**:
  - khoi phuc config cu
  - restart DB

## 7. Login hook / dashboard wiring

- **Pre-check**:
  - xac nhan shell rc file nao bi sua
  - xac nhan chi ap dung cho interactive shell
- **Change**:
  - them hoac sua login hook goi `ops-dashboard`
- **Verify**:
  - dang nhap shell interactive thay dashboard
  - `scp`/non-interactive shell khong bi anh huong
- **Rollback**:
  - bo hook
  - khoi phuc rc file backup

## 8. Notification checks and delivery

- **Pre-check**:
  - xac nhan website/domain/list checks can bat
  - xac nhan kenh Telegram va Email da duoc cau hinh
  - xac nhan scheduler contract dang dung
- **Change**:
  - bat/tat uptime-downtime checks
  - bat/tat SSL expiry checks
  - bat/tat domain expiry checks
  - bat/tat periodic security scan
- **Verify**:
  - scheduler artefact ton tai/bi go dung nhu mong doi
  - test notification di dung kenh
  - disable check thi khong con execution moi
- **Rollback**:
  - disable check
  - xoa scheduler artefact moi
  - khoi phuc notification config neu can

## 9. Telegram Cloud uploads backup

- **Pre-check**:
  - xac nhan uploads path/site can backup
  - xac nhan Telegram transport config va local staging path
  - xac nhan metadata file se duoc luu o dau
- **Change**:
  - manual upload backup
  - manual download backup
  - enable/disable auto backup schedule
- **Verify**:
  - archive local tao thanh cong
  - upload hoac download thanh cong
  - metadata duoc cap nhat dung
  - scheduler auto-backup chay dung lich neu bat
- **Rollback**:
  - disable auto-backup
  - remove local config/meta moi neu can
  - khong xoa remote backup neu chua co xac nhan ro rang

## 10. Advanced web controls

- **Pre-check**:
  - xac nhan domain/site bi anh huong
  - backup Nginx config/snippets va `.htaccess` neu feature co dung toi
  - nhac lai: `.htaccess` chi la PHP-secondary compatibility utility
- **Change**:
  - bat/tat Cloudflare real IP logging
  - them/xoa custom `X-Powered-By`
  - bat/tat block direct `http://IP`
  - factory reset `.htaccess`
- **Verify**:
  - `nginx -t`
  - request logs hien real IP dung
  - direct IP request bi chan
  - header dung nhu mong doi
  - `.htaccess` duoc reset dung file mong doi
- **Rollback**:
  - khoi phuc snippet/config backup
  - bo custom header/rule moi
  - khoi phuc `.htaccess` backup neu reset sai
