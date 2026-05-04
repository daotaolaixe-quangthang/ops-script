#!/usr/bin/env bash
# ============================================================
# ops/modules/security.sh
# Purpose:  SSH hardening, firewall, fail2ban management
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# Called by bin/ops via menu dispatch.
# Do NOT add set -euo pipefail here — inherited from bin/ops.

SECURITY_SSHD_CONFIG="/etc/ssh/sshd_config"
SECURITY_SSHD_INCLUDE_DIR="/etc/ssh/sshd_config.d"
SECURITY_SSHD_OPS_INCLUDE="${SECURITY_SSHD_INCLUDE_DIR}/99-ops-hardening.conf"
SECURITY_FAIL2BAN_JAIL_LOCAL="/etc/fail2ban/jail.local"
SECURITY_FAIL2BAN_JAIL_OPS="/etc/fail2ban/jail.d/ops-sshd.local"
SECURITY_SYSCTL_OPS_CONF="/etc/sysctl.d/99-ops-hardening.conf"
SECURITY_SWAP_FILE="/swapfile"

security_require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        print_error "This action requires root privileges (run OPS with sudo/root)."
        return 1
    fi
}

security_detect_ssh_service() {
    if systemctl list-unit-files | grep -q '^ssh\.service'; then
        echo "ssh"
    else
        echo "sshd"
    fi
}

security_get_current_ssh_port() {
    local port
    # Primary: read from running sshd effective config
    port=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' || true)

    # Fallback 1: ops.conf (most reliable after OPS has run)
    if [[ -z "$port" ]]; then
        port=$(ops_conf_get "ops.conf" "OPS_SSH_PORT" 2>/dev/null || true)
    fi

    # Fallback 2: OPS-managed include file (port may have moved out of main config)
    if [[ -z "$port" && -f "$SECURITY_SSHD_OPS_INCLUDE" ]]; then
        port=$(awk 'tolower($1)=="port" {print $2; exit}' \
            "$SECURITY_SSHD_OPS_INCLUDE" 2>/dev/null || true)
    fi

    # Fallback 3: main sshd_config (legacy / pre-OPS systems)
    if [[ -z "$port" ]]; then
        port=$(awk '
            BEGIN { p="" }
            /^[[:space:]]*#/ { next }
            tolower($1) == "port" { p=$2; print p; exit }
        ' "$SECURITY_SSHD_CONFIG" 2>/dev/null || true)
    fi

    echo "${port:-22}"
}


security_get_server_ip() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    echo "${ip:-<SERVER_IP_OR_HOSTNAME>}"
}

security_get_admin_user() {
    local admin
    admin=$(ops_conf_get "ops.conf" "OPS_ADMIN_USER" || true)
    if [[ -z "$admin" ]]; then
        admin="${ADMIN_USER:-${SUDO_USER:-admin}}"
    fi
    echo "$admin"
}

security_validate_ssh_port() {
    local port="$1"
    local current_port="${2:-}"

    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        print_error "SSH port must be numeric."
        return 1
    fi

    if (( port > 65535 )); then
        print_error "SSH port must be between 1 and 65535."
        return 1
    fi

    if (( port == 8317 )); then
        print_error "Port 8317 is forbidden (reserved security constraint for CLIProxyAPI hardening)."
        return 1
    fi

    # F-19: Ports 1-1024 are privileged (system) ports — services binding them require
    # root. Running sshd on a new privileged port creates a security risk and will fail
    # on hardened systems. Preserve the current managed port if it is already 22, but
    # do not allow selecting arbitrary new privileged ports.
    if (( port <= 1024 )); then
        if [[ -n "$current_port" && "$port" == "$current_port" ]]; then
            return 0
        fi
        print_error "SSH port must be greater than 1024 unless you are preserving the current managed port."
        return 1
    fi
}

security_set_sshd_option() {
    local key="$1"
    local value="$2"
    local file="$3"

    # F-17: Only match ACTIVE (non-commented) lines.
    # The old regex used #? which also matched commented directives, causing
    # sed to uncomment them in-place — silently activating intentionally disabled
    # settings (e.g. #PermitRootLogin prohibit-password → PermitRootLogin no).
    # If the directive is currently commented-out, we fall through to the else
    # branch and APPEND a new active line. This is safe because 99-ops-hardening.conf
    # is included with Include /etc/ssh/sshd_config.d/*.conf at the top of sshd_config,
    # and OpenSSH uses first-match-wins semantics.
    if grep -Eq "^[[:space:]]*${key}[[:space:]]+" "$file"; then
        sed -i -E "s|^[[:space:]]*${key}[[:space:]]+.*|${key} ${value}|" "$file"
    else
        echo "${key} ${value}" >> "$file"
    fi
}

security_get_transition_port() {
    ops_conf_get "ops.conf" "OPS_SSH_TRANSITION_PORT" 2>/dev/null || true
}

security_get_locked_ssh_port() {
    local port
    port=$(ops_conf_get "ops.conf" "OPS_SSH_PORT" 2>/dev/null || true)
    echo "${port:-$(security_get_current_ssh_port)}"
}

security_get_runtime_user() {
    local runtime_user
    runtime_user=$(ops_conf_get "ops.conf" "OPS_RUNTIME_USER" 2>/dev/null || true)
    if [[ -z "$runtime_user" ]]; then
        runtime_user="$(security_get_admin_user)"
    fi
    echo "$runtime_user"
}

security_get_tcp_forwarding() {
    local val
    val=$(ops_conf_get "ops.conf" "OPS_SSH_TCP_FORWARDING" 2>/dev/null || true)
    echo "${val:-no}"
}

security_normalize_script_permissions() {
    if [[ -d "${OPS_ROOT}/modules" ]]; then
        find "${OPS_ROOT}" -type f -name '*.sh' -exec chmod 755 {} + 2>/dev/null || true
    fi
}

security_effective_password_auth() {
    local desired_password_auth="$1"
    local locked_port="$2"
    local transition_port="${3:-}"

    if [[ -n "$transition_port" && "$transition_port" != "$locked_port" ]]; then
        echo "yes"
    else
        echo "$desired_password_auth"
    fi
}

