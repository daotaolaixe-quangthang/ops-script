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

_vs_set_result() {
    _VS_LAST_RESULT="$1"
}

# ── Individual check functions ────────────────────────────────

_vs_get_ops_runtime_user() {
    ops_runtime_user
}

_vs_get_ops_runtime_home() {
    ops_runtime_home "$(_vs_get_ops_runtime_user)"
}

_vs_run_as_runtime_user() {
    ops_run_as_user "$(_vs_get_ops_runtime_user)" "$@"
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
        _vs_set_result fail
        return 0
    fi

    if [[ "$root_login" != "no" ]]; then
        _vs_fail "SSH" "PermitRootLogin=${root_login:-unknown}" "set PermitRootLogin no"
        _vs_set_result fail
        return 0
    fi

    if [[ "$x11_forwarding" != "no" || "$tcp_forwarding" != "no" || "$agent_forwarding" != "no" ]]; then
        _vs_fail "SSH" "forwarding still enabled (x11=${x11_forwarding:-?}, tcp=${tcp_forwarding:-?}, agent=${agent_forwarding:-?})" "disable forwarding in managed SSH config"
        _vs_set_result fail
        return 0
    fi

    if [[ -z "$transition_port" && "$password_auth" != "no" ]]; then
        _vs_fail "SSH" "PasswordAuthentication=${password_auth:-unknown} outside transition window" "disable password auth after key verification"
        _vs_set_result fail
        return 0
    fi

    if [[ -n "$transition_port" ]]; then
        if ss -tln 2>/dev/null | grep -qE ":${transition_port}\b"; then
            _vs_warn "SSH" "transition active: locked=${ssh_port}, transition=${transition_port}, password_auth=${password_auth:-unknown}" "finalize SSH transition after login test succeeds"
            _vs_set_result warn
            return 0
        fi
        _vs_warn "SSH" "transition port ${transition_port} recorded in state but not listening" "clean OPS_SSH_TRANSITION_PORT and reconcile SSH config"
        _vs_set_result warn
        return 0
    fi

    _vs_pass "SSH" "locked port ${ssh_port} listening, effective ports=${effective_ports:-unknown}, root/password hardening active"
    _vs_set_result pass
    return 0
}

_vs_check_ufw() {
    if ! command -v ufw >/dev/null 2>&1; then
        _vs_warn "UFW" "not installed" "install and reconcile firewall baseline"
        _vs_set_result warn
        return 0
    fi

    local status_output expected_port transition_port found_stale=0 allowed_tcp_ports=() port
    status_output="$(ufw status 2>/dev/null || true)"
    expected_port="$(ops_conf_get "ops.conf" "OPS_SSH_PORT" 2>/dev/null || true)"
    expected_port="${expected_port:-22}"
    transition_port="$(ops_conf_get "ops.conf" "OPS_SSH_TRANSITION_PORT" 2>/dev/null || true)"

    if ! printf '%s\n' "$status_output" | grep -q "Status: active"; then
        _vs_fail "UFW" "firewall inactive" "enable UFW and apply OPS baseline"
        _vs_set_result fail
        return 0
    fi

    if ! printf '%s\n' "$status_output" | grep -Eq "${expected_port}/tcp[[:space:]]+ALLOW"; then
        _vs_fail "UFW" "locked SSH port ${expected_port}/tcp not allowed" "reconcile UFW baseline"
        _vs_set_result fail
        return 0
    fi

    if ! printf '%s\n' "$status_output" | grep -Eq "80/tcp[[:space:]]+ALLOW" || ! printf '%s\n' "$status_output" | grep -Eq "443/tcp[[:space:]]+ALLOW"; then
        _vs_warn "UFW" "HTTP/HTTPS baseline not fully present" "reconcile UFW baseline if this host serves public web traffic"
        _vs_set_result warn
        return 0
    fi

    if printf '%s\n' "$status_output" | grep -Eq "8317/tcp[[:space:]]+ALLOW"; then
        _vs_fail "UFW" "CLIProxyAPI port 8317 is publicly allowed" "remove allow rule and keep only nginx public"
        _vs_set_result fail
        return 0
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
        _vs_set_result warn
        return 0
    fi

    _vs_pass "UFW" "active, managed SSH/http/https rules present, 8317 not exposed"
    _vs_set_result pass
    return 0
}

