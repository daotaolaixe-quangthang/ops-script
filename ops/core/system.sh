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
# P3-5 fix: service_restart now verifies the service is actually active after
# restart. systemctl restart exit 0 only means the restart command was accepted,
# not that the service is running. Poll is-active up to 3 times (6s total).
service_restart() {
    local svc="$1"
    systemctl restart "$svc" && log_info "Restarted: $svc"
    local _attempt=0
    while (( _attempt < 3 )); do
        sleep 2
        if systemctl is-active --quiet "$svc"; then
            log_info "Health check OK: $svc is active after restart."
            return 0
        fi
        (( _attempt++ ))
        log_warn "Health check attempt ${_attempt}/3: $svc not yet active after restart..."
    done
    log_error "Health check FAILED: $svc is not active after restart. Check: journalctl -u ${svc} -n 30"
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
