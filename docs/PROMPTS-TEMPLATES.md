## Prompt Templates for OPS AI Work

This document provides ready-to-use prompt templates for humans to instruct AI agents when working on OPS. The goal is to ensure agents always have the right context and follow project rules.

When using these templates, replace placeholders like `<TASK>`, `<MODULE>`, `<FILE>` with your specifics.

---

### 1. General "implement a feature" prompt

Use this when you want an AI agent to implement or extend a feature in OPS.

```text
Repo: E:\2WEBApp\ops-script

Goal:
- <Short description of the feature, e.g. "Add support in Node.js Services menu to restart all services at once.">

Before writing any code, read and respect:
- docs/README.md
- docs/ARCHITECTURE.md
- docs/FLOW-INSTALL.md
- docs/MENU-REFERENCE.md
- docs/SECURITY-RULES.md
- docs/PERF-TUNING.md
- docs/CODE-SKELETON-GUIDE.md   ← read before writing any module
- rules/PROJECT-RULES.md
- rules/BASH-STYLE.md

Requirements:
- Implement the feature according to existing architecture and menus.
- Keep code idempotent and safe; follow Bash style and security rules.
- Each config action must have: backup → validate → apply → verify → rollback note.
- Never print secrets to terminal or logs.
- Update docs if behaviour or menu structure changes.
```

---

### 2. Implementing or updating the installer

Use this when working on `install/ops-install.sh` or related installer logic.

```text
Repo: E:\2WEBApp\ops-script

Read first (mandatory):
- docs/FLOW-INSTALL.md       ← primary spec for installer flow
- docs/SECURITY-RULES.md sections 1, 4
- docs/ARCHITECTURE.md
- docs/CODE-SKELETON-GUIDE.md
- rules/BASH-STYLE.md

Task: Implement or update install/ops-install.sh

Installer URL (fixed): https://raw.githubusercontent.com/daotaolaixe-quangthang/ops-script/main/install/ops-install.sh

Key requirements:
- Match flow in docs/FLOW-INSTALL.md exactly:
  - OS detection for Ubuntu 22.04/24.04 (fail clearly if wrong).
  - SSH port change with transition (keep port 22 until final confirmation).
  - Non-root admin user creation (sudo, SSH-capable).
  - Capacity estimation (RAM/CPU → OPS_TIER S/M/L) saved to /etc/ops/capacity.conf.
  - Clone OPS core to /opt/ops and run ops-setup.sh.
- Keep installer small and auditable.
- Do not duplicate logic that belongs in core/ or modules/.
- Do not weaken security defaults from SECURITY-RULES.md.
```

---

### 3. Implementing or updating a module

Use this when working on a specific module.

```text
Repo: E:\2WEBApp\ops-script

Read first (mandatory):
- docs/ARCHITECTURE.md
- docs/CODE-SKELETON-GUIDE.md   ← read before writing any module
- docs/MENU-REFERENCE.md        ← section for this module
- docs/SECURITY-RULES.md
- docs/PERF-TUNING.md           ← if module tunes services
- rules/BASH-STYLE.md

Task: Implement or update modules/<MODULE>.sh

Module purpose:
- <Describe purpose, e.g. "Manage Node.js services via PM2.">

Requirements:
- Expose clear functions for each menu item.
- Use helpers from core/env.sh, core/ui.sh, core/utils.sh, core/system.sh.
- All operations must be idempotent and safe to re-run.
- Validate configs before reload (e.g. nginx -t, bash -n).
- Every state change must write to /etc/ops/<module>.conf.

If you change menu labels or behaviour, update docs/MENU-REFERENCE.md.
```

---

### 4. Phase 1 — Task-specific prompts

#### P1-00: Scaffold file structure

