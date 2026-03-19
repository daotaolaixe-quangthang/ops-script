## 9Router VPS — Implementation Spec

> Source repo: **https://github.com/daotaolaixe-quangthang/9routervps** (chốt — không dùng URL nào khác)
> Tech Stack: Node.js 20+, Next.js 16, React 19, LowDB (JSON file-based), SSE streaming
> Port: `20128` (fixed, do not change)
> Binding: `HOSTNAME=0.0.0.0` (Next.js requirement) — security enforced tại **UFW + Nginx layer**

---

### 1. What is 9router?

9Router is an **OpenAI-compatible API proxy router** that:

- Acts as a unified endpoint for AI coding tools (Claude Code, Codex CLI, Gemini CLI, Cursor, Cline, OpenClaw...)
- Routes requests through a 3-tier fallback: Subscription → Cheap → Free
- Handles OAuth token refresh, quota tracking, format translation (OpenAI ↔ Claude)
- Exposes a web dashboard at `http://localhost:20128/dashboard`
- Exposes an OpenAI-compatible API at `http://localhost:20128/v1`

**Architecture on OPS-managed VPS:**

```
[AI CLI Tools] ──> Nginx (public, 443) ──> [9Router on 127.0.0.1:20128]
                                                    │
                                          ├─> Subscription providers
                                          ├─> Cheap providers
                                          └─> Free providers
```

---

### 2. Install Flow (inside `modules/nine-router.sh`)

#### 2.1 Prerequisites

- Node.js 20+ (installed via `nodesource` apt — see PHASE-01-SPEC P1-06)
- PM2 installed globally
- Git

#### 2.2 Clone and install

```bash
NINE_ROUTER_DIR="/opt/9router"
NINE_ROUTER_DATA_DIR="/var/lib/9router"

# Clone — chốt URL này, không dùng decolua/9router hay URL nào khác
git clone https://github.com/daotaolaixe-quangthang/9routervps.git "$NINE_ROUTER_DIR"
cd "$NINE_ROUTER_DIR"

# Install dependencies
npm install

# Build production bundle (bắt buộc — Next.js cần build trước khi start)
npm run build
```

#### 2.3 Environment configuration

**Bước 1 — OPS hỏi operator nhập INITIAL_PASSWORD:**

```bash
# Trong module nine-router.sh khi install:
prompt_secret "Enter 9router dashboard initial password"
NINE_ROUTER_INIT_PASSWORD="$SECRET"

# Lưu vào file restricted (KHÔNG lưu vào /etc/ops/nine-router.conf)
echo "$NINE_ROUTER_INIT_PASSWORD" > /etc/ops/.nine-router-password
chmod 600 /etc/ops/.nine-router-password
chown "$ADMIN_USER":"$ADMIN_USER" /etc/ops/.nine-router-password

log_info "9router initial password saved to /etc/ops/.nine-router-password (0600)"
print_warn "This password unlocks the 9router dashboard. Keep it safe."
```

**Bước 2 — Tạo `/opt/9router/.env` (0600):**

```bash
JWT_SECRET=$(openssl rand -hex 32)
API_KEY_SECRET=$(openssl rand -hex 32)
MACHINE_ID_SALT=$(openssl rand -hex 16)

write_file /opt/9router/.env <<EOF
PORT=20128
HOSTNAME=0.0.0.0
NODE_ENV=production
DATA_DIR=/var/lib/9router
JWT_SECRET=${JWT_SECRET}
INITIAL_PASSWORD=${NINE_ROUTER_INIT_PASSWORD}
NEXT_PUBLIC_BASE_URL=http://localhost:20128
NEXT_PUBLIC_CLOUD_URL=https://9router.com
API_KEY_SECRET=${API_KEY_SECRET}
MACHINE_ID_SALT=${MACHINE_ID_SALT}
ENABLE_REQUEST_LOGS=false
AUTH_COOKIE_SECURE=false
REQUIRE_API_KEY=false
EOF
chmod 600 /opt/9router/.env
chown "$ADMIN_USER":"$ADMIN_USER" /opt/9router/.env
```

