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
  - chi finalize sau khi verify xong qua OPS menu: `Security -> Finalize SSH transition`
- **Verify**:
  - `sshd -t` â€” kiem tra syntax config truoc khi apply
  - dang nhap bang `ssh -p <NEW_PORT> <ADMIN_USER>@host`
  - `ss -tlnp | grep <NEW_PORT>` â€” xac nhan port dang listen
  - sau finalize: `sshd -T | awk '/^port / {print $2}'` chi con port moi
  - sau finalize: `ufw status | grep 22/tcp` khong con rule ALLOW cho port 22
  - sau finalize: `fail2ban-client status sshd` phai track desired OPS SSH state cuoi cung, khong track port transition cu hay port runtime doan tu live listener scan
- **Rollback**:
  - neu `sshd -t`, `systemctl reload/restart ssh`, UFW reconcile, hoac fail2ban apply fail, OPS phai giu `OPS_SSH_TRANSITION_PORT` va KHONG bao finalize thanh cong
  - OPS phai restore lai SSH config/include, UFW state, va fail2ban jail state truoc khi thoat failure
  - mo lai port 22 neu can: `ufw allow 22/tcp`
  - khoi phuc `sshd_config`: `cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config`
  - restart `sshd`: `systemctl restart sshd`

## 1a. Installer bootstrap rollback before activation

- **Pre-check**:
  - giu session SSH hien tai mo trong suot installer run
  - note lai live SSH ports hien tai va admin user dang dung
  - xac nhan neu rerun tren host multi-port thi OPS phai preserve tat ca live SSH port trong firewall va khong rewrite `OPS_SSH_PORT` / `OPS_SSH_TRANSITION_PORT` neu state managed van ambiguous
- **Change**:
  - installer co the sua `sshd_config`, `sshd_config.d`, UFW, tao admin user, them sudo group, them bootstrap SSH key, va ghi minimum SSH hardening truoc khi `/opt/ops` duoc activate
- **Verify**:
  - neu installer fail truoc activation, SSH/UFW/admin-user/bootstrap-key/minimum-hardening state phai tro ve trang thai truoc khi chay
  - neu installer fail sau activation, ngoai pre-activation rollback con phai restore `/opt/ops`, symlink, `ops.conf`, login hook, va cac file state operator-facing khac
- **Rollback**:
  - restore `/etc/ssh/sshd_config` va `sshd_config.d/`
  - restore UFW files (`user.rules`, `user6.rules`, `ufw.conf`) va reload/disable theo state cu
  - remove admin user neu user do duoc tao boi run hien tai; neu chi moi add vao sudo thi go khoi sudo group
  - restore `~/.ssh` bootstrap state neu key moi duoc add vao user da ton tai
  - xoa minimum hardening include neu no khong ton tai truoc run

## 1b. SSH Key Setup and PasswordAuthentication Recovery

**Triggers:**
- First-time setup: admin user created but SSH key not added during install.
- SSH lockout: `PasswordAuthentication no` was set before any key existed in `authorized_keys`.
- Operator wants to safely disable `PasswordAuthentication`.

### Pre-check
```bash
# Check if key file exists for admin user (run as root)
cat /home/<ADMIN_USER>/.ssh/authorized_keys 2>/dev/null || echo "NO KEY FILE"
# Check current PasswordAuthentication setting
grep -r PasswordAuthentication /etc/ssh/sshd_config.d/
```

### Normal path -- via OPS menu (when SSH still works)
```
ops -> Security menu -> 8) Manage SSH Keys
  -> 1) Add new SSH public key   (paste key from local: cat ~/.ssh/id_ed25519.pub)
  -> Verify SSH key login in a NEW terminal before next step
  -> 4) Disable PasswordAuthentication (OPS checks key exists first)
```

### Emergency recovery -- via VPS KVM/VNC console (as root)
```bash
# Step 1: Re-enable PasswordAuthentication so password login works again
sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' \
    /etc/ssh/sshd_config.d/99-ops-hardening.conf
systemctl reload ssh

# Step 2: Add your SSH public key (paste content of id_rsa.pub or id_ed25519.pub)
ADMIN_USER="opsuser"
mkdir -p /home/${ADMIN_USER}/.ssh && chmod 700 /home/${ADMIN_USER}/.ssh
echo "ssh-ed25519 AAAA...your-key..." >> /home/${ADMIN_USER}/.ssh/authorized_keys
chmod 600 /home/${ADMIN_USER}/.ssh/authorized_keys
chown -R ${ADMIN_USER}:${ADMIN_USER} /home/${ADMIN_USER}/.ssh

# Step 3: Open NEW terminal, verify SSH key login works
# Step 4: Disable PasswordAuthentication via OPS menu (option 8 -> 4)
#         OPS will verify key presence before accepting the change.
```