_vs_check_fail2ban() {
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        _vs_warn "fail2ban" "not installed" "install fail2ban baseline"
        _vs_set_result warn
        return 0
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
        _vs_set_result fail
        return 0
    fi

    if ! printf '%s\n' "$status_all" | grep -q 'sshd'; then
        _vs_fail "fail2ban" "sshd jail missing" "write OPS fail2ban jail and restart service"
        _vs_set_result fail
        return 0
    fi

    if ! printf '%s\n' "$status_sshd" | grep -Eq "Port:[[:space:]]*${expected_ports//,/|}"; then
        _vs_warn "fail2ban" "sshd jail ports do not match OPS state (${expected_ports})" "rewrite fail2ban jail from OPS baseline"
        _vs_set_result warn
        return 0
    fi

    _vs_pass "fail2ban" "active, sshd jail present, expected ports=${expected_ports}"
    _vs_set_result pass
    return 0
}

_vs_check_nginx() {
    if ! command -v nginx >/dev/null 2>&1; then
        _vs_warn "Nginx" "not installed" "install via OPS: Domains & Nginx → Install Nginx"
        _vs_set_result warn
        return 0
    fi
    local config_ok is_active
    nginx -t >/dev/null 2>&1 && config_ok=1 || config_ok=0
    systemctl is-active nginx >/dev/null 2>&1 && is_active=1 || is_active=0

    if [[ "$config_ok" -eq 0 ]]; then
        _vs_fail "Nginx" "config test failed" "run: nginx -t  to see errors"
        _vs_set_result fail
        return 0
    fi
    if [[ "$is_active" -eq 0 ]]; then
        _vs_fail "Nginx" "config ok but service inactive" "systemctl start nginx"
        _vs_set_result fail
        return 0
    fi

    # ── Hardening sub-checks ────────────────────────────────────
    local nginx_full_conf any_warn=0

    # Cache nginx -T output once for all sub-checks
    nginx_full_conf=$(nginx -T 2>/dev/null || true)

    # 1. Version — warn if still on Ubuntu distro pkg (< 1.24)
    local nginx_ver
    nginx_ver=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
    if [[ -n "$nginx_ver" ]] && ! awk -v v="$nginx_ver" 'BEGIN{exit !(v+0 >= 1.24)}'; then
        _vs_warn "Nginx version" "${nginx_ver} (< 1.24)" "run OPS: Domains & Nginx → Install Nginx to upgrade to official mainline"
        any_warn=1
    fi

    # 2. HTTP/2 — accept both old combined form (listen 443 ssl http2) and
    #    the two-directive nginx 1.25.1+ form (listen 443 ssl; http2 on;)
    if ! printf '%s\n' "$nginx_full_conf" | grep -qE 'listen[[:space:]]+[0-9]+[[:space:]]+ssl[[:space:]]+http2|^[[:space:]]*http2[[:space:]]+on'; then
        _vs_warn "Nginx http2" "no http2 directive found" "run OPS: Apply security baseline, then rebuild vhosts"
        any_warn=1
    fi

    # 3. Gzip types — must have gzip_types configured (not just gzip on)
    if ! printf '%s\n' "$nginx_full_conf" | grep -qE '^[[:space:]]*gzip_types[[:space:]]'; then
        _vs_warn "Nginx gzip" "gzip_types not configured (only gzip on)" "run OPS: Domains & Nginx → Apply security baseline"
        any_warn=1
    fi

    # 4. Rate limiting zones
    if ! printf '%s\n' "$nginx_full_conf" | grep -qE 'limit_req_zone'; then
        _vs_warn "Nginx rate limit" "limit_req_zone not defined" "run OPS: Domains & Nginx → Apply security baseline"
        any_warn=1
    fi

    # 5. client_max_body_size
    if ! printf '%s\n' "$nginx_full_conf" | grep -qE 'client_max_body_size'; then
        _vs_warn "Nginx client" "client_max_body_size not set (DoS risk)" "run OPS: Domains & Nginx → Apply security baseline"
        any_warn=1
    fi

    # 6. worker_rlimit_nofile
    if ! printf '%s\n' "$nginx_full_conf" | grep -qE 'worker_rlimit_nofile'; then
        _vs_warn "Nginx rlimit" "worker_rlimit_nofile not set" "run OPS: Domains & Nginx → Apply security baseline"
        any_warn=1
    fi

    if [[ "$any_warn" -eq 1 ]]; then
        _vs_warn "Nginx" "active but hardening incomplete — see WARNs above" "run OPS: Domains & Nginx → Apply security baseline (option 8)"
        _vs_set_result warn
        return 0
    fi

    _vs_pass "Nginx" "active, config ok, http2, gzip_types, rate-limit zones, client limits, rlimit all present"
    _vs_set_result pass
    return 0
}


