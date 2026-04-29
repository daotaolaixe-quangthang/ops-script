#!/usr/bin/env bash
# ============================================================
# ops/bin/ops-setup.sh
# Purpose:  Idempotent post-clone setup — symlinks, login hook, base config
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# Designed to be run:
#   - Once by ops-install.sh (as root, with ADMIN_USER set in env)
#   - Again safely on re-install / upgrade (idempotent)
#
# Environment expected from caller (ops-install.sh):
#   ADMIN_USER  — non-root admin user just created
#   OPS_VERSION — version string (optional, defaults to "0.1.0")
# ============================================================
set -euo pipefail
IFS=$'\n\t'

OPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=core/env.sh
source "$OPS_ROOT/core/env.sh"
# shellcheck source=core/utils.sh
source "$OPS_ROOT/core/utils.sh"
# shellcheck source=core/ui.sh
source "$OPS_ROOT/core/ui.sh"
# shellcheck source=core/system.sh
source "$OPS_ROOT/core/system.sh"

# ── Resolve effective admin user ──────────────────────────────
# ADMIN_USER may be passed from ops-install.sh or already in env.
# Fallback: first sudo-group non-root user, then SUDO_USER, then fail.
resolve_admin_user() {
    # ADMIN_USER set by ops-install.sh takes priority.
    : "${ADMIN_USER:=}"

    if [[ -z "$ADMIN_USER" ]]; then
        ADMIN_USER="$(ops_conf_get "ops.conf" "OPS_ADMIN_USER" 2>/dev/null || true)"
    fi

    if [[ -z "$ADMIN_USER" ]]; then
        # First-install fallback: first non-root sudo user.
        ADMIN_USER=$(getent group sudo 2>/dev/null \
            | cut -d: -f4 | tr ',' '\n' \
            | grep -v '^root$' | head -n1 || true)
    fi

    if [[ -z "$ADMIN_USER" ]]; then
        ADMIN_USER="${SUDO_USER:-}"
    fi

    if [[ -z "$ADMIN_USER" || "$ADMIN_USER" == "root" ]]; then
        log_error "Cannot determine ADMIN_USER. Set ADMIN_USER=<username> before running ops-setup.sh."
        exit 1
    fi

    export ADMIN_USER
    ops_conf_set "setup.conf" "SETUP_ADMIN_USER" "$ADMIN_USER"
    log_info "Admin user: ${ADMIN_USER}"
}

# ── 1. Ensure log dir ─────────────────────────────────────────

setup_log_dir() {
    ensure_dir "$OPS_LOG_DIR"
    # Let admin user write logs too
    chown root:"$ADMIN_USER" "$OPS_LOG_DIR" 2>/dev/null || true
    chmod 775 "$OPS_LOG_DIR" 2>/dev/null || true
    ops_conf_set "setup.conf" "SETUP_LOG_DIR_READY" "yes"
    log_info "Log directory ready: $OPS_LOG_DIR"
}

# ── 2. Symlinks ───────────────────────────────────────────────

setup_symlinks() {
    print_section "Setting up symlinks"

    # /usr/local/bin/ops → /opt/ops/bin/ops
    local bin_ops="/usr/local/bin/ops"
    local src_ops="${OPS_ROOT}/bin/ops"

    safe_symlink "$src_ops" "$bin_ops"
    print_ok "Symlink ready: $bin_ops → $src_ops"
    ops_conf_set "setup.conf" "SETUP_SYMLINK_OPS" "$bin_ops"

    # /usr/local/bin/ops-dashboard → /opt/ops/bin/ops-dashboard
    local bin_dash="/usr/local/bin/ops-dashboard"
    local src_dash="${OPS_ROOT}/bin/ops-dashboard"

    safe_symlink "$src_dash" "$bin_dash"
    print_ok "Symlink ready: $bin_dash → $src_dash"
    ops_conf_set "setup.conf" "SETUP_SYMLINK_DASHBOARD" "$bin_dash"

    # Ensure executables are marked +x
    chmod +x "${OPS_ROOT}/bin/ops"
    chmod +x "${OPS_ROOT}/bin/ops-dashboard"
    chmod +x "${OPS_ROOT}/bin/ops-setup.sh"
    ops_conf_set "setup.conf" "SETUP_BIN_EXECUTABLES" "yes"
}

# ── 3. Login hook via ~/.bash_profile ────────────────────────

