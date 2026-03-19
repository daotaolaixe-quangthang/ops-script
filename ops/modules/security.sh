#!/usr/bin/env bash
# ============================================================
# ops/modules/security.sh
# Purpose:  SSH hardening, firewall, fail2ban management
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# Called by bin/ops via menu dispatch.
# Do NOT add set -euo pipefail here — inherited from bin/ops.

SECURITY_SSHD_CONFIG="/etc/ssh/sshd_config"
SECURITY_SSHD_INCLUDE_DIR="/etc/ssh/sshd_config.d"
SECURITY_SSHD_OPS_INCLUDE="${SECURITY_SSHD_INCLUDE_DIR}/99-ops-hardening.conf"
SECURITY_FAIL2BAN_JAIL_LOCAL="/etc/fail2ban/jail.local"
SECURITY_FAIL2BAN_JAIL_OPS="/etc/fail2ban/jail.d/ops-sshd.local"
SECURITY_SYSCTL_OPS_CONF="/etc/sysctl.d/99-ops-hardening.conf"
SECURITY_SWAP_FILE="/swapfile"

security_require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        print_error "This action requires root privileges (run OPS with sudo/root)."
        return 1
    fi
}

security_detect_ssh_service() {
    if systemctl list-unit-files | grep -q '^ssh\.service'; then
        echo "ssh"
    else
        echo "sshd"
    fi
}

security_get_current_ssh_port() {
    local port
    port=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' || true)

    if [[ -z "$port" ]]; then
        port=$(awk '
            BEGIN { p="" }
            /^[[:space:]]*#/ { next }
            tolower($1) == "port" { p=$2; print p; exit }
        ' "$SECURITY_SSHD_CONFIG" 2>/dev/null || true)
    fi

    if [[ -z "$port" ]]; then
        echo "22"
    else
        echo "$port"
    fi
}

security_get_server_ip() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    echo "${ip:-<SERVER_IP_OR_HOSTNAME>}"
}

security_get_admin_user() {
    local admin
    admin=$(ops_conf_get "ops.conf" "OPS_ADMIN_USER" || true)
    if [[ -z "$admin" ]]; then
        admin="${ADMIN_USER:-${SUDO_USER:-admin}}"
    fi
    echo "$admin"
}

security_validate_ssh_port() {
    local port="$1"

    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        print_error "SSH port must be numeric."
        return 1
    fi

    if (( port < 1 || port > 65535 )); then
        print_error "SSH port must be between 1 and 65535."
        return 1
    fi

    if (( port == 20128 )); then
        print_error "Port 20128 is forbidden (reserved security constraint for 9router hardening)."
        return 1
    fi
}

security_set_sshd_option() {
    local key="$1"
    local value="$2"
    local file="$3"

    if grep -Eq "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+" "$file"; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+.*|${key} ${value}|" "$file"
    else
        echo "${key} ${value}" >> "$file"
    fi
}

security_get_transition_port() {
    ops_conf_get "ops.conf" "OPS_SSH_TRANSITION_PORT" 2>/dev/null || true
}

security_get_locked_ssh_port() {
    local port
    port=$(ops_conf_get "ops.conf" "OPS_SSH_PORT" 2>/dev/null || true)
    echo "${port:-$(security_get_current_ssh_port)}"
}

security_get_runtime_user() {
    local runtime_user
    runtime_user=$(ops_conf_get "ops.conf" "OPS_RUNTIME_USER" 2>/dev/null || true)
    if [[ -z "$runtime_user" ]]; then
        runtime_user="$(security_get_admin_user)"
    fi
    echo "$runtime_user"
}

security_normalize_script_permissions() {
    if [[ -d "${OPS_ROOT}/modules" ]]; then
        find "${OPS_ROOT}" -type f -name '*.sh' -exec chmod 755 {} + 2>/dev/null || true
    fi
}