_security_authorized_key_line_is_valid() {
    local line="${1:-}"

    [[ -n "$line" ]] || return 1
    [[ "$line" =~ ^[[:space:]]*# ]] && return 1

    grep -Eq '(^|[[:space:]])(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|sk-ecdsa-sha2-nistp256@openssh\.com|sk-ssh-ed25519@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]]|$)' <<< "$line"
}

# _security_has_authorized_keys <username>
# Fix B: Returns 0 if the user has at least one valid SSH public key.
# Used to guard against disabling PasswordAuthentication with no key present.
_security_has_authorized_keys() {
    local user="$1"
    local home_dir
    local auth_keys
    local line

    home_dir=$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)
    [[ -z "$home_dir" ]] && return 1
    auth_keys="${home_dir}/.ssh/authorized_keys"
    [[ -f "$auth_keys" ]] || return 1

    while IFS= read -r line || [[ -n "$line" ]]; do
        if _security_authorized_key_line_is_valid "$line"; then
            return 0
        fi
    done < "$auth_keys"

    return 1
}

security_wizard_baseline() {
    print_section "Security Baseline"
    security_require_root || return 1

    local current_port new_port password_auth
    current_port="$(security_get_current_ssh_port)"

    print_warn "Current SSH port detected: ${current_port}"
    print_warn "OPS will keep the current SSH port open during transition until login on the new port is verified."

    prompt_input "New SSH port (keep blank to leave as ${current_port})" "$current_port"
    new_port="$REPLY"
    security_validate_ssh_port "$new_port" "$current_port" || return 1

    # Fix B: Only offer to disable PasswordAuthentication if SSH key is present.
    # Without a key, disabling password auth causes complete SSH lockout.
    local admin_user
    admin_user="$(security_get_admin_user)"
    if _security_has_authorized_keys "$admin_user"; then
        if prompt_confirm "Disable PasswordAuthentication after transition completes?"; then
            password_auth="no"
        else
            password_auth="yes"
        fi
    else
        print_warn "No SSH public key found for '${admin_user}'."
        print_warn "PasswordAuthentication will remain ENABLED to prevent SSH lockout."
        print_warn "Add a key first: Security menu -> Manage SSH Keys (option 8)"
        password_auth="yes"
    fi

    security_apply_sshd_hardening "$new_port" "$password_auth" || return 1
    if [[ "$new_port" != "$current_port" ]]; then
        print_warn "Open a NEW terminal and verify SSH on port ${new_port} before you finalize and remove old port ${current_port}."
    fi

    security_status
}

security_write_sshd_hardening_include() {
    local locked_port="$1"
    local password_auth="$2"
    local transition_port="${3:-}"
    local tcp_forwarding_override="${4:-}"
    local tcp_forwarding effective_password_auth
    if [[ -n "$tcp_forwarding_override" ]]; then
        tcp_forwarding="$tcp_forwarding_override"
    else
        tcp_forwarding="$(security_get_tcp_forwarding)"
    fi
    effective_password_auth="$(security_effective_password_auth "$password_auth" "$locked_port" "$transition_port")"

    ensure_dir "$SECURITY_SSHD_INCLUDE_DIR"
    backup_file "$SECURITY_SSHD_OPS_INCLUDE" >/dev/null 2>&1 || true
    write_file "$SECURITY_SSHD_OPS_INCLUDE" <<EOF_SSH_OPS
# Managed by OPS — do not edit manually.
PermitRootLogin no
PasswordAuthentication ${effective_password_auth}
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
X11Forwarding no
AllowTcpForwarding ${tcp_forwarding}
AllowAgentForwarding no
AllowStreamLocalForwarding no
PermitTunnel no
ClientAliveInterval 300
ClientAliveCountMax 2
Port ${locked_port}
EOF_SSH_OPS

    # Fix D: trim whitespace from transition_port before comparing to locked_port.
    # ops.conf may store a value with trailing whitespace, causing false inequality
    # and duplicate Port entries in the hardening include file.
    local _clean_transition="${transition_port// /}"
    if [[ -n "$_clean_transition" && "$_clean_transition" != "$locked_port" ]]; then
        printf 'Port %s\n' "$_clean_transition" >> "$SECURITY_SSHD_OPS_INCLUDE"
    fi

    chmod 644 "$SECURITY_SSHD_OPS_INCLUDE"
}

security_ensure_include_first() {
    local file="$1"
    local include_val="${SECURITY_SSHD_INCLUDE_DIR}/*.conf"

    # Remove all existing Include lines wherever they appear in the file
    sed -i '/^[[:space:]]*Include[[:space:]]/d' "$file"
    # Prepend Include as the very first line so it wins first-match semantics
    sed -i "1i Include ${include_val}" "$file"
    log_info "sshd_config: Include ensured as first directive in ${file}."
}

security_reconcile_sshd_main_config() {
    backup_file "$SECURITY_SSHD_CONFIG" > /dev/null 2>&1 || true


    # Bug B fix: ensure Include is FIRST so 99-ops-hardening.conf wins first-match.
    # OpenSSH uses first-match-wins; this guarantees include file values take precedence
    # regardless of whether Include was pre-existing (Ubuntu) or appended (other distros).
    security_ensure_include_first "$SECURITY_SSHD_CONFIG"

    # Bug C fix: only set PermitRootLogin as an absolute safety net in main config.
    # All other directives (PasswordAuthentication, Port, X11Forwarding, etc.) are
    # managed exclusively by 99-ops-hardening.conf via the Include directive above.
    # Duplicating them here risks first-match collision if Include ends up after them.
    security_set_sshd_option "PermitRootLogin" "no" "$SECURITY_SSHD_CONFIG"

    # Security fix: comment out PasswordAuthentication in base config.
    # The authoritative value is set to 'no' in 99-ops-hardening.conf.
    # Leaving an active 'yes' here creates config drift risk and audit confusion.
    if grep -Eq '^[[:space:]]*PasswordAuthentication[[:space:]]+(yes|no)' "$SECURITY_SSHD_CONFIG"; then
        sed -i -E 's|^([[:space:]]*PasswordAuthentication[[:space:]]+.*)$|#\1  # managed via sshd_config.d/99-ops-hardening.conf|' \
            "$SECURITY_SSHD_CONFIG"
        log_info "Commented out PasswordAuthentication in ${SECURITY_SSHD_CONFIG} — managed via include."
    fi

    # Comment out standalone Port directives in main config (managed via include).
    if grep -Eq '^[[:space:]]*Port[[:space:]]+[0-9]+' "$SECURITY_SSHD_CONFIG" 2>/dev/null; then
        sed -i -E 's|^([[:space:]]*Port[[:space:]]+[0-9]+)|#\1  # managed via sshd_config.d/99-ops-hardening.conf|' \
            "$SECURITY_SSHD_CONFIG"
        log_info "Commented out Port directives in ${SECURITY_SSHD_CONFIG} -- managed via include."
    fi

    # Strip conflicting directives from OTHER include files (not our managed file).
    # Bug-1 fix: skip .bak.* backup files — same guard as security_strip_cloud_init_overrides.
    # Without this, backup_file() would be called on the backups themselves, creating
    # ever-growing chains like 99-ops-hardening.conf.bak.TIMESTAMP.bak.TIMESTAMP2 on
    # every wizard re-run.
    if [[ -d "$SECURITY_SSHD_INCLUDE_DIR" ]]; then
        find "$SECURITY_SSHD_INCLUDE_DIR" -maxdepth 1 -type f ! -name '99-ops-hardening.conf' -print0 2>/dev/null | while IFS= read -r -d '' include_file; do
            local _bname_r
            _bname_r="$(basename "$include_file")"
            [[ "$_bname_r" == *".bak."* ]] && continue
            if grep -Eq '^[[:space:]]*(PasswordAuthentication|PermitRootLogin|Port|X11Forwarding|AllowTcpForwarding|AllowAgentForwarding|AllowStreamLocalForwarding|PermitTunnel)[[:space:]]+' "$include_file"; then
                backup_file "$include_file" > /dev/null 2>&1 || true
                sed -i -E '/^[[:space:]]*(PasswordAuthentication|PermitRootLogin|Port|X11Forwarding|AllowTcpForwarding|AllowAgentForwarding|AllowStreamLocalForwarding|PermitTunnel)[[:space:]]+/d' "$include_file"
            fi
        done
    fi
}


# security_strip_cloud_init_overrides
# Public helper — strips conflicting SSH directives injected by cloud-init
# from all include files EXCEPT 99-ops-hardening.conf.
# Safe to call multiple times (idempotent via sed -i with no-match case).
security_strip_cloud_init_overrides() {
    if [[ ! -d "$SECURITY_SSHD_INCLUDE_DIR" ]]; then
        return 0
    fi

    local stripped=0
    local include_file
    while IFS= read -r -d '' include_file; do
        local _bname
        _bname="$(basename "$include_file")"
        # Skip our own managed file
        [[ "$_bname" == "99-ops-hardening.conf" ]] && continue
        # Bug-1 fix: skip accumulated backup files (*.bak.*) — they are NOT config
        # files despite ending in .conf after chained suffixes, but more importantly
        # sshd's Include glob (*.conf) will NOT match them since .bak.* is appended
        # AFTER .conf. However backup_file() was re-backing-up the backups on every
        # wizard re-run, creating an ever-growing chain of filenames. Skip any file
        # whose name contains ".bak." to prevent this accumulation.
        [[ "$_bname" == *".bak."* ]] && continue
        if grep -Eq '^[[:space:]]*(PasswordAuthentication|PermitRootLogin|Port|X11Forwarding|AllowTcpForwarding|AllowAgentForwarding|AllowStreamLocalForwarding|PermitTunnel)[[:space:]]+' "$include_file" 2>/dev/null; then
            backup_file "$include_file" >/dev/null 2>&1 || true
            sed -i -E '/^[[:space:]]*(PasswordAuthentication|PermitRootLogin|Port|X11Forwarding|AllowTcpForwarding|AllowAgentForwarding|AllowStreamLocalForwarding|PermitTunnel)[[:space:]]+/d' "$include_file"
            log_info "Stripped conflicting SSH directives from: ${include_file}"
            stripped=1
        fi
    done < <(find "$SECURITY_SSHD_INCLUDE_DIR" -maxdepth 1 -type f -print0 2>/dev/null)

    if [[ "$stripped" -eq 1 ]]; then
        print_ok "cloud-init SSH overrides stripped from sshd_config.d/"
    fi
    return 0
}

security_list_desired_ssh_ports() {
    local locked_port="${1:-}"
    local transition_port=""

    if [[ -z "$locked_port" ]]; then
        locked_port="$(security_get_locked_ssh_port)"
    fi
    if [[ "${2+x}" == "x" ]]; then
        transition_port="$2"
    else
        transition_port="$(security_get_transition_port)"
    fi

    printf '%s\n' "$locked_port"
    if [[ -n "$transition_port" && "$transition_port" != "$locked_port" ]]; then
        printf '%s\n' "$transition_port"
    fi
}

security_snapshot_sshd_include_dir() {
    local snapshot_root
    snapshot_root=$(mktemp -d /tmp/ops-sshd-include-state-XXXXXX)
    snapshot_path_state "$SECURITY_SSHD_INCLUDE_DIR" "$snapshot_root" "sshd-include-dir"
    echo "$snapshot_root"
}

security_snapshot_ufw_state() {
    local snapshot_root
    snapshot_root=$(mktemp -d /tmp/ops-ufw-state-XXXXXX)
    snapshot_ufw_state "$snapshot_root"
    echo "$snapshot_root"
}

security_ufw_status_has_allow_port() {
    local status_output="$1"
    local port="$2"
    printf '%s\n' "$status_output" | grep -Eq "^[[:space:]]*${port}(/tcp)?([[:space:]]|\(v6\)).*ALLOW"
}

security_finalize_ufw_transition() {
    local new_port="$1"
    local old_port="$2"
    local status_output

    if ! command -v ufw >/dev/null 2>&1; then
        apt_install ufw || {
            print_error "Failed to install ufw while finalizing the SSH transition."
            return 1
        }
    fi

    ufw default deny incoming >/dev/null 2>&1 || {
        print_error "Failed to set UFW default deny incoming while finalizing the SSH transition."
        return 1
    }
    ufw default allow outgoing >/dev/null 2>&1 || {
        print_error "Failed to set UFW default allow outgoing while finalizing the SSH transition."
        return 1
    }
    ufw_allow "${new_port}/tcp" "SSH managed" >/dev/null 2>&1 || {
        print_error "Failed to allow SSH port ${new_port}/tcp in UFW while finalizing the SSH transition."
        return 1
    }
    ufw_allow 80/tcp "HTTP" >/dev/null 2>&1 || {
        print_error "Failed to allow 80/tcp in UFW while finalizing the SSH transition."
        return 1
    }
    ufw_allow 443/tcp "HTTPS" >/dev/null 2>&1 || {
        print_error "Failed to allow 443/tcp in UFW while finalizing the SSH transition."
        return 1
    }

    status_output="$(ufw status 2>/dev/null || true)"
    if security_ufw_status_has_allow_port "$status_output" "8317"; then
        yes | ufw delete allow 8317/tcp >/dev/null 2>&1 || {
            print_error "Failed to remove a public UFW allow rule for 8317/tcp while finalizing the SSH transition."
            return 1
        }
    fi

    if security_ufw_status_has_allow_port "$status_output" "$old_port"; then
        yes | ufw delete allow "${old_port}/tcp" >/dev/null 2>&1 || {
            print_error "Failed to remove the old SSH UFW allow rule for ${old_port}/tcp."
            return 1
        }
    fi

    if grep -qi 'Status: active' <<< "$status_output"; then
        ufw reload >/dev/null 2>&1 || {
            print_error "Failed to reload UFW while finalizing the SSH transition."
            return 1
        }
    else
        ufw --force enable >/dev/null 2>&1 || {
            print_error "Failed to enable UFW while finalizing the SSH transition."
            return 1
        }
    fi

    status_output="$(ufw status 2>/dev/null || true)"
    if ! security_ufw_status_has_allow_port "$status_output" "$new_port"; then
        print_error "UFW does not show SSH port ${new_port}/tcp as allowed after finalization."
        return 1
    fi
    if security_ufw_status_has_allow_port "$status_output" "$old_port"; then
        print_error "UFW still shows the old SSH port ${old_port}/tcp as allowed after finalization."
        return 1
    fi
    if security_ufw_status_has_allow_port "$status_output" "8317"; then
        print_error "UFW still shows 8317/tcp as allowed after finalization."
        return 1
    fi
}

security_apply_fail2ban_ssh_state() {
    local locked_port="${1:-}"
    local transition_port=""
    local has_transition_arg="no"

    if [[ "${2+x}" == "x" ]]; then
        transition_port="$2"
        has_transition_arg="yes"
    fi

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        log_info "security_apply_fail2ban_ssh_state: fail2ban not found — installing..."
        if ! apt_install fail2ban; then
            print_error "Failed to install fail2ban while applying the SSH security state."
            return 1
        fi
    fi

    # backend=systemd works best when python3-systemd is available, but some
    # containers cannot install it. Keep this best-effort like the existing flow.
    if ! dpkg -s python3-systemd >/dev/null 2>&1; then
        apt_install python3-systemd 2>/dev/null || true
    fi

    if [[ "$has_transition_arg" == "yes" ]]; then
        security_write_fail2ban_config "$locked_port" "$transition_port"
    else
        security_write_fail2ban_config "$locked_port"
    fi

    if ! service_enable fail2ban; then
        print_error "Failed to enable fail2ban while applying the SSH security state."
        return 1
    fi
    if ! service_restart fail2ban; then
        print_error "fail2ban restart failed while applying the SSH security state."
        return 1
    fi
    if ! fail2ban-client ping >/dev/null 2>&1; then
        print_error "fail2ban did not respond after restart."
        return 1
    fi
    if ! fail2ban-client status sshd >/dev/null 2>&1; then
        print_error "fail2ban SSH jail is not active after reconciliation."
        return 1
    fi
}

security_restore_ssh_ops_state() {
    local locked_port="$1"
    local transition_port="$2"
    local root_login="$3"
    local password_auth="$4"
    local runtime_user="$5"
    local tcp_forwarding="$6"

    ops_conf_set "ops.conf" "OPS_SSH_PORT" "$locked_port"
    ops_conf_set "ops.conf" "OPS_SSH_TRANSITION_PORT" "$transition_port"
    ops_conf_set "ops.conf" "OPS_SSH_ROOT_LOGIN" "$root_login"
    ops_conf_set "ops.conf" "OPS_SSH_PASSWORD_AUTH" "$password_auth"
    ops_conf_set "ops.conf" "OPS_RUNTIME_USER" "$runtime_user"
    ops_conf_set "ops.conf" "OPS_SSH_TCP_FORWARDING" "$tcp_forwarding"
}

security_reconcile_ufw_rules() {
    local locked_port="${1:-}"
    local transition_port=""
    local has_transition_arg="no"
    local desired_ports=()
    local active_ssh_ports=()
    local existing_ports=()
    local port desired status_output
    local ufw_errors=0
    local managed_locked_port=""
    local managed_state_ambiguous=0

    if [[ "${2+x}" == "x" ]]; then
        transition_port="$2"
        has_transition_arg="yes"
    fi

    managed_locked_port="$(ops_conf_get "ops.conf" "OPS_SSH_PORT" 2>/dev/null || true)"
    if [[ -z "${1:-}" && -z "$managed_locked_port" ]]; then
        managed_state_ambiguous=1
    fi

    if ! command -v ufw > /dev/null 2>&1; then
        apt_install ufw
    fi

    while IFS= read -r port; do
        [[ -n "$port" ]] && active_ssh_ports+=("$port")
    done < <(ss -tlnp 2>/dev/null | awk '/sshd/ {print $4}' | grep -oP ':\K[0-9]+$' | sort -u)

    if [[ "$has_transition_arg" == "yes" ]]; then
        while IFS= read -r port; do
            [[ -n "$port" ]] && desired_ports+=("$port")
        done < <(security_list_desired_ssh_ports "$locked_port" "$transition_port")
    else
        while IFS= read -r port; do
            [[ -n "$port" ]] && desired_ports+=("$port")
        done < <(security_list_desired_ssh_ports "$locked_port")
    fi

    if [[ "$managed_state_ambiguous" -eq 1 ]]; then
        for port in "${active_ssh_ports[@]}"; do
            local seen=0
            [[ -n "$port" ]] || continue
            for desired in "${desired_ports[@]}"; do
                if [[ "$desired" == "$port" ]]; then
                    seen=1
                    break
                fi
            done
            if [[ "$seen" -eq 0 ]]; then
                desired_ports+=("$port")
                log_warn "UFW: preserving live SSH port ${port} during ambiguous bootstrap/rerun state"
            fi
        done
    fi

    # Abort if no SSH ports resolved — prevents lockout via 'default deny'
    if [[ ${#desired_ports[@]} -eq 0 ]]; then
        print_error "UFW reconcile: no SSH ports resolved -- aborting to prevent lockout."
        log_info "security_reconcile_ufw_rules: aborted (no desired SSH ports)"
        return 1
    fi

    if ! ufw default deny incoming > /dev/null 2>&1; then
        print_warn "UFW: failed to set default deny incoming"
        ((ufw_errors++))
    fi
    if ! ufw default allow outgoing > /dev/null 2>&1; then
        print_warn "UFW: failed to set default allow outgoing"
        ((ufw_errors++))
    fi

    # Track SSH rule add success; only enable UFW if at least one succeeded
    local ssh_rules_added=0
    for port in "${desired_ports[@]}"; do
        if ufw_allow "${port}/tcp" "SSH managed" > /dev/null 2>&1; then
            ((ssh_rules_added++))
        else
            print_warn "UFW: failed to add SSH rule for port ${port}/tcp"
            log_info "security_reconcile_ufw_rules: ufw allow ${port}/tcp failed"
        fi
    done
    if ! ufw_allow 80/tcp "HTTP" > /dev/null 2>&1; then
        print_warn "UFW: failed to add 80/tcp rule"
        ((ufw_errors++))
    fi
    if ! ufw_allow 443/tcp "HTTPS" > /dev/null 2>&1; then
        print_warn "UFW: failed to add 443/tcp rule"
        ((ufw_errors++))
    fi

    # Skip enable if no SSH rules added — prevents lockout on fresh UFW enable
    if [[ "$ssh_rules_added" -eq 0 ]]; then
        print_error "UFW reconcile: no SSH rules added -- skipping enable to prevent lockout."
        log_info "security_reconcile_ufw_rules: skipped ufw enable (no SSH rules added)"
        return 1
    fi

    # Normalize UFW status to bare port numbers.
    # Handles both "22/tcp  ALLOW" and "22 (v6)  ALLOW" formats; deduplicates with sort -u.
    status_output="$(ufw status 2>/dev/null || true)"
    while IFS= read -r port; do
        [[ -n "$port" ]] && existing_ports+=("$port")
    done < <(printf '%s\n' "$status_output" \
        | awk '/ALLOW/ {print $1}' \
        | sed -E 's|/tcp$||; s|/udp$||; s|[[:space:]]*\(v6\)[[:space:]]*||; s|[[:space:]]||g' \
        | grep -E '^[0-9]+$' \
        | sort -u)

    for port in "${existing_ports[@]}"; do
        if [[ "$port" == "80" || "$port" == "443" ]]; then
            continue
        fi

        local keep=0
        for desired in "${desired_ports[@]}"; do
            if [[ "$desired" == "$port" ]]; then
                keep=1
                break
            fi
        done

        if [[ "$keep" -eq 0 ]]; then
            local removed_any=0
            if yes | ufw delete allow "${port}/tcp" > /dev/null 2>&1; then
                removed_any=1
            fi
            if yes | ufw delete allow "${port}/udp" > /dev/null 2>&1; then
                removed_any=1
            fi
            if [[ "$removed_any" -eq 1 ]]; then
                log_info "UFW: removed stale allow rule for port ${port}"
            else
                print_warn "UFW: failed to remove stale allow rule for port ${port}"
                ((ufw_errors++))
            fi
        fi
    done

    if grep -qi 'Status: active' <<< "$status_output"; then
        if ! ufw reload > /dev/null 2>&1; then
            print_warn "UFW: failed to reload ufw"
            ((ufw_errors++))
        fi
    else
        if ! ufw --force enable > /dev/null 2>&1; then
            print_warn "UFW: failed to enable ufw"
            ((ufw_errors++))
        fi
    fi

    if [[ "$ufw_errors" -gt 0 ]]; then
        log_info "security_reconcile_ufw_rules: completed with ${ufw_errors} warning-level failures"
        return 1
    fi
}


security_write_fail2ban_config() {
    local locked_port="${1:-}"
    local transition_port=""
    local has_transition_arg="no"
    local ssh_ports=""
    local port

    if [[ "${2+x}" == "x" ]]; then
        transition_port="$2"
        has_transition_arg="yes"
    fi

    # Desired SSH policy comes from OPS managed state. Runtime socket inspection
    # is validation-only; do not derive fail2ban policy from partial live output.
    if [[ "$has_transition_arg" == "yes" ]]; then
        while IFS= read -r port; do
            [[ -n "$port" ]] || continue
            if [[ -n "$ssh_ports" ]]; then
                ssh_ports+=","
            fi
            ssh_ports+="$port"
        done < <(security_list_desired_ssh_ports "$locked_port" "$transition_port")
    else
        while IFS= read -r port; do
            [[ -n "$port" ]] || continue
            if [[ -n "$ssh_ports" ]]; then
                ssh_ports+=","
            fi
            ssh_ports+="$port"
        done < <(security_list_desired_ssh_ports "$locked_port")
    fi

    # Last fallback: port 22
    ssh_ports="${ssh_ports:-22}"

    ensure_dir "/etc/fail2ban/jail.d"
    backup_file "$SECURITY_FAIL2BAN_JAIL_OPS" >/dev/null 2>&1 || true

    # Build conditional nginx jails (only enable if filter file exists)
    local nginx_auth_jail="" nginx_limit_jail=""
    if [[ -f /etc/fail2ban/filter.d/nginx-http-auth.conf ]]; then
        nginx_auth_jail="$(printf '[nginx-http-auth]\nenabled  = true\nport     = http,https\nlogpath  = %%(nginx_error_log)s\nmaxretry = 3\n')"
    fi
    if [[ -f /etc/fail2ban/filter.d/nginx-limit-req.conf ]]; then
        nginx_limit_jail="$(printf '[nginx-limit-req]\nenabled  = true\nport     = http,https\nlogpath  = %%(nginx_error_log)s\nmaxretry = 10\nfindtime = 1m\n')"
    fi

    # P3-4 fix: backend=systemd requires python3-systemd. On OpenVZ/LXC containers
    # without a real systemd journal, the import fails → fail2ban logs errors and
    # silently misses SSH brute-force events.
    # Detect before writing: if import fails, use backend=auto (safe cross-platform fallback).
    local _f2b_backend="auto"
    if python3 -c 'import systemd' > /dev/null 2>&1; then
        _f2b_backend="systemd"
        log_info "fail2ban: python3-systemd available — using backend=systemd"
    else
        log_warn "fail2ban: python3-systemd unavailable — using backend=auto (safe fallback)"
    fi

    write_file "$SECURITY_FAIL2BAN_JAIL_OPS" <<EOF_JAIL
# Managed by OPS — do not edit manually.
[DEFAULT]
bantime = 1d
findtime = 10m
maxretry = 3
bantime.increment = true
bantime.maxtime = 2w
backend = ${_f2b_backend}

[sshd]
enabled  = true
port     = ${ssh_ports}
logpath  = %(sshd_log)s
maxretry = 3

${nginx_auth_jail}
${nginx_limit_jail}
EOF_JAIL
    chmod 644 "$SECURITY_FAIL2BAN_JAIL_OPS"
}

security_apply_sysctl_baseline() {
    backup_file "$SECURITY_SYSCTL_OPS_CONF" >/dev/null 2>&1 || true
    write_file "$SECURITY_SYSCTL_OPS_CONF" <<EOF_SYSCTL
# Managed by OPS — do not edit manually.
# Network: disable ICMP send redirects (server is not a router)
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
# Network: strict reverse path filtering (prevent IP spoofing)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
# Network: reject source-routed packets
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
# Network: log martian packets (helps detect spoofing)
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
# Kernel: disable core dumps for SUID binaries
fs.suid_dumpable = 0
# Memory: reduce swap aggressiveness on VPS
vm.swappiness = 10
EOF_SYSCTL
    chmod 644 "$SECURITY_SYSCTL_OPS_CONF"
    if ! sysctl -p "$SECURITY_SYSCTL_OPS_CONF" >/dev/null 2>&1; then
        log_warn "security_apply_sysctl_baseline: sysctl apply failed for ${SECURITY_SYSCTL_OPS_CONF}"
        return 1
    fi
}

security_ensure_swap() {
    local desired_size_mb
    local _swapfile_escaped
    local swap_active="no"
    desired_size_mb=$(ops_conf_get "ops.conf" "OPS_SWAP_MB" 2>/dev/null || true)
    desired_size_mb="${desired_size_mb:-2048}"
    _swapfile_escaped="${SECURITY_SWAP_FILE//\//\\/}"

    # P5-A: Check existing swap SIZE before returning early.
    # If swapfile exists but is smaller than desired, remove and recreate.
    if swapon --show 2>/dev/null | grep -q "${SECURITY_SWAP_FILE}"; then
        # Bug-2 fix: compare at byte level with a 1 MB tolerance.
        # fallocate -l 2048M allocates exactly (N*1024*1024 - 4096) bytes because
        # ext4/xfs reserve one block for the file header.  Integer MB truncation made
        # 2047.996 MB → 2047, which always triggered recreation.  byte-level compare
        # with a -1 MB slack (i.e. accept anything >= (desired-1)*1048576) is resilient
        # to this filesystem overhead without allowing genuinely undersized swap.
        local _desired_bytes _existing_bytes _threshold_bytes
        _desired_bytes=$(( desired_size_mb * 1048576 ))
        _threshold_bytes=$(( (_desired_bytes) - 1048576 ))   # accept down to -1 MB
        _existing_bytes=$(swapon --show --bytes 2>/dev/null \
            | awk -v f="${SECURITY_SWAP_FILE}" '$1==f {print $3; exit}')
        if [[ -n "$_existing_bytes" && "$_existing_bytes" -ge "$_threshold_bytes" ]]; then
            swap_active="yes"
        else
            local _existing_mb=$(( ${_existing_bytes:-0} / 1048576 ))
            log_info "security_ensure_swap: existing swap ${_existing_mb}MB (${_existing_bytes:-0}B) < desired ${desired_size_mb}MB — recreating."
            swapoff "$SECURITY_SWAP_FILE" 2>/dev/null || true
            rm -f "$SECURITY_SWAP_FILE"
        fi
    fi

    if [[ -f "$SECURITY_SWAP_FILE" ]]; then
        chmod 600 "$SECURITY_SWAP_FILE"
    else
        if ! fallocate -l "${desired_size_mb}M" "$SECURITY_SWAP_FILE" 2>/dev/null && \
           ! dd if=/dev/zero of="$SECURITY_SWAP_FILE" bs=1M count="$desired_size_mb"; then
            print_error "Failed to allocate ${SECURITY_SWAP_FILE} (${desired_size_mb}MB)."
            return 1
        fi
        chmod 600 "$SECURITY_SWAP_FILE"
        if ! mkswap "$SECURITY_SWAP_FILE" >/dev/null 2>&1; then
            print_error "Failed to initialize swap area on ${SECURITY_SWAP_FILE}."
            return 1
        fi
    fi

    if [[ "$swap_active" != "yes" ]]; then
        if ! swapon "$SECURITY_SWAP_FILE" >/dev/null 2>&1; then
            print_error "Failed to activate swap on ${SECURITY_SWAP_FILE}."
            return 1
        fi
    fi
    if ! grep -Eq "^[[:space:]]*${_swapfile_escaped}[[:space:]]+[^[:space:]]+[[:space:]]+swap([[:space:]]|$)" /etc/fstab 2>/dev/null; then
        printf '%s none swap sw 0 0\n' "$SECURITY_SWAP_FILE" >> /etc/fstab
    fi
}

security_ensure_ssh_transition_ports() {
    local old_port="$1"
    local new_port="$2"

    ops_conf_set "ops.conf" "OPS_SSH_PORT" "$new_port"
    if [[ "$old_port" != "$new_port" ]]; then
        ops_conf_set "ops.conf" "OPS_SSH_TRANSITION_PORT" "$old_port"
    fi

    security_reconcile_ufw_rules
}

security_rollback_sshd_config() {
    local sshd_backup="$1"
    local include_state_snapshot="$2"
    local ssh_service="$3"
    local ufw_state_snapshot="${4:-}"
    local fail2ban_state_snapshot="${5:-}"

    print_warn "Rollback triggered: restoring previous SSH, firewall, and fail2ban state..."

    if [[ -n "$sshd_backup" && -f "$sshd_backup" ]]; then
        cp "$sshd_backup" "$SECURITY_SSHD_CONFIG"
        print_warn "Restored SSH config from backup: ${sshd_backup}"
    fi

    if [[ -n "$include_state_snapshot" && -d "$include_state_snapshot" ]]; then
        restore_path_snapshot "$SECURITY_SSHD_INCLUDE_DIR" "$include_state_snapshot" "sshd-include-dir"
    fi

    if [[ -n "$fail2ban_state_snapshot" && -d "$fail2ban_state_snapshot" ]]; then
        restore_path_snapshot "$SECURITY_FAIL2BAN_JAIL_OPS" "$fail2ban_state_snapshot" "fail2ban-ops-jail"
    fi

    if sshd -t > /dev/null 2>&1; then
        service_restart "$ssh_service" >/dev/null 2>&1 || print_warn "Rollback restored SSH config, but SSH service restart still needs manual attention."
    else
        print_error "Rollback restored SSH config still fails sshd -t. Manual recovery required immediately."
    fi

    if [[ -n "$ufw_state_snapshot" && -d "$ufw_state_snapshot" ]]; then
        restore_ufw_state "$ufw_state_snapshot"
    fi

    if [[ -n "$fail2ban_state_snapshot" && -d "$fail2ban_state_snapshot" ]] && command -v fail2ban-client >/dev/null 2>&1; then
        service_restart fail2ban >/dev/null 2>&1 || print_warn "Rollback restored fail2ban config, but fail2ban still needs manual attention."
    fi
}


security_apply_sshd_hardening() {
    local new_port="$1"
    local password_auth="$2"
    local old_port ssh_service sshd_backup include_state_snapshot ufw_state_snapshot
    local prev_locked_port prev_transition_port prev_root_login prev_password_auth prev_runtime_user prev_tcp_forwarding
    local new_transition_port="" new_runtime_user current_tcp_forwarding fail2ban_state_snapshot=""

    old_port=$(security_get_current_ssh_port)
    ssh_service=$(security_detect_ssh_service)
    sshd_backup=$(backup_file "$SECURITY_SSHD_CONFIG" | tail -n1)
    include_state_snapshot=$(security_snapshot_sshd_include_dir)
    ufw_state_snapshot=$(security_snapshot_ufw_state)
    prev_locked_port=$(ops_conf_get "ops.conf" "OPS_SSH_PORT" 2>/dev/null || true)
    prev_transition_port=$(ops_conf_get "ops.conf" "OPS_SSH_TRANSITION_PORT" 2>/dev/null || true)
    prev_root_login=$(ops_conf_get "ops.conf" "OPS_SSH_ROOT_LOGIN" 2>/dev/null || true)
    prev_password_auth=$(ops_conf_get "ops.conf" "OPS_SSH_PASSWORD_AUTH" 2>/dev/null || true)
    prev_runtime_user=$(ops_conf_get "ops.conf" "OPS_RUNTIME_USER" 2>/dev/null || true)
    prev_tcp_forwarding=$(ops_conf_get "ops.conf" "OPS_SSH_TCP_FORWARDING" 2>/dev/null || true)
    current_tcp_forwarding="${prev_tcp_forwarding:-$(security_get_tcp_forwarding)}"
    new_runtime_user=$(security_get_runtime_user)

    fail2ban_state_snapshot=$(mktemp -d /tmp/ops-fail2ban-state-XXXXXX)
    snapshot_path_state "$SECURITY_FAIL2BAN_JAIL_OPS" "$fail2ban_state_snapshot" "fail2ban-ops-jail"

    if [[ "$old_port" != "$new_port" ]]; then
        new_transition_port="$old_port"
    fi

    security_reconcile_sshd_main_config
    # Bug D fix: strip cloud-init SSH overrides BEFORE writing our include file and
    # running sshd -t, so a single service_restart applies all changes atomically.
    security_strip_cloud_init_overrides
    security_write_sshd_hardening_include "$new_port" "$password_auth" "$new_transition_port"

    if ! sshd -t > /dev/null 2>&1; then
        print_error "sshd -t failed after update. Starting rollback."
        security_rollback_sshd_config "$sshd_backup" "$include_state_snapshot" "$ssh_service" "$ufw_state_snapshot" "$fail2ban_state_snapshot"
        rm -rf "$include_state_snapshot" "$ufw_state_snapshot" "$fail2ban_state_snapshot"
        return 1
    fi

    if ! service_restart "$ssh_service"; then
        print_error "SSH service restart failed after update. Starting rollback."
        security_rollback_sshd_config "$sshd_backup" "$include_state_snapshot" "$ssh_service" "$ufw_state_snapshot" "$fail2ban_state_snapshot"
        rm -rf "$include_state_snapshot" "$ufw_state_snapshot" "$fail2ban_state_snapshot"
        return 1
    fi

    if ! security_reconcile_ufw_rules "$new_port" "$new_transition_port"; then
        print_error "UFW reconcile failed after SSH hardening. Restoring previous SSH and firewall state."
        security_rollback_sshd_config "$sshd_backup" "$include_state_snapshot" "$ssh_service" "$ufw_state_snapshot" "$fail2ban_state_snapshot"
        rm -rf "$include_state_snapshot" "$ufw_state_snapshot" "$fail2ban_state_snapshot"
        return 1
    fi

    if ! security_apply_fail2ban_ssh_state "$new_port" "$new_transition_port"; then
        print_error "fail2ban apply failed after SSH hardening. Restoring previous SSH, firewall, and fail2ban state."
        security_rollback_sshd_config "$sshd_backup" "$include_state_snapshot" "$ssh_service" "$ufw_state_snapshot" "$fail2ban_state_snapshot"
        rm -rf "$include_state_snapshot" "$ufw_state_snapshot" "$fail2ban_state_snapshot"
        return 1
    fi

    security_restore_ssh_ops_state "$new_port" "$new_transition_port" "no" "$password_auth" "$new_runtime_user" "$current_tcp_forwarding"
    rm -rf "$include_state_snapshot" "$ufw_state_snapshot" "$fail2ban_state_snapshot"
    print_ok "SSH hardening applied successfully."
    if [[ -n "$new_transition_port" && "$new_transition_port" != "$new_port" ]]; then
        print_warn "Transition safety: keep only managed transition ports until login is verified on port $new_port."
    fi
    return 0
}


# ── Public menu entry ─────────────────────────────────────────
menu_security() {
    _security_menu_run() {
        "$@"
        return 0
    }

    while true; do
        print_section "Security Management"
        echo "  1) Harden SSH config"
        echo "  2) Configure UFW firewall"
        echo "  3) Install & configure fail2ban"
        echo "  4) Show security status"
        echo "  5) Change SSH port"
        echo "  6) Finalize SSH transition (close old SSH port)"
        echo "  7) Apply host baseline (sysctl/swap/firewall/fail2ban)"
        echo "  8) Manage SSH keys"
        echo "  9) TCP Forwarding (VSCode Remote SSH)"
        echo "  10) Auto Security Updates (unattended-upgrades)"
        echo "  0) Back"
        echo ""
        prompt_menu_choice "Select" "" choice
        case "$choice" in
            1) _security_menu_run security_harden_ssh ;;
            2) _security_menu_run security_configure_ufw ;;
            3) _security_menu_run security_setup_fail2ban ;;
            4) _security_menu_run security_status ;;
            5) _security_menu_run security_change_ssh_port ;;
            6) _security_menu_run security_finalize_ssh_transition ;;
            7) _security_menu_run security_apply_host_baseline ;;
            8) _security_menu_run security_manage_ssh_keys ;;
            9) _security_menu_run security_manage_tcp_forwarding ;;
            10) _security_menu_run security_manage_unattended_upgrades ;;
            0) return 0                       ;;
            *) print_warn "Invalid option"    ;;
        esac
    done
}

