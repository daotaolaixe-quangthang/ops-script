## OPS Regression Test Cases

Tai lieu nay dinh nghia bo test case chuan cho OPS de moi thay doi hoac tinh nang moi deu di qua cung mot contract verify, giam bug lap lai va loi an.

Ap dung cho:

- `install/ops-install.sh`
- `ops/bin/*`
- `ops/core/*`
- `ops/modules/*`
- templates runtime trong `ops/modules/templates/*`

Muc tieu:

- giu on dinh TUI va menu boundary contract
- chan regression cho Ubuntu 22.04/24.04
- bat cac bug shell/Bash/Linux thuong gap truoc khi merge
- buoc moi thay doi phai co verify ro rang theo impact layer

## 1. Nguyen tac test bat buoc

Moi thay doi trong OPS phai duoc map vao it nhat 1 impact layer:

1. SSH va operator access
2. Nginx, proxy, TLS
3. Node runtime va PM2
4. PHP runtime va PHP-FPM
5. Database
6. Firewall va fail2ban
7. Monitoring, logs, login hooks, TUI

Moi feature/sua bug moi phai di qua 4 lop test:

1. **Static validation**
   - `bash -n` cho script bi anh huong
   - shell strict mode khong bi vo
   - path/runtime contract khong bi drift
2. **Unit-like function validation**
   - test function voi state thieu, state sai, state hop le
   - test non-zero handling o action boundary
3. **Integration/runtime validation**
   - verify file tao ra, service state, process manager, config syntax
4. **Regression validation**
   - re-test nhung bug pattern da tung xay ra trong `docs/reference/KNOWN-RISKS-PATTERNS.md`

## 2. Definition of Done cho thay doi moi

Mot thay doi chi duoc xem la passed khi dap ung du cac dieu kien sau:

- Khong co syntax error: `bash -n` pass tren tat ca script lien quan.
- Khong lam vo menu boundary contract: menu khong thoat bat ngo khi action fail/WARN.
- Co verify ro rang va lap lai duoc tren Ubuntu 22.04 va/hoac 24.04.
- Co rollback toi thieu neu thay doi cham vao SSH, Nginx, DB, PHP, PM2, firewall.
- Khong lam lo secret trong output/log/doc.
- Khong tao runtime drift voi `docs/reference/ARCHITECTURE.md`, `docs/operator/MENU-REFERENCE.md`, `docs/operator/SECURITY-RULES.md`.
- Da chay lai nhom regression lien quan den impact layer cua thay doi.

## 3. Test matrix moi truong

Toi thieu phai cover cac matrix sau:

| ID | Environment | Muc dich |
|---|---|---|
| ENV-01 | Ubuntu 22.04 fresh VPS | baseline install va backward compatibility |
| ENV-02 | Ubuntu 24.04 fresh VPS | current target support |
| ENV-03 | da cai OPS, rerun wizard/module | idempotence |
| ENV-04 | stdin redirect / non-interactive shell | bat bug TTY, prompt, spin loop |
| ENV-05 | host co Node app + PHP site + MariaDB + Nginx | cross-module regression |
| ENV-06 | host co CLIProxyAPI + SSL + systemd | network posture, Nginx, systemd, secret contract |

Khuyen nghi:

- Dung snapshot VPS de rerun nhanh.
- Neu chua co automation, luu ket qua test theo form testcase ID + PASS/FAIL + runtime evidence.

## 4. Test case core regression suite

### 4.1 Installer va first-run