```text
Repo: E:\2WEBApp\ops-script

Read first:
- docs/ARCHITECTURE.md (section 2: Directory layout, section 3.1: state files)
- docs/CODE-SKELETON-GUIDE.md
- rules/BASH-STYLE.md

Task P1-00: Create full Phase 1 skeleton file structure.

Requirements:
- Create all files listed in docs/ARCHITECTURE.md section 2.
- Each .sh file must have: shebang, header comment, set -euo pipefail.
- bin/ops: menu dispatcher stub (returns "not implemented" per item).
- core/env.sh: detect RAM_MB, CPU_CORES, OS version, ADMIN_USER;
  compute OPS_TIER (S=<1500MB, M=1500-5000MB, L=>5000MB).
- core/ui.sh: print_section, print_ok, print_warn, print_error,
  prompt_confirm, prompt_input, prompt_secret.
- core/utils.sh: write_file, backup_file, log_info, log_warn, log_error,
  ops_conf_set, ops_conf_get.
- core/system.sh: apt_install, apt_update, service_enable, service_restart,
  ufw_allow, ufw_deny.
- All templates/ from ARCHITECTURE.md section 2 as empty placeholder files.
- Do NOT implement real logic yet — skeletons and stubs only.

Verify: bash -n on all .sh files must return no errors.
```

---

#### P1-01 + P1-02: Installer + Core Setup

```text
Repo: E:\2WEBApp\ops-script

Read first (mandatory):
- docs/FLOW-INSTALL.md        ← read entirely, primary spec
- docs/SECURITY-RULES.md sections 1, 4
- docs/CODE-SKELETON-GUIDE.md
- rules/BASH-STYLE.md

Task P1-01: Implement install/ops-install.sh
Task P1-02: Implement bin/ops-setup.sh + bin/ops-dashboard + login hook

Installer URL (fixed):
  https://raw.githubusercontent.com/daotaolaixe-quangthang/ops-script/main/install/ops-install.sh

Specific requirements:

1. ops-install.sh:
   - Verify Ubuntu 22.04/24.04 (exit 1 with clear message if wrong).
   - Detect RAM_MB/CPU_CORES → compute OPS_TIER → save /etc/ops/capacity.conf.
   - Ask for new SSH port (>1024, not in use); add to sshd_config; open BOTH port 22
     + new port in UFW.
   - Create non-root admin user, set password, add to sudo.
   - Clone repo to /opt/ops, run ops-setup.sh.
   - Print clearly: "After reboot use: ssh -p <PORT> <USER>@<IP>"

2. ops-setup.sh (must be idempotent):
   - Create symlinks: /usr/local/bin/ops → /opt/ops/bin/ops
   - Create symlink: /usr/local/bin/ops-dashboard → /opt/ops/bin/ops-dashboard
   - Write login hook to ~/.bash_profile of admin user:
     Guard: [[ $- == *i* ]] && [[ -t 0 ]] && [[ -n "$SSH_TTY" ]]
   - Create /etc/ops/ops.conf: OPS_VERSION, OPS_INSTALL_DATE, ADMIN_USER, OPS_DIR.

3. ops-dashboard:
   - Display: hostname, IP, uptime, RAM/CPU/disk usage, OPS_TIER, key service status.
   - Prompt: "Press 1 to open OPS menu, Enter to skip".
   - Guard: only run in interactive SSH session (not scp/rsync/non-interactive).

Security: Do NOT create any secret files in this phase.
```

---

#### P1-04: Security module

```text
Repo: E:\2WEBApp\ops-script

Read first:
- docs/SECURITY-RULES.md      ← entire file
- docs/KNOWN-RISKS-PATTERNS.md patterns #2, #14
- docs/MENU-REFERENCE.md (main menu Production Setup Wizard)
- docs/CODE-SKELETON-GUIDE.md

Task P1-04: Implement modules/security.sh

Requirements:
1. SSH hardening: disable root login, configure new port, PasswordAuthentication handling.
2. UFW setup: allow only SSH port(s) + 80 + 443. DENY everything else.
   Never open port 20128 (9router) — this is a hard constraint.
3. fail2ban: install, enable for sshd, create /etc/fail2ban/jail.local.
4. Close port 22 flow (offered after setup verified):
   - Remove port 22 from UFW
   - Reload UFW
   - Print: "You MUST now use: ssh -p <NEW_PORT> <ADMIN_USER>@<IP>"

Verify: sshd -t, ufw status, fail2ban-client status.
Rollback: open port 22 first, then revert sshd_config, restart sshd.
```

