## OPS Security Rules

This document defines non-negotiable security rules for OPS. Any change that violates these rules is a bug and must be rejected or fixed.

### 1. SSH and user accounts

- OPS must:
  - Enforce use of a **non-root admin/runtime user** for SSH and day-2 operations.
  - Support changing the SSH port from 22 to a user-defined port.
  - Keep only the locked SSH port active in steady state, with an explicitly recorded transition port allowed only during controlled migration.
  - During installer/bootstrap reruns, preserve every detected live SSH port in UFW until OPS has an unambiguous managed state; do not collapse multi-port hosts to one guessed port.
  - In that ambiguous rerun state, do not rewrite `OPS_SSH_PORT` / `OPS_SSH_TRANSITION_PORT` until OPS can identify the managed SSH state safely.
  - Reconcile both `/etc/ssh/sshd_config` and `/etc/ssh/sshd_config.d/*.conf` so stale overrides cannot silently re-enable insecure settings.
  - Offer a guided step to close the old SSH port once login on the new port has been verified.
  - Keep transition state recorded and avoid reporting success if SSH validation/reload-restart, UFW reconcile, or fail2ban apply fails during finalization.
- Prompts must clearly show the **new SSH port and admin username**, for example:

  ```text
  After reboot, you MUST use:
    ssh -p <NEW_PORT> <ADMIN_USER>@<SERVER_IP_OR_HOSTNAME>
  ```

- Root login must be disabled once the admin user is set up.
- Password authentication must be disabled after the controlled transition window is complete.
- **SSH lockout prevention (non-negotiable):** OPS must NOT disable `PasswordAuthentication` unless
  the admin user has at least one valid public key in `~/.ssh/authorized_keys`. The check is
  performed by `_security_has_authorized_keys()` before offering the disable prompt in both:
  - `security_wizard_baseline()` (Setup Wizard step 1>1)
  - `security_harden_ssh()` (Security menu > 1)
  If no key is present, `PasswordAuthentication` remains `yes` regardless of user input.
- **Installer-time rule:** the bootstrap installer may add the admin user's SSH public key, but it
  must still keep `PasswordAuthentication yes` until the operator has verified SSH access on the
  admin user and locked SSH port. Disabling password auth belongs to the wizard/security flow, not
  to the installer itself.
- SSH hardening baseline must disable at least:
  - `PermitRootLogin`
  - `PasswordAuthentication` (outside transition)
  - `X11Forwarding`
  - `AllowTcpForwarding`
  - `AllowAgentForwarding`
  - `AllowStreamLocalForwarding`
  - `PermitTunnel`

### 2. Network exposure and Nginx

- Nginx must be the **only public HTTP(S) entrypoint**.
- Backend services (Node.js apps, PHP-FPM sockets) must:
  - Bind to localhost (`127.0.0.1`) or Unix sockets.
  - Never listen publicly without Nginx proxying in front.
- **CLIProxyAPI contract**: CLIProxyAPI must bind `127.0.0.1:8317` and be reached only through Nginx.
- There should be a default Nginx server that rejects unknown hosts (e.g. 444 or 404).
- Direct access by `http://<SERVER_IP>` should be blocked or rejected by the default server path.

### 3. CLIProxyAPI exposure

- CLIProxyAPI must:
  - Bind to `127.0.0.1:8317` only.
  - Never be exposed directly through firewall (UFW must not open port 8317).
  - Be reachable only via Nginx and, where applicable, Cloudflare Access.
  - Use Nginx as the only public entrypoint; direct public access to `8317` is a bug.
- **Implementation authority for CLIProxyAPI network posture**:
  - `ops/modules/cli-proxy-api.sh`
  - `ops/modules/templates/nginx/cli-proxy-api.vhost.conf.tpl`
  - `ops/modules/nginx.sh`
  - `ops/modules/verify.sh`
- For Cloudflare Access setups:
  - Protect only the intended router domain.
  - Keep Cloudflare proxy enabled and use `Full (strict)` when applicable.
  - Treat Cloudflare Access as an additional gate, not a replacement for firewall rules.
- Keep a default Nginx server that rejects unknown hosts.
- If Cloudflare sits in front of a domain, real visitor IP logging must use a managed and auditable real-IP configuration path rather than ad hoc edits.

### 4. Firewall and fail2ban

