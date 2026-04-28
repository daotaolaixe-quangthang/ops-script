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
    # Determine timeout: caller-supplied > slow-service default > general default
    local _timeout
    if [[ -n "${2:-}" ]]; then
        _timeout="$2"
    elif [[ "$svc" =~ ^(mariadb|mysql)$ ]]; then
        _timeout=30   # InnoDB buffer-pool init on low-RAM VPS can take 10-15 s
    else
        _timeout=15
    fi

    systemctl restart "$svc" && log_info "Restarted: $svc"

    local _elapsed=0
    local _interval=1   # start with 1 s; doubles each miss (1,2,4,8,…)
    local _attempt=0
    while (( _elapsed < _timeout )); do
        sleep "$_interval"
        (( _elapsed += _interval ))
        (( _attempt++ ))
        if systemctl is-active --quiet "$svc"; then
            log_info "Health check OK: $svc is active after restart (${_elapsed}s elapsed)."
            return 0
        fi
        log_warn "Health check attempt ${_attempt}: $svc not yet active after ${_elapsed}s / ${_timeout}s..."
        # Double the interval up to a max of 8 s to avoid hammering systemd
        (( _interval = _interval * 2 < 8 ? _interval * 2 : 8 ))
    done
    log_error "Health check FAILED: $svc is not active after ${_timeout}s. Check: journalctl -u ${svc} -n 30"
    return 1
}
service_reload()  { systemctl reload  "$1" && log_info "Reloaded: $1"; }
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
    if [[ -z "$runtime_user" ]]; then
        runtime_user="$(ops_conf_get "ops.conf" "OPS_ADMIN_USER" 2>/dev/null || true)"
    fi
    if [[ -z "$runtime_user" ]]; then
        if [[ -n "${ADMIN_USER:-}" && "${ADMIN_USER}" != "root" ]]; then
            runtime_user="$ADMIN_USER"
        elif [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
            runtime_user="$SUDO_USER"
        else
            runtime_user="$(whoami)"
            if [[ "$runtime_user" == "root" ]]; then
                log_warn "ops_runtime_user: resolved to 'root' — set OPS_RUNTIME_USER or OPS_ADMIN_USER in ops.conf."
            fi
        fi
    fi
    echo "$runtime_user"
}

ops_runtime_home() {
    local runtime_user="${1:-$(ops_runtime_user)}"
    getent passwd "$runtime_user" | cut -d: -f6
}

ops_require_runtime_user() {
    local runtime_user="${1:-$(ops_runtime_user)}"
    if ! id "$runtime_user" >/dev/null 2>&1; then
        print_error "OPS runtime user does not exist: ${runtime_user}"
        return 1
    fi
}

ops_run_as_user() {
    local runtime_user home_dir
    runtime_user="$1"
    shift
    home_dir="$(ops_runtime_home "$runtime_user")"
    runuser -u "$runtime_user" -- env HOME="$home_dir" PM2_HOME="$home_dir/.pm2" PATH="$PATH" "$@"
}

ops_run_as_runtime_user() {
    ops_run_as_user "$(ops_runtime_user)" "$@"
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
