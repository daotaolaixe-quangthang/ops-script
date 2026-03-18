# OPS — VPS Production Setup & Manager

> **One-line install · Bash TUI · Ubuntu 22.04 / 24.04**

---

## Mục lục

1. [Yêu cầu hệ thống](#1-yêu-cầu-hệ-thống)
2. [Cài đặt lần đầu](#2-cài-đặt-lần-đầu)
3. [Sau khi cài — bước tiếp theo](#3-sau-khi-cài--bước-tiếp-theo)
4. [Menu chính](#4-menu-chính)
5. [Production Setup Wizard](#5-production-setup-wizard)
6. [Node.js Services](#6-nodejs-services)
7. [Domains & Nginx](#7-domains--nginx)
8. [SSL Management](#8-ssl-management)
9. [9router Management](#9-9router-management)
10. [PHP / PHP-FPM Management](#10-php--php-fpm-management)
11. [Database Management](#11-database-management)
12. [Codex CLI Integration](#12-codex-cli-integration)
13. [System & Monitoring](#13-system--monitoring)
14. [Cài lại / Cập nhật OPS](#14-cài-lại--cập-nhật-ops)
15. [Troubleshooting](#15-troubleshooting)

---

## 1. Yêu cầu hệ thống

| Yêu cầu | Chi tiết |
|---|---|
| OS | Ubuntu **22.04** hoặc **24.04** (LTS) |
| Quyền | Root hoặc sudo |
| RAM tối thiểu | 512 MB (1 GB+ được khuyến nghị) |
| Disk | 5 GB+ trống |
| Kết nối | Internet (tải tarball từ GitHub) |
| Công cụ cần có | `curl`, `tar` — sẽ tự cài nếu thiếu |

> **Không cần git.** Installer tải tarball trực tiếp từ GitHub.

---

## 2. Cài đặt lần đầu

### Lệnh duy nhất (chạy với quyền root)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/daotaolaixe-quangthang/ops-script/main/install/ops-install.sh)
```

> ⚠️ Dùng `bash <(...)` thay vì `curl ... | bash` để stdin vẫn là TTY, các prompt nhập liệu mới hoạt động đúng.

### Installer sẽ hỏi bạn

| Bước | Nội dung | Lưu ý |
|---|---|---|
| 1 | Xác nhận cài đặt `[y/N]` | Nhập `y` để tiếp tục |
| 2 | SSH port mới (> 1024) | Mặc định: `2222`. Port 22 vẫn mở trong transition |
| 3 | Tên admin user | Mặc định: `opsadmin` |
| 4 | Password cho admin user | Nhập 2 lần |

### Installer làm gì

1. OS check (Ubuntu 22.04 / 24.04)
2. Cài dependencies thiếu (`curl tar awk` v.v.)
3. Phát hiện VPS resources → xác định Tier (S/M/L)
4. Cấu hình SSH port (transition: giữ port 22 + mở port mới)
5. Cấu hình UFW (deny incoming, allow SSH + 80 + 443)
6. Tạo admin user + sudo
7. Tải tarball OPS từ GitHub → giải nén → copy vào `/opt/ops/`
8. Tạo symlink `ops` và `ops-dashboard` vào `/usr/local/bin/`
9. Cài login hook vào `~/.bash_profile` (hiển thị dashboard khi SSH)
10. Ghi cấu hình ban đầu vào `/etc/ops/`

### Sau khi cài xong — QUAN TRỌNG

```
╔══════════════════════════════════════════════════════╗
║               OPS Installation Complete              ║
╚══════════════════════════════════════════════════════╝

  Admin user : opsadmin
  SSH port   : 2222
  SSH command: ssh -p 2222 opsadmin@<IP>
```

**Bắt buộc:** Mở terminal MỚI và test login trước khi đóng terminal hiện tại:

```bash
ssh -p 2222 opsadmin@<YOUR_SERVER_IP>
```

Sau khi verify login thành công, đóng port 22:

```
ops → 9) System & Monitoring → [sẽ có trong Security module]
```

---

## 3. Sau khi cài — bước tiếp theo

```bash
# Login bằng terminal mới
ssh -p 2222 opsadmin@<IP>

# OPS dashboard tự động hiện khi SSH login
# Hoặc chạy thủ công:
ops
```

**Thứ tự khuyến nghị:**

```
1. ops → 1) Production Setup Wizard    ← hoàn thiện stack toàn bộ
2. ops → 3) Domains & Nginx            ← thêm website
3. ops → 4) SSL Management             ← cấp SSL
4. ops → 9) System & Monitoring → 12) Verify stack health
```

---

## 4. Menu chính

```
╔══════════════════════╗
║  OPS — Main Menu     ║
╚══════════════════════╝
  1) Production Setup Wizard
  2) Node.js Services
  3) Domains & Nginx
  4) SSL Management
  5) 9router Management
  6) PHP / PHP-FPM Management
  7) Database Management
  8) Codex CLI Integration
  9) System & Monitoring
  0) Exit
