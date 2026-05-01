#!/usr/bin/env bash
# ============================================================
# ops/core/env.sh
# Purpose:  Environment detection and global constants
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# Source this file; do NOT execute directly.
set -euo pipefail
IFS=$'\n\t'

# ── Runtime paths ─────────────────────────────────────────────
export OPS_ROOT="${OPS_ROOT:-/opt/ops}"
export OPS_CONFIG_DIR="${OPS_CONFIG_DIR:-/etc/ops}"
export OPS_LOG_DIR="${OPS_LOG_DIR:-/var/log/ops}"
export OPS_LOG_FILE="${OPS_LOG_FILE:-$OPS_LOG_DIR/ops.log}"

_ops_user_exists() {
    local candidate="${1:-}"
    [[ -n "$candidate" ]] && id "$candidate" >/dev/null 2>&1
}

_ops_non_root_user_exists() {
    local candidate="${1:-}"
    [[ -n "$candidate" && "$candidate" != "root" ]] && _ops_user_exists "$candidate"
}

_ops_first_sudo_user() {
    getent group sudo 2>/dev/null | cut -d: -f4 | tr ',' '\n' | grep -v '^root$' | head -n1 || true
}

_ops_valid_conf_key() {
    local key="${1:-}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

# ── OS detection ──────────────────────────────────────────────
detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION_ID="${VERSION_ID:-unknown}"
    else
        OS_ID="unknown"
        OS_VERSION_ID="unknown"
    fi
    export OS_ID OS_VERSION_ID
}

# ── Resource detection ────────────────────────────────────────
detect_resources() {
    local disk_total disk_avail

    RAM_MB=$(awk '/MemTotal/ { printf "%d", $2/1024 }' /proc/meminfo)
    CPU_CORES=$(nproc)
    IFS=' ' read -r disk_total disk_avail < <(df -BG / | awk 'NR==2 { gsub("G","",$2); gsub("G","",$4); print $2, $4 }')
    DISK_GB="$disk_total"
    DISK_AVAIL_GB="$disk_avail"
    export RAM_MB CPU_CORES DISK_GB DISK_AVAIL_GB
}

# ── Tier mapping ──────────────────────────────────────────────
# Per PERF-TUNING.md (RAM-only tier selection):
#   S: RAM_MB < 1500
#   M: RAM_MB >= 1500 && < 5000
#   L: RAM_MB >= 5000
detect_tier() {
    detect_resources
    if   (( RAM_MB < 1500 ));                   then OPS_TIER="S"
    elif (( RAM_MB >= 1500 && RAM_MB < 5000 )); then OPS_TIER="M"
    else                                             OPS_TIER="L"
    fi
    export OPS_TIER
}

# ── Admin user detection ──────────────────────────────────────
# Prefer explicit/persisted OPS state, then the actual invoking user.
# Only fall back to the sudo group as a last resort on partially configured hosts.
detect_admin_user() {
    local candidate=""

    if _ops_non_root_user_exists "${ADMIN_USER:-}"; then
        candidate="$ADMIN_USER"
    else
        candidate="$(ops_conf_get "ops.conf" "OPS_ADMIN_USER" 2>/dev/null || true)"
        if ! _ops_non_root_user_exists "$candidate"; then
            candidate="${SUDO_USER:-}"
        fi
        if ! _ops_non_root_user_exists "$candidate"; then
            candidate="${USER:-}"
        fi
        if ! _ops_non_root_user_exists "$candidate"; then
            candidate="$(_ops_first_sudo_user)"
        fi
        if ! _ops_non_root_user_exists "$candidate"; then
            candidate="${ADMIN_USER:-${SUDO_USER:-${USER:-root}}}"
        fi
    fi

    ADMIN_USER="$candidate"
    export ADMIN_USER
}

# ── OPS config loader ─────────────────────────────────────────
# Usage: ops_load_conf <filename>   e.g. ops_load_conf ops.conf
ops_load_conf() {
    local conf_name="${1:-}"
    local conf_file

    [[ -n "$conf_name" ]] || return 1
    conf_file="$OPS_CONFIG_DIR/$conf_name"

    if [[ ! -r "$conf_file" ]]; then
        return 0
    fi

    # shellcheck source=/dev/null
    source "$conf_file"
}

# ── OPS config writer ─────────────────────────────────────────
# Usage: ops_conf_set <filename> <KEY> <VALUE>
ops_conf_set() {
    local conf_name="$1"
    local conf_file="$OPS_CONFIG_DIR/$conf_name"
    local key="$2"
    local value="$3"
    local current quoted_value tmp line found=0

    _ops_valid_conf_key "$key" || return 1

    # Conf values are stored as single-line shell literals.
    value="${value//$'\n'/ }"
    value="${value//$'\r'/ }"

    mkdir -p "$OPS_CONFIG_DIR"

    current=$(ops_conf_get "$conf_name" "$key" || true)
    if [[ "$current" == "$value" ]]; then
        return 0
    fi

    printf -v quoted_value '%q' "$value"
    tmp=$(mktemp "${conf_file}.tmp.XXXXXX")

    if [[ -f "$conf_file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == "${key}="* ]]; then
                printf '%s=%s\n' "$key" "$quoted_value" >> "$tmp"
                found=1
            else
                printf '%s\n' "$line" >> "$tmp"
            fi
        done < "$conf_file"
    fi

    if [[ "$found" -eq 0 ]]; then
        printf '%s=%s\n' "$key" "$quoted_value" >> "$tmp"
    fi

    if [[ -e "$conf_file" ]]; then
        chmod --reference="$conf_file" "$tmp" 2>/dev/null || true
        chown --reference="$conf_file" "$tmp" 2>/dev/null || true
    else
        chmod 600 "$tmp" 2>/dev/null || true
    fi

    mv "$tmp" "$conf_file"
}

# ── OPS config reader ─────────────────────────────────────────
# Usage: ops_conf_get <filename> <KEY>
# Prints the value; returns empty string if key not found.
ops_conf_get() {
    local conf_file="$OPS_CONFIG_DIR/$1"
    local key="$2"

    _ops_valid_conf_key "$key" || return 1

    if [[ ! -r "$conf_file" ]]; then
        return 0
    fi

    (
        set -euo pipefail
        # shellcheck source=/dev/null
        source "$conf_file"
        printf '%s' "${!key-}"
    )
}

# ── Initialise on source ──────────────────────────────────────
detect_os
detect_tier
detect_admin_user
