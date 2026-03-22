
## OPS Install & First‑Run Flow

This document describes the exact end‑to‑end flow from a fresh VPS to a production‑ready stack managed by OPS. It is the primary reference for how installers and wizards should behave.

> Target: Ubuntu 22.04 / 24.04, systemd, Nginx + Node + multi‑PHP + MariaDB (default).

### 1. One‑line installer

The recommended entrypoint for users:

```bash
curl -sO https://raw.githubusercontent.com/daotaolaixe-quangthang/ops-script/main/install/ops-install.sh \
  && bash ops-install.sh
```

> **Installer URL (chốt)**: `https://raw.githubusercontent.com/daotaolaixe-quangthang/ops-script/main/install/ops-install.sh`

The `ops-install.sh` script **must**:

1. Verify OS is supported (Ubuntu 22.04/24.04).
2. Gather basic VPS info (RAM, CPU cores, disk).
3. Show a short summary and confirmation prompt.



Installer asks for:

1. **New SSH port** (with default suggestion, e.g. `2222`):
   - Validate port is not in use and > 1024.
   - Add new port to `sshd_config` but keep port 22 temporarily.
   - Open both ports in firewall.

2. **Non‑root admin user** (e.g. `opsadmin` with a suggested default):
   - Create user, set password (or SSH key), add to `sudo`.
   - This user is used for daily SSH and to run Node/PM2 services.

3. **Capacity estimation**:
   - Based on RAM and CPU, compute:
     - Recommended number of active Node/9router sites.
     - Rough concurrent user range per site.
   - Store this in `/etc/ops/capacity.conf` (or JSON) for later display.

After this step, installer:

- Clones or extracts OPS core to `/opt/ops`.
- Runs `/opt/ops/bin/ops-setup.sh`.

### 3. `ops-setup.sh` responsibilities

`ops-setup.sh` is idempotent and:

1. Creates symlinks:
   - `/usr/local/bin/ops` → `/opt/ops/bin/ops`
   - `/usr/local/bin/ops-dashboard` → `/opt/ops/bin/ops-dashboard`
2. Wires login hook:
   - When an interactive shell starts for the admin user, run `ops-dashboard`.
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
   - Install Nginx from the distribution repositories.
   - Apply tuning based on RAM/CPU via `PERF-TUNING.md`:
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

6. **Database (MariaDB (default))**
   - Ask whether to install a database server now.
   - If yes:
     - Install MySQL or MariaDB (as default).
     - Run secure setup (root password, disable anonymous users, etc.).
     - Apply tuning from `PERF-TUNING.md`.

7. **Logging & basic monitoring**
   - Ensure `logrotate` rules for Nginx, PHP‑FPM, and Node/PM2 logs.
   - Optionally install simple monitoring tools (e.g. `htop`).

8. **Summary & verification**
   - Run checks to confirm:
     - Nginx active.
     - Node and PM2 installed.
     - PHP‑FPM versions installed (if selected).
     - DB server running (if installed).
   - Show a summary screen with next recommended actions:
     - Use Node.js / 9router menus to create services.
     - Use Domain & SSL menus to attach domains.

The wizard should be re‑runnable; subsequent runs should detect existing state and ask before changing configs.

### 6. SSH port finalisation and reboot

After the stack and menus are confirmed to be working, OPS offers a security hardening step to finish the SSH transition:

Prompt example:

```text
Everything looks ready.

We will now:
- close SSH port 22
- keep SSH port <NEW_PORT> open
- reboot the server

After reboot, you MUST use:
  ssh -p <NEW_PORT> <ADMIN_USER>@<SERVER_IP_OR_HOSTNAME>

Do you want to apply these changes and reboot now? [y/N]:
```

If the user confirms:

1. UFW (or other firewall) is updated to **deny port 22** and allow only the new SSH port.
2. `sshd_config` is updated to remove port 22 and keep only the new port.
3. A reboot is triggered.

If the user declines:

- Both ports remain open and OPS should show a clear security warning on dashboard and in relevant menus.

### 7. Typical next steps after wizard

After reboot and first stable login on the new port, users typically:

1. Use **Node.js Services** menu to:
   - Create or import Node.js apps.
   - Deploy and manage 9router.
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

