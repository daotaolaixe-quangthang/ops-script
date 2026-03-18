#!/usr/bin/env bash
# ============================================================
# ops/modules/monitoring.sh
# Purpose:  System overview, service status, quick logs — P1-11
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# Called by bin/ops via menu dispatch.
# Do NOT add set -euo pipefail here — inherited from bin/ops.
#
# Design (PHASE-01-IMPLEMENTATION-SPEC.md §P1-11):
#   1. system overview (CPU/RAM/disk/uptime/load)
#   2. service status (nginx, mariadb, php-fpm, pm2)
#   3. quick logs: Nginx, PHP-FPM, PM2 Node services, DB
#   4. log path bootstrap /var/log/ops/ops.log
#
# Security: never print tokens, passwords, or API keys.

# ── Public menu entry ─────────────────────────────────────────
menu_monitoring() {
    while true; do
        print_section "System & Monitoring"
        echo "  1) System overview"
        echo "  2) Service status"
        echo "  3) Quick logs — Nginx"
        echo "  4) Quick logs — PHP-FPM"
        echo "  5) Quick logs — PM2 / Node apps"
        echo "  6) Quick logs — Database (MariaDB)"
        echo "  7) OPS log (ops.log)"
        echo "  8) Login history"
        echo "  9) Disk usage"
        echo "  10) Setup Telegram notifications"
        echo "  11) Test Telegram notification"
        echo "  0) Back"
        echo ""
        read -r -p "Select: " choice
        case "$choice" in
            1)  monitoring_system_overview  ;;
            2)  monitoring_service_status   ;;
            3)  monitoring_logs_nginx       ;;
            4)  monitoring_logs_php         ;;
            5)  monitoring_logs_pm2         ;;
            6)  monitoring_logs_db          ;;
            7)  monitoring_show_ops_log     ;;
            8)  monitoring_login_history    ;;
            9)  monitoring_disk_usage       ;;
            10) monitoring_setup_telegram   ;;
            11) monitoring_test_telegram    ;;
            0)  return                      ;;
            *)  print_warn "Invalid option" ;;
        esac
    done
}

# ── Task 1: System overview ───────────────────────────────────
monitoring_system_overview() {
    print_section "System Overview"

    # Basic identity
    local hostname os_id os_ver kernel uptime_str
    hostname=$(hostname -f 2>/dev/null || hostname)
    os_id="${OS_ID:-$(grep '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')}"
    os_ver="${OS_VERSION_ID:-$(grep '^VERSION_ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')}"
    kernel=$(uname -r)
    uptime_str=$(uptime -p 2>/dev/null || uptime)

    printf "  %-18s %s\n" "Hostname:"   "$hostname"
    printf "  %-18s %s %s\n" "OS:"      "$os_id" "$os_ver"
    printf "  %-18s %s\n" "Kernel:"     "$kernel"
    printf "  %-18s %s\n" "Uptime:"     "$uptime_str"
    printf "  %-18s %s\n" "OPS Tier:"   "${OPS_TIER:-?}"

    echo ""

    # CPU
    local cpu_cores load_1 load_5 load_15
    cpu_cores="${CPU_CORES:-$(nproc)}"
    read -r load_1 load_5 load_15 _ < /proc/loadavg
    printf "  %-18s %s cores  (load: %s %s %s)\n" "CPU:" "$cpu_cores" "$load_1" "$load_5" "$load_15"

    # RAM
    local total_mb used_mb free_mb
    total_mb=$(awk '/MemTotal/  { printf "%d", $2/1024 }' /proc/meminfo)
    free_mb=$(awk '/MemAvailable/ { printf "%d", $2/1024 }' /proc/meminfo)
    used_mb=$(( total_mb - free_mb ))
    printf "  %-18s %s MB total  /  %s MB used  /  %s MB free\n" "RAM:" "$total_mb" "$used_mb" "$free_mb"

    # Swap
    local swap_total swap_free
    swap_total=$(awk '/SwapTotal/ { printf "%d", $2/1024 }' /proc/meminfo)
    swap_free=$(awk '/SwapFree/  { printf "%d", $2/1024 }' /proc/meminfo)
    if (( swap_total > 0 )); then
        printf "  %-18s %s MB total  /  %s MB free\n" "Swap:" "$swap_total" "$swap_free"
    fi

    # Disk
    echo ""
    echo "  --- Disk (/) ---"
    df -h --output=size,used,avail,pcent,target / 2>/dev/null | tail -n +2 \
        | awk '{ printf "  %-18s size=%-8s used=%-8s avail=%-8s %s\n", "Disk:", $1, $2, $3, $4 }'

    echo ""

    # Top 5 procs by CPU
    echo "  --- Top processes (CPU) ---"
    ps aux --sort=-%cpu 2>/dev/null | awk 'NR==1 || NR<=6 { printf "  %-10s %-6s %-6s %s\n", $1, $3, $4, $11 }'

    log_info "monitoring_system_overview: done"
}