# ── Actions (stubs) ───────────────────────────────────────────

security_harden_ssh() {
    print_section "SSH Hardening"
    security_require_root || return 1

    local current_port new_port password_auth
    current_port=$(security_get_current_ssh_port)

    prompt_input "Enter SSH port" "$current_port"
    new_port="$REPLY"
    security_validate_ssh_port "$new_port" "$current_port" || return 1

    # Fix B: Guard -- only offer to disable PasswordAuthentication if SSH key is present.
    local admin_user
    admin_user="$(security_get_admin_user)"
    if _security_has_authorized_keys "$admin_user"; then
        if prompt_confirm "Disable PasswordAuthentication after transition completes?"; then
            password_auth="no"
        else
            password_auth="yes"
        fi
    else
        print_warn "No SSH public key found for '${admin_user}'."
        print_warn "PasswordAuthentication will remain ENABLED to prevent SSH lockout."
        print_warn "Add a key first: Security menu -> Manage SSH Keys (option 8)"
        password_auth="yes"
    fi

    security_apply_sshd_hardening "$new_port" "$password_auth" || return 1
    security_status
}

security_configure_ufw() {
    print_section "UFW Firewall"
    security_require_root || return 1

    print_warn "This will reconcile UFW to OPS-managed baseline and remove stale SSH rules."
    if ! prompt_confirm "Continue applying UFW baseline now?"; then
        print_warn "Cancelled."
        return 0
    fi

    security_reconcile_ufw_rules || return 1

    print_ok "UFW baseline reconciled."
    ufw_status
}

