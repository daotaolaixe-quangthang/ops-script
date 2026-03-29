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
    # F-22: Credentials must be root-owned (mode 0600, owner root:root).
    local owner="root"

    ensure_parent_dir "$path"
    # P4-1b fix: db-credentials dir must be 700 (not world-traversable).
    # Even though files inside are 600, a world-exec dir allows filename enumeration.
    chmod 700 "$(dirname "$path")" 2>/dev/null || true
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

# Restrict file import/export to a non-existent path = fully disabled.
# IMPORTANT: Do NOT use empty string "" — that means NO restriction (any path allowed).
# Do NOT use the word NULL — MariaDB 10.6 tries to stat it and crashes.
# A non-existent directory path is the correct way to fully disable this feature.
secure_file_priv        = /var/lib/mysql-files-disabled

# Skip reverse DNS on connections (prevents latency + DNS rebinding)
skip_name_resolve       = ON

# Block hosts after 100 consecutive failed connections.
# NOTE: 10 is too aggressive — connection pool restarts after deploy can self-DoS.
max_connect_errors      = 100

# Idle non-interactive connection timeout: 5 minutes
wait_timeout            = 300

# Idle interactive connection timeout: 10 minutes
interactive_timeout     = 600

# Limit packet size to 32MB (prevents large-payload SQL injection attacks)
# Default is 16MB (old) or 64MB (new MariaDB) — 32MB is a reasonable production limit.
max_allowed_packet      = 32M
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