```

---

## 5. Production Setup Wizard

**`ops → 1`**

Wizard hướng dẫn cài đặt toàn bộ stack lần đầu theo thứ tự:

1. Security & Firewall (UFW, Fail2ban)
2. Nginx install & tuning (theo Tier S/M/L)
3. Node.js + PM2
4. PHP-FPM (multi-version)
5. Database (MariaDB mặc định)
6. Logging & monitoring cơ bản

> Dùng wizard này cho lần cài đặt đầu tiên. Sau đó dùng từng menu riêng để quản lý.

---

## 6. Node.js Services

**`ops → 2`**

| Menu | Chức năng |
|---|---|
| 1) List services | Hiện tất cả PM2 processes và trạng thái |
| 2) Create new service | Tạo Node.js app mới, đăng ký PM2 |
| 3) Start/Stop/Restart | Quản lý lifecycle app cụ thể |
| 4) View logs | Xem PM2 logs của app |

**Lưu ý:**
- Tất cả Node.js apps dùng **PM2** (không dùng systemd trực tiếp)
- Web root quy ước: `/var/www/<appname>` (operator deploy, OPS không tạo/xoá)
- App bind vào `localhost:<port>`, Nginx là public entrypoint duy nhất

---

## 7. Domains & Nginx

**`ops → 3`**

| Menu | Chức năng |
|---|---|
| 1) List domains | Hiện tất cả domains đang quản lý |
| 2) Add new domain | Thêm domain + vhost Nginx |
| 3) Edit domain | Sửa backend type hoặc HTTPS redirect |
| 4) Remove domain | Xoá vhost (không xoá web root) |
| 5) Test & reload | `nginx -t && nginx reload` |

### Add new domain — flow

1. Nhập domain (vd: `example.com`)
2. Chọn backend:
   - **Node.js** — reverse proxy đến PM2 service hoặc port thủ công
   - **PHP site** — qua PHP-FPM socket (chọn version)
   - **Static site** — serve files từ web root
3. OPS render Nginx vhost từ template → enable → reload
4. State file lưu tại `/etc/ops/domains/<domain>.conf`

> **SSL không được cấp ở đây** — issue SSL riêng qua menu SSL Management.

### Web root convention

| Backend | Web root |
|---|---|
| Node.js | `/var/www/<appname>` (operator deploy) |
| PHP site | `/var/www/<domain>` (OPS tạo sẵn) |
| Static | `/var/www/<domain>` (OPS tạo sẵn) |

### Remove domain

OPS xoá Nginx config và state file. **Web root `/var/www/<domain>` KHÔNG bị xoá** — xoá thủ công nếu cần.

---

## 8. SSL Management

**`ops → 4`**

| Menu | Chức năng |
|---|---|
| 1) Issue certificate | Cấp SSL cho domain qua Certbot |
| 2) Renew all | Renew tất cả certs (`certbot renew`) |
| 3) Show status | Xem domains, expiry date, trạng thái |

**Công cụ:** Certbot (snap). SSL được tích hợp tự động vào Nginx vhost.

**Auto-action:** Sau khi cấp SSL cho domain 9router → tự set `AUTH_COOKIE_SECURE=true` trong `/opt/9router/.env` và restart.

---

## 9. 9router Management

**`ops → 5`**

9router là reverse proxy + auth layer viết bằng Node.js, bind tại `127.0.0.1:20128`.

| Menu | Chức năng |
|---|---|
| 1) Install 9router | Clone, build, đăng ký PM2 |
| 2) Update 9router | `git pull` + `npm build` + PM2 restart |
| 3) Link to domain | Tạo Nginx vhost với `proxy_buffering off` (bắt buộc cho SSE) |
| 4/5/6) Start/Stop/Restart | PM2 lifecycle |
| 7) View logs | PM2 logs |
| 8) Enable API key | `REQUIRE_API_KEY=true` → restart |
| 9) Disable API key | `REQUIRE_API_KEY=false` → restart |

**Secrets được tạo tự động khi install:**
- `INITIAL_PASSWORD` → `/etc/ops/.nine-router-password` (0600)
- `JWT_SECRET`, `API_KEY_SECRET`, `MACHINE_ID_SALT` → `openssl rand`

---

## 10. PHP / PHP-FPM Management

**`ops → 6`**

| Menu | Chức năng |
|---|---|
| 1) List PHP versions | Hiện versions đã cài |
| 2) Install/Remove | Cài thêm hoặc gỡ version |
| 3) Configure pools | Tạo/sửa PHP-FPM pool |
| 4) Set default CLI | `update-alternatives` |
| 5) Show status | PM2/FPM status chi tiết |

**Versions hỗ trợ:** 7.4, 8.1, 8.2, 8.3 (via `ppa:ondrej/php`)

**Pool convention:**
- Config: `/etc/php/<ver>/fpm/pool.d/<site>.conf`
- Socket: `/run/php/php<ver>-fpm-<site>.sock`

---

## 11. Database Management

**`ops → 7`**

| Menu | Chức năng |
|---|---|
| 1) Install/reinstall | Cài MariaDB (mặc định) hoặc MySQL |
| 2) Secure & tune | Tương đương `mysql_secure_installation` + tuning theo Tier |
| 3) Create DB & user | Tạo database và user riêng |
| 4) List databases | Liệt kê DBs và users |
| 5) Show status | Service status + connection test |

**Quy tắc bất biến:**
- `bind-address = 127.0.0.1` luôn được đặt (MariaDB không expose ra ngoài VPS)
- DB root password lưu tại `/etc/ops/.db-root-password` (0600) — không in ra terminal

---

## 12. Codex CLI Integration

**`ops → 8`**

| Menu | Chức năng |
|---|---|
| 1) Install Codex CLI | npm global install |
| 2) Configure | API key + server settings |
| 3) Enable/disable auto env | Tự load env khi SSH |
| 4) Test | Gửi test query |

- Config: `/etc/ops/codex-cli.conf`
- API key: `/etc/ops/.codex-api-key` (0600)

---

## 13. System & Monitoring

**`ops → 9`**

| Menu | Chức năng |
|---|---|
| 1) System overview | CPU, RAM, Swap, Disk, Load, Uptime |
| 2) Service status | Nginx, PHP-FPM, MariaDB, PM2, UFW, Fail2ban |
| 3) Quick logs — Nginx | Tail access + error log |
| 4) Quick logs — PHP-FPM | Tail PHP-FPM logs |
| 5) Quick logs — PM2/Node | `pm2 logs --nostream` |
| 6) Quick logs — Database | MariaDB error log / journalctl |
| 7) OPS log | `/var/log/ops/ops.log` |
| 8) Login history | `last`, `lastb`, SSH journalctl |
| 9) Disk usage | `df -h` + top dirs in `/var/www` |
| 10) Setup Telegram | Cấu hình bot token + chat ID |
| 11) Test Telegram | Gửi test message |
| 12) Verify stack health | PASS/WARN/FAIL từng component |
| 13) Advanced monitoring | Netdata opt-in (submenu) |
| 14) Notifications & checks | Scheduled uptime/SSL/domain alerts (submenu) |
| 15) Backup helpers | DB backup + config archive (submenu) |
| 16) Update OPS from git | Tải tarball mới → syntax check → apply |

### Verify stack health (12)

Kiểm tra toàn bộ stack, output ví dụ:

```
[PASS] SSH            port 2222 active
[PASS] Nginx          active, nginx -t ok
[PASS] PM2            3 process(es) online
[WARN] PHP-FPM 8.1    inactive — not installed?
[PASS] MariaDB        active
[PASS] UFW            active
[PASS] SSL            example.com — 45 days left
[FAIL] 9router        process not found in PM2
```

> Luôn return exit 0 — không làm menu thoát.

### Telegram notifications (10 + 11)

```
ops → 9 → 10) Setup Telegram notifications
  Nhập Bot Token (hidden)
  Nhập Chat ID