### Rollback
- Key accidentally removed: repeat Step 2 above from the VPS console.
- Hardening file corrupted: restore from backup OPS created automatically:
  `ls /etc/ssh/sshd_config.d/99-ops-hardening.conf.bak.*`
  `cp <backup> /etc/ssh/sshd_config.d/99-ops-hardening.conf && systemctl reload ssh`


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

## 4. CLIProxyAPI deploy or relink

- **Pre-check**:
  - xac nhan CLIProxyAPI chi bind `127.0.0.1:8317`
  - xac nhan domain proxy neu co se di qua Nginx
  - xac nhan runtime user co HOME hop le de login providers
- **Change**:
  - tai binary release vao `/opt/cli-proxy-api`
  - ghi `config.yaml`, tao `cli-proxy-api.service`, start bang systemd
  - bootstrap auth bang `--antigravity-login`, `--login`, `--claude-login`, hoac `--codex-login`
  - wire Nginx route toi `127.0.0.1:8317`
- **Verify**:
  - `systemctl status cli-proxy-api --no-pager`
  - `curl http://127.0.0.1:8317/v1/models`
  - direct external access vao `:8317` that bai
  - domain proxy hoat dong qua Nginx
- **Rollback**:
  - `systemctl stop cli-proxy-api`
  - remove route moi
  - khoi phuc config/state cu neu can

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
  - note so ket noi dang active va chon maintenance window neu host dang phuc vu production
- **Change**:
  - secure setup hoac tuning tung nhom
  - OPS phai validate lai MariaDB config truoc moi restart path
  - OPS phai hien canh bao downtime va yeu cau operator xac nhan truoc khi restart live DB
- **Verify**:
  - DB service active
  - login DB thanh cong (`sudo mysql` theo socket baseline, hoac file secret fallback neu host legacy dang dung password auth)
  - app van ket noi duoc
- **Rollback**:
  - khoi phuc config cu
  - chi restart DB sau khi config rollback da validate lai

## 7. Login hook / dashboard wiring

- **Pre-check**:
  - xac nhan shell rc file nao bi sua
  - xac nhan chi ap dung cho interactive shell
- **Change**:
  - them hoac sua login hook goi `ops-dashboard`
- **Verify**:
  - dang nhap shell interactive thay dashboard
  - `scp`/non-interactive shell khong bi anh huong
  - legacy sudoers auto-finalize rule chi duoc remove sau khi rewrite hook thanh cong
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
  - kiem tra `CHANGELOG.md` hoac release notes cua commit truoc khi upgrade
- **Change (qua menu OPS)**:
  - `ops -> 9) System & Monitoring -> 16) Update OPS from git`
  - OPS tai tarball tu GitHub (khong dung git pull), verify archive, extract vao tmp dir, syntax-check tung `.sh`, roi copy vao `/opt/ops`.
  - Sau khi update: thoat va chay lai `ops` de load version moi.
- **Change (thu cong / idempotent installer)**:
  - `bash <(curl -fsSL https://raw.githubusercontent.com/daotaolaixe-quangthang/ops-script/main/install/ops-install.sh)`
  - Installer la idempotent — khong dung lai config hay web root.
- **Verify**:
  - `bash -n /opt/ops/bin/ops` — syntax check
  - Chay `ops` -> menu hien thi dung va khong bi broken
  - `cat /etc/ops/ops.conf | grep OPS_VERSION` — version da cap nhat
- **Rollback**:
  - `/opt/ops` la directory thuong, khong phai git working tree tren VPS.
  - Restore tu backup: `cp -a /backup/opt-ops /opt/ops`
  - Hoac re-run installer voi tarball cu neu can.
  - restart khong can thiet (OPS la shell script, khong phai long-running service)

## 12. Netdata advanced monitoring install / remove

- **Pre-check**:
  - xac nhan RAM con tu do: `free -m` — nen co > 512MB free
  - Netdata se bind `127.0.0.1:19999` — khong expose ra ngoai
  - Khong dung tren VPS < 512MB RAM neu khong can thiet
- **Change (install)**:
  - OPS menu: `System & Monitoring -> Advanced monitoring (Netdata) -> Install Netdata`
  - OPS tu dong apt install, enable service, va chinh `bind to = 127.0.0.1` trong `/etc/netdata/netdata.conf`
- **Verify**:
  - `systemctl is-active netdata` -> active
  - `curl -s http://localhost:19999/api/v1/info` -> JSON response
  - `grep 'bind to' /etc/netdata/netdata.conf` -> `127.0.0.1`
  - `ss -tlnp | grep 19999` -> ONLY listening on 127.0.0.1 (not 0.0.0.0)
