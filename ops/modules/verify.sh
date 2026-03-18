#!/usr/bin/env bash
# ============================================================
# ops/modules/verify.sh
# Purpose:  Unified stack health verify — P2-04
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# Called by bin/ops via menu dispatch (sourced, not executed).
# Do NOT add set -euo pipefail here — inherited from bin/ops.
#
# Output format per check:
#   [PASS] Component     — detail
#   [WARN] Component     — detail  →  next action
#   [FAIL] Component     — detail  →  next action

# ── Colour helpers (safe if terminal doesn't support colours) ─
_vs_green()  { printf '\033[0;32m%s\033[0m' "$*"; }
_vs_yellow() { printf '\033[0;33m%s\033[0m' "$*"; }
_vs_red()    { printf '\033[0;31m%s\033[0m' "$*"; }

_vs_pass() {
    local label="$1"; shift
    printf '  ['; _vs_green 'PASS'; printf '] %-20s — %s\n' "$label" "$*"
}
_vs_warn() {
    local label="$1"; local detail="$2"; local hint="${3:-}"
    printf '  ['; _vs_yellow 'WARN'; printf '] %-20s — %s' "$label" "$detail"
    [[ -n "$hint" ]] && printf '  →  %s' "$hint"
    printf '\n'
}
_vs_fail() {
    local label="$1"; local detail="$2"; local hint="${3:-}"
    printf '  ['; _vs_red 'FAIL'; printf '] %-20s — %s' "$label" "$detail"
    [[ -n "$hint" ]] && printf '  →  %s' "$hint"
    printf '\n'
}

# ── Individual check functions ────────────────────────────────

_vs_check_ssh() {
    local ssh_port
    ssh_port="$(ops_conf_get "ops.conf" "SSH_PORT" 2>/dev/null || true)"
    ssh_port="${ssh_port:-22}"
    if ss -tlnp 2>/dev/null | grep -qE ":${ssh_port}\b"; then
        _vs_pass "SSH" "port ${ssh_port} listening"
        return 0
    else
        _vs_fail "SSH" "port ${ssh_port} not found in ss output" "check sshd: systemctl status sshd"
        return 2
    fi
}

_vs_check_nginx() {
    if ! command -v nginx >/dev/null 2>&1; then
        _vs_warn "Nginx" "not installed" "install via OPS: Domains & Nginx → Install Nginx"
        return 1
    fi
    local config_ok is_active
    nginx -t >/dev/null 2>&1 && config_ok=1 || config_ok=0
    systemctl is-active nginx >/dev/null 2>&1 && is_active=1 || is_active=0

    if [[ "$config_ok" -eq 1 && "$is_active" -eq 1 ]]; then
        _vs_pass "Nginx" "active, config ok"
        return 0
    elif [[ "$is_active" -eq 0 && "$config_ok" -eq 1 ]]; then
        _vs_fail "Nginx" "config ok but service inactive" "systemctl start nginx"
        return 2
    elif [[ "$config_ok" -eq 0 ]]; then
        _vs_fail "Nginx" "config test failed" "run: nginx -t  to see errors"
        return 2
    fi
}

_vs_check_pm2() {
    if ! command -v pm2 >/dev/null 2>&1; then
        _vs_warn "PM2" "not installed" "install via OPS: Node.js Services"
        return 1
    fi
    local online_count
    online_count=$(pm2 jlist 2>/dev/null | python3 -c "
import sys,json
try:
    procs=json.load(sys.stdin)
    online=sum(1 for p in procs if p.get('pm2_env',{}).get('status')=='online')
    print(online)
except:
    print(0)
" 2>/dev/null || echo "0")
    _vs_pass "PM2" "${online_count} process(es) online"
    return 0
}

_vs_check_nine_router() {
    if ! command -v pm2 >/dev/null 2>&1; then
        return 0  # PM2 not present, skip
    fi
    local status
    status=$(pm2 jlist 2>/dev/null | python3 -c "
import sys,json
try:
    procs=json.load(sys.stdin)
    for p in procs:
        if p.get('name')=='nine-router':
            print(p.get('pm2_env',{}).get('status','?'))
            raise SystemExit
    print('not-found')
except SystemExit:
    pass
except:
    print('error')
" 2>/dev/null || echo "not-found")
    case "$status" in
        online)
            # Also bind-check
            if curl -sf --max-time 2 "http://127.0.0.1:20128" >/dev/null 2>&1 || \
               curl -sf --max-time 2 "http://127.0.0.1:20128/health" >/dev/null 2>&1; then
                _vs_pass "9router" "online, port 20128 reachable"
            else
                _vs_pass "9router" "online (bind check inconclusive)"
            fi
            return 0
            ;;
        not-found)
            _vs_warn "9router" "not registered in PM2" "deploy via OPS: 9router Management"
            return 1
            ;;
        *)
            _vs_fail "9router" "PM2 status: ${status}" "pm2 logs nine-router  to diagnose"
            return 2
            ;;
    esac
}

