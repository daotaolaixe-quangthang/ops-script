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

_vs_get_ops_runtime_user() {
    local runtime_user
    runtime_user="$(ops_conf_get "ops.conf" "OPS_RUNTIME_USER" 2>/dev/null || true)"
    if [[ -z "$runtime_user" ]]; then
        runtime_user="$(ops_conf_get "ops.conf" "OPS_ADMIN_USER" 2>/dev/null || true)"
    fi
    echo "${runtime_user:-root}"
}

_vs_get_ops_runtime_home() {
    local runtime_user
    runtime_user="$(_vs_get_ops_runtime_user)"
    getent passwd "$runtime_user" | cut -d: -f6
}

_vs_run_as_runtime_user() {
    local runtime_user home_dir
    runtime_user="$(_vs_get_ops_runtime_user)"
    home_dir="$(_vs_get_ops_runtime_home)"
    runuser -u "$runtime_user" -- env HOME="$home_dir" PM2_HOME="$home_dir/.pm2" PATH="$PATH" "$@"
}

_vs_check_ssh() {
    local ssh_port transition_port effective_ports root_login password_auth x11_forwarding tcp_forwarding agent_forwarding
    ssh_port="$(ops_conf_get "ops.conf" "OPS_SSH_PORT" 2>/dev/null || true)"
    ssh_port="${ssh_port:-22}"
    transition_port="$(ops_conf_get "ops.conf" "OPS_SSH_TRANSITION_PORT" 2>/dev/null || true)"
    effective_ports="$(sshd -T 2>/dev/null | awk '/^port / {print $2}' | paste -sd, -)"
    root_login="$(sshd -T 2>/dev/null | awk '/^permitrootlogin / {print $2; exit}')"
    password_auth="$(sshd -T 2>/dev/null | awk '/^passwordauthentication / {print $2; exit}')"
    x11_forwarding="$(sshd -T 2>/dev/null | awk '/^x11forwarding / {print $2; exit}')"
    tcp_forwarding="$(sshd -T 2>/dev/null | awk '/^allowtcpforwarding / {print $2; exit}')"
    agent_forwarding="$(sshd -T 2>/dev/null | awk '/^allowagentforwarding / {print $2; exit}')"

    if ! ss -tln 2>/dev/null | grep -qE ":${ssh_port}\b"; then
        _vs_fail "SSH" "locked port ${ssh_port} not listening" "check ssh service and managed SSH include"
        return 2
    fi

    if [[ "$root_login" != "no" ]]; then
        _vs_fail "SSH" "PermitRootLogin=${root_login:-unknown}" "set PermitRootLogin no"
        return 2
    fi

    if [[ "$x11_forwarding" != "no" || "$tcp_forwarding" != "no" || "$agent_forwarding" != "no" ]]; then
        _vs_fail "SSH" "forwarding still enabled (x11=${x11_forwarding:-?}, tcp=${tcp_forwarding:-?}, agent=${agent_forwarding:-?})" "disable forwarding in managed SSH config"
        return 2
    fi

    if [[ -z "$transition_port" && "$password_auth" != "no" ]]; then
        _vs_fail "SSH" "PasswordAuthentication=${password_auth:-unknown} outside transition window" "disable password auth after key verification"
        return 2
    fi

    if [[ -n "$transition_port" ]]; then
        if ss -tln 2>/dev/null | grep -qE ":${transition_port}\b"; then
            _vs_warn "SSH" "transition active: locked=${ssh_port}, transition=${transition_port}, password_auth=${password_auth:-unknown}" "finalize SSH transition after login test succeeds"
            return 1
        fi
        _vs_warn "SSH" "transition port ${transition_port} recorded in state but not listening" "clean OPS_SSH_TRANSITION_PORT and reconcile SSH config"
        return 1
    fi

    _vs_pass "SSH" "locked port ${ssh_port} listening, effective ports=${effective_ports:-unknown}, root/password hardening active"
    return 0
}

