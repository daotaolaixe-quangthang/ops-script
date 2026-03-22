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

    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        print_error "SSH port must be numeric."
        return 1
    fi

    if (( port < 1 || port > 65535 )); then
        print_error "SSH port must be between 1 and 65535."
        return 1
    fi

    if (( port == 20128 )); then
        print_error "Port 20128 is forbidden (reserved security constraint for 9router hardening)."
        return 1
    fi
}

security_set_sshd_option() {
    local key="$1"
    local value="$2"
    local file="$3"

    if grep -Eq "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+" "$file"; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+.*|${key} ${value}|" "$file"
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

# _security_has_authorized_keys <username>
# Fix B: Returns 0 if the user has at least one valid SSH public key.
# Used to guard against disabling PasswordAuthentication with no key present.
_security_has_authorized_keys() {
    local user="$1"
    local home_dir
    home_dir=$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)
    [[ -z "$home_dir" ]] && return 1
    local auth_keys="${home_dir}/.ssh/authorized_keys"
    [[ -f "$auth_keys" ]] && \
        grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp|sk-ssh) ' "$auth_keys" 2>/dev/null
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
    security_validate_ssh_port "$new_port" || return 1

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

    if [[ "$new_port" != "$current_port" ]]; then
        security_apply_sshd_hardening "$new_port" "$password_auth" || return 1
        print_warn "Open a NEW terminal and verify SSH on port ${new_port} before you finalize and remove old port ${current_port}."
    else
        ops_conf_set "ops.conf" "OPS_SSH_PORT" "$current_port"
        ops_conf_set "ops.conf" "OPS_SSH_TRANSITION_PORT" ""
        ops_conf_set "ops.conf" "OPS_SSH_PASSWORD_AUTH" "$password_auth"
        security_reconcile_ufw_rules
        security_write_fail2ban_config
        service_enable fail2ban >/dev/null 2>&1 || true
        service_restart fail2ban >/dev/null 2>&1 || true
        print_ok "SSH port unchanged; managed firewall and fail2ban baseline reconciled."
    fi

    security_status
}

security_write_sshd_hardening_include() {
    local locked_port="$1"
    local password_auth="$2"
    local transition_port="${3:-}"
    # Read TCP forwarding preference; default no (security-hardened)
    local tcp_forwarding
    tcp_forwarding="$(security_get_tcp_forwarding)"

    ensure_dir "$SECURITY_SSHD_INCLUDE_DIR"
    backup_file "$SECURITY_SSHD_OPS_INCLUDE" >/dev/null 2>&1 || true
    write_file "$SECURITY_SSHD_OPS_INCLUDE" <<EOF_SSH_OPS
# Managed by OPS — do not edit manually.
PermitRootLogin no
PasswordAuthentication ${password_auth}
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
    if [[ -d "$SECURITY_SSHD_INCLUDE_DIR" ]]; then
        find "$SECURITY_SSHD_INCLUDE_DIR" -maxdepth 1 -type f ! -name '99-ops-hardening.conf' -print0 2>/dev/null | while IFS= read -r -d '' include_file; do
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
        # Skip our own managed file
        [[ "$(basename "$include_file")" == "99-ops-hardening.conf" ]] && continue
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
    local locked_port transition_port
    locked_port="$(security_get_locked_ssh_port)"
    transition_port="$(security_get_transition_port)"

    printf '%s\n' "$locked_port"
    if [[ -n "$transition_port" && "$transition_port" != "$locked_port" ]]; then
        printf '%s\n' "$transition_port"
    fi
}

