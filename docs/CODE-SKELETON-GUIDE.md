## OPS Code Skeleton Guide

Mục tiêu: cung cấp skeleton thực tế (chạy được) cho AI Agent khi bắt đầu viết scripts.
Đây là **starting point** — implement theo đúng pattern này, không tự bịa convention mới.

---

## A. Coding Spine (áp dụng cho mọi file)

```bash
#!/usr/bin/env bash
# ============================================================
# ops/<path/to/file>.sh
# Purpose: <one-line description>
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
set -euo pipefail
IFS=$'\n\t'

# Resolve OPS_ROOT to absolute path (works regardless of cwd)
OPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source core helpers (always in this order)
# shellcheck source=core/env.sh
source "$OPS_ROOT/core/env.sh"
# shellcheck source=core/utils.sh
source "$OPS_ROOT/core/utils.sh"
# shellcheck source=core/ui.sh
source "$OPS_ROOT/core/ui.sh"
# shellcheck source=core/system.sh
source "$OPS_ROOT/core/system.sh"
```

---

## B. `core/env.sh` — Skeleton

```bash
#!/usr/bin/env bash
# core/env.sh — Environment detection and global constants
# Source this file; do not execute directly.
set -euo pipefail

# ── Runtime paths ────────────────────────────────────────────
export OPS_ROOT="${OPS_ROOT:-/opt/ops}"
export OPS_CONFIG_DIR="/etc/ops"
export OPS_LOG_DIR="/var/log/ops"
export OPS_LOG_FILE="$OPS_LOG_DIR/ops.log"

# ── OS detection ─────────────────────────────────────────────
detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION_ID="${VERSION_ID:-unknown}"
    else
        OS_ID="unknown"
        OS_VERSION_ID="unknown"
    fi
    export OS_ID OS_VERSION_ID
}

# ── Resource detection ───────────────────────────────────────
detect_resources() {
    RAM_MB=$(awk '/MemTotal/ { printf "%d", $2/1024 }' /proc/meminfo)
    CPU_CORES=$(nproc)
    DISK_GB=$(df -BG / | awk 'NR==2 { gsub("G","",$4); print $4 }')
    export RAM_MB CPU_CORES DISK_GB
}

# ── Tier mapping ─────────────────────────────────────────────
# S: <1500MB RAM  M: 1500-5000MB  L: >5000MB
detect_tier() {
    detect_resources
    if   (( RAM_MB < 1500 ));                      then OPS_TIER="S"
    elif (( RAM_MB >= 1500 && RAM_MB < 5000 ));    then OPS_TIER="M"
    else                                                 OPS_TIER="L"
    fi
    export OPS_TIER
}

# ── OPS config loader ────────────────────────────────────────
# Usage: ops_load_conf <filename>  (e.g. ops_load_conf ops.conf)
ops_load_conf() {
    local conf_file="$OPS_CONFIG_DIR/$1"
    [[ -f "$conf_file" ]] && source "$conf_file"
}

# ── OPS config writer ─────────────────────────────────────────
# Usage: ops_conf_set <filename> <KEY> <VALUE>
ops_conf_set() {
    local conf_file="$OPS_CONFIG_DIR/$1"
    local key="$2"
    local value="$3"
    ensure_dir "$OPS_CONFIG_DIR"
    if grep -q "^${key}=" "$conf_file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$conf_file"
    else
        echo "${key}=\"${value}\"" >> "$conf_file"
    fi
}

# Initialise on source
detect_os
detect_tier
```

---

## C. `core/utils.sh` — Skeleton