# _db_innodb_log_resize_if_needed
# MariaDB 10.x refuses to start if innodb_log_file_size in the config differs
# from the actual size of /var/lib/mysql/ib_logfile0 on disk.
# This function reads the target size from MARIADB_TUNING_CNF, compares it
# with ib_logfile0, and if they differ:
#   1. Stops MariaDB cleanly so InnoDB writes a full checkpoint.
#   2. Removes the old ib_logfile0 / ib_logfile1.
# MariaDB will then create fresh log files at the correct size on next start.
# Safe to call even when MariaDB is already stopped.
_db_innodb_log_resize_if_needed() {
    local logfile="/var/lib/mysql/ib_logfile0"
    [[ -f "$logfile" ]] || return 0   # fresh install — nothing to resize

    local target_str current_bytes target_bytes num
    target_str=$(grep -E '^[[:space:]]*innodb_log_file_size[[:space:]]*=' \
                     "$MARIADB_TUNING_CNF" 2>/dev/null \
                 | tail -1 | sed 's/.*=[[:space:]]*//' | tr -d ' ')
    [[ -n "$target_str" ]] || return 0

    current_bytes=$(stat -c '%s' "$logfile" 2>/dev/null || echo 0)
    num="${target_str//[^0-9]/}"
    if [[ "$target_str" =~ [Gg] ]]; then
        target_bytes=$(( num * 1024 * 1024 * 1024 ))
    else
        target_bytes=$(( num * 1024 * 1024 ))
    fi

    if [[ "$current_bytes" -eq "$target_bytes" ]]; then
        return 0   # sizes match — no action needed
    fi

    # ── INNODB LOG RESIZE GUARD ─────────────────────────────────────────────
    # Resizing ib_logfile requires: stop MariaDB → delete log files → restart.
    # On a production server with active connections this is DISRUPTIVE.
    # Show the operator exactly what will happen and require confirmation.
    echo ""
    print_warn "InnoDB redo log resize can thiet:"
    print_warn "  Tren disk   : $(( current_bytes / 1024 / 1024 ))M (hien tai)"
    print_warn "  Trong config: ${target_str} (moi)"
    print_warn ""
    print_warn "De resize, InnoDB phai:"
    print_warn "  [1] STOP MariaDB hoan toan (DROP tat ca active connections)"
    print_warn "  [2] XOA /var/lib/mysql/ib_logfile0 va ib_logfile1"
    print_warn "  [3] Khoi dong lai de tao file moi"
    print_warn ""

    # Show active connection count so operator can make an informed decision
    local _active_conn="?"
    if mysql --protocol=socket -u root -e "SELECT 1;" > /dev/null 2>&1; then
        _active_conn=$(mysql --protocol=socket -u root -sNe \
            "SHOW STATUS LIKE 'Threads_connected';" 2>/dev/null \
            | awk '{print $2}' || echo "?")
    fi
    print_warn "  So ket noi dang active: ${_active_conn}"
    print_warn ""
    print_warn "Neu MariaDB stop khong sach (do I/O cao, locked tables): rui ro data corruption."
    print_warn "Neu khong chac chan: huy va chon thoi diem maintenance window."
    echo ""

    if ! prompt_confirm "XAC NHAN stop MariaDB va xoa InnoDB redo log files de resize?"; then
        print_warn "InnoDB log resize bi huy boi operator."
        print_warn "Config log size va ib_logfile tren disk hien KHONG KHOP."
        print_warn "MariaDB co the tu choi khoi dong sau restart neu size khong khop."
        print_warn "Chay 'Database -> Apply tuning' lai sau khi chon thoi diem phu hop."
        log_warn "_db_innodb_log_resize_if_needed: resize cancelled by operator (disk=$(( current_bytes/1024/1024 ))M, config=${target_str})"
        return 0
    fi

    log_warn "_db_innodb_log_resize_if_needed: operator confirmed resize $(( current_bytes/1024/1024 ))M -> ${target_str} (active_conn=${_active_conn})"
    print_warn "Stopping MariaDB for a clean InnoDB checkpoint before removing old log files..."
    systemctl stop mariadb 2>/dev/null || true
    # Wait up to 30 s for clean shutdown (increased from 15 for busy servers)
    local _i=0
    while systemctl is-active mariadb > /dev/null 2>&1 && [[ $_i -lt 30 ]]; do
        sleep 1; (( _i++ )) || true
    done
    if systemctl is-active mariadb > /dev/null 2>&1; then
        print_warn "MariaDB van chua stop sau 30s — xoa ib_logfile co the khong an toan."
        if ! prompt_confirm "Buoc xoa ib_logfile ngay ca khi MariaDB chua stop hoan toan?"; then
            print_warn "InnoDB log resize aborted — ib_logfile giu nguyen."
            log_warn "_db_innodb_log_resize_if_needed: aborted — MariaDB still active after 30s stop"
            return 1
        fi
    fi
    rm -f /var/lib/mysql/ib_logfile0 /var/lib/mysql/ib_logfile1
    print_ok "Old InnoDB log files removed — MariaDB will create new ${target_str} files on next start."
    log_info "_db_innodb_log_resize_if_needed: resized $(( current_bytes/1024/1024 ))M -> ${target_str}"
    # ── END INNODB LOG RESIZE GUARD ─────────────────────────────────────────
}