security_setup_fail2ban() {
    print_section "fail2ban Setup"
    security_require_root || return 1

    security_apply_fail2ban_ssh_state || return 1

    print_ok "fail2ban configured for OPS-managed SSH and nginx baseline."
    fail2ban-client status
}

security_status() {
    print_section "Security Status"
    local ssh_port root_login password_auth transition_port runtime_user tcp_fwd_live tcp_fwd_conf
    local sshd_state live_port conf_port

    sshd_state="$(sshd -T 2>/dev/null || true)"
    ssh_port=$(security_get_current_ssh_port)
    root_login=$(awk '/^permitrootlogin /{print $2; exit}' <<< "$sshd_state")
    password_auth=$(awk '/^passwordauthentication /{print $2; exit}' <<< "$sshd_state")
    transition_port=$(security_get_transition_port)
    runtime_user=$(security_get_runtime_user)
    tcp_fwd_live=$(awk '/^allowtcpforwarding /{print $2; exit}' <<< "$sshd_state")
    tcp_fwd_conf=$(security_get_tcp_forwarding)

    echo "Locked SSH Port: ${ssh_port}"
    echo "Transition SSH Port: ${transition_port:-<none>}"
    echo "PermitRootLogin: ${root_login:-<unknown>}"
    echo "PasswordAuthentication: ${password_auth:-<unknown>}"
    echo "AllowTcpForwarding (live):   ${tcp_fwd_live:-<unknown>}"
    echo "AllowTcpForwarding (config): ${tcp_fwd_conf}"
    echo "Runtime User: ${runtime_user}"
    echo "Host Baseline Sysctl File: ${SECURITY_SYSCTL_OPS_CONF}"
    echo "Swap File: ${SECURITY_SWAP_FILE}"
    echo ""

    # P5-E: SSH port drift detection — warn if live sshd port differs from ops.conf
    live_port=$(awk '/^port / {print $2; exit}' <<< "$sshd_state")
    conf_port=$(ops_conf_get "ops.conf" "OPS_SSH_PORT" || true)
    if [[ -n "$live_port" && -n "$conf_port" && "$live_port" != "$conf_port" ]]; then
        print_warn "DRIFT DETECTED: live SSH port ($live_port) != ops.conf ($conf_port)"
        print_warn "Run 'Security → Harden SSH' or 'Security → Change SSH Port' to reconcile."
    fi

    if sshd -t >/dev/null 2>&1; then
        print_ok "sshd -t: OK"
    else
        print_error "sshd -t: FAILED"
    fi

    if [[ -f "$SECURITY_SSHD_OPS_INCLUDE" ]]; then
        print_ok "OPS SSH include present: ${SECURITY_SSHD_OPS_INCLUDE}"
    else
        print_warn "OPS SSH include missing: ${SECURITY_SSHD_OPS_INCLUDE}"
    fi

    echo ""
    if command -v ufw >/dev/null 2>&1; then
        ufw_status || true
    else
        print_warn "ufw not installed"
    fi

    echo ""
    if command -v fail2ban-client >/dev/null 2>&1; then
        fail2ban-client status || true
        fail2ban-client status sshd || true
    else
        print_warn "fail2ban not installed"
    fi

    echo ""
    sysctl net.ipv4.conf.all.send_redirects net.ipv4.conf.default.send_redirects net.ipv4.conf.all.log_martians net.ipv4.conf.default.log_martians vm.swappiness 2>/dev/null || true
    swapon --show 2>/dev/null || true
}