---

#### P1-05: Domains & Nginx module

```text
Repo: E:\2WEBApp\ops-script

Read first (mandatory):
- docs/MENU-REFERENCE.md section 4 (Domains & Nginx) — web root + remove domain flow
- docs/MENU-REFERENCE.md section 5 (SSL Management)
- docs/SECURITY-RULES.md sections 2, 3
- docs/PERF-TUNING.md section 2 (Nginx)
- docs/NINE-ROUTER-SPEC.md section 2.5 (Nginx vhost with rate limiting)
- docs/CODE-SKELETON-GUIDE.md

Task P1-05: Implement modules/nginx.sh

Requirements:

1. install_nginx: install + tune nginx.conf per OPS_TIER (worker_processes, connections).
2. create_default_deny: server block returning 444 for unknown hosts (ALWAYS present).
3. add_domain <domain> <type>:
   - Types: node | php | static
   - Node: proxy_pass to port (ask operator which port/PM2 service)
   - PHP: fastcgi to /run/php/php<ver>-fpm-<site>.sock (ask PHP version)
   - Static/PHP: create /var/www/<domain>, chown $ADMIN_USER:www-data, chmod 755
   - Render from template, nginx -t, symlink enable, reload
   - Save /etc/ops/domains/<domain>.conf
   - Do NOT issue SSL here

4. remove_domain <domain> (chot flow):
   - Confirm prompt
   - Delete: sites-enabled/<domain>, sites-available/<domain>
   - Delete: /etc/ops/domains/<domain>.conf
   - nginx -t && reload
   - Print: "Web root /var/www/<domain> NOT deleted — remove manually if needed."
   - Never delete web root. Never delete SSL certs.

5. issue_ssl <domain>: certbot --nginx -d <domain> via snap install.
   After cert issued for 9router domain: sed AUTH_COOKIE_SECURE=false→true in
   /opt/9router/.env and pm2 restart nine-router.

Verify: nginx -t, curl -I https://<domain>, certbot certificates.
```

---

#### P1-06: 9router module

```text
Repo: E:\2WEBApp\ops-script

Read first (mandatory — entire files):
- docs/NINE-ROUTER-SPEC.md    ← source of truth for all 9router implementation
- docs/SECURITY-RULES.md sections 2, 3
- docs/KNOWN-RISKS-PATTERNS.md patterns #13, #14
- docs/CODE-SKELETON-GUIDE.md

Task P1-06: Implement modules/nine-router.sh

Git repo (fixed URL — do NOT use any other):
  https://github.com/daotaolaixe-quangthang/9routervps

Functions to implement (follow NINE-ROUTER-SPEC exactly):

1. install_nine_router:
   - Clone to /opt/9router
   - npm install && npm run build
   - prompt_secret "Enter 9router dashboard initial password"
     → save to /etc/ops/.nine-router-password (chmod 600, chown $ADMIN_USER)
   - Generate: JWT_SECRET=$(openssl rand -hex 32), API_KEY_SECRET, MACHINE_ID_SALT
   - Create /opt/9router/.env (chmod 600) with all vars from NINE-ROUTER-SPEC section 2.3
   - mkdir -p /var/lib/9router; chown $ADMIN_USER; chmod 750
   - Register PM2 process nine-router; pm2 save; pm2 startup

2. link_nine_router_domain <domain>:
   - Render nine-router.vhost.conf.tpl (proxy to 127.0.0.1:20128, buffering off,
     rate limiting 30r/min with burst=10, proxy_connect_timeout 10s,
     proxy_read_timeout 120s, proxy_send_timeout 60s)
   - Add limit_req_zone to nginx.conf http block if not present
   - nginx -t && enable && reload
   - If domain already has SSL cert: set AUTH_COOKIE_SECURE=true in /opt/9router/.env
     then pm2 restart nine-router
   - Save /etc/ops/nine-router.conf NINE_ROUTER_DOMAIN

3. toggle_require_api_key <on|off>:
   - sed -i 's/REQUIRE_API_KEY=.*/REQUIRE_API_KEY=true|false/' /opt/9router/.env
   - pm2 restart nine-router
   - ops_conf_set nine-router.conf NINE_ROUTER_REQUIRE_API_KEY "yes"|"no"

4. verify_nine_router:
   - pm2 status | grep nine-router → must be online
   - curl -s http://127.0.0.1:20128/v1/models → must return JSON
   - ufw status | grep 20128 → MUST be empty (port not open)

Security invariants:
- HOSTNAME=0.0.0.0 in .env is EXPECTED (Next.js requirement)
- UFW must NOT open port 20128 — verify every time
- All secrets auto-generated, never hard-coded
```

