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
CHECKS_DISK_CRIT_PERCENT="${CHECKS_DISK_CRIT_PERCENT:-95}"
CHECKS_SSL_WARN_DAYS="${CHECKS_SSL_WARN_DAYS:-14}"
CHECKS_DOMAIN_WARN_DAYS="${CHECKS_DOMAIN_WARN_DAYS:-30}"
CHECKS_COOLDOWN_SECONDS="${CHECKS_COOLDOWN_SECONDS:-3600}"   # 1 hour
CHECKS_PM2_RESTART_THRESHOLD="${CHECKS_PM2_RESTART_THRESHOLD:-3}"  # restarts per cycle
CHECKS_LOG_SPIKE_LINES="${CHECKS_LOG_SPIKE_LINES:-200}"            # new lines per 5-min cycle
CHECKS_DDOS_IP_REQS="${CHECKS_DDOS_IP_REQS:-100}"                 # req/IP in last 500 lines
CHECKS_DDOS_TOTAL_REQS="${CHECKS_DDOS_TOTAL_REQS:-500}"           # total reqs in last 500 lines
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
    local chat_id tg_enabled

    # Read from notifications.conf (chốt per ARCHITECTURE.md, RUNTIME-ARTEFACT-INVENTORY.md)
    chat_id=$(ops_conf_get "notifications.conf" "TELEGRAM_CHAT_ID" 2>/dev/null || true)
    tg_enabled=$(ops_conf_get "notifications.conf" "TELEGRAM_ENABLED" 2>/dev/null || echo "no")

    # Migration fallback: legacy installs stored these in ops.conf
    if [[ "$tg_enabled" != "yes" || -z "$chat_id" ]]; then
        local legacy_chat legacy_enabled
        legacy_chat=$(ops_conf_get "ops.conf" "TELEGRAM_CHAT_ID" 2>/dev/null || true)
        legacy_enabled=$(ops_conf_get "ops.conf" "TELEGRAM_ENABLED" 2>/dev/null || echo "no")
        if [[ "$legacy_enabled" == "yes" && -n "$legacy_chat" ]]; then
            chat_id="$legacy_chat"
            tg_enabled="$legacy_enabled"
            log_warn "_checks_send_telegram: Telegram config found in ops.conf (legacy) — re-run 'Setup Telegram notifications' to migrate."
        fi
    fi

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

