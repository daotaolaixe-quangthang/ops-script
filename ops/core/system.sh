#!/usr/bin/env bash
# ============================================================
# ops/core/system.sh
# Purpose:  Wrappers for apt, systemctl, ufw — system-level ops
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# Source this file; do NOT execute directly.
set -euo pipefail
IFS=$'\n\t'

# ── apt wrappers ──────────────────────────────────────────────

apt_update() {
    log_info "apt-get update"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
}

apt_upgrade() {
    log_info "apt-get upgrade"
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
}

# Usage: apt_install nginx curl
apt_install() {
    log_info "apt-get install: $*"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
}

# Usage: apt_remove nginx
apt_remove() {
    log_info "apt-get remove: $*"
    DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq "$@"
}

# ── systemctl wrappers ────────────────────────────────────────

_service_default_timeout() {
    local svc="$1"
    if [[ "$svc" =~ ^(mariadb|mysql)$ ]]; then
        printf '30'
    else
        printf '15'
    fi
}

_service_wait_active() {
    local svc="$1"
    local timeout="$2"
    local action="$3"
    local elapsed=0
    local interval=1
    local attempt=0

    while true; do
        if systemctl is-active --quiet "$svc"; then
            log_info "Health check OK: $svc is active after ${action} (${elapsed}s elapsed)."
            return 0
        fi
        if (( elapsed >= timeout )); then
            break
        fi
        sleep "$interval"
        (( elapsed += interval ))
        (( attempt++ ))
        log_warn "Health check attempt ${attempt}: $svc not yet active after ${elapsed}s / ${timeout}s..."
        (( interval = interval * 2 < 8 ? interval * 2 : 8 ))
    done

    log_error "Health check FAILED: $svc is not active after ${action} within ${timeout}s. Check: journalctl -u ${svc} -n 30"
    return 1
}

service_enable()  { systemctl enable  "$1" && log_info "Enabled:  $1"; }
service_start()   { systemctl start   "$1" && log_info "Started:  $1"; }
# F-27 fix: service_restart verifies the service is actually active after
# restart with exponential backoff and a configurable timeout.
#   systemctl restart exits 0 only when the restart *command* was accepted,
#   not when the service is actually running. Slow services like MariaDB can
#   take 10-15 s on a cold InnoDB buffer-pool init on a low-RAM VPS.
#
# Usage: service_restart <svc> [timeout_seconds]
#   timeout_seconds defaults to 30 for mariadb/mysql, 15 for everything else.
#   Callers that need a custom window can pass an explicit timeout:
#     service_restart netdata 45
service_restart() {
    local svc="$1"
    local _timeout
    if [[ -n "${2:-}" ]]; then
        _timeout="$2"
    else
        _timeout="$(_service_default_timeout "$svc")"
    fi

    systemctl restart "$svc" && log_info "Restarted: $svc"
    _service_wait_active "$svc" "$_timeout" "restart"
}

service_reload() {
    local svc="$1"
    local _timeout="${2:-5}"

    systemctl reload "$svc" && log_info "Reloaded: $svc"
    _service_wait_active "$svc" "$_timeout" "reload"
}
service_stop()    { systemctl stop    "$1" && log_info "Stopped:  $1"; }
service_status()  { systemctl status  "$1" --no-pager; }
service_active()  { systemctl is-active --quiet "$1"; }

# Backward-compatible aliases (used by skeleton/docs)
svc_enable()    { service_enable "$@"; }
svc_start()     { service_start "$@"; }
svc_restart()   { service_restart "$@"; }
svc_reload()    { service_reload "$@"; }
svc_stop()      { service_stop "$@"; }
svc_status()    { service_status "$@"; }
svc_is_active() { service_active "$@"; }

# ── Runtime-user / PM2 helpers ────────────────────────────────

ops_runtime_user() {
    local runtime_user=""

    runtime_user="$(ops_conf_get "ops.conf" "OPS_RUNTIME_USER" 2>/dev/null || true)"
    if ! _ops_non_root_user_exists "$runtime_user"; then
        runtime_user="$(ops_conf_get "ops.conf" "OPS_ADMIN_USER" 2>/dev/null || true)"
    fi
    if ! _ops_non_root_user_exists "$runtime_user"; then
        runtime_user="${ADMIN_USER:-}"
    fi
    if ! _ops_non_root_user_exists "$runtime_user"; then
        runtime_user="${SUDO_USER:-}"
    fi
    if ! _ops_non_root_user_exists "$runtime_user"; then
        runtime_user="${USER:-}"
    fi

    if ! _ops_non_root_user_exists "$runtime_user"; then
        log_error "ops_runtime_user: unable to resolve a non-root runtime user — set OPS_RUNTIME_USER or OPS_ADMIN_USER in ops.conf."
        return 1
    fi

    echo "$runtime_user"
}

