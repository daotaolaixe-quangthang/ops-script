#!/usr/bin/env bash
# ============================================================
# ops/modules/checks.sh
# Purpose:  Scheduled health checks, alerts, thresholds — P2-03
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# Called by bin/ops (sourced). Individual check functions are also
# called from /etc/cron.d/ops-checks via the ops-check wrapper.
# Do NOT add set -euo pipefail here — inherited from bin/ops.
#
# Exit codes for check functions:
#   0 = ok/pass   1 = warn   2 = fail/critical

# ── Thresholds (operator can override in /etc/ops/checks.conf) ─
CHECKS_CPU_WARN_PERCENT="${CHECKS_CPU_WARN_PERCENT:-90}"
CHECKS_RAM_WARN_PERCENT="${CHECKS_RAM_WARN_PERCENT:-85}"
CHECKS_DISK_WARN_PERCENT="${CHECKS_DISK_WARN_PERCENT:-85}"
CHECKS_SSL_WARN_DAYS="${CHECKS_SSL_WARN_DAYS:-14}"
CHECKS_DOMAIN_WARN_DAYS="${CHECKS_DOMAIN_WARN_DAYS:-30}"
CHECKS_COOLDOWN_SECONDS="${CHECKS_COOLDOWN_SECONDS:-3600}"   # 1 hour
CHECKS_CRON_FILE="/etc/cron.d/ops-checks"
CHECKS_CONF_DIR="${OPS_CONFIG_DIR:-/etc/ops}/checks"

# Load overrides if present
[[ -f "${OPS_CONFIG_DIR:-/etc/ops}/checks.conf" ]] && \
    source "${OPS_CONFIG_DIR:-/etc/ops}/checks.conf" 2>/dev/null || true

# ── Cooldown helper ───────────────────────────────────────────
# Returns 0 (ok to alert) if no recent cooldown file, 1 (suppress) if within window.
_checks_cooldown_ok() {
    local type="$1"
    local id="${2:-default}"
    # Sanitise id for use in filename
    local safe_id
    safe_id=$(printf '%s' "$id" | tr -cs 'a-zA-Z0-9._-' '_')
    local cooldown_file="/tmp/ops-alert-${type}-${safe_id}.cooldown"

    if [[ -f "$cooldown_file" ]]; then
        local last_alert now elapsed
        last_alert=$(cat "$cooldown_file" 2>/dev/null || echo 0)
        now=$(date +%s)
        elapsed=$(( now - last_alert ))
        if (( elapsed < CHECKS_COOLDOWN_SECONDS )); then
            return 1  # suppress — still in cooldown
        fi
    fi

    # Update cooldown timestamp
    date +%s > "$cooldown_file" 2>/dev/null || true
    return 0  # ok to alert
}

# ── Telegram dispatch helper ───────────────────────────────────
_checks_send_telegram() {
    local message="$1"
    local token_file="${OPS_CONFIG_DIR:-/etc/ops}/.telegram-bot-token"
    local chat_id

    # Respect TELEGRAM_ENABLED flag
    chat_id=$(ops_conf_get "ops.conf" "TELEGRAM_CHAT_ID" 2>/dev/null || true)
    local tg_enabled
    tg_enabled=$(ops_conf_get "ops.conf" "TELEGRAM_ENABLED" 2>/dev/null || echo "no")

    if [[ "$tg_enabled" != "yes" || -z "$chat_id" || ! -f "$token_file" ]]; then
        log_info "_checks_send_telegram: Telegram not configured, skipping notification."
        return 0
    fi

    local bot_token
    bot_token=$(cat "$token_file" 2>/dev/null || true)
    [[ -z "$bot_token" ]] && return 0

    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)
    local full_msg="⚠️ OPS Alert [${hostname}]

${message}"

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "https://api.telegram.org/bot${bot_token}/sendMessage" \
        -d "chat_id=${chat_id}" \
        --data-urlencode "text=${full_msg}" 2>/dev/null || echo "000")

    log_info "_checks_send_telegram: http_code=${http_code}"
    # bot_token intentionally NOT logged
}