security_wizard_baseline() {
    print_section "Security Baseline"
    security_require_root || return 1

    local current_port new_port password_auth
    current_port="$(security_get_current_ssh_port)"

    print_warn "Current SSH port detected: ${current_port}"
    print_warn "OPS will keep the current SSH port open during transition until login on the new port is verified."

    prompt_input "New SSH port (keep blank to leave as ${current_port})" "$current_port"
    new_port="$REPLY"
    security_validate_ssh_port "$new_port" || return 1

    if prompt_confirm "Disable PasswordAuthentication after transition completes?"; then
        password_auth="no"
    else
        password_auth="yes"
    fi

    if [[ "$new_port" != "$current_port" ]]; then
        security_apply_sshd_hardening "$new_port" "$password_auth" || return 1
        print_warn "Open a NEW terminal and verify SSH on port ${new_port} before you finalize and remove old port ${current_port}."
    else
        ops_conf_set "ops.conf" "OPS_SSH_PORT" "$current_port"
        ops_conf_set "ops.conf" "OPS_SSH_TRANSITION_PORT" ""
        ops_conf_set "ops.conf" "OPS_SSH_PASSWORD_AUTH" "$password_auth"
        security_reconcile_ufw_rules
        security_write_fail2ban_config
        service_enable fail2ban >/dev/null 2>&1 || true
        service_restart fail2ban >/dev/null 2>&1 || true
        print_ok "SSH port unchanged; managed firewall and fail2ban baseline reconciled."
    fi

    security_status
}

security_write_sshd_hardening_include() {
    local locked_port="$1"
    local password_auth="$2"
    local transition_port="${3:-}"

    ensure_dir "$SECURITY_SSHD_INCLUDE_DIR"
    backup_file "$SECURITY_SSHD_OPS_INCLUDE" >/dev/null 2>&1 || true
    write_file "$SECURITY_SSHD_OPS_INCLUDE" <<EOF_SSH_OPS
# Managed by OPS — do not edit manually.
PermitRootLogin no
PasswordAuthentication ${password_auth}
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
AllowStreamLocalForwarding no
PermitTunnel no
ClientAliveInterval 300
ClientAliveCountMax 2
Port ${locked_port}
EOF_SSH_OPS

    if [[ -n "$transition_port" && "$transition_port" != "$locked_port" ]]; then
        printf 'Port %s\n' "$transition_port" >> "$SECURITY_SSHD_OPS_INCLUDE"
    fi

    chmod 644 "$SECURITY_SSHD_OPS_INCLUDE"
}

security_reconcile_sshd_main_config() {
    backup_file "$SECURITY_SSHD_CONFIG" >/dev/null 2>&1 || true

    security_set_sshd_option "Include" "${SECURITY_SSHD_INCLUDE_DIR}/*.conf" "$SECURITY_SSHD_CONFIG"
    security_set_sshd_option "PermitRootLogin" "no" "$SECURITY_SSHD_CONFIG"
    security_set_sshd_option "PasswordAuthentication" "no" "$SECURITY_SSHD_CONFIG"
    security_set_sshd_option "KbdInteractiveAuthentication" "no" "$SECURITY_SSHD_CONFIG"
    security_set_sshd_option "ChallengeResponseAuthentication" "no" "$SECURITY_SSHD_CONFIG"
    security_set_sshd_option "PubkeyAuthentication" "yes" "$SECURITY_SSHD_CONFIG"
    security_set_sshd_option "X11Forwarding" "no" "$SECURITY_SSHD_CONFIG"
    security_set_sshd_option "AllowTcpForwarding" "no" "$SECURITY_SSHD_CONFIG"
    security_set_sshd_option "AllowAgentForwarding" "no" "$SECURITY_SSHD_CONFIG"
    security_set_sshd_option "AllowStreamLocalForwarding" "no" "$SECURITY_SSHD_CONFIG"
    security_set_sshd_option "PermitTunnel" "no" "$SECURITY_SSHD_CONFIG"

    if [[ -d "$SECURITY_SSHD_INCLUDE_DIR" ]]; then
        find "$SECURITY_SSHD_INCLUDE_DIR" -maxdepth 1 -type f ! -name '99-ops-hardening.conf' -print0 2>/dev/null | while IFS= read -r -d '' include_file; do
            if grep -Eq '^[[:space:]]*(PasswordAuthentication|PermitRootLogin|Port|X11Forwarding|AllowTcpForwarding|AllowAgentForwarding|AllowStreamLocalForwarding|PermitTunnel)[[:space:]]+' "$include_file"; then
                backup_file "$include_file" >/dev/null 2>&1 || true
                sed -i -E '/^[[:space:]]*(PasswordAuthentication|PermitRootLogin|Port|X11Forwarding|AllowTcpForwarding|AllowAgentForwarding|AllowStreamLocalForwarding|PermitTunnel)[[:space:]]+/d' "$include_file"
            fi
        done
    fi
}

