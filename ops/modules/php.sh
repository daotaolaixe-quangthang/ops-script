#!/usr/bin/env bash
# ============================================================
# ops/modules/php.sh
# Purpose:  Multi-PHP (7.4, 8.1, 8.2, 8.3) install and PHP-FPM tuning
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# Called by bin/ops via menu dispatch.
# Do NOT add set -euo pipefail here — inherited from bin/ops.

# ── Public menu entry ─────────────────────────────────────────
menu_php() {
    while true; do
        print_section "PHP / PHP-FPM Management"
        echo "  1) Install PHP version"
        echo "  2) Remove PHP version"
        echo "  3) List installed PHP versions"
        echo "  4) Apply PHP-FPM tuning (by Tier)"
        echo "  5) Set default PHP version"
        echo "  6) PHP-FPM status"
        echo "  0) Back"
        echo ""
        read -r -p "Select: " choice
        case "$choice" in
            1) php_install_version  ;;
            2) php_remove_version   ;;
            3) php_list_versions    ;;
            4) php_apply_tuning     ;;
            5) php_set_default      ;;
            6) php_fpm_status       ;;
            0) return               ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}

# ── Actions (stubs) ───────────────────────────────────────────

# Supported PHP versions (from ARCHITECTURE.md)
PHP_VERSIONS=("7.4" "8.1" "8.2" "8.3")

php_install_version() {
    print_section "Install PHP Version"
    # TODO: prompt_input "PHP version" "8.2"; add ondrej/php PPA; apt_install php${ver}-fpm php${ver}-common ...
    # TODO: service_enable php${ver}-fpm
    print_warn "php_install_version: not implemented yet"
}

php_remove_version() {
    print_section "Remove PHP Version"
    # TODO: prompt_input version; apt_remove php${ver}-fpm; service stop/disable
    print_warn "php_remove_version: not implemented yet"
}

php_list_versions() {
    print_section "Installed PHP Versions"
    # TODO: iterate PHP_VERSIONS, check is_installed php${ver}; service_active php${ver}-fpm
    print_warn "php_list_versions: not implemented yet"
}

php_apply_tuning() {
    print_section "Apply PHP-FPM Tuning (Tier: ${OPS_TIER:-?})"
    # TODO: per PERF-TUNING.md §3 — set pm, max_children, etc. based on OPS_TIER
    # Tier S: pm=ondemand, max_children=5
    # Tier M: pm=dynamic, max_children=20
    # Tier L: pm=dynamic, max_children=50
    print_warn "php_apply_tuning: not implemented yet"
}

php_set_default() {
    print_section "Set Default PHP Version"
    # TODO: update-alternatives --set php /usr/bin/php${ver}
    print_warn "php_set_default: not implemented yet"
}

php_fpm_status() {
    print_section "PHP-FPM Status"
    # TODO: iterate installed versions, show systemctl status php${ver}-fpm
    print_warn "php_fpm_status: not implemented yet"
}