> **Security**: `HOSTNAME=0.0.0.0` là yêu cầu của Next.js để bind HTTP server.
> Public exposure bị chặn tại **UFW layer** (port 20128 không được mở) và **Nginx layer**.
> Nginx chỉ proxy đến `127.0.0.1:20128`.

**Bước 3 — Tạo state dirs:**

```bash
mkdir -p "$NINE_ROUTER_DATA_DIR"
chown "$ADMIN_USER":"$ADMIN_USER" "$NINE_ROUTER_DATA_DIR"
chmod 750 "$NINE_ROUTER_DATA_DIR"
```

#### 2.3.1 AUTH_COOKIE_SECURE — update sau khi issue SSL

Sau khi SSL được issue cho 9router domain (từ SSL Management menu), OPS **phải tự động** cập nhật:

```bash
# Gọi sau khi certbot issue SSL cho domain 9router:
nine_router_enable_cookie_secure() {
    sed -i 's/AUTH_COOKIE_SECURE=false/AUTH_COOKIE_SECURE=true/' /opt/9router/.env
    pm2 restart nine-router
    log_info "9router AUTH_COOKIE_SECURE=true (SSL active)"
}
```

Lưu trạng thái vào OPS state:
```bash
ops_conf_set nine-router.conf NINE_ROUTER_SSL "yes"
```

#### 2.4 PM2 process registration

OPS manages 9router via **PM2 only** (same contract as all Node services).

Use the template at `templates/pm2/nine-router.ecosystem.config.js.tpl`:

```javascript
// /opt/9router/nine-router.ecosystem.config.js
// Managed by OPS — do not edit manually
module.exports = {
  apps: [{
    name:       'nine-router',
    script:     'node_modules/.bin/next',
    args:       'start',
    cwd:        '/opt/9router',
    instances:  1,
    exec_mode:  'fork',
    env: {
      PORT:                    '20128',
      HOSTNAME:                '0.0.0.0',
      NODE_ENV:                'production',
      DATA_DIR:                '/var/lib/9router',
      // Secrets loaded from .env file — do NOT inline here
    },
    env_file:        '/opt/9router/.env',
    error_file:      '/var/log/ops/nine-router.err.log',
    out_file:        '/var/log/ops/nine-router.out.log',
    log_date_format: 'YYYY-MM-DD HH:mm:ss',
    restart_delay:   3000,
    max_restarts:    10,
    watch:           false
  }]
};
```

Register with PM2:

```bash
cd /opt/9router
pm2 start nine-router.ecosystem.config.js
pm2 save
```

#### 2.5 Nginx vhost (via Domains & Nginx menu)

When user selects "Link 9router to a domain", OPS creates an Nginx vhost:

```nginx
# /etc/nginx/sites-available/nine-router.<domain>
# Rate limiting zone (define in nginx.conf http block if not already present)
# limit_req_zone $binary_remote_addr zone=nine_router:10m rate=30r/m;

server {
    listen 80;
    server_name {{DOMAIN}};

    access_log /var/log/nginx/nine-router.access.log;
    error_log  /var/log/nginx/nine-router.error.log;

    # Rate limiting: max 30 req/min per IP (burst 10)
    limit_req zone=nine_router burst=10 nodelay;
    limit_req_status 429;

    # Dashboard and API — proxy to 9router
    location / {
        proxy_pass         http://127.0.0.1:20128;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade         $http_upgrade;
        proxy_set_header   Connection      'upgrade';
        proxy_set_header   Host            $host;
        proxy_set_header   X-Real-IP       $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
        proxy_read_timeout    120s;   # SSE streaming needs longer timeout
        proxy_connect_timeout  10s;
        proxy_send_timeout     60s;
        proxy_buffering        off;   # Required for SSE streaming
    }
}
```

Nginx `http` block trong `nginx.conf` phai co:
```nginx
limit_req_zone $binary_remote_addr zone=nine_router:10m rate=30r/m;
```
OPS se tu dong them vao neu chua ton tai khi "Link 9router to a domain".