# ── check_resources ───────────────────────────────────────────
check_resources() {
    local rc=0
    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)

    # CPU load
    local load_1 cpu_cores load_pct
    read -r load_1 _ < /proc/loadavg
    cpu_cores=$(nproc)
    # multiply by 100 for integer comparison (load_1 * 100 / cores)
    load_pct=$(awk "BEGIN { printf \"%d\", (${load_1} / ${cpu_cores}) * 100 }")
    if (( load_pct >= CHECKS_CPU_WARN_PERCENT )); then
        local msg="CPU load high: ${load_1} (${load_pct}% of ${cpu_cores} cores)"
        log_warn "check_resources: $msg"
        if _checks_cooldown_ok "cpu" "host"; then
            _checks_send_telegram "CPU: $msg"
        fi
        rc=1
    fi

    # RAM usage
    local total_kb avail_kb used_pct
    total_kb=$(awk '/MemTotal/    { print $2 }' /proc/meminfo)
    avail_kb=$(awk '/MemAvailable/ { print $2 }' /proc/meminfo)
    used_pct=$(awk "BEGIN { printf \"%d\", (1 - ${avail_kb}/${total_kb}) * 100 }")
    if (( used_pct >= CHECKS_RAM_WARN_PERCENT )); then
        local msg="RAM usage high: ${used_pct}% used"
        log_warn "check_resources: $msg"
        if _checks_cooldown_ok "ram" "host"; then
            _checks_send_telegram "RAM: $msg"
        fi
        [[ "$rc" -lt 1 ]] && rc=1
    fi

    # Disk usage — all real mounts
    local mount pct_raw pct
    while IFS= read -r line; do
        pct_raw=$(printf '%s' "$line" | awk '{print $5}' | tr -d '%')
        mount=$(printf '%s' "$line" | awk '{print $6}')
        pct="${pct_raw:-0}"
        if (( pct >= CHECKS_DISK_WARN_PERCENT )); then
            local msg="Disk ${mount} usage high: ${pct}%"
            log_warn "check_resources: $msg"
            if _checks_cooldown_ok "disk" "$mount"; then
                _checks_send_telegram "Disk: $msg"
            fi
            [[ "$rc" -lt 1 ]] && rc=1
        fi
    done < <(df -h --output=source,fstype,size,used,avail,pcent,target 2>/dev/null \
             | tail -n +2 \
             | grep -Ev '^(tmpfs|devtmpfs|udev|overlay|none)' \
             | awk '{print $0}')

    return "$rc"
}

# ── check_uptime ──────────────────────────────────────────────
# Usage: check_uptime [domain]   — if no arg, checks all domains in /etc/ops/domains/
check_uptime() {
    local target_domain="${1:-}"
    local domains=()
    local rc=0

    if [[ -n "$target_domain" ]]; then
        domains=("$target_domain")
    else
        # Discover all OPS-managed domains
        local f
        for f in "${OPS_CONFIG_DIR:-/etc/ops}/domains/"*.conf; do
            [[ -f "$f" ]] || continue
            local d
            d=$(grep '^DOMAIN=' "$f" | head -1 | cut -d= -f2- | tr -d '"')
            [[ -n "$d" ]] && domains+=("$d")
        done
    fi

    if [[ "${#domains[@]}" -eq 0 ]]; then
        log_info "check_uptime: no domains to check"
        return 0
    fi

    local domain http_code
    for domain in "${domains[@]}"; do
        # Try HTTPS first, fall back to HTTP
        http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
            --max-time 10 --connect-timeout 5 \
            --location \
            "https://${domain}/" 2>/dev/null || echo "000")
        if [[ "$http_code" == "000" ]]; then
            http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
                --max-time 10 --connect-timeout 5 \
                --location \
                "http://${domain}/" 2>/dev/null || echo "000")
        fi

        local http_int="${http_code//[^0-9]/}"
        http_int="${http_int:-0}"

        if (( http_int >= 200 && http_int < 400 )); then
            log_info "check_uptime: ${domain} OK (HTTP ${http_code})"
        else
            local msg="Site DOWN: ${domain} — HTTP ${http_code}"
            log_warn "check_uptime: $msg"
            if _checks_cooldown_ok "uptime" "$domain"; then
                _checks_send_telegram "$msg"
            fi
            rc=2
        fi
    done
    return "$rc"
}

