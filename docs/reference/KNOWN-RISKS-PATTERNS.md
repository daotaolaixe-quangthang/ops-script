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

- **Pattern**: doi port SSH va dong port 22 qua som
- **Risk**: mat truy cap VPS
- **Safe action**: mo ca 2 port trong transition, verify login moi truoc khi dong 22

## 2b) PasswordAuthentication disabled without SSH key -- FIXED

- **Pattern**:
  - Setup Wizard (1>1) or Security menu (Harden SSH) disables `PasswordAuthentication` before any
    SSH public key has been added to `~/.ssh/authorized_keys`.
- **Risk**: Complete SSH lockout -- operator cannot log in with password OR key.
- **Root cause (historical)**: Script did not check for key presence before offering the prompt.
- **Fix applied**: `_security_has_authorized_keys()` guard in `security_wizard_baseline()` and
  `security_harden_ssh()`. If no key exists, disable prompt is suppressed and auth stays `yes`.
- **Recovery (if already locked out)**:
  ```bash
  # Via VPS console (KVM/VNC):
  sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' \
      /etc/ssh/sshd_config.d/99-ops-hardening.conf
  systemctl reload ssh
  # Then add SSH key via: ops -> Security -> Manage SSH Keys (option 8)
  ```

## 3) Nginx la public entrypoint duy nhat

- **Pattern**:
  - Node app hoac CLIProxyAPI bi expose thang ra public
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

## 13) CLIProxyAPI network posture va UFW check

- **Pattern**:
  - doc note cu/ngoai repo roi "sua" provider bind thanh `0.0.0.0`
  - hoac mo public port `8317`
  - hoac bat `remote-management.allow-remote: true` ma khong co nhu cau ro rang
- **Rui ro**:
  - CLIProxyAPI bi expose sai posture va bypass public edge policy cua Nginx
  - management surface mo rong ngoai y muon
- **Safe action**:
  - CLIProxyAPI trong OPS hien tai BUOC PHAI bind `127.0.0.1:8317`
  - Nginx la public entrypoint duy nhat cho CLIProxyAPI
  - `ufw allow 8317` la sai
  - `remote-management.allow-remote` mac dinh phai la `false`
  - `pprof.enable` mac dinh phai la `false`
  - Source of truth: `ops/modules/cli-proxy-api.sh`, `ops/modules/nginx.sh`, `ops/modules/verify.sh`, `ops/modules/templates/nginx/cli-proxy-api.vhost.conf.tpl`
  - Luon verify: `ufw status | grep 8317` khong duoc co `ALLOW`; `curl http://127.0.0.1:8317/v1/models` phai truy cap duoc local; public path phai di qua Nginx

## 14) Secret files permissions drift

- **Pattern**:
  - `/etc/ops/.cli-proxy-api-key`, `/etc/ops/.db-root-password`, `/etc/ops/.codex-api-key`
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
  - Caller menu KHONG duoc dua vao `verify_stack || true` nhu cach sua tam
  - Contract ro trong `P2-04`: PASS/WARN/FAIL deu exit 0; caller xu ly display, khong xu ly exit code
  - Dung wrapper menu-local de hap thu action-level non-zero:
    ```bash
    _monitoring_menu_run verify_stack; press_enter
    ```
  - Khi review bat ky verify action nao: kiem tra ro ket qua khi co FAIL co lam menu thoat khong

## 15.1) Menu boundary contract bi drift ve `|| true`

- **Pattern**:
  - `menu_*` hoac action trong menu tra ve non-zero
  - menu cha / `bin/ops` them `|| true` de chong thoat TUI
- **Rui ro**:
  - Contract bi an trong caller thay vi nam o boundary cua menu
  - Them menu moi rat de quen guard va tai phat bug menu exit
  - Code review kho phan biet dau la soft-failure hop le, dau la loi can xu ly that
- **Safe action**:
  - Moi `menu_*` PHAI `return 0` tai boundary
  - Action-level non-zero CHI duoc hap thu boi wrapper menu-local
  - `bin/ops` chi goi `menu_*` truc tiep, khong dung `menu_x || true`
  - Khi them menu moi, ap dung pattern:
    ```bash
    menu_x() {
        _menu_x_run() {
            "$@"
            return 0
        }

        while true; do
            case "$choice" in
                1) _menu_x_run x_action; press_enter ;;
                0) return 0 ;;
            esac
        done
    }
    ```

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