_vs_check_pm2() {
    if ! command -v pm2 >/dev/null 2>&1; then
        _vs_warn "PM2" "not installed" "install via OPS: Node.js Services"
        _vs_set_result warn
        return 0
    fi
    local online_count runtime_user pm2_owner
    online_count=$(_vs_run_as_runtime_user pm2 jlist 2>/dev/null | ops_pm2_online_count_from_json 2>/dev/null || echo "0")
    runtime_user="$(_vs_get_ops_runtime_user)"
    pm2_owner="$(ps -eo user=,comm= 2>/dev/null | awk '$2=="PM2"{print $1; exit}')"

    if [[ -n "$pm2_owner" && "$pm2_owner" == "root" ]]; then
        _vs_fail "PM2" "daemon running as root" "migrate PM2 to runtime user ${runtime_user}"
        _vs_set_result fail
        return 0
    fi

    if [[ -n "$pm2_owner" && "$pm2_owner" != "$runtime_user" ]]; then
        _vs_warn "PM2" "daemon owner=${pm2_owner}, expected=${runtime_user}" "reconcile PM2 startup user"
        _vs_set_result warn
        return 0
    fi

    _vs_pass "PM2" "${online_count} process(es) online, owner=${pm2_owner:-unknown}"
    _vs_set_result pass
    return 0
}