# ── check_ssl_expiry ──────────────────────────────────────────
check_ssl_expiry() {
    local target_domain="${1:-}"
    local rc=0

    # Gather domains to check
    local domains=()
    if [[ -n "$target_domain" ]]; then
        domains=("$target_domain")
    elif command -v certbot >/dev/null 2>&1; then
        local cert_output
        cert_output=$(certbot certificates 2>/dev/null || true)
        while IFS= read -r line; do
            case "$line" in
                *"Domains:"*)
                    local d
                    d=$(printf '%s' "$line" | sed -E 's/.*Domains: //' | awk '{print $1}')
                    [[ -n "$d" ]] && domains+=("$d")
                    ;;
            esac
        done <<< "$cert_output"
    fi

    if [[ "${#domains[@]}" -eq 0 ]]; then
        log_info "check_ssl_expiry: no domains to check"
        return 0
    fi

    local domain
    for domain in "${domains[@]}"; do
        # Query live cert expiry via openssl
        local expiry_str days_left
        expiry_str=$(echo | timeout 5 openssl s_client -connect "${domain}:443" \
            -servername "$domain" 2>/dev/null \
            | openssl x509 -noout -enddate 2>/dev/null \
            | cut -d= -f2 || true)
        if [[ -z "$expiry_str" ]]; then
            log_info "check_ssl_expiry: could not fetch cert for ${domain}"
            continue
        fi

        local expiry_epoch now_epoch
        expiry_epoch=$(date -d "$expiry_str" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

        if (( days_left <= 0 )); then
            local msg="SSL EXPIRED: ${domain}"
            log_warn "check_ssl_expiry: $msg"
            if _checks_cooldown_ok "ssl" "$domain"; then
                _checks_send_telegram "$msg"
            fi
            rc=2
        elif (( days_left <= CHECKS_SSL_WARN_DAYS )); then
            local msg="SSL expiring soon: ${domain} — ${days_left} days left"
            log_warn "check_ssl_expiry: $msg"
            if _checks_cooldown_ok "ssl" "$domain"; then
                _checks_send_telegram "$msg"
            fi
            [[ "$rc" -lt 1 ]] && rc=1
        else
            log_info "check_ssl_expiry: ${domain} OK (${days_left} days)"
        fi
    done
    return "$rc"
}

