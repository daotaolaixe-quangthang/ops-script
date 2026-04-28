## OPS Phase 1 Implementation Spec

Muc tieu: bien `Phase 1` tu roadmap thanh spec thuc thi co the code, test, review theo tung task nho.

Phase 1 chi tap trung vao:

- Ubuntu 22.04 / 24.04
- Nginx la public entrypoint duy nhat
- Node.js apps va 9router dung PM2
- PHP la backend phu qua PHP-FPM
- MySQL/MariaDB
- docs-first, verify-first, rollback-aware

Khong bao gom trong Phase 1:

- plugin system
- multi-OS
- cloud API automation
- heavy monitoring stack
- backup/restore full automation

---

## 1) Phase 1 architecture contract

Truoc khi code, tat ca implementers phai coi nhung diem sau la "fixed contract":

1. `install/ops-install.sh` phai nho, audit duoc, khong chua business logic lon.
2. `bin/ops` chi dong vai tro menu dispatcher.
3. `core/*.sh` chua helpers dung chung, khong chua module business logic.
4. Node services va 9router deu dung PM2.
5. Nginx la public entrypoint duy nhat.
6. State production phai huong toi `/etc/ops/*` lam source-of-truth.
7. Moi task config quan trong phai co:
   - backup
   - validate
   - reload/restart
   - verify
   - rollback minimum

### 1.1 Technology decisions (chốt, không thay đổi trong Phase 1)

| Component | Quyết định | Lý do |
|---|---|---|
| Node.js install | **nodesource apt** (`setup_lts.x`) | `/usr/bin/node` cố định, PM2 startup an toàn |
| PHP multi-version | **`ppa:ondrej/php`** | Duy nhất hỗ trợ 7.4/8.1/8.2/8.3 cùng lúc trên Ubuntu |
| Certbot | **snap primary**, apt fallback | EFF recommend; auto-renewal built-in |
| Login hook | **`~/.bash_profile`** của admin user | Chỉ áp dụng admin, dễ rollback, không ảnh hưởng scp/non-interactive |
| `/etc/ops/*.conf` format | **Bash key=value** shell-sourceable | Không cần parser ngoài, source trực tiếp trong script |
| 9router install | **git clone + npm build + PM2** | Chi tiết: `docs/NINE-ROUTER-SPEC.md` |
| Codex CLI install | **npm install -g @openai/codex** | Consistent với Node ecosystem đã có |

**Code skeleton reference**: `docs/CODE-SKELETON-GUIDE.md` — đọc trước khi viết bất kỳ module nào.

---

## 2) Phase 1 deliverables

Phase 1 duoc coi la xong khi repo co du cac nhom deliverables sau:

### A. Core repo scaffold

- `install/ops-install.sh`
- `bin/ops`
- `bin/ops-dashboard`
- `bin/ops-setup.sh`
- `core/env.sh`
- `core/ui.sh`
- `core/utils.sh`
- `core/system.sh`
- `modules/setup-wizard.sh`
- `modules/security.sh`
- `modules/nginx.sh`
- `modules/node.sh`
- `modules/nine-router.sh`
- `modules/php.sh`
- `modules/database.sh`
- `modules/monitoring.sh`
- `modules/codex-cli.sh`

### B. Template scaffold

- `templates/nginx/node_vhost.conf.tpl`
- `templates/nginx/php_vhost.conf.tpl`
- `templates/nginx/ssl_snippet.tpl`
- `templates/nginx/default-deny.conf.tpl`
- `templates/pm2/ecosystem.config.js.tpl`
- `templates/pm2/nine-router.ecosystem.config.js.tpl`

### C. Runtime-state contract

- `/etc/ops/ops.conf`
- `/etc/ops/capacity.conf` hoac JSON
- `/etc/ops/apps/<app>.conf`
- `/etc/ops/domains/<domain>.conf`
- `/etc/ops/php-sites/<site>.conf`
- `/etc/ops/codex-cli.conf`

### D. Menus co the dung duoc

- main menu
- setup wizard
- Node.js Services
- Domains & Nginx
- SSL Management
- 9router Management
- PHP / PHP-FPM Management
- Database Management
- Codex CLI Integration
- System & Monitoring

### E. Production verification line

1. cai core
2. login thay dashboard
3. chay wizard thanh cong
4. tao 1 Node app mau
5. tao 1 PHP site mau
6. deploy 9router
7. issue SSL
8. tat port 22 sau verify

