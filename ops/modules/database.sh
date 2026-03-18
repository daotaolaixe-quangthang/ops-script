#!/usr/bin/env bash
# ============================================================
# ops/modules/database.sh
# Purpose:  MariaDB install, security baseline, tuning, and DB/user management
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# Called by bin/ops via menu dispatch.
# Do NOT add set -euo pipefail here — inherited from bin/ops.

DB_CONFIG_FILE="${OPS_CONFIG_DIR}/database.conf"
DB_ROOT_PASSWORD_FILE="${OPS_CONFIG_DIR}/.db-root-password"
DB_CREDENTIALS_DIR="${OPS_CONFIG_DIR}/db-credentials"
MARIADB_SERVER_CNF="/etc/mysql/mariadb.conf.d/50-server.cnf"
MARIADB_TUNING_CNF="/etc/mysql/mariadb.conf.d/60-ops-tuning.cnf"

_db_mysql_socket_exec() {
    local sql="$1"
    mysql --protocol=socket -u root -e "$sql"
}

_db_mysql_root_exec() {
    local sql="$1"
    if [[ ! -f "$DB_ROOT_PASSWORD_FILE" ]]; then
        print_error "Root password file not found: ${DB_ROOT_PASSWORD_FILE}"
        return 1
    fi

    local root_password
    root_password="$(cat "$DB_ROOT_PASSWORD_FILE")"
    MYSQL_PWD="$root_password" mysql -u root -e "$sql"
}

_db_escape_sql_string() {
    local value="$1"
    printf '%s' "$value" | sed "s/'/''/g"
}

_db_valid_identifier() {
    local value="$1"
    [[ "$value" =~ ^[A-Za-z0-9_]+$ ]]
}

_db_detect_mariadb_version() {
    dpkg-query -W -f='${Version}' mariadb-server 2>/dev/null || echo "unknown"
}

_db_set_bind_localhost() {
    [[ -f "$MARIADB_SERVER_CNF" ]] || {
        print_error "MariaDB config not found: ${MARIADB_SERVER_CNF}"
        return 1
    }

    backup_file "$MARIADB_SERVER_CNF" >/dev/null || true

    if grep -Eq '^\s*bind-address\s*=' "$MARIADB_SERVER_CNF"; then
        sed -i -E 's/^\s*bind-address\s*=.*/bind-address = 127.0.0.1/' "$MARIADB_SERVER_CNF"
    else
        awk '
            BEGIN { in_mysqld=0; inserted=0 }
            /^\[mysqld\]/ { in_mysqld=1; print; next }
            /^\[/ && in_mysqld==1 && inserted==0 {
                print "bind-address = 127.0.0.1"
                inserted=1
                in_mysqld=0
            }
            { print }
            END {
                if (in_mysqld==1 && inserted==0) {
                    print "bind-address = 127.0.0.1"
                    inserted=1
                }
                if (inserted==0) {
                    print "[mysqld]"
                    print "bind-address = 127.0.0.1"
                }
            }
        ' "$MARIADB_SERVER_CNF" > "${MARIADB_SERVER_CNF}.tmp"
        mv "${MARIADB_SERVER_CNF}.tmp" "$MARIADB_SERVER_CNF"
    fi
}

_db_write_secret_file() {
    local path="$1"
    local content="$2"
    local owner="${ADMIN_USER:-root}"

    ensure_parent_dir "$path"
    write_file "$path" <<EOF_SECRET
${content}
EOF_SECRET
    chmod 600 "$path"
    chown "$owner":"$owner" "$path" 2>/dev/null || true
}

_db_save_database_conf() {
    local db_version="$1"

    ops_conf_set "database.conf" "DB_ENGINE" "mariadb"
    ops_conf_set "database.conf" "DB_VERSION" "$db_version"
    ops_conf_set "database.conf" "DB_ROOT_PASSWORD_FILE" "$DB_ROOT_PASSWORD_FILE"
    ops_conf_set "database.conf" "DB_INSTALL_DATE" "$(date '+%F %T')"
    chmod 600 "$DB_CONFIG_FILE" 2>/dev/null || true
}

install_mariadb() {
    print_section "Install MariaDB"

    apt_update
    apt_install mariadb-server mariadb-client
    service_enable mariadb
    service_start mariadb

    _db_set_bind_localhost

    if ! command -v openssl >/dev/null 2>&1; then
        apt_install openssl
    fi

    local root_password escaped_root_password
    root_password="$(openssl rand -base64 24)"
    escaped_root_password="$(_db_escape_sql_string "$root_password")"

    # Security baseline equivalent to mysql_secure_installation.
    _db_mysql_socket_exec "DELETE FROM mysql.user WHERE User='';"
    _db_mysql_socket_exec "DELETE FROM mysql.user WHERE User='root' AND Host != 'localhost';"
    _db_mysql_socket_exec "DROP DATABASE IF EXISTS test;"
    _db_mysql_socket_exec "ALTER USER 'root'@'localhost' IDENTIFIED BY '${escaped_root_password}';"
    _db_mysql_socket_exec "FLUSH PRIVILEGES;"

    _db_write_secret_file "$DB_ROOT_PASSWORD_FILE" "$root_password"
    _db_save_database_conf "$(_db_detect_mariadb_version)"

    service_restart mariadb

    print_ok "MariaDB installed and secured."
    print_ok "Root password stored at ${DB_ROOT_PASSWORD_FILE} (0600)."
}

tune_mariadb() {
    print_section "Tune MariaDB (Tier: ${OPS_TIER:-M})"

    local innodb_buffer_pool_size max_connections tmp_table_size max_heap_table_size
    case "${OPS_TIER:-M}" in
        S)
            innodb_buffer_pool_size="256M"
            max_connections="80"
            tmp_table_size="32M"
            max_heap_table_size="32M"
            ;;
        M)
            innodb_buffer_pool_size="768M"
            max_connections="150"
            tmp_table_size="64M"
            max_heap_table_size="64M"
            ;;
        L)
            innodb_buffer_pool_size="2G"
            max_connections="300"
            tmp_table_size="128M"
            max_heap_table_size="128M"
            ;;
        *)
            innodb_buffer_pool_size="512M"
            max_connections="120"
            tmp_table_size="64M"
            max_heap_table_size="64M"
            ;;
    esac

    backup_file "$MARIADB_TUNING_CNF" >/dev/null || true
    write_file "$MARIADB_TUNING_CNF" <<EOF_TUNE