_vs_check_cliproxyapi() {
    if ! systemctl list-unit-files 2>/dev/null | grep -q '^cli-proxy-api\.service'; then
        _vs_warn "CLIProxyAPI" "service cli-proxy-api is not installed" "deploy via OPS: CLIProxyAPI Management"
        _vs_set_result warn
        return 0
    fi

    local status listening_public listening_local api_key api_header response
    status=$(systemctl is-active cli-proxy-api 2>/dev/null || echo "inactive")
    listening_public=$(ss -tln 2>/dev/null | awk '$4 ~ /:8317$/ {print $4}' | grep -E '(^0\.0\.0\.0:8317$|^\[::\]:8317$)' || true)
    listening_local=$(ss -tln 2>/dev/null | awk '$4 ~ /:8317$/ {print $4}' | grep -E '(^127\.0\.0\.1:8317$|^\[::1\]:8317$)' || true)

    case "$status" in
        active)
            if [[ -n "$listening_public" ]]; then
                _vs_warn "CLIProxyAPI" "service is binding publicly on 8317 (${listening_public})" "verify UFW deny rule and keep nginx as sole public entrypoint"
                _vs_set_result warn
                return 0
            fi
            if [[ -z "$listening_local" ]]; then
                _vs_fail "CLIProxyAPI" "service is not listening on loopback 8317" "systemctl status cli-proxy-api to diagnose"
                _vs_set_result fail
                return 0
            fi

            api_header=()
            if [[ "$(ops_conf_get "cli-proxy-api.conf" "CLIPROXYAPI_REQUIRE_API_KEY" 2>/dev/null || true)" == "yes" ]] && [[ -f "${OPS_CONFIG_DIR}/.cli-proxy-api-key" ]]; then
                api_key=$(tr -d '\r\n' < "${OPS_CONFIG_DIR}/.cli-proxy-api-key")
                [[ -n "$api_key" ]] && api_header=(-H "Authorization: Bearer ${api_key}")
            fi

            response=$(curl -fsS --max-time 3 "${api_header[@]}" "http://127.0.0.1:8317/v1/models" 2>/dev/null || true)
            if [[ -n "$response" ]] && printf '%s' "$response" | grep -qE '^[[:space:]]*[\[{]'; then
                _vs_pass "CLIProxyAPI" "active, loopback 8317 reachable, /v1/models returned JSON"
            else
                _vs_warn "CLIProxyAPI" "active, loopback 8317 reachable, /v1/models probe inconclusive" "complete provider auth bootstrap and re-run verify"
            fi
            _vs_set_result pass
            return 0
            ;;
        inactive|failed|activating|deactivating)
            _vs_fail "CLIProxyAPI" "systemd status: ${status}" "systemctl status cli-proxy-api to diagnose"
            _vs_set_result fail
            return 0
            ;;
        *)
            _vs_warn "CLIProxyAPI" "systemd status: ${status}" "verify service installation"
            _vs_set_result warn
            return 0
            ;;
    esac
}

