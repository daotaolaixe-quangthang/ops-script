#!/usr/bin/env bash
# ============================================================
# ops/modules/setup-wizard.sh
# Purpose:  First-time production setup wizard (orchestrator)
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# Called by bin/ops via menu dispatch.
# Do NOT add set -euo pipefail here — inherited from bin/ops.
#
# Design contract (stable-line setup wizard):
#   − Wizard ONLY orchestrates module functions; no business logic here.
#   − Re-runnable: reads /etc/ops/ops.conf to detect prior runs.
#   − Each step is independently skippable.
#   − Summary screen at end.
#
# Step sequence: system_update → security → nginx → node → php → database → monitoring → verification

# ── Public menu entry ─────────────────────────────────────────
menu_setup_wizard() {
    _setup_wizard_menu_run() {
        "$@"
        return 0
    }

    while true; do
        print_section "Production Setup Wizard"
        echo "  1) Run full production wizard"
        echo "  2) System update & base tools"
        echo "  3) Security baseline (SSH, UFW, fail2ban)"
        echo "  4) Install Nginx"
        echo "  5) Install Node.js LTS & PM2"
        echo "  6) Install PHP (multi-version)"
        echo "  7) Install Database (MariaDB)"
        echo "  8) Install Logging & Monitoring"
        echo "  9) Show setup status"
        echo "  0) Back"
        echo ""
        prompt_menu_choice "Select" "" choice
        case "$choice" in
            1) _setup_wizard_menu_run wizard_run_full ;;
            2) _setup_wizard_menu_run wizard_step_system_update ;;
            3) _setup_wizard_menu_run wizard_step_security ;;
            4) _setup_wizard_menu_run wizard_step_nginx ;;
            5) _setup_wizard_menu_run wizard_step_node ;;
            6) _setup_wizard_menu_run wizard_step_php ;;
            7) _setup_wizard_menu_run wizard_step_database ;;
            8) _setup_wizard_menu_run wizard_step_monitoring ;;
            9) _setup_wizard_menu_run wizard_status ;;
            0) return 0                     ;;
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

# _wizard_clear_done <step_key>
_wizard_clear_done() {
    local key="WIZARD_DONE_${1}"
    ops_conf_set "ops.conf" "$key" "no"
    log_info "Wizard step cleared: $1"
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
        else
            _wizard_clear_done "$step_key"
        fi
    fi
}

# ── Individual step functions (called by wizard_run_full or standalone) ──

# Step 0: System update + base tools
wizard_step_system_update() {
    _wizard_step_header "SYSTEM_UPDATE" "Step 0 — System Update & Base Tools"
    require_root || return 1
    [[ "$WIZARD_SKIP" -eq 1 ]] && return 0

    log_info "Wizard: system update"
    apt_update

    if prompt_confirm "Run apt upgrade now?"; then
        log_info "Wizard: upgrading installed packages"
        apt_upgrade
    else
        print_warn "Skipping apt upgrade for now. Re-run Step 0 later if you want to apply package upgrades."
    fi

    log_info "Wizard: installing base tools"
    apt_install \
        curl wget git unzip ca-certificates gnupg lsb-release \
        software-properties-common apt-transport-https \
        htop iotop net-tools dnsutils jq logrotate ufw fail2ban

    _wizard_mark_done "SYSTEM_UPDATE"
    print_ok "System update & base tools done."
}

