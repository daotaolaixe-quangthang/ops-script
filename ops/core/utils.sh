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
    logdir=$(dirname "$logfile")
    mkdir -p "$logdir" 2>/dev/null || true
    echo "$msg" >> "$logfile" 2>/dev/null || true
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

# ── File backup ───────────────────────────────────────────────
# Usage: backup_file /path/to/file
# Creates /path/to/file.bak.YYYYMMDD_HHMMSS; prints backup path.
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local backup="${file}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$file" "$backup"
        log_info "Backup: $file → $backup"
        echo "$backup"   # caller can capture path for rollback
    fi
}

# ── Atomic write ──────────────────────────────────────────────
# Write stdin to a temp file then move atomically — avoids partial writes.
# Usage: write_file /path/to/dest <<'EOF'
#        content
#        EOF
write_file() {
    local dest="$1"
    local tmp
    ensure_parent_dir "$dest"
    tmp=$(mktemp)
    cat > "$tmp"
    if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"
        return 0
    fi
    mv "$tmp" "$dest"
    log_info "Wrote: $dest"
}

# Usage: safe_symlink /target/path /link/path
safe_symlink() {
    local target="$1"
    local link_path="$2"

    ensure_parent_dir "$link_path"

    if [[ -L "$link_path" ]] && [[ "$(readlink "$link_path")" == "$target" ]]; then
        return 0
    fi

    [[ -e "$link_path" || -L "$link_path" ]] && rm -f "$link_path"
    ln -s "$target" "$link_path"
    log_info "Linked: $link_path -> $target"
}

# ── Template renderer ─────────────────────────────────────────
# Replaces {{VAR}} placeholders in a template file.
# Usage: render_template /path/to/tpl.tpl VAR1=val1 VAR2=val2
render_template() {
    local tpl="$1"
    shift
    local content
    content=$(cat "$tpl")
    for kv in "$@"; do
        local key="${kv%%=*}"
        local val="${kv#*=}"
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