security_change_ssh_port() {
    print_section "Change SSH Port"
    security_require_root || return 1

    local current_port new_port current_password_auth admin_user
    current_port=$(security_get_current_ssh_port)

    prompt_input "Enter new SSH port" "$current_port"
    new_port="$REPLY"
    security_validate_ssh_port "$new_port" "$current_port" || return 1

    current_password_auth=$(ops_conf_get "ops.conf" "OPS_SSH_PASSWORD_AUTH" 2>/dev/null || true)
    # F-05: Safe default is "yes" — never silently disable password auth if the key
    # was not explicitly recorded in ops.conf. A lockout risk exists if we default to
    # "no" and the operator has no SSH key installed.
    if [[ "$current_password_auth" != "yes" && "$current_password_auth" != "no" ]]; then
        current_password_auth="yes"
    fi

    admin_user="$(security_get_admin_user)"
    if [[ "$current_password_auth" == "no" ]] && ! _security_has_authorized_keys "$admin_user"; then
        print_warn "OPS_SSH_PASSWORD_AUTH is set to 'no', but no SSH key is currently authorized for '${admin_user}'."
        print_warn "Falling back to PasswordAuthentication=yes during the port change to prevent SSH lockout."
        current_password_auth="yes"
    fi
    print_warn "PasswordAuthentication is currently: ${current_password_auth} (will be preserved on port change)"

    security_apply_sshd_hardening "$new_port" "$current_password_auth" || return 1

    if [[ "$new_port" != "$current_port" ]]; then
        print_warn "After login test succeeds in a new SSH session on the new port, run 'Finalize SSH transition (close old SSH port)'."
    fi
    security_status
}