_vs_check_php_fpm() {
    local found=0
    local any_fail=0
    local ver svc
    for ver in 7.4 8.1 8.2 8.3; do
        svc="php${ver}-fpm"
        if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
            found=1
            if systemctl is-active "$svc" >/dev/null 2>&1; then
                _vs_pass "PHP ${ver}-FPM" "active"
            else
                _vs_fail "PHP ${ver}-FPM" "inactive" "systemctl start ${svc}"
                any_fail=1
            fi
        fi
    done
    if [[ "$found" -eq 0 ]]; then
        _vs_warn "PHP-FPM" "no PHP-FPM version installed" "install via OPS: PHP Management"
        _vs_set_result warn
        return 0
    fi

    if [[ "$any_fail" -eq 1 ]]; then
        _vs_set_result fail
    else
        _vs_set_result pass
    fi

    return 0
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
        _vs_set_result fail
        return 0
    fi

    if [[ -z "$svc" ]]; then
        _vs_warn "Database" "MariaDB/MySQL not installed" "install via OPS: Database Management"
        _vs_set_result warn
        return 0
    fi

    if ! systemctl is-active "$svc" >/dev/null 2>&1; then
        _vs_fail "Database (${svc})" "inactive" "systemctl start ${svc}"
        _vs_set_result fail
        return 0
    fi

    # ── Deep security checks (OPS audit requirements) ───────────
    trap 'unset -f _vs_db_query _vs_db_var 2>/dev/null' RETURN
    _vs_db_query() {
        local sql="$1"
        local pass_file="${DB_ROOT_PASSWORD_FILE:-${OPS_CONFIG_DIR:-/etc/ops}/.db-root-password}"

        if declare -F _db_mysql_root_query >/dev/null 2>&1; then
            _db_mysql_root_query "$sql"
            return $?
        fi

        if mysql --protocol=socket -u root -e "SELECT 1;" >/dev/null 2>&1; then
            mysql --protocol=socket -u root -sNe "$sql"
            return $?
        fi

        if [[ -f "$pass_file" ]]; then
            local pw
            pw=$(cat "$pass_file")
            MYSQL_PWD="$pw" mysql -u root -sNe "$sql"
            return $?
        fi

        return 1
    }

    _vs_db_var() {
        _vs_db_query "SHOW VARIABLES LIKE '${1}';" 2>/dev/null | awk 'NR==1 {print $2}'
    }

    if ! _vs_db_query "SELECT 1;" >/dev/null 2>&1; then
        _vs_fail "Database (${svc})" "root auth unavailable for verify" "restore unix_socket root auth or ensure legacy /etc/ops/.db-root-password is current"
        _vs_set_result fail
        return 0
    fi

    local any_fail=0 any_warn=0

    # 1. Bind address — must be 127.0.0.1 (never 0.0.0.0)
    local bind_addr
    bind_addr="$(_vs_db_var "bind_address")"
    if [[ "$bind_addr" != "127.0.0.1" && "$bind_addr" != "localhost" && "$bind_addr" != "::1" ]]; then
        _vs_fail "DB bind_address" "${bind_addr:-unknown}" "set bind-address=127.0.0.1 in mariadb.conf.d/50-server.cnf"
        any_fail=1
    fi

    # 2. local_infile must be OFF (file exfiltration vector)
    local local_infile
    local_infile="$(_vs_db_var "local_infile")"
    if [[ "${local_infile^^}" != "OFF" ]]; then
        _vs_fail "DB local_infile" "${local_infile:-unknown}" "set local_infile=OFF via OPS: Database → Apply tuning"
        any_fail=1
    fi

    # 3. secure_file_priv must NOT be empty string (empty = unrestricted file read/write)
    local sfp
    sfp="$(_vs_db_var "secure_file_priv")"
    if [[ -z "$sfp" ]]; then
        _vs_warn "DB secure_file_priv" "empty (unrestricted)" "set secure_file_priv to a disabled non-existent path via OPS: Database → Apply tuning"
        any_warn=1
    fi

    # 4. SSL must be enabled
    local have_ssl
    have_ssl="$(_vs_db_var "have_ssl")"
    if [[ "${have_ssl^^}" != "YES" ]]; then
        _vs_fail "DB SSL" "${have_ssl:-DISABLED}" "run OPS: Database → Apply tuning to generate SSL certs"
        any_fail=1
    fi

    # 5. Slow query log should be ON
    local slow_log
    slow_log="$(_vs_db_var "slow_query_log")"
    if [[ "${slow_log^^}" != "ON" ]]; then
        _vs_warn "DB slow_query_log" "${slow_log:-OFF}" "run OPS: Database → Apply tuning"
        any_warn=1
    fi

    # 6. skip_name_resolve should be ON (avoid DNS lookup latency)
    local skip_ns
    skip_ns="$(_vs_db_var "skip_name_resolve")"
    if [[ "${skip_ns^^}" != "ON" ]]; then
        _vs_warn "DB skip_name_resolve" "${skip_ns:-OFF}" "run OPS: Database → Apply tuning"
        any_warn=1
    fi

    unset -f _vs_db_query _vs_db_var

    if [[ "$any_fail" -eq 1 ]]; then
        _vs_set_result fail
        return 0
    fi
    if [[ "$any_warn" -eq 1 ]]; then
        _vs_warn "Database (${svc})" "active, security hardening incomplete" "run OPS: Database → Apply tuning"
        _vs_set_result warn
        return 0
    fi

    _vs_pass "Database (${svc})" "active, bind=127.0.0.1, SSL=YES, local_infile=OFF, slow_log=ON"
    _vs_set_result pass
    return 0
}