security_list_desired_ssh_ports() {
    local locked_port transition_port
    locked_port="$(security_get_locked_ssh_port)"
    transition_port="$(security_get_transition_port)"

    printf '%s\n' "$locked_port"
    if [[ -n "$transition_port" && "$transition_port" != "$locked_port" ]]; then
        printf '%s\n' "$transition_port"
    fi
}

security_reconcile_ufw_rules() {
    local desired_ports=()
    local port status_output existing_ssh_ports=()

    if ! command -v ufw >/dev/null 2>&1; then
        apt_install ufw
    fi

    while IFS= read -r port; do
        [[ -n "$port" ]] && desired_ports+=("$port")
    done < <(security_list_desired_ssh_ports)

    ufw default deny incoming
    ufw default allow outgoing

    for port in "${desired_ports[@]}"; do
        ufw allow "${port}/tcp" comment "ops: SSH managed" >/dev/null 2>&1 || true
    done
    ufw allow 80/tcp comment "ops: HTTP" >/dev/null 2>&1 || true
    ufw allow 443/tcp comment "ops: HTTPS" >/dev/null 2>&1 || true

    status_output="$(ufw status 2>/dev/null || true)"
    while IFS= read -r port; do
        [[ -n "$port" ]] && existing_ssh_ports+=("$port")
    done < <(printf '%s\n' "$status_output" | awk '/\/tcp/ && /ALLOW/ {print $1}' | cut -d/ -f1 | grep -E '^[0-9]+$' | sort -u)

    for port in "${existing_ssh_ports[@]}"; do
        local keep=0
        if [[ "$port" == "80" || "$port" == "443" || "$port" == "20128" ]]; then
            continue
        fi
        for desired in "${desired_ports[@]}"; do
            if [[ "$desired" == "$port" ]]; then
                keep=1
                break
            fi
        done
        if [[ "$keep" -eq 0 ]]; then
            ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
        fi
    done

    ufw delete allow 20128/tcp >/dev/null 2>&1 || true
    ufw deny 20128/tcp >/dev/null 2>&1 || true
    ufw --force enable >/dev/null 2>&1 || true
    ufw reload >/dev/null 2>&1 || true
}

security_write_fail2ban_config() {
    local ssh_ports
    ssh_ports=$(security_list_desired_ssh_ports | paste -sd, -)
    ensure_dir "/etc/fail2ban/jail.d"
    backup_file "$SECURITY_FAIL2BAN_JAIL_OPS" >/dev/null 2>&1 || true
    write_file "$SECURITY_FAIL2BAN_JAIL_OPS" <<EOF_JAIL
[DEFAULT]
bantime = 1d
findtime = 10m
maxretry = 3
backend = systemd

[sshd]
enabled = true
port = ${ssh_ports}
logpath = %(sshd_log)s

[nginx-http-auth]
enabled = true

[nginx-badbots]
enabled = true
EOF_JAIL
    chmod 644 "$SECURITY_FAIL2BAN_JAIL_OPS"
}