security_restore_finalize_backups() {
    security_rollback_sshd_config "$@"
}

security_finalize_ssh_transition_preflight() {
    local final_pw_auth admin_user
    final_pw_auth="$(ops_conf_get "ops.conf" "OPS_SSH_PASSWORD_AUTH" 2>/dev/null || true)"
    admin_user="$(security_get_admin_user)"

    if [[ "$final_pw_auth" != "no" ]]; then
        print_error "Cannot finalize SSH transition while PasswordAuthentication is still enabled for the final steady state."
        print_error "Use Security -> Manage SSH Keys and choose 'Disable PasswordAuthentication after transition completes' first."
        return 1
    fi

    if ! _security_has_authorized_keys "$admin_user"; then
        print_error "Cannot finalize SSH transition: no valid SSH key is authorized for '${admin_user}'."
        print_error "Add a key first in Security -> Manage SSH Keys, then retry finalization."
        return 1
    fi
}

security_finalize_ssh_transition_apply() {
    security_require_root || return 1

    exec 8>/var/lock/ops-ssh-finalize.lock
    if ! flock -n 8; then
        print_warn "Another SSH finalize operation is already running."
        log_info "security_finalize_ssh_transition_apply: finalize lock already held"
        return 0
    fi

    local new_port old_port admin_user server_ip ssh_service
    local prev_locked_port prev_transition_port prev_root_login prev_runtime_user prev_tcp_forwarding current_tcp_forwarding
    local final_pw_auth="no"
    new_port=$(security_get_locked_ssh_port)
    old_port=$(security_get_transition_port)
    ssh_service=$(security_detect_ssh_service)
    prev_locked_port="$new_port"
    prev_transition_port="$old_port"
    prev_root_login="$(ops_conf_get "ops.conf" "OPS_SSH_ROOT_LOGIN" 2>/dev/null || true)"
    prev_runtime_user="$(ops_conf_get "ops.conf" "OPS_RUNTIME_USER" 2>/dev/null || true)"
    prev_tcp_forwarding="$(ops_conf_get "ops.conf" "OPS_SSH_TCP_FORWARDING" 2>/dev/null || true)"
    current_tcp_forwarding="${prev_tcp_forwarding:-$(security_get_tcp_forwarding)}"

    if [[ -z "$old_port" || "$old_port" == "$new_port" ]]; then
        print_warn "No SSH transition port is currently recorded."
        return 0
    fi

    security_finalize_ssh_transition_preflight || return 1

    local sshd_backup include_state_snapshot ufw_state_snapshot fail2ban_state_snapshot=""
    sshd_backup="$(backup_file "$SECURITY_SSHD_CONFIG" 2>/dev/null | tail -n1 || true)"
    include_state_snapshot="$(security_snapshot_sshd_include_dir)"
    ufw_state_snapshot="$(security_snapshot_ufw_state)"
    fail2ban_state_snapshot=$(mktemp -d /tmp/ops-fail2ban-state-XXXXXX)
    snapshot_path_state "$SECURITY_FAIL2BAN_JAIL_OPS" "$fail2ban_state_snapshot" "fail2ban-ops-jail"

    security_reconcile_sshd_main_config
    security_strip_cloud_init_overrides
    security_write_sshd_hardening_include "$new_port" "$final_pw_auth" ""

    if ! sshd -t >/dev/null 2>&1; then
        print_error "sshd -t failed while finalizing transition. Restoring previous SSH config."
        security_restore_finalize_backups "$sshd_backup" "$include_state_snapshot" "$ssh_service" "$ufw_state_snapshot" "$fail2ban_state_snapshot"
        rm -rf "$include_state_snapshot" "$ufw_state_snapshot" "$fail2ban_state_snapshot"
        return 1
    fi

    if ! service_restart "$ssh_service"; then
        print_error "SSH service restart failed while finalizing transition. Restoring previous SSH config."
        security_restore_finalize_backups "$sshd_backup" "$include_state_snapshot" "$ssh_service" "$ufw_state_snapshot" "$fail2ban_state_snapshot"
        rm -rf "$include_state_snapshot" "$ufw_state_snapshot" "$fail2ban_state_snapshot"
        return 1
    fi

    if ! security_finalize_ufw_transition "$new_port" "$old_port"; then
        print_error "UFW finalize failed while closing the old SSH transition port. Restoring previous SSH and firewall state."
        security_restore_finalize_backups "$sshd_backup" "$include_state_snapshot" "$ssh_service" "$ufw_state_snapshot" "$fail2ban_state_snapshot"
        rm -rf "$include_state_snapshot" "$ufw_state_snapshot" "$fail2ban_state_snapshot"
        return 1
    fi

    if ! security_apply_fail2ban_ssh_state "$new_port" ""; then
        print_error "fail2ban apply failed while finalizing the SSH transition. Restoring previous SSH, firewall, fail2ban, and OPS SSH state."
        security_restore_finalize_backups "$sshd_backup" "$include_state_snapshot" "$ssh_service" "$ufw_state_snapshot" "$fail2ban_state_snapshot"
        rm -rf "$include_state_snapshot" "$ufw_state_snapshot" "$fail2ban_state_snapshot"
        return 1
    fi

    security_restore_ssh_ops_state "$new_port" "" "$prev_root_login" "$final_pw_auth" "$prev_runtime_user" "$current_tcp_forwarding"

    rm -rf "$include_state_snapshot" "$ufw_state_snapshot" "$fail2ban_state_snapshot"

    admin_user=$(security_get_admin_user)
    server_ip=$(security_get_server_ip)

    print_ok "Old SSH port ${old_port} removed from managed config and firewall."
    echo "You MUST now use: ssh -p ${new_port} ${admin_user}@${server_ip}"
    if command -v ufw >/dev/null 2>&1; then
        ufw_status
    fi
}

