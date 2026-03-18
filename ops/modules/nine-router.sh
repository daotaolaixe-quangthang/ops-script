#!/usr/bin/env bash
# ============================================================
# ops/modules/nine-router.sh
# Purpose:  9router install, PM2 service, domain integration
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# Called by bin/ops via menu dispatch.
# Do NOT add set -euo pipefail here — inherited from bin/ops.

# ── Public menu entry ─────────────────────────────────────────
menu_nine_router() {
    while true; do
        print_section "9router Management"
        echo "  1) Install 9router"
        echo "  2) Configure domain & SSL"
        echo "  3) Start / restart 9router"
        echo "  4) Stop 9router"
        echo "  5) Show 9router status"
        echo "  6) Show 9router logs"
        echo "  7) Update 9router"
        echo "  0) Back"
        echo ""
        read -r -p "Select: " choice
        case "$choice" in
            1) nine_router_install      ;;
            2) nine_router_configure    ;;
            3) nine_router_restart      ;;
            4) nine_router_stop         ;;
            5) nine_router_status       ;;
            6) nine_router_logs         ;;
            7) nine_router_update       ;;
            0) return                   ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}

# ── Actions (stubs) ───────────────────────────────────────────

nine_router_install() {
    print_section "Install 9router"
    # TODO: clone/copy 9router to /opt/9router, npm install, create .env, pm2 start
    # TODO: ops_conf_set nine-router.conf NINE_ROUTER_INSTALLED true
    print_warn "nine_router_install: not implemented yet"
}

nine_router_configure() {
    print_section "Configure 9router Domain & SSL"
    # TODO: prompt_input domain; render_template nine-router.vhost.conf.tpl; ssl_issue_cert; nginx_reload
    # TODO: ops_conf_set nine-router.conf NINE_ROUTER_DOMAIN "$REPLY"
    print_warn "nine_router_configure: not implemented yet"
}

nine_router_restart() {
    print_section "Restart 9router"
    # TODO: pm2 restart nine-router
    print_warn "nine_router_restart: not implemented yet"
}

nine_router_stop() {
    print_section "Stop 9router"
    # TODO: pm2 stop nine-router
    print_warn "nine_router_stop: not implemented yet"
}

nine_router_status() {
    print_section "9router Status"
    # TODO: pm2 show nine-router; show domain and SSL status from ops.conf
    print_warn "nine_router_status: not implemented yet"
}

nine_router_logs() {
    print_section "9router Logs"
    # TODO: pm2 logs nine-router --lines 50
    print_warn "nine_router_logs: not implemented yet"
}

nine_router_update() {
    print_section "Update 9router"
    # TODO: git pull in /opt/9router, npm install --production, pm2 restart nine-router
    print_warn "nine_router_update: not implemented yet"
}