- UFW (or equivalent firewall) must:
  - Be reconciled from OPS state, not left as an append-only ruleset.
  - Allow only:
    - SSH port(s) currently recorded in OPS state.
    - HTTP (80).
    - HTTPS (443).
  - Remove stale SSH allow rules once transition is finalized.
  - Not have any `ALLOW` rule for port `8317` (CLIProxyAPI).
  - Rely on default-deny posture for other inbound ports; explicit `DENY 8317` is not required and stale deny rules may be removed.
- `fail2ban`:
  - **Must be installed** (via `apt_install fail2ban`) **and enabled** by the end of wizard Step 1 (Security Baseline).
  - `security_apply_host_baseline`, `security_setup_fail2ban`, and SSH finalization must call `apt_install fail2ban` if not already present before attempting to configure it.
  - SSH finalization must treat fail2ban reconciliation as mandatory: do not clear `OPS_SSH_TRANSITION_PORT` unless fail2ban config write, enable, restart, and `fail2ban-client status sshd` all succeed.
  - Generated SSH jail policy must come from OPS state (`OPS_SSH_PORT` plus optional `OPS_SSH_TRANSITION_PORT`), including temporary multi-port transition windows.
  - `sshd -T`, `ss -tlnp`, and `fail2ban-client` are validation/diagnostic inputs here, not policy-generation inputs.
  - Should include a minimal Nginx-facing baseline when the host serves public web traffic.
  - Configuration changes must be conservative; avoid breaking legitimate SSH access.

### 5. TLS and certificates

- Certbot is the default ACME client — install via **snap** (primary), apt as fallback.
- Certificates should:
  - Use secure defaults (strong ciphers, modern TLS versions).
  - Be renewed automatically or via simple periodic commands.
- Nginx global baseline must enforce at least:
  - `server_tokens off`
  - `ssl_protocols TLSv1.2 TLSv1.3`
  - validation with `nginx -t` before reload
- OPS must not:
  - Store private keys in world-readable locations.
  - Print private keys directly to the terminal except where explicitly requested by the user.

### 6. PHP security

- PHP configuration must:
  - **Disable dangerous functions** — set `disable_functions` at minimum to:
    `exec, passthru, shell_exec, system, proc_open, popen, proc_terminate, proc_get_status, pcntl_exec, parse_ini_file, show_source`.
  - Set `expose_php = Off` (hides PHP version from HTTP headers).
  - Set `display_errors = Off` and `log_errors = On` (never expose stack traces to browsers).
  - Set `allow_url_fopen = Off` (prevents SSRF via PHP file wrappers; apps must use cURL for remote HTTP).
  - Set `allow_url_include = Off`.
  - Set sensible `memory_limit`, `max_execution_time`, `post_max_size`, `upload_max_filesize`.
  - Enable and correctly tune opcache.
  - Common performance tuning may apply to both CLI and FPM, but **security-sensitive hardening** (`disable_functions`, `allow_url_fopen`, `allow_url_include`, `display_errors`, `log_errors`, `expose_php`) must be applied to PHP-FPM by default, not forced onto CLI workloads.
  - If an app pool requires a function in `disable_functions` or needs `allow_url_fopen = On`, add a `php_admin_value` override in that pool's `.conf` file only.
  - `pm.status_path` and `ping.path` should stay disabled in the default pool baseline. If you enable them for debugging, expose them only through a localhost-only Nginx location.
- PHP-FPM pools:
  - Run under non-root users.
  - Have file/directory permissions restricted to what applications need.
  - Use one explicit pool identity for the pool file, socket path, and `/etc/ops/php-sites/<pool>.conf` state.
  - Re-running pool configuration must refresh OPS-managed keys without deleting existing per-pool `env[]`, `php_admin_value`, or `php_admin_flag` overrides, including across PHP version migration.

### 7. Database security

- Default and currently supported DB engine: **MariaDB**.
- OPS baseline uses local `unix_socket` root auth. `/etc/ops/.db-root-password` is a legacy/fallback secret file only when password auth is explicitly in use; it must never be printed to terminal.
- OPS-managed DB app credentials must live under `/etc/ops/db-credentials/<db>__<user>.conf` with mode `0600`, owned by the admin user.
- Secure setup must:
  - Remove anonymous users.
  - Disable remote root login unless the user explicitly opts in.
  - Remove test databases.
  - Require passwords for all non-local accounts.
