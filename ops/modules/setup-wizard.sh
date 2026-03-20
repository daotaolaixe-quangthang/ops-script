#!/usr/bin/env bash
# ============================================================
# ops/modules/setup-wizard.sh
# Purpose:  First-time production setup wizard (orchestrator)
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# Called by bin/ops via menu dispatch.
# Do NOT add set -euo pipefail here — inherited from bin/ops.
#
# Design contract (PHASE-01-IMPLEMENTATION-SPEC.md §P1-09):
#   − Wizard ONLY orchestrates module functions; no business logic here.
#   − Re-runnable: reads /etc/ops/ops.conf to detect prior runs.
#   − Each step is independently skippable.
#   − Summary screen at end.
#
# Step sequence: security → nginx → node → php → database → monitoring

# ── Public menu entry ─────────────────────────────────────────
menu_setup_wizard() {
    while true; do
        print_section "Production Setup Wizard"
        echo "  1) Run full production wizard"
        echo "  2) System update & base tools"
        echo "  3) Security baseline (SSH, UFW, fail2ban)"
        echo "  4) Install Nginx"
        echo "  5) Install Node.js LTS & PM2"
        echo "  6) Install PHP (multi-version)"
        echo "  7) Install Database (MariaDB)"
        echo "  8) Show setup status"
        echo "  0) Back"
        echo ""
        read -r -p "Select: " choice
        case "$choice" in
            1) wizard_run_full              ;;
            2) wizard_step_system_update    ;;
            3) wizard_step_security         ;;
            4) wizard_step_nginx            ;;
            5) wizard_step_node             ;;
            6) wizard_step_php              ;;
            7) wizard_step_database         ;;
            8) wizard_status                ;;
            0) return                       ;;
            *) print_warn "Invalid option"  ;;
        esac
    done
}

# ── Re-run detection helpers ──────────────────────────────────

# _wizard_is_done <step_key>
# Returns 0 if step was already recorded as done in /etc/ops/ops.conf
_wizard_is_done() {
    local key="WIZARD_DONE_${1}"
    local val
    val=$(ops_conf_get "ops.conf" "$key" 2>/dev/null || true)
    [[ "$val" == "yes" ]]
}

# _wizard_mark_done <step_key>
_wizard_mark_done() {
    local key="WIZARD_DONE_${1}"
    ops_conf_set "ops.conf" "$key" "yes"
    log_info "Wizard step done: $1"
}

# _wizard_step_header <step_key> <title>
# Prints step header; if already done offers to skip.
# Sets WIZARD_SKIP=1 if operator chooses to skip.
_wizard_step_header() {
    local step_key="$1"
    local title="$2"
    WIZARD_SKIP=0
    echo ""
    echo -e "  ──────────────────────────────────────────────"
    print_section "$title"
    if _wizard_is_done "$step_key"; then
        print_ok "This step was already completed."
        if ! prompt_confirm "Re-run anyway?"; then
            WIZARD_SKIP=1
        fi
    fi
}

# ── Individual step functions (called by wizard_run_full or standalone) ──

# Step 0: System update + base tools
wizard_step_system_update() {
    _wizard_step_header "SYSTEM_UPDATE" "Step 0 — System Update & Base Tools"
    [[ "$WIZARD_SKIP" -eq 1 ]] && return 0

    log_info "Wizard: system update"
    apt_update

    log_info "Wizard: installing base tools"
    apt_install \
        curl wget git unzip ca-certificates gnupg lsb-release \
        software-properties-common apt-transport-https \
        htop iotop net-tools dnsutils ufw fail2ban

    _wizard_mark_done "SYSTEM_UPDATE"
    print_ok "System update & base tools done."
}