| ID | Test case | Preconditions | Steps | Expected result |
|---|---|---|---|---|
| INS-01 | Install tren Ubuntu 22.04 fresh | VPS sach, login root | Chay installer one-liner | Cai dat hoan tat, clone vao `/opt/ops`, sinh config co ban, khong vo SSH |
| INS-02 | Install tren Ubuntu 24.04 fresh | VPS sach, login root | Chay installer one-liner | Ket qua nhu INS-01 |
| INS-03 | Reject unsupported OS | dung distro/version khac | Chay installer | Script dung an toan, thong bao ro unsupported OS, khong sua he thong nua chung |
| INS-04 | Admin user da ton tai | user admin trung ten da co | Rerun installer/setup | Khong tao user duplicate, xu ly idempotent hoac thong bao ro rang |
| INS-05 | Rerun `ops-setup.sh` | OPS da cai dat | Chay `ops-setup.sh` 2 lan | Symlink, hook, config khong duplicate |
| INS-06 | Login dashboard interactive | SSH vao bang admin user | Dang nhap lai | `ops-dashboard` hien dung trong shell interactive |
| INS-07 | Non-interactive shell khong bi hook | Chay `ssh host command`, scp, rsync | Kiem tra shell hook | Dashboard khong chen vao non-interactive session |
| INS-08 | Login hook dung `SSH_CONNECTION` | Hook da tao | Inspect hook + dang nhap | Dashboard hien on dinh voi client khong set `SSH_TTY` |
| INS-09 | Installer failure rollback toi thieu | Gia lap loi giua qua trinh | Chay installer | Khong de state vo nua chung khien mat SSH/menu |

### 4.2 TUI, menu, prompt, shell behavior

| ID | Test case | Preconditions | Steps | Expected result |
|---|---|---|---|---|
| TUI-01 | Main menu render du labels | OPS da cai | Chay `ops` | Menu hien du muc theo `docs/operator/MENU-REFERENCE.md` |
| TUI-02 | Invalid option khong crash | Dang o main menu | Nhap ky tu la | Hien warn, menu tiep tuc |
| TUI-03 | Timeout TTY exit clean | Dang o main menu | De qua timeout hoac mat tty | Process exit 0, khong spin CPU 100% |
| TUI-04 | Chay `ops` trong non-tty | Pipe/redirect stdin stdout | Chay `ops < /dev/null` | Thong bao can interactive terminal, exit sach |
| TUI-05 | Moi `menu_*` return 0 boundary | Action ben trong fail co kiem soat | Mo submenu va kich hoat action fail | Menu van con, khong bi thoat ra shell |
| TUI-06 | Verify action FAIL/WARN khong thoat menu | Tao truoc 1 runtime issue | Chay verify tu menu | Hien PASS/WARN/FAIL nhung menu van tiep tuc |
| TUI-07 | Prompt visible khi doc tu `/dev/tty` | stdin redirect | Chay menu/confirm co redirect | Prompt van hien, khong bi mat do `read -p ... 2>/dev/null` |
| TUI-08 | Exit option thoat dung | Dang o menu | Chon `0` | Thoat sach, khong de lock stale |
| TUI-09 | Session lock chong 2 session song song | Mo 2 terminal | Chay `ops` o ca 2 | Session thu 2 bi chan voi thong bao ro rang |
| TUI-10 | Lock duoc giai phong sau exit | Session 1 da thoat | Chay lai `ops` | Vao binh thuong, khong bi stale lock |

### 4.3 Security, SSH, UFW, fail2ban

| ID | Test case | Preconditions | Steps | Expected result |
|---|---|---|---|---|
| SEC-01 | Khong disable password auth khi chua co SSH key | `authorized_keys` rong | Chay Security Baseline | Prompt disable password auth khong duoc hien, gia tri giu `yes` |
| SEC-02 | Co key moi cho disable password auth | Da co it nhat 1 public key | Chay Security Baseline | Co prompt va disable thanh cong neu user xac nhan |
| SEC-03 | SSH transition mo ca 2 port | Dang doi port SSH | Chay flow doi port | Port moi va port transition cung hoat dong truoc khi finalize |
| SEC-04 | Finalize SSH khong lockout | Da dang nhap duoc qua port moi | Dong 22/finalize | Van SSH duoc bang port moi |
| SEC-05 | UFW baseline mo dung port | Da harden xong | Kiem tra `ufw status` | Chi mo SSH managed port, `80`, `443`, va transition port neu con |
| SEC-06 | 8317 khong public allow | CLIProxyAPI da cai | Kiem tra UFW | Khong co `ALLOW 8317` |
| SEC-07 | fail2ban sshd jail dung port | Doi SSH port | Chay verify | jail `sshd` map dung port theo OPS state |
| SEC-08 | Root login bi khoa | Hardening xong | Kiem tra `sshd -T` | `PermitRootLogin no` |
| SEC-09 | Forwarding flags bi tat | Hardening xong | Kiem tra `sshd -T` | `x11forwarding no`, `allowtcpforwarding no`, `allowagentforwarding no` |