> **Important**: `proxy_buffering off` is required for SSE streaming (AI responses streamed in real-time).


#### 2.6 Update flow

```bash
cd /opt/9router
pm2 stop nine-router
git pull origin main
npm install
npm run build
pm2 start nine-router
pm2 save
```

---

### 3. Runtime State

| Artefact | Path | Purpose |
|---|---|---|
| Source code | `/opt/9router` | App code + build output |
| Env config | `/opt/9router/.env` | Secrets and runtime config (0600) |
| DB state | `/var/lib/9router/db.json` | Providers, combos, aliases, API keys |
| Usage history | `~/.9router/usage.json` | Per-admin usage stats *(app-managed, not created by OPS)* |
| Usage log | `~/.9router/log.txt` | Usage log *(app-managed, not created by OPS)* |
| PM2 process | `nine-router` | Managed by PM2 |
| OPS state file | `/etc/ops/nine-router.conf` | OPS-level metadata |
| Nginx vhost | `/etc/nginx/sites-available/nine-router.*` | Public routing |
| App log | `/var/log/ops/nine-router.{out,err}.log` | PM2 logs |

#### OPS state file format:

```bash
# /etc/ops/nine-router.conf (0640)
NINE_ROUTER_INSTALLED="yes"
NINE_ROUTER_DIR="/opt/9router"
NINE_ROUTER_DATA_DIR="/var/lib/9router"
NINE_ROUTER_PORT="20128"
NINE_ROUTER_PM2_NAME="nine-router"
NINE_ROUTER_RUNTIME_USER=""         # Linux user that owns PM2 and runs the process
NINE_ROUTER_DOMAIN=""              # empty until linked via Domains menu
NINE_ROUTER_SSL="no"               # updated to "yes" after certbot issues SSL
NINE_ROUTER_REQUIRE_API_KEY="no"   # updated via Enable/Disable menu action
NINE_ROUTER_INSTALL_DATE=""
```

> **Secret**: INITIAL_PASSWORD KHÔNG được lưu ở đây.
> Chỉ lưu tại `/etc/ops/.nine-router-password` (0600, owned by admin user).


---

### 4. Verify

```bash
# 1. PM2 process running
pm2 status nine-router

# 2. Process is NOT directly reachable from public internet
# (curl from external should fail; curl from localhost should work)
curl -s http://127.0.0.1:20128/v1/models | head -5

# 3. Port 20128 NOT open in UFW
ufw status | grep 20128   # should return nothing

# 4. Dashboard accessible via domain (after Nginx linked)
curl -I https://<domain>/dashboard

# 5. Process logs look clean (no crash loop)
pm2 logs nine-router --lines 20
```

---

### 5. Rollback

If 9router fails to start or causes issues:

```bash
pm2 stop nine-router
pm2 delete nine-router

# Remove Nginx vhost if linked
rm /etc/nginx/sites-enabled/nine-router.<domain>
nginx -t && systemctl reload nginx

# Restore previous state if update went wrong
cd /opt/9router
git log --oneline -5
git checkout <previous-commit>
npm install
npm run build
pm2 start nine-router.ecosystem.config.js
pm2 save
```

---

### 6. Security contract

- Port `20128` MUST NOT be open in UFW
- Nginx MUST validate `Host` header before proxying (default-deny server handles unknown hosts)
- `.env` MUST have permission `0600`
- `/var/lib/9router/db.json` contains API keys — owned by admin user only
- `AUTH_COOKIE_SECURE=true` MUST be set if dashboard is accessed over HTTPS (after SSL issued)

---

### 7. Note on `HOSTNAME=0.0.0.0`

Next.js requires `HOSTNAME=0.0.0.0` to bind its HTTP server to accept connections.
On the OS level, this means port 20128 is bound on all interfaces.
**Security is enforced at the UFW layer** (port 20128 must not be allowed in UFW rules)
and at the **Nginx layer** (only Nginx proxies to it; direct public access is blocked by UFW).

OPS must verify UFW does not have port 20128 open after any install/update.
