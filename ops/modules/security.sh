#!/usr/bin/env bash
# ============================================================
# ops/modules/security.sh
# Purpose:  SSH hardening, firewall, fail2ban management
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# Called by bin/ops via menu dispatch.
# Do NOT add set -euo pipefail here — inherited from bin/ops.

# ── Public menu entry ─────────────────────────────────────────
menu_security() {
    while true; do
        print_section "Security Management"
        echo "  1) Harden SSH config"
        echo "  2) Configure UFW firewall"
        echo "  3) Install & configure fail2ban"
        echo "  4) Show security status"
        echo "  5) Change SSH port"
        echo "  0) Back"
        echo ""
        read -r -p "Select: " choice
        case "$choice" in
            1) security_harden_ssh      ;;
            2) security_configure_ufw   ;;
            3) security_setup_fail2ban  ;;
            4) security_status          ;;
            5) security_change_ssh_port ;;
            0) return                   ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}

# ── Actions (stubs) ───────────────────────────────────────────

security_harden_ssh() {
    print_section "SSH Hardening"
    # TODO: disable PasswordAuthentication, PermitRootLogin, set Port
    print_warn "security_harden_ssh: not implemented yet"
}

security_configure_ufw() {
    print_section "UFW Firewall"
    # TODO: set default deny, allow SSH/HTTP/HTTPS, enable ufw
    print_warn "security_configure_ufw: not implemented yet"
}

security_setup_fail2ban() {
    print_section "fail2ban Setup"
    # TODO: apt_install fail2ban, write jail.local, service_enable fail2ban
    print_warn "security_setup_fail2ban: not implemented yet"
}

security_status() {
    print_section "Security Status"
    # TODO: show UFW status, fail2ban status, SSH config summary
    print_warn "security_status: not implemented yet"
}

security_change_ssh_port() {
    print_section "Change SSH Port"
    # TODO: prompt_input new port, backup sshd_config, sed Port line, service_restart ssh, ufw_allow
    print_warn "security_change_ssh_port: not implemented yet"
}