install_mariadb() {
    print_section "Install MariaDB"
    require_root || return 1

    _db_assert_not_rescue_mode || return 1

    # ── PRODUCTION GUARD ───────────────────────────────────────────────────────
    # Detect if MariaDB is already installed with production data.
    # Re-running install_mariadb on a live server will:
    #   [1] Upgrade MariaDB package (apt) — possible uncontrolled major version jump
    #   [2] Reset root authentication to unix_socket (breaks password-based scripts)
    #   [3] DROP DATABASE test and all test_% named databases
    #   [4] Unconditionally restart MariaDB (drops all active connections)
    #   [5] Possibly delete InnoDB redo log files if log size config changed
    local _db_is_reinstall=0
    local _was_running=0
    local _prod_db_names=""
    local _installed_version=""

    if command -v mysql > /dev/null 2>&1 \
        && mysql --protocol=socket -u root -e "SELECT 1;" > /dev/null 2>&1; then
        _was_running=1
        _installed_version=$(mysql --protocol=socket -u root -sNe \
            "SELECT VERSION();" 2>/dev/null || echo "unknown")
        _prod_db_names=$(mysql --protocol=socket -u root -sNe \
            "SELECT GROUP_CONCAT(SCHEMA_NAME ORDER BY SCHEMA_NAME SEPARATOR ', ')
             FROM information_schema.SCHEMATA
             WHERE SCHEMA_NAME NOT IN
               ('information_schema','performance_schema','mysql','sys');" \
            2>/dev/null || echo "")

        if [[ -n "$_prod_db_names" ]]; then
            _db_is_reinstall=1

            echo ""
            echo "  ╔══════════════════════════════════════════════════════════════╗"
            echo "  ║       ⚠  CANH BAO: PRODUCTION DATABASE DETECTED  ⚠          ║"
            echo "  ╚══════════════════════════════════════════════════════════════╝"
            echo ""
            print_warn "MariaDB ${_installed_version} da duoc cai dat voi du lieu production."
            print_warn "Production databases hien tai: ${_prod_db_names}"
            echo ""
            print_warn "Chay lai install_mariadb tren server nay SE:"
            print_warn "  [1] apt upgrade MariaDB len version moi nhat trong repo"
            print_warn "        -> Co the nang major version (vd 10.6->10.11) khong co ke hoach"
            print_warn "        -> apt co the tu restart MariaDB trong qua trinh upgrade"
            print_warn "  [2] Reset root authentication sang unix_socket"
            print_warn "        -> Neu dang dung password auth: moi script dung -p<pass> se FAIL"
            print_warn "  [3] DROP DATABASE tat ca DB co ten 'test' hoac bat dau bang 'test_'"
            print_warn "        -> Neu production DB ten 'test*': MAT DATA HOAN TOAN, KHONG PHUC HOI"
            print_warn "  [4] Restart MariaDB khong co grace period"
            print_warn "        -> Toan bo active connections bi kill ngay lap tuc"
            print_warn "  [5] Co the xoa InnoDB redo log (ib_logfile0/1) neu log size thay doi"
            print_warn "        -> Rui ro data corruption neu MariaDB stop khong sach"
            echo ""
            print_warn "THAY VAO DO, hay dung cac lenh an toan hon:"
            print_warn "  -> Database -> Secure/re-harden  (co confirm truoc restart)"
            print_warn "  -> Database -> Apply tuning       (validate config truoc restart)"
            echo ""

            # Require typed confirmation — not just Y/n
            local _confirm_text=""
            read -r -p "  Nhap chinh xac chu 'REINSTALL' de xac nhan: " _confirm_text
            if [[ "$_confirm_text" != "REINSTALL" ]]; then
                print_warn "Cancelled. MariaDB reinstall aborted (nhap: '${_confirm_text}')."
                log_info "install_mariadb: cancelled at production guard (input='${_confirm_text}')"
                return 0
            fi
            echo ""
            print_warn "Da xac nhan. Tien hanh reinstall — kiem tra log can than."
            log_warn "install_mariadb: REINSTALL confirmed over production DBs: ${_prod_db_names}"
        fi
    fi
    # ── END PRODUCTION GUARD ────────────────────────────────────────────────────

    # ── PACKAGE UPGRADE WARNING ─────────────────────────────────────────────────
    # If MariaDB already installed, show current vs apt candidate version before upgrade.
    if [[ "$_was_running" -eq 1 ]]; then
        local _apt_candidate
        _apt_candidate=$(apt-cache policy mariadb-server 2>/dev/null \
            | awk '/Candidate:/{print $2}' || echo "unknown")
        echo ""
        print_warn "Kiem tra phien ban package:"
        print_warn "  Dang cai      : MariaDB ${_installed_version}"
        print_warn "  apt candidate : ${_apt_candidate}"
        if [[ "$_apt_candidate" != "unknown" && "$_apt_candidate" != *"${_installed_version%%.*}"* ]]; then
            print_warn "  *** Phien ban candidate KHAC phien ban hien tai — se co UPGRADE! ***"
        fi
        echo ""
        if ! prompt_confirm "Tiep tuc chay apt install/upgrade mariadb-server?"; then
            print_warn "Cancelled tai buoc apt upgrade."
            log_info "install_mariadb: cancelled at apt upgrade confirmation"
            return 0
        fi
    fi
    # ── END PACKAGE UPGRADE WARNING ─────────────────────────────────────────────

    apt_update
    apt_install mariadb-server mariadb-client
    service_enable mariadb
    service_start mariadb

    _db_set_bind_localhost

    if ! command -v openssl > /dev/null 2>&1; then
        apt_install openssl
    fi

    # Security baseline — equivalent to mysql_secure_installation (full).
    # Remove anonymous users (no username = any host can connect without credentials)
    _db_mysql_socket_exec "DELETE FROM mysql.user WHERE User='';"
    # Remove remote root — root must only connect via local unix socket
    _db_mysql_socket_exec "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
    # Drop test database AND test_% wildcard databases (mysql_secure_installation removes both)
    _db_mysql_socket_exec "DROP DATABASE IF EXISTS test;"
    _db_mysql_socket_exec "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
    # Enforce unix_socket auth for root — no password needed/possible from remote
    _db_mysql_socket_exec "ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket;"
    _db_mysql_socket_exec "FLUSH PRIVILEGES;"
    print_ok "Security baseline applied: anonymous users removed, test DBs dropped, root restricted to localhost."

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

    # Resize ib_logfile* if innodb_log_file_size was changed by tune_mariadb above.
    # _db_innodb_log_resize_if_needed has its own confirm prompt when server is live.
    _db_innodb_log_resize_if_needed

    # ── FINAL RESTART CONFIRMATION ───────────────────────────────────────────
    # Fresh install: no active connections — restart unconditionally.
    # Reinstall over running server: warn and confirm before dropping connections.
    if [[ "$_db_is_reinstall" -eq 1 ]]; then
        echo ""
        print_warn "MariaDB restart se DROP toan bo active connections ngay lap tuc."
        print_warn "Apps (Node.js, PHP-FPM) se gap loi 'MySQL server has gone away' trong ~5-30s."
        if ! prompt_confirm "Restart MariaDB ngay bay gio?"; then
            print_warn "Restart skipped. Config moi se ap dung lan restart tiep theo."
            log_info "install_mariadb: final restart skipped by operator on reinstall path"
            print_ok "MariaDB hardened and tuned (restart pending — run: systemctl restart mariadb)."
            return 0
        fi
    fi
    # ── END FINAL RESTART CONFIRMATION ──────────────────────────────────────

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
            # < 1500 MB RAM — 40% of RAM for buffer pool
            innodb_buffer_pool_size="$(( RAM_MB * 40 / 100 ))M"
            innodb_buffer_pool_instances="1"
            innodb_log_file_size="64M"
            max_connections="80"
            tmp_table_size="32M"
            max_heap_table_size="32M"
            ;;
        M)
            # 1500–5000 MB RAM — P3-F fix: was hardcoded 2G; now 50% of actual RAM
            innodb_buffer_pool_size="$(( RAM_MB * 50 / 100 ))M"
            innodb_buffer_pool_instances="2"
            innodb_log_file_size="256M"
            max_connections="150"
            tmp_table_size="64M"
            max_heap_table_size="64M"
            ;;
        L)
            # > 5000 MB RAM — P3-F fix: was hardcoded 5G; now 60% of actual RAM
            innodb_buffer_pool_size="$(( RAM_MB * 60 / 100 ))M"
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

    # P5-F: MariaDB 10.9+ deprecated innodb_log_file_size in favour of
    # innodb_redo_log_capacity (bytes). Use the correct directive per version.
    local _mariadb_major
    _mariadb_major=$(mysqld --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "0.0")
    local _innodb_log_directive
    if awk -v v="$_mariadb_major" 'BEGIN{exit !(v+0 >= 10.9)}'; then
        # Convert NNNMb string to bytes for innodb_redo_log_capacity
        local _log_bytes
        _log_bytes=$(( ${innodb_log_file_size//[^0-9]/} * 1024 * 1024 ))
        _innodb_log_directive="innodb_redo_log_capacity = ${_log_bytes}"
    else
        _innodb_log_directive="innodb_log_file_size         = ${innodb_log_file_size}"
    fi

    backup_file "$MARIADB_TUNING_CNF" >/dev/null || true

    # F-12 fix: Use awk strip+append (same pattern as _db_apply_security_hardening,
    # _db_setup_ssl, _db_setup_logging) so that calling tune_mariadb standalone
    # never clobbers existing security/SSL/logging blocks in the tuning file.
    #
    # Safe failure mode: if this function crashes after the strip but before the
    # append, the perf block is absent but security/SSL/logging blocks survive
    # untouched — MariaDB remains hardened on next restart.

    # Create file with [mysqld] header if it doesn't exist yet (fresh install).
    if [[ ! -f "$MARIADB_TUNING_CNF" ]]; then
        printf '[mysqld]\n' > "$MARIADB_TUNING_CNF"
        chmod 644 "$MARIADB_TUNING_CNF"
    fi

    # Strip previous performance tuning block (idempotent re-runs).
    local _tune_tmp
    _tune_tmp=$(mktemp)
    awk '/^# --- OPS PERFORMANCE TUNING/,/^# --- END OPS PERFORMANCE TUNING ---$/ { next } { print }' \
        "$MARIADB_TUNING_CNF" > "$_tune_tmp"
    mv "$_tune_tmp" "$MARIADB_TUNING_CNF"

    # Append the new performance tuning block.
    cat >> "$MARIADB_TUNING_CNF" <<EOF_TUNE

# --- OPS PERFORMANCE TUNING (Tier: ${OPS_TIER:-M}) ---
# Generated by ops-script tune_mariadb(). Do not edit manually.

# InnoDB buffer pool — most important MariaDB setting (~70% of available RAM)
innodb_buffer_pool_size      = ${innodb_buffer_pool_size}
innodb_buffer_pool_instances = ${innodb_buffer_pool_instances}

# InnoDB redo log — larger = fewer checkpoint flushes under write load
${_innodb_log_directive}

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
        # Resize ib_logfile* if innodb_log_file_size changed vs what's on disk.
        # _db_innodb_log_resize_if_needed has its own confirm prompt.
        _db_innodb_log_resize_if_needed

        # ── STANDALONE RESTART CONFIRMATION ─────────────────────────────────
        # tune_mariadb called standalone (not via install_mariadb) means MariaDB
        # is potentially serving production traffic. Confirm before restarting.
        local _tune_active_conn="?"
        if mysql --protocol=socket -u root -e "SELECT 1;" > /dev/null 2>&1; then
            _tune_active_conn=$(mysql --protocol=socket -u root -sNe \
                "SHOW STATUS LIKE 'Threads_connected';" 2>/dev/null \
                | awk '{print $2}' || echo "?")
        fi
        echo ""
        print_warn "MariaDB restart can thiet de ap dung config tuning moi."
        print_warn "  So ket noi dang active : ${_tune_active_conn}"
        print_warn "  Thoi gian downtime uoc tinh: 3-10 giay"
        print_warn "  Apps se gap loi 'MySQL server has gone away' trong khoang thoi gian nay."
        echo ""
        if ! prompt_confirm "Restart MariaDB ngay bay gio de ap dung tuning?"; then
            print_warn "Restart skipped. Config moi (${MARIADB_TUNING_CNF}) da duoc ghi."
            print_warn "Chay 'systemctl restart mariadb' vao thoi diem phu hop de ap dung."
            log_info "tune_mariadb: restart skipped by operator (active_conn=${_tune_active_conn})"
            return 0
        fi
        log_info "tune_mariadb: operator confirmed restart (active_conn=${_tune_active_conn})"
        # ── END STANDALONE RESTART CONFIRMATION ─────────────────────────────

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
    log_info "create_db_user: user '${db_user}'@localhost created on db '${db_name}'; creds=${credentials_file}"
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
    log_info "db_install: MariaDB installed"
}

db_secure() {
    # F-15: Do NOT call install_mariadb here — that runs a full reinstall + unconditional
    # service_restart, which silently drops all active DB connections on a live server.
    # Instead: apply only the hardening config and prompt before restarting.
    print_section "Re-harden MariaDB (no reinstall)"
    require_root || return 1
    _db_assert_not_rescue_mode || return 1

    if ! service_active mariadb 2>/dev/null; then
        print_error "MariaDB is not running. Start it first: systemctl start mariadb"
        return 1
    fi

    _db_apply_security_hardening
    _db_setup_ssl
    _db_setup_logging

    echo ""
    print_warn "MariaDB must restart to apply the new hardening settings."
    print_warn "This will briefly drop all active database connections."
    if prompt_confirm "Restart MariaDB now?"; then
        service_restart mariadb
        print_ok "MariaDB restarted with hardened configuration."
        log_info "db_secure: hardening applied; MariaDB restarted"
    else
        print_warn "Restart skipped. Settings will take effect on next MariaDB restart."
        log_info "db_secure: hardening applied; restart skipped (operator choice)"
    fi
}

db_apply_tuning() {
    # P-01 fix: DB_TUNING_NO_RESTART=1 prevents tune_mariadb from restarting
    # MariaDB internally — avoids a double restart when db_apply_tuning also
    # restarts at the end after all blocks are written.
    DB_TUNING_NO_RESTART=1 tune_mariadb
    _db_apply_security_hardening
    _db_setup_ssl
    _db_setup_logging

    # P-01 fix: validate the assembled config BEFORE restarting MariaDB.
    # Catching a malformed config here prevents a failed restart from taking
    # MariaDB offline. mysqld --verbose --help parses the config and exits.
    if ! mysqld --defaults-extra-file="$MARIADB_TUNING_CNF" \
            --verbose --help > /dev/null 2>&1; then
        print_error "P-01: MariaDB config validation failed — NOT restarting."
        print_error "      Check ${MARIADB_TUNING_CNF} and run 'db_apply_tuning' again."
        log_error "db_apply_tuning: mysqld config validation failed — restart skipped"
        return 1
    fi

    # Resize ib_logfile* if innodb_log_file_size changed vs what's on disk.
    _db_innodb_log_resize_if_needed
    service_restart mariadb
    print_ok "MariaDB fully re-hardened and restarted."
    log_info "db_apply_tuning: tuning applied and MariaDB restarted (tier=${OPS_TIER:-M})"
}

# db_audit — show current compliance status for all OPS-managed settings.
db_audit() {
    print_section "MariaDB Compliance Audit"
    require_root || return 1

    _db_assert_not_rescue_mode || return 1

    local pass=0 warn=0 fail=0

    # P5-C: Inner function named with _db_ prefix to avoid global scope collision.
    # trap RETURN guarantees cleanup even on early return (e.g., _db_assert_not_rescue_mode).
    trap 'unset -f _db_audit_check 2>/dev/null' RETURN
    _db_audit_check() {
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

    _db_audit_check "Network isolation"       "bind_address"          "127\.0\.0\.1"
    _db_audit_check "SSL enabled"             "have_ssl"              "YES"
    _db_audit_check "local_infile disabled"   "local_infile"          "OFF"
    # secure_file_priv must point to a non-existent path to fully disable file I/O.
    # Empty string "" = NO restriction (any path allowed) — that is INSECURE.
    # We expect the path /var/lib/mysql-files-disabled which does not exist on disk.
    _db_audit_check "secure_file_priv disabled" "secure_file_priv"   ".*mysql-files-disabled.*|/nonexistent.*"  "WARN"
    _db_audit_check "skip_name_resolve"       "skip_name_resolve"     "ON"
    _db_audit_check "slow_query_log ON"       "slow_query_log"        "ON"            "WARN"
    # P3-3 fix: old regex [1-9][0-9]?[0-9]? matched values 1-999 -- 600 would
    # show as PASS incorrectly. New regex anchors exact range 1-300 only.
    _db_audit_check "wait_timeout<=300"       "wait_timeout"          "[1-9]|[1-9][0-9]|[12][0-9]{2}|300"
    _db_audit_check "innodb_flush_neighbors"  "innodb_flush_neighbors" "0"
    _db_audit_check "key_buffer_size<=16MB"   "key_buffer_size"       "[0-9]{1,7}|1[0-5][0-9]{5}|16777216"
    # Check max_allowed_packet <= 32MB (33554432 bytes)
    _db_audit_check "max_allowed_packet<=32MB" "max_allowed_packet"   "[0-9]{1,7}|[12][0-9]{7}|3[0-2][0-9]{6}|3355[0-4][0-9]{3}|33554432"  "WARN"

    # Check no anonymous users remain (counts should be 0)
    local anon_count
    anon_count=$(mysql --protocol=socket -u root -sNe "SELECT COUNT(*) FROM mysql.user WHERE User='';" 2>/dev/null || echo "?")
    if [[ "$anon_count" == "0" ]]; then
        printf '  [\033[0;32mPASS\033[0m] %-35s %s\n' "anonymous_users" "0 (none)"
        (( pass++ )) || true
    else
        printf '  [\033[0;31mFAIL\033[0m] %-35s got=%s anonymous users remaining\n' "anonymous_users" "$anon_count"
        (( fail++ )) || true
    fi

    # Check no test database exists
    local test_db_count
    test_db_count=$(mysql --protocol=socket -u root -sNe "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME LIKE 'test%';" 2>/dev/null || echo "?")
    if [[ "$test_db_count" == "0" ]]; then
        printf '  [\033[0;32mPASS\033[0m] %-35s %s\n' "test_databases" "0 (none)"
        (( pass++ )) || true
    else
        printf '  [\033[0;33mWARN\033[0m] %-35s found=%s test/test_%% databases\n' "test_databases" "$test_db_count"
        (( warn++ )) || true
    fi

    unset -f _db_audit_check

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
    log_info "db_create: created database '${db_name}'"
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

    # F-23: Scan credentials dir for any OPS-managed app that uses this database.
    local cred_file registered_apps=()
    if [[ -d "$DB_CREDENTIALS_DIR" ]]; then
        for cred_file in "${DB_CREDENTIALS_DIR}"/*.conf; do
            [[ -f "$cred_file" ]] || continue
            local file_db_name
            file_db_name=$(grep -E '^DB_NAME=' "$cred_file" | head -1 | cut -d'=' -f2- | tr -d '"'"'" )
            if [[ "$file_db_name" == "$db_name" ]]; then
                registered_apps+=("$(basename "$cred_file")")
            fi
        done
    fi

    if [[ "${#registered_apps[@]}" -gt 0 ]]; then
        print_warn "WARNING: The following OPS-managed app(s) use database '${db_name}':"
        local app
        for app in "${registered_apps[@]}"; do
            print_warn "  • ${app}"
        done
        print_warn "Dropping this database will break the app(s) listed above."
        echo ""
        read -r -p "  Type 'yes' to confirm you understand and want to drop '${db_name}': " _drop_confirm
        if [[ "$_drop_confirm" != "yes" ]]; then
            print_warn "Cancelled."
            return 0
        fi
    else
        if ! prompt_confirm "Drop database '${db_name}'?"; then
            print_warn "Cancelled."
            return 0
        fi
    fi

    _db_mysql_root_exec "DROP DATABASE IF EXISTS \`${db_name}\`;"
    print_ok "Database dropped: ${db_name}"
    log_info "db_drop: dropped database '${db_name}'"
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