# Step 1: Security (SSH port, UFW, fail2ban)
wizard_step_security() {
    _wizard_step_header "SECURITY" "Step 1 — Security Baseline"
    require_root || return 1
    [[ "$WIZARD_SKIP" -eq 1 ]] && return 0

    local step_ok=1

    # Source security module if available
    local sec_mod="${OPS_ROOT:-/opt/ops}/modules/security.sh"
    if [[ -f "$sec_mod" ]]; then
        # shellcheck source=/dev/null
        source "$sec_mod"
    fi

    if declare -f security_wizard_baseline >/dev/null 2>&1; then
        security_wizard_baseline || {
            print_error "Security baseline failed — step will not be marked as done."
            log_info "Wizard: wizard_step_security aborted due to security_wizard_baseline failure"
            return 1
        }
    else
        _wizard_inline_security || return 1
    fi

    # ── Auto-apply non-interactive security baseline ──────────
    # These are idempotent and safe for running production systems.

    # 1. Kernel hardening (sysctl): send_redirects, rp_filter, suid_dumpable.
    # Keep the user-facing behavior warning-only, but fail the step so stale
    # WIZARD_DONE_SECURITY state is not preserved when manual follow-up is needed.
    if declare -f security_apply_sysctl_baseline >/dev/null 2>&1; then
        log_info "Wizard: applying sysctl security baseline..."
        if security_apply_sysctl_baseline; then
            print_ok "Kernel sysctl hardening applied."
        else
            print_warn "Kernel sysctl hardening partially failed (restricted by container / hypervisor)."
            print_warn "Manual sysctl settings may not have been written. Check logs and apply manually if required."
            log_warn "Wizard: security_apply_sysctl_baseline returned non-zero — sysctl hardening may be incomplete"
            step_ok=0
        fi
    fi

    # 2. Strip cloud-init SSH overrides.
    # For port-change path: already called inside security_apply_sshd_hardening
    # (before sshd -t) so one service_restart covers strip + new config atomically.
    # For port-unchanged path: call here; effective on next sshd reload/restart.
    if declare -f security_strip_cloud_init_overrides >/dev/null 2>&1; then
        log_info "Wizard: stripping cloud-init SSH config overrides..."
        if security_strip_cloud_init_overrides; then
            print_ok "Cloud-init SSH overrides stripped."
        else
            print_warn "Could not strip cloud-init SSH overrides automatically."
            print_warn "Check cloud-init SSH snippets before re-running this step."
            log_warn "Wizard: security_strip_cloud_init_overrides returned non-zero"
            step_ok=0
        fi
    fi

    # NOTE: UFW reconciliation and fail2ban config are already handled inside
    # security_wizard_baseline -> security_apply_sshd_hardening ->
    # security_ensure_ssh_transition_ports (when port changes), or directly
    # in security_wizard_baseline when port is unchanged.
    # Do NOT call security_reconcile_ufw_rules a second time here -- it can
    # cause SSH lockout if UFW state changes between the two calls.
    # fail2ban is also reconciled inside security_wizard_baseline already.

    # 3. Swap: always provision swap unconditionally, regardless of SSH port outcome.
    # On VPS with no swap, OOM killer can kill Nginx/MariaDB arbitrarily on memory spikes.
    if declare -f security_ensure_swap >/dev/null 2>&1; then
        log_info "Wizard: provisioning swap file if not present..."
        if security_ensure_swap; then
            print_ok "Swap provisioned (2GB default, vm.swappiness=10)."
        else
            print_warn "Swap provisioning failed — OOM risk on low-memory VPS."
            print_warn "Check available disk space and permissions, then run: Security → Ensure swap."
            log_warn "Wizard: security_ensure_swap returned non-zero — swap may not be active"
            step_ok=0
        fi
    fi

    if (( step_ok == 0 )); then
        print_warn "Security baseline completed with manual follow-up required — step will NOT be marked as done."
        return 1
    fi

    _wizard_mark_done "SECURITY"
    print_ok "Security baseline done."
}

# Inline fallback -- only reached when security_wizard_baseline is not defined.
# The outer check in wizard_step_security already confirmed it is absent,
# so the re-check here was dead code. Simplified to fail fast with clear error.
_wizard_inline_security() {
    print_error "Security module (security.sh) not loaded -- cannot manage SSH transition safely."
    print_warn "Ensure ${OPS_ROOT:-/opt/ops}/modules/security.sh exists and is readable."
    log_info "Wizard: _wizard_inline_security: security module not loaded"
    return 1
}