security_finalize_ssh_transition() {
    print_section "Finalize SSH Transition"
    security_require_root || return 1

    local new_port old_port
    new_port=$(security_get_locked_ssh_port)
    old_port=$(security_get_transition_port)

    if [[ -z "$old_port" || "$old_port" == "$new_port" ]]; then
        print_warn "No SSH transition port is currently recorded."
        return 0
    fi

    security_finalize_ssh_transition_preflight || return 1

    print_warn "Only continue after you confirmed SSH login works on port ${new_port}."
    if ! prompt_confirm "Finalize SSH transition and remove old port ${old_port}?"; then
        print_warn "Cancelled."
        return 0
    fi

    security_finalize_ssh_transition_apply
}

security_apply_host_baseline() {
    print_section "OPS Host Security Baseline"
    security_require_root || return 1

    security_normalize_script_permissions
    security_apply_sysctl_baseline || return 1
    security_ensure_swap || return 1
    security_reconcile_ufw_rules || return 1

    if ! security_apply_fail2ban_ssh_state; then
        print_error "Failed to reconcile fail2ban as part of the OPS host baseline."
        return 1
    fi

    print_ok "OPS host security baseline applied."
    security_status
}

# -- Fix C: SSH Key Management sub-menu ----------------------------
# Allows viewing, adding and removing SSH public keys for the admin user,
# and toggling PasswordAuthentication with safety guardrails.
security_manage_ssh_keys() {
    print_section "Manage SSH Keys"
    security_require_root || return 1

    local admin_user admin_home auth_keys
    admin_user="$(security_get_admin_user)"
    admin_home=$(getent passwd "$admin_user" 2>/dev/null | cut -d: -f6 || true)

    if [[ -z "$admin_home" || ! -d "$admin_home" ]]; then
        print_error "Cannot find home directory for '${admin_user}'."
        return 1
    fi
    auth_keys="${admin_home}/.ssh/authorized_keys"

    while true; do
        echo ""
        echo "  Admin user : ${admin_user}"
        echo "  Keys file  : ${auth_keys}"
        echo ""

        # Display current keys
        local key_count=0
        if [[ -f "$auth_keys" ]]; then
            echo "  Current authorized keys:"
            local n=1
            while IFS= read -r line || [[ -n "$line" ]]; do
                _security_authorized_key_line_is_valid "$line" || continue
                printf "    %d) %s\n" "$n" "$line"
                ((n++))
            done < "$auth_keys"
            key_count=$((n - 1))
        fi
        if (( key_count == 0 )); then
            print_warn "No SSH public keys currently authorized."
        fi

        echo ""
        echo "  1) Add new SSH public key"
        echo "  2) Remove a key by number"
        echo "  3) Enable PasswordAuthentication (emergency restore)"
        echo "  4) Disable PasswordAuthentication (deferred if transition active)"
        echo "  0) Back"
        echo ""
        prompt_menu_choice "  Select" "" subchoice

        case "$subchoice" in
            1)
                echo ""
                echo "  Paste your SSH public key below (one line, then Enter):"
                tty_write "  > "
                tty_read new_key
                if [[ -z "$new_key" ]]; then
                    print_warn "Empty input -- cancelled."
                elif ! _security_authorized_key_line_is_valid "$new_key"; then
                    print_error "Input does not look like a valid SSH public key. Not added."
                else
                    local tmp_add
                    mkdir -p "${admin_home}/.ssh"
                    chmod 700 "${admin_home}/.ssh"
                    chown "${admin_user}:${admin_user}" "${admin_home}/.ssh"

                    if [[ -f "$auth_keys" ]] && grep -Fxq "$new_key" "$auth_keys" 2>/dev/null; then
                        print_warn "That SSH public key is already authorized."
                        continue
                    fi

                    if [[ -f "$auth_keys" ]] && ! backup_file "$auth_keys" >/dev/null 2>&1; then
                        print_error "Failed to back up ${auth_keys}. Key not added."
                        continue
                    fi

                    tmp_add=$(mktemp) || {
                        print_error "Failed to create a temporary file for authorized_keys update."
                        continue
                    }
                    if [[ -f "$auth_keys" ]]; then
                        cat "$auth_keys" > "$tmp_add"
                    fi
                    printf '%s\n' "$new_key" >> "$tmp_add"
                    if ! mv "$tmp_add" "$auth_keys"; then
                        rm -f "$tmp_add"
                        print_error "Failed to update ${auth_keys}. Key not added."
                        continue
                    fi
                    chmod 600 "$auth_keys"
                    chown "${admin_user}:${admin_user}" "$auth_keys"
                    print_ok "Key added to ${auth_keys}."
                fi
                ;;
            2)
                if [[ ! -f "$auth_keys" ]] || (( key_count == 0 )); then
                    print_warn "No authorized_keys file or no valid keys found."
                    continue
                fi
                echo ""
                tty_write "  Enter key number to remove (1-${key_count}): "
                tty_read del_num
                if ! [[ "$del_num" =~ ^[0-9]+$ ]] || \
                   (( del_num < 1 || del_num > key_count )); then
                    print_warn "Invalid number. Must be between 1 and ${key_count}."
                    continue
                fi
                if ! prompt_confirm "Remove key #${del_num}?"; then
                    print_warn "Cancelled."
                    continue
                fi
                if ! backup_file "$auth_keys" >/dev/null 2>&1; then
                    print_error "Failed to back up ${auth_keys}. Key not removed."
                    continue
                fi
                local tmp_del counted=0
                tmp_del=$(mktemp) || {
                    print_error "Failed to create a temporary file for authorized_keys update."
                    continue
                }
                if ! while IFS= read -r line || [[ -n "$line" ]]; do
                    if _security_authorized_key_line_is_valid "$line"; then
                        ((counted++))
                        [[ "$counted" -eq "$del_num" ]] && continue
                    fi
                    printf '%s\n' "$line"
                done < "$auth_keys" > "$tmp_del"; then
                    rm -f "$tmp_del"
                    print_error "Failed to rebuild ${auth_keys}. Key not removed."
                    continue
                fi
                if ! mv "$tmp_del" "$auth_keys"; then
                    rm -f "$tmp_del"
                    print_error "Failed to update ${auth_keys}. Key not removed."
                    continue
                fi
                chmod 600 "$auth_keys"
                chown "${admin_user}:${admin_user}" "$auth_keys"
                print_ok "Key #${del_num} removed."
                ;;
            3)
                print_warn "WARNING: Enabling PasswordAuthentication allows password-based SSH login."
                if prompt_confirm "Enable PasswordAuthentication?"; then
                    local pw_port ssh_svc _pw_transition_port _prev_pw
                    pw_port="$(security_get_locked_ssh_port)"
                    ssh_svc="$(security_detect_ssh_service)"
                    _pw_transition_port="$(security_get_transition_port)"
                    _prev_pw="$(ops_conf_get "ops.conf" "OPS_SSH_PASSWORD_AUTH" 2>/dev/null || true)"
                    _prev_pw="${_prev_pw:-yes}"
                    security_write_sshd_hardening_include "$pw_port" "yes" "$_pw_transition_port"
                    if ! sshd -t >/dev/null 2>&1; then
                        print_error "sshd -t validation failed. Reverting include file."
                        security_write_sshd_hardening_include "$pw_port" "$_prev_pw" "$_pw_transition_port"
                        continue
                    fi
                    if ! service_reload "$ssh_svc" >/dev/null 2>&1; then
                        print_error "SSH reload failed. Reverting include file."
                        security_write_sshd_hardening_include "$pw_port" "$_prev_pw" "$_pw_transition_port"
                        continue
                    fi
                    ops_conf_set "ops.conf" "OPS_SSH_PASSWORD_AUTH" "yes"
                    print_ok "PasswordAuthentication enabled. SSH reloaded."
                    if [[ -n "$_pw_transition_port" && "$_pw_transition_port" != "$pw_port" ]]; then
                        print_warn "Active SSH transition detected. Finalize will remain blocked until PasswordAuthentication is disabled again."
                    fi
                fi
                ;;
            4)
                if ! _security_has_authorized_keys "$admin_user"; then
                    print_error "No SSH key found for '${admin_user}'."
                    print_error "Add a key first (option 1) to avoid lockout."
                else
                    local lock_port ssh_svc _lock_transition_port _prev_lock_pw
                    lock_port="$(security_get_locked_ssh_port)"
                    ssh_svc="$(security_detect_ssh_service)"
                    _lock_transition_port="$(security_get_transition_port)"
                    _prev_lock_pw="$(ops_conf_get "ops.conf" "OPS_SSH_PASSWORD_AUTH" 2>/dev/null || true)"
                    _prev_lock_pw="${_prev_lock_pw:-yes}"

                    if [[ -n "$_lock_transition_port" && "$_lock_transition_port" != "$lock_port" ]]; then
                        print_warn "WARNING: Active SSH transition detected. PasswordAuthentication will stay enabled until transition finalization."
                        if ! prompt_confirm "Disable PasswordAuthentication after transition completes?"; then
                            continue
                        fi
                    else
                        print_warn "WARNING: Only SSH key logins will work after this change."
                        if ! prompt_confirm "Disable PasswordAuthentication?"; then
                            continue
                        fi
                    fi

                    security_write_sshd_hardening_include "$lock_port" "no" "$_lock_transition_port"
                    if ! sshd -t >/dev/null 2>&1; then
                        print_error "sshd -t validation failed. Reverting include file."
                        security_write_sshd_hardening_include "$lock_port" "$_prev_lock_pw" "$_lock_transition_port"
                        continue
                    fi
                    if ! service_reload "$ssh_svc" >/dev/null 2>&1; then
                        print_error "SSH reload failed. Reverting include file."
                        security_write_sshd_hardening_include "$lock_port" "$_prev_lock_pw" "$_lock_transition_port"
                        continue
                    fi
                    ops_conf_set "ops.conf" "OPS_SSH_PASSWORD_AUTH" "no"
                    if [[ -n "$_lock_transition_port" && "$_lock_transition_port" != "$lock_port" ]]; then
                        print_ok "Desired post-finalize state saved: PasswordAuthentication disabled. Live SSH remains password-enabled until transition finalization."
                    else
                        print_ok "PasswordAuthentication disabled. SSH key-only mode active."
                    fi
                fi
                ;;
            0) return ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}