ops → 9 → 11) Test Telegram notification
  → Gửi test message để verify
```

- Token lưu tại: `/etc/ops/.telegram-bot-token` (0600)
- Chat ID lưu tại: `/etc/ops/notifications.conf`
- Tự động gửi alert khi: CPU/RAM/Disk cao, site down, SSL gần hết hạn, domain gần hết hạn

### Scheduled checks (14)

```
ops → 9 → 14) Notifications & scheduled checks
  1) Install scheduled checks (cron)
  2) Remove scheduled checks
  3-7) Run checks manually
  8) Show check log
```

Cron schedule mặc định:
- Resource check: mỗi 5 phút
- Uptime check: mỗi 5 phút
- SSL expiry: hàng ngày 06:00
- Domain expiry: hàng ngày 07:00
- Security scan: Chủ nhật 03:00

### Backup helpers (15)

```
ops → 9 → 15) Backup helpers
  1) Backup database
  2) Archive configs
  3) List backups
```

Backup locations:
- DB: `/var/backups/ops/db/`
- Config: `/var/backups/ops/config/`

### Update OPS (16)

```
ops → 9 → 16) Update OPS from git
```

Tải tarball mới từ GitHub → verify → diff preview → apply → syntax check tất cả `.sh` files → báo cáo kết quả.

> Sau khi update: thoát và chạy lại `ops` để load version mới.

---

## 14. Cài lại / Cập nhật OPS

### Chạy lại installer (idempotent)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/daotaolaixe-quangthang/ops-script/main/install/ops-install.sh)
```

