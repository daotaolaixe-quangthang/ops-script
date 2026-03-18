#!/usr/bin/env bash
# ============================================================
# ops/modules/security.sh
# Purpose:  SSH hardening, firewall, fail2ban management
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# Called by bin/ops via menu dispatch.
# Do NOT add set -euo pipefail here — inherited from bin/ops.

SECURITY_SSHD_CONFIG="/etc/ssh/sshd_config"
SECURITY_FAIL2BAN_JAIL_LOCAL="/etc/fail2ban/jail.local"

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
    port=$(awk '
        BEGIN { p="" }
        /^[[:space:]]*#/ { next }
        tolower($1) == "port" { p=$2; print p; exit }
    ' "$SECURITY_SSHD_CONFIG" 2>/dev/null || true)

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

security_ensure_ssh_transition_ports() {
    local old_port="$1"
    local new_port="$2"

    if ! command -v ufw >/dev/null 2>&1; then
        apt_install ufw
    fi

    ufw allow "${old_port}/tcp" comment "ops: SSH transition old port" >/dev/null 2>&1 || true
    ufw allow "${new_port}/tcp" comment "ops: SSH transition new port" >/dev/null 2>&1 || true
    ufw delete allow 20128/tcp >/dev/null 2>&1 || true
    ufw deny 20128/tcp >/dev/null 2>&1 || true
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

    security_set_sshd_option "Port" "$new_port" "$SECURITY_SSHD_CONFIG"
    security_set_sshd_option "PermitRootLogin" "no" "$SECURITY_SSHD_CONFIG"
    security_set_sshd_option "PasswordAuthentication" "$password_auth" "$SECURITY_SSHD_CONFIG"
    security_set_sshd_option "ChallengeResponseAuthentication" "no" "$SECURITY_SSHD_CONFIG"

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

    print_ok "SSH hardening applied successfully."
    print_warn "Transition safety: keep port 22 open until you verify login on port $new_port."
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
        echo "  6) Finalize SSH transition (close port 22)"
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

    local ssh_port
    ssh_port=$(security_get_current_ssh_port)

    if ! command -v ufw >/dev/null 2>&1; then
        apt_install ufw
    fi

    print_warn "This will reset UFW rules and apply OPS baseline only."
    print_warn "Allowed inbound: 22/tcp, ${ssh_port}/tcp, 80/tcp, 443/tcp."
    if ! prompt_confirm "Continue applying UFW baseline now?"; then
        print_warn "Cancelled."
        return 0
    fi

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing

    ufw allow 22/tcp comment "ops: SSH transition"
    ufw allow "${ssh_port}/tcp" comment "ops: SSH active"
    ufw allow 80/tcp comment "ops: HTTP"
    ufw allow 443/tcp comment "ops: HTTPS"

    # Hard constraint: never expose 9router direct port.
    ufw delete allow 20128/tcp >/dev/null 2>&1 || true
    ufw deny 20128/tcp

    ufw --force enable
    ufw reload

    print_ok "UFW baseline applied."
    ufw status verbose
}

security_setup_fail2ban() {
    print_section "fail2ban Setup"
    security_require_root || return 1

    local ssh_port
    ssh_port=$(security_get_current_ssh_port)

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        apt_install fail2ban
    fi

    backup_file "$SECURITY_FAIL2BAN_JAIL_LOCAL" >/dev/null 2>&1 || true
    write_file "$SECURITY_FAIL2BAN_JAIL_LOCAL" <<EOF_JAIL
[DEFAULT]
bantime = 10m
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = ${ssh_port}
backend = systemd
logpath = %(sshd_log)s
EOF_JAIL

    service_enable fail2ban
    service_restart fail2ban

    print_ok "fail2ban configured for sshd."
    fail2ban-client status
}

security_status() {
    print_section "Security Status"
    local ssh_port root_login password_auth

    ssh_port=$(security_get_current_ssh_port)
    root_login=$(awk 'tolower($1)=="permitrootlogin"{print $2; exit}' "$SECURITY_SSHD_CONFIG" 2>/dev/null || true)
    password_auth=$(awk 'tolower($1)=="passwordauthentication"{print $2; exit}' "$SECURITY_SSHD_CONFIG" 2>/dev/null || true)

    echo "SSH Port: ${ssh_port}"
    echo "PermitRootLogin: ${root_login:-<default>}"
    echo "PasswordAuthentication: ${password_auth:-<default>}"
    echo ""

    if sshd -t >/dev/null 2>&1; then
        print_ok "sshd -t: OK"
    else
        print_error "sshd -t: FAILED"
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
}

security_change_ssh_port() {
    print_section "Change SSH Port"
    security_require_root || return 1

    local current_port new_port current_password_auth
    current_port=$(security_get_current_ssh_port)

    prompt_input "Enter new SSH port" "$current_port"
    new_port="$REPLY"
    security_validate_ssh_port "$new_port" || return 1

    current_password_auth=$(awk '
        tolower($1)=="passwordauthentication" {
            print tolower($2)
            exit
        }
    ' "$SECURITY_SSHD_CONFIG" 2>/dev/null || true)

    if [[ "$current_password_auth" != "yes" && "$current_password_auth" != "no" ]]; then
        current_password_auth="yes"
    fi

    security_apply_sshd_hardening "$new_port" "$current_password_auth" || return 1

    print_warn "After login test succeeds on new port, run 'Finalize SSH transition (close port 22)'."
    security_status
}

security_finalize_ssh_transition() {
    print_section "Finalize SSH Transition"
    security_require_root || return 1

    local new_port admin_user server_ip
    new_port=$(security_get_current_ssh_port)

    if [[ "$new_port" == "22" ]]; then
        print_warn "Current SSH port is still 22. Change SSH port before closing port 22."
        return 1
    fi

    print_warn "Only continue after you confirmed SSH login works on port ${new_port}."
    if ! prompt_confirm "Remove port 22 from UFW now?"; then
        print_warn "Cancelled."
        return 0
    fi

    ufw --force delete allow 22/tcp >/dev/null 2>&1 || true
    ufw --force delete allow OpenSSH >/dev/null 2>&1 || true
    ufw reload

    admin_user=$(security_get_admin_user)
    server_ip=$(security_get_server_ip)

    print_ok "Port 22 removed from UFW and firewall reloaded."
    echo "You MUST now use: ssh -p ${new_port} ${admin_user}@${server_ip}"
    ufw status verbose
}
