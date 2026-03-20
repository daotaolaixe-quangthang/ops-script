#!/usr/bin/env bash
# ============================================================
# ops/bin/ops-ssh-finalize.sh
# Purpose:  Automatically close the SSH transition port (port 22)
#           after admin user successfully logs in on the new SSH port.
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# Called by the login hook in ~/.bash_profile via:
#   sudo /opt/ops/bin/ops-ssh-finalize.sh
#
# Prerequisites (set up by ops-setup.sh):
#   /etc/sudoers.d/99-ops-ssh-finalize  — NOPASSWD rule for admin user
#   /etc/ops/ops.conf                   — OPS_SSH_PORT + OPS_SSH_TRANSITION_PORT
# ============================================================
set -euo pipefail
IFS=$'\n\t'

OPS_CONF="/etc/ops/ops.conf"
OPS_LOG="/var/log/ops/ops.log"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_OPS_INCLUDE="/etc/ssh/sshd_config.d/99-ops-hardening.conf"

# ── helpers ──────────────────────────────────────────────────
_log() { local ts; ts=$(date '+%F %T'); echo "[INFO]  ${ts} ops-ssh-finalize: $*" | tee -a "$OPS_LOG" 2>/dev/null || true; }
_warn() { local ts; ts=$(date '+%F %T'); echo "[WARN]  ${ts} ops-ssh-finalize: $*" | tee -a "$OPS_LOG" 2>/dev/null || true; }
_err()  { local ts; ts=$(date '+%F %T'); echo "[ERROR] ${ts} ops-ssh-finalize: $*" | tee -a "$OPS_LOG" 2>/dev/null || true; }

conf_get() { grep "^${1}=" "$OPS_CONF" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"' || true; }
conf_clear() {
    local key="$1"
    local tmp
    tmp=$(mktemp)
    sed "s|^${key}=.*|${key}=\"\"|" "$OPS_CONF" > "$tmp"
    mv "$tmp" "$OPS_CONF"
}

detect_ssh_service() {
    if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
        echo "ssh"
    else
        echo "sshd"
    fi
}

# ── main ─────────────────────────────────────────────────────
main() {
    if [[ "$(id -u)" -ne 0 ]]; then
        _err "Must run as root (via sudo). Aborting."
        exit 1
    fi

    if [[ ! -f "$OPS_CONF" ]]; then
        _err "ops.conf not found at ${OPS_CONF}. Aborting."
        exit 1
    fi

    local locked_port transition_port
    locked_port=$(conf_get "OPS_SSH_PORT")
    transition_port=$(conf_get "OPS_SSH_TRANSITION_PORT")

    # Idempotency guard: nothing to do if transition port is already cleared
    if [[ -z "$transition_port" ]]; then
        _log "No transition port recorded — already finalized. Nothing to do."
        exit 0
    fi

    if [[ -z "$locked_port" ]]; then
        _err "OPS_SSH_PORT is empty in ops.conf. Cannot finalize safely. Aborting."
        exit 1
    fi

    if [[ "$transition_port" == "$locked_port" ]]; then
        _log "Transition port equals locked port (${locked_port}) — clearing and exiting."
        conf_clear "OPS_SSH_TRANSITION_PORT"
        exit 0
    fi

    _log "Finalizing SSH transition: removing port ${transition_port}, keeping port ${locked_port}."

    # ── 1. Remove transition port from sshd_config ────────────
    local sshd_bak=""
    if grep -qE "^[[:space:]]*Port[[:space:]]+${transition_port}$" "$SSHD_CONFIG" 2>/dev/null; then
        sshd_bak="${SSHD_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$SSHD_CONFIG" "$sshd_bak"
        sed -i -E "/^[[:space:]]*Port[[:space:]]+${transition_port}$/d" "$SSHD_CONFIG"
        _log "Removed 'Port ${transition_port}' from ${SSHD_CONFIG} (backup: ${sshd_bak})"
    else
        _log "Port ${transition_port} not found in ${SSHD_CONFIG} — already removed or not set."
    fi

    # ── 2. Write/update 99-ops-hardening.conf ─────────────────
    # Preserve existing directives (if file exists), only update Port lines
    local inc_bak=""
    if [[ -f "$SSHD_OPS_INCLUDE" ]]; then
        inc_bak="${SSHD_OPS_INCLUDE}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$SSHD_OPS_INCLUDE" "$inc_bak"
        # Remove all Port lines, then append the single locked port
        sed -i -E '/^[[:space:]]*Port[[:space:]]+[0-9]+/d' "$SSHD_OPS_INCLUDE"
        echo "Port ${locked_port}" >> "$SSHD_OPS_INCLUDE"
        _log "Updated ${SSHD_OPS_INCLUDE}: only Port ${locked_port} remains."
    else
        # Create a minimal hardening file if it doesn't exist
        mkdir -p "$(dirname "$SSHD_OPS_INCLUDE")"
        cat > "$SSHD_OPS_INCLUDE" << EOF
# Managed by OPS — do not edit manually.
PermitRootLogin no
PasswordAuthentication yes
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
AllowStreamLocalForwarding no
PermitTunnel no
ClientAliveInterval 300
ClientAliveCountMax 2
Port ${locked_port}
EOF
        chmod 644 "$SSHD_OPS_INCLUDE"
        _log "Created ${SSHD_OPS_INCLUDE} with Port ${locked_port}."
    fi

    # ── 3. Validate sshd config ───────────────────────────────
    if ! sshd -t > /dev/null 2>&1; then
        _err "sshd -t failed after removing port ${transition_port}. Rolling back both files."
        # Restore BOTH sshd_config AND the hardening include to avoid inconsistency
        if [[ -n "$sshd_bak" && -f "$sshd_bak" ]]; then
            cp "$sshd_bak" "$SSHD_CONFIG"
            _warn "Restored ${SSHD_CONFIG} from ${sshd_bak}."
        fi
        if [[ -n "$inc_bak" && -f "$inc_bak" ]]; then
            cp "$inc_bak" "$SSHD_OPS_INCLUDE"
            _warn "Restored ${SSHD_OPS_INCLUDE} from ${inc_bak}."
        fi
        exit 1
    fi

    # ── 4. Reload sshd ────────────────────────────────────────
    local ssh_service
    ssh_service=$(detect_ssh_service)
    if systemctl reload "$ssh_service" > /dev/null 2>&1; then
        _log "sshd reloaded — now listening only on port ${locked_port}."
    else
        _err "Failed to reload sshd. Manual reload required: systemctl reload ${ssh_service}"
        exit 1
    fi

    # ── 5. Update UFW: remove transition port rule ─────────────
    if command -v ufw > /dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -qE "^${transition_port}/tcp"; then
            ufw delete allow "${transition_port}/tcp" > /dev/null 2>&1 || true
            ufw reload > /dev/null 2>&1 || true
            _log "UFW: removed rule for port ${transition_port}/tcp."
        else
            _log "UFW: no rule found for port ${transition_port}/tcp — skipping."
        fi
    else
        _warn "ufw not installed — skipping firewall update."
    fi

    # ── 6. Clear transition port from ops.conf ─────────────────
    conf_clear "OPS_SSH_TRANSITION_PORT"
    _log "Cleared OPS_SSH_TRANSITION_PORT from ops.conf."

    echo ""
    echo "  [OPS] ✓ SSH transition finalized."
    echo "  [OPS] ✓ Port ${transition_port} is now closed."
    echo "  [OPS] ✓ Use: ssh -p ${locked_port} <user>@<server>"
    echo ""
}

main "$@"