### 4.4 Nginx, domain, SSL

| ID | Test case | Preconditions | Steps | Expected result |
|---|---|---|---|---|
| WEB-01 | Install/update Nginx an toan | Nginx chua co hoac can update | Chay menu install/update | `nginx -t` pass, service active |
| WEB-02 | Add Node domain | Da co PM2 app | Tao domain backend Node | Vhost tao dung, `/etc/ops/domains/<domain>.conf` duoc ghi, reload ok |
| WEB-03 | Add PHP domain | PHP-FPM da co | Tao domain backend PHP | FastCGI target dung version/pool |
| WEB-04 | Add static domain | Nginx active | Tao static site | Web root duoc tao, ownership dung |
| WEB-05 | Remove domain khong xoa web root | Domain ton tai | Remove domain | Xoa state + nginx config, giu `/var/www/<domain>` |
| WEB-06 | Reload bi chan khi config loi | Co vhost loi cu phap | Chay test/reload | `nginx -t` fail thi khong reload |
| WEB-07 | SSL issue thanh cong | Domain tro dung DNS | Issue cert | Cert duoc tao, vhost SSL hoat dong |
| WEB-08 | SSL status hien dung domain het han/khong co cert | Co domain co va khong co cert | Chay status | Hien du expiry/status ro rang |
| WEB-09 | CLIProxyAPI vhost giu `proxy_buffering off` | CLIProxyAPI domain da link | Inspect vhost | Co `proxy_buffering off`, proxy toi `127.0.0.1:8317` |
| WEB-10 | Nginx van la public entrypoint duy nhat | CLIProxyAPI/Node app da chay | Test public va local binding | Backend bind localhost, public truy cap qua Nginx |

### 4.5 Node.js va PM2

| ID | Test case | Preconditions | Steps | Expected result |
|---|---|---|---|---|
| NODE-01 | Install Node LTS + PM2 | Host chua co Node | Chay wizard/module | Node LTS va PM2 cai thanh cong |
| NODE-02 | PM2 startup khong chay duoi root | PM2 da cai | Kiem tra unit | Co `pm2-<runtime_user>.service`, khong co `pm2-root.service` |
| NODE-03 | `pm2 list` trong OPS dung runtime user | Co app da chay | List app tu menu | Hien dung app, khong false empty |
| NODE-04 | Add Node app | Co source app | Add app qua menu | Tao state file, ecosystem, PM2 process online |
| NODE-05 | Restart app | Co app trong PM2 | Restart qua menu | App restart thanh cong, khong mat state |
| NODE-06 | Show logs | Co app co log | Xem logs qua menu | Hien log dung app, khong crash |
| NODE-07 | Remove app | Co app da register | Remove qua menu | Xoa process + state, backup conf neu co |
| NODE-08 | Ecosystem co `merge_logs: true` | Co ecosystem duoc tao | Inspect file | Log filename on dinh, khong bi suffix `-0` |
| NODE-09 | Co `pm2-logrotate` sau install PM2 | PM2 da cai | Kiem tra module PM2 | Log rotation da duoc cai |
| NODE-10 | `max_memory_restart` di kem `node_args` phu hop | Ecosystem co memory limit | Inspect ecosystem | Giam nguy co OOM truoc nguong restart |

### 4.6 CLIProxyAPI