---

#### P1-07: PHP module

```text
Repo: E:\2WEBApp\ops-script

Read first:
- docs/PHASE-01-IMPLEMENTATION-SPEC.md section P1-07
- docs/MENU-REFERENCE.md section 7
- docs/PERF-TUNING.md section 3 (PHP-FPM per tier)
- docs/CODE-SKELETON-GUIDE.md

Task P1-07: Implement modules/php.sh

PHP install method (fixed): ppa:ondrej/php
PHP versions: 7.4, 8.1, 8.2, 8.3

PHP pool naming convention (fixed):
  Pool file: /etc/php/<ver>/fpm/pool.d/<site-name>.conf
  Socket:    /run/php/php<ver>-fpm-<site-name>.sock

Functions:
1. install_php_version <ver>: add ppa, apt update, install php<ver>-{cli,fpm,common,
   mysql,curl,gd,intl,mbstring,opcache,xml,zip,soap,bcmath}
2. configure_php_pool <site> <ver>: write pool config with socket path above
3. set_php_cli_default <ver>: update-alternatives --set php /usr/bin/php<ver>
4. tune_php <ver>: set memory_limit, opcache settings per OPS_TIER
5. Save /etc/ops/php-sites/<site>.conf with SITE_PHP_VERSION, SITE_FPM_SOCKET

Verify: php -v, php-fpm<ver> -t, service php<ver>-fpm status.
```

---

#### P1-08: Database module

```text
Repo: E:\2WEBApp\ops-script

Read first:
- docs/PHASE-01-IMPLEMENTATION-SPEC.md section P1-08
- docs/PERF-TUNING.md section 4 (MariaDB — bind-address=127.0.0.1)
- docs/SECURITY-RULES.md section 7
- docs/CODE-SKELETON-GUIDE.md

Task P1-08: Implement modules/database.sh — MariaDB as default engine

Functions:

1. install_mariadb:
   - apt install mariadb-server mariadb-client
   - Set bind-address=127.0.0.1 in /etc/mysql/mariadb.conf.d/50-server.cnf (REQUIRED)
   - Secure setup (equivalent to mysql_secure_installation):
     DELETE FROM mysql.user WHERE User='';
     DELETE FROM mysql.user WHERE User='root' AND Host != 'localhost';
     DROP DATABASE IF EXISTS test;
     FLUSH PRIVILEGES;
   - Generate root password (openssl rand -base64 24)
     → save to /etc/ops/.db-root-password (chmod 600, chown $ADMIN_USER)
     → NEVER print to terminal
   - Save /etc/ops/database.conf: DB_ENGINE="mariadb", DB_VERSION, DB_ROOT_PASSWORD_FILE

2. tune_mariadb: apply innodb_buffer_pool_size, max_connections, tmp_table_size
   per OPS_TIER from PERF-TUNING.md section 4

3. create_db_user <db_name> <db_user>:
   - Generate random password
   - CREATE DATABASE, CREATE USER, GRANT minimal privileges
   - Print credentials once (or save to /etc/ops/db-credentials/<db>.conf 0600)

Verify: mysqladmin status, mysql -u root --password=$(cat /etc/ops/.db-root-password) -e "SHOW DATABASES;"
```

---

#### P1-09 + P1-10: Codex CLI module

