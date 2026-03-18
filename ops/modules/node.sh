#!/usr/bin/env bash
# ============================================================
# ops/modules/node.sh
# Purpose:  Node.js LTS install, PM2 setup, Node service management
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# Called by bin/ops via menu dispatch.
# Do NOT add set -euo pipefail here — inherited from bin/ops.

# ── Public menu entry ─────────────────────────────────────────
menu_node() {
    while true; do
        print_section "Node.js Services"
        echo "  1) Install Node.js LTS"
        echo "  2) Install / update PM2"
        echo "  3) List PM2 services"
        echo "  4) Add Node.js app"
        echo "  5) Remove Node.js app"
        echo "  6) Restart app"
        echo "  7) Show app logs"
        echo "  0) Back"
        echo ""
        read -r -p "Select: " choice
        case "$choice" in
            1) node_install         ;;
            2) node_install_pm2     ;;
            3) node_list_apps       ;;
            4) node_add_app         ;;
            5) node_remove_app      ;;
            6) node_restart_app     ;;
            7) node_show_logs       ;;
            0) return               ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}

# ── Actions (stubs) ───────────────────────────────────────────

node_install() {
    print_section "Install Node.js LTS"
    # TODO: curl NodeSource setup script, apt_install nodejs, verify node --version
    print_warn "node_install: not implemented yet"
}

node_install_pm2() {
    print_section "Install PM2"
    # TODO: npm install -g pm2, pm2 startup, service_enable pm2-ADMIN_USER
    print_warn "node_install_pm2: not implemented yet"
}

node_list_apps() {
    print_section "PM2 Service List"
    # TODO: pm2 list --no-interaction
    print_warn "node_list_apps: not implemented yet"
}

node_add_app() {
    print_section "Add Node.js App"
    # TODO: prompt_input app_name, app_path, port; render ecosystem.config.js.tpl; pm2 start; pm2 save
    print_warn "node_add_app: not implemented yet"
}

node_remove_app() {
    print_section "Remove Node.js App"
    # TODO: prompt_input app_name; pm2 delete app_name; pm2 save; remove conf from /etc/ops/apps/
    print_warn "node_remove_app: not implemented yet"
}

node_restart_app() {
    print_section "Restart App"
    # TODO: prompt_input app_name; pm2 restart app_name
    print_warn "node_restart_app: not implemented yet"
}

node_show_logs() {
    print_section "App Logs"
    # TODO: prompt_input app_name; pm2 logs app_name --lines 50
    print_warn "node_show_logs: not implemented yet"
}