security_apply_sysctl_baseline() {
    backup_file "$SECURITY_SYSCTL_OPS_CONF" >/dev/null 2>&1 || true
    write_file "$SECURITY_SYSCTL_OPS_CONF" <<EOF_SYSCTL
# Managed by OPS — do not edit manually.
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
vm.swappiness = 10
EOF_SYSCTL
    chmod 644 "$SECURITY_SYSCTL_OPS_CONF"
    sysctl -p "$SECURITY_SYSCTL_OPS_CONF" >/dev/null 2>&1 || true
}

security_ensure_swap() {
    local desired_size_mb
    desired_size_mb=$(ops_conf_get "ops.conf" "OPS_SWAP_MB" 2>/dev/null || true)
    desired_size_mb="${desired_size_mb:-2048}"

    if swapon --show 2>/dev/null | grep -q "${SECURITY_SWAP_FILE}"; then
        return 0
    fi

    if [[ -f "$SECURITY_SWAP_FILE" ]]; then
        chmod 600 "$SECURITY_SWAP_FILE"
    else
        fallocate -l "${desired_size_mb}M" "$SECURITY_SWAP_FILE" 2>/dev/null || dd if=/dev/zero of="$SECURITY_SWAP_FILE" bs=1M count="$desired_size_mb"
        chmod 600 "$SECURITY_SWAP_FILE"
        mkswap "$SECURITY_SWAP_FILE" >/dev/null 2>&1
    fi

    swapon "$SECURITY_SWAP_FILE" >/dev/null 2>&1 || true
    if ! grep -qF "${SECURITY_SWAP_FILE} none swap sw 0 0" /etc/fstab 2>/dev/null; then
        printf '%s none swap sw 0 0\n' "$SECURITY_SWAP_FILE" >> /etc/fstab
    fi
}

security_ensure_ssh_transition_ports() {
    local old_port="$1"
    local new_port="$2"

    ops_conf_set "ops.conf" "OPS_SSH_PORT" "$new_port"
    if [[ "$old_port" != "$new_port" ]]; then
        ops_conf_set "ops.conf" "OPS_SSH_TRANSITION_PORT" "$old_port"
    fi

    security_reconcile_ufw_rules
}

security_rollback_sshd_config() {
    local backup_path="$1"
    local ssh_service
    ssh_service=$(security_detect_ssh_service)

    print_warn "Rollback triggered: opening port 22 first to avoid SSH lockout..."
    ufw allow 22/tcp comment "ops: rollback emergency SSH" >/dev/null 2>&1 || true

    if [[ -n "$backup_path" && -f "$backup_path" ]]; then
        cp "$backup_path" "$SECURITY_SSHD_CONFIG"
        print_warn "Restored SSH config from backup: $backup_path"
    fi

    if sshd -t >/dev/null 2>&1; then
        service_restart "$ssh_service"
        print_warn "Rollback complete: SSH service restarted."
    else
        print_error "Rollback restored config still fails sshd -t. Manual recovery required immediately."
    fi
}

security_apply_sshd_hardening() {
    local new_port="$1"
    local password_auth="$2"
    local old_port
    local ssh_service
    local backup_path

    old_port=$(security_get_current_ssh_port)
    ssh_service=$(security_detect_ssh_service)

    backup_path=$(backup_file "$SECURITY_SSHD_CONFIG")

    security_reconcile_sshd_main_config
    security_write_sshd_hardening_include "$new_port" "$password_auth" "$old_port"

    if ! sshd -t >/dev/null 2>&1; then
        print_error "sshd -t failed after update. Starting rollback."
        security_rollback_sshd_config "$backup_path"
        return 1
    fi

    security_ensure_ssh_transition_ports "$old_port" "$new_port"
    service_restart "$ssh_service"

    ops_conf_set "ops.conf" "OPS_SSH_PORT" "$new_port"
    ops_conf_set "ops.conf" "OPS_SSH_ROOT_LOGIN" "no"
    ops_conf_set "ops.conf" "OPS_SSH_PASSWORD_AUTH" "$password_auth"
    ops_conf_set "ops.conf" "OPS_RUNTIME_USER" "$(security_get_runtime_user)"

    print_ok "SSH hardening applied successfully."
    print_warn "Transition safety: keep only managed transition ports until login is verified on port $new_port."
    return 0
}