# ── check_services ────────────────────────────────────────────
# Checks that all installed system services and PM2 processes are running.
# Alerts on service crash and PM2 restart loops.
check_services() {
    local rc=0
    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)

    # Fix-2: cache unit list — call systemctl list-unit-files once, reuse for all lookups.
    # Previously called 5-9 times per run (1 IPC round-trip each ≈ 10-30ms → 50-270ms overhead).
    local _unit_list
    _unit_list=$(systemctl list-unit-files 2>/dev/null || true)

    # ── Systemd services ──
    local svc label
    declare -A SVC_LABELS=(
        [nginx]="Nginx"
        [mariadb]="MariaDB"
        [mysql]="MySQL"
        [fail2ban]="fail2ban"
    )

    for svc in nginx mariadb mysql fail2ban; do
        # Only check if the unit file exists (service is installed)
        if ! printf '%s' "$_unit_list" | grep -q "^${svc}\.service"; then
            continue
        fi
        # mysql and mariadb are exclusive — skip mysql if mariadb is installed
        if [[ "$svc" == "mysql" ]] && printf '%s' "$_unit_list" | grep -q '^mariadb\.service'; then
            continue
        fi

        label="${SVC_LABELS[$svc]:-$svc}"
        if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
            local msg="Service DOWN: ${label} on ${hostname}"
            log_warn "check_services: $msg"
            if _checks_cooldown_ok "svc" "$svc"; then
                _checks_send_telegram "🔴 ${msg}"
            fi
            rc=2
        else
            log_info "check_services: ${label} OK"
        fi
    done

    # ── PHP-FPM versions ──
    local php_ver fpm_svc
    for php_ver in 7.4 8.1 8.2 8.3; do
        fpm_svc="php${php_ver}-fpm"
        if ! printf '%s' "$_unit_list" | grep -q "^${fpm_svc}\.service"; then
            continue
        fi
        if ! systemctl is-active --quiet "$fpm_svc" 2>/dev/null; then
            local msg="Service DOWN: PHP ${php_ver}-FPM on ${hostname}"
            log_warn "check_services: $msg"
            if _checks_cooldown_ok "svc" "$fpm_svc"; then
                _checks_send_telegram "🔴 ${msg}"
            fi
            rc=2
        else
            log_info "check_services: PHP ${php_ver}-FPM OK"
        fi
    done

    # ── MariaDB rescue-mode detection ──
    local db_rescue
    db_rescue=$(ps -eo args= 2>/dev/null | grep -E '[m]ariadbd?.*--skip-grant-tables|[m]ysqld.*--skip-grant-tables' || true)
    if [[ -n "$db_rescue" ]]; then
        local rescue_msg="DB SECURITY: MariaDB running with --skip-grant-tables on ${hostname}"
        log_warn "check_services: $rescue_msg"
        if _checks_cooldown_ok "svc" "mariadb-rescue"; then
            _checks_send_telegram "[WARN] ${rescue_msg} - stop rescue process immediately"
        fi
        [[ "$rc" -lt 2 ]] && rc=2
    fi

    # ── PM2 processes ──
    if command -v pm2 >/dev/null 2>&1; then
        # Fix-3 (partial): capture pm2 jlist once — reused by restart-loop check below.
        local pm2_json
        pm2_json=$(ops_pm2_jlist 2>/dev/null || echo '[]')

        # Parse with python3: check status and restart counter
        local pm2_issues
        pm2_issues=$(printf '%s' "$pm2_json" | python3 - <<'PYEOF' 2>/dev/null || true
import sys, json, os, time

try:
    procs = json.load(sys.stdin)
except Exception:
    sys.exit(0)

cache_dir = "/tmp"
restart_threshold = int(os.environ.get("CHECKS_PM2_RESTART_THRESHOLD", 3))
issues = []

for p in procs:
    name = p.get("name", "?")
    env  = p.get("pm2_env", {})
    status = env.get("status", "?")
    restarts = env.get("restart_time", 0)

    # Check if not online
    if status != "online":
        issues.append(f"PM2 process NOT online: {name} (status={status})")
        continue

    # Check restart loop: compare vs cached restart count
    cache_file = f"{cache_dir}/ops-pm2-restart-{name}.cache"
    prev_restarts = 0
    try:
        with open(cache_file) as f:
            prev_restarts = int(f.read().strip())
    except Exception:
        pass

    delta = restarts - prev_restarts
    if delta >= restart_threshold and prev_restarts > 0:
        issues.append(f"PM2 restart loop: {name} ({delta} restarts since last check)")

    # Write current restart count
    try:
        with open(cache_file, "w") as f:
            f.write(str(restarts))
    except Exception:
        pass

for i in issues:
    print(i)
PYEOF
)

        if [[ -n "$pm2_issues" ]]; then
            while IFS= read -r issue_line; do
                [[ -z "$issue_line" ]] && continue
                log_warn "check_services: $issue_line"
                # Use first word of issue as cooldown key
                local pm2_key
                pm2_key=$(printf '%s' "$issue_line" | awk '{print $NF}' | tr -cs 'a-zA-Z0-9._-' '_')
                if _checks_cooldown_ok "pm2" "$pm2_key"; then
                    _checks_send_telegram "⚠️ ${issue_line} [${hostname}]"
                fi
                [[ "$rc" -lt 2 ]] && rc=2
            done <<< "$pm2_issues"
        else
            log_info "check_services: PM2 OK"
        fi
    fi

    return "$rc"
}