# Step 1: Security (SSH port, UFW, fail2ban)
wizard_step_security() {
    _wizard_step_header "SECURITY" "Step 1 — Security Baseline"
    [[ "$WIZARD_SKIP" -eq 1 ]] && return 0

    # Source security module if available
    local sec_mod="${OPS_ROOT:-/opt/ops}/modules/security.sh"
    if [[ -f "$sec_mod" ]]; then
        # shellcheck source=/dev/null
        source "$sec_mod"
    fi

    if declare -f security_wizard_baseline >/dev/null 2>&1; then
        security_wizard_baseline
    else
        _wizard_inline_security
    fi

    # ── Auto-apply non-interactive security baseline ──────────
    # These are idempotent and safe for running production systems.

    # 1. Kernel hardening (sysctl): send_redirects, rp_filter, suid_dumpable
    if declare -f security_apply_sysctl_baseline >/dev/null 2>&1; then
        log_info "Wizard: applying sysctl security baseline..."
        security_apply_sysctl_baseline
        print_ok "Kernel sysctl hardening applied."
    fi

    # 2. Strip cloud-init SSH overrides (idempotent)
    if declare -f security_strip_cloud_init_overrides >/dev/null 2>&1; then
        log_info "Wizard: stripping cloud-init SSH config overrides..."
        security_strip_cloud_init_overrides
    fi

    # 3. fail2ban: rewrite config with current live SSH ports + nginx jails
    if declare -f security_write_fail2ban_config >/dev/null 2>&1; then
        if command -v fail2ban-client >/dev/null 2>&1; then
            log_info "Wizard: reconciling fail2ban config..."
            security_write_fail2ban_config
            systemctl reload fail2ban >/dev/null 2>&1 || systemctl restart fail2ban >/dev/null 2>&1 || true
            print_ok "fail2ban config reconciled (SSH ports + nginx jails)."
        fi
    fi

    # 4. UFW: remove stale SSH port rules left from previous installs
    if declare -f security_reconcile_ufw_rules >/dev/null 2>&1; then
        log_info "Wizard: reconciling UFW rules (removing stale SSH ports)..."
        security_reconcile_ufw_rules
        print_ok "UFW rules reconciled."
    fi

    _wizard_mark_done "SECURITY"
    print_ok "Security baseline done."
}

# Inline fallback if security module not loaded
_wizard_inline_security() {
    log_info "Wizard: inline security baseline"

    if declare -f security_wizard_baseline >/dev/null 2>&1; then
        security_wizard_baseline
        return $?
    fi

    print_error "Security module baseline is unavailable; cannot safely manage SSH transition inline."
    return 1
}

# Step 2: Nginx
wizard_step_nginx() {
    _wizard_step_header "NGINX" "Step 2 — Nginx Install & Tuning"
    [[ "$WIZARD_SKIP" -eq 1 ]] && return 0

    local nginx_mod="${OPS_ROOT:-/opt/ops}/modules/nginx.sh"
    if [[ -f "$nginx_mod" ]]; then
        # shellcheck source=/dev/null
        source "$nginx_mod"
    fi

    if declare -f nginx_install >/dev/null 2>&1; then
        nginx_install
    else
        log_info "Wizard: inline nginx install"
        apt_install nginx
        service_enable nginx
        service_start nginx
        print_ok "Nginx installed and started"
    fi

    # Always ensure security tuning is applied, even if nginx was pre-installed.
    # _nginx_apply_global_tuning is idempotent: sets server_tokens off,
    # TLSv1.2+, security headers. nginx -t + reload only if needed.
    if command -v nginx >/dev/null 2>&1; then
        if declare -f _nginx_apply_global_tuning >/dev/null 2>&1; then
            log_info "Wizard: applying nginx security tuning baseline..."
            _nginx_apply_global_tuning
            nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
            print_ok "Nginx security baseline applied (server_tokens off, TLSv1.2+, security headers)."
        fi
    fi

    _wizard_mark_done "NGINX"
    print_ok "Nginx step done."
}

