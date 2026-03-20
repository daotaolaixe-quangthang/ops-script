#!/usr/bin/env bash
# ============================================================
# ops/modules/backup.sh
# Purpose:  DB dump and config archive backup helpers — P2-05
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# Called by bin/ops (sourced). Do NOT add set -euo pipefail here.
#
# Backup dir layout:
#   /var/backups/ops/db/       — database dumps (.sql.gz, chmod 0600)
#   /var/backups/ops/config/   — config archives (.tar.gz, chmod 0600)
#
# Retention: warn when > 7 files in a backup subdir. Never auto-delete.

BACKUP_BASE_DIR="/var/backups/ops"
BACKUP_DB_DIR="${BACKUP_BASE_DIR}/db"
BACKUP_CONFIG_DIR="${BACKUP_BASE_DIR}/config"
BACKUP_RETENTION_WARN=7
BACKUP_DISK_WARN_PERCENT=80

# ── Internal helpers ──────────────────────────────────────────

_backup_ensure_dirs() {
    mkdir -p "$BACKUP_DB_DIR" "$BACKUP_CONFIG_DIR"
    chmod 700 "$BACKUP_BASE_DIR" "$BACKUP_DB_DIR" "$BACKUP_CONFIG_DIR"
}

_backup_timestamp() {
    date '+%Y%m%d-%H%M%S'
}

_backup_check_disk() {
    local dir="${1:-$BACKUP_BASE_DIR}"
    local pct
    pct=$(df --output=pcent "$dir" 2>/dev/null | tail -1 | tr -d ' %' || echo 0)
    if (( pct >= BACKUP_DISK_WARN_PERCENT )); then
        print_warn "Disk usage is ${pct}% on $(df --output=target "$dir" 2>/dev/null | tail -1 | xargs)."
        print_warn "Consider freeing space before creating more backups."
    fi
}

_backup_retention_warn() {
    local dir="$1"
    local ext="$2"
    local count
    count=$(find "$dir" -maxdepth 1 -name "*${ext}" 2>/dev/null | wc -l)
    if (( count > BACKUP_RETENTION_WARN )); then
        print_warn "Found ${count} backup files in ${dir} (retention warning: > ${BACKUP_RETENTION_WARN})."
        print_warn "Remove old backups manually: ls -lth ${dir}"
    fi
}

_backup_db_root_exec() {
    # Reuse database.sh socket/password auth pattern
    local sql="$1"
    if mysql --protocol=socket -u root -e "$sql" >/dev/null 2>&1; then
        mysql --protocol=socket -u root -e "$sql"
        return $?
    fi
    local pass_file="${OPS_CONFIG_DIR:-/etc/ops}/.db-root-password"
    if [[ -f "$pass_file" ]]; then
        local pw
        pw=$(cat "$pass_file")
        MYSQL_PWD="$pw" mysql -u root -e "$sql"
        return $?
    fi
    print_error "Cannot authenticate as MariaDB root. DB dump aborted."
    return 1
}

# ── DB dump functions ─────────────────────────────────────────

# backup_dump_db <dbname>
# Dumps a single database to /var/backups/ops/db/<dbname>-<ts>.sql.gz
backup_dump_db() {
    local db_name="${1:-}"
    require_root || return 1
    if [[ -z "$db_name" ]]; then
        print_error "Usage: backup_dump_db <dbname>"
        return 1
    fi

    _backup_ensure_dirs
    _backup_check_disk "$BACKUP_DB_DIR"

    local ts
    ts=$(_backup_timestamp)
    local out_file="${BACKUP_DB_DIR}/${db_name}-${ts}.sql.gz"

    print_section "DB Dump: ${db_name}"
    print_warn "Dumping ${db_name} → ${out_file}"

    if mysql --protocol=socket -u root -e "SELECT 1;" >/dev/null 2>&1; then
        mysqldump --protocol=socket -u root \
            --single-transaction --quick --lock-tables=false \
            "$db_name" 2>/dev/null | gzip -9 > "$out_file"
    else
        local pass_file="${OPS_CONFIG_DIR:-/etc/ops}/.db-root-password"
        if [[ -f "$pass_file" ]]; then
            local pw
            pw=$(cat "$pass_file")
            MYSQL_PWD="$pw" mysqldump -u root \
                --single-transaction --quick --lock-tables=false \
                "$db_name" 2>/dev/null | gzip -9 > "$out_file"
        else
            print_error "Cannot authenticate as MariaDB root. Dump aborted."
            rm -f "$out_file"
            return 1
        fi
    fi

    chmod 600 "$out_file"

    # Verify
    if gzip -t "$out_file" 2>/dev/null; then
        local size
        size=$(du -sh "$out_file" 2>/dev/null | cut -f1)
        print_ok "Dump created and verified: ${out_file} (${size})"
    else
        print_error "Dump file failed integrity check: ${out_file}"
        rm -f "$out_file"
        return 1
    fi

    _backup_retention_warn "$BACKUP_DB_DIR" ".sql.gz"
    log_info "backup_dump_db: ${db_name} → ${out_file}"
}