# ── check_log_spikes ──────────────────────────────────────────
# Detects sudden log growth that signals crashes, floods, or runaway processes.
# Compares current log line count vs cached value; alerts if delta > threshold.
check_log_spikes() {
    local rc=0
    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)

    # Logs to monitor: label:path
    local -a LOG_TARGETS=(
        "Nginx-Error:/var/log/nginx/error.log"
        "PHP-FPM:/var/log/php8.3-fpm.log"
        "PHP-FPM:/var/log/php8.2-fpm.log"
        "PHP-FPM:/var/log/php8.1-fpm.log"
        "PHP-FPM:/var/log/php7.4-fpm.log"
        "MariaDB:/var/log/mysql/error.log"
        "MariaDB:/var/log/mariadb/mariadb.log"
    )

    local entry label log_path
    for entry in "${LOG_TARGETS[@]}"; do
        label="${entry%%:*}"
        log_path="${entry#*:}"
        [[ -f "$log_path" ]] || continue

        local current_lines prev_lines delta
        current_lines=$(wc -l < "$log_path" 2>/dev/null || echo 0)

        local safe_name
        safe_name=$(printf '%s' "$log_path" | tr '/' '_')
        local cache_file="/tmp/ops-logsize${safe_name}.cache"

        prev_lines=0
        [[ -f "$cache_file" ]] && prev_lines=$(cat "$cache_file" 2>/dev/null || echo 0)

        # Write current count for next cycle
        printf '%s\n' "$current_lines" > "$cache_file" 2>/dev/null || true

        delta=$(( current_lines - prev_lines ))
        if (( prev_lines > 0 && delta >= CHECKS_LOG_SPIKE_LINES )); then
            local msg="Log spike detected: ${label} grew by ${delta} lines (${log_path})"
            log_warn "check_log_spikes: $msg"
            if _checks_cooldown_ok "logspike" "$safe_name"; then
                _checks_send_telegram "📈 ${msg} on ${hostname}"
            fi
            rc=1
        else
            log_info "check_log_spikes: ${label} OK (lines=${current_lines}, delta=${delta})"
        fi
    done

    return "$rc"
}

# ── check_ddos ────────────────────────────────────────────────
# Lightweight DDoS / HTTP flood detection via Nginx access.log analysis.
# Uses pure awk/grep — no external tools required.
check_ddos() {
    local rc=0
    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)

    local access_log="/var/log/nginx/access.log"
    [[ -f "$access_log" ]] || { log_info "check_ddos: access log not found, skipping"; return 0; }

    # Analyse last 500 lines for IP frequency and total request count
    local analysis
    analysis=$(tail -500 "$access_log" 2>/dev/null | awk '
    {
        ip = $1
        total++
        count[ip]++
    }
    END {
        max_ip = ""; max_count = 0
        for (ip in count) {
            if (count[ip] > max_count) { max_count = count[ip]; max_ip = ip }
        }
        print total " " max_ip " " max_count
    }' 2>/dev/null || echo "0  0")

    local total_reqs top_ip top_ip_reqs
    # Use read to split on whitespace cleanly — avoids embedded newlines from awk
    read -r total_reqs top_ip top_ip_reqs <<< "$analysis"
    total_reqs="${total_reqs:-0}"
    top_ip="${top_ip:--}"
    top_ip_reqs="${top_ip_reqs:-0}"

    # Alert: single-IP flood
    if (( top_ip_reqs >= CHECKS_DDOS_IP_REQS )); then
        local msg="Possible DDoS: IP ${top_ip} made ${top_ip_reqs} requests in last 500 Nginx log entries"
        log_warn "check_ddos: $msg"
        if _checks_cooldown_ok "ddos" "ip_${top_ip}"; then
            _checks_send_telegram "🚨 ${msg} on ${hostname}"
        fi
        rc=2
    fi

    # Alert: total flood
    if (( total_reqs >= CHECKS_DDOS_TOTAL_REQS )); then
        local msg="Traffic flood: ${total_reqs} requests in last 500 Nginx log entries"
        log_warn "check_ddos: $msg"
        if _checks_cooldown_ok "ddos" "total"; then
            _checks_send_telegram "🚨 ${msg} on ${hostname}"
        fi
        [[ "$rc" -lt 1 ]] && rc=1
    fi

    if (( rc == 0 )); then
        log_info "check_ddos: OK (total=${total_reqs}, top_ip=${top_ip} [${top_ip_reqs} reqs])"
    fi

    return "$rc"
}