[mysqld]
innodb_buffer_pool_size = ${innodb_buffer_pool_size}
max_connections = ${max_connections}
tmp_table_size = ${tmp_table_size}
max_heap_table_size = ${max_heap_table_size}
EOF_TUNE

    chmod 644 "$MARIADB_TUNING_CNF"
    service_restart mariadb
    print_ok "MariaDB tuning applied for tier ${OPS_TIER:-M}."
}

create_db_user() {
    local db_name="${1:-}"
    local db_user="${2:-}"

    if [[ -z "$db_name" || -z "$db_user" ]]; then
        print_error "Usage: create_db_user <db_name> <db_user>"
        return 1
    fi

    if ! _db_valid_identifier "$db_name"; then
        print_error "Invalid db_name '${db_name}'. Use only letters, numbers, underscore."
        return 1
    fi
    if ! _db_valid_identifier "$db_user"; then
        print_error "Invalid db_user '${db_user}'. Use only letters, numbers, underscore."
        return 1
    fi

    local db_password escaped_db_password
    db_password="$(openssl rand -base64 24)"
    escaped_db_password="$(_db_escape_sql_string "$db_password")"

    _db_mysql_root_exec "CREATE DATABASE IF NOT EXISTS \`${db_name}\`;"
    _db_mysql_root_exec "CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${escaped_db_password}';"
    _db_mysql_root_exec "GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, DROP ON \`${db_name}\`.* TO '${db_user}'@'localhost';"
    _db_mysql_root_exec "FLUSH PRIVILEGES;"

    local credentials_file
    credentials_file="${DB_CREDENTIALS_DIR}/${db_name}.conf"
    _db_write_secret_file "$credentials_file" "DB_NAME=\"${db_name}\"
DB_USER=\"${db_user}\"
DB_PASSWORD=\"${db_password}\""

    print_ok "Database '${db_name}' and user '${db_user}' created."
    print_ok "Credentials saved to ${credentials_file} (0600)."
}

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
            1) db_install      ;;
            2) db_secure       ;;
            3) db_apply_tuning ;;
            4) db_create       ;;
            5) db_create_user  ;;
            6) db_drop         ;;
            7) db_list         ;;
            8) db_status       ;;
            0) return          ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}

db_install() {
    install_mariadb
}

db_secure() {
    install_mariadb
}

db_apply_tuning() {
    tune_mariadb
}

db_create() {
    print_section "Create Database"
    prompt_input "Database name"
    local db_name="$REPLY"

    if ! _db_valid_identifier "$db_name"; then
        print_error "Invalid database name '${db_name}'."
        return 1
    fi

    _db_mysql_root_exec "CREATE DATABASE IF NOT EXISTS \`${db_name}\`;"
    print_ok "Database created: ${db_name}"
}

db_create_user() {
    print_section "Create Database User"
    prompt_input "Database name"
    local db_name="$REPLY"
    prompt_input "Database user"
    local db_user="$REPLY"
    create_db_user "$db_name" "$db_user"
}

db_drop() {
    print_section "Drop Database"
    prompt_input "Database name"
    local db_name="$REPLY"

    if ! _db_valid_identifier "$db_name"; then
        print_error "Invalid database name '${db_name}'."
        return 1
    fi

    if ! prompt_confirm "Drop database '${db_name}'?"; then
        print_warn "Cancelled."
        return 0
    fi

    _db_mysql_root_exec "DROP DATABASE IF EXISTS \`${db_name}\`;"
    print_ok "Database dropped: ${db_name}"
}

db_list() {
    print_section "Database List"
    _db_mysql_root_exec "SHOW DATABASES;"
}

db_status() {
    print_section "Database Status"
    service_status mariadb || true

    if [[ -f "$DB_ROOT_PASSWORD_FILE" ]]; then
        local root_password
        root_password="$(cat "$DB_ROOT_PASSWORD_FILE")"
        MYSQL_PWD="$root_password" mysqladmin -u root status || true
        MYSQL_PWD="$root_password" mysql -u root -e "SHOW DATABASES;" || true
    else
        print_warn "Root password file not found: ${DB_ROOT_PASSWORD_FILE}"
    fi
}
