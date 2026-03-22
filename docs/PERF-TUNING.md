## Performance Tuning Rules

This document defines how OPS should tune Nginx, PHP-FPM, MySQL/MariaDB, and Node.js based on VPS resources. AI agents should update this file first when changing tuning logic.

Values below are guidelines; actual implementation can interpolate between tiers as needed.

### 1. Resource tiers

Define rough tiers based on RAM and CPU cores:

- **Tier S (small)**: < 1500 MB RAM, 1 vCPU
- **Tier M (medium)**: 1500–5000 MB RAM, 2 vCPU
- **Tier L (large)**: > 5000 MB RAM, 4+ vCPU

**RAM threshold mapping (chốt — dùng trong `core/env.sh`):**

```bash
# RAM_MB < 1500     → Tier S
# RAM_MB 1500-5000  → Tier M
# RAM_MB > 5000     → Tier L
if   (( RAM_MB < 1500 ));                   then OPS_TIER="S"
elif (( RAM_MB >= 1500 && RAM_MB < 5000 )); then OPS_TIER="M"
else                                             OPS_TIER="L"
fi
```

OPS should detect actual RAM/CPU and map to the closest tier.



---

### 2. Nginx tuning

For all tiers:

- `worker_processes`: set to number of CPU cores (or `auto`).
- `worker_connections`: at least 2048.
- Enable gzip for text assets; avoid compressing already-compressed formats.

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

### 3. PHP-FPM tuning (per version)

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

### 4. MariaDB tuning (default engine)

**Security baseline (chot — all tiers, applied by `_db_apply_security_hardening`):**

See SECURITY-RULES.md §7 for the full security hardening table.
`bind-address = 127.0.0.1` must always be set — MariaDB must never bind to 0.0.0.0.

**Performance settings per tier** (written to `60-ops-tuning.cnf` by `tune_mariadb()`):

| Setting | Tier S (<1500MB) | Tier M (1500-5000MB) | Tier L (>5000MB) |
|---|---|---|---|
| `innodb_buffer_pool_size` | 512M | 2G | 5G |
| `innodb_buffer_pool_instances` | 1 | 2 | 4 |
| `innodb_log_file_size` | 64M | 256M | 512M |
| `max_connections` | 80 | 150 | 300 |
| `tmp_table_size` | 32M | 64M | 128M |
| `max_heap_table_size` | 32M | 64M | 128M |

**InnoDB / SSD settings (all tiers, fixed values):**

| Setting | Value | Reason |
|---|---|---|
| `key_buffer_size` | `8M` | Default 128MB wasted on InnoDB-only setups (MyISAM index cache) |
| `innodb_flush_neighbors` | `0` | No benefit from neighbour-page flushing on SSD |
| `innodb_io_capacity` | `1000` | Match typical cloud SSD IOPS (default 200 is HDD-era) |
| `innodb_io_capacity_max` | `4000` | Burst capacity for large checkpoint flushes |

OPS must not oversubscribe memory; values must remain conservative by default.

---

### 5. Node.js and PM2

For Node.js services (including 9router):

- **Process count**:
  - Start with a single process per app unless:
    - CPU cores > 2
    - and the app is clearly CPU-bound.
  - For CPU-bound apps on Tier M/L, consider up to `min(cores, 4)` processes.
- **Environment**:
  - Set `NODE_ENV=production` by default.
  - Avoid enabling verbose logging unless explicitly requested.

OPS should provide sensible defaults but leave app-specific tuning (e.g. cluster mode) to the application owner where appropriate.

---

### 6. Capacity estimates

OPS stores a capacity estimate (based on tier) to help set expectations:

- **Tier S**
  - 1–3 low-traffic sites.
  - Roughly tens of concurrent users per site under typical conditions.
- **Tier M**
  - 3–8 low-to-medium-traffic sites.
  - Hundreds of concurrent users total with proper caching.
- **Tier L**
  - 8+ sites.
  - Higher concurrency depending on application behaviour and caching.

These are indicative only and must be presented as **guidance, not guarantees**.

---

### 7. Updating this document

When changing any tuning logic in code:

1. Update this document first with the new strategy and rationale.
2. Ensure module implementations reference these rules rather than hard-coding unrelated values.



---

### 8. Swap sizing per tier

Swap is **mandatory** on all VPS setups managed by OPS (see SECURITY-RULES.md §10). Without swap, the OOM killer terminates services arbitrarily on memory spikes.

| Tier | Typical RAM | Recommended Swapfile |
|------|-------------|----------------------|
| S    | ≤1.5GB      | 2GB                  |
| M    | 1.5–5GB     | 2GB                  |
| L    | >5GB        | 4GB                  |

- `vm.swappiness = 10` — prefer RAM heavily; use swap only when RAM is near-exhausted.
- Swapfile location: `/swapfile` (managed by OPS, persisted in `/etc/fstab`).

---

### 9. PHP security ini tuning notes

The following PHP ini values are applied by `php_ini_tuning_for_tier` as a **security baseline** (non-tier-specific, always applied):

| Setting | Value | Reason |
|---------|-------|--------|
| `expose_php` | `Off` | Hides PHP version from HTTP headers |
| `display_errors` | `Off` | No stack traces in browser output |
| `log_errors` | `On` | Errors go to log file, not browser |
| `allow_url_fopen` | `Off` | Prevents SSRF via PHP file wrappers |
| `allow_url_include` | `Off` | Prevents remote code inclusion |
| `disable_functions` | see SECURITY-RULES.md §6 | Blocks common RCE function calls |

> **Note:** Apps using `file_get_contents('https://...')` for external API calls must be migrated to use cURL after OPS tuning is applied.