# ── check_health_digest ───────────────────────────────────────
# Sends a daily full-system snapshot to Telegram.
# Intended to run once per day (07:00 cron) so operators get a routine overview.
check_health_digest() {
    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)
    local ts
    ts=$(date '+%Y-%m-%d %H:%M')

    # ── Resources ──
    local load_1 load_5 load_15
    read -r load_1 load_5 load_15 _ < /proc/loadavg
    local cpu_cores
    cpu_cores=$(nproc)

    local total_mb avail_mb used_mb ram_pct
    total_mb=$(awk '/MemTotal/    { printf "%d", $2/1024 }' /proc/meminfo)
    avail_mb=$(awk '/MemAvailable/{ printf "%d", $2/1024 }' /proc/meminfo)
    used_mb=$(( total_mb - avail_mb ))
    ram_pct=$(awk "BEGIN { printf \"%d\", (${used_mb}/${total_mb})*100 }")

    local disk_pct disk_avail
    disk_pct=$(df / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
    disk_avail=$(df -h / 2>/dev/null | awk 'NR==2{print $4}')

    # ── Services ──
    local svc_lines=""
    for svc in nginx mariadb fail2ban; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                svc_lines+="  ✅ ${svc}\n"
            else
                svc_lines+="  🔴 ${svc} (DOWN)\n"
            fi
        fi
    done
    for php_ver in 8.3 8.2 8.1 7.4; do
        local fpm_svc="php${php_ver}-fpm"
        if systemctl list-unit-files 2>/dev/null | grep -q "^${fpm_svc}\.service"; then
            if systemctl is-active --quiet "$fpm_svc" 2>/dev/null; then
                svc_lines+="  ✅ PHP ${php_ver}-FPM\n"
            else
                svc_lines+="  🔴 PHP ${php_ver}-FPM (DOWN)\n"
            fi
            break  # only report first installed version
        fi
    done

    # ── PM2 ──
    # Keep a single pm2 jlist fetch, then reuse shared parsers for the summary.
    local pm2_summary="not installed"
    if command -v pm2 >/dev/null 2>&1; then
        local _pm2_json online_count total_count
        _pm2_json=$(ops_pm2_jlist 2>/dev/null || echo '[]')
        online_count=$(printf '%s' "$_pm2_json" | ops_pm2_online_count_from_json 2>/dev/null || echo "?")
        total_count=$(printf '%s' "$_pm2_json" | ops_pm2_total_count_from_json 2>/dev/null || echo "?")
        pm2_summary="${online_count}/${total_count} online"
    fi

    # ── Compose message ──
    local msg
    msg=$(printf '📊 Daily Health Digest\n'
          printf '🖥️ Host: %s\n' "$hostname"
          printf '🕐 Time: %s UTC\n' "$ts"
          printf '\n'
          printf '💻 CPU load: %s %s %s (%s cores)\n' "$load_1" "$load_5" "$load_15" "$cpu_cores"
          printf '🧠 RAM: %s/%s MB (%s%%)\n' "$used_mb" "$total_mb" "$ram_pct"
          printf '💾 Disk /: %s%% used (%s free)\n' "$disk_pct" "$disk_avail"
          printf '\n'
          printf '🔧 Services:\n'
          printf '%b' "$svc_lines"
          printf '🔄 PM2: %s\n' "$pm2_summary")

    # Send unconditionally (no cooldown — this IS the daily digest)
    local token_file="${OPS_CONFIG_DIR:-/etc/ops}/.telegram-bot-token"
    local chat_id tg_enabled
    chat_id=$(ops_conf_get "notifications.conf" "TELEGRAM_CHAT_ID" 2>/dev/null || true)
    tg_enabled=$(ops_conf_get "notifications.conf" "TELEGRAM_ENABLED" 2>/dev/null || echo "no")

    if [[ "$tg_enabled" != "yes" || -z "$chat_id" || ! -f "$token_file" ]]; then
        log_info "check_health_digest: Telegram not configured, skipping"
        return 0
    fi

    local bot_token http_code
    bot_token=$(cat "$token_file" 2>/dev/null || true)
    [[ -z "$bot_token" ]] && return 0

    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "https://api.telegram.org/bot${bot_token}/sendMessage" \
        -d "chat_id=${chat_id}" \
        --data-urlencode "text=${msg}" 2>/dev/null || echo "000")

    log_info "check_health_digest: sent digest, http_code=${http_code}"
    return 0
}