| ID | Test case | Preconditions | Steps | Expected result |
|---|---|---|---|---|
| CPA-01 | Install CLIProxyAPI | Host co curl/tar, systemd san sang | Chay install CLIProxyAPI | Binary vao `/opt/cli-proxy-api`, service online |
| CPA-02 | CLIProxyAPI bind localhost only | CLIProxyAPI da cai | Kiem tra port listen | Chi bind `127.0.0.1:8317` |
| CPA-03 | Secret files dung permission | CLIProxyAPI da cai | Kiem tra `/etc/ops/.cli-proxy-api-key` | File `0600`, owner admin user |
| CPA-04 | Link CLIProxyAPI vao domain | Domain san DNS | Chay link domain | Nginx proxy `127.0.0.1:8317`, `proxy_buffering off` |
| CPA-05 | Verify CLIProxyAPI khi local ok, public qua nginx | CLIProxyAPI va nginx active | Chay verify + curl local/public | `/v1/models` tra JSON local, public di qua Nginx |
| CPA-06 | Toggle API key requirement | CLIProxyAPI da cai | Enable/Disable API key requirement | `config.yaml` va `/etc/ops/cli-proxy-api.conf` cap nhat dung, service restart |
| CPA-07 | Update CLIProxyAPI giu config va state | CLIProxyAPI da co du lieu | Chay update | Binary duoc cap nhat, config/state duoc preserve |
| CPA-08 | SSL re-render vhost | Domain CLIProxyAPI da co SSL | Link/reissue SSL | Vhost duoc re-render, Nginx tiep tuc proxy HTTPS -> localhost |
| CPA-09 | CLIProxyAPI schema contract | Co source module | Inspect `cli-proxy-api.sh` | `oauth-model-alias` va payload filter van duoc giu dung |
| CPA-10 | Quota helper `cpaq` duoc quan ly idempotent | Quota Inspector duoc cai/re-cai | Inspect `~/.bashrc` admin | Chi co 1 block marker OPS cho `cpaq()` |
| CPA-11 | Quota shortcut chay mac dinh gon | Quota Inspector da cai | Reload shell va chay `cpaq` | Su dung binary quota inspector voi `--summary-only --no-progress` |
| CPA-12 | Management key van explicit | CPA bat management auth | Check flow + warning | OPS khong auto-persist `CPA_MANAGEMENT_KEY`; operator tu export khi can |
| CPA-13 | Menu Check quota co san | Vao menu CLIProxyAPI | Xem submenu/chay option 14 | Co `14) Check quota`, neu thieu inspector thi OPS hoi cai truoc |
| CPA-14 | Bootstrap auth co submenu account type | Vao menu CLIProxyAPI | Chon `13) Bootstrap auth providers` | Hien submenu `Antigravity` / `Gemini` / `Claude Code` / `Codex` va goi dung login flag |

### 4.7 PHP / PHP-FPM

| ID | Test case | Preconditions | Steps | Expected result |
|---|---|---|---|---|
| PHP-01 | Cai duoc cac version muc tieu | Host sach | Cai PHP 7.4/8.1/8.2/8.3 | Package va service FPM len dung |
| PHP-02 | CLI va FPM mapping dung | Co site PHP | Kiem tra version CLI, pool, fastcgi | Khong mismatch ngoai y muon |
| PHP-03 | Tao PHP site | PHP-FPM active | Add domain backend PHP | Site response dung qua socket/pool |
| PHP-04 | App co `disable_functions` nhay bug | App mau dung `exec()` | Truy cap app sau hardening | Loi duoc phat hien trong logs; khong sua global vo toi va |
| PHP-05 | App co `allow_url_fopen` dependency | App mau dung `file_get_contents('https://')` | Truy cap app | Phat hien regression va xu ly per-pool neu can |
| PHP-06 | Pool override khong anh huong global | Da them override cho 1 site | Kiem tra site khac | Chi pool muc tieu thay doi |

### 4.8 Database

| ID | Test case | Preconditions | Steps | Expected result |
|---|---|---|---|---|
| DB-01 | Install MariaDB default | Host sach | Cai DB qua wizard/module | Service active, state file duoc ghi |
| DB-02 | Root secret file dung permission | DB da cai | Kiem tra `/etc/ops/.db-root-password` | `0600`, owner admin user |
| DB-03 | Secure setup khong vo app ket noi | Co app dung DB | Chay secure/tuning | App van ket noi duoc sau moi thay doi quan trong |
| DB-04 | Bind address dung posture | DB da cai | Kiem tra config | Bind localhost theo baseline neu khong co yeu cau khac |
| DB-05 | Tao DB/user | DB active | Tao DB + user | Dang nhap bang user moi duoc |
| DB-06 | Backup helper dump DB | DB co du lieu | Chay backup helper | Dump file hop le, khong lo password ra log |

### 4.9 Monitoring, verify, logs, scheduler