# ── Task 2: Service status ────────────────────────────────────
monitoring_service_status() {
    print_section "Service Status"

    _mon_svc_line() {
        local svc="$1"
        local label="${2:-$svc}"
        if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
            if service_active "$svc" 2>/dev/null; then
                print_ok "$label: active"
            else
                print_warn "$label: inactive"
            fi
        else
            print_warn "$label: not installed"
        fi
    }

    # Nginx
    _mon_svc_line nginx Nginx

    # Node / PM2
    if command -v pm2 >/dev/null 2>&1; then
        local online_count
        online_count=$(pm2 jlist 2>/dev/null | python3 -c "
import sys,json
try:
    procs = json.load(sys.stdin)
    online = sum(1 for p in procs if p.get('pm2_env',{}).get('status')=='online')
    print(online)
except:
    print('?')
" 2>/dev/null || echo "?")
        print_ok "PM2: ${online_count} process(es) online"
    else
        print_warn "PM2: not installed"
    fi

    # PHP-FPM versions
    local php_ver fpm_svc
    for php_ver in 7.4 8.1 8.2 8.3; do
        fpm_svc="php${php_ver}-fpm"
        if systemctl list-unit-files 2>/dev/null | grep -q "^${fpm_svc}\.service"; then
            _mon_svc_line "$fpm_svc" "PHP ${php_ver}-FPM"
        fi
    done

    # MariaDB / MySQL
    if systemctl list-unit-files 2>/dev/null | grep -q '^mariadb\.service'; then
        _mon_svc_line mariadb MariaDB
    elif systemctl list-unit-files 2>/dev/null | grep -q '^mysql\.service'; then
        _mon_svc_line mysql MySQL
    else
        print_warn "Database: not installed"
    fi

    # fail2ban
    _mon_svc_line fail2ban fail2ban

    # UFW
    if command -v ufw >/dev/null 2>&1; then
        local ufw_status
        ufw_status=$(ufw status 2>/dev/null | head -n1)
        print_ok "UFW: ${ufw_status}"
    else
        print_warn "UFW: not installed"
    fi

    echo ""
    log_info "monitoring_service_status: done"
}

# ── Task 3: Quick logs — Nginx ────────────────────────────────
monitoring_logs_nginx() {
    print_section "Nginx Logs"
    local lines=50
    prompt_input "Lines to show" "50"
    [[ "$REPLY" =~ ^[0-9]+$ ]] && lines="$REPLY"

    local access_log="/var/log/nginx/access.log"
    local error_log="/var/log/nginx/error.log"

    echo ""
    echo "  ── Access log (last ${lines} lines) ──────────────"
    if [[ -f "$access_log" ]]; then
        tail -n "$lines" "$access_log"
    else
        print_warn "Not found: $access_log"
    fi

    echo ""
    echo "  ── Error log (last ${lines} lines) ───────────────"
    if [[ -f "$error_log" ]]; then
        tail -n "$lines" "$error_log"
    else
        print_warn "Not found: $error_log"
    fi
    log_info "monitoring_logs_nginx: done"
}

# ── Task 3: Quick logs — PHP-FPM ─────────────────────────────
monitoring_logs_php() {
    print_section "PHP-FPM Logs"

    local lines=50
    prompt_input "Lines to show" "50"
    [[ "$REPLY" =~ ^[0-9]+$ ]] && lines="$REPLY"

    local php_ver log_path found=0
    for php_ver in 8.3 8.2 8.1 7.4; do
        log_path="/var/log/php${php_ver}-fpm.log"
        if [[ -f "$log_path" ]]; then
            echo ""
            echo "  ── PHP ${php_ver}-FPM (last ${lines} lines) ──────"
            tail -n "$lines" "$log_path"
            found=1
        fi
    done

    if [[ "$found" -eq 0 ]]; then
        print_warn "No PHP-FPM log files found in /var/log/phpX.Y-fpm.log"
        print_warn "Check with: journalctl -u php8.2-fpm -n 50"
    fi
    log_info "monitoring_logs_php: done"
}

# ── Task 3: Quick logs — PM2 / Node ──────────────────────────
monitoring_logs_pm2() {
    print_section "PM2 / Node App Logs"

    if ! command -v pm2 >/dev/null 2>&1; then
        print_warn "PM2 not installed."
        return 1
    fi

    local lines=50
    prompt_input "Lines to show" "50"
    [[ "$REPLY" =~ ^[0-9]+$ ]] && lines="$REPLY"

    echo ""
    echo "  ── PM2 combined log (last ${lines} lines) ─────────"
    pm2 logs --lines "$lines" --nostream 2>/dev/null || \
        print_warn "No PM2 logs available (no apps running?)"

    log_info "monitoring_logs_pm2: done"
}

# ── Task 3: Quick logs — Database ────────────────────────────
monitoring_logs_db() {
    print_section "Database Logs (MariaDB)"

    local lines=50
    prompt_input "Lines to show" "50"
    [[ "$REPLY" =~ ^[0-9]+$ ]] && lines="$REPLY"

    local log_paths=(
        "/var/log/mysql/error.log"
        "/var/log/mariadb/mariadb.log"
        "/var/lib/mysql/$(hostname).err"
    )

    local log_path found=0
    for log_path in "${log_paths[@]}"; do
        if [[ -f "$log_path" ]]; then
            echo ""
            echo "  ── ${log_path} (last ${lines} lines) ──"
            tail -n "$lines" "$log_path"
            found=1
            break
        fi
    done

    if [[ "$found" -eq 0 ]]; then
        echo ""
        print_warn "No MariaDB log file found. Trying journalctl:"
        journalctl -u mariadb -n "$lines" --no-pager 2>/dev/null || \
            print_warn "journalctl -u mariadb: no output"
    fi
    log_info "monitoring_logs_db: done"
}

# ── Task 4: OPS log ───────────────────────────────────────────
monitoring_show_ops_log() {
    print_section "OPS Log"

    # Bootstrap log path if not exists
    local log_file="${OPS_LOG_FILE:-/var/log/ops/ops.log}"
    local log_dir
    log_dir=$(dirname "$log_file")
    if [[ ! -d "$log_dir" ]]; then
        mkdir -p "$log_dir" 2>/dev/null || true
        log_info "Bootstrapped log directory: $log_dir"
    fi

    local lines=50
    prompt_input "Lines to show" "50"
    [[ "$REPLY" =~ ^[0-9]+$ ]] && lines="$REPLY"

    if [[ -f "$log_file" ]]; then
        tail -n "$lines" "$log_file"
    else
        print_warn "Log file not found: ${log_file}"
        print_warn "Log will be created on next OPS action."
    fi
}

# ── Login history ─────────────────────────────────────────────
monitoring_login_history() {
    print_section "Login History"
    local lines=20
    prompt_input "Lines to show" "20"
    [[ "$REPLY" =~ ^[0-9]+$ ]] && lines="$REPLY"

    echo "  ── last (successful logins) ───────────────────"
    last -n "$lines" 2>/dev/null || print_warn "last: command not available"

    echo ""
    echo "  ── lastb (failed login attempts) ──────────────"
    lastb -n "$lines" 2>/dev/null || print_warn "lastb: command not available or no failures logged"

    echo ""
    echo "  ── Recent SSH auth (journalctl) ───────────────"
    journalctl -u ssh -u sshd -n 20 --no-pager 2>/dev/null \
        | grep -i 'accepted\|failed\|invalid\|disconnect' \
        | tail -n "$lines" \
        || print_warn "journalctl SSH: no output"

    log_info "monitoring_login_history: done"
}

# ── Disk usage ────────────────────────────────────────────────
monitoring_disk_usage() {
    print_section "Disk Usage"
    df -h --output=source,fstype,size,used,avail,pcent,target 2>/dev/null | head -n 25
    echo ""
    echo "  ── Top 10 largest dirs in /var/www ────────────"
    du -sh /var/www/*/ 2>/dev/null | sort -rh | head -n 10 || true
    echo ""
    echo "  ── /var/log usage ──────────────────────────────"
    du -sh /var/log/ 2>/dev/null || true
    log_info "monitoring_disk_usage: done"
}

# ── Telegram notifications ────────────────────────────────────
# Secret stored at /etc/ops/.telegram-bot-token (0600) — never printed.

_monitoring_telegram_token_file() { echo "${OPS_CONFIG_DIR:-/etc/ops}/.telegram-bot-token"; }

monitoring_setup_telegram() {
    print_section "Setup Telegram Notifications"

    prompt_secret "Telegram Bot Token (input hidden)"
    local bot_token="${SECRET:-}"
    unset SECRET

    if [[ -z "$bot_token" ]]; then
        print_error "Bot token cannot be empty."
        return 1
    fi

    prompt_input "Telegram Chat ID (e.g. -100123456789)"
    local chat_id="$REPLY"
    if [[ -z "$chat_id" ]]; then
        print_error "Chat ID cannot be empty."
        return 1
    fi

    # Store token in secret file (0600) — never in conf
    local token_file
    token_file="$(_monitoring_telegram_token_file)"
    ensure_parent_dir "$token_file"
    printf '%s\n' "$bot_token" > "$token_file"
    chmod 600 "$token_file"
    chown "${ADMIN_USER:-root}:${ADMIN_USER:-root}" "$token_file" 2>/dev/null || true
    log_info "Telegram bot token saved to $token_file (0600)"

    # Store non-secret config
    ops_conf_set "ops.conf" "TELEGRAM_ENABLED"  "yes"
    ops_conf_set "ops.conf" "TELEGRAM_CHAT_ID"  "$chat_id"

    print_ok "Telegram configured. Token at $token_file (0600). Chat ID: $chat_id"
    print_warn "Run 'Test Telegram notification' to verify."
    log_info "monitoring_setup_telegram: done"
}

monitoring_test_telegram() {
    print_section "Test Telegram Notification"

    local token_file
    token_file="$(_monitoring_telegram_token_file)"

    if [[ ! -f "$token_file" ]]; then
        print_error "Telegram not configured. Run 'Setup Telegram notifications' first."
        return 1
    fi

    local bot_token chat_id
    bot_token="$(cat "$token_file")"
    chat_id="$(ops_conf_get "ops.conf" "TELEGRAM_CHAT_ID" 2>/dev/null || true)"

    if [[ -z "$chat_id" ]]; then
        print_error "Telegram chat ID not set. Run 'Setup Telegram notifications' first."
        return 1
    fi

    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)
    local message="✅ OPS test notification from ${hostname} at $(date '+%Y-%m-%d %H:%M:%S')"

    log_info "Sending Telegram test notification..."
    local response http_code
    # -w "%{http_code}" outputs status at end; -o /dev/null suppresses body to avoid token in logs
    http_code=$(curl -s -o /tmp/tg_response.json -w "%{http_code}" \
        -X POST "https://api.telegram.org/bot${bot_token}/sendMessage" \
        -d "chat_id=${chat_id}" \
        --data-urlencode "text=${message}" 2>/dev/null || echo "000")

    if [[ "$http_code" == "200" ]]; then
        print_ok "Telegram test message sent successfully (HTTP 200)."
    else
        print_error "Telegram test failed (HTTP ${http_code}). Check bot token and chat ID."
        cat /tmp/tg_response.json 2>/dev/null | python3 -m json.tool 2>/dev/null || true
    fi
    rm -f /tmp/tg_response.json
    # NOTE: bot_token variable is NOT logged — only http_code is logged
    log_info "monitoring_test_telegram: http_code=$http_code"
}
