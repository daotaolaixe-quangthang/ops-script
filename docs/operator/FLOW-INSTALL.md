
## OPS Install & First‑Run Flow

This document describes the exact end‑to‑end flow from a fresh VPS to a production‑ready stack managed by OPS. It is the primary reference for how installers and wizards should behave.

> Target: Ubuntu 22.04 / 24.04, systemd, Nginx + Node + multi‑PHP + MariaDB (default).

### 1. One‑line installer

The recommended entrypoint for users:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/daotaolaixe-quangthang/ops-script/main/install/ops-install.sh)
```

> **Installer URL (chốt)**: `https://raw.githubusercontent.com/daotaolaixe-quangthang/ops-script/main/install/ops-install.sh`
>
> Process substitution is the recommended entrypoint because it preserves the TTY for interactive prompts.

The `ops-install.sh` script **must**:

1. Verify OS is supported (Ubuntu 22.04/24.04).
2. Gather basic VPS info (RAM, CPU cores, disk).
3. Show a short summary and confirmation prompt.



Installer asks for:

1. **New SSH port** (with default suggestion, e.g. `2222`):
   - Validate port is not in use and > 1024.
   - Add new port to `sshd_config` but keep port 22 temporarily.
   - Open both ports in firewall.
   - On rerun, if the host already has multiple live SSH ports, preserve all detected live SSH ports during bootstrap and do not collapse firewall/state down to a guessed single port.
   - In that ambiguous rerun case, do not rewrite `OPS_SSH_PORT` / `OPS_SSH_TRANSITION_PORT` until OPS can infer a managed state unambiguously.

2. **Non‑root admin user** (e.g. `opsadmin` with a suggested default):
   - Create user, set password, add to `sudo`.
   - This user is used for daily SSH and to run Node/PM2 services.

2b. **SSH public key setup** (optional but strongly recommended):
   - Immediately after admin user creation, installer prompts operator to paste their SSH public key.
   - If provided: creates `~/.ssh/authorized_keys` with correct permissions (`700`/`600`, `chown ADMIN_USER`).
   - If skipped: warns that `PasswordAuthentication` will remain `yes` until a key is added later.
   - Sets internal state `SSH_KEY_CONFIGURED=yes|no`, used by the Security Wizard to guard against
     disabling `PasswordAuthentication` without any key present (prevents SSH lockout).
   - **Installer-time rule:** OPS still keeps `PasswordAuthentication = yes` during the bootstrap phase,
     even if a key was pasted successfully. Disabling password auth is only offered later from the
     Security Wizard / Security menu after the operator has verified SSH access on the admin user
     and locked SSH port.
   - Idempotent: no-op if `authorized_keys` already contains a valid key.


3. **Capacity estimation**:
   - Capture RAM, CPU cores, root-disk total, and root-disk available.
   - Compute `OPS_TIER` from RAM only, then derive:
     - Recommended number of active Node.js / CLIProxyAPI sites.
     - Rough concurrent user range per site.
   - Store this in `/etc/ops/capacity.conf` as a shell-sourceable key=value file for later display.

After this step, installer:

- Before any bootstrap mutation to SSH, UFW, admin-user state, SSH keys, or minimum SSH hardening, snapshots the current host state so a pre-activation failure can roll back cleanly.
- Builds and validates a full staged OPS tree before touching the live `/opt/ops` path.
- Activates `/opt/ops` only after staged syntax checks pass, including extensionless Bash entrypoints such as `bin/ops` and `bin/ops-dashboard`.
- Runs `/opt/ops/bin/ops-setup.sh` only after the live tree activation succeeds.
- If bootstrap fails before activation completes, OPS restores the previous SSH/UFW/admin-user/bootstrap-key/minimum-hardening state before exiting.
- If post-deploy setup fails after activation (for example `ops-setup.sh` or `capacity.conf` write), OPS restores the previous `/opt/ops` tree and operator-facing state (`ops.conf`, symlinks, login hook) before exiting with failure.

### 3. `ops-setup.sh` responsibilities

`ops-setup.sh` is idempotent and:

1. Creates symlinks:
   - `/usr/local/bin/ops` → `/opt/ops/bin/ops`
   - `/usr/local/bin/ops-dashboard` → `/opt/ops/bin/ops-dashboard`