| ID | Test case | Preconditions | Steps | Expected result |
|---|---|---|---|---|
| MON-01 | Verify stack tra PASS/WARN/FAIL nhung exit 0 | Tao 1 issue co kiem soat | Chay verify tu menu va shell | Output dung format, command/menu boundary khong vo |
| MON-02 | Quick logs path ton tai | Services da chay | Xem quick logs | Khong crash khi file rong/thieu, thong bao hop ly |
| MON-03 | Monitoring menu khong thoat khi 1 check fail | Gia lap service down | Vao System & Monitoring | Menu van song |
| MON-04 | Scheduler/check scripts idempotent | Cron/timer da ton tai | Rerun install checks | Khong duplicate job |
| MON-05 | Notification disable path an toan | Telegram chưa config | Chay test notification / disable | Khong crash, thong bao ro missing config |

### 4.10 Secrets, permissions, files

| ID | Test case | Preconditions | Steps | Expected result |
|---|---|---|---|---|
| FILE-01 | Secret files luon 0600 | Da cai cac module co secret | Kiem tra `/etc/ops/.*` | Moi file secret la `0600`, owner admin user |
| FILE-02 | Script khong in secret ra terminal | Chay install/configure secrets | Quan sat output/log | Khong xuat raw password/token |
| FILE-03 | Config files shell-sourceable hop le | Co file `/etc/ops/*.conf` | Source/parse file | Khong vo syntax, key=value nhat quan |
| FILE-04 | Backup truoc khi rewrite config quan trong | Sua SSH/Nginx/PHP/systemd config | Chay action | Co backup rollback duoc |
| FILE-05 | Web root ownership dung | OPS tao PHP/static root | Kiem tra perm | `$ADMIN_USER:www-data`, mode mong doi |

## 5. Nhom hidden bug regression bat buoc

Day la nhom bug phai retest moi khi co thay doi lien quan, vi da xuat hien hoac rat de tai phat:

| ID | Bug pattern | Bat buoc retest khi |
|---|---|---|
| REG-01 | Prompt bi mat do `read -p ... < /dev/tty 2>/dev/null` | sua prompt/menu/confirm/input |
| REG-02 | Menu thoat do action return non-zero duoi `set -e` | sua `bin/ops`, `menu_*`, verify actions |
| REG-03 | Verify action FAIL lam thoat menu | sua monitoring/verify/checks |
| REG-04 | SSH lockout do disable password auth khi chua co key | sua installer, security, setup wizard |
| REG-05 | Login hook pha shell non-interactive | sua `ops-dashboard`, hook shell, `ops-setup.sh` |
| REG-06 | CLIProxyAPI bi expose cong khai | sua module provider, nginx, ufw, verify |
| REG-07 | PM2 startup chay root | sua node install, PM2 integration |
| REG-08 | `pm2 list` false empty do sai runtime user | sua node menu, runtime wrappers |
| REG-09 | Secret permission drift | sua module ghi file secret |
| REG-10 | Config rewrite duplicate/sai vi tri lam vo syntax | sua logic `sed`, append, template rendering |
| REG-11 | Nginx CLIProxyAPI vhost vo `proxy_buffering off` hoac proxy sai port | sua nginx hardening/template |
| REG-12 | Log grow vo han / filename suffix drift | sua PM2 ecosystem, logrotate |

## 6. Quy trinh test khi them/chinh sua 1 chuc nang moi

1. Xac dinh impact layer cua thay doi.
2. Chay `bash -n` cho file vua sua va file source/noi goi truc tiep.
3. Chay lai toan bo nhom regression `REG-*` lien quan.
4. Chay test integration cua module bi anh huong.
5. Chay it nhat 1 test end-to-end tu menu cha den runtime state.
6. Neu co config rewrite: verify syntax + backup + rollback.
7. Neu co service/process: verify active state, port posture, log, restart path.
8. Neu co secret: verify permission, ownership, khong leak output.
9. Neu co docs/menu contract thay doi: cap nhat `docs/operator/MENU-REFERENCE.md`, `docs/reference/ARCHITECTURE.md`, va docs lien quan.

## 7. Checklist review nhanh truoc merge