```bash
#!/usr/bin/env bash
# core/utils.sh — Safe file ops, logging, idempotence helpers

# ── Logging ──────────────────────────────────────────────────
log_info()  { echo "[INFO]  $(date '+%F %T') $*" | tee -a "$OPS_LOG_FILE"; }
log_warn()  { echo "[WARN]  $(date '+%F %T') $*" | tee -a "$OPS_LOG_FILE" >&2; }
log_error() { echo "[ERROR] $(date '+%F %T') $*" | tee -a "$OPS_LOG_FILE" >&2; }

# ── Directory helpers ─────────────────────────────────────────
ensure_dir() {
    local dir="$1"
    [[ -d "$dir" ]] || mkdir -p "$dir"
}

# ── File backup ───────────────────────────────────────────────
# Usage: backup_file /path/to/file
# Creates /path/to/file.bak.YYYYMMDD_HHMMSS
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local backup="${file}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$file" "$backup"
        log_info "Backup: $file → $backup"
        echo "$backup"   # return path for reference
    fi
}

# ── Atomic write ──────────────────────────────────────────────
# Write to temp then move — avoids partial writes corrupting config files
# Usage: write_file /path/to/file <<'EOF'
#        content
#        EOF
write_file() {
    local dest="$1"
    local tmp
    tmp=$(mktemp)
    cat > "$tmp"
    mv "$tmp" "$dest"
    log_info "Wrote: $dest"
}

# ── Template renderer ─────────────────────────────────────────
# Replaces {{VAR}} placeholders in a template file
# Usage: render_template /path/to/tpl VAR1=val1 VAR2=val2
render_template() {
    local tpl="$1"
    shift
    local content
    content=$(cat "$tpl")
    for kv in "$@"; do
        local key="${kv%%=*}"
        local val="${kv#*=}"
        content="${content//\{\{${key}\}\}/${val}}"
    done
    echo "$content"
}

# ── Idempotence check ─────────────────────────────────────────
# Usage: is_installed nginx && echo "already installed"
is_installed() { command -v "$1" &>/dev/null; }

# Usage: service_active nginx && echo "running"
service_active() { systemctl is-active --quiet "$1"; }
```

---

## D. `core/ui.sh` — Skeleton

```bash
#!/usr/bin/env bash
# core/ui.sh — Menu rendering, prompts, colours

# ── Colours ───────────────────────────────────────────────────
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
BLU='\033[0;34m'
CYN='\033[0;36m'
BLD='\033[1m'
RST='\033[0m'

print_section() {
    echo ""
    echo -e "${CYN}${BLD}━━━ $* ━━━${RST}"
    echo ""
}

print_ok()   { echo -e "  ${GRN}✓${RST} $*"; }
print_warn() { echo -e "  ${YLW}⚠${RST} $*"; }
print_err()  { echo -e "  ${RED}✗${RST} $*"; }

# ── Prompts ───────────────────────────────────────────────────
# Usage: prompt_text "Enter domain" "example.com" → stored in REPLY
prompt_text() {
    local label="$1"
    local default="${2:-}"
    if [[ -n "$default" ]]; then
        read -r -p "${label} [${default}]: " REPLY
        REPLY="${REPLY:-$default}"
    else
        read -r -p "${label}: " REPLY
    fi
}

# Usage: confirm "Apply changes?" → returns 0 (yes) or 1 (no)
confirm() {
    local label="${1:-Are you sure?}"
    read -r -p "${label} [y/N]: " ans
    [[ "${ans,,}" == "y" ]]
}

# Usage: prompt_secret "Enter password" → stored in SECRET (no echo)
prompt_secret() {
    local label="${1:-Enter secret}"
    read -r -s -p "${label}: " SECRET
    echo
}

# ── Menu helper ───────────────────────────────────────────────
show_menu() {
    local title="$1"
    shift
    print_section "$title"
    local i=1
    for item in "$@"; do
        echo -e "  ${BLD}${i})${RST} $item"
        (( i++ ))
    done
    echo -e "  ${BLD}0)${RST} Back / Exit"
    echo ""
    read -r -p "Select option: " MENU_CHOICE
}
```

---

## E. `core/system.sh` — Skeleton

```bash
#!/usr/bin/env bash
# core/system.sh — Wrappers for apt, systemctl, ufw

# ── apt wrappers ──────────────────────────────────────────────
apt_install() {
    log_info "apt install: $*"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
}

apt_update() {
    log_info "apt update"
    apt-get update -qq
}

# ── systemctl wrappers ────────────────────────────────────────
svc_enable()  { systemctl enable  "$1"; }
svc_start()   { systemctl start   "$1"; }
svc_restart() { systemctl restart "$1"; }
svc_reload()  { systemctl reload  "$1"; }
svc_status()  { systemctl status  "$1" --no-pager; }
svc_is_active() { systemctl is-active --quiet "$1"; }

# ── nginx helpers ─────────────────────────────────────────────
nginx_validate() {
    if ! nginx -t 2>/dev/null; then
        log_error "Nginx config test failed — aborting reload"
        return 1
    fi
}

nginx_reload() {
    nginx_validate || return 1
    systemctl reload nginx
    log_info "Nginx reloaded"
}

# ── ufw wrappers ──────────────────────────────────────────────
ufw_allow() { ufw allow "$1" comment "ops: $2"; }
ufw_deny()  { ufw deny  "$1"; }
ufw_status() { ufw status verbose; }
```