- Database users created by OPS:
  - Should have least privilege (e.g. per-database accounts).
  - Must be created idempotently; OPS must not persist credentials that were never actually applied in MariaDB.
- `db_secure()`, `db_apply_tuning()`, and reinstall/upgrade flows must validate MariaDB config before restart and require explicit operator acknowledgement before live downtime.

**OPS MariaDB hardening baseline (enforced by `install_mariadb` / `db_install`):**

The following settings are written to `/etc/mysql/mariadb.conf.d/60-ops-tuning.cnf` and are **non-negotiable** on every OPS-managed MariaDB installation:

| Setting | Required Value | Reason |
|---|---|---|
| `bind-address` | `127.0.0.1` | Never expose DB to network |
| `local_infile` | `OFF` | Blocks `LOAD DATA LOCAL` file exfiltration |
| `secure_file_priv` | `/var/lib/mysql-files-disabled` (non-existent path) | Disables `SELECT INTO OUTFILE` / `LOAD DATA INFILE` without relying on MariaDB `NULL` parsing |
| `skip_name_resolve` | `ON` | Eliminates per-connection DNS lookup latency |
| `max_connect_errors` | `100` | Avoid self-DoS from noisy reconnect storms while still capping repeated bad auth attempts |
| `wait_timeout` | `300` | Close idle connections after 5 min (was 8h default) |
| `interactive_timeout` | `600` | Close idle interactive sessions after 10 min |

**OPS MariaDB SSL (enforced by `_db_setup_ssl`):**
- Self-signed CA + server cert generated at `/etc/mysql/ssl/` (owned `mysql:mysql`, mode 600).
- `ssl-ca`, `ssl-cert`, `ssl-key` written to `60-ops-tuning.cnf`.
- SSL certs are valid 10 years; rotate via `db_apply_tuning` (deletes old certs first).

**OPS MariaDB Logging (enforced by `_db_setup_logging`):**
- `log_error = /var/log/mysql/error.log`
- `slow_query_log = ON`, `long_query_time = 2s`, `log_slow_verbosity = query_plan,explain`
- `log_queries_not_using_indexes = ON`

### 8. File safety and backups

- Before writing or replacing critical config files, OPS must:
  - Create backup copies with clear timestamps or suffixes.
  - Fail safely on errors rather than producing partial configs.
- For Nginx, PHP-FPM, and systemd:
  - Changes must be validated (e.g. `nginx -t`) before reloading services.
- Managed symlink reconciliation (for example `/usr/local/bin/ops` and `/usr/local/bin/ops-dashboard`) must:
  - no-op when the symlink already points to the desired OPS target
  - replace only clearly OPS-managed/stale OPS symlinks
  - refuse to remove foreign regular files, foreign symlinks, or directories
- For PM2-managed Node services:
  - Run processes under a non-root runtime user.
  - **PM2 startup (`pm2 startup systemd`) MUST be configured for the runtime user, not `root`.** Running `pm2 startup` as root causes all PM2-managed processes to run as root, which is a critical security violation.
  - **`pm2-logrotate` MUST be installed** immediately after PM2 (`pm2 install pm2-logrotate`). Without it, logs in `/var/log/ops/` grow unbounded and can fill the disk, causing service crashes.
    - Recommended settings: `max_size=20M`, `retain=7`, `compress=true`, `rotateInterval=0 0 * * *`
  - All ecosystem configs MUST include `merge_logs: true` to prevent PM2 appending `-<id>` suffixes to log filenames on instance count changes.
  - `kill_timeout` must be set in ecosystem configs to allow graceful shutdown (minimum 5000ms; Next.js apps require ≥8000ms to drain SSR requests).
  - Set `node_args: "--max-old-space-size=<N>"` to ≈90% of `max_memory_restart` so V8 GC runs aggressively before PM2 triggers a hard restart.
  - Root PM2 daemon (`/root/.pm2`) must not coexist with the runtime user's daemon. Kill it after setup: `PM2_HOME=/root/.pm2 pm2 kill`.
  - All `pm2 list` / status displays inside OPS must run via `_node_run_as_runtime_user` — bare `pm2 list` as root shows root's empty daemon.
  - Reconcile app directory ownership to that runtime user where OPS manages the deployment path.
  - Verify process health, restart behaviour, and localhost binding after changes.

### 9. Logging and secrets

- OPS must avoid:
  - Printing secrets (passwords, tokens, API keys) into logs.
  - Storing secrets in world-readable files.