- `bash -n` pass cho file sua.
- Khong co `read -p ... < /dev/tty 2>/dev/null`.
- Khong them `|| true` o `bin/ops` de che menu bug.
- Moi `menu_*` boundary van `return 0`.
- Verify functions van return 0 va chi render ket qua.
- Moi thay doi Nginx/SSH/PHP/systemd deu co syntax test truoc reload/restart.
- Khong co secret hard-code trong repo, log, docs.
- Secret files moi co `chmod 600` va `chown` dung user.
- Node services van di qua PM2, khong drift sang wrapper tu phat.
- CLIProxyAPI van bind `127.0.0.1:8317`, khong public allow UFW.
- Domain remove khong xoa web root.
- Login dashboard chi hien trong interactive SSH session.

## 8. Mau ghi nhan ket qua test

Dung form sau cho moi thay doi:

```text
Change:
Impact layers:
Environment:

Executed:
- INS-__ : PASS/FAIL
- TUI-__ : PASS/FAIL
- REG-__ : PASS/FAIL

Evidence:
- command:
- key output:
- runtime files checked:

Rollback checked:
- yes/no
- minimum rollback path:

Notes:
```

## 9. Minimum smoke suite theo loai thay doi

### 9.1 Neu sua menu/TUI/prompt

Bat buoc chay:

- `TUI-01` den `TUI-10`
- `REG-01`, `REG-02`, `REG-03`, `REG-05`

### 9.2 Neu sua security/SSH/UFW

Bat buoc chay:

- `SEC-01` den `SEC-09`
- `REG-04`, `REG-09`, `REG-10`

### 9.3 Neu sua Nginx/domain/SSL/CLIProxyAPI

Bat buoc chay:

- `WEB-01` den `WEB-10`
- `CPA-02`, `CPA-04`, `CPA-05`, `CPA-08`
- `REG-06`, `REG-10`, `REG-11`

### 9.4 Neu sua Node/PM2

Bat buoc chay:

- `NODE-01` den `NODE-10`
- `REG-07`, `REG-08`, `REG-12`

### 9.5 Neu sua PHP/DB/monitoring

Bat buoc chay:

- `PHP-01` den `PHP-06`
- `DB-01` den `DB-06`
- `MON-01` den `MON-05`
- `REG-03`, `REG-09`, `REG-10`

## 10. Huong mo rong sau nay

Khi OPS co automation test, tai lieu nay se la source de chuyen thanh:

- shell regression harness
- golden output tests cho TUI
- VM snapshot acceptance tests
- verify/health contract tests

Trong luc chua co harness day du, `docs/reference/TEST-CASES.md` la baseline review va QA gate bat buoc cho moi thay doi.

## 11. Shell regression harness

Repo hien co shell regression harness contract-level tai:

- `ops/tests/regression/run-all.sh`
- `ops/tests/regression/tui-suite.sh`
- `ops/tests/regression/reg-suite.sh`
- `ops/tests/regression/lib.sh`

Pham vi cover hien tai:

- `TUI-01..TUI-10`
- `REG-01..REG-15`
- contract/static coverage cho `SEC-01..SEC-09`, `INS-01..INS-09`, `WEB-01..WEB-10`, `NODE-01..NODE-10`, `PHP-01..PHP-06`, `DB-01..DB-06`, `CPA-01..CPA-08`, `MON-01..MON-05`, `FILE-01..FILE-04`

Muc dich:

- chay nhanh tren VM snapshot truoc release
- chay sau moi bug fix de chan tai phat
- lam gate toi thieu truoc khi duyet thay doi lien quan TUI/menu/regression contracts

Lenh chay:

```bash
bash /opt/ops/tests/regression/run-all.sh
```

Hoac trong repo:

```bash
bash ops/tests/regression/run-all.sh
```

Gioi han hien tai:

- day la contract/regression harness muc shell-level, uu tien bat drift va bug tai phat
- nhieu case ngoai `TUI-*`/`REG-*` dang la static-contract assertions, khong thay the verify runtime that
- chua thay the full end-to-end runtime acceptance tren VPS test
- cac case can TTY that, SSH that, UFW/Nginx/PM2 runtime that van phai duoc chay theo smoke/integration suite trong release gate