_vs_check_ssl() {
    if ! command -v certbot >/dev/null 2>&1; then
        _vs_warn "SSL (certbot)" "certbot not installed" "install via OPS: SSL Management → Install Certbot"
        _vs_set_result warn
        return 0
    fi
    local certs_output domain expiry_date days_left
    certs_output=$(certbot certificates 2>/dev/null || true)
    if [[ -z "$certs_output" ]]; then
        _vs_warn "SSL" "no certificates found" "issue cert via OPS: SSL Management"
        _vs_set_result warn
        return 0
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

    [[ "$any_fail" -eq 1 ]] && { _vs_set_result fail; return 0; }
    [[ "$any_warn" -eq 1 ]] && { _vs_set_result warn; return 0; }
    _vs_set_result pass
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
        _vs_set_result fail
        return 0
    fi

    if [[ -z "$swappiness" || "$swappiness" -gt 20 ]]; then
        _vs_warn "Swappiness" "vm.swappiness=${swappiness:-unknown}" "set low swappiness in OPS sysctl baseline"
        _vs_set_result warn
        return 0
    fi

    if [[ "$swap_count" -eq 0 ]]; then
        _vs_warn "Swap" "no active swap detected" "apply OPS host baseline to provision swap if policy allows"
        _vs_set_result warn
        return 0
    fi

    _vs_pass "Host Kernel" "sysctl hardening active, swappiness=${swappiness}, swap devices=${swap_count}"
    _vs_set_result pass
    return 0
}

_vs_check_patch_state() {
    local reboot_needed=0 upgradable_count=0
    [[ -f /var/run/reboot-required ]] && reboot_needed=1
    upgradable_count=$(apt list --upgradable 2>/dev/null | grep -c '/upgradable' || true)
    upgradable_count="${upgradable_count:-0}"

    if [[ "$reboot_needed" -eq 1 ]]; then
        _vs_fail "OS Patches" "reboot required (pending kernel/lib update)" "reboot in a controlled window, then re-run verify"
        _vs_set_result fail
    elif [[ "$upgradable_count" -gt 0 ]]; then
        _vs_warn "OS Patches" "${upgradable_count} package(s) upgradable" "run: apt upgrade -y && apt autoremove -y"
        _vs_set_result warn
    else
        _vs_pass "OS Patches" "up-to-date, no reboot required"
        _vs_set_result pass
    fi
    return 0
}

_vs_check_runtime_user() {
    local ru
    ru="$(ops_runtime_user 2>/dev/null || true)"
    if [[ "$ru" == "root" || -z "$ru" ]]; then
        _vs_fail "Runtime User" "ops_runtime_user resolved to '${ru:-empty}'" \
            "set OPS_RUNTIME_USER or OPS_ADMIN_USER to a valid non-root user in ops.conf"
        _vs_set_result fail
    else
        _vs_pass "Runtime User" "${ru}"
        _vs_set_result pass
    fi
    return 0
}

# ── Main verify_stack function ────────────────────────────────

verify_stack() {
    print_section "Stack Health Verification"

    local pass_count=0 warn_count=0 fail_count=0
    local _VS_LAST_RESULT=""

    # Wrapper that tallies semantic results while every verify action still returns 0.
    _vs_run() {
        local fn="$1"
        _VS_LAST_RESULT=""
        "$fn"
        case "${_VS_LAST_RESULT:-warn}" in
            pass) pass_count=$(( pass_count + 1 )) ;;
            warn) warn_count=$(( warn_count + 1 )) ;;
            fail) fail_count=$(( fail_count + 1 )) ;;
            *)    warn_count=$(( warn_count + 1 )) ;;
        esac
        return 0
    }

    _vs_run _vs_check_ssh
    _vs_run _vs_check_ufw
    _vs_run _vs_check_fail2ban
    _vs_run _vs_check_nginx
    _vs_run _vs_check_pm2
    _vs_run _vs_check_runtime_user
    _vs_run _vs_check_cliproxyapi
    _vs_run _vs_check_php_fpm
    _vs_run _vs_check_mariadb
    _vs_run _vs_check_ssl
    _vs_run _vs_check_sysctl_swap
    _vs_run _vs_check_patch_state
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
    return 0   # verify action never exits the menu due to WARN/FAIL counts
}
