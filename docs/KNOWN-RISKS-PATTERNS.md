## OPS Known Risks Patterns

Muc tieu: liet ke cac pattern de AI Agent san loi tiem an va review thay doi an toan hon.

## 1) Installer va runtime drift

- **Pattern**:
  - installer setup mot kieu, runtime bi sua tay sau do
- **Rui ro**:
  - doc docs dung nhung production van sai
- **Safe action**:
  - debug bang runtime truth, khong chi docs

## 2) SSH transition lockout

- **Pattern**:
  - doi port SSH va dong port 22 qua som
- **Rui ro**:
  - mat truy cap VPS
- **Safe action**:
  - mo ca 2 port trong transition, verify login moi truoc khi dong 22

## 3) Nginx la public entrypoint duy nhat

- **Pattern**:
  - Node app hoac 9router bi expose thang ra public
- **Rui ro**:
  - bo qua TLS, rate limit, host validation, default deny
- **Safe action**:
  - app chi bind localhost hoac unix socket

## 4) PM2 ownership drift cho Node services

- **Pattern**:
  - Node services duoc quan ly mot phan bang PM2, mot phan bang script tay hoac wrappers khong ro contract
- **Rui ro**:
  - restart loop, status sai, startup state kho truy vet
- **Safe action**:
  - PM2 la process manager duy nhat cho Node services
  - docs phai ghi app nao duoc PM2 quan ly

## 5) Node runtime va app runtime mismatch

- **Pattern**:
  - CLI Node version khac version ma app service dang chay
- **Rui ro**:
  - test bang shell thay on, nhung service van loi
- **Safe action**:
  - verify ca runtime cua process manager va shell

## 6) PHP CLI va PHP-FPM mismatch

- **Pattern**:
  - PHP CLI version khac PHP-FPM version cua site
- **Rui ro**:
  - debug sai huong
- **Safe action**:
  - verify ca CLI, pool, fastcgi mapping

## 7) Config rewrite lam vo syntax

- **Pattern**:
  - `sed`/append vao Nginx, PHP-FPM, sshd, systemd config
- **Rui ro**:
  - duplicate block, line sai vi tri, service fail to reload
- **Safe action**:
  - backup truoc
  - syntax test sau
  - diff va rollback ro rang

## 8) DB secure setup/tuning gay outage

- **Pattern**:
  - secure setup hoac tuning doi qua nhieu trong 1 lan
- **Rui ro**:
  - app mat ket noi DB
- **Safe action**:
  - doi tung nhom setting
  - verify app ket noi sau moi thay doi quan trong

## 9) Secrets leak qua logs/docs

- **Pattern**:
  - in password/token ra terminal hoac log
- **Rui ro**:
  - lo secret production
- **Safe action**:
  - chi ghi vi tri secret
  - file secret permission chat

## 10) Login hooks gay hong shell path

- **Pattern**:
  - dashboard/login hook chen vao shell rc mot cach khong guard interactive shell
- **Rui ro**:
  - scp/non-interactive shell bi hong
- **Safe action**:
  - guard interactive shell ro rang
  - co rollback hook nhanh

## 11) Node-first nhung PHP phu bi bo quen

- **Pattern**:
  - toi uu he thong cho Node app nhung khong giu contract cho PHP sites phu
- **Rui ro**:
  - PHP sites bi nghet pool, wrong fastcgi, wrong file perms
- **Safe action**:
  - tach global defaults va per-backend overrides

## 12) Clone logic theo syntax thay vi theo capability

- **Pattern**:
  - copy setup tu project khac theo lenh/syntax cu the
- **Rui ro**:
  - mang theo phu thuoc stack cu, script kho maintain
- **Safe action**:
  - clone capability, source of truth, verify/rollback discipline

## 13) 9router HOSTNAME=0.0.0.0 va UFW check

- **Pattern**:
  - sau khi install 9router, quet port tren server thay port 20128 "mo" (netstat/ss bind 0.0.0.0)
  - tuong nham rang UFW da expose port nay ra ngoai
- **Rui ro**:
  - UFW co the da block, nhung neu ai do chay `ufw allow 20128` nham la 9router bi expose truc tiep
- **Safe action**:
  - 9router BUOC PHAI bind HOSTNAME=0.0.0.0 (Next.js requirement)
  - Bao mat phu thuoc vao UFW (port 20128 KHONG duoc allow) va Nginx (proxy in front)
  - Luon verify: `ufw status | grep 20128` phai tra ve trong sau moi install/update 9router
  - Neu co doubt: `curl -x "" http://<PUBLIC_IP>:20128` tu ngoai phai bi tu choi (timeout/refused)

## 14) Secret files permissions drift

- **Pattern**:
  - `/etc/ops/.nine-router-password`, `/etc/ops/.db-root-password`, `/etc/ops/.codex-api-key`
    bi su dung trong script va vu tinh doi permission hoac owned by root
- **Rui ro**:
  - admin user khong doc duoc secret, hoac secret bi lo neu group-readable