setup_login_hook() {
    print_section "Setting up login hook"

    local admin_home
    admin_home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)

    if [[ -z "$admin_home" || ! -d "$admin_home" ]]; then
        log_error "Cannot find home directory for user '${ADMIN_USER}'. Skipping login hook."
        return 1
    fi

    local profile="${admin_home}/.bash_profile"
    local hook_marker="# OPS login hook — do not remove"
    local hook_end_marker="# OPS login hook end"
    # Versioned marker: bump version when hook content changes so re-install
    # rewrites stale hooks from older OPS versions automatically.
    local hook_version="OPS_HOOK_V3"
    local hook_version_marker="# ${hook_version}"
    local hook_code legacy_hook_code

    # The guard ensures ops-dashboard only runs for interactive SSH sessions.
    # [[ $- == *i* ]] — shell is interactive
    # [[ -n $SSH_CONNECTION ]] — actual SSH login shell context
    read -r -d '' hook_code << 'HOOK' || true
# OPS login hook — do not remove
# OPS_HOOK_V3
if [[ $- == *i* ]] && [[ -n "${SSH_CONNECTION:-}" ]]; then
    if command -v ops-dashboard &>/dev/null; then
        ops-dashboard || true
    fi
fi
# OPS login hook end
HOOK

    read -r -d '' legacy_hook_code << 'HOOK' || true
# OPS login hook — do not remove
# OPS_HOOK_V2
if [[ $- == *i* ]] && [[ -n "${SSH_CONNECTION:-}" ]]; then
    # OPS SSH auto-finalize: close transition port (port 22) on first login via new port
    _ops_trans=$(grep '^OPS_SSH_TRANSITION_PORT=' /etc/ops/ops.conf 2>/dev/null | cut -d= -f2- | tr -d '"')
    _ops_locked=$(grep '^OPS_SSH_PORT=' /etc/ops/ops.conf 2>/dev/null | cut -d= -f2- | tr -d '"')
    _ops_srv_port=$(awk '{print $4}' <<< "${SSH_CONNECTION}" 2>/dev/null || true)
    if [[ -n "${_ops_trans:-}" && -n "${_ops_locked:-}" \
          && "${_ops_trans}" != "${_ops_locked}" \
          && "${_ops_srv_port}" == "${_ops_locked}" ]]; then
        echo ""
        echo "  [OPS] First SSH login on new port ${_ops_locked} detected."
        echo "  [OPS] Closing transition port ${_ops_trans}..."
        sudo /opt/ops/bin/ops-ssh-finalize.sh 2>&1
    fi
    unset _ops_trans _ops_locked _ops_srv_port
    if command -v ops-dashboard &>/dev/null; then
        ops-dashboard || true
    fi
fi
HOOK

    # Ensure .bash_profile exists and sources .bashrc for interactive use.
    if [[ ! -f "$profile" ]]; then
        cat > "$profile" <<'BASHPROFILE'
# ~/.bash_profile — sourced on SSH login
# Source .bashrc if it exists
if [[ -f ~/.bashrc ]]; then
    # shellcheck source=/dev/null
    source ~/.bashrc
fi
BASHPROFILE
        chown "${ADMIN_USER}:${ADMIN_USER}" "$profile"
    fi

    if ! bash -n "$profile" 2>/dev/null; then
        log_error "Refusing to update OPS login hook: ${profile} has invalid bash syntax"
        return 1
    fi

    if grep -q "$hook_version_marker" "$profile" 2>/dev/null; then
        log_info "Login hook ${hook_version} already present in ${profile} — skipping."
        return 0
    fi

    local profile_backup="${profile}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$profile" "$profile_backup"

    if grep -q "$hook_marker" "$profile" 2>/dev/null; then
        log_info "Stale OPS login hook found in ${profile} — replacing with ${hook_version}."
        local content updated_content tmp
        content="$(<"$profile")"

        if [[ "$content" == *"$legacy_hook_code"* ]]; then
            updated_content="${content/$legacy_hook_code/}"
            printf '%s' "$updated_content" > "$profile"
        elif [[ "$content" == *"$hook_end_marker"* ]]; then
            tmp=$(mktemp)
            awk -v start="$hook_marker" -v end="$hook_end_marker" '
                $0 == start { skip=1; next }
                skip && $0 == end { skip=0; next }
                !skip { print }
            ' "$profile" > "$tmp"
            mv "$tmp" "$profile"
        else
            cp "$profile_backup" "$profile"
            log_error "Refusing to rewrite unknown legacy OPS login hook in ${profile}. Review ${profile_backup} manually."
            return 1
        fi
    fi

    printf '\n%s\n' "$hook_code" >> "$profile"

    if ! bash -n "$profile" 2>/dev/null; then
        cp "$profile_backup" "$profile"
        log_error "Login hook caused syntax failure in ${profile}. Restored backup ${profile_backup}."
        return 1
    fi

    chown "${ADMIN_USER}:${ADMIN_USER}" "$profile"
    print_ok "Login hook ${hook_version} installed in ${profile}"
    ops_conf_set "setup.conf" "SETUP_LOGIN_HOOK" "installed"
}