ops_runtime_home() {
    local runtime_user="${1:-}"
    local home_dir=""

    if [[ -z "$runtime_user" ]]; then
        runtime_user="$(ops_runtime_user)" || return 1
    fi

    ops_require_runtime_user "$runtime_user" || return 1
    home_dir="$(getent passwd "$runtime_user" | cut -d: -f6)"
    if [[ -z "$home_dir" || ! -d "$home_dir" ]]; then
        log_error "ops_runtime_home: unable to resolve a valid home directory for runtime user '${runtime_user}'."
        return 1
    fi

    echo "$home_dir"
}

ops_require_runtime_user() {
    local runtime_user="${1:-}"

    if [[ -z "$runtime_user" ]]; then
        runtime_user="$(ops_runtime_user)" || return 1
    fi

    if ! _ops_non_root_user_exists "$runtime_user"; then
        print_error "OPS runtime user must be a real non-root user: ${runtime_user:-empty}"
        return 1
    fi
}

ops_run_as_user() {
    local runtime_user home_dir
    runtime_user="$1"
    shift

    ops_require_runtime_user "$runtime_user" || return 1
    home_dir="$(ops_runtime_home "$runtime_user")" || return 1
    runuser -u "$runtime_user" -- env HOME="$home_dir" PM2_HOME="$home_dir/.pm2" PATH="$PATH" "$@"
}

ops_run_as_runtime_user() {
    local runtime_user
    runtime_user="$(ops_runtime_user)" || return 1
    ops_run_as_user "$runtime_user" "$@"
}

ops_pm2_jlist() {
    ops_run_as_runtime_user pm2 jlist
}

ops_pm2_online_count_from_json() {
    python3 -c 'import json, sys; procs=json.load(sys.stdin); print(sum(1 for p in procs if p.get("pm2_env", {}).get("status") == "online"))'
}

ops_pm2_total_count_from_json() {
    python3 -c 'import json, sys; procs=json.load(sys.stdin); print(len(procs))'
}

ops_pm2_process_status_from_json() {
    local pm2_name="$1"
    python3 -c 'import json, sys; name=sys.argv[1]; procs=json.load(sys.stdin)
for p in procs:
    if p.get("name") == name:
        print(p.get("pm2_env", {}).get("status", "?"))
        break
else:
    print("not-found")' "$pm2_name"
}

ops_pm2_online_count() {
    ops_pm2_jlist 2>/dev/null | ops_pm2_online_count_from_json
}

ops_pm2_total_count() {
    ops_pm2_jlist 2>/dev/null | ops_pm2_total_count_from_json
}

ops_pm2_process_status() {
    local pm2_name="$1"
    ops_pm2_jlist 2>/dev/null | ops_pm2_process_status_from_json "$pm2_name"
}

# ── Nginx helpers ─────────────────────────────────────────────

nginx_validate() {
    # Per BASH-STYLE.md §7 and PERF-TUNING.md — always test before reload
    if ! nginx -t 2>/dev/null; then
        log_error "Nginx config test failed — aborting reload"
        return 1
    fi
}

nginx_reload() {
    nginx_validate || return 1
    service_reload nginx
    log_info "Nginx reloaded"
}

# Usage: bash_validate /path/to/script.sh
bash_validate() {
    local script_path="$1"
    if ! bash -n "$script_path" 2>/dev/null; then
        log_error "bash -n failed for: $script_path"
        return 1
    fi
}

# ── ufw wrappers ──────────────────────────────────────────────

# Usage: ufw_allow "80/tcp" "HTTP"
ufw_allow() {
    local port="$1"
    local comment="${2:-ops}"
    ufw allow "$port" comment "ops: $comment"
    log_info "UFW allow: $port ($comment)"
}

# Usage: ufw_deny "23/tcp"
ufw_deny() {
    local port="$1"
    ufw deny "$port"
    log_info "UFW deny: $port"
}

ufw_status() { ufw status verbose; }

# ── User management helpers ───────────────────────────────────

# Usage: create_user username
create_user() {
    local username="$1"
    if id "$username" &>/dev/null; then
        log_info "User already exists: $username"
    else
        adduser --disabled-password --gecos "" "$username"
        log_info "Created user: $username"
    fi
}

# Usage: add_sudo username
add_sudo() {
    local username="$1"
    usermod -aG sudo "$username"
    log_info "Added $username to sudo group"
}