# Step 3: Node.js + PM2
wizard_step_node() {
    _wizard_step_header "NODE" "Step 3 — Node.js LTS & PM2"
    [[ "$WIZARD_SKIP" -eq 1 ]] && return 0

    # node.sh is sourced by bin/ops already; call directly
    if declare -f node_install >/dev/null 2>&1; then
        node_install
        node_install_pm2
    else
        local node_mod="${OPS_ROOT:-/opt/ops}/modules/node.sh"
        if [[ -f "$node_mod" ]]; then
            # shellcheck source=/dev/null
            source "$node_mod"
            node_install
            node_install_pm2
        else
            print_warn "node.sh not found — skipping Node step"
            return 1
        fi
    fi

    _wizard_mark_done "NODE"
    print_ok "Node.js & PM2 step done."
}

# Step 4: PHP (multi-version)
wizard_step_php() {
    _wizard_step_header "PHP" "Step 4 — PHP (multi-version via ondrej/php)"
    [[ "$WIZARD_SKIP" -eq 1 ]] && return 0

    local php_mod="${OPS_ROOT:-/opt/ops}/modules/php.sh"
    if [[ -f "$php_mod" ]]; then
        # shellcheck source=/dev/null
        source "$php_mod"
        # install_php_version is the correct function (not php_install)
        if declare -f install_php_version >/dev/null 2>&1; then
            install_php_version "8.2"
            # Set php 8.2 as default CLI so 'command -v php' works
            if declare -f set_php_cli_default > /dev/null 2>&1; then
                set_php_cli_default "8.2" || true
            fi
        fi
    else
        log_info "Wizard: inline PHP install (ppa:ondrej/php)"
        add-apt-repository ppa:ondrej/php -y
        apt_update
        # Default: install 8.2 baseline
        local PHP_COMMON_EXTS="cli fpm common mysql curl gd intl mbstring opcache xml zip soap bcmath"
        for ver in 8.2; do
            # shellcheck disable=SC2046
            apt_install $(printf "php${ver}-%s " $PHP_COMMON_EXTS)
        done
        print_ok "PHP 8.2 installed"
    fi

    _wizard_mark_done "PHP"
    print_ok "PHP step done."
}

# Step 5: Database (MariaDB default per spec)
wizard_step_database() {
    _wizard_step_header "DATABASE" "Step 5 — Database (MariaDB)"
    [[ "$WIZARD_SKIP" -eq 1 ]] && return 0

    local db_mod="${OPS_ROOT:-/opt/ops}/modules/database.sh"
    if [[ -f "$db_mod" ]]; then
        # shellcheck source=/dev/null
        source "$db_mod"
        if declare -f db_install >/dev/null 2>&1; then
            db_install
        fi
    else
        log_info "Wizard: inline MariaDB install"
        apt_install mariadb-server mariadb-client
        service_enable mariadb
        service_start mariadb

        # Secure setup (equivalent to mysql_secure_installation)
        mysql -e "DELETE FROM mysql.user WHERE User='';" 2>/dev/null || true
        mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host != 'localhost';" 2>/dev/null || true
        mysql -e "DROP DATABASE IF EXISTS test;" 2>/dev/null || true
        mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || true

        print_ok "MariaDB installed and secured"
    fi

    _wizard_mark_done "DATABASE"
    print_ok "Database step done."
}