# ── TCP Forwarding management (VSCode Remote SSH) ─────────────────────────────
# Toggles AllowTcpForwarding in the OPS-managed sshd include file.
# Required for VSCode SSH Remote (SOCKS dynamic port forwarding -D).
# The setting is persisted in ops.conf as OPS_SSH_TCP_FORWARDING.
security_manage_tcp_forwarding() {
    print_section "TCP Forwarding (VSCode Remote SSH)"
    security_require_root || return 1

    local current ssh_svc locked_port password_auth transition_port
    current="$(security_get_tcp_forwarding)"
    ssh_svc="$(security_detect_ssh_service)"
    locked_port="$(security_get_locked_ssh_port)"
    password_auth="$(ops_conf_get "ops.conf" "OPS_SSH_PASSWORD_AUTH" 2>/dev/null || true)"
    password_auth="${password_auth:-yes}"
    transition_port="$(security_get_transition_port)"

    echo ""
    echo "  Current setting : AllowTcpForwarding = ${current}"
    echo ""
    echo "  TCP Forwarding is required by VSCode SSH Remote (SOCKS -D tunnel)."
    echo "  Enabling allows SSH port forwarding through this server."
    echo "  Disabling (default) improves security by preventing tunnel abuse."
    echo ""
    echo "  1) Enable TCP Forwarding  (required for VSCode Remote SSH)"
    echo "  2) Disable TCP Forwarding (security-hardened default)"
    echo "  3) Show live sshd TCP forwarding status"
    echo "  0) Back"
    echo ""
    prompt_menu_choice "  Select" "" subchoice
    case "$subchoice" in
        1)
            if [[ "$current" == "yes" ]]; then
                print_ok "TCP Forwarding is already enabled."
                return 0
            fi
            print_warn "Enabling AllowTcpForwarding reduces SSH hardening (tunnel / port-scan risk)."
            if prompt_confirm "Enable TCP Forwarding?"; then
                security_write_sshd_hardening_include "$locked_port" "$password_auth" "$transition_port" "yes"
                if ! sshd -t >/dev/null 2>&1; then
                    print_error "sshd -t validation failed. Reverting include file."
                    security_write_sshd_hardening_include "$locked_port" "$password_auth" "$transition_port" "$current"
                    return 1
                fi
                if ! service_reload "$ssh_svc" >/dev/null 2>&1; then
                    print_error "SSH reload failed. Reverting include file."
                    security_write_sshd_hardening_include "$locked_port" "$password_auth" "$transition_port" "$current"
                    return 1
                fi
                ops_conf_set "ops.conf" "OPS_SSH_TCP_FORWARDING" "yes"
                print_ok "TCP Forwarding enabled. SSH reloaded."
                print_warn "Reconnect VSCode SSH Remote to use the new setting."
            else
                print_warn "Cancelled."
            fi
            ;;
        2)
            if [[ "$current" == "no" ]]; then
                print_ok "TCP Forwarding is already disabled."
                return 0
            fi
            print_warn "Disabling TCP Forwarding will break VSCode SSH Remote connections."
            if prompt_confirm "Disable TCP Forwarding?"; then
                security_write_sshd_hardening_include "$locked_port" "$password_auth" "$transition_port" "no"
                if ! sshd -t >/dev/null 2>&1; then
                    print_error "sshd -t validation failed. Reverting include file."
                    security_write_sshd_hardening_include "$locked_port" "$password_auth" "$transition_port" "$current"
                    return 1
                fi
                if ! service_reload "$ssh_svc" >/dev/null 2>&1; then
                    print_error "SSH reload failed. Reverting include file."
                    security_write_sshd_hardening_include "$locked_port" "$password_auth" "$transition_port" "$current"
                    return 1
                fi
                ops_conf_set "ops.conf" "OPS_SSH_TCP_FORWARDING" "no"
                print_ok "TCP Forwarding disabled. SSH reloaded."
            else
                print_warn "Cancelled."
            fi
            ;;
        3)
            local live_val
            live_val=$(sshd -T 2>/dev/null | awk '/^allowtcpforwarding /{print $2; exit}' || true)
            echo "  AllowTcpForwarding (sshd live): ${live_val:-<unknown>}"
            echo "  AllowTcpForwarding (ops.conf):  $(security_get_tcp_forwarding)"
            ;;
        0) return ;;
        *) print_warn "Invalid option" ;;
    esac
}

# ── Auto Security Updates (unattended-upgrades) ───────────────────────────────
# Manages automatic security package updates via unattended-upgrades.
# Persists enabled/disabled state in ops.conf (OPS_UNATTENDED_UPGRADES).
security_uu_is_installed() {
    dpkg -l unattended-upgrades 2>/dev/null | grep -q '^ii'
}

security_uu_is_active() {
    systemctl is-active apt-daily-upgrade.timer >/dev/null 2>&1
}

security_uu_get_status_line() {
    if security_uu_is_installed; then
        if security_uu_is_active; then
            echo "enabled (timer active)"
        else
            echo "installed but timer inactive"
        fi
    else
        echo "not installed"
    fi
}

security_manage_unattended_upgrades() {
    print_section "Auto Security Updates (unattended-upgrades)"
    security_require_root || return 1

    while true; do
        local status_line
        status_line="$(security_uu_get_status_line)"

        echo ""
        echo "  Status : ${status_line}"
        echo ""
        echo "  1) Enable  — install & activate automatic security updates"
        echo "  2) Disable — stop timer (keep package installed)"
        echo "  3) Run now — apply all pending security updates immediately"
        echo "  4) Show status & recent log"
        echo "  0) Back"
        echo ""
        prompt_menu_choice "  Select" "" subchoice

        case "$subchoice" in
            1)
                print_section "Enable Auto Security Updates"
                if ! security_uu_is_installed; then
                    print_warn "Installing unattended-upgrades..."
                    apt_install unattended-upgrades
                fi
                # Configure with debconf non-interactively to enable security updates
                echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' \
                    | debconf-set-selections 2>/dev/null || true
                dpkg-reconfigure -f noninteractive unattended-upgrades 2>/dev/null || true
                systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
                ops_conf_set "ops.conf" "OPS_UNATTENDED_UPGRADES" "enabled"
                print_ok "unattended-upgrades enabled. Security updates will be applied automatically."
                systemctl status apt-daily-upgrade.timer --no-pager -l 2>/dev/null | head -10 || true
                ;;
            2)
                print_section "Disable Auto Security Updates"
                if ! security_uu_is_installed; then
                    print_warn "unattended-upgrades is not installed — nothing to disable."
                    continue
                fi
                print_warn "This will stop the automatic update timer. The package remains installed."
                if ! prompt_confirm "Disable automatic security updates?"; then
                    print_warn "Cancelled."
                    continue
                fi
                systemctl disable --now apt-daily-upgrade.timer >/dev/null 2>&1 || true
                ops_conf_set "ops.conf" "OPS_UNATTENDED_UPGRADES" "disabled"
                print_ok "Auto security updates disabled. Run option 1 to re-enable."
                ;;
            3)
                print_section "Run Security Updates Now"
                if ! security_uu_is_installed; then
                    print_warn "unattended-upgrades is not installed."
                    if prompt_confirm "Install and run now?"; then
                        apt_install unattended-upgrades
                    else
                        continue
                    fi
                fi
                print_warn "Running apt-get update first..."
                apt-get update -qq
                print_warn "Applying unattended-upgrades (this may take a while)..."
                unattended-upgrade --verbose
                print_ok "Unattended-upgrades run complete."
                ;;
            4)
                print_section "Auto Security Updates Status"
                echo "  Package : $(security_uu_get_status_line)"
                echo ""
                if systemctl list-timers apt-daily-upgrade.timer --no-pager 2>/dev/null | grep -q apt-daily-upgrade; then
                    systemctl list-timers apt-daily-upgrade.timer --no-pager 2>/dev/null || true
                else
                    print_warn "Timer apt-daily-upgrade.timer not found."
                fi
                echo ""
                local logfile
                logfile=$(ls -t /var/log/unattended-upgrades/unattended-upgrades.log* 2>/dev/null | head -1 || true)
                if [[ -n "$logfile" && -f "$logfile" ]]; then
                    echo "  Last 20 lines of ${logfile}:"
                    echo ""
                    tail -20 "$logfile" || true
                else
                    print_warn "No unattended-upgrades log found (has it run yet?)."
                fi
                ;;
            0) return ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}