---

## 3) Implementation order trong Phase 1

Lam theo thu tu nay, khong nen nhay co module:

1. `P1-00` repo scaffold va coding spine
2. `P1-01` core helpers
3. `P1-02` installer va setup bootstrap
4. `P1-03` dashboard va menu skeleton
5. `P1-04` security module
6. `P1-05` nginx module
7. `P1-06` node module
8. `P1-07` php module
9. `P1-08` database module
10. `P1-09` setup wizard orchestration
11. `P1-10` 9router module
12. `P1-11` monitoring module
13. `P1-12` codex-cli module
14. `P1-13` end-to-end verification and docs sync

Ly do:

- phai co core va runtime conventions truoc
- security + nginx la nen public edge
- node/php/db phai co truoc wizard
- 9router phai dung lai primitives cua node + nginx

---

## 4) Detailed tasks

### P1-00 Repo scaffold and coding spine

**Muc tieu**

- Tao du structure file/folder theo `ARCHITECTURE.md`
- Co entrypoints va module stubs co the source duoc

**Tasks**

1. Tao `bin/`, `install/`, `core/`, `modules/`, `templates/nginx/`, `templates/pm2/`.
2. Tao file shell co shebang, strict mode base, source path conventions.
3. Chot helper pattern:
   - `source` theo relative root
   - `OPS_ROOT`
   - `OPS_CONFIG_DIR`
   - `OPS_LOG_DIR`
4. Tao stub function cho moi module.

**Output**

- repo co the source/load ma khong fail vi thieu file

**Verify**

- `bash -n` cho tat ca shell files
- `bin/ops` chay va hien menu stub

**Review checklist**

- ten file dung docs
- khong co business logic lon o installer

---

### P1-01 Core helpers

**Muc tieu**

- Tao helper layer de cac module khong viet lai logic chung

**Tasks**

1. `core/env.sh`
   - detect Ubuntu version
   - detect RAM, CPU, disk
   - export runtime paths
2. `core/ui.sh`
   - print section
   - prompt text
   - confirm
   - choose menu item
3. `core/utils.sh`
   - backup file
   - safe write
   - log op
   - ensure dir
   - render template basic
4. `core/system.sh`
   - apt wrappers
   - systemctl wrappers
   - ufw wrappers
   - service status helpers

**Output**

- module nao cung co the goi helper chung

**Verify**

- source tung file thanh cong
- helper backup/write/log tao output dung path

**Review checklist**

- helper functions ten ro
- khong mixed UI vao env/system layers

---

### P1-02 Installer and setup bootstrap

**Muc tieu**

- Co installer co the dua 1 VPS moi vao trang thai OPS-core installed

**Tasks**

1. `install/ops-install.sh`
   - check Ubuntu 22.04/24.04
   - collect capacity
   - ask SSH port moi
   - ask admin user
   - create/install vao `/opt/ops`
   - call `bin/ops-setup.sh`
2. `bin/ops-setup.sh`
   - tao symlink `ops`, `ops-dashboard`
   - tao `/etc/ops/ops.conf`
   - tao `/etc/ops/capacity.conf`
   - wire login hook interactive shell

**Login hook implementation (chốt):**

```bash
# Append to ~/.bash_profile của ADMIN_USER — KHÔNG dùng /etc/profile.d/
# Guard: chỉ kích hoạt khi là interactive shell có SSH_TTY
if [[ $- == *i* ]] && [[ -n "${SSH_TTY:-}" ]]; then
    /usr/local/bin/ops-dashboard
    read -r -t 30 -p "Press 1 to open OPS menu, or Enter to continue: " _ops_ans 2>/dev/null || true
    [[ "${_ops_ans:-}" == "1" ]] && /usr/local/bin/ops
fi
```

**`/etc/ops/ops.conf` schema:**

```bash
OPS_VERSION="1.0.0"
OPS_ROOT="/opt/ops"
OPS_CONFIG_DIR="/etc/ops"
OPS_LOG_DIR="/var/log/ops"
OPS_ADMIN_USER=""
OPS_SSH_PORT=""
OPS_INSTALL_DATE=""
```

**`/etc/ops/capacity.conf` schema:**

```bash
OPS_RAM_MB=""
OPS_CPU_CORES=""
OPS_DISK_GB=""
OPS_TIER=""   # S | M | L
OPS_MAX_SITES=""
```

**Output**

- login lai bang admin user thay dashboard

**Verify**

