#!/usr/bin/env bash
# ============================================================
# ops/core/utils.sh
# Purpose:  Safe file writes, backups, logging, idempotence helpers
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# Source this file; do NOT execute directly.
set -euo pipefail
IFS=$'\n\t'

# ── Logging ───────────────────────────────────────────────────
# Writes to stdout AND appends to $OPS_LOG_FILE.
# OPS_LOG_FILE must be set (done by core/env.sh).
_log_append() {
    local msg="$1"
    local logfile="${OPS_LOG_FILE:-/tmp/ops.log}"
    local logdir
    local euid="${EUID:-$(id -u)}"
    logdir=$(dirname "$logfile")

    if [[ "$logfile" == /var/log/ops/* && "$euid" -eq 0 ]]; then
        mkdir -p "$logdir" 2>/dev/null || true
        chmod 755 "$logdir" 2>/dev/null || true
        chown root:root "$logdir" 2>/dev/null || true
        touch "$logfile" 2>/dev/null || true
        chmod 640 "$logfile" 2>/dev/null || true
        chown root:root "$logfile" 2>/dev/null || true
    else
        mkdir -p "$logdir" 2>/dev/null || true
        touch "$logfile" 2>/dev/null || true
    fi

    printf '%s\n' "$msg" >> "$logfile" 2>/dev/null || true
}

log_info()  {
    local msg="[INFO]  $(date '+%F %T') $*"
    echo "$msg"
    _log_append "$msg"
}

log_warn()  {
    local msg="[WARN]  $(date '+%F %T') $*"
    echo "$msg" >&2
    _log_append "$msg"
}

log_error() {
    local msg="[ERROR] $(date '+%F %T') $*"
    echo "$msg" >&2
    _log_append "$msg"
}

# ── Directory helpers ─────────────────────────────────────────
ensure_dir() {
    local dir="$1"
    [[ -d "$dir" ]] || mkdir -p "$dir"
}

ensure_parent_dir() {
    local file_path="$1"
    ensure_dir "$(dirname "$file_path")"
}

# ── Snapshot / rollback helpers ───────────────────────────────
snapshot_path_state() {
    local path="$1"
    local snapshot_root="$2"
    local name="$3"

    [[ -n "$snapshot_root" ]] || return 1
    ensure_dir "$snapshot_root"

    if [[ -e "$path" || -L "$path" ]]; then
        printf 'yes' > "${snapshot_root}/${name}.exists"
        cp -a "$path" "${snapshot_root}/${name}"
    else
        printf 'no' > "${snapshot_root}/${name}.exists"
    fi
}

restore_path_snapshot() {
    local path="$1"
    local snapshot_root="$2"
    local name="$3"
    local marker="${snapshot_root}/${name}.exists"

    [[ -n "$snapshot_root" && -d "$snapshot_root" ]] || return 0

    if [[ -f "$marker" && "$(<"$marker")" == "yes" ]]; then
        rm -rf "$path"
        ensure_dir "$(dirname "$path")"
        cp -a "${snapshot_root}/${name}" "$path"
    else
        rm -rf "$path"
    fi
}

snapshot_ufw_state() {
    local snapshot_root="$1"
    snapshot_path_state "/etc/ufw/user.rules" "$snapshot_root" "ufw-user-rules"
    snapshot_path_state "/etc/ufw/user6.rules" "$snapshot_root" "ufw-user6-rules"
    snapshot_path_state "/etc/ufw/ufw.conf" "$snapshot_root" "ufw-conf"
}

restore_ufw_state() {
    local snapshot_root="$1"
    [[ -n "$snapshot_root" && -d "$snapshot_root" ]] || return 0

    restore_path_snapshot "/etc/ufw/user.rules" "$snapshot_root" "ufw-user-rules"
    restore_path_snapshot "/etc/ufw/user6.rules" "$snapshot_root" "ufw-user6-rules"
    restore_path_snapshot "/etc/ufw/ufw.conf" "$snapshot_root" "ufw-conf"

    if command -v ufw >/dev/null 2>&1; then
        if grep -Eq '^ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null; then
            ufw --force enable >/dev/null 2>&1 || ufw reload >/dev/null 2>&1 || true
        else
            ufw --force disable >/dev/null 2>&1 || true
        fi
    fi
}

# ── File backup ───────────────────────────────────────────────
# Usage: backup_file /path/to/file
# Creates /path/to/file.bak.YYYYMMDD_HHMMSS; prints backup path.
backup_file() {
    local file="$1"
    if [[ -e "$file" || -L "$file" ]]; then
        local backup="${file}.bak.$(date +%Y%m%d_%H%M%S)"
        cp -a -- "$file" "$backup"
        log_info "Backup: $file → $backup"
        echo "$backup"   # caller can capture path for rollback
    fi
}

# ── Atomic write ──────────────────────────────────────────────
# Write stdin to a temp file in the destination directory, then rename.
# Existing metadata is preserved when rewriting an existing file.
# Usage: write_file /path/to/dest <<'EOF'
#        content
#        EOF
write_file() {
    local dest="$1"
    local tmp

    ensure_parent_dir "$dest"
    tmp=$(mktemp "${dest}.tmp.XXXXXX")
    cat > "$tmp"

    if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"
        return 0
    fi

    if [[ -e "$dest" ]]; then
        chmod --reference="$dest" "$tmp" 2>/dev/null || true
        chown --reference="$dest" "$tmp" 2>/dev/null || true
    fi

    mv -f "$tmp" "$dest"
    log_info "Wrote: $dest"
}

# Usage: safe_symlink /target/path /link/path
safe_symlink() {
    local target="$1"
    local link_path="$2"
    local current_target=""
    local target_name
    local link_dir
    local link_name
    local tmp_link
    target_name=$(basename "$target")

    ensure_parent_dir "$link_path"
    link_dir=$(dirname "$link_path")
    link_name=$(basename "$link_path")

    if [[ -L "$link_path" ]]; then
        current_target="$(readlink "$link_path")"
        if [[ "$current_target" == "$target" ]]; then
            return 0
        fi

        case "$current_target" in
            /opt/ops/*|/opt/ops-script/*)
                if [[ "$(basename "$current_target")" != "$target_name" ]]; then
                    log_error "Refusing to replace unexpected OPS symlink: $link_path -> $current_target"
                    return 1
                fi
                ;;
            *)
                log_error "Refusing to replace non-OPS symlink: $link_path -> $current_target"
                return 1
                ;;
        esac
    elif [[ -e "$link_path" ]]; then
        if [[ -d "$link_path" ]]; then
            log_error "Refusing to replace directory at $link_path"
        else
            log_error "Refusing to replace regular file at $link_path"
        fi
        return 1
    fi

    tmp_link=$(mktemp -p "$link_dir" ".${link_name}.tmp.XXXXXX")
    rm -f "$tmp_link"
    if ! ln -s "$target" "$tmp_link"; then
        log_error "Failed to stage symlink: $tmp_link -> $target"
        return 1
    fi
    if ! mv -Tf "$tmp_link" "$link_path"; then
        rm -f "$tmp_link"
        log_error "Failed to replace symlink: $link_path"
        return 1
    fi

    log_info "Linked: $link_path -> $target"
}

# ── Template renderer ─────────────────────────────────────────
# Replaces {{VAR}} placeholders in a template file.
# Usage: render_template /path/to/tpl.tpl VAR1=val1 VAR2=val2
#
# P3-1 fix: val is sanitized before Bash parameter expansion.
# ${content//.../${val}} treats & and \ specially in replacement strings.
# A val containing & would be replaced by the full matched string; a val
# containing \ would trigger escape sequences. We escape both beforehand.
render_template() {
    local tpl="$1"
    shift
    local content
    content=$(cat "$tpl")
    for kv in "$@"; do
        local key="${kv%%=*}"
        local val="${kv#*=}"
        # Escape backslash first (must be first to avoid double-escaping),
        # then & (Bash treats & as "matched string" in substitution patterns).
        val="${val//\\/\\\\}"
        val="${val//&/\\&}"
        content="${content//\{\{${key}\}\}/${val}}"
    done
    echo "$content"
}

# ── OPS conf helpers (thin wrappers; full impl in env.sh) ─────
# Usage: ops_conf_set <filename> <KEY> <VALUE>
# Delegated to env.sh implementation; duplicated signature here
# so utils.sh users have a clear reference.
# NOTE: env.sh must be sourced before utils.sh for this to work.

# ops_conf_set and ops_conf_get are defined in core/env.sh.
# Do not redefine here — they depend on OPS_CONFIG_DIR which env.sh sets.

# ── Idempotence guards ────────────────────────────────────────
# Usage: is_installed nginx && echo "already installed"
is_installed() { command -v "$1" &>/dev/null; }

# Usage: service_active nginx && echo "running"
service_active() { systemctl is-active --quiet "$1"; }

# Usage: file_contains /etc/hosts "myhost" && echo "already there"
file_contains() {
    local file="$1"
    local pattern="$2"
    grep -q "$pattern" "$file" 2>/dev/null
}

# ── Root privilege guard ──────────────────────────────────────
# Usage: require_root || return 1
# Call at the top of any action function that needs root.
# Prints a clear warning and returns 1 so the menu loop continues gracefully.
require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        echo ""
        print_error "This action requires root privileges."
        print_warn  "Please run:  sudo ops"
        echo ""
        return 1
    fi
}
# alias for compatibility
assert_root() { require_root; }