- **Safe action**:
  - Chay sau moi install/update: `ls -la /etc/ops/.*` verify 0600 owned by admin user
  - Bat ky script nao ghi file secret phai co: `chmod 600 <file> && chown $ADMIN_USER:$ADMIN_USER <file>`

## 15) Verify action exit non-zero lam menu loop thoat

- **Pattern**:
  - verify function (vi du `verify_stack`, `verify_service_health`) tra ve exit code khac 0 khi detect issue
  - caller menu dung `set -e` hoac khong guard return code neu function fail
- **Rui ro**:
  - Menu exit ngoai y muon sau khi user chon "Verify stack health" — da xay ra o Phase 1
  - User khong biet menu da thoat, tuong rang verify da pass
- **Safe action**:
  - Moi verify function PHAI return 0 \u2014 in PASS/WARN/FAIL len screen, KHONG propagate exit code
  - Caller menu PHAI wrap: `verify_stack || true`
  - Contract ro trong `P2-04`: PASS/WARN/FAIL deu exit 0; caller xu ly display, khong xu ly exit code
  - Khi review bat ky verify action nao: kiem tra ro ket qua khi co FAIL co lam menu thoat khong

## 16) PHP disable_functions breaking existing apps

- **Pattern**: OPS sets `disable_functions` in `php.ini`; existing app calls `exec()`, `shell_exec()`, or `system()`.
- **Risk**: App breaks silently (PHP logs error, browser sees 500 since `display_errors=Off`).
- **Safe action**:
  - After PHP tuning, check app-specific PHP error logs (`/var/log/php*.log`, `/var/log/nginx/*.error.log`).
  - If an app legitimately needs one of the blocked functions, add a **per-pool** `php_admin_value disable_functions ""` override inside that pool's `.conf` file only.
  - Do NOT globally re-enable `disable_functions` to fix one app.

## 17) PM2 startup configured as root

- **Pattern**: `pm2 startup` was run as root, so the service unit runs as root and all PM2-managed processes inherit root context.
- **Risk**: Any RCE in a Node.js app grants full root access to the VPS.
- **Safe action**:
  - Run `pm2 startup systemd -u <runtime_user> --hp <home>` as root to generate the unit for the correct user.
  - OPS `node_install_pm2` does this automatically using `_node_runtime_user()`.
  - Verify: `systemctl list-unit-files | grep pm2` should show `pm2-<runtime_user>.service`, NOT `pm2-root.service`.

## 18) allow_url_fopen = Off breaking app integrations

- **Pattern**: OPS sets `allow_url_fopen = Off`; PHP app uses `file_get_contents('https://...')` for external API calls (e.g. payment gateway, SMS provider).
- **Risk**: External API calls silently return `false` or empty string; app behaves unexpectedly.
- **Safe action**:
  - Replace `file_get_contents('https://...')` with a cURL implementation.
  - If a short-term workaround is needed, add `php_admin_value allow_url_fopen On` in that FPM pool's `.conf` file (not globally in `php.ini`).
  - Do NOT re-enable `allow_url_fopen` globally — it opens SSRF risk.

## 19) pm2 list shows empty when run as root

- **Pattern**: OPS menu calls bare `pm2 list` as root → connects to root's PM2 daemon, which has no apps (apps run under opsuser's PM2).
- **Risk**: Appears as if no apps are running (false negative); operator may restart or reinstall running apps unnecessarily.
- **Safe action**: Always invoke PM2 via `_node_run_as_runtime_user pm2 list` inside OPS scripts. When debugging manually: `su opsuser -c "HOME=/home/opsuser PM2_HOME=/home/opsuser/.pm2 pm2 ls"`.

## 20) PM2 logs grow unbounded without pm2-logrotate

- **Pattern**: `pm2-logrotate` not installed; `/var/log/ops/*.log` grows indefinitely without a size cap.
- **Risk**: Disk fills up; log write failures can cause PM2 to crash processes or refuse to write error output.
- **Safe action**: Install `pm2-logrotate` immediately after PM2: `pm2 install pm2-logrotate`. OPS `node_install_pm2` does this automatically.

## 21) PM2 log filenames get -0 suffix when merge_logs missing

- **Pattern**: Ecosystem config missing `merge_logs: true` → PM2 appends `-<instance_id>` to log filenames (e.g. `nine-router.err-0.log` instead of `nine-router.err.log`).
- **Risk**: Log rotation rules, monitoring scripts, and logrotate configs that reference the filename without suffix stop working.
- **Safe action**: Always set `merge_logs: true` in all ecosystem configs. OPS templates include this by default.

## 22) Node.js heap OOM before PM2 memory restart triggers

- **Pattern**: `max_memory_restart` set in ecosystem (e.g. `512M`) but no `--max-old-space-size` in `node_args` → Node.js V8 uses system default heap limit (can be >1.5GB) → Node crashes with OOM before PM2 can gracefully restart it.
- **Risk**: Hard crash instead of graceful restart; in-flight requests are lost without graceful shutdown.
- **Safe action**: Set `node_args: "--max-old-space-size=<N>"` to ≈90% of `max_memory_restart` (e.g. `460` for 512M restart). This makes V8 GC aggressive at the threshold and allows PM2 to trigger a clean restart.