```text
Repo: E:\2WEBApp\ops-script

Read first (mandatory — entire files):
- docs/CODEX-CLI-SPEC.md    ← source of truth for all Codex CLI implementation
- docs/MENU-REFERENCE.md section 9
- docs/SECURITY-RULES.md section 9
- docs/CODE-SKELETON-GUIDE.md

Task: Implement modules/codex-cli.sh

Follow docs/CODEX-CLI-SPEC.md exactly:
- Section 2: install via npm install -g @openai/codex
- Section 3.1: configure with 9router (recommended)
- Section 3.2: configure with OpenAI API key
- Section 3.3: ChatGPT OAuth flow (OPS only installs, user authenticates manually)
- Section 4: all 4 menu actions with exact code from spec
- Section 5: runtime state paths (config.toml 0600, .codex-api-key 0600)
- Section 8: security rules (non-negotiable)

Secret files:
- /etc/ops/.codex-api-key (0600) — API key
- ~/.codex/config.toml (0600) — endpoint + model config
- /etc/ops/codex-cli.conf (640) — OPS state (mode, endpoint, version)
```

---

### 5. Verify prompt (use after completing any task)

```text
Task P1-XX has been implemented.

Verify against docs/PHASE-01-IMPLEMENTATION-SPEC.md section P1-XX:

1. Run: bash -n on all new/modified .sh files.
2. Check all verify steps in the spec are covered in the implementation.
3. Check security invariants from docs/SECURITY-RULES.md are not violated.
4. Check no secrets are printed to terminal or written to logs:
   grep -r "password\|api_key\|token\|secret" modules/<module>.sh | grep -v "FILE\|Path\|_file\|prompt"
5. Check all /etc/ops/*.conf state writes are present.
6. Report: files changed, state files created, verify commands to run.
```

---

### 6. Adding or changing performance tuning

```text
Repo: E:\2WEBApp\ops-script

Task: Adjust performance tuning for <component> (Nginx / PHP-FPM / MariaDB).

Steps:
1. First update docs/PERF-TUNING.md:
   - Which parameters change per tier (S: <1500MB / M: 1500-5000MB / L: >5000MB RAM).
   - Rationale for new values.
2. Then update the relevant module to implement those values.

Constraints:
- Do not oversubscribe memory for small VPS (Tier S).
- Keep defaults conservative; stability over micro-optimization.
- MariaDB must always keep bind-address=127.0.0.1 regardless of tier.
```

---

### 7. Bugfix or refactor

```text
Repo: E:\2WEBApp\ops-script

Read first:
- docs/BUG-TRIAGE-INDEX.md   ← identify impact layer
- docs/SOURCE-TO-RUNTIME-TRACE.md  ← trace to runtime state
- docs/KNOWN-RISKS-PATTERNS.md     ← check for known patterns

Task: Fix bug / refactor — <describe bug/goal>

Context:
- Current behaviour: <describe>
- Expected behaviour: <describe>
- Relevant files: <list>

Constraints:
- Preserve all security and performance rules.
- Do not change menu labels unless explicitly required.
- Keep changes minimal and focused.
- Update docs if the change affects documented behaviour.
- Rollback must be possible without data loss.
```

---

### 8. Documentation-only updates

```text
Repo: E:\2WEBApp\ops-script

Task: Update documentation in docs/ to better explain <TOPIC>.

Constraints:
- Do not change any code.
- Keep language concise and practical.
- Ensure docs stay consistent with ARCHITECTURE.md, MENU-REFERENCE.md,
  SECURITY-RULES.md, and PHASE-01-IMPLEMENTATION-SPEC.md.
- Cross-check: if you update MENU-REFERENCE, verify SOURCE-TO-RUNTIME-TRACE
  and RUNTIME-ARTEFACT-INVENTORY are still consistent.
```

---

These templates are starting points. Always include specific task IDs from `PHASE-0X-IMPLEMENTATION-SPEC.md` so the AI agent works within the approved scope. When in doubt, add more context — links to specific file sections, prior decisions, or acceptance criteria.