# ── Public menu entry ─────────────────────────────────────────
menu_security() {
    while true; do
        print_section "Security Management"
        echo "  1) Harden SSH config"
        echo "  2) Configure UFW firewall"
        echo "  3) Install & configure fail2ban"
        echo "  4) Show security status"
        echo "  5) Change SSH port"
        echo "  6) Finalize SSH transition (close old SSH port)"
        echo "  7) Apply host baseline (sysctl/swap/firewall/fail2ban)"
        echo "  0) Back"
        echo ""
        read -r -p "Select: " choice
        case "$choice" in
            1) security_harden_ssh      ;;
            2) security_configure_ufw   ;;
            3) security_setup_fail2ban  ;;
            4) security_status          ;;
            5) security_change_ssh_port ;;
            6) security_finalize_ssh_transition ;;
            7) security_apply_host_baseline ;;
            0) return                   ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}

# ── Actions (stubs) ───────────────────────────────────────────

security_harden_ssh() {
    print_section "SSH Hardening"
    security_require_root || return 1

    local current_port new_port password_auth
    current_port=$(security_get_current_ssh_port)

    prompt_input "Enter SSH port" "$current_port"
    new_port="$REPLY"
    security_validate_ssh_port "$new_port" || return 1

    if prompt_confirm "Disable PasswordAuthentication (recommended if SSH keys are ready)?"; then
        password_auth="no"
    else
        password_auth="yes"
    fi

    security_apply_sshd_hardening "$new_port" "$password_auth" || return 1
    security_status
}

security_configure_ufw() {
    print_section "UFW Firewall"
    security_require_root || return 1

    print_warn "This will reconcile UFW to OPS-managed baseline and remove stale SSH rules."
    if ! prompt_confirm "Continue applying UFW baseline now?"; then
        print_warn "Cancelled."
        return 0
    fi

    security_reconcile_ufw_rules

    print_ok "UFW baseline reconciled."
    ufw status verbose
}

security_setup_fail2ban() {
    print_section "fail2ban Setup"
    security_require_root || return 1

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        apt_install fail2ban
    fi

    backup_file "$SECURITY_FAIL2BAN_JAIL_LOCAL" >/dev/null 2>&1 || true
    security_write_fail2ban_config

    service_enable fail2ban
    service_restart fail2ban

    print_ok "fail2ban configured for OPS-managed SSH and nginx baseline."
    fail2ban-client status
}

security_status() {
    print_section "Security Status"
    local ssh_port root_login password_auth transition_port runtime_user

    ssh_port=$(security_get_current_ssh_port)
    root_login=$(sshd -T 2>/dev/null | awk '/^permitrootlogin /{print $2; exit}' || true)
    password_auth=$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2; exit}' || true)
    transition_port=$(security_get_transition_port)
    runtime_user=$(security_get_runtime_user)

    echo "Locked SSH Port: ${ssh_port}"
    echo "Transition SSH Port: ${transition_port:-<none>}"
    echo "PermitRootLogin: ${root_login:-<unknown>}"
    echo "PasswordAuthentication: ${password_auth:-<unknown>}"
    echo "Runtime User: ${runtime_user}"
    echo "Host Baseline Sysctl File: ${SECURITY_SYSCTL_OPS_CONF}"
    echo "Swap File: ${SECURITY_SWAP_FILE}"
    echo ""

    if sshd -t >/dev/null 2>&1; then
        print_ok "sshd -t: OK"
    else
        print_error "sshd -t: FAILED"
    fi

    if [[ -f "$SECURITY_SSHD_OPS_INCLUDE" ]]; then
        print_ok "OPS SSH include present: ${SECURITY_SSHD_OPS_INCLUDE}"
    else
        print_warn "OPS SSH include missing: ${SECURITY_SSHD_OPS_INCLUDE}"
    fi

    echo ""
    if command -v ufw >/dev/null 2>&1; then
        ufw status verbose || true
    else
        print_warn "ufw not installed"
    fi

    echo ""
    if command -v fail2ban-client >/dev/null 2>&1; then
        fail2ban-client status || true
        fail2ban-client status sshd || true
    else
        print_warn "fail2ban not installed"
    fi

    echo ""
    sysctl net.ipv4.conf.all.send_redirects net.ipv4.conf.default.send_redirects net.ipv4.conf.all.log_martians net.ipv4.conf.default.log_martians vm.swappiness 2>/dev/null || true
    swapon --show 2>/dev/null || true
}