2. Wires login hook:
   - When an interactive shell starts for the admin user, run `ops-dashboard`.
   - The hook is display-only; it must not mutate SSH/firewall state.
   - On rerun, OPS rewrites one managed login-hook block and only removes the legacy auto-finalize sudoers rule after the hook migration succeeds.
   - After showing the dashboard, print a prompt like:

     ```text
     Press 1 to open OPS menu, or Enter to continue to the shell:
     ```

3. Writes global config file `/etc/ops/ops.conf` (install version, paths, defaults).

User is then instructed to **logout and SSH back in** using the new admin user (they can still use port 22 until final switch).

### 4. Login experience after setup

When the admin user logs in:

1. `ops-dashboard` runs and shows:
   - Hostname, OS, uptime.
   - CPU cores, load averages.
   - RAM and swap usage.
   - Disk usage for root filesystem.
   - Status summary for key services (if already configured).
2. The prompt offers:

   ```text
   Press 1 to open OPS menu, or Enter to continue to the shell:
   ```

3. If user presses `1`, `ops` is executed and the main TUI menu appears.

### 5. First‑time Production Setup Wizard

From the main menu, user selects **“Production Setup Wizard”** (or similar). The wizard orchestrates first‑time configuration:

1. **System update & base tools**
   - Optionally run `apt update && apt upgrade`.
   - Install base packages: `curl`, `git`, `ufw`, `fail2ban`, `htop`, `jq`, `logrotate` (if needed).

2. **Firewall & basic security**
   - Enable UFW (if disabled).
   - Allow SSH ports (22 + new port during transition).
   - Allow HTTP (80) and HTTPS (443).
   - Install and configure `fail2ban` for SSH at minimum (`apt_install fail2ban` then `security_write_fail2ban_config`).
   - **Provision swap file** (default 2GB) if no swap is present:
     - `fallocate -l 2G /swapfile`, `mkswap`, `swapon`, persist in `/etc/fstab`.
     - `vm.swappiness = 10` applied via sysctl.
   - Apply kernel hardening via `/etc/sysctl.d/99-ops-hardening.conf`.

3. **Nginx installation & tuning**
   - Install Nginx from nginx.org mainline repo (enforced by `_nginx_add_official_repo()`; Ubuntu distro package is rejected as it ships 1.18.0 with known CVEs).
   - Apply tuning based on RAM/CPU via `docs/reference/PERF-TUNING.md`:
     - `worker_processes`
     - `worker_connections`
     - keepalive, timeouts, gzip.
   - Set up `sites-available` / `sites-enabled` if not already present.

4. **Node.js LTS and PM2**
   - Install Node.js LTS (exact method documented in module).
   - Install PM2 globally.
   - Configure PM2 startup **for the runtime user** (not root): runs `pm2 startup systemd -u <runtime_user>` automatically.
   - PM2 processes must always run under the non-root runtime user (e.g. `opsuser`).
   - Install `pm2-logrotate` immediately after PM2: `pm2 install pm2-logrotate`.
     - Configure: `max_size=20M`, `retain=7`, `compress=true`, daily rotate.
   - Kill root PM2 ghost daemon if empty: `PM2_HOME=/root/.pm2 pm2 kill`.
   - All ecosystem configs must include `merge_logs: true`, `kill_timeout ≥ 5000`, and `node_args: "--max-old-space-size=<N>"` at ≈90% of `max_memory_restart`.

5. **PHP‑FPM (multi‑version)**
   - Ask which PHP versions to install: 7.4, 8.1, 8.2, 8.3.
   - For each selected version:
     - Install PHP + FPM + common extensions.
     - Generate FPM pool config from templates with tuning rules.
     - Configure `php.ini` with opcache tuning **and security baseline**:
       - `disable_functions` (blocks exec, system, shell_exec, etc.)
       - `allow_url_fopen = Off` (apps must use cURL for remote URLs)
       - `expose_php = Off`, `display_errors = Off`, `log_errors = On`.

6. **Database (MariaDB)**
   - Ask whether to install a database server now.
   - If yes:
     - Install MariaDB.
     - Run secure setup (unix_socket root baseline, remove anonymous users, drop test DBs, etc.).
     - Apply tuning from `docs/reference/PERF-TUNING.md`. 