# ── Cron install/remove ───────────────────────────────────────
checks_install_cron() {
    print_section "Install Scheduled Checks (cron)"
    require_root || return 1

    # Fix-1: Consolidate all */5 checks into ONE cron job (ops-check 5min).
    # Previously 5 separate jobs fired simultaneously → 5× process spawn + source overhead
    # at the same minute. Now: 1 process, 1× source, checks run sequentially in one shell.
    cat > "$CHECKS_CRON_FILE" <<EOF
# OPS scheduled health checks — managed by OPS, do not edit manually.
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# ALL 5-minute checks in one process (resources, uptime, services, logspike, ddos)
# Fix-1: was 5 separate */5 cron jobs; consolidated → eliminates simultaneous CPU burst.
*/5 * * * * root  ${OPS_ROOT}/bin/ops-check 5min       >> /var/log/ops/checks.log 2>&1
# SSL expiry daily at 06:00
0 6 * * *   root  ${OPS_ROOT}/bin/ops-check ssl        >> /var/log/ops/checks.log 2>&1
# Domain expiry daily at 07:00
0 7 * * *   root  ${OPS_ROOT}/bin/ops-check domain     >> /var/log/ops/checks.log 2>&1
# Daily health digest at 07:05
5 7 * * *   root  ${OPS_ROOT}/bin/ops-check digest     >> /var/log/ops/checks.log 2>&1
# Security scan weekly on Sunday at 03:00
0 3 * * 0   root  ${OPS_ROOT}/bin/ops-check security   >> /var/log/ops/checks.log 2>&1
EOF
    chmod 644 "$CHECKS_CRON_FILE"
    print_ok "Scheduled checks installed: $CHECKS_CRON_FILE"
    print_warn "Logs → /var/log/ops/checks.log"

    # Ensure log file exists
    local log_dir="/var/log/ops"
    mkdir -p "$log_dir" 2>/dev/null || true
    chown root:root "$log_dir" 2>/dev/null || true
    chmod 755 "$log_dir" 2>/dev/null || true
    touch "$log_dir/checks.log" 2>/dev/null || true
    chown root:root "$log_dir/checks.log" 2>/dev/null || true
    chmod 640 "$log_dir/checks.log" 2>/dev/null || true

    # Also create the ops-check dispatcher script
    _checks_write_dispatcher

    # Fix-4: Install systemd OnFailure dropin units for instant crash alerting.
    # These fire the moment systemd detects a service failure — no 5-minute polling lag.
    _checks_install_systemd_dropins

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
    # Fix-4: also remove systemd OnFailure dropin units
    _checks_remove_systemd_dropins
    log_info "checks_remove_cron: done"
}

# Fix-4: Install systemd OnFailure dropin units.
# When any listed service crashes, systemd immediately runs ops-check alert-crash <svc>.
# This provides <1 second crash-to-Telegram latency vs the previous 5-minute polling gap.
_checks_install_systemd_dropins() {
    local dropin_svc="/etc/systemd/system/ops-alert-crash@.service"
    local dispatcher="${OPS_ROOT}/bin/ops-check"
    local svcs_to_watch=(nginx mariadb fail2ban)
    local php_ver
    for php_ver in 8.3 8.2 8.1 7.4; do
        local fpm_unit="php${php_ver}-fpm"
        systemctl list-unit-files 2>/dev/null | grep -q "^${fpm_unit}\.service" && svcs_to_watch+=("$fpm_unit")
    done

    # Write the generic crash alert service template.
    # ${OPS_ROOT}/bin/ops-check is canonical; /usr/local/bin/ops-check is only a compatibility symlink.
    cat > "$dropin_svc" <<DROPIN_EOF
[Unit]
Description=OPS crash alert for %i
DefaultDependencies=no
After=network.target

[Service]
Type=oneshot
ExecStart=${dispatcher} alert-crash %i
DROPIN_EOF
    chmod 644 "$dropin_svc"
    systemctl daemon-reload 2>/dev/null || true

    # Install OnFailure dropin for each watched service
    local svc installed=0
    for svc in "${svcs_to_watch[@]}"; do
        # Only install dropin if the service unit actually exists
        if ! systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
            continue
        fi
        local dropin_dir="/etc/systemd/system/${svc}.service.d"
        mkdir -p "$dropin_dir"
        cat > "${dropin_dir}/ops-alert.conf" <<DROPIN_CONF
[Unit]
OnFailure=ops-alert-crash@${svc}.service
DROPIN_CONF
        chmod 644 "${dropin_dir}/ops-alert.conf"
        (( installed++ )) || true
        log_info "_checks_install_systemd_dropins: installed dropin for ${svc}"
    done

    if (( installed > 0 )); then
        systemctl daemon-reload 2>/dev/null || true
        print_ok "Systemd OnFailure dropin installed for ${installed} service(s) — instant crash alerts enabled."
    else
        print_warn "No watched services found for systemd dropin (nginx/mariadb/php-fpm not installed?)"
    fi
}