# ── Full wizard orchestration ─────────────────────────────────
wizard_run_full() {
    print_section "Full Production Wizard"

    # Re-run guard
    if _wizard_is_done "FULL_WIZARD"; then
        print_warn "Wizard was already completed on this server."
        if ! prompt_confirm "Run again anyway? (individual steps can be skipped)"; then
            return 0
        fi
    fi

    echo ""
    echo "  This wizard will set up:"
    echo "    0) System update & base tools"
    echo "    1) Security baseline (SSH, UFW, fail2ban)"
    echo "    2) Nginx"
    echo "    3) Node.js LTS + PM2"
    echo "    4) PHP (ondrej/php — multi-version)"
    echo "    5) Database (MariaDB — default)"
    echo ""
    print_warn "Each step will ask for confirmation if already done."
    if ! prompt_confirm "Start full wizard?"; then
        return 0
    fi

    # Track which steps pass
    declare -A STEP_RESULT

    # Step 0
    if wizard_step_system_update; then
        STEP_RESULT[system_update]="ok"
    else
        STEP_RESULT[system_update]="FAILED"
        print_error "System update failed — aborting wizard."
        return 1
    fi

    # Step 1
    if wizard_step_security; then
        STEP_RESULT[security]="ok"
    else
        STEP_RESULT[security]="FAILED"
        print_warn "Security step failed — continuing with caution."
    fi

    # Step 2
    if wizard_step_nginx; then
        STEP_RESULT[nginx]="ok"
    else
        STEP_RESULT[nginx]="FAILED"
        print_warn "Nginx step failed — continuing."
    fi

    # Step 3
    if wizard_step_node; then
        STEP_RESULT[node]="ok"
    else
        STEP_RESULT[node]="FAILED"
        print_warn "Node.js step failed — continuing."
    fi

    # Step 4 (optional prompt)
    if prompt_confirm "Install PHP? (skip if not needed)"; then
        if wizard_step_php; then
            STEP_RESULT[php]="ok"
        else
            STEP_RESULT[php]="FAILED"
            print_warn "PHP step failed — continuing."
        fi
    else
        STEP_RESULT[php]="skipped"
    fi

    # Step 5 (optional prompt)
    if prompt_confirm "Install Database (MariaDB)?"; then
        if wizard_step_database; then
            STEP_RESULT[database]="ok"
        else
            STEP_RESULT[database]="FAILED"
            print_warn "Database step failed — continuing."
        fi
    else
        STEP_RESULT[database]="skipped"
    fi

    # Mark full wizard complete
    _wizard_mark_done "FULL_WIZARD"
    ops_conf_set "ops.conf" "OPS_WIZARD_DATE" "$(date '+%Y-%m-%d %H:%M:%S')"

    # Summary screen
    _wizard_print_summary STEP_RESULT
}

# ── Summary screen ────────────────────────────────────────────
_wizard_print_summary() {
    local -n _res="$1"
    print_section "Wizard Summary"

    local step icon label
    for step in system_update security nginx node php database; do
        local status="${_res[$step]:-unknown}"
        case "$status" in
            ok)      icon="✓"; label="${GRN:-}${status}${RST:-}" ;;
            skipped) icon="–"; label="${YLW:-}skipped${RST:-}"   ;;
            *)       icon="✗"; label="${RED:-}${status}${RST:-}" ;;
        esac
        printf "  %s  %-20s  %b\n" "$icon" "$step" "$label"
    done

    echo ""
    echo "  ── Next steps ──────────────────────────────────"
    echo "    • Add Node.js apps     → Main menu → Node.js Services"
    echo "    • Add PHP sites        → Main menu → PHP / PHP-FPM"
    echo "    • Configure domains    → Main menu → Domains & Nginx"
    echo "    • Issue SSL certs      → Main menu → SSL Management"
    echo "    • Deploy 9router       → Main menu → 9router Management"
    echo "    • Finalise SSH port    → Main menu → Security (close old SSH port)"
    echo ""
    print_ok "Wizard complete. Server is ready for production setup."
    log_info "wizard_run_full: completed"
}

# ── Status screen ─────────────────────────────────────────────
_wizard_detect_ssh_port() {
    local ssh_port=""

    ssh_port="$(ops_conf_get "ops.conf" "OPS_SSH_PORT" 2>/dev/null || true)"
    if [[ -n "$ssh_port" ]]; then
        echo "$ssh_port"
        return 0
    fi

    if declare -f security_get_current_ssh_port >/dev/null 2>&1; then
        ssh_port="$(security_get_current_ssh_port 2>/dev/null || true)"
    else
        ssh_port="$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' || true)"
        if [[ -z "$ssh_port" && -f /etc/ssh/sshd_config ]]; then
            ssh_port=$(awk '
                BEGIN { p="" }
                /^[[:space:]]*#/ { next }
                tolower($1) == "port" { p=$2; print p; exit }
            ' /etc/ssh/sshd_config 2>/dev/null || true)
        fi
    fi

    echo "${ssh_port:-22}"
}

_wizard_tier_capacity_text() {
    case "${OPS_TIER:-unknown}" in
        S) echo "small VPS profile (~1-5 websites, ~20-100 concurrent users est.)" ;;
        M) echo "medium VPS profile (~5-15 websites, ~100-300 concurrent users est.)" ;;
        L) echo "large VPS profile (~15-40 websites, ~300-1500 concurrent users est.)" ;;
        *) echo "unknown capacity profile" ;;
    esac
}