security_reconcile_ufw_rules() {
    local desired_ports=()
    local port status_output existing_ports=()

    if ! command -v ufw > /dev/null 2>&1; then
        apt_install ufw
    fi

    while IFS= read -r port; do
        [[ -n "$port" ]] && desired_ports+=("$port")
    done < <(security_list_desired_ssh_ports)

    # Abort if no SSH ports resolved — prevents lockout via 'default deny'
    if [[ ${#desired_ports[@]} -eq 0 ]]; then
        print_error "UFW reconcile: no SSH ports resolved -- aborting to prevent lockout."
        log_info "security_reconcile_ufw_rules: aborted (no desired SSH ports)"
        return 1
    fi

    ufw default deny incoming > /dev/null 2>&1 || true
    ufw default allow outgoing > /dev/null 2>&1 || true

    # Track SSH rule add success; only enable UFW if at least one succeeded
    local ssh_rules_added=0
    for port in "${desired_ports[@]}"; do
        if ufw allow "${port}/tcp" comment "ops: SSH managed" > /dev/null 2>&1; then
            ((ssh_rules_added++))
        else
            print_warn "UFW: failed to add SSH rule for port ${port}/tcp"
            log_info "security_reconcile_ufw_rules: ufw allow ${port}/tcp failed"
        fi
    done
    ufw allow 80/tcp  comment "ops: HTTP"  > /dev/null 2>&1 || true
    ufw allow 443/tcp comment "ops: HTTPS" > /dev/null 2>&1 || true

    # Skip enable if no SSH rules added — prevents lockout on fresh UFW enable
    if [[ "$ssh_rules_added" -eq 0 ]]; then
        print_error "UFW reconcile: no SSH rules added -- skipping enable to prevent lockout."
        log_info "security_reconcile_ufw_rules: skipped ufw enable (no SSH rules added)"
        return 1
    fi

    # Read live SSH listen ports from kernel to protect ports sshd actively uses
    local active_ssh_ports=()
    while IFS= read -r port; do
        [[ -n "$port" ]] && active_ssh_ports+=("$port")
    done < <(ss -tlnp 2>/dev/null | awk '/sshd/ {print $4}' | grep -oP ':\K[0-9]+$' | sort -u)

    # Bug A fix: load user-declared extra ports to preserve (OPS_UFW_SKIP_PORTS in ops.conf)
    local skip_ports_csv skip_ports=()
    skip_ports_csv="$(ops_conf_get "ops.conf" "OPS_UFW_SKIP_PORTS" 2>/dev/null || true)"
    if [[ -n "$skip_ports_csv" ]]; then
        IFS=',' read -ra skip_ports <<< "$skip_ports_csv"
    fi

    # Bug G fix: normalize UFW status to bare port numbers.
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
        # Always keep: standard web ports and OPS reserved deny port
        if [[ "$port" == "80" || "$port" == "443" || "$port" == "20128" ]]; then
            continue
        fi

        local keep=0

        # Keep if in desired SSH ports (managed by ops.conf)
        for desired in "${desired_ports[@]}"; do
            [[ "$desired" == "$port" ]] && keep=1 && break
        done

        # Keep if sshd is actively listening on this port (transition / not yet in ops.conf)
        if [[ "$keep" -eq 0 ]]; then
            for active in "${active_ssh_ports[@]}"; do
                if [[ "$active" == "$port" ]]; then
                    keep=1
                    log_info "UFW: preserving active SSH port ${port} (not in ops.conf yet)"
                    break
                fi
            done
        fi

        # Bug A fix (3a): keep if declared in OPS_UFW_SKIP_PORTS by user
        if [[ "$keep" -eq 0 ]]; then
            for skip in "${skip_ports[@]}"; do
                skip="${skip// /}"
                if [[ "$skip" == "$port" ]]; then
                    keep=1
                    log_info "UFW: preserving user-declared port ${port} (OPS_UFW_SKIP_PORTS)"
                    break
                fi
            done
        fi

        # Bug A fix (3b): keep if the UFW rule has NO "ops:" comment.
        # Rules created externally (cloud provider, manual) are never touched.
        if [[ "$keep" -eq 0 ]]; then
            if ! printf '%s\n' "$status_output" \
                    | grep -qE "^[[:space:]]*${port}[^0-9].*ALLOW.*# ops:"; then
                keep=1
                log_info "UFW: preserving non-OPS rule for port ${port} (no 'ops:' comment)"
            fi
        fi

        if [[ "$keep" -eq 0 ]]; then
            ufw delete allow "${port}/tcp" > /dev/null 2>&1 || true
            log_info "UFW: removed stale OPS-managed rule for port ${port}"
        fi
    done

    ufw delete allow 20128/tcp > /dev/null 2>&1 || true
    ufw deny   20128/tcp       > /dev/null 2>&1 || true
    ufw --force enable         > /dev/null 2>&1 || true
    ufw reload                 > /dev/null 2>&1 || true
}


security_write_fail2ban_config() {
    local ssh_ports
    # Detect live SSH ports from ss (more reliable than sshd -T in non-session contexts)
    ssh_ports=$(ss -tlnp 2>/dev/null \
        | awk '/sshd/ {print $4}' \
        | grep -oP ':\K[0-9]+$' \
        | sort -un \
        | paste -sd, - || true)
    # Fallback: use OPS-managed ports from ops.conf
    if [[ -z "$ssh_ports" ]]; then
        ssh_ports=$(security_list_desired_ssh_ports | paste -sd, -)
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

    write_file "$SECURITY_FAIL2BAN_JAIL_OPS" <<EOF_JAIL
# Managed by OPS — do not edit manually.
[DEFAULT]
bantime = 1d
findtime = 10m
maxretry = 3
bantime.increment = true
bantime.maxtime = 2w
backend = systemd

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
    sysctl -p "$SECURITY_SYSCTL_OPS_CONF" >/dev/null 2>&1 || true
}

security_ensure_swap() {
    local desired_size_mb
    desired_size_mb=$(ops_conf_get "ops.conf" "OPS_SWAP_MB" 2>/dev/null || true)
    desired_size_mb="${desired_size_mb:-2048}"

    if swapon --show 2>/dev/null | grep -q "${SECURITY_SWAP_FILE}"; then
        return 0
    fi

    if [[ -f "$SECURITY_SWAP_FILE" ]]; then
        chmod 600 "$SECURITY_SWAP_FILE"
    else
        fallocate -l "${desired_size_mb}M" "$SECURITY_SWAP_FILE" 2>/dev/null || dd if=/dev/zero of="$SECURITY_SWAP_FILE" bs=1M count="$desired_size_mb"
        chmod 600 "$SECURITY_SWAP_FILE"
        mkswap "$SECURITY_SWAP_FILE" >/dev/null 2>&1
    fi

    swapon "$SECURITY_SWAP_FILE" >/dev/null 2>&1 || true
    if ! grep -qF "${SECURITY_SWAP_FILE} none swap sw 0 0" /etc/fstab 2>/dev/null; then
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
    local backup_path="$1"
    local ssh_service
    ssh_service=$(security_detect_ssh_service)

    print_warn "Rollback triggered: opening port 22 first to avoid SSH lockout..."
    ufw allow 22/tcp comment "ops: rollback emergency SSH" > /dev/null 2>&1 || true

    if [[ -n "$backup_path" && -f "$backup_path" ]]; then
        cp "$backup_path" "$SECURITY_SSHD_CONFIG"
        print_warn "Restored SSH config from backup: $backup_path"
    fi

    if sshd -t > /dev/null 2>&1; then
        service_restart "$ssh_service"
        print_warn "Rollback complete: SSH service restarted."
        # Bug F fix: reconcile UFW back to pre-hardening state and remove the emergency
        # port-22 rule. ops.conf still reflects the old SSH port since
        # security_ensure_ssh_transition_ports had not yet run when rollback triggered.
        log_info "Rollback: reconciling UFW to remove emergency rule..."
        security_reconcile_ufw_rules || true
    else
        print_error "Rollback restored config still fails sshd -t. Manual recovery required immediately."
    fi
}


security_apply_sshd_hardening() {
    local new_port="$1"
    local password_auth="$2"
    local old_port
    local ssh_service
    local backup_path

    old_port=$(security_get_current_ssh_port)
    ssh_service=$(security_detect_ssh_service)

    backup_path=$(backup_file "$SECURITY_SSHD_CONFIG")

    security_reconcile_sshd_main_config
    # Bug D fix: strip cloud-init SSH overrides BEFORE writing our include file and
    # running sshd -t, so a single service_restart applies all changes atomically.
    security_strip_cloud_init_overrides
    security_write_sshd_hardening_include "$new_port" "$password_auth" "$old_port"

    if ! sshd -t > /dev/null 2>&1; then
        print_error "sshd -t failed after update. Starting rollback."
        security_rollback_sshd_config "$backup_path"
        return 1
    fi

    security_ensure_ssh_transition_ports "$old_port" "$new_port"
    service_restart "$ssh_service"

    ops_conf_set "ops.conf" "OPS_SSH_PORT" "$new_port"
    ops_conf_set "ops.conf" "OPS_SSH_ROOT_LOGIN" "no"
    ops_conf_set "ops.conf" "OPS_SSH_PASSWORD_AUTH" "$password_auth"
    ops_conf_set "ops.conf" "OPS_RUNTIME_USER" "$(security_get_runtime_user)"

    print_ok "SSH hardening applied successfully."
    print_warn "Transition safety: keep only managed transition ports until login is verified on port $new_port."
    return 0
}


# ── Public menu entry ─────────────────────────────────────────
menu_security() {
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
        echo "  0) Back"
        echo ""
        read -r -p "Select: " choice
        case "$choice" in
            1) security_harden_ssh            ;;
            2) security_configure_ufw         ;;
            3) security_setup_fail2ban        ;;
            4) security_status                ;;
            5) security_change_ssh_port       ;;
            6) security_finalize_ssh_transition ;;
            7) security_apply_host_baseline   ;;
            8) security_manage_ssh_keys       ;;
            9) security_manage_tcp_forwarding ;;
            0) return                         ;;
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
    security_validate_ssh_port "$new_port" || return 1

    # Fix B: Guard -- only offer to disable PasswordAuthentication if SSH key is present.
    local admin_user
    admin_user="$(security_get_admin_user)"
    if _security_has_authorized_keys "$admin_user"; then
        if prompt_confirm "Disable PasswordAuthentication (recommended if SSH keys are ready)?"; then
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

    security_reconcile_ufw_rules

    print_ok "UFW baseline reconciled."
    ufw status verbose
}