# Fix-4: Remove systemd OnFailure dropin units
_checks_remove_systemd_dropins() {
    local dropin_svc="/etc/systemd/system/ops-alert-crash@.service"
    local svcs=(nginx mariadb fail2ban php8.3-fpm php8.2-fpm php8.1-fpm php7.4-fpm)
    local svc removed=0
    for svc in "${svcs[@]}"; do
        local dropin_file="/etc/systemd/system/${svc}.service.d/ops-alert.conf"
        if [[ -f "$dropin_file" ]]; then
            rm -f "$dropin_file"
            # Remove dropin dir if empty
            local dropin_dir="/etc/systemd/system/${svc}.service.d"
            [[ -d "$dropin_dir" ]] && rmdir "$dropin_dir" 2>/dev/null || true
            (( removed++ )) || true
        fi
    done
    [[ -f "$dropin_svc" ]] && rm -f "$dropin_svc"
    if (( removed > 0 )); then
        systemctl daemon-reload 2>/dev/null || true
        print_ok "Removed ${removed} systemd OnFailure dropin(s)."
    fi
    log_info "_checks_remove_systemd_dropins: removed=${removed}"
}

_checks_write_dispatcher() {
    # Write a small dispatcher script that ops-check cron entries call
    local dispatcher="${OPS_ROOT}/bin/ops-check"
    cat > "$dispatcher" <<'DISPATCHER_EOF'
#!/usr/bin/env bash
# ops-check — OPS scheduled check dispatcher
# Called by /etc/cron.d/ops-checks and systemd OnFailure dropin units.
# Fix-1: supports '5min' type to run all */5 checks in one process (1× source overhead).
# Fix-4: supports 'alert-crash <svc>' for instant systemd OnFailure alerting.
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
    # Fix-1: consolidated 5-minute batch — all checks in one bash process.
    5min)
        check_resources  || true
        check_uptime     || true
        check_services   || true
        check_log_spikes || true
        check_ddos       || true
        ;;
    # Fix-4: instant crash alert via systemd OnFailure — called with service name as arg.
    alert-crash)
        _CRASHED_SVC="${2:-unknown}"
        _HOSTNAME=$(hostname -f 2>/dev/null || hostname)
        _checks_send_telegram "🔴 Service CRASHED: ${_CRASHED_SVC} on ${_HOSTNAME} (systemd OnFailure)"
        log_warn "alert-crash: ${_CRASHED_SVC} crashed on ${_HOSTNAME}"
        ;;
    resources) check_resources      ;;
    uptime)    check_uptime         ;;
    ssl)       check_ssl_expiry     ;;
    domain)    check_domain_expiry  ;;
    security)  check_security_scan  ;;
    services)  check_services       ;;
    logspike)  check_log_spikes     ;;
    ddos)      check_ddos           ;;
    digest)    check_health_digest  ;;
    *)
        echo "Usage: ops-check <5min|alert-crash <svc>|resources|uptime|ssl|domain|security|services|logspike|ddos|digest>" >&2
        exit 1
        ;;
esac
DISPATCHER_EOF
    chmod 755 "$dispatcher"
    log_info "_checks_write_dispatcher: wrote ${dispatcher}"
}

# ── Checks menu ───────────────────────────────────────────────
menu_checks() {
    _checks_menu_run() {
        "$@"
        return 0
    }

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
        echo "  9) Run service crash check now"
        echo "  10) Run log spike check now"
        echo "  11) Run DDoS pattern check now"
        echo "  12) Send daily health digest now"
        echo "  0) Back"
        echo ""
        prompt_menu_choice "Select" "" choice
        case "$choice" in
            1)  _checks_menu_run checks_install_cron; press_enter ;;
            2)  _checks_menu_run checks_remove_cron; press_enter ;;
            3)  _checks_menu_run check_resources; press_enter ;;
            4)  _checks_menu_run check_uptime; press_enter ;;
            5)  _checks_menu_run check_ssl_expiry; press_enter ;;
            6)  _checks_menu_run check_domain_expiry; press_enter ;;
            7)  _checks_menu_run check_security_scan; press_enter ;;
            8)  _checks_menu_run _checks_show_log; press_enter ;;
            9)  _checks_menu_run check_services; press_enter ;;
            10) _checks_menu_run check_log_spikes; press_enter ;;
            11) _checks_menu_run check_ddos; press_enter ;;
            12) _checks_menu_run check_health_digest; press_enter ;;
            0)  return 0                      ;;
            *)  print_warn "Invalid option"   ;;
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