# Step 2: Nginx
wizard_step_nginx() {
    _wizard_step_header "NGINX" "Step 2 — Nginx Install & Tuning"
    require_root || return 1
    [[ "$WIZARD_SKIP" -eq 1 ]] && return 0

    local nginx_mod="${OPS_ROOT:-/opt/ops}/modules/nginx.sh"
    if [[ -f "$nginx_mod" ]]; then
        # shellcheck source=/dev/null
        source "$nginx_mod"
    fi

    if declare -f nginx_install >/dev/null 2>&1; then
        nginx_install || return 1
    else
        log_info "Wizard: inline nginx install"
        apt_install nginx || return 1
        service_enable nginx || return 1
        service_start nginx || return 1
        print_ok "Nginx installed and started"
    fi

    # Always ensure security tuning is applied, even if nginx was pre-installed.
    if command -v nginx >/dev/null 2>&1 && declare -f _nginx_apply_global_tuning >/dev/null 2>&1; then
        log_info "Wizard: applying nginx security tuning baseline..."
        if ! _nginx_apply_global_tuning; then
            print_error "Nginx tuning failed — step will not be marked as done."
            return 1
        fi
        if ! nginx_validate; then
            print_error "Nginx config test failed after global tuning — NOT reloading."
            print_warn "Check /etc/nginx/nginx.conf before re-running this step."
            log_error "wizard_step_nginx: nginx_validate failed after _nginx_apply_global_tuning"
            return 1
        fi
        if ! service_reload nginx >/dev/null 2>&1; then
            print_error "Nginx reload failed after applying the OPS baseline."
            print_warn "Check 'systemctl status nginx' before re-running this step."
            log_error "wizard_step_nginx: service_reload nginx returned non-zero after tuning"
            return 1
        fi
        print_ok "Nginx security baseline applied (server_tokens off, TLSv1.2+, security headers)."
    fi

    _wizard_mark_done "NGINX"
    print_ok "Nginx step done."
}

# Step 3: Node.js + PM2
wizard_step_node() {
    _wizard_step_header "NODE" "Step 3 — Node.js LTS & PM2"
    require_root || return 1
    [[ "$WIZARD_SKIP" -eq 1 ]] && return 0

    # node.sh is sourced by bin/ops already; call directly
    if declare -f node_install >/dev/null 2>&1; then
        node_install || return 1
        node_install_pm2 || return 1
    else
        local node_mod="${OPS_ROOT:-/opt/ops}/modules/node.sh"
        if [[ -f "$node_mod" ]]; then
            # shellcheck source=/dev/null
            source "$node_mod"
            node_install || return 1
            node_install_pm2 || return 1
        else
            print_warn "node.sh not found — skipping Node step"
            return 1
        fi
    fi

    local saved_runtime_user
    saved_runtime_user="$(ops_conf_get "ops.conf" "OPS_RUNTIME_USER" 2>/dev/null || true)"
    if [[ -z "$saved_runtime_user" ]]; then
        print_error "OPS_RUNTIME_USER was not written after PM2 setup."
        log_error "wizard_step_node: OPS_RUNTIME_USER missing in ops.conf after node_install_pm2"
        return 1
    fi
    if [[ "$saved_runtime_user" == "root" ]]; then
        print_error "OPS_RUNTIME_USER is still set to 'root' after PM2 setup."
        print_error "PM2 and all managed apps would run as root — step will NOT be marked as done."
        log_error "wizard_step_node: OPS_RUNTIME_USER=root in ops.conf after node_install_pm2"
        return 1
    fi

    print_ok "PM2 runtime user: ${saved_runtime_user} (non-root ✓)"
    _wizard_mark_done "NODE"
    print_ok "Node.js & PM2 step done."
}

_wizard_detect_installed_php_versions() {
    local php_ver
    local detected=()

    for php_ver in 7.4 8.1 8.2 8.3; do
        if command -v "php${php_ver}" >/dev/null 2>&1 || \
           systemctl list-unit-files 2>/dev/null | grep -q "^php${php_ver}-fpm\\.service"; then
            detected+=("$php_ver")
        fi
    done

    printf '%s' "${detected[*]:-}"
}