# ── 4. Write /etc/ops/ops.conf ────────────────────────────────

setup_base_config() {
    print_section "Writing base configuration"

    ensure_dir "$OPS_CONFIG_DIR"

    local conf="${OPS_CONFIG_DIR}/ops.conf"
    local version="${OPS_VERSION:-0.1.0}"
    local install_date="${OPS_INSTALL_DATE:-$(date '+%F %T')}"

    # Keep a one-time backup only when the file already exists.
    if [[ -f "$conf" ]]; then
        backup_file "$conf" >/dev/null 2>&1 || true
    fi

    ops_conf_set "ops.conf" "OPS_VERSION" "$version"
    ops_conf_set "ops.conf" "OPS_ROOT" "$OPS_ROOT"
    ops_conf_set "ops.conf" "OPS_CONFIG_DIR" "$OPS_CONFIG_DIR"
    ops_conf_set "ops.conf" "OPS_LOG_DIR" "$OPS_LOG_DIR"
    ops_conf_set "ops.conf" "OPS_LOG_FILE" "$OPS_LOG_FILE"
    ops_conf_set "ops.conf" "OPS_ADMIN_USER" "$ADMIN_USER"
    # OPS_SSH_PORT / OPS_SSH_TRANSITION_PORT: set by ops-install.sh via env.
    # OPS_SSH_TRANSITION_PORT is cleared by ops-ssh-finalize.sh after explicit finalization.
    ops_conf_set "ops.conf" "OPS_SSH_PORT"            "${OPS_SSH_PORT:-}"
    ops_conf_set "ops.conf" "OPS_SSH_TRANSITION_PORT" "${OPS_SSH_TRANSITION_PORT:-}"
    ops_conf_set "ops.conf" "OPS_INSTALL_DATE" "$install_date"

    ops_conf_set "setup.conf" "SETUP_BASE_CONFIG" "written"
    ops_conf_set "setup.conf" "SETUP_LAST_RUN_AT" "$(date '+%F %T')"

    # P4-1 fix: ops.conf contains SSH port, admin user, wizard state — must NOT be
    # world-readable (644). Set to 640 so root+admin_group can read, others cannot.
    chmod 640 "$conf"
    chown "root:${ADMIN_USER}" "$conf" 2>/dev/null || chmod 600 "$conf"
    print_ok "Config written: ${conf} (mode 640, owner root:${ADMIN_USER})"
}

# ── 5. Cleanup legacy auto-finalize sudoers rule ─────────────
# Older OPS builds granted NOPASSWD sudo for ops-ssh-finalize.sh so the
# login hook could auto-close the transition port. Finalization is now an
# explicit operator action from the Security menu, so this extra privilege
# should be removed on re-run.

cleanup_legacy_ssh_finalize_sudoers() {
    local sudoers_file="/etc/sudoers.d/99-ops-ssh-finalize"

    if [[ ! -f "$sudoers_file" ]]; then
        return 0
    fi

    backup_file "$sudoers_file" >/dev/null 2>&1 || true
    rm -f "$sudoers_file"
    print_ok "Removed legacy auto-finalize sudoers rule: ${sudoers_file}"
}

# ── 6. logrotate for /var/log/ops/ops.log ────────────────────
# P4-E: Without logrotate the ops.log grows without bound.
# Weekly rotation, 8 weeks retention, compressed, created 0640 root root.
setup_logrotate() {
    local lr_file="/etc/logrotate.d/ops"

    # Idempotent: skip if already written
    if [[ -f "$lr_file" ]]; then
        log_info "logrotate config already present: ${lr_file}"
        return 0
    fi

    cat > "$lr_file" <<'EOF_LR'
/var/log/ops/ops.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    create 0640 root root
}
EOF_LR
    chmod 644 "$lr_file"
    print_ok "logrotate config written: ${lr_file}"
    log_info "setup_logrotate: ${lr_file} created"
}

# ── Main ──────────────────────────────────────────────────────

main() {
    print_section "OPS Post-Clone Setup"

    resolve_admin_user
    setup_log_dir
    setup_logrotate
    setup_symlinks
    setup_base_config
    cleanup_legacy_ssh_finalize_sudoers
    setup_login_hook

    echo ""
    print_ok "ops-setup.sh complete."
    echo ""
    log_info "ops-setup.sh finished successfully."
}

main