**An toàn khi chạy lại:**

| Thành phần | Hành động khi chạy lại |
|---|---|
| SSH port đã thay đổi | Chỉ thông báo, không thay đổi |
| Port 22 đã đóng | Giữ nguyên, không mở lại |
| Admin user đã tồn tại | Skip hoàn toàn kể cả password |
| Nginx configs, PHP pools, DBs | **Không đụng đến** |
| Web root `/var/www/` | **Không đụng đến** |
| OPS scripts `/opt/ops/` | Cập nhật từ tarball mới nhất |

### Update chỉ OPS scripts (không cần installer)

```
ops → 9) System & Monitoring → 16) Update OPS from git
```

---

## 15. Troubleshooting

### Menu thoát bất ngờ

Không xảy ra với phiên bản hiện tại. Nếu gặp, kiểm tra:

```bash
bash -n /opt/ops/bin/ops
bash -n /opt/ops/modules/verify.sh
```

### OPS không tìm thấy sau install

```bash
which ops          # → /usr/local/bin/ops
ls -la /usr/local/bin/ops   # → symlink đến /opt/ops/bin/ops
```

Nếu symlink bị mất:

```bash
ln -sf /opt/ops/bin/ops /usr/local/bin/ops
```

### Nginx không reload

```bash
nginx -t           # kiểm tra syntax
systemctl status nginx
journalctl -u nginx -n 20
```

### Telegram không gửi được

```bash
# Kiểm tra token file
ls -la /etc/ops/.telegram-bot-token

# Test thủ công
ops → 9 → 11) Test Telegram notification
```

### Logs

| File | Nội dung |
|---|---|
| `/var/log/ops/ops.log` | OPS actions log |
| `/var/log/ops/checks.log` | Scheduled checks output |
| `/var/log/nginx/error.log` | Nginx errors |
| `/var/log/mysql/error.log` | MariaDB errors |

---

## File & Thư mục quan trọng

| Path | Mục đích |
|---|---|
| `/opt/ops/` | OPS scripts (bin, core, modules) |
| `/etc/ops/` | Tất cả config files |
| `/etc/ops/ops.conf` | Config chính |
| `/etc/ops/notifications.conf` | Telegram Chat ID, TELEGRAM_ENABLED |
| `/etc/ops/.telegram-bot-token` | Telegram token (0600) |
| `/etc/ops/.db-root-password` | MariaDB root password (0600) |
| `/etc/ops/domains/` | Domain state files |
| `/var/log/ops/` | OPS logs |
| `/var/backups/ops/` | Backups |
| `/usr/local/bin/ops` | Symlink → `/opt/ops/bin/ops` |

---

*Repo: [github.com/daotaolaixe-quangthang/ops-script](https://github.com/daotaolaixe-quangthang/ops-script)*