# Step 4: PHP (multi-version)
wizard_step_php() {
    _wizard_step_header "PHP" "Step 4 — PHP (multi-version via ondrej/php)"
    require_root || return 1
    if [[ "$WIZARD_SKIP" -eq 1 ]]; then
        WIZARD_PHP_VERSIONS_LAST_RUN="$(_wizard_detect_installed_php_versions)"
        if [[ -z "$WIZARD_PHP_VERSIONS_LAST_RUN" ]]; then
            print_error "No installed PHP versions were detected even though the PHP wizard step was previously marked done."
            return 1
        fi
        return 0
    fi

    local php_mod="${OPS_ROOT:-/opt/ops}/modules/php.sh"
    local raw_versions seen_versions="" default_php="8.2" ver
    local selected_versions=() versions_to_install=()

    if [[ -f "$php_mod" ]]; then
        # shellcheck source=/dev/null
        source "$php_mod"
    fi

    prompt_input "PHP versions to install (space/comma separated: 7.4 8.1 8.2 8.3)" "8.2"
    raw_versions="${REPLY//,/ }"
    local IFS=' '
    read -r -a selected_versions <<< "$raw_versions"

    for ver in "${selected_versions[@]}"; do
        [[ -z "$ver" ]] && continue
        if declare -f php_is_supported_version >/dev/null 2>&1; then
            if ! php_is_supported_version "$ver"; then
                print_error "Unsupported PHP version: ${ver}. Allowed: 7.4 8.1 8.2 8.3"
                return 1
            fi
        else
            case "$ver" in
                7.4|8.1|8.2|8.3) ;;
                *)
                    print_error "Unsupported PHP version: ${ver}. Allowed: 7.4 8.1 8.2 8.3"
                    return 1
                    ;;
            esac
        fi
        if [[ " $seen_versions " != *" $ver "* ]]; then
            versions_to_install+=("$ver")
            seen_versions+=" $ver"
        fi
    done

    if [[ ${#versions_to_install[@]} -eq 0 ]]; then
        print_error "No valid PHP versions were selected."
        return 1
    fi

    if [[ "$seen_versions" != *" 8.2"* ]]; then
        default_php="${versions_to_install[0]}"
    fi

    if declare -f install_php_version >/dev/null 2>&1; then
        for ver in "${versions_to_install[@]}"; do
            install_php_version "$ver" || return 1
        done
        if declare -f set_php_cli_default >/dev/null 2>&1; then
            set_php_cli_default "$default_php" || return 1
        fi
    else
        log_info "Wizard: inline PHP install (ppa:ondrej/php)"
        add-apt-repository ppa:ondrej/php -y
        apt_update
        local PHP_COMMON_EXTS="cli fpm common mysql curl gd intl mbstring opcache xml zip soap bcmath"
        for ver in "${versions_to_install[@]}"; do
            # shellcheck disable=SC2046
            apt_install $(printf "php${ver}-%s " $PHP_COMMON_EXTS) || return 1
        done
        update-alternatives --set php "/usr/bin/php${default_php}" >/dev/null 2>&1 || true
    fi

    WIZARD_PHP_VERSIONS_LAST_RUN="${versions_to_install[*]}"
    print_ok "Installed PHP versions: ${versions_to_install[*]}"
    print_ok "Default PHP CLI: ${default_php}"
    _wizard_mark_done "PHP"
    print_ok "PHP step done."
}

# Step 5: Database (MariaDB default per spec)
wizard_step_database() {
    _wizard_step_header "DATABASE" "Step 5 — Database (MariaDB)"
    require_root || return 1
    [[ "$WIZARD_SKIP" -eq 1 ]] && return 0

    local db_mod="${OPS_ROOT:-/opt/ops}/modules/database.sh"
    if [[ -f "$db_mod" ]]; then
        # shellcheck source=/dev/null
        source "$db_mod"
        # FIX-02: preinstall rescue-mode check BEFORE attempting install.
        # MariaDB may be pre-installed by cloud provider in --skip-grant-tables state.
        # _db_assert_not_rescue_mode is also called inside install_mariadb() but
        # checking here gives a clearer wizard-level error and prevents mark_done.
        if declare -f _db_assert_not_rescue_mode > /dev/null 2>&1; then
            if ! _db_assert_not_rescue_mode; then
                print_error "MariaDB is in rescue mode (--skip-grant-tables) — aborting DB install."
                print_warn "Fix steps:"
                print_warn "  1. Find PID:    ps -eo pid,args | grep '[m]ariadbd.*--skip-grant'"
                print_warn "  2. Kill it:     kill -9 <PID>"
                print_warn "  3. Start clean: systemctl start mariadb"
                print_warn "  4. Re-run:      Setup Wizard -> Install Database"
                log_error "wizard_step_database: aborted — rescue mode detected before install"
                return 1
            fi
        fi

        if declare -f db_install > /dev/null 2>&1; then
            if ! db_install; then
                print_error "MariaDB install failed — step will NOT be marked as done."
                print_warn "Fix the error above then re-run: Setup Wizard -> Install Database"
                log_error "wizard_step_database: db_install returned non-zero — mark_done skipped"
                return 1
            fi
        fi
    else
        log_info "Wizard: inline MariaDB install"
        apt_install mariadb-server mariadb-client || return 1
        service_enable mariadb || return 1
        service_start mariadb || return 1

        # Secure setup (equivalent to mysql_secure_installation)
        mysql -e "DELETE FROM mysql.user WHERE User='';" 2>/dev/null || true
        mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host != 'localhost';" 2>/dev/null || true
        mysql -e "DROP DATABASE IF EXISTS test;" 2>/dev/null || true
        mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || true

        print_ok "MariaDB installed and secured"
        print_warn "Security hardening (local_infile, SSL, slow_log) not applied in inline mode."
        print_warn "Install ops-script modules and run: Database → Apply tuning"
    fi

    _wizard_mark_done "DATABASE"
    print_ok "Database step done."
}

# Step 6: Logging & basic monitoring
wizard_step_monitoring() {
    _wizard_step_header "MONITORING" "Step 6 — Logging & Basic Monitoring"
    require_root || return 1
    [[ "$WIZARD_SKIP" -eq 1 ]] && return 0

    local monitoring_mod="${OPS_ROOT:-/opt/ops}/modules/monitoring.sh"
    if [[ -f "$monitoring_mod" ]]; then
        # shellcheck source=/dev/null
        source "$monitoring_mod"
    fi

    if declare -f monitoring_apply_baseline >/dev/null 2>&1; then
        monitoring_apply_baseline || return 1
    else
        print_error "monitoring.sh does not expose monitoring_apply_baseline — cannot complete this step safely."
        return 1
    fi

    _wizard_mark_done "MONITORING"
    print_ok "Logging & monitoring step done."
}

_wizard_full_run_succeeded() {
    local -n _res="$1"
    local required_step

    for required_step in system_update security nginx node monitoring verification; do
        [[ "${_res[$required_step]:-FAILED}" == "ok" ]] || return 1
    done
    [[ "${_res[php]:-skipped}" =~ ^(ok|skipped)$ ]] || return 1
    [[ "${_res[database]:-skipped}" =~ ^(ok|skipped)$ ]] || return 1
    return 0
}

_wizard_run_final_verification() {
    local php_versions_csv="${1:-}"
    local expect_database="${2:-no}"
    local ok=1
    local runtime_user=""
    local ops_log="${OPS_LOG_FILE:-/var/log/ops/ops.log}"
    local ops_log_dir
    ops_log_dir="$(dirname "$ops_log")"

    print_section "Step 7 — Final Verification"

    if command -v curl >/dev/null 2>&1 && command -v git >/dev/null 2>&1 \
        && command -v jq >/dev/null 2>&1 && command -v logrotate >/dev/null 2>&1; then
        print_ok "Base tools present (curl, git, jq, logrotate)."
    else
        print_error "Base tools are incomplete. Re-run Step 0 to reconcile system packages."
        ok=0
    fi

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        print_ok "UFW active."
    else
        print_error "UFW is inactive or missing. Re-run Step 1 to restore the firewall baseline."
        ok=0
    fi

    if command -v fail2ban-client >/dev/null 2>&1 && service_active fail2ban 2>/dev/null; then
        print_ok "fail2ban active."
    else
        print_error "fail2ban is inactive or missing. Re-run Step 1 to restore the security baseline."
        ok=0
    fi

    if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1 && service_active nginx 2>/dev/null; then
        print_ok "Nginx active and config valid."
    else
        print_error "Nginx is not healthy. Re-run Step 2 and check nginx -t / systemctl status nginx."
        ok=0
    fi

    runtime_user="$(ops_conf_get "ops.conf" "OPS_RUNTIME_USER" 2>/dev/null || true)"
    if [[ -n "$runtime_user" && "$runtime_user" != "root" ]] \
        && command -v node >/dev/null 2>&1 && command -v pm2 >/dev/null 2>&1 \
        && systemctl list-unit-files 2>/dev/null | grep -q "^pm2-${runtime_user}\\.service" \
        && ops_run_as_user "$runtime_user" pm2 module:list 2>/dev/null | grep -q 'pm2-logrotate'; then
        print_ok "Node.js, PM2, runtime-user startup, and pm2-logrotate are ready."
    else
        print_error "Node.js / PM2 baseline is incomplete. Re-run Step 3 and confirm PM2 startup uses a non-root runtime user."
        ok=0
    fi

    if [[ -n "$php_versions_csv" ]]; then
        local php_ver
        local IFS=' '
        for php_ver in $php_versions_csv; do
            if command -v "php${php_ver}" >/dev/null 2>&1 && service_active "php${php_ver}-fpm" 2>/dev/null; then
                print_ok "PHP ${php_ver}-FPM active."
            else
                print_error "PHP ${php_ver}-FPM is missing or inactive. Re-run Step 4."
                ok=0
            fi
        done
    fi

    if [[ "$expect_database" == "yes" ]]; then
        if service_active mariadb 2>/dev/null || service_active mysql 2>/dev/null; then
            print_ok "Database service active."
        else
            print_error "Database service is inactive. Re-run Step 5."
            ok=0
        fi
    fi

    if command -v logrotate >/dev/null 2>&1 && [[ -d "$ops_log_dir" && -f "$ops_log" && -f /etc/logrotate.d/ops ]]; then
        if command -v nginx >/dev/null 2>&1 && [[ ! -f /etc/logrotate.d/nginx-ops ]]; then
            print_error "Nginx logrotate config is missing. Re-run Step 6 to reconcile monitoring."
            ok=0
        elif systemctl list-unit-files 2>/dev/null | grep -Eq '^php(7\.4|8\.1|8\.2|8\.3)-fpm\.service' \
            && ! compgen -G '/etc/logrotate.d/php*-fpm' >/dev/null; then
            print_error "PHP-FPM logrotate config is missing. Re-run Step 6 to reconcile monitoring."
            ok=0
        else
            print_ok "Monitoring baseline ready (ops.log + logrotate)."
        fi
    else
        print_error "Monitoring baseline is incomplete. Re-run Step 6 to repair logging prerequisites."
        ok=0
    fi

    if (( ok == 1 )); then
        print_ok "Final verification passed."
        return 0
    fi

    print_error "Final verification failed. Review the errors above before treating the wizard as complete."
    return 1
}

# ── Full wizard orchestration ─────────────────────────────────
wizard_run_full() {
    print_section "Full Production Wizard"
    require_root || return 1

    local wizard_php_versions=""
    local wizard_expect_database="no"
    local full_status="FAILED"

    # Re-run guard
    if _wizard_is_done "FULL_WIZARD"; then
        print_warn "Wizard was already completed on this server."
        if ! prompt_confirm "Run again anyway? (individual steps can be skipped)"; then
            return 0
        fi
        _wizard_clear_done "FULL_WIZARD"
        ops_conf_set "ops.conf" "OPS_WIZARD_DATE" ""
    fi

    echo ""
    echo "  This wizard will set up:"
    echo "    0) System update & base tools"
    echo "    1) Security baseline (SSH, UFW, fail2ban)"
    echo "    2) Nginx"
    echo "    3) Node.js LTS + PM2"
    echo "    4) PHP (ondrej/php — multi-version)"
    echo "    5) Database (MariaDB — default)"
    echo "    6) Logging & basic monitoring"
    echo "    7) Final verification"
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
        WIZARD_PHP_VERSIONS_LAST_RUN=""
        if wizard_step_php; then
            STEP_RESULT[php]="ok"
            wizard_php_versions="${WIZARD_PHP_VERSIONS_LAST_RUN:-}"
        else
            STEP_RESULT[php]="FAILED"
            print_warn "PHP step failed — continuing."
        fi
    else
        STEP_RESULT[php]="skipped"
    fi

    # Step 5 (optional prompt)
    if prompt_confirm "Install Database (MariaDB)?"; then
        wizard_expect_database="yes"
        if wizard_step_database; then
            STEP_RESULT[database]="ok"
        else
            STEP_RESULT[database]="FAILED"
            print_warn "Database step failed — continuing."
        fi
    else
        STEP_RESULT[database]="skipped"
    fi

    # Step 6
    if wizard_step_monitoring; then
        STEP_RESULT[monitoring]="ok"
    else
        STEP_RESULT[monitoring]="FAILED"
        print_warn "Logging & monitoring step failed — continuing to final verification."
    fi

    # Step 7
    if _wizard_run_final_verification "$wizard_php_versions" "$wizard_expect_database"; then
        STEP_RESULT[verification]="ok"
    else
        STEP_RESULT[verification]="FAILED"
    fi

    if _wizard_full_run_succeeded STEP_RESULT; then
        _wizard_mark_done "FULL_WIZARD"
        ops_conf_set "ops.conf" "OPS_WIZARD_DATE" "$(date '+%Y-%m-%d %H:%M:%S')"
        full_status="ok"
    else
        print_warn "Full wizard finished with follow-up required — WIZARD_DONE_FULL_WIZARD was not written."
    fi

    # Summary screen
    _wizard_print_summary STEP_RESULT "$full_status"
}

# ── Summary screen ────────────────────────────────────────────
_wizard_print_summary() {
    local -n _res="$1"
    local overall_status="${2:-FAILED}"
    print_section "Wizard Summary"

    local step icon label
    for step in system_update security nginx node php database monitoring verification; do
        local status="${_res[$step]:-unknown}"
        case "$status" in
            ok)      icon="✓"; label="${GRN:-}${status}${RST:-}" ;;
            skipped) icon="–"; label="${YLW:-}skipped${RST:-}"   ;;
            *)       icon="✗"; label="${RED:-}${status}${RST:-}" ;;
        esac
        printf "  %s  %-20s  %b\n" "$icon" "$step" "$label"
    done

    echo ""
    if [[ "$overall_status" == "ok" ]]; then
        echo "  ── Next steps ──────────────────────────────────"
        echo "    • Add Node.js apps     → Main menu → Node.js Services"
        echo "    • Add PHP sites        → Main menu → PHP / PHP-FPM"
        echo "    • Configure domains    → Main menu → Domains & Nginx"
        echo "    • Issue SSL certs      → Main menu → SSL Management"
        echo "    - Deploy CLIProxyAPI   -> Main menu -> CLIProxyAPI Management"
        echo "    • Finalise SSH port    → Main menu → Security (close old SSH port)"
        echo ""
        print_ok "Wizard complete. Server is ready for production setup."
        log_info "wizard_run_full: completed"
    else
        echo "  ── Follow-up ───────────────────────────────────"
        echo "    • Fix the failed steps above"
        echo "    • Re-run the individual wizard steps as needed"
        echo "    • Re-run the full wizard after verification passes"
        echo ""
        print_warn "Wizard finished with follow-up required."
        log_warn "wizard_run_full: finished with follow-up required"
    fi
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
        pm2_online_count=$(ops_pm2_online_count 2>/dev/null || echo "0")
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

    # ── PHP-FPM active versions ──────────────────────────────
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
    local steps=(SYSTEM_UPDATE SECURITY NGINX NODE PHP DATABASE MONITORING FULL_WIZARD)
    local s val icon
    for s in "${steps[@]}"; do
        val=$(ops_conf_get "ops.conf" "WIZARD_DONE_${s}" 2>/dev/null || echo "no")
        icon="✗"
        [[ "$val" == "yes" ]] && icon="✓"
        printf "  %s  %s\n" "$icon" "$s"
    done

    echo ""
    echo "  ── Service Status ────────────────────────────────"
    local svc
    for svc in nginx; do
        if service_active "$svc" 2>/dev/null; then
            print_ok "${svc}: active"
        else
            print_warn "${svc}: inactive / not installed"
        fi
    done
    # P4-5 fix: check both mariadb and mysql — Ubuntu 24.04 may ship MySQL, not MariaDB
    if service_active mariadb 2>/dev/null; then
        print_ok "mariadb: active"
    elif service_active mysql 2>/dev/null; then
        print_ok "mysql: active"
    else
        print_warn "mariadb / mysql: inactive / not installed"
    fi

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