security_setup_fail2ban() {
    print_section "fail2ban Setup"
    security_require_root || return 1

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        apt_install fail2ban
    fi

    backup_file "$SECURITY_FAIL2BAN_JAIL_LOCAL" >/dev/null 2>&1 || true
    security_write_fail2ban_config

    service_enable fail2ban
    service_restart fail2ban

    print_ok "fail2ban configured for OPS-managed SSH and nginx baseline."
    fail2ban-client status
}

security_status() {
    print_section "Security Status"
    local ssh_port root_login password_auth transition_port runtime_user tcp_fwd_live tcp_fwd_conf

    ssh_port=$(security_get_current_ssh_port)
    root_login=$(sshd -T 2>/dev/null | awk '/^permitrootlogin /{print $2; exit}' || true)
    password_auth=$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2; exit}' || true)
    transition_port=$(security_get_transition_port)
    runtime_user=$(security_get_runtime_user)
    tcp_fwd_live=$(sshd -T 2>/dev/null | awk '/^allowtcpforwarding /{print $2; exit}' || true)
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
        ufw status verbose || true
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

    local current_port new_port current_password_auth
    current_port=$(security_get_current_ssh_port)

    prompt_input "Enter new SSH port" "$current_port"
    new_port="$REPLY"
    security_validate_ssh_port "$new_port" || return 1

    current_password_auth=$(ops_conf_get "ops.conf" "OPS_SSH_PASSWORD_AUTH" 2>/dev/null || true)
    if [[ "$current_password_auth" != "yes" && "$current_password_auth" != "no" ]]; then
        current_password_auth="no"
    fi

    security_apply_sshd_hardening "$new_port" "$current_password_auth" || return 1

    print_warn "After login test succeeds in a new SSH session on the new port, run 'Finalize SSH transition (close old SSH port)'."
    security_status
}

