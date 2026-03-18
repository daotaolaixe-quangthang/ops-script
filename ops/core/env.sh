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
export OPS_CONFIG_DIR="/etc/ops"
export OPS_LOG_DIR="/var/log/ops"
export OPS_LOG_FILE="$OPS_LOG_DIR/ops.log"

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
    RAM_MB=$(awk '/MemTotal/ { printf "%d", $2/1024 }' /proc/meminfo)
    CPU_CORES=$(nproc)
    DISK_GB=$(df -BG / | awk 'NR==2 { gsub("G","",$4); print $4 }')
    export RAM_MB CPU_CORES DISK_GB
}

# ── Tier mapping ──────────────────────────────────────────────
# Per PERF-TUNING.md:
#   S: RAM_MB < 1500
#   M: RAM_MB 1500-5000
#   L: RAM_MB > 5000
detect_tier() {
    detect_resources
    if   (( RAM_MB < 1500 ));                   then OPS_TIER="S"
    elif (( RAM_MB >= 1500 && RAM_MB < 5000 )); then OPS_TIER="M"
    else                                             OPS_TIER="L"
    fi
    export OPS_TIER
}

# ── Admin user detection ──────────────────────────────────────
# Returns the first non-root sudo user, or falls back to $SUDO_USER / $USER.
detect_admin_user() {
    local candidate
    candidate=$(getent group sudo 2>/dev/null | cut -d: -f4 | tr ',' '\n' | grep -v '^root$' | head -n1 || true)
    if [[ -z "$candidate" ]]; then
        candidate="${SUDO_USER:-${USER:-root}}"
    fi
    ADMIN_USER="$candidate"
    export ADMIN_USER
}

# ── OPS config loader ─────────────────────────────────────────
# Usage: ops_load_conf <filename>   e.g. ops_load_conf ops.conf
ops_load_conf() {
    local conf_file="$OPS_CONFIG_DIR/$1"
    # shellcheck source=/dev/null
    [[ -f "$conf_file" ]] && source "$conf_file"
}

# ── OPS config writer ─────────────────────────────────────────
# Usage: ops_conf_set <filename> <KEY> <VALUE>
ops_conf_set() {
    local conf_file="$OPS_CONFIG_DIR/$1"
    local key="$2"
    local value="$3"
    local escaped_value

    escaped_value=$(printf '%s' "$value" | sed 's/"/\\"/g')

    mkdir -p "$OPS_CONFIG_DIR"

    if [[ ! -f "$conf_file" ]]; then
        printf '%s="%s"\n' "$key" "$escaped_value" > "$conf_file"
        return 0
    fi

    local current
    current=$(ops_conf_get "$1" "$key" || true)
    if [[ "$current" == "$value" ]]; then
        return 0
    fi

    local tmp
    tmp=$(mktemp)
    if grep -q "^${key}=" "$conf_file" 2>/dev/null; then
        sed "s|^${key}=.*|${key}=\"${escaped_value}\"|" "$conf_file" > "$tmp"
    else
        cat "$conf_file" > "$tmp"
        printf '%s="%s"\n' "$key" "$escaped_value" >> "$tmp"
    fi
    mv "$tmp" "$conf_file"
}

# ── OPS config reader ─────────────────────────────────────────
# Usage: ops_conf_get <filename> <KEY>
# Prints the value; returns empty string if key not found.
ops_conf_get() {
    local conf_file="$OPS_CONFIG_DIR/$1"
    local key="$2"
    if [[ -f "$conf_file" ]]; then
        grep "^${key}=" "$conf_file" 2>/dev/null \
            | head -n1 \
            | cut -d= -f2- \
            | tr -d '"' \
            || true
    fi
}

# ── Initialise on source ──────────────────────────────────────
detect_os
detect_tier
detect_admin_user