security_change_ssh_port() {
    print_section "Change SSH Port"
    security_require_root || return 1

    local current_port new_port current_password_auth
    current_port=$(security_get_current_ssh_port)

    prompt_input "Enter new SSH port" "$current_port"
    new_port="$REPLY"
    security_validate_ssh_port "$new_port" || return 1

    current_password_auth=$(ops_conf_get "ops.conf" "OPS_SSH_PASSWORD_AUTH" 2>/dev/null || true)
    if [[ "$current_password_auth" != "yes" && "$current_password_auth" != "no" ]]; then
        current_password_auth="no"
    fi

    security_apply_sshd_hardening "$new_port" "$current_password_auth" || return 1

    print_warn "After login test succeeds in a new SSH session on the new port, run 'Finalize SSH transition (close old SSH port)'."
    security_status
}

security_finalize_ssh_transition() {
    print_section "Finalize SSH Transition"
    security_require_root || return 1

    local new_port old_port admin_user server_ip ssh_service
    new_port=$(security_get_locked_ssh_port)
    old_port=$(security_get_transition_port)
    ssh_service=$(security_detect_ssh_service)

    if [[ -z "$old_port" || "$old_port" == "$new_port" ]]; then
        print_warn "No SSH transition port is currently recorded."
        return 0
    fi

    print_warn "Only continue after you confirmed SSH login works on port ${new_port}."
    if ! prompt_confirm "Finalize SSH transition and remove old port ${old_port}?"; then
        print_warn "Cancelled."
        return 0
    fi

    security_write_sshd_hardening_include "$new_port" "$(ops_conf_get "ops.conf" "OPS_SSH_PASSWORD_AUTH" 2>/dev/null || echo no)"
    if ! sshd -t >/dev/null 2>&1; then
        print_error "sshd -t failed while finalizing transition."
        return 1
    fi

    service_restart "$ssh_service"
    ops_conf_set "ops.conf" "OPS_SSH_TRANSITION_PORT" ""
    security_reconcile_ufw_rules

    if command -v fail2ban-client >/dev/null 2>&1; then
        security_write_fail2ban_config
        service_restart fail2ban >/dev/null 2>&1 || true
    fi

    admin_user=$(security_get_admin_user)
    server_ip=$(security_get_server_ip)

    print_ok "Old SSH port ${old_port} removed from managed config and firewall."
    echo "You MUST now use: ssh -p ${new_port} ${admin_user}@${server_ip}"
    ufw status verbose
}

security_apply_host_baseline() {
    print_section "OPS Host Security Baseline"
    security_require_root || return 1

    security_normalize_script_permissions
    security_apply_sysctl_baseline
    security_ensure_swap
    security_reconcile_ufw_rules

    if command -v fail2ban-client >/dev/null 2>&1; then
        security_write_fail2ban_config
        service_enable fail2ban >/dev/null 2>&1 || true
        service_restart fail2ban >/dev/null 2>&1 || true
    fi

    print_ok "OPS host security baseline applied."
    security_status
}