_vs_check_php_fpm() {
    local found=0
    local ver svc
    for ver in 7.4 8.1 8.2 8.3; do
        svc="php${ver}-fpm"
        if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
            found=1
            if systemctl is-active "$svc" >/dev/null 2>&1; then
                _vs_pass "PHP ${ver}-FPM" "active"
            else
                _vs_fail "PHP ${ver}-FPM" "inactive" "systemctl start ${svc}"
            fi
        fi
    done
    if [[ "$found" -eq 0 ]]; then
        _vs_warn "PHP-FPM" "no PHP-FPM version installed" "install via OPS: PHP Management"
    fi
}

_vs_check_mariadb() {
    local svc=""
    if systemctl list-unit-files 2>/dev/null | grep -q '^mariadb\.service'; then
        svc="mariadb"
    elif systemctl list-unit-files 2>/dev/null | grep -q '^mysql\.service'; then
        svc="mysql"
    fi
    if [[ -z "$svc" ]]; then
        _vs_warn "Database" "MariaDB/MySQL not installed" "install via OPS: Database Management"
        return 1
    fi
    if systemctl is-active "$svc" >/dev/null 2>&1; then
        _vs_pass "Database (${svc})" "active"
        return 0
    else
        _vs_fail "Database (${svc})" "inactive" "systemctl start ${svc}"
        return 2
    fi
}

_vs_check_ssl() {
    if ! command -v certbot >/dev/null 2>&1; then
        _vs_warn "SSL (certbot)" "certbot not installed" "install via OPS: SSL Management → Install Certbot"
        return 1
    fi
    local certs_output domain expiry_date days_left
    certs_output=$(certbot certificates 2>/dev/null || true)
    if [[ -z "$certs_output" ]]; then
        _vs_warn "SSL" "no certificates found" "issue cert via OPS: SSL Management"
        return 1
    fi

    local any_warn=0 any_fail=0
    # Parse each cert block
    while IFS= read -r line; do
        case "$line" in
            *"Domains:"*)
                domain=$(printf '%s' "$line" | sed -E 's/.*Domains: //' | awk '{print $1}')
                ;;
            *"Expiry Date:"*)
                expiry_date=$(printf '%s' "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -n1)
                if [[ -n "$expiry_date" && -n "$domain" ]]; then
                    local expiry_epoch now_epoch
                    expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo 0)
                    now_epoch=$(date +%s)
                    days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
                    if [[ "$days_left" -le 0 ]]; then
                        _vs_fail "SSL (${domain})" "EXPIRED" "certbot renew"
                        any_fail=1
                    elif [[ "$days_left" -le 14 ]]; then
                        _vs_warn "SSL (${domain})" "expires in ${days_left} days" "certbot renew  before expiry"
                        any_warn=1
                    else
                        _vs_pass "SSL (${domain})" "valid, ${days_left} days remaining"
                    fi
                    domain=""
                fi
                ;;
        esac
    done <<< "$certs_output"

    [[ "$any_fail" -eq 1 ]] && return 2
    [[ "$any_warn" -eq 1 ]] && return 1
    return 0
}

_vs_check_monitoring() {
    if systemctl list-unit-files 2>/dev/null | grep -q '^netdata\.service'; then
        if systemctl is-active netdata >/dev/null 2>&1; then
            _vs_pass "Netdata" "active, dashboard at localhost:19999"
        else
            _vs_warn "Netdata" "installed but inactive" "systemctl start netdata"
        fi
    fi
    # If not installed — skip silently (opt-in feature)
}

# ── Main verify_stack function ────────────────────────────────

verify_stack() {
    print_section "Stack Health Verification"

    local pass_count=0 warn_count=0 fail_count=0

    # Wrapper that tallies return codes without triggering set -e
    _vs_run() {
        local fn="$1"
        local rc=0
        "$fn" || rc=$?
        case "$rc" in
            0) pass_count=$(( pass_count + 1 )) ;;
            1) warn_count=$(( warn_count + 1 )) ;;
            2) fail_count=$(( fail_count + 1 )) ;;
            *) warn_count=$(( warn_count + 1 )) ;;
        esac
        return 0   # always return 0 so set -e never triggers
    }

    _vs_run _vs_check_ssh
    _vs_run _vs_check_nginx
    _vs_run _vs_check_pm2
    _vs_run _vs_check_nine_router
    _vs_run _vs_check_php_fpm
    _vs_run _vs_check_mariadb
    _vs_run _vs_check_ssl
    _vs_check_monitoring 2>/dev/null || true   # always optional

    echo ""
    echo "  ═══════════════════════════════════════════════════"
    printf '  Summary: '
    _vs_green "${pass_count} PASS"; printf '  '
    _vs_yellow "${warn_count} WARN"; printf '  '
    _vs_red "${fail_count} FAIL"; printf '\n'

    if [[ "$fail_count" -gt 0 || "$warn_count" -gt 0 ]]; then
        echo ""
        echo "  → Review FAIL items first, then WARN items."
        echo "    Each line above shows the suggested next action."
    else
        echo "  → All monitored components healthy."
    fi
    echo ""

    log_info "verify_stack: pass=${pass_count} warn=${warn_count} fail=${fail_count}"
    unset -f _vs_run
    return 0   # never exit the menu due to FAIL counts
}