security_finalize_ssh_transition() {
    print_section "Finalize SSH Transition"
    security_require_root || return 1

    local new_port old_port admin_user server_ip ssh_service
    new_port=$(security_get_locked_ssh_port)
    old_port=$(security_get_transition_port)
    ssh_service=$(security_detect_ssh_service)

    if [[ -z "$old_port" || "$old_port" == "$new_port" ]]; then
        print_warn "No SSH transition port is currently recorded."
        return 0
    fi

    print_warn "Only continue after you confirmed SSH login works on port ${new_port}."
    if ! prompt_confirm "Finalize SSH transition and remove old port ${old_port}?"; then
        print_warn "Cancelled."
        return 0
    fi

    # Bug E fix: use parameter expansion to catch empty-string return (exit 0 bypasses || fallback)
    local _final_pw_auth
    _final_pw_auth="$(ops_conf_get "ops.conf" "OPS_SSH_PASSWORD_AUTH" 2>/dev/null || true)"
    _final_pw_auth="${_final_pw_auth:-no}"
    security_write_sshd_hardening_include "$new_port" "$_final_pw_auth"
    if ! sshd -t >/dev/null 2>&1; then
        print_error "sshd -t failed while finalizing transition."
        return 1
    fi

    service_restart "$ssh_service"
    ops_conf_set "ops.conf" "OPS_SSH_TRANSITION_PORT" ""
    security_reconcile_ufw_rules

    if command -v fail2ban-client >/dev/null 2>&1; then
        security_write_fail2ban_config
        service_restart fail2ban >/dev/null 2>&1 || true
    fi

    admin_user=$(security_get_admin_user)
    server_ip=$(security_get_server_ip)

    print_ok "Old SSH port ${old_port} removed from managed config and firewall."
    echo "You MUST now use: ssh -p ${new_port} ${admin_user}@${server_ip}"
    ufw status verbose
}

