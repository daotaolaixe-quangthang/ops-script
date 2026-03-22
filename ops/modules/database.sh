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
MARIADB_SSL_DIR="/etc/mysql/ssl"
DB_ROOT_AUTH_MODE="socket"

_db_mysql_socket_exec() {
    local sql="$1"
    mysql --protocol=socket -u root -e "$sql"
}

_db_mysql_root_exec() {
    local sql="$1"
    if _db_mysql_socket_exec "SELECT 1;" >/dev/null 2>&1; then
        _db_mysql_socket_exec "$sql"
        return $?
    fi

    if [[ -f "$DB_ROOT_PASSWORD_FILE" ]]; then
        local root_password
        root_password="$(cat "$DB_ROOT_PASSWORD_FILE")"
        MYSQL_PWD="$root_password" mysql -u root -e "$sql"
        return $?
    fi

    print_error "Cannot authenticate as MariaDB root via socket or password file."
    return 1
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

_db_assert_not_rescue_mode() {
    local rescue_proc
    rescue_proc="$(ps -eo args= 2>/dev/null | grep -E '[m]ariadbd?.*--skip-grant-tables|[m]ysqld.*--skip-grant-tables' || true)"
    if [[ -n "$rescue_proc" ]]; then
        print_error "MariaDB rescue mode detected (--skip-grant-tables). Stop unmanaged process before continuing."
        log_error "database guard blocked action due to rescue mode: ${rescue_proc}"
        return 1
    fi
    return 0
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

_db_remove_secret_file() {
    local path="$1"
    [[ -f "$path" ]] || return 0
    rm -f "$path"
}

_db_save_database_conf() {
    local db_version="$1"

    ops_conf_set "database.conf" "DB_ENGINE" "mariadb"
    ops_conf_set "database.conf" "DB_VERSION" "$db_version"
    ops_conf_set "database.conf" "DB_ROOT_AUTH_MODE" "$DB_ROOT_AUTH_MODE"
    if [[ "$DB_ROOT_AUTH_MODE" == "password" ]]; then
        ops_conf_set "database.conf" "DB_ROOT_PASSWORD_FILE" "$DB_ROOT_PASSWORD_FILE"
    fi
    ops_conf_set "database.conf" "DB_INSTALL_DATE" "$(date '+%F %T')"
    chmod 600 "$DB_CONFIG_FILE" 2>/dev/null || true
}

# _db_setup_mysql_log_dir
# Creates /var/log/mysql with correct ownership for error log and slow log.
_db_setup_mysql_log_dir() {
    local log_dir="/var/log/mysql"
    if [[ ! -d "$log_dir" ]]; then
        mkdir -p "$log_dir"
    fi
    chown -R mysql:adm "$log_dir" 2>/dev/null || chown -R mysql:mysql "$log_dir" || true
    chmod 750 "$log_dir"
}

# _db_apply_security_hardening
# Writes security-critical settings to 60-ops-tuning.cnf.
# Idempotent: called after tune_mariadb so settings are merged into same file.
# These settings address the OPS MariaDB audit findings:
#   local_infile, secure_file_priv, skip_name_resolve, max_connect_errors,
#   wait_timeout, interactive_timeout.
_db_apply_security_hardening() {
    # Remove any previous security block to stay idempotent
    if [[ -f "$MARIADB_TUNING_CNF" ]]; then
        # Strip the OPS security block (between markers) if present
        local tmp
        tmp=$(mktemp)
        awk '/^# --- OPS SECURITY HARDENING ---$/,/^# --- END OPS SECURITY HARDENING ---$/ { next } { print }' \
            "$MARIADB_TUNING_CNF" > "$tmp"
        mv "$tmp" "$MARIADB_TUNING_CNF"
    fi

    cat >> "$MARIADB_TUNING_CNF" <<'EOF_SEC'

# --- OPS SECURITY HARDENING ---
# Applied by install_mariadb / db_install (ops-script)
# Do NOT remove — these settings address critical audit findings.

# Disable LOAD DATA LOCAL INFILE (file exfiltration vector)
local_infile            = OFF

# Restrict file import/export to NULL (disables SELECT INTO OUTFILE)
secure_file_priv        = NULL

# Skip reverse DNS on connections (prevents latency + DNS rebinding)
skip_name_resolve       = ON

# Block hosts after 10 consecutive failed connections
max_connect_errors      = 10

# Idle non-interactive connection timeout: 5 minutes
wait_timeout            = 300

# Idle interactive connection timeout: 10 minutes
interactive_timeout     = 600
# --- END OPS SECURITY HARDENING ---
EOF_SEC

    chmod 644 "$MARIADB_TUNING_CNF"
    print_ok "MariaDB security hardening applied to ${MARIADB_TUNING_CNF}."
}

# _db_setup_ssl
# Generates a self-signed CA + server cert under /etc/mysql/ssl/ and adds
# ssl-ca, ssl-cert, ssl-key directives to 60-ops-tuning.cnf.
# Idempotent: skips cert generation if files already exist.
_db_setup_ssl() {
    if ! command -v openssl >/dev/null 2>&1; then
        apt_install openssl
    fi

    local ca_key="${MARIADB_SSL_DIR}/ca-key.pem"
    local ca_cert="${MARIADB_SSL_DIR}/ca.pem"
    local srv_key="${MARIADB_SSL_DIR}/server-key.pem"
    local srv_cert="${MARIADB_SSL_DIR}/server-cert.pem"
    local srv_req="${MARIADB_SSL_DIR}/server-req.pem"

    mkdir -p "$MARIADB_SSL_DIR"

    if [[ ! -f "$ca_cert" || ! -f "$srv_cert" || ! -f "$srv_key" ]]; then
        print_ok "Generating MariaDB self-signed SSL certificates..."

        # CA key + cert
        openssl genrsa 2048 > "$ca_key" 2>/dev/null
        openssl req -new -x509 -nodes -days 3650 \
            -key "$ca_key" -out "$ca_cert" \
            -subj "/CN=OPS-MariaDB-CA" 2>/dev/null

        # Server key + cert signed by CA
        openssl req -newkey rsa:2048 -days 3650 -nodes \
            -keyout "$srv_key" -out "$srv_req" \
            -subj "/CN=$(hostname -f 2>/dev/null || hostname)" 2>/dev/null
        openssl x509 -req -in "$srv_req" -days 3650 \
            -CA "$ca_cert" -CAkey "$ca_key" -set_serial 01 \
            -out "$srv_cert" 2>/dev/null

        # Clean temp request file
        rm -f "$srv_req"

        chown -R mysql:mysql "$MARIADB_SSL_DIR"
        chmod 600 "${MARIADB_SSL_DIR}/"*.pem
        chmod 644 "$ca_cert" "$srv_cert"   # CA+server cert can be world-readable
        print_ok "SSL certificates generated at ${MARIADB_SSL_DIR}/."
    else
        print_ok "MariaDB SSL certificates already present — skipping generation."
    fi

    # Remove previous SSL block from tuning cnf (idempotent)
    if [[ -f "$MARIADB_TUNING_CNF" ]]; then
        local tmp
        tmp=$(mktemp)
        awk '/^# --- OPS SSL ---$/,/^# --- END OPS SSL ---$/ { next } { print }' \
            "$MARIADB_TUNING_CNF" > "$tmp"
        mv "$tmp" "$MARIADB_TUNING_CNF"
    fi

    cat >> "$MARIADB_TUNING_CNF" <<EOF_SSL

# --- OPS SSL ---
# MariaDB TLS configuration (self-signed cert, managed by ops-script)
ssl-ca   = ${ca_cert}
ssl-cert = ${srv_cert}
ssl-key  = ${srv_key}
# --- END OPS SSL ---
EOF_SSL

    chmod 644 "$MARIADB_TUNING_CNF"
    print_ok "MariaDB SSL configured in ${MARIADB_TUNING_CNF}."
}

# _db_setup_logging
# Enables error log and slow query log in 60-ops-tuning.cnf.
_db_setup_logging() {
    _db_setup_mysql_log_dir

    # Remove previous logging block (idempotent)
    if [[ -f "$MARIADB_TUNING_CNF" ]]; then
        local tmp
        tmp=$(mktemp)
        awk '/^# --- OPS LOGGING ---$/,/^# --- END OPS LOGGING ---$/ { next } { print }' \
            "$MARIADB_TUNING_CNF" > "$tmp"
        mv "$tmp" "$MARIADB_TUNING_CNF"
    fi

    cat >> "$MARIADB_TUNING_CNF" <<'EOF_LOG'

# --- OPS LOGGING ---
# Error log (structured, separate from journald for retention)
log_error                       = /var/log/mysql/error.log

# Slow query log — catch queries > 2 seconds
slow_query_log                  = ON
slow_query_log_file             = /var/log/mysql/mariadb-slow.log
long_query_time                 = 2
log_slow_verbosity              = query_plan,explain
log_queries_not_using_indexes   = ON
# --- END OPS LOGGING ---
EOF_LOG

    chmod 644 "$MARIADB_TUNING_CNF"
    print_ok "MariaDB logging configured (error log + slow query log)."
}

install_mariadb() {
    print_section "Install MariaDB"
    require_root || return 1

    _db_assert_not_rescue_mode || return 1

    apt_update
    apt_install mariadb-server mariadb-client
    service_enable mariadb
    service_start mariadb

    _db_set_bind_localhost

    if ! command -v openssl >/dev/null 2>&1; then
        apt_install openssl
    fi

    # Security baseline equivalent to mysql_secure_installation.
    _db_mysql_socket_exec "DELETE FROM mysql.user WHERE User='';"
    _db_mysql_socket_exec "DELETE FROM mysql.user WHERE User='root' AND Host != 'localhost';"
    _db_mysql_socket_exec "DROP DATABASE IF EXISTS test;"
    _db_mysql_socket_exec "ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket;"
    _db_mysql_socket_exec "FLUSH PRIVILEGES;"

    _db_remove_secret_file "$DB_ROOT_PASSWORD_FILE"
    _db_save_database_conf "$(_db_detect_mariadb_version)"

    # Apply performance tuning first (creates the tuning cnf).
    # DB_TUNING_NO_RESTART=1 prevents double service restart — install_mariadb
    # restarts once at the end after all hardening blocks are written.
    DB_TUNING_NO_RESTART=1 tune_mariadb

    # OPS hardening — appends security settings to tuning cnf
    _db_apply_security_hardening
    _db_setup_ssl
    _db_setup_logging

    service_restart mariadb

    print_ok "MariaDB installed, hardened, and tuned."
    print_ok "MariaDB root uses local unix_socket authentication (sudo mysql)."
}

tune_mariadb() {
    print_section "Tune MariaDB (Tier: ${OPS_TIER:-M})"
    require_root || return 1

    _db_assert_not_rescue_mode || return 1

    # Tier-variable settings
    local innodb_buffer_pool_size innodb_buffer_pool_instances innodb_log_file_size
    local max_connections tmp_table_size max_heap_table_size

    case "${OPS_TIER:-M}" in
        S)
            # < 1500 MB RAM — conservative settings
            innodb_buffer_pool_size="512M"
            innodb_buffer_pool_instances="1"
            innodb_log_file_size="64M"
            max_connections="80"
            tmp_table_size="32M"
            max_heap_table_size="32M"
            ;;
        M)
            # 1500–5000 MB RAM
            innodb_buffer_pool_size="2G"
            innodb_buffer_pool_instances="2"
            innodb_log_file_size="256M"
            max_connections="150"
            tmp_table_size="64M"
            max_heap_table_size="64M"
            ;;
        L)
            # > 5000 MB RAM
            innodb_buffer_pool_size="5G"
            innodb_buffer_pool_instances="4"
            innodb_log_file_size="512M"
            max_connections="300"
            tmp_table_size="128M"
            max_heap_table_size="128M"
            ;;
        *)
            innodb_buffer_pool_size="1G"
            innodb_buffer_pool_instances="1"
            innodb_log_file_size="128M"
            max_connections="120"
            tmp_table_size="64M"
            max_heap_table_size="64M"
            ;;
    esac

    backup_file "$MARIADB_TUNING_CNF" >/dev/null || true

    # Write the base performance tuning block.
    # Security hardening (_db_apply_security_hardening), SSL (_db_setup_ssl),
    # and logging (_db_setup_logging) append their own tagged blocks below.
    write_file "$MARIADB_TUNING_CNF" <<EOF_TUNE