- `/var/log/ops` must be root-owned and not group-writable (`0755` or stricter).
- OPS-managed log files such as `/var/log/ops/ops.log` and `/var/log/ops/checks.log` must be root-owned `0640` (or stricter) and created safely under rerun/reconcile flows.
- Secret files must have restrictive permissions (`0600`, owned by admin or runtime service user as appropriate):
  - `/opt/cli-proxy-api/config.yaml` (local API keys and managed proxy settings)
  - `/etc/ops/.cli-proxy-api-key` (CLIProxyAPI local client key)
  - `/etc/ops/db-credentials/*.conf` (OPS-managed MariaDB app credentials)
  - `/etc/ops/.db-root-password` (legacy/fallback MariaDB root password file when password auth is explicitly used)
  - `/etc/ops/.codex-api-key` (Codex CLI API key)
  - `~/.codex/config.toml` (Codex CLI config with API key)
- When prompting for secrets, prefer:
  - Hidden input (no echo).
  - Clear instructions on how to rotate or regenerate secrets.
- Notification and remote-backup integrations (Telegram, Email, provider APIs) must:
  - Store secrets in restricted files.
  - Document secret locations but never literal values.
  - Make rotation and disable paths explicit.

### 10. Host kernel and memory baseline

- OPS host baseline should be idempotent and re-runnable.
- At minimum, OPS should be able to enforce:
  - `net.ipv4.conf.all.send_redirects = 0`
  - `net.ipv4.conf.default.send_redirects = 0`
  - `net.ipv4.conf.all.log_martians = 1`
  - `net.ipv4.conf.default.log_martians = 1`
  - low `vm.swappiness` (10)
- **Swap MUST be provisioned unconditionally during wizard Step 1** (Security Baseline), regardless of SSH port change outcome. Without swap, the OOM killer can terminate Nginx, MariaDB, or Node processes arbitrarily.
- Swap provisioning must:
  - create a managed swapfile at `/swapfile` with `0600` permissions
  - persist in `/etc/fstab` (idempotent — no duplicate entries)
  - remain safe to re-run when swapfile already exists

### 11. Database runtime safety

- MariaDB must bind localhost unless the operator explicitly chooses otherwise.
- Rescue or break-glass startup modes such as `--skip-grant-tables` must never remain in place after setup.
- OPS verify/audit must treat an unmanaged MariaDB rescue process as a production blocker.

### 12. AI and automation considerations

- AI agents modifying OPS must:
  - Respect all rules in this document and in `rules/`.
  - Avoid introducing features that weaken defaults (e.g. opening extra ports) without:
    - A clear, documented reason.
    - An explicit, opt-in prompt to the user.
- Any new module or feature that touches security-sensitive areas must:
  - Add or update relevant sections here.
  - Be designed opt-in by default when risk is non-trivial.

### 13. Nginx global security headers

The `http {}` block in `/etc/nginx/nginx.conf` MUST enforce all of the following headers (applied via `_nginx_apply_global_tuning`):

| Header | Required Value |
|--------|----------------|
| `X-Frame-Options` | `SAMEORIGIN always` |
| `X-Content-Type-Options` | `nosniff always` |
| `Referrer-Policy` | `strict-origin-when-cross-origin always` |
| `X-XSS-Protection` | `1; mode=block always` |
| `Permissions-Policy` | `geolocation=(), microphone=(), camera=(), payment=(), usb=()` |
| `Content-Security-Policy` | restrictive default (see `_nginx_apply_global_tuning`); per-vhost overrides allowed |

> [!IMPORTANT]
> **`Strict-Transport-Security` (HSTS) is intentionally NOT set in the global `http {}` block.**
> Per RFC 6797 §7.2, browsers ignore HSTS headers delivered over plain HTTP, and injecting
> HSTS into the global block causes policy errors on non-SSL vhosts. HSTS is applied
> exclusively inside each SSL (`listen 443`) `server {}` block generated by `_render_*_vhost()`.
> The default value for every SSL vhost is: `max-age=31536000; includeSubDomains`
> (1 year, no `preload` — see S3-1 fix below).

