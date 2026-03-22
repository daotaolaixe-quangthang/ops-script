## OPS Runbooks

Muc tieu: cung cap runbook ngan theo format `pre-check -> change -> verify -> rollback` cho cac thao tac production co rui ro cao.

## 1. SSH port transition and finalisation

- **Pre-check**:
  - xac nhan admin user moi da tao
  - xac nhan port SSH moi chua bi chiem: `ss -tlnp | grep <NEW_PORT>`
  - mo ca port 22 va port moi tren firewall: `ufw allow <NEW_PORT>/tcp`
  - **QUAN TRONG:** giu session SSH hien tai mo trong suot qua trinh
- **Change**:
  - them port moi vao `sshd_config`: `Port <NEW_PORT>`
  - giu port 22 trong giai doan transition
  - verify login bang session SSH moi: `ssh -p <NEW_PORT> <ADMIN_USER>@host`
  - chi dong port 22 sau khi verify xong: `ufw delete allow 22/tcp`
- **Verify**:
  - `sshd -t` — kiem tra syntax config
  - dang nhap bang `ssh -p <NEW_PORT> <ADMIN_USER>@host`
  - `ss -tlnp | grep <NEW_PORT>` — xac nhan port dang listen
- **Rollback**:
  - mo lai port 22: `ufw allow 22/tcp`
  - khoi phuc `sshd_config`: `cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config`
  - restart `sshd`: `systemctl restart sshd`

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

## 11. OPS self-upgrade

- **Pre-check**:
  - xac nhan phien ban OPS dang chay: `cat /etc/ops/ops.conf | grep OPS_VERSION`
  - snapshot VPS neu co the, hoac backup `/opt/ops` va `/etc/ops`
  - kiem tra changelog / release notes truoc khi upgrade
- **Change**:
  - `cd /opt/ops && git fetch origin`
  - `git log HEAD..origin/main --oneline` — xem truoc nhung gi se thay doi
  - `git pull origin main`
- **Verify**:
  - `bash -n bin/ops` — syntax check
  - `ops --version` hoac chay menu de confirm khong bi broken
  - kiem tra cac module lien quan neu co thay doi trong release notes
- **Rollback**:
  - `git log --oneline -10` — tim commit truoc do
  - `git checkout <previous-commit>`
  - restart khong can thiet (OPS la shell script, khong phai long-running service)

## 12. Netdata advanced monitoring install / remove (P2-02)

- **Pre-check**:
  - xac nhan RAM con tu do: `free -m` — nen co > 512MB free
  - Netdata se bind `127.0.0.1:19999` — khong expose ra ngoai
  - Khong dung tren VPS < 512MB RAM neu khong can thiet
- **Change (install)**:
  - OPS menu: `System & Monitoring → Advanced monitoring (Netdata) → Install Netdata`
  - OPS tu dong apt install, enable service, va chinh `bind to = 127.0.0.1` trong `/etc/netdata/netdata.conf`
- **Verify**:
  - `systemctl is-active netdata` → active
  - `curl -s http://localhost:19999/api/v1/info` → JSON response
  - `grep 'bind to' /etc/netdata/netdata.conf` → `127.0.0.1`
  - `ss -tlnp | grep 19999` → ONLY listening on 127.0.0.1 (not 0.0.0.0)
- **Rollback (remove)**:
  - OPS menu: `Advanced monitoring → Remove Netdata`
  - Manual: `systemctl stop netdata && apt-get purge -y netdata && apt-get autoremove -y`
  - Verify: `systemctl status netdata` → not found, `ss -tlnp | grep 19999` → empty

## 13. Alerts scheduler — enable / disable (P2-03)

- **Pre-check**:
  - xac nhan Telegram da config: `grep TELEGRAM_ENABLED /etc/ops/ops.conf`
  - xac nhan `/etc/ops/.telegram-bot-token` ton tai va co quyen 0600
  - Neu Telegram chua setup, alerts se chi ghi vao `/var/log/ops/checks.log`
- **Change (enable)**:
  - OPS menu: `System & Monitoring → Notifications & scheduled checks → Install scheduled checks`
  - Tao `/etc/cron.d/ops-checks` va `bin/ops-check` dispatcher
- **Verify**:
  - `cat /etc/cron.d/ops-checks` → 5 cron entries dung lich
  - `bash -n <OPS_ROOT>/bin/ops-check` → no errors
  - `ls /var/log/ops/checks.log` → file exists (created by cron)
  - Sau 5 phut: `tail /var/log/ops/checks.log` → check output
- **Change (disable)**:
  - OPS menu: `Notifications & scheduled checks → Remove scheduled checks`
  - Manual: `rm -f /etc/cron.d/ops-checks`
- **Rollback**:
  - `rm -f /etc/cron.d/ops-checks` → scheduler bi vo hieu
  - `rm -f /tmp/ops-alert-*.cooldown` → xoa cooldown files neu can reset
  - Khong co long-running process — chi cron entries

