#!/usr/bin/env bash
# ============================================================
# ops/modules/setup-wizard.sh
# Purpose:  First-time production setup wizard (orchestrator)
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# Called by bin/ops via menu dispatch.
# Do NOT add set -euo pipefail here — inherited from bin/ops.

# ── Public menu entry ─────────────────────────────────────────
menu_setup_wizard() {
    while true; do
        print_section "Production Setup Wizard"
        echo "  1) Run full production wizard"
        echo "  2) Configure SSH & admin user"
        echo "  3) Configure firewall baseline"
        echo "  4) Show current setup status"
        echo "  0) Back"
        echo ""
        read -r -p "Select: " choice
        case "$choice" in
            1) wizard_run_full       ;;
            2) wizard_configure_ssh  ;;
            3) wizard_configure_ufw  ;;
            4) wizard_status         ;;
            0) return                ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}

# ── Actions (stubs) ───────────────────────────────────────────

wizard_run_full() {
    print_section "Full Production Wizard"
    # TODO: orchestrate security → nginx → node → php → database → monitoring
    print_warn "wizard_run_full: not implemented yet"
}

wizard_configure_ssh() {
    print_section "SSH & Admin User"
    # TODO: change SSH port, create admin user, disable root login
    print_warn "wizard_configure_ssh: not implemented yet"
}

wizard_configure_ufw() {
    print_section "Firewall Baseline"
    # TODO: ufw_allow SSH_PORT, ufw_allow 80, ufw_allow 443, ufw enable
    print_warn "wizard_configure_ufw: not implemented yet"
}

wizard_status() {
    print_section "Setup Status"
    # TODO: check which modules have been applied; read /etc/ops/ops.conf
    print_warn "wizard_status: not implemented yet"
}