security_apply_host_baseline() {
    print_section "OPS Host Security Baseline"
    security_require_root || return 1

    security_normalize_script_permissions
    security_apply_sysctl_baseline
    security_ensure_swap
    security_reconcile_ufw_rules

    # Ensure fail2ban is installed before attempting to configure it
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        log_info "security_apply_host_baseline: fail2ban not found — installing..."
        apt_install fail2ban
    fi

    if command -v fail2ban-client >/dev/null 2>&1; then
        security_write_fail2ban_config
        service_enable fail2ban >/dev/null 2>&1 || true
        service_restart fail2ban >/dev/null 2>&1 || true
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
        if [[ -f "$auth_keys" ]] && \
           grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp|sk-ssh) ' "$auth_keys" 2>/dev/null; then
            echo "  Current authorized keys:"
            local n=1
            while IFS= read -r line; do
                [[ "$line" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp|sk-ssh)[[:space:]] ]] || continue
                local ktype kdata kcomment
                ktype=$(printf '%s' "$line" | awk '{print $1}')
                kdata=$(printf '%s' "$line" | awk '{print $2}')
                kcomment=$(printf '%s' "$line" | awk '{$1=$2=""; gsub(/^[ \t]+/,""); print}')
                printf "    %d) %-20s ...%s  %s\n" "$n" "$ktype" "${kdata: -20}" "$kcomment"
                ((n++))
            done < "$auth_keys"
            key_count=$((n - 1))
        else
            print_warn "No SSH public keys currently authorized."
        fi

        echo ""
        echo "  1) Add new SSH public key"
        echo "  2) Remove a key by number"
        echo "  3) Enable PasswordAuthentication (emergency restore)"
        echo "  4) Disable PasswordAuthentication (requires at least 1 key above)"
        echo "  0) Back"
        echo ""
        read -r -p "  Select: " subchoice

        case "$subchoice" in
            1)
                echo ""
                echo "  Paste your SSH public key below (one line, then Enter):"
                read -r -p "  > " new_key
                if [[ -z "$new_key" ]]; then
                    print_warn "Empty input -- cancelled."
                elif ! printf '%s' "$new_key" | \
                     grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp|sk-ssh) [A-Za-z0-9+/=]'; then
                    print_error "Input does not look like a valid SSH public key. Not added."
                else
                    mkdir -p "${admin_home}/.ssh"
                    chmod 700 "${admin_home}/.ssh"
                    printf '%s\n' "$new_key" >> "$auth_keys"
                    chmod 600 "$auth_keys"
                    chown -R "${admin_user}:${admin_user}" "${admin_home}/.ssh"
                    print_ok "Key added to ${auth_keys}."
                fi
                ;;
            2)
                if [[ ! -f "$auth_keys" ]] || (( key_count == 0 )); then
                    print_warn "No authorized_keys file or no valid keys found."
                    continue
                fi
                echo ""
                read -r -p "  Enter key number to remove (1-${key_count}): " del_num
                if ! [[ "$del_num" =~ ^[0-9]+$ ]] || \
                   (( del_num < 1 || del_num > key_count )); then
                    print_warn "Invalid number. Must be between 1 and ${key_count}."
                    continue
                fi
                if ! prompt_confirm "Remove key #${del_num}?"; then
                    print_warn "Cancelled."
                    continue
                fi
                local tmp_del counted=0
                tmp_del=$(mktemp)
                while IFS= read -r line; do
                    if printf '%s' "$line" | \
                       grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp|sk-ssh) '; then
                        ((counted++))
                        [[ "$counted" -eq "$del_num" ]] && continue
                    fi
                    printf '%s\n' "$line"
                done < "$auth_keys" > "$tmp_del"
                mv "$tmp_del" "$auth_keys"
                chmod 600 "$auth_keys"
                chown "${admin_user}:${admin_user}" "$auth_keys"
                print_ok "Key #${del_num} removed."
                ;;
            3)
                print_warn "WARNING: Enabling PasswordAuthentication allows password-based SSH login."
                if prompt_confirm "Enable PasswordAuthentication?"; then
                    local pw_port ssh_svc
                    pw_port="$(security_get_locked_ssh_port)"
                    ssh_svc="$(security_detect_ssh_service)"
                    security_write_sshd_hardening_include "$pw_port" "yes"
                    systemctl reload "$ssh_svc" >/dev/null 2>&1 || true
                    ops_conf_set "ops.conf" "OPS_SSH_PASSWORD_AUTH" "yes"
                    print_ok "PasswordAuthentication enabled. SSH reloaded."
                fi
                ;;
            4)
                if ! _security_has_authorized_keys "$admin_user"; then
                    print_error "No SSH key found for '${admin_user}'."
                    print_error "Add a key first (option 1) to avoid lockout."
                else
                    print_warn "WARNING: Only SSH key logins will work after this change."
                    if prompt_confirm "Disable PasswordAuthentication?"; then
                        local lock_port ssh_svc
                        lock_port="$(security_get_locked_ssh_port)"
                        ssh_svc="$(security_detect_ssh_service)"
                        security_write_sshd_hardening_include "$lock_port" "no"
                        systemctl reload "$ssh_svc" >/dev/null 2>&1 || true
                        ops_conf_set "ops.conf" "OPS_SSH_PASSWORD_AUTH" "no"
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
    read -r -p "  Select: " subchoice
    case "$subchoice" in
        1)
            if [[ "$current" == "yes" ]]; then
                print_ok "TCP Forwarding is already enabled."
                return 0
            fi
            print_warn "Enabling AllowTcpForwarding reduces SSH hardening (tunnel / port-scan risk)."
            if prompt_confirm "Enable TCP Forwarding?"; then
                ops_conf_set "ops.conf" "OPS_SSH_TCP_FORWARDING" "yes"
                security_write_sshd_hardening_include "$locked_port" "$password_auth" "$transition_port"
                if sshd -t >/dev/null 2>&1; then
                    systemctl reload "$ssh_svc" >/dev/null 2>&1 || true
                    print_ok "TCP Forwarding enabled. SSH reloaded."
                    print_warn "Reconnect VSCode SSH Remote to use the new setting."
                else
                    print_error "sshd -t validation failed. Reverting ops.conf change."
                    ops_conf_set "ops.conf" "OPS_SSH_TCP_FORWARDING" "no"
                    security_write_sshd_hardening_include "$locked_port" "$password_auth" "$transition_port"
                fi
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
                ops_conf_set "ops.conf" "OPS_SSH_TCP_FORWARDING" "no"
                security_write_sshd_hardening_include "$locked_port" "$password_auth" "$transition_port"
                if sshd -t >/dev/null 2>&1; then
                    systemctl reload "$ssh_svc" >/dev/null 2>&1 || true
                    print_ok "TCP Forwarding disabled. SSH reloaded."
                else
                    print_error "sshd -t validation failed. Reverting ops.conf change."
                    ops_conf_set "ops.conf" "OPS_SSH_TCP_FORWARDING" "yes"
                    security_write_sshd_hardening_include "$locked_port" "$password_auth" "$transition_port"
                fi
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