# ── check_domain_expiry ───────────────────────────────────────
check_domain_expiry() {
    local target_domain="${1:-}"
    local rc=0

    if ! command -v whois >/dev/null 2>&1; then
        log_warn "check_domain_expiry: whois not installed, skipping"
        return 0
    fi

    local domains=()
    if [[ -n "$target_domain" ]]; then
        domains=("$target_domain")
    else
        local f d
        for f in "${OPS_CONFIG_DIR:-/etc/ops}/domains/"*.conf; do
            [[ -f "$f" ]] || continue
            d=$(grep '^DOMAIN=' "$f" | head -1 | cut -d= -f2- | tr -d '"')
            [[ -n "$d" ]] && domains+=("$d")
        done
    fi

    local domain
    for domain in "${domains[@]}"; do
        # Extract root domain (strip subdomains past first two levels)
        local root_domain
        root_domain=$(printf '%s' "$domain" | awk -F. '{
            n=NF; if (n>=2) print $(n-1)"."$n; else print $0
        }')

        local expiry_line days_left
        expiry_line=$(whois "$root_domain" 2>/dev/null \
            | grep -iE '(expiry|expir|paid-till|renewal).*[0-9]{4}' \
            | head -n1 || true)

        if [[ -z "$expiry_line" ]]; then
            log_info "check_domain_expiry: ${domain} — could not determine expiry"
            continue
        fi

        # Try to extract a date from the line
        local expiry_date
        expiry_date=$(printf '%s' "$expiry_line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 \
                   || printf '%s' "$expiry_line" | grep -oE '[0-9]{2}\.[0-9]{2}\.[0-9]{4}' | head -1 \
                   || true)

        if [[ -z "$expiry_date" ]]; then
            log_info "check_domain_expiry: ${domain} — unparseable expiry line"
            continue
        fi

        local expiry_epoch now_epoch
        expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

        if (( days_left <= CHECKS_DOMAIN_WARN_DAYS )); then
            local msg="Domain expiring: ${domain} — ${days_left} days left"
            log_warn "check_domain_expiry: $msg"
            if _checks_cooldown_ok "domain" "$domain"; then
                _checks_send_telegram "$msg"
            fi
            [[ "$rc" -lt 1 ]] && rc=1
        else
            log_info "check_domain_expiry: ${domain} OK (${days_left} days)"
        fi
    done
    return "$rc"
}

# ── check_security_scan ───────────────────────────────────────
check_security_scan() {
    local rc=0
    if command -v lynis >/dev/null 2>&1; then
        log_info "check_security_scan: running lynis quick scan"
        local lynis_out
        lynis_out=$(lynis audit system --quick --no-colors 2>&1 | tail -20 || true)
        local hardening_index
        hardening_index=$(printf '%s' "$lynis_out" | grep -oE 'Hardening index.*[0-9]+' | grep -oE '[0-9]+' | tail -1 || true)
        if [[ -n "$hardening_index" && "$hardening_index" -lt 60 ]]; then
            local msg="Security scan: hardening index ${hardening_index}/100 (below 60)"
            log_warn "check_security_scan: $msg"
            if _checks_cooldown_ok "security" "host"; then
                _checks_send_telegram "$msg"
            fi
            rc=1
        else
            log_info "check_security_scan: lynis done (index: ${hardening_index:-?})"
        fi
    else
        # Basic fallback checks
        local warn_msgs=()
        # Root SSH login enabled?
        if grep -qE '^\s*PermitRootLogin\s+yes' /etc/ssh/sshd_config 2>/dev/null; then
            warn_msgs+=("PermitRootLogin is enabled in sshd_config")
        fi
        # Password auth enabled?
        if grep -qE '^\s*PasswordAuthentication\s+yes' /etc/ssh/sshd_config 2>/dev/null; then
            warn_msgs+=("PasswordAuthentication is enabled in sshd_config")
        fi
        # UFW inactive?
        if command -v ufw >/dev/null 2>&1; then
            local ufw_st
            ufw_st=$(ufw status 2>/dev/null | head -1)
            if [[ "$ufw_st" != *"active"* ]]; then
                warn_msgs+=("UFW firewall is not active")
            fi
        fi
        if [[ "${#warn_msgs[@]}" -gt 0 ]]; then
            local combined
            combined=$(printf '• %s\n' "${warn_msgs[@]}")
            log_warn "check_security_scan: basic issues found"
            if _checks_cooldown_ok "security" "host"; then
                _checks_send_telegram "Security findings:\n${combined}"
            fi
            rc=1
        else
            log_info "check_security_scan: basic check ok"
        fi
    fi
    return "$rc"
}

# ── Cron install/remove ───────────────────────────────────────
checks_install_cron() {
    print_section "Install Scheduled Checks (cron)"

    local ops_bin="/usr/local/bin/ops"
    if [[ ! -x "$ops_bin" ]]; then
        ops_bin="${OPS_ROOT}/bin/ops"
    fi

    cat > "$CHECKS_CRON_FILE" <<EOF
# OPS scheduled health checks — managed by OPS, do not edit manually.
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Resource check every 5 minutes
*/5 * * * * root  ${OPS_ROOT}/bin/ops-check resources  >> /var/log/ops/checks.log 2>&1
# Uptime check every 5 minutes
*/5 * * * * root  ${OPS_ROOT}/bin/ops-check uptime     >> /var/log/ops/checks.log 2>&1
# SSL expiry daily at 06:00
0 6 * * *   root  ${OPS_ROOT}/bin/ops-check ssl        >> /var/log/ops/checks.log 2>&1
# Domain expiry daily at 07:00
0 7 * * *   root  ${OPS_ROOT}/bin/ops-check domain     >> /var/log/ops/checks.log 2>&1
# Security scan weekly on Sunday at 03:00
0 3 * * 0   root  ${OPS_ROOT}/bin/ops-check security   >> /var/log/ops/checks.log 2>&1
EOF
    chmod 644 "$CHECKS_CRON_FILE"
    print_ok "Scheduled checks installed: $CHECKS_CRON_FILE"
    print_warn "Logs → /var/log/ops/checks.log"

    # Ensure log file exists
    local log_dir="/var/log/ops"
    mkdir -p "$log_dir" 2>/dev/null || true
    touch "$log_dir/checks.log" 2>/dev/null || true

    # Also create the ops-check dispatcher script
    _checks_write_dispatcher
    log_info "checks_install_cron: done"
}

checks_remove_cron() {
    print_section "Remove Scheduled Checks"
    if [[ -f "$CHECKS_CRON_FILE" ]]; then
        rm -f "$CHECKS_CRON_FILE"
        print_ok "Removed: $CHECKS_CRON_FILE"
    else
        print_warn "No cron file found at $CHECKS_CRON_FILE"
    fi
    log_info "checks_remove_cron: done"
}

_checks_write_dispatcher() {
    # Write a small dispatcher script that ops-check cron entries call
    local dispatcher="${OPS_ROOT}/bin/ops-check"
    cat > "$dispatcher" <<'DISPATCHER_EOF'
#!/usr/bin/env bash
# ops-check — OPS scheduled check dispatcher
# Called by /etc/cron.d/ops-checks
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_PATH" ]]; do
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
    SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
    [[ "$SCRIPT_PATH" != /* ]] && SCRIPT_PATH="${SCRIPT_DIR}/${SCRIPT_PATH}"
done
OPS_ROOT="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"

source "$OPS_ROOT/core/env.sh"
source "$OPS_ROOT/core/utils.sh"
source "$OPS_ROOT/core/ui.sh"
source "$OPS_ROOT/core/system.sh"
source "$OPS_ROOT/modules/monitoring.sh"
source "$OPS_ROOT/modules/checks.sh"
source "$OPS_ROOT/modules/verify.sh"
source "$OPS_ROOT/modules/backup.sh"

CHECK_TYPE="${1:-}"
case "$CHECK_TYPE" in
    resources) check_resources  ;;
    uptime)    check_uptime     ;;
    ssl)       check_ssl_expiry ;;
    domain)    check_domain_expiry ;;
    security)  check_security_scan ;;
    *)
        echo "Usage: ops-check <resources|uptime|ssl|domain|security>" >&2
        exit 1
        ;;
esac
DISPATCHER_EOF
    chmod 755 "$dispatcher"
    log_info "_checks_write_dispatcher: wrote ${dispatcher}"
}

# ── Checks menu ───────────────────────────────────────────────
menu_checks() {
    while true; do
        print_section "Notifications & Scheduled Checks"
        echo "  1) Install scheduled checks (cron)"
        echo "  2) Remove scheduled checks"
        echo "  3) Run resource check now"
        echo "  4) Run uptime check now"
        echo "  5) Run SSL expiry check now"
        echo "  6) Run domain expiry check now"
        echo "  7) Run security scan now"
        echo "  8) Show check log"
        echo "  0) Back"
        echo ""
        read -r -p "Select: " choice
        case "$choice" in
            1) checks_install_cron      ;;
            2) checks_remove_cron       ;;
            3) check_resources          ;;
            4) check_uptime             ;;
            5) check_ssl_expiry         ;;
            6) check_domain_expiry      ;;
            7) check_security_scan      ;;
            8) _checks_show_log         ;;
            0) return                   ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}

_checks_show_log() {
    print_section "Check Log"
    local log_file="/var/log/ops/checks.log"
    local lines=50
    prompt_input "Lines to show" "50"
    [[ "$REPLY" =~ ^[0-9]+$ ]] && lines="$REPLY"
    if [[ -f "$log_file" ]]; then
        tail -n "$lines" "$log_file"
    else
        print_warn "Log not found: $log_file (run install_cron first)"
    fi
}