- `/opt/ops` ton tai
- `/usr/local/bin/ops` ton tai
- `/etc/ops/*.conf` ton tai

**Review checklist**

- installer khong embed tuning/business logic module
- login hook co guard interactive shell

---

### P1-03 Dashboard and main menu skeleton

**Muc tieu**

- Co UX co ban cho operator vao OPS va dieu huong module

**Tasks**

1. `bin/ops-dashboard`
   - hostname, OS, uptime
   - RAM, CPU, disk, swap
   - service summary base
   - prompt `Press 1 to open OPS menu...`
2. `bin/ops`
   - main menu dung labels trong `MENU-REFERENCE.md`
   - call module actions/stubs

**Output**

- dashboard va menu co the dung duoc ngay ca khi module chua full

**Verify**

- login interactive hien dashboard
- bam `1` vao menu dung

**Review checklist**

- labels dung docs
- khong hard-code logic module vao menu

---

### P1-04 Security module

**Muc tieu**

- Xu ly SSH transition, UFW, fail2ban, admin safety

**Tasks**

1. install `ufw`, `fail2ban` neu thieu
2. open SSH current + new port during transition
3. open `80/443`
4. configure fail2ban cho SSH
5. helper finalise SSH:
   - close port 22
   - keep new port
   - reboot confirm

**Output**

- host co baseline security usable

**Verify**

- `ufw status`
- `fail2ban-client status`
- `sshd -t`
- SSH login bang port moi

**Review checklist**

- rollback-first cho SSH
- khong khoa operator ra khoi host

---

### P1-05 Nginx module

**Muc tieu**

- Cai Nginx, base tuning, default deny, domain config lifecycle

**Tasks**

1. install Nginx (from Ubuntu apt — version trong Ubuntu 22.04/24.04 repo là đủ)
2. apply global tuning tu `PERF-TUNING.md`
3. create default deny server (template: `templates/nginx/default-deny.conf.tpl`)
4. create helpers:
   - list domains
   - add domain
   - edit domain
   - remove domain
   - test + reload
5. support backend type:
   - Node reverse proxy (template: `templates/nginx/node_vhost.conf.tpl`)
   - PHP fastcgi (template: `templates/nginx/php_vhost.conf.tpl`)
   - static site
6. tao `/etc/ops/domains/<domain>.conf`

**Certbot install method (chốt):**

```bash
# Primary: snap
if command -v snap &>/dev/null; then
    snap install --classic certbot
    ln -sf /snap/bin/certbot /usr/local/bin/certbot
else
    # Fallback: apt
    apt_install certbot python3-certbot-nginx
fi
```

**`/etc/ops/domains/<domain>.conf` schema:**

```bash
DOMAIN=""
DOMAIN_BACKEND_TYPE=""   # node | php | static
DOMAIN_BACKEND_TARGET="" # e.g. 127.0.0.1:3000 or /run/php/php8.1-fpm-site.sock
DOMAIN_SSL="no"          # yes | no
DOMAIN_PHP_VERSION=""    # e.g. 8.1 (only if backend_type=php)
DOMAIN_APP_NAME=""       # linked app name if node
DOMAIN_CREATED=""
```

**Output**

- domain lifecycle hoat dong

**Verify**

- `nginx -t`
- `curl -I` host headers
- unknown host bi reject

**Review checklist**

- Nginx la public entrypoint duy nhat
- config generation co backup

---

### P1-06 Node module

**Muc tieu**

- Cai Node.js LTS, PM2, va quan ly Node services

**Node.js install method (chốt: nodesource apt):**

```bash
# Không dùng nvm, snap, hoặc OS repo — chỉ dùng nodesource
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
apt_install nodejs
# Verify: /usr/bin/node phải tồn tại
node -v
```

**Tasks**

1. install Node.js LTS (via nodesource apt — xem trên)
2. install PM2 global: `npm install -g pm2`
3. configure PM2 startup cho admin user: `pm2 startup systemd -u $ADMIN_USER --hp /home/$ADMIN_USER`
4. helpers:
   - list services
   - create service
   - start/stop/restart
   - view logs
5. tao `/etc/ops/apps/<app>.conf`
6. support ecosystem template render (template: `templates/pm2/ecosystem.config.js.tpl`)

**`/etc/ops/apps/<appname>.conf` schema:**