- **Rollback (remove)**:
  - OPS menu: `Advanced monitoring -> Remove Netdata`
  - Manual: `systemctl stop netdata && apt-get purge -y netdata && apt-get autoremove -y`
  - Verify: `systemctl status netdata` -> not found, `ss -tlnp | grep 19999` -> empty

## 13. Release / update / bugfix test gate

Muc tieu: moi release, update function, hoac fix bug deu phai chay qua cung 1 gate test va co report thong nhat truoc khi duyet.

### Gate bat buoc

- **Gate 1 - static**:
  - `bash -n` cho file vua sua va file source truc tiep
- **Gate 2 - shell regression**:
  - `bash ops/tests/regression/run-all.sh`
- **Gate 3 - smoke suite theo impact layer**:
  - chay `bash ops/tests/smoke/run-all.sh`
  - hoac chay tung layer: `bash ops/tests/smoke/run-all.sh --layer <tui|security|web|node|php-db-monitoring>`
- **Gate 4 - runtime acceptance**:
  - chay tren VM snapshot Ubuntu 22.04 hoac 24.04 bang `bash ops/tests/acceptance/run-all.sh --profile <fresh-install|rerun-idempotence|high-risk-runtime>`
  - verify file, service, port, permissions, rollback minimum
  - profile mutate host (`fresh-install`, `rerun-idempotence`) phai duoc chay tren snapshot disposable va set `OPS_ACCEPT_CONFIRM_MUTATION=YES`

### Cach dung theo loai thay doi

- **Fix bug menu/TUI/verify**:
  - chay `bash ops/tests/regression/run-all.sh`
  - chay them `TUI-*`, `REG-*`, `MON-01` neu co verify action
- **Update function trong module**:
  - chay harness regression
  - chay smoke suite cua module do theo `docs/reference/TEST-CASES.md` bang `ops/tests/smoke/run-all.sh --layer ...`
- **Release**:
  - chay harness regression
  - chay full smoke suite cua cac module bi anh huong trong release note
  - chay it nhat 1 fresh install snapshot + 1 rerun/idempotence snapshot bang `ops/tests/acceptance/run-all.sh`

### Lenh khuyen nghi

```bash
# 1) Static syntax
bash -n install/ops-install.sh
bash -n ops/bin/ops

# 2) Regression harness
bash ops/tests/regression/run-all.sh

# 3) Smoke gate theo impact layer
bash ops/tests/smoke/run-all.sh
bash ops/tests/smoke/run-all.sh --layer web

# 4) Runtime acceptance tren snapshot disposable
OPS_ACCEPT_CONFIRM_MUTATION=YES bash ops/tests/acceptance/run-all.sh --profile fresh-install
bash ops/tests/acceptance/run-all.sh --profile high-risk-runtime
```

### Mau report PASS/FAIL chuan

```text
Release / Change ID:
Date:
Reviewer / Tester:
Environment:
- Ubuntu version:
- VM snapshot id:
- OPS branch/commit:

Scope changed:
- files/modules:
- impact layers:

Executed gates:
- Gate 1 Static: PASS/FAIL
- Gate 2 Shell regression: PASS/FAIL
- Gate 3 Smoke suite: PASS/FAIL
- Gate 4 Runtime acceptance: PASS/FAIL

Executed test IDs:
- TUI-__ : PASS/FAIL
- REG-__ : PASS/FAIL
- WEB-__ : PASS/FAIL
- NODE-__ : PASS/FAIL

Evidence:
- commands run:
- key output summary:
- runtime files checked:
- services checked:

Rollback checked:
- yes/no
- minimum rollback path:

Decision:
- APPROVED
- BLOCKED

Blocking issues:
- ...

Notes:
- ...
```

### Quy tac duyet

- Khong duyet neu Gate 2 fail.
- Khong duyet neu smoke suite cua module bi thay doi chua chay.
- Khong duyet fix lien quan SSH/Nginx/DB neu chua co runtime acceptance tren snapshot.
- Moi bug da fix phai duoc them vao regression mapping hoac harness neu co the tu dong hoa.

## 14. Alerts scheduler — enable / disable

- **Pre-check**:
  - xac nhan Telegram da config: `grep TELEGRAM_ENABLED /etc/ops/notifications.conf`
  - xac nhan `/etc/ops/.telegram-bot-token` ton tai va co quyen 0600: `ls -la /etc/ops/.telegram-bot-token`
  - Neu Telegram chua setup, alerts se chi ghi vao `/var/log/ops/checks.log`
- **Change (enable)**:
  - OPS menu: `System & Monitoring -> Notifications & scheduled checks -> Install scheduled checks`
  - Tao `/etc/cron.d/ops-checks` va `bin/ops-check` dispatcher