## 14. Backup helpers — DB dump and config archive (P2-05)

- **Pre-check**:
  - Kiem tra disk space truoc: `df -h /var/backups`
  - DB dump yeu cau MariaDB active: `systemctl is-active mariadb`
  - Config archive yeu cau `/etc/ops/` va `/etc/nginx/sites-available/` ton tai
- **Change (DB dump)**:
  - OPS menu: `System & Monitoring → Backup helpers → Dump single database`
  - Hoac: `Dump all databases`
  - Output: `/var/backups/ops/db/<dbname>-YYYYMMDD-HHMMSS.sql.gz` (0600)
- **Verify (DB dump)**:
  - `ls -lh /var/backups/ops/db/` → file ton tai, size > 0
  - `gzip -t /var/backups/ops/db/<dbname>-<ts>.sql.gz` → no error
  - Test restore (staging only): `gunzip < <file> | mysql <dbname>`
- **Change (config archive)**:
  - OPS menu: `Backup helpers → Archive configs`
  - Output: `/var/backups/ops/config/ops-config-YYYYMMDD-HHMMSS.tar.gz` (0600)
- **Verify (config archive)**:
  - `tar -tzf /var/backups/ops/config/ops-config-<ts>.tar.gz` → list files without error
  - `ls -lh /var/backups/ops/config/` → file ton tai, size > 0
- **Restore (manual)**:
  - DB: `gunzip < /var/backups/ops/db/<file>.sql.gz | mysql <dbname>`
  - Nginx: `tar -xzf <archive> -C / etc/nginx/sites-available/ && nginx -t && systemctl reload nginx`
  - OPS config: `tar -xzf <archive> -C / etc/ops/ && chmod 600 /etc/ops/.*`
- **Rollback**:
  - Backup files bao gio cung nam o `/var/backups/ops/` — khong bi xoa tu dong
  - Neu restore sai: restore tu backup cu hon
  - Secret files: verify `chmod 600` sau moi restore: `.telegram-bot-token`, `.db-root-password`, `.codex-api-key`



---

## Nginx Upgrade: Ubuntu Package → Official Mainline

**When:** `nginx -v` shows < 1.24 (e.g. 1.18.0 from Ubuntu repo).

**Steps:**
```bash
# 1. From OPS menu:
# Domains & Nginx → Install / update Nginx (option 6)
# This calls _nginx_add_official_repo() + apt upgrade

# 2. Or manually:
curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/ubuntu $(lsb_release -cs) nginx" \
    > /etc/apt/sources.list.d/nginx.list
cat > /etc/apt/preferences.d/99nginx <<'PINEOF'
Package: nginx
Pin: origin nginx.org
Pin-Priority: 1001
PINEOF
apt update && apt install nginx
nginx -v && nginx -t && systemctl reload nginx
```

**Rollback:** Remove `/etc/apt/sources.list.d/nginx.list` and `/etc/apt/preferences.d/99nginx`, then `apt install nginx=1.18*` (not recommended for production).

---

## Apply Nginx Security Baseline

**When:** After fresh install, after nginx upgrade, or when `verify_stack` shows WARN on any nginx hardening check.

**Steps:**
```bash
# From OPS menu:
# Domains & Nginx → Apply security baseline (option 8)
# This runs nginx_apply_security_baseline() which calls _nginx_apply_global_tuning() + reload

# Verify all checks pass:
# Main menu → Verify stack → check Nginx section for PASS
```

**What it applies:**
- `worker_rlimit_nofile 65535`, `multi_accept on`, `use epoll`
- `keepalive_timeout 30s`, `client_max_body_size 10m`, client timeouts
- Full gzip config with `gzip_types`
- `open_file_cache`, `limit_req_zone`, `limit_conn_zone`
- All security headers (HSTS+preload, CSP, Permissions-Policy, etc.)
- Custom `log_format main_ext`

---

## Enable / Disable Cloudflare IP Restriction

**When:** All public domains are behind Cloudflare (Orange Cloud ON). Blocks any direct-IP access bypassing Cloudflare.

**Enable:**
```bash
# OPS menu: Domains & Nginx → Advanced web controls → option 5
# Writes /etc/nginx/conf.d/cloudflare-ip-restrict.conf
# Then manually add to each server {} block:
#   if ($blocked_cf) { return 444; }
# Then: nginx -t && systemctl reload nginx
```

**Disable:**
```bash
# OPS menu: Domains & Nginx → Advanced web controls → option 6
# Removes /etc/nginx/conf.d/cloudflare-ip-restrict.conf
# Then remove any "if ($blocked_cf)" lines from server blocks
# Then: nginx -t && systemctl reload nginx
```

> **Warning:** Never enable CF IP restrict if any domain has Cloudflare proxying disabled (Grey Cloud). It will block all traffic to that domain.