# backup_dump_all_dbs
# Dumps all non-system databases to individual files.
backup_dump_all_dbs() {
    print_section "DB Dump: All Databases"
    require_root || return 1

    local dbs_raw
    if mysql --protocol=socket -u root -e "SHOW DATABASES;" >/dev/null 2>&1; then
        dbs_raw=$(mysql --protocol=socket -u root -N -e "SHOW DATABASES;" 2>/dev/null)
    else
        local pass_file="${OPS_CONFIG_DIR:-/etc/ops}/.db-root-password"
        if [[ -f "$pass_file" ]]; then
            local pw
            pw=$(cat "$pass_file")
            dbs_raw=$(MYSQL_PWD="$pw" mysql -u root -N -e "SHOW DATABASES;" 2>/dev/null)
        else
            print_error "Cannot authenticate as MariaDB root."
            return 1
        fi
    fi

    local db skipped=0 dumped=0
    while IFS= read -r db; do
        case "$db" in
            information_schema|performance_schema|mysql|sys|"")
                (( skipped++ )) || true
                continue
                ;;
        esac
        if backup_dump_db "$db"; then
            (( dumped++ )) || true
        fi
    done <<< "$dbs_raw"

    print_ok "All-DB dump complete: ${dumped} database(s) dumped, ${skipped} system DB(s) skipped."
    log_info "backup_dump_all_dbs: dumped=${dumped} skipped=${skipped}"
}

# ── Config archive function ───────────────────────────────────

backup_archive_configs() {
    print_section "Config Archive"
    require_root || return 1

    _backup_ensure_dirs
    _backup_check_disk "$BACKUP_CONFIG_DIR"

    local ts
    ts=$(_backup_timestamp)
    local out_file="${BACKUP_CONFIG_DIR}/ops-config-${ts}.tar.gz"

    # Directories to archive (only include if they exist)
    local archive_paths=()
    local candidate
    for candidate in \
        "/etc/ops" \
        "/etc/nginx/sites-available" \
        "/etc/nginx/snippets"
    do
        [[ -e "$candidate" ]] && archive_paths+=("$candidate")
    done

    if [[ "${#archive_paths[@]}" -eq 0 ]]; then
        print_error "No config paths found to archive."
        return 1
    fi

    print_warn "Archiving: ${archive_paths[*]}"
    print_warn "Output: ${out_file}"

    # Create archive — exclude secret file content safely (we DO include for backup, just ensure 0600)
    tar -czf "$out_file" "${archive_paths[@]}" 2>/dev/null || {
        print_error "tar archive failed."
        rm -f "$out_file"
        return 1
    }

    chmod 600 "$out_file"

    # Verify
    if tar -tzf "$out_file" >/dev/null 2>&1; then
        local size
        size=$(du -sh "$out_file" 2>/dev/null | cut -f1)
        print_ok "Config archive created and verified: ${out_file} (${size})"
    else
        print_error "Archive integrity check failed: ${out_file}"
        rm -f "$out_file"
        return 1
    fi

    _backup_retention_warn "$BACKUP_CONFIG_DIR" ".tar.gz"
    log_info "backup_archive_configs: ${out_file}"
}

# ── Restore guidance ──────────────────────────────────────────

backup_show_restore_guidance() {
    print_section "Restore Guidance"
    cat <<'GUIDANCE'

  ── DB Restore ──────────────────────────────────────────────
  # Restore a single database dump:
  gunzip < /var/backups/ops/db/<dbname>-<ts>.sql.gz | mysql -u root <dbname>

  # Verify the DB after restore:
  mysql -u root -e "SHOW TABLES;" <dbname>

  ── Nginx Config Restore ─────────────────────────────────────
  # Extract nginx sites from archive:
  tar -xzf /var/backups/ops/config/ops-config-<ts>.tar.gz \
      -C / etc/nginx/sites-available/

  # Test and reload:
  nginx -t && systemctl reload nginx

  ── OPS Config Restore ────────────────────────────────────────
  # Extract OPS config:
  tar -xzf /var/backups/ops/config/ops-config-<ts>.tar.gz \
      -C / etc/ops/

  # Secret files — verify permissions after restore:
  chmod 600 /etc/ops/.telegram-bot-token
  chmod 600 /etc/ops/.db-root-password
  chmod 600 /etc/ops/.codex-api-key

  NOTE: Restore is never automatic. Always verify after restoring.
        Keep at least 2 recent backups before making large changes.

GUIDANCE
}

# ── List backups ──────────────────────────────────────────────

backup_list() {
    print_section "Current Backups"
    echo ""
    echo "  ── DB dumps (${BACKUP_DB_DIR}) ─────────────────────"
    if ls "${BACKUP_DB_DIR}/"*.sql.gz 2>/dev/null | head -20; then
        true
    else
        echo "  (none)"
    fi
    echo ""
    echo "  ── Config archives (${BACKUP_CONFIG_DIR}) ──────────"
    if ls "${BACKUP_CONFIG_DIR}/"*.tar.gz 2>/dev/null | head -20; then
        true
    else
        echo "  (none)"
    fi
    echo ""
    _backup_check_disk "$BACKUP_BASE_DIR"
}

# ── Backup menu ───────────────────────────────────────────────

menu_backup() {
    while true; do
        print_section "Backup Helpers"
        echo "  1) Dump single database"
        echo "  2) Dump all databases"
        echo "  3) Archive configs (/etc/ops, nginx sites)"
        echo "  4) Show restore guidance"
        echo "  5) List current backups"
        echo "  0) Back"
        echo ""
        read -r -p "Select: " choice
        case "$choice" in
            1) _backup_menu_dump_one        || true; press_enter ;;
            2) backup_dump_all_dbs          || true; press_enter ;;
            3) backup_archive_configs       || true; press_enter ;;
            4) backup_show_restore_guidance || true; press_enter ;;
            5) backup_list                  || true; press_enter ;;
            0) return                               ;;
            *) print_warn "Invalid option"          ;;
        esac
    done
}

_backup_menu_dump_one() {
    prompt_input "Database name to dump"
    local db_name="$REPLY"
    if [[ -z "$db_name" ]]; then
        print_error "Database name cannot be empty."
        return 1
    fi
    backup_dump_db "$db_name"
}