_vs_check_ufw() {
    if ! command -v ufw >/dev/null 2>&1; then
        _vs_warn "UFW" "not installed" "install and reconcile firewall baseline"
        return 1
    fi

    local status_output expected_port transition_port found_stale=0 allowed_tcp_ports=() port
    status_output="$(ufw status 2>/dev/null || true)"
    expected_port="$(ops_conf_get "ops.conf" "OPS_SSH_PORT" 2>/dev/null || true)"
    expected_port="${expected_port:-22}"
    transition_port="$(ops_conf_get "ops.conf" "OPS_SSH_TRANSITION_PORT" 2>/dev/null || true)"

    if ! printf '%s\n' "$status_output" | grep -q "Status: active"; then
        _vs_fail "UFW" "firewall inactive" "enable UFW and apply OPS baseline"
        return 2
    fi

    if ! printf '%s\n' "$status_output" | grep -Eq "${expected_port}/tcp[[:space:]]+ALLOW"; then
        _vs_fail "UFW" "locked SSH port ${expected_port}/tcp not allowed" "reconcile UFW baseline"
        return 2
    fi

    if ! printf '%s\n' "$status_output" | grep -Eq "80/tcp[[:space:]]+ALLOW" || ! printf '%s\n' "$status_output" | grep -Eq "443/tcp[[:space:]]+ALLOW"; then
        _vs_warn "UFW" "HTTP/HTTPS baseline not fully present" "reconcile UFW baseline if this host serves public web traffic"
        return 1
    fi

    if printf '%s\n' "$status_output" | grep -Eq "20128/tcp[[:space:]]+ALLOW"; then
        _vs_fail "UFW" "9router port 20128 is publicly allowed" "remove allow rule and keep only nginx public"
        return 2
    fi

    while IFS= read -r port; do
        [[ -n "$port" ]] && allowed_tcp_ports+=("$port")
    done < <(printf '%s\n' "$status_output" | awk '/\/tcp/ && /ALLOW/ {print $1}' | cut -d/ -f1 | grep -E '^[0-9]+$' | sort -u)

    for port in "${allowed_tcp_ports[@]}"; do
        if [[ "$port" == "80" || "$port" == "443" || "$port" == "$expected_port" || "$port" == "$transition_port" ]]; then
            continue
        fi
        found_stale=1
        break
    done

    if [[ "$found_stale" -eq 1 ]]; then
        _vs_warn "UFW" "stale SSH allow rule detected" "reconcile UFW and finalize old SSH transition ports"
        return 1
    fi

    _vs_pass "UFW" "active, managed SSH/http/https rules present, 20128 not exposed"
    return 0
}