[mysqld]
# --- OPS PERFORMANCE TUNING (Tier: ${OPS_TIER:-M}) ---
# Generated by ops-script tune_mariadb(). Do not edit manually.

# InnoDB buffer pool — most important MariaDB setting (~70% of available RAM)
innodb_buffer_pool_size      = ${innodb_buffer_pool_size}
innodb_buffer_pool_instances = ${innodb_buffer_pool_instances}

# InnoDB redo log — larger = fewer checkpoint flushes under write load
innodb_log_file_size         = ${innodb_log_file_size}

# Key buffer: only used by MyISAM; InnoDB-only setups waste 128MB otherwise
key_buffer_size              = 8M

# SSD optimisations: disable neighbour flushing, raise I/O capacity
innodb_flush_neighbors       = 0
innodb_io_capacity           = 1000
innodb_io_capacity_max       = 4000

# Connection and temp table limits
max_connections              = ${max_connections}
tmp_table_size               = ${tmp_table_size}
max_heap_table_size          = ${max_heap_table_size}
# --- END OPS PERFORMANCE TUNING ---
EOF_TUNE

    chmod 644 "$MARIADB_TUNING_CNF"
    print_ok "MariaDB performance tuning applied for tier ${OPS_TIER:-M}."
    print_ok "  innodb_buffer_pool_size=${innodb_buffer_pool_size}, instances=${innodb_buffer_pool_instances}, log=${innodb_log_file_size}"
    print_ok "  max_connections=${max_connections}, tmp_table=${tmp_table_size}"

    # Restart only if called standalone (not from install_mariadb which restarts at the end)
    if [[ "${DB_TUNING_NO_RESTART:-0}" != "1" ]]; then
        service_restart mariadb
    fi
}