- `server_tokens off` must always be set.
- Global Nginx hardening must keep `limit_req_zone` and `limit_conn_zone` definitions inside `http {}` as shared baseline controls.
- Standard vhosts may enforce those zones with per-vhost `limit_req` / `limit_conn`.
- The CLIProxyAPI vhost must keep `proxy_buffering off` and continue proxying to loopback only.
- AI agents must not break the global zone definitions when editing CLIProxyAPI-related docs or vhosts. Global hardening and provider-specific proxy settings are separate.
- **S3-1 fix — HSTS `preload` is an explicit operator opt-in, NOT a default.**
  Per [Google's HSTS guidelines](https://hstspreload.org/) and hstspreload.org:
  - The OPS default is `max-age=31536000; includeSubDomains` (1 year, no `preload`).
  - `preload` submits the domain to browser-maintained preload lists (Chrome, Firefox, Safari, Edge).
    Removal takes **6–12 months** to propagate — effectively irreversible short-term.
  - `includeSubDomains` means **every subdomain** must also be HTTPS-only before adding `preload`.
  - Operators who intentionally commit to a production domain may manually change the value to
    `max-age=31536000; includeSubDomains; preload` and submit at https://hstspreload.org/
    **after** verifying all subdomains are HTTPS-ready.
  - Applied per-SSL-vhost only — never in the global `http {}` block (see note above).
- Node.js vhosts (proxy_pass) **must include** `proxy_hide_header X-Powered-By;` and `proxy_hide_header Server;` to prevent technology fingerprinting.
- CSP `unsafe-inline` and `unsafe-eval` are permitted at the global level for Next.js/SPA compatibility; however, per-vhost overrides should tighten this where possible.

Security rules are intentionally conservative; usability should be improved without relaxing these guarantees unless the spec is explicitly updated.

### 14. Database runtime hardening compliance

The following settings are the minimum security posture that `_vs_check_mariadb()` in `verify.sh` enforces on every `verify_stack` run. Any deviation is a **WARN** or **FAIL**:

| Variable | Expected | Severity if wrong |
|---|---|---|
| `bind_address` | `127.0.0.1` or `localhost` | FAIL |
| `local_infile` | `OFF` | FAIL |
| `have_ssl` | `YES` | FAIL |
| `secure_file_priv` | non-empty disabled path (for OPS: `/var/lib/mysql-files-disabled`) | WARN |
| `slow_query_log` | `ON` | WARN |
| `skip_name_resolve` | `ON` | WARN |

- FAIL items are production blockers; they prevent `verify_stack` from scoring PASS on the Database component.
- WARN items are degraded-posture issues; they display with `[WARN]` but do not block scoring.
- All FAIL items are automatically fixed by running **Database → Apply tuning** from the OPS menu or calling `db_apply_tuning`.

---

### 11. Nginx hardening baseline (extended)

The following rules apply to every Nginx installation managed by OPS (enforced by `_nginx_apply_global_tuning`):

**HTTP/2:** All HTTPS virtual hosts MUST use the two-directive nginx 1.25.1+ canonical form:
```nginx
listen 443 ssl;
listen [::]:443 ssl;
http2 on;
```
The old combined form (`listen 443 ssl http2;`) is accepted by `_vs_check_nginx` for backward compat but must not be used in new renders. HTTP/1.1-only is not acceptable.

**Rate limiting:** The global http block must define `limit_req_zone` and `limit_conn_zone`. Default zones:
- `ops_req: 100r/s per IP` — burst 200 per vhost location
- `ops_conn: 10m` — max 30 concurrent connections per IP per vhost

**Client body limits:** `client_max_body_size 10m` must always be set. Protects against large-payload DoS.

**Gzip must be fully configured:** `gzip on` alone is insufficient. `gzip_types` must include at minimum `application/json`, `text/css`, `application/javascript`. A bare `gzip on` without `gzip_types` only compresses `text/html`.

**Cloudflare IP restrict (opt-in):** When a domain is fully behind Cloudflare (Orange Cloud ON), use `nginx_enable_cloudflare_ip_restrict` (Advanced Web Controls menu) to add a `geo $blocked_cf` block serving 444 to non-CF IPs. This is **not auto-applied** because it breaks direct-access setups.

**Nginx version:** Must be >= 1.24. OPS adds nginx.org mainline repo during install. Running Ubuntu distro package (1.18.0) is a policy violation (`_vs_check_nginx` will WARN).

**worker_rlimit_nofile:** Must be set to 65535 in the main context. Without this, `worker_connections 8192` is silently constrained by the OS default ulimit (~1024).