---

## F. `bin/ops` — Entry point skeleton

```bash
#!/usr/bin/env bash
# bin/ops — OPS main menu dispatcher
set -euo pipefail
IFS=$'\n\t'

OPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$OPS_ROOT/core/env.sh"
source "$OPS_ROOT/core/utils.sh"
source "$OPS_ROOT/core/ui.sh"
source "$OPS_ROOT/core/system.sh"

# Load all modules (sourced, not executed)
source "$OPS_ROOT/modules/setup-wizard.sh"
source "$OPS_ROOT/modules/security.sh"
source "$OPS_ROOT/modules/nginx.sh"
source "$OPS_ROOT/modules/node.sh"
source "$OPS_ROOT/modules/nine-router.sh"
source "$OPS_ROOT/modules/php.sh"
source "$OPS_ROOT/modules/database.sh"
source "$OPS_ROOT/modules/monitoring.sh"
source "$OPS_ROOT/modules/codex-cli.sh"

main_menu() {
    while true; do
        clear
        print_section "OPS — VPS Production Manager"
        echo "  1) Production Setup Wizard"
        echo "  2) Node.js Services"
        echo "  3) Domains & Nginx"
        echo "  4) SSL Management"
        echo "  5) 9router Management"
        echo "  6) PHP / PHP-FPM Management"
        echo "  7) Database Management"
        echo "  8) Codex CLI Integration"
        echo "  9) System & Monitoring"
        echo "  0) Exit"
        echo ""
        read -r -p "Select: " choice
        case "$choice" in
            1) menu_setup_wizard   ;;
            2) menu_node           ;;
            3) menu_nginx          ;;
            4) menu_ssl            ;;
            5) menu_nine_router    ;;
            6) menu_php            ;;
            7) menu_database       ;;
            8) menu_codex_cli      ;;
            9) menu_monitoring     ;;
            0) exit 0              ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}

main_menu
```

---

## G. Module skeleton pattern

```bash
#!/usr/bin/env bash
# modules/<name>.sh — <Module name>
# Called by bin/ops via menu dispatch
# Do NOT add set -euo pipefail here — inherited from bin/ops

# ── Public menu entry ─────────────────────────────────────────
menu_<name>() {
    while true; do
        print_section "<Module> Management"
        echo "  1) List ..."
        echo "  2) Create ..."
        echo "  3) ..."
        echo "  0) Back"
        read -r -p "Select: " choice
        case "$choice" in
            1) <name>_list    ;;
            2) <name>_create  ;;
            0) return         ;;
            *) print_warn "Invalid" ;;
        esac
    done
}

# ── Actions ───────────────────────────────────────────────────
<name>_list() {
    print_section "List ..."
    # implementation
}

<name>_create() {
    print_section "Create ..."
    # 1. Gather inputs
    # 2. Backup affected configs
    # 3. Apply change
    # 4. Validate (nginx -t, systemctl check, etc.)
    # 5. Reload/restart service
    # 6. Verify
    # 7. Log
}
```

---

## H. Convention cheat sheet

| Rule | Detail |
|---|---|
| Source order | `env.sh` → `utils.sh` → `ui.sh` → `system.sh` |
| Path variable | Always use `$OPS_ROOT`, `$OPS_CONFIG_DIR`, `$OPS_LOG_DIR` |
| Config write | Always via `ops_conf_set`, never `echo > /etc/ops/foo.conf` directly |
| File write | Always via `backup_file` + `write_file` for critical configs |
| Service reload | Always `nginx_validate` before `nginx_reload` |
| User input | `prompt_text`, `confirm`, `prompt_secret` from `ui.sh` |
| Logging | `log_info`, `log_warn`, `log_error` — never bare `echo` for ops |
| Idempotence | Check before creating: `is_installed`, `service_active`, `grep -q` |
| Secrets | Never inline; always file-based at `/etc/ops/.<name>-secret` with `0600` |