_vs_check_fail2ban() {
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        _vs_warn "fail2ban" "not installed" "install fail2ban baseline"
        return 1
    fi

    local status_all status_sshd expected_ports transition_port
    status_all="$(fail2ban-client status 2>/dev/null || true)"
    status_sshd="$(fail2ban-client status sshd 2>/dev/null || true)"
    expected_ports="$(ops_conf_get "ops.conf" "OPS_SSH_PORT" 2>/dev/null || true)"
    expected_ports="${expected_ports:-22}"
    transition_port="$(ops_conf_get "ops.conf" "OPS_SSH_TRANSITION_PORT" 2>/dev/null || true)"
    if [[ -n "$transition_port" && "$transition_port" != "$expected_ports" ]]; then
        expected_ports="${expected_ports},${transition_port}"
    fi

    if ! systemctl is-active fail2ban >/dev/null 2>&1; then
        _vs_fail "fail2ban" "service inactive" "systemctl enable --now fail2ban"
        return 2
    fi

    if ! printf '%s\n' "$status_all" | grep -q 'sshd'; then
        _vs_fail "fail2ban" "sshd jail missing" "write OPS fail2ban jail and restart service"
        return 2
    fi

    if ! printf '%s\n' "$status_sshd" | grep -Eq "Port:[[:space:]]*${expected_ports//,/|}"; then
        _vs_warn "fail2ban" "sshd jail ports do not match OPS state (${expected_ports})" "rewrite fail2ban jail from OPS baseline"
        return 1
    fi

    _vs_pass "fail2ban" "active, sshd jail present, expected ports=${expected_ports}"
    return 0
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
    local online_count runtime_user pm2_owner
    online_count=$(_vs_run_as_runtime_user pm2 jlist 2>/dev/null | python3 -c "
import sys,json
try:
    procs=json.load(sys.stdin)
    online=sum(1 for p in procs if p.get('pm2_env',{}).get('status')=='online')
    print(online)
except:
    print(0)
" 2>/dev/null || echo "0")
    runtime_user="$(_vs_get_ops_runtime_user)"
    pm2_owner="$(ps -eo user=,comm= 2>/dev/null | awk '$2=="PM2"{print $1; exit}')"

    if [[ -n "$pm2_owner" && "$pm2_owner" == "root" ]]; then
        _vs_fail "PM2" "daemon running as root" "migrate PM2 to runtime user ${runtime_user}"
        return 2
    fi

    if [[ -n "$pm2_owner" && "$pm2_owner" != "$runtime_user" ]]; then
        _vs_warn "PM2" "daemon owner=${pm2_owner}, expected=${runtime_user}" "reconcile PM2 startup user"
        return 1
    fi

    _vs_pass "PM2" "${online_count} process(es) online, owner=${pm2_owner:-unknown}"
    return 0
}

_vs_check_nine_router() {
    if ! command -v pm2 >/dev/null 2>&1; then
        return 0
    fi
    local status listening_public
    status=$(_vs_run_as_runtime_user pm2 jlist 2>/dev/null | python3 -c "
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
    listening_public=$(ss -tln 2>/dev/null | awk '$4 ~ /:20128$/ {print $4}' | grep -E '(^0\.0\.0\.0:20128$|^\[::\]:20128$)' || true)
    case "$status" in
        online)
            if [[ -n "$listening_public" ]]; then
                _vs_warn "9router" "PM2 online and binding publicly on 20128 (${listening_public})" "verify UFW deny rule and keep nginx as sole public entrypoint"
                return 1
            fi
            if curl -sf --max-time 2 "http://127.0.0.1:20128" >/dev/null 2>&1 || \
               curl -sf --max-time 2 "http://127.0.0.1:20128/health" >/dev/null 2>&1; then
                _vs_pass "9router" "online, localhost 20128 reachable"
            else
                _vs_pass "9router" "online (localhost health probe inconclusive)"
            fi
            return 0
            ;;
        not-found)
            _vs_warn "9router" "not registered in PM2" "deploy via OPS: 9router Management"
            return 1
            ;;
        *)
            _vs_fail "9router" "PM2 status: ${status}" "pm2 logs nine-router to diagnose"
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
    local svc="" rescue_proc
    if systemctl list-unit-files 2>/dev/null | grep -q '^mariadb\.service'; then
        svc="mariadb"
    elif systemctl list-unit-files 2>/dev/null | grep -q '^mysql\.service'; then
        svc="mysql"
    fi
    rescue_proc="$(ps -eo args= 2>/dev/null | grep -E '[m]ariadbd?.*--skip-grant-tables|[m]ysqld.*--skip-grant-tables' || true)"

    if [[ -n "$rescue_proc" ]]; then
        _vs_fail "Database" "rescue mode detected: --skip-grant-tables still running" "stop unmanaged DB process and restore managed service mode"
        return 2
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
}

_vs_check_sysctl_swap() {
    local send_all send_default martians_all martians_default swappiness swap_count
    send_all="$(sysctl -n net.ipv4.conf.all.send_redirects 2>/dev/null || true)"
    send_default="$(sysctl -n net.ipv4.conf.default.send_redirects 2>/dev/null || true)"
    martians_all="$(sysctl -n net.ipv4.conf.all.log_martians 2>/dev/null || true)"
    martians_default="$(sysctl -n net.ipv4.conf.default.log_martians 2>/dev/null || true)"
    swappiness="$(sysctl -n vm.swappiness 2>/dev/null || true)"
    swap_count="$(swapon --show --noheadings 2>/dev/null | wc -l | tr -d ' ')"

    if [[ "$send_all" != "0" || "$send_default" != "0" || "$martians_all" != "1" || "$martians_default" != "1" ]]; then
        _vs_fail "Sysctl" "hardening drift detected (send_redirects/log_martians)" "reapply OPS host baseline"
        return 2
    fi

    if [[ -z "$swappiness" || "$swappiness" -gt 20 ]]; then
        _vs_warn "Swappiness" "vm.swappiness=${swappiness:-unknown}" "set low swappiness in OPS sysctl baseline"
        return 1
    fi

    if [[ "$swap_count" -eq 0 ]]; then
        _vs_warn "Swap" "no active swap detected" "apply OPS host baseline to provision swap if policy allows"
        return 1
    fi

    _vs_pass "Host Kernel" "sysctl hardening active, swappiness=${swappiness}, swap devices=${swap_count}"
    return 0
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
    _vs_run _vs_check_ufw
    _vs_run _vs_check_fail2ban
    _vs_run _vs_check_nginx
    _vs_run _vs_check_pm2
    _vs_run _vs_check_nine_router
    _vs_run _vs_check_php_fpm
    _vs_run _vs_check_mariadb
    _vs_run _vs_check_ssl
    _vs_run _vs_check_sysctl_swap
    _vs_check_monitoring 2>/dev/null || true

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
