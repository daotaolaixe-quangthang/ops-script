#!/usr/bin/env bash
# ============================================================
# ops/modules/monitoring.sh
# Purpose:  Basic and optional advanced monitoring
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# Called by bin/ops via menu dispatch.
# Do NOT add set -euo pipefail here — inherited from bin/ops.

# ── Public menu entry ─────────────────────────────────────────
menu_monitoring() {
    while true; do
        print_section "System & Monitoring"
        echo "  1) Show system overview"
        echo "  2) Show OPS log (tail)"
        echo "  3) Setup Telegram notifications"
        echo "  4) Test Telegram notification"
        echo "  5) Show login history"
        echo "  6) Disk usage summary"
        echo "  0) Back"
        echo ""
        read -r -p "Select: " choice
        case "$choice" in
            1) monitoring_system_overview    ;;
            2) monitoring_show_ops_log       ;;
            3) monitoring_setup_telegram     ;;
            4) monitoring_test_telegram      ;;
            5) monitoring_login_history      ;;
            6) monitoring_disk_usage         ;;
            0) return                        ;;
            *) print_warn "Invalid option"   ;;
        esac
    done
}

# ── Actions (stubs) ───────────────────────────────────────────

monitoring_system_overview() {
    print_section "System Overview"
    echo "  Tier:   ${OPS_TIER:-?}"
    echo "  OS:     ${OS_ID:-?} ${OS_VERSION_ID:-?}"
    echo "  RAM:    ${RAM_MB:-?} MB"
    echo "  CPU:    ${CPU_CORES:-?} cores"
    echo ""
    # TODO: show disk usage, uptime, load average, top services
    print_warn "Full system overview: not implemented yet"
}

monitoring_show_ops_log() {
    print_section "OPS Log (last 50 lines)"
    if [[ -f "${OPS_LOG_FILE:-}" ]]; then
        tail -n 50 "$OPS_LOG_FILE"
    else
        print_warn "Log file not found: ${OPS_LOG_FILE:-/var/log/ops/ops.log}"
    fi
}

monitoring_setup_telegram() {
    print_section "Setup Telegram Notifications"
    # TODO: prompt_secret TELEGRAM_BOT_TOKEN; prompt_input TELEGRAM_CHAT_ID
    # TODO: store token in /etc/ops/.telegram-bot-token (chmod 0600)
    # TODO: ops_conf_set notifications.conf TELEGRAM_ENABLED true
    # TODO: ops_conf_set notifications.conf CHAT_ID "$CHAT_ID"
    print_warn "monitoring_setup_telegram: not implemented yet"
}

monitoring_test_telegram() {
    print_section "Test Telegram"
    # TODO: read token from secret file; curl Telegram API test message
    print_warn "monitoring_test_telegram: not implemented yet"
}

monitoring_login_history() {
    print_section "Login History"
    # TODO: last -n 20
    print_warn "monitoring_login_history: not implemented yet"
}

monitoring_disk_usage() {
    print_section "Disk Usage"
    df -h --output=source,fstype,size,used,avail,pcent,target | head -n 20
}