create_db_user() {
    require_root || return 1
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
        echo "  2) Secure/re-harden MariaDB"
        echo "  3) Apply tuning (by Tier)"
        echo "  4) Create database"
        echo "  5) Create database user"
        echo "  6) Drop database"
        echo "  7) List databases"
        echo "  8) Database status"
        echo "  9) Compliance audit"
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
            9) db_audit        ;;
            0) return          ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}

db_install() {
    install_mariadb
}

db_secure() {
    _db_assert_not_rescue_mode || return 1
    install_mariadb
}

db_apply_tuning() {
    tune_mariadb
    _db_apply_security_hardening
    _db_setup_ssl
    _db_setup_logging
    service_restart mariadb
    print_ok "MariaDB fully re-hardened and restarted."
}

# db_audit — show current compliance status for all OPS-managed settings.
db_audit() {
    print_section "MariaDB Compliance Audit"
    require_root || return 1

    _db_assert_not_rescue_mode || return 1

    local pass=0 warn=0 fail=0

    _audit_check() {
        local label="$1"
        local variable="$2"
        local expected="$3"   # regex, case-insensitive
        local severity="${4:-FAIL}"  # FAIL or WARN

        local actual
        actual=$(mysql --protocol=socket -u root -sNe "SHOW VARIABLES LIKE '${variable}';" 2>/dev/null | awk '{print $2}')

        if printf '%s' "$actual" | grep -iqE "^(${expected})$"; then
            printf '  [\033[0;32mPASS\033[0m] %-35s %s\n' "${variable}" "${actual}"
            (( pass++ )) || true
        else
            if [[ "$severity" == "WARN" ]]; then
                printf '  [\033[0;33mWARN\033[0m] %-35s got=%s, expected~=%s\n' "${variable}" "${actual:-<empty>}" "$expected"
                (( warn++ )) || true
            else
                printf '  [\033[0;31mFAIL\033[0m] %-35s got=%s, expected~=%s\n' "${variable}" "${actual:-<empty>}" "$expected"
                (( fail++ )) || true
            fi
        fi
    }

    _audit_check "Network isolation"       "bind_address"          "127\.0\.0\.1"
    _audit_check "SSL enabled"             "have_ssl"              "YES"
    _audit_check "local_infile disabled"   "local_infile"          "OFF"
    _audit_check "secure_file_priv=NULL"   "secure_file_priv"      ""              "WARN"
    _audit_check "skip_name_resolve"       "skip_name_resolve"     "ON"
    _audit_check "slow_query_log ON"       "slow_query_log"        "ON"            "WARN"
    _audit_check "wait_timeout<=300"       "wait_timeout"          "[1-9][0-9]?[0-9]?|[12][0-9]{2}|300"
    _audit_check "innodb_flush_neighbors"  "innodb_flush_neighbors" "0"
    _audit_check "key_buffer_size<=16MB"   "key_buffer_size"       "[0-9]{1,7}|1[0-5][0-9]{5}|16777216"

    unset -f _audit_check

    echo ""
    printf '  Summary: \033[0;32m%d PASS\033[0m  \033[0;33m%d WARN\033[0m  \033[0;31m%d FAIL\033[0m\n' "$pass" "$warn" "$fail"
    echo ""
    if [[ "$fail" -gt 0 ]]; then
        print_warn "Run 'Database → Apply tuning' to fix FAIL items."
    fi
    log_info "db_audit: pass=${pass} warn=${warn} fail=${fail}"
}

db_create() {
    print_section "Create Database"
    require_root || return 1
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
    require_root || return 1
    prompt_input "Database name"
    local db_name="$REPLY"
    prompt_input "Database user"
    local db_user="$REPLY"
    create_db_user "$db_name" "$db_user"
}

db_drop() {
    print_section "Drop Database"
    require_root || return 1
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

    _db_mysql_root_exec "SHOW DATABASES;" || true
    _db_mysql_root_exec "SHOW GLOBAL STATUS LIKE 'Threads_connected';" || true
}