- **Verify**:
  - `cat /etc/cron.d/ops-checks` -> 5 cron entries dung lich
  - `bash -n <OPS_ROOT>/bin/ops-check` -> no errors
  - `ls /var/log/ops/checks.log` -> file exists (created by cron)
  - Sau 5 phut: `tail /var/log/ops/checks.log` -> check output
- **Change (disable)**:
  - OPS menu: `Notifications & scheduled checks -> Remove scheduled checks`
  - Manual: `rm -f /etc/cron.d/ops-checks`
- **Rollback**:
  - `rm -f /etc/cron.d/ops-checks` -> scheduler bi vo hieu
  - `rm -f /tmp/ops-alert-*.cooldown` -> xoa cooldown files neu can reset
  - Khong co long-running process — chi cron entries

## 15. Backup helpers — DB dump and config archive

- **Pre-check**:
  - Kiem tra disk space truoc: `df -h /var/backups`
  - DB dump yeu cau MariaDB active: `systemctl is-active mariadb`
  - Config archive yeu cau `/etc/ops/` va `/etc/nginx/sites-available/` ton tai
- **Change (DB dump)**:
  - OPS menu: `System & Monitoring -> Backup helpers -> Dump single database`
  - Hoac: `Dump all databases`
  - Output: `/var/backups/ops/db/<dbname>-YYYYMMDD-HHMMSS.sql.gz` (0600)
  - Luu y: `Dump all databases` tao **mot file cho moi non-system database**, khong tao 1 file `all-*.sql.gz`
- **Verify (DB dump)**:
  - `ls -lh /var/backups/ops/db/` -> file ton tai, size > 0
  - `gzip -t /var/backups/ops/db/<dbname>-<ts>.sql.gz` -> no error
  - Test restore (staging only): `gunzip -c /var/backups/ops/db/<dbname>-<ts>.sql.gz | sudo mysql --database="<dbname>"`
- **Change (config archive)**:
  - OPS menu: `Backup helpers -> Archive configs`
  - Output: `/var/backups/ops/config/ops-config-YYYYMMDD-HHMMSS.tar.gz` (0600)
- **Verify (config archive)**:
  - `tar -tzf /var/backups/ops/config/ops-config-<ts>.tar.gz` -> list files without error
  - `ls -lh /var/backups/ops/config/` -> file ton tai, size > 0
- **Restore (manual)**:
  - DB: `gunzip -c /var/backups/ops/db/<dbname>-<ts>.sql.gz | sudo mysql --database="<dbname>"`
  - Nginx: `tar -xzf <archive> -C /etc/nginx/sites-available/ && nginx -t && systemctl reload nginx`
  - OPS config: `tar -xzf <archive> -C /etc/ops/`
  - Secret perms sau restore: `chmod 600 /etc/ops/.* /etc/ops/db-credentials/*.conf 2>/dev/null || true`
  - Secret owners sau restore: `chown <ADMIN_USER>:<ADMIN_USER> /etc/ops/.* /etc/ops/db-credentials/*.conf 2>/dev/null || true`
  - Secret dir perms sau restore: `chmod 700 /etc/ops/db-credentials && chown <ADMIN_USER>:<ADMIN_USER> /etc/ops/db-credentials`
- **Rollback**:
  - Backup files bao gio cung nam o `/var/backups/ops/` — khong bi xoa tu dong
  - Neu restore sai: restore tu backup cu hon
  - Secret files: verify `0600` + admin-owned sau moi restore: `.telegram-bot-token`, `.db-root-password` (neu host legacy dang dung), `.codex-api-key`, `db-credentials/*.conf`

---

## Nginx Upgrade: Ubuntu Package -> Official Mainline

**When:** `nginx -v` shows < 1.24 (e.g. 1.18.0 from Ubuntu repo).

**Steps:**
```bash
# 1. From OPS menu:
# Domains & Nginx -> Install / update Nginx (option 6)
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
# Domains & Nginx -> Apply security baseline (option 8)
# This runs nginx_apply_security_baseline() which calls _nginx_apply_global_tuning() + reload

# Verify all checks pass:
# Main menu -> Verify stack -> check Nginx section for PASS
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
# OPS menu: Domains & Nginx -> Advanced web controls -> option 5
# Writes /etc/nginx/conf.d/cloudflare-ip-restrict.conf
# Then manually add to each server {} block:
#   if ($blocked_cf) { return 444; }
# Then: nginx -t && systemctl reload nginx
```

**Disable:**
```bash
# OPS menu: Domains & Nginx -> Advanced web controls -> option 6
# Removes /etc/nginx/conf.d/cloudflare-ip-restrict.conf
# Then remove any "if ($blocked_cf)" lines from server blocks
# Then: nginx -t && systemctl reload nginx
```

> **Warning:** Never enable CF IP restrict if any domain has Cloudflare proxying disabled (Grey Cloud). It will block all traffic to that domain.