```bash
APP_NAME=""
APP_DIR=""
APP_PORT=""
APP_ENTRY=""        # e.g. dist/index.js
APP_PM2_NAME=""
APP_NODE_ENV="production"
APP_DOMAIN=""       # empty until linked via Domains menu
APP_CREATED=""
```

**Output**

- 1 Node app mau chay qua PM2

**Verify**

- `node -v`
- `pm2 status`
- app bind localhost
- Nginx proxy vao duoc neu linked

**Review checklist**

- PM2-only
- app khong bind public port

---

### P1-07 PHP module

**Muc tieu**

- Multi-PHP install, PHP-FPM pool config, default CLI switching

**PHP install method (chốt: ppa:ondrej/php):**

```bash
# Bắt buộc dùng PPA này — Ubuntu repo không có multi-version
add-apt-repository ppa:ondrej/php -y
apt_update

# Cài từng version được chọn (7.4, 8.1, 8.2, 8.3)
PHP_COMMON_EXTS="cli fpm common mysql curl gd intl mbstring opcache xml zip soap bcmath"
for ver in "$@"; do
    apt_install $(printf "php${ver}-%s " $PHP_COMMON_EXTS)
done
```

**PHP pool naming convention (chốt):**

Khi nhiều sites dùng cùng PHP version, tên pool và socket phải unique:

```
Pool name:    <site-name>
Pool file:    /etc/php/<ver>/fpm/pool.d/<site-name>.conf
Socket path:  /run/php/php<ver>-fpm-<site-name>.sock

Ví dụ:
  site: myshop   PHP: 8.1
  Pool file: /etc/php/8.1/fpm/pool.d/myshop.conf
  Socket:    /run/php/php8.1-fpm-myshop.sock

  site: blog     PHP: 8.1
  Pool file: /etc/php/8.1/fpm/pool.d/blog.conf
  Socket:    /run/php/php8.1-fpm-blog.sock
```

Nginx fastcgi target:
```nginx
fastcgi_pass unix:/run/php/php8.1-fpm-myshop.sock;
```

**Tasks**

1. add `ppa:ondrej/php` và apt update
2. install selected PHP versions: 7.4, 8.1, 8.2, 8.3 với common extensions
3. tune php.ini va opcache theo `PERF-TUNING.md`
4. pool helpers:
   - list installed versions
   - configure pools (dùng naming convention trên)
   - set CLI default (`update-alternatives --set php /usr/bin/phpX.Y`)
   - show FPM status
5. tao `/etc/ops/php-sites/<site>.conf`

**`/etc/ops/php-sites/<site>.conf` schema:**

```bash
SITE_NAME=""
SITE_DIR=""
SITE_PHP_VERSION=""  # e.g. 8.1
SITE_FPM_POOL=""     # pool name in /etc/php/X.Y/fpm/pool.d/
SITE_FPM_SOCKET=""   # e.g. /run/php/php8.1-fpm-mysite.sock
SITE_DOMAIN=""
SITE_CREATED=""
```

**Output**

- 1 PHP site co the phuc vu qua Nginx

**Verify**

- `php -v`
- `systemctl status php<ver>-fpm`
- PHP response test

**Review checklist**

- tach biet PHP CLI va PHP-FPM
- backup truoc khi sua pool/php.ini

---

### P1-08 Database module

**Muc tieu**

- Cai, secure, tune DB va tao DB/user

**Database default (chốt: MariaDB):**

```bash
# Default: MariaDB — không hỏi nếu operator không chọn gì
# Lý do: có sẵn trong Ubuntu repo, performance tốt hơn MySQL với workload nhỏ,
#         thiếu biết drop-in replacement cho MySQL.
apt_install mariadb-server mariadb-client

# Secure setup tương đương mysql_secure_installation:
mysql -e "DELETE FROM mysql.user WHERE User='';"          # remove anonymous
mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host != 'localhost';"  # remove remote root
mysql -e "DROP DATABASE IF EXISTS test;"                   # remove test db
mysql -e "FLUSH PRIVILEGES;"
```

**Tasks**

1. install **MariaDB** (default) — prompt operator nếu muốn MySQL thay thế
2. secure setup (tương đương `mysql_secure_installation`)
3. tune theo `PERF-TUNING.md`
4. create DB and user
5. list DBs/users
6. show DB status
7. optional `/etc/ops/database.conf`

**`/etc/ops/database.conf` schema:**

