## Performance Tuning Rules

This document defines how OPS should tune Nginx, PHP‑FPM, MySQL/MariaDB, and Node.js based on VPS resources. AI agents should update this file first when changing tuning logic.

Values below are guidelines; actual implementation can interpolate between tiers as needed.

### 1. Resource tiers

Define rough tiers based on RAM and CPU cores:

- **Tier S (small)**: 1 GB RAM, 1 vCPU
- **Tier M (medium)**: 2–4 GB RAM, 2 vCPU
- **Tier L (large)**: 8+ GB RAM, 4+ vCPU

OPS should detect actual RAM/CPU and map to the closest tier.

---

### 2. Nginx tuning

For all tiers:

- `worker_processes`: set to number of CPU cores (or `auto`).
- `worker_connections`: at least 2048.
- Enable gzip for text assets; avoid compressing already‑compressed formats.

Suggested defaults:

- **Tier S**
  - `worker_processes 1;`
  - `worker_connections 2048;`
  - `keepalive_timeout 65;`
- **Tier M**
  - `worker_processes 2;`
  - `worker_connections 4096;`
  - `keepalive_timeout 65;`
- **Tier L**
  - `worker_processes 4;`
  - `worker_connections 8192;`
  - `keepalive_timeout 65;`

OPS must always validate Nginx config with `nginx -t` before reload.

---

### 3. PHP‑FPM tuning (per version)

Each PHP version (7.4, 8.1, 8.2, 8.3) should have pools tuned by tier.

Common defaults:

- `pm = ondemand` for Tier S.
- `pm = dynamic` for Tier M and L.
- `pm.max_children` derives from available RAM.

Approximate guidelines (per pool):

- **Tier S**
  - `pm = ondemand`
  - `pm.max_children = 5`
  - `pm.process_idle_timeout = 10s`
  - `pm.max_requests = 500`
- **Tier M**
  - `pm = dynamic`
  - `pm.max_children = 20`
  - `pm.start_servers = 4`
  - `pm.min_spare_servers = 2`
  - `pm.max_spare_servers = 8`
  - `pm.max_requests = 1000`
- **Tier L**
  - `pm = dynamic`
  - `pm.max_children = 50`
  - `pm.start_servers = 10`
  - `pm.min_spare_servers = 5`
  - `pm.max_spare_servers = 20`
  - `pm.max_requests = 2000`

`php.ini` / opcache suggested defaults:

- Enable opcache.
- Set `memory_limit` based on tier:
  - Tier S: `128M`
  - Tier M: `256M`
  - Tier L: `512M` or higher as needed.

---

### 4. MySQL/MariaDB tuning

Key parameters to adjust per tier:

- `innodb_buffer_pool_size`
- `max_connections`
- `thread_cache_size`
- `tmp_table_size` and `max_heap_table_size`

Suggested starting points:

- **Tier S (1 GB RAM)**
  - `innodb_buffer_pool_size = 256M`
  - `max_connections = 80`
  - `tmp_table_size = 32M`
  - `max_heap_table_size = 32M`
- **Tier M (2–4 GB RAM)**
  - `innodb_buffer_pool_size = 512M`–`1G`
  - `max_connections = 150`
  - `tmp_table_size = 64M`
  - `max_heap_table_size = 64M`
- **Tier L (8+ GB RAM)**
  - `innodb_buffer_pool_size = 2G` or more depending on DB usage.
  - `max_connections = 300` or higher if needed.
  - `tmp_table_size = 128M`
  - `max_heap_table_size = 128M`

OPS should not oversubscribe memory; values must be conservative by default.

---

### 5. Node.js and PM2

For Node.js services (including 9router):

- **Process count**:
  - Start with a single process per app unless:
    - CPU cores > 2
    - and the app is clearly CPU‑bound.
  - For CPU‑bound apps on Tier M/L, consider up to `min(cores, 4)` processes.
- **Environment**:
  - Set `NODE_ENV=production` by default.
  - Avoid enabling verbose logging unless explicitly requested.

OPS should provide sensible defaults but leave app‑specific tuning (e.g. cluster mode) to the application owner where appropriate.

---

### 6. Capacity estimates

OPS stores a capacity estimate (based on tier) to help set expectations:

- **Tier S**
  - 1–3 low‑traffic sites.
  - Roughly tens of concurrent users per site under typical conditions.
- **Tier M**
  - 3–8 low‑to‑medium‑traffic sites.
  - Hundreds of concurrent users total with proper caching.
- **Tier L**
  - 8+ sites.
  - Higher concurrency depending on application behaviour and caching.

These are indicative only and must be presented as **guidance, not guarantees**.

---

### 7. Updating this document

When changing any tuning logic in code:

1. Update this document first with the new strategy and rationale.
2. Ensure module implementations reference these rules rather than hard‑coding unrelated values.