- **Pattern**: Ecosystem config missing `merge_logs: true` -> PM2 appends `-<instance_id>` to log filenames (e.g. `app.err-0.log` instead of `app.err.log`).
- **Risk**: Log rotation rules, monitoring scripts, and logrotate configs that reference the filename without suffix stop working.
- **Safe action**: Always set `merge_logs: true` in all ecosystem configs. OPS templates include this by default.

## 22) Node.js heap OOM before PM2 memory restart triggers

- **Pattern**: `max_memory_restart` set in ecosystem (e.g. `512M`) but no `--max-old-space-size` in `node_args` → Node.js V8 uses system default heap limit (can be >1.5GB) → Node crashes with OOM before PM2 can gracefully restart it.
- **Risk**: Hard crash instead of graceful restart; in-flight requests are lost without graceful shutdown.
- **Safe action**: Set `node_args: "--max-old-space-size=<N>"` to ≈90% of `max_memory_restart` (e.g. `460` for 512M restart). This makes V8 GC aggressive at the threshold and allows PM2 to trigger a clean restart.

## 17) Nginx from Ubuntu distro repo — old version with CVEs

**Risk:** Ubuntu 20.04/22.04 ships nginx/1.18.0. CVE-2021-23017 (1-byte DNS overwrite) and other post-1.18 CVEs exist. Running distro nginx on a production server is a policy violation.

**Detection:** `nginx -v` shows version < 1.24 **or** `_vs_check_nginx` reports WARN on version.

**Fix:** Run OPS: `Domains & Nginx → Install Nginx`. The `_nginx_add_official_repo()` function adds nginx.org mainline repo + apt pin and upgrades.

---

## 18) `gzip on` without `gzip_types` — nearly useless gzip

**Risk:** The default Nginx gzip config only compresses `text/html`. Without `gzip_types`, JS, CSS, JSON — the bulk of application payload — are sent uncompressed.

**Detection:** `nginx -T | grep gzip_types` returns empty **or** `_vs_check_nginx` WARN on gzip.

**Fix:** Run OPS: `Domains & Nginx → Apply security baseline (option 8)`. `_nginx_patch_gzip_block()` replaces the bare `gzip on` with a full config including `gzip_types`.

---

## 19) No rate limiting in Nginx — origin DoS possible if CF bypass

**Risk:** Without `limit_req_zone` / `limit_conn_zone`, if the VPS IP is discovered and Cloudflare is bypassed, an attacker can send unlimited requests directly to the origin.

**Detection:** `nginx -T | grep limit_req_zone` returns empty **or** `_vs_check_nginx` WARN on rate limit.

**Fix:** Run OPS: `Domains & Nginx → Apply security baseline`. Rate limit zones are defined globally; vhosts enforce `limit_req zone=ops_req burst=200 nodelay`.

---

## 20) `listen 443 ssl` without `http2` — forced HTTP/1.1

**Risk:** HTTP/2 provides multiplexing and header compression. Without `http2` in the listen directive, all HTTPS traffic uses HTTP/1.1 even on modern clients.

**Detection:** `nginx -T | grep "443 ssl" | grep -v http2` returns matches **or** `_vs_check_nginx` WARN on http2.

**Fix:** Rebuild vhost via OPS after running `Apply security baseline`. All inline vhost renders now emit `listen 443 ssl http2;`.

---

## 23) `read -p` prompt bị nuốt khi `< /dev/tty` + `2>/dev/null` — FIXED (3 lần)

- **Pattern**:
  - Dùng `read -r -t N -p "Label: " var < /dev/tty 2>/dev/null` để đọc input từ TTY
  - `-p` ghi prompt ra **stderr**; `2>/dev/null` redirect stderr vào /dev/null → prompt biến mất
- **Risk**: Menu chính hoặc submenu hiển thị trống, không có nhãn `Select:` / `Confirm [y/N]:` → user mất orientation
- **Root cause**: Bash `read -p` viết prompt ra fd 2 (stderr). Redirecting `2>/dev/null` ẩn hoàn toàn.
- **Lịch sử**: Đã xảy ra và fix **3 lần** trong project. Lần cuối fix tại `bin/ops` dòng 79 (2026-03-24).
- **Safe action — LUÔN dùng pattern này**:
  ```bash
  # ✅ ĐÚNG
  printf "Select: " > /dev/tty
  read -r -t 300 choice < /dev/tty

  printf "Confirm [y/N]: " > /dev/tty
  read -r answer < /dev/tty
  ```
  ```bash
  # ❌ SAI — prompt bị nuốt bởi 2>/dev/null
  read -r -p "Select: " choice < /dev/tty 2>/dev/null
  ```
- **Áp dụng cho**: mọi main menu, submenu, confirm prompt (y/n), password prompt khi stdin bị redirect