```bash
DB_ENGINE="mariadb"   # mariadb | mysql
DB_VERSION=""         # detected from dpkg
DB_ROOT_PASSWORD_FILE="/etc/ops/.db-root-password"  # (0600)
DB_INSTALL_DATE=""
```

> **Secret**: Root password lưu tại `/etc/ops/.db-root-password` (0600) — không lưu vào `database.conf`.

**Output**

- Node/PHP apps co the duoc cap DB an toan

**Verify**

- service active
- login DB
- app ket noi thanh cong

**Review checklist**

- least privilege users
- khong remote expose root mac dinh

---

### P1-09 Setup wizard orchestration

**Muc tieu**

- Gop cac module P1-04 -> P1-08 thanh first-time production flow

**Tasks**

1. `modules/setup-wizard.sh`
   - system update + base tools
   - security baseline
   - Nginx install + tuning
   - Node + PM2
   - PHP selected versions
   - DB optional
   - logging/basic monitoring
2. summary screen
3. re-runnable detection

**Output**

- fresh VPS co the chay wizard xong de vao lam viec tiep

**Verify**

- tung step report thanh cong
- rerun khong pha state cu

**Review checklist**

- wizard chi orchestrate, khong duplicate business logic

---

### P1-10 9router module

**Muc tieu**

- Deploy va quan ly 9router nhu 1 Node service dac biet

**Tasks**

1. clone/update 9router code
2. install dependencies/build
3. tao PM2 process config rieng
4. force bind `127.0.0.1:20128`
5. helpers:
   - install
   - link domain
   - start/stop/restart
   - logs

**Output**

- 9router chay local va vao duoc qua Nginx

**Verify**

- `pm2 status`
- direct public access vao `:20128` that bai
- route domain ok

**Review checklist**

- 9router khong co duong public bypass Nginx

---

### P1-11 Monitoring module

**Muc tieu**

- Co system overview, service status, quick logs dung cho ops hang ngay

**Tasks**

1. system overview
2. service status
3. quick logs for:
   - Nginx
   - PHP-FPM
   - PM2 Node services
   - DB
4. log path bootstrap `/var/log/ops/ops.log`

**Output**

- operator co the check stack nhanh ma khong grep tay

**Verify**

- menu show dung service state
- quick logs mo dung file/stream

**Review checklist**

- khong leak secrets qua logs

---

### P1-12 Codex CLI module

**Muc tieu**

- Cai va quan ly Codex CLI integration co ban

**Tasks**

1. install Codex CLI
2. configure env path/state
3. enable/disable auto env
4. test command
5. tao `/etc/ops/codex-cli.conf`

**Output**

- Codex CLI ready cho operator

**Verify**

- command test pass
- config state duoc luu

**Review checklist**

- khong log secrets/token

---

### P1-13 End-to-end verification and docs sync

**Muc tieu**

- Chot Phase 1 bang test line va docs cleanup

**Tasks**

1. fresh VPS smoke test
2. installer test
3. wizard test
4. Node sample deploy test
5. PHP sample deploy test
6. 9router test
7. SSL test
8. SSH finalisation test
9. cap nhat docs neu implementation lech spec

**Output**

- Phase 1 acceptance report

**Verify**

- tat ca test line pass

**Review checklist**

- docs khop code
- khong con TODO blocking trong Phase 1

---

## 5) Phase 1 test strategy

### Test levels

1. **Static checks**
   - `bash -n`
   - shellcheck neu co
2. **Module smoke checks**
   - source module
   - call dry-run helpers
3. **Runtime integration**
   - tren VPS test that
4. **E2E phase acceptance**
   - full install -> wizard -> create Node/PHP -> SSL -> SSH finalise

### Minimum pass gate cho moi task

Moi task chi duoc xem la xong khi co:

- code xong
- docs khop
- verify pass
- rollback minimum duoc mo ta ro

---

## 6) Cach review Phase 1

Khi review phase, dung form nay:

1. Scope task co bi lan sang phase khac khong?
2. Co dung docs contract khong?
3. Runtime source-of-truth du kien da ro chua?
4. Verify step co thuc su do duoc thanh cong khong?
5. Rollback minimum co kha thi tren VPS production khong?
6. Co bug/rui ro nao lan sang task lien quan khong?

---

## 7) Suggested working mode

De tranh lan man, nen lam theo sprint task-level:

1. chot 1 task `P1-xx`
2. code task do
3. test pass task do
4. review task do
5. moi sang task tiep theo

Khong nen mo dong 4-5 module cung luc trong Phase 1.