7. **Logging & basic monitoring**
   - Ensure the OPS log path (`/var/log/ops/ops.log`) exists and is rotated via `/etc/logrotate.d/ops`.
   - Ensure `logrotate` rules for Nginx, PHP‑FPM, and Node/PM2 logs.
   - Optionally install simple monitoring tools (e.g. `htop`).

8. **Summary & verification**
   - Run checks to confirm:
     - Nginx active.
     - Node and PM2 installed.
     - PHP‑FPM versions installed (if selected).
     - DB server running (if installed).
   - Show a summary screen with next recommended actions:
     - Use Node.js / CLIProxyAPI menus to create services.
     - Use Domain & SSL menus to attach domains.

The wizard should be re‑runnable; subsequent runs should detect existing state and ask before changing configs.

### 6. SSH port finalisation

After the stack and menus are confirmed to be working, OPS offers a security hardening step to finish the SSH transition:

Prompt example:

```text
Everything looks ready.

We will now:
- close SSH port 22
- keep SSH port <NEW_PORT> open
- validate the final SSH config before applying it

You MUST then use:
  ssh -p <NEW_PORT> <ADMIN_USER>@<SERVER_IP_OR_HOSTNAME>

Do you want to finalize the SSH transition now? [y/N]:
```

If the user confirms:

1. OPS reconciles both `/etc/ssh/sshd_config` and `sshd_config.d/*.conf` so stale `Port` directives do not keep port 22 active.
2. The managed hardening include is rewritten so only the locked SSH port remains.
3. `sshd -t` must pass before OPS applies the change.
4. SSH is reloaded/restarted successfully.
5. OPS writes the final intended SSH state, then reconciles UFW and fail2ban from that OPS state for the final single-port policy.
6. Only after SSH, UFW, and fail2ban all apply cleanly does OPS clear transition state and report success.

If validation, SSH apply, UFW reconcile, or fail2ban apply fails:

- OPS must keep the transition state recorded and must **not** report success.
- OPS must restore the previous SSH/firewall/fail2ban state before exiting failure.
- The operator should fix the issue first, then re-run finalization.

If the user declines:

- Both ports remain open and OPS should show a clear security warning on dashboard and in relevant menus.

### 7. Typical next steps after wizard

After reboot and first stable login on the new port, users typically:

1. Use **CLIProxyAPI Management** menu (option 5) to:
   - Install CLIProxyAPI, link a domain, manage API keys.
2. Use **Node.js Services** menu to:
   - Create or import Node.js apps.
2. Use **Domains & Nginx** menu to:
   - Add domains.
   - Attach them to Node/PHP apps.
3. Use **SSL Management** menu to:
   - Issue certificates via Certbot for those domains.
4. Use **PHP / PHP‑FPM** menu to:
   - Verify PHP versions and adjust pools.
5. Use **Database** menu to:
   - Create databases and users.
6. Use **Codex CLI integration** menu to:
   - Install and configure Codex CLI for AI‑assisted operations.

This document should be kept in sync with any installer or wizard behaviour changes.


---

### Nginx installation — official mainline repo

During `install_nginx()`, OPS automatically:

1. Calls `_nginx_add_official_repo()` to add the nginx.org mainline apt repo and pin it above the distro repo.
2. Installs `nginx` (will be >= 1.24 mainline, not Ubuntu's 1.18.0).
3. Calls `_nginx_apply_global_tuning()` to apply ALL hardening directives:
   - `worker_rlimit_nofile 65535` (main context)
   - `multi_accept on` + `use epoll` (events block)
   - `keepalive_timeout 30s`, `client_max_body_size 10m`, client timeouts
   - Full gzip config (`gzip_types`, `gzip_comp_level 6`, etc.)
   - `open_file_cache`, `limit_req_zone`, `limit_conn_zone`
   - Security headers (CSP, X-Frame-Options, X-Content-Type-Options, Referrer-Policy, Permissions-Policy, X-XSS-Protection) -- HSTS is applied per SSL vhost only, not globally (RFC 6797 §7.2)
   - Custom `log_format main_ext` with upstream response timing
4. Calls `create_default_deny()` and `_nginx_disable_packaged_default_site()`.
5. Runs `nginx -t && systemctl reload-or-restart nginx`.

If Nginx >= 1.24 is already installed, `_nginx_add_official_repo()` is a no-op.
