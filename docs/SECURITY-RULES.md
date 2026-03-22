## OPS Security Rules

This document defines non-negotiable security rules for OPS. Any change that violates these rules is a bug and must be rejected or fixed.

### 1. SSH and user accounts

- OPS must:
  - Enforce use of a **non-root admin/runtime user** for SSH and day-2 operations.
  - Support changing the SSH port from 22 to a user-defined port.
  - Keep only the locked SSH port active in steady state, with an explicitly recorded transition port allowed only during controlled migration.
  - Reconcile both `/etc/ssh/sshd_config` and `/etc/ssh/sshd_config.d/*.conf` so stale overrides cannot silently re-enable insecure settings.
  - Offer a guided step to close the old SSH port once login on the new port has been verified.
- Prompts must clearly show the **new SSH port and admin username**, for example:

  ```text
  After reboot, you MUST use:
    ssh -p <NEW_PORT> <ADMIN_USER>@<SERVER_IP_OR_HOSTNAME>
  ```

- Root login must be disabled once the admin user is set up.
- Password authentication must be disabled after the controlled transition window is complete.
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
- **Exception — 9router only**: Next.js requires `HOSTNAME=0.0.0.0` to bind its HTTP server.
  This is permitted under the following conditions (all three must hold):
  1. UFW **does not** open port 20128 (verified by `ufw status | grep 20128`).
  2. Nginx proxies 9router via `proxy_pass http://127.0.0.1:20128`.
  3. A default-deny Nginx server block is in place to reject unknown hosts.
- There should be a default Nginx server that rejects unknown hosts (e.g. 444 or 404).
- Direct access by `http://<SERVER_IP>` should be blocked or rejected by the default server path.

### 3. 9router exposure

- 9router must:
  - Never be exposed directly through firewall (UFW must not open port 20128).
  - Be reachable only via Nginx and, where applicable, Cloudflare Access.
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
  - Deny other inbound ports by default — **including port 20128 (9router)**.
- `fail2ban`:
  - **Must be installed** (via `apt_install fail2ban`) **and enabled** by the end of wizard Step 1 (Security Baseline).
  - `security_apply_host_baseline` and `security_setup_fail2ban` must call `apt_install fail2ban` if not already present before attempting to configure it.
  - Must follow the real SSH port set in OPS state, including temporary multi-port transition windows.
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
  - If an app pool requires a function in `disable_functions`, add a `php_admin_value` override in that pool's `.conf` file only.
- PHP-FPM pools:
  - Run under non-root users.
  - Have file/directory permissions restricted to what applications need.

### 7. Database security

- Default DB engine: **MariaDB** (drop-in replacement; chosen for Ubuntu repo availability and performance).
- MySQL is alternative; operator must explicitly choose MySQL over MariaDB.
- Secure setup must:
  - Remove anonymous users.
  - Disable remote root login unless the user explicitly opts in.
  - Remove test databases.
  - Require passwords for all non-local accounts.
- Database users created by OPS:
  - Should have least privilege (e.g. per-database accounts).
- DB root password stored in `/etc/ops/.db-root-password` (0600) — never printed to terminal.

### 8. File safety and backups

- Before writing or replacing critical config files, OPS must:
  - Create backup copies with clear timestamps or suffixes.
  - Fail safely on errors rather than producing partial configs.
- For Nginx, PHP-FPM, and systemd:
  - Changes must be validated (e.g. `nginx -t`) before reloading services.
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
- Secret files must have restrictive permissions (`0600`, owned by admin or runtime service user as appropriate):
  - `/opt/9router/.env` (JWT_SECRET, INITIAL_PASSWORD, API_KEY_SECRET)
  - `/etc/ops/.nine-router-password` (9router dashboard password)
  - `/etc/ops/.db-root-password` (MariaDB/MySQL root password)
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
| `Strict-Transport-Security` | `max-age=63072000; includeSubDomains; preload` |
| `X-Frame-Options` | `SAMEORIGIN always` |
| `X-Content-Type-Options` | `nosniff always` |
| `Referrer-Policy` | `strict-origin-when-cross-origin always` |
| `X-XSS-Protection` | `1; mode=block always` |
| `Permissions-Policy` | `geolocation=(), microphone=(), camera=(), payment=(), usb=()` |
| `Content-Security-Policy` | restrictive default (see `_nginx_apply_global_tuning`); per-vhost overrides allowed |

- `server_tokens off` must always be set.
- **HSTS must include `preload`** — minimum `max-age=63072000` (2 years) required for HSTS preload list eligibility.
- Node.js vhosts (proxy_pass) **must include** `proxy_hide_header X-Powered-By;` and `proxy_hide_header Server;` to prevent technology fingerprinting.
- CSP `unsafe-inline` and `unsafe-eval` are permitted at the global level for Next.js/SPA compatibility; however, per-vhost overrides should tighten this where possible.

Security rules are intentionally conservative; usability should be improved without relaxing these guarantees unless the spec is explicitly updated.
