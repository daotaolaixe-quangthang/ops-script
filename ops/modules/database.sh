#!/usr/bin/env bash
# ============================================================
# ops/modules/database.sh
# Purpose:  MySQL/MariaDB install, secure setup, tuning, DB/user management
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# Called by bin/ops via menu dispatch.
# Do NOT add set -euo pipefail here — inherited from bin/ops.

# ── Public menu entry ─────────────────────────────────────────
menu_database() {
    while true; do
        print_section "Database Management"
        echo "  1) Install MariaDB"
        echo "  2) Secure MariaDB installation"
        echo "  3) Apply tuning (by Tier)"
        echo "  4) Create database"
        echo "  5) Create database user"
        echo "  6) Drop database"
        echo "  7) List databases"
        echo "  8) Database status"
        echo "  0) Back"
        echo ""
        read -r -p "Select: " choice
        case "$choice" in
            1) db_install           ;;
            2) db_secure            ;;
            3) db_apply_tuning      ;;
            4) db_create            ;;
            5) db_create_user       ;;
            6) db_drop              ;;
            7) db_list              ;;
            8) db_status            ;;
            0) return               ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}

# ── Actions (stubs) ───────────────────────────────────────────

db_install() {
    print_section "Install MariaDB"
    # TODO: apt_update; apt_install mariadb-server; service_enable mariadb
    # TODO: ops_conf_set database.conf DB_ENGINE mariadb
    print_warn "db_install: not implemented yet"
}

db_secure() {
    print_section "Secure MariaDB"
    # TODO: generate random root password, store in /etc/ops/.db-root-password (chmod 0600)
    # TODO: run equivalent of mysql_secure_installation non-interactively
    # NOTE: bind-address = 127.0.0.1 is mandatory per PERF-TUNING.md §4
    print_warn "db_secure: not implemented yet"
}

db_apply_tuning() {
    print_section "Apply MariaDB Tuning (Tier: ${OPS_TIER:-?})"
    # TODO: per PERF-TUNING.md §4 — set innodb_buffer_pool_size, max_connections, etc. based on OPS_TIER
    # Tier S: buffer_pool=256M, max_conn=80
    # Tier M: buffer_pool=512M-1G, max_conn=150
    # Tier L: buffer_pool=2G+, max_conn=300
    print_warn "db_apply_tuning: not implemented yet"
}

db_create() {
    print_section "Create Database"
    # TODO: prompt_input db_name; run CREATE DATABASE via mysql CLI with stored root password
    print_warn "db_create: not implemented yet"
}

db_create_user() {
    print_section "Create Database User"
    # TODO: prompt_input db_user, db_name; prompt_secret password; CREATE USER / GRANT
    print_warn "db_create_user: not implemented yet"
}

db_drop() {
    print_section "Drop Database"
    # TODO: prompt_input db_name; prompt_confirm; DROP DATABASE
    print_warn "db_drop: not implemented yet"
}

db_list() {
    print_section "Database List"
    # TODO: SHOW DATABASES via mysql CLI with stored root password
    print_warn "db_list: not implemented yet"
}

db_status() {
    print_section "Database Status"
    # TODO: service_status mariadb; show version, connections
    print_warn "db_status: not implemented yet"
}