_wizard_print_wrapped_csv() {
    local label="$1"
    local text="$2"
    local width=54
    local first=1

    if [[ -z "$text" ]]; then
        printf "  %-22s  %s\n" "$label" "none"
        return 0
    fi

    while [[ -n "$text" ]]; do
        local chunk="$text"
        if (( ${#chunk} > width )); then
            chunk="${text:0:width}"
            if [[ "$text" == *,* && "$chunk" != *, ]]; then
                chunk="${chunk%,*}"
            fi
            [[ -z "$chunk" ]] && chunk="${text:0:width}"
        fi

        if (( first == 1 )); then
            printf "  %-22s  %s\n" "$label" "$chunk"
            first=0
        else
            printf "  %-22s  %s\n" "" "$chunk"
        fi

        text="${text#"$chunk"}"
        text="${text#, }"
    done
}

wizard_status() {
    print_section "Setup Status"

    # Load ops.conf if present
    ops_load_conf "ops.conf" 2>/dev/null || true

    local ssh_port tier_text runtime_user pm2_online_count
    local managed_domains=0 node_sites=0 php_sites=0 static_sites=0
    local node_apps=0 php_pools=0 ssl_active=0
    local node_domains_csv=""
    local state_file domain backend_type
    local php_ver active_php_versions=()

    ssh_port="$(_wizard_detect_ssh_port)"
    tier_text="$(_wizard_tier_capacity_text)"
    runtime_user="$(ops_conf_get "ops.conf" "OPS_RUNTIME_USER" 2>/dev/null || true)"
    [[ -z "$runtime_user" ]] && runtime_user="${OPS_ADMIN_USER:-${ADMIN_USER:-unknown}}"

    if [[ -d /etc/ops/domains ]]; then
        for state_file in /etc/ops/domains/*.conf; do
            [[ -f "$state_file" ]] || continue
            ((managed_domains++))
            domain=$(grep '^DOMAIN=' "$state_file" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
            backend_type=$(grep '^DOMAIN_BACKEND_TYPE=' "$state_file" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
            case "$backend_type" in
                node)
                    ((node_sites++))
                    if [[ -n "$domain" ]]; then
                        if [[ -n "$node_domains_csv" ]]; then
                            node_domains_csv+=", "
                        fi
                        node_domains_csv+="$domain"
                    fi
                    ;;
                php) ((php_sites++)) ;;
                static) ((static_sites++)) ;;
            esac
        done
    fi

    if [[ -d /etc/ops/apps ]]; then
        for state_file in /etc/ops/apps/*.conf; do
            [[ -f "$state_file" ]] || continue
            ((node_apps++))
        done
    fi

    if [[ -d /etc/ops/php-sites ]]; then
        for state_file in /etc/ops/php-sites/*.conf; do
            [[ -f "$state_file" ]] || continue
            ((php_pools++))
        done
    fi

    if [[ -d /etc/letsencrypt/live ]]; then
        for state_file in /etc/letsencrypt/live/*; do
            [[ -d "$state_file" ]] || continue
            [[ "$(basename "$state_file")" == "README" ]] && continue
            ((ssl_active++))
        done
    fi

    pm2_online_count="0"
    if command -v pm2 >/dev/null 2>&1; then
        pm2_online_count=$(pm2 jlist 2>/dev/null | python3 -c '
import sys, json
try:
    procs = json.load(sys.stdin)
    print(sum(1 for p in procs if p.get("pm2_env", {}).get("status") == "online"))
except Exception:
    print(0)
' 2>/dev/null || echo "0")
    [[ -z "$pm2_online_count" ]] && pm2_online_count="0"
    [[ ! "$pm2_online_count" =~ ^[0-9]+$ ]] && pm2_online_count="0"
    print_ok "pm2: installed ($(pm2 --version 2>/dev/null))"
    print_ok "pm2 online apps: ${pm2_online_count}"
    if [[ "$node_apps" -gt 0 ]]; then
        print_ok "node registry apps: ${node_apps}"
    fi
    if [[ "$node_sites" -gt 0 ]]; then
        print_ok "node managed sites: ${node_sites}"
    fi
    if [[ "$pm2_online_count" -ne "$node_sites" ]]; then
        print_warn "pm2 online app count may differ from node site count (one app can serve multiple domains)."
    fi
    echo ""
fi

    for php_ver in 7.4 8.1 8.2 8.3; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^php${php_ver}-fpm\\.service"; then
            if service_active "php${php_ver}-fpm" 2>/dev/null; then
                active_php_versions+=("${php_ver}")
            fi
        fi
    done

    echo "  ── OPS Installation ──────────────────────────────"
    printf "  %-22s  %s\n" "OPS version"       "${OPS_VERSION:-unknown}"
    printf "  %-22s  %s\n" "Install date"      "${OPS_INSTALL_DATE:-unknown}"
    printf "  %-22s  %s\n" "Wizard date"       "${OPS_WIZARD_DATE:-not run}"
    printf "  %-22s  %s\n" "SSH port"          "$ssh_port"
    printf "  %-22s  %s\n" "Admin user"        "${OPS_ADMIN_USER:-${ADMIN_USER:-unknown}}"
    printf "  %-22s  %s\n" "Runtime user"      "$runtime_user"
    printf "  %-22s  %s\n" "Tier"              "${OPS_TIER:-unknown}"
    printf "  %-22s  %s\n" "Tier capacity"     "$tier_text"

    echo ""
    echo "  ── Managed Web Stack ─────────────────────────────"
    printf "  %-22s  %s\n" "Managed domains"   "$managed_domains"
    printf "  %-22s  %s\n" "SSL active"        "$ssl_active"
    printf "  %-22s  %s\n" "Node.js sites"     "$node_sites"
    printf "  %-22s  %s\n" "Node.js apps"      "$node_apps"
    printf "  %-22s  %s\n" "PHP sites"         "$php_sites"
    printf "  %-22s  %s\n" "PHP pools"         "$php_pools"
    printf "  %-22s  %s\n" "Static sites"      "$static_sites"
    _wizard_print_wrapped_csv "Node.js domains" "$node_domains_csv"

    echo ""
    echo "  ── Wizard Steps ──────────────────────────────────"
    local steps=(SYSTEM_UPDATE SECURITY NGINX NODE PHP DATABASE FULL_WIZARD)
    local s val icon
    for s in "${steps[@]}"; do
        val=$(ops_conf_get "ops.conf" "WIZARD_DONE_${s}" 2>/dev/null || echo "no")
        icon="✗"
        [[ "$val" == "yes" ]] && icon="✓"
        printf "  %s  %s\n" "$icon" "$s"
    done

    echo ""
    echo "  ── Service Status ────────────────────────────────"
    local services=(nginx mariadb)
    local svc
    for svc in "${services[@]}"; do
        if service_active "$svc" 2>/dev/null; then
            print_ok "${svc}: active"
        else
            print_warn "${svc}: inactive / not installed"
        fi
    done

    if command -v node >/dev/null 2>&1; then
        print_ok "node: $(node --version)"
    else
        print_warn "node: not installed"
    fi

    if command -v php >/dev/null 2>&1; then
        print_ok "php (CLI default): $(php --version | head -n1)"
        if [[ ${#active_php_versions[@]} -gt 0 ]]; then
            print_ok "php-fpm active: ${active_php_versions[*]}"
        else
            print_warn "php-fpm active: none"
        fi
    else
        print_warn "php: not installed"
    fi

    echo ""
}
