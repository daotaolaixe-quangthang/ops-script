#!/usr/bin/env bash
# ============================================================
# ops/install/ops-install.sh
# Purpose:  Bootstrap installer — curl -sO … && bash entry point
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# Installer URL (chốt):
#   https://raw.githubusercontent.com/daotaolaixe-quangthang/ops-script/main/install/ops-install.sh
#
# Usage (from VPS, as root — one command):
#   bash <(curl -fsSL https://raw.githubusercontent.com/daotaolaixe-quangthang/ops-script/main/install/ops-install.sh)
#
# (Process substitution keeps stdin as TTY so interactive prompts work correctly.)

# This script must remain small and auditable.
# Complex logic delegates to core modules and ops-setup.sh.
# ============================================================
set -euo pipefail
IFS=$'\n\t'

# ── Constants ─────────────────────────────────────────────────
readonly OPS_INSTALL_DIR="/opt/ops"
readonly OPS_CONFIG_DIR="/etc/ops"
readonly OPS_GITHUB_REPO="daotaolaixe-quangthang/ops-script"
readonly OPS_GITHUB_BRANCH="main"
readonly OPS_VERSION="0.1.0"
readonly OPS_SOURCE_SUBDIR="ops"

# Colours (inline — do not depend on core/ui.sh before install)
RED=$'\033[0;31m'
GRN=$'\033[0;32m'
YLW=$'\033[1;33m'
CYN=$'\033[0;36m'
BLD=$'\033[1m'
RST=$'\033[0m'

die()  { echo -e "${RED}[ERROR]${RST} $*" >&2; exit 1; }
info() { echo -e "${GRN}[INFO]${RST}  $*"; }
warn() { echo -e "${YLW}[WARN]${RST}  $*"; }
ok()   { echo -e "${GRN}[OK]${RST}    $*"; }

SSH_CURRENT_PORTS=()
SSH_BOOTSTRAP_PORTS=()
SSH_BOOTSTRAP_MODE="fresh"
OPS_SSH_STATE_PERSIST="no"
OPS_MANAGED_SSH_PORT=""
OPS_MANAGED_SSH_TRANSITION_PORT=""
OPS_PRE_ACTIVATION_SNAPSHOT_DIR=""
OPS_PRE_ACTIVATION_ROLLBACK_ARMED="no"
OPS_BOOTSTRAP_USER_CREATED="no"
OPS_BOOTSTRAP_SUDO_ADDED="no"
OPS_BOOTSTRAP_ADMIN_SSH_PATH=""
OPS_INSTALL_PREVIOUS_BACKUP=""
OPS_POST_DEPLOY_SNAPSHOT_DIR=""
OPS_INSTALL_STAGE_DIR=""
OPS_INSTALL_SOURCE_ROOT=""
OPS_INSTALL_SOURCE_OPS=""
OPS_INSTALL_CANDIDATE_ROOT=""
OPS_SHARED_HELPERS_LOADED="no"

port_list_contains() {
    local needle="$1"
    shift || true
    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

format_port_list() {
    local joined=""
    local item
    for item in "$@"; do
        [[ -n "$item" ]] || continue
        if [[ -n "$joined" ]]; then
            joined+=" "
        fi
        joined+="$item"
    done
    printf '%s' "$joined"
}

installer_authorized_key_line_is_valid() {
    local line="${1:-}"

    [[ -n "$line" ]] || return 1
    [[ "$line" =~ ^[[:space:]]*# ]] && return 1

    grep -Eq '(^|[[:space:]])(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|sk-ecdsa-sha2-nistp256@openssh\.com|sk-ssh-ed25519@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]]|$)' <<< "$line"
}

installer_has_authorized_keys() {
    local auth_keys="$1"
    local line

    [[ -f "$auth_keys" ]] || return 1

    while IFS= read -r line || [[ -n "$line" ]]; do
        if installer_authorized_key_line_is_valid "$line"; then
            return 0
        fi
    done < "$auth_keys"

    return 1
}

cleanup_install_artifacts() {
    if [[ -n "${OPS_INSTALL_STAGE_DIR:-}" && -d "${OPS_INSTALL_STAGE_DIR}" ]]; then
        rm -rf "${OPS_INSTALL_STAGE_DIR}"
    fi
    OPS_INSTALL_STAGE_DIR=""
    OPS_INSTALL_SOURCE_ROOT=""
    OPS_INSTALL_SOURCE_OPS=""

    if [[ -n "${OPS_INSTALL_CANDIDATE_ROOT:-}" && -e "${OPS_INSTALL_CANDIDATE_ROOT}" ]]; then
        rm -rf "${OPS_INSTALL_CANDIDATE_ROOT}"
    fi
    OPS_INSTALL_CANDIDATE_ROOT=""
}

prepare_install_source_tree() {
    [[ -n "${OPS_INSTALL_SOURCE_ROOT:-}" && -d "${OPS_INSTALL_SOURCE_ROOT}" ]] && return 0

    local tarball_url="https://github.com/${OPS_GITHUB_REPO}/archive/refs/heads/${OPS_GITHUB_BRANCH}.tar.gz"
    local tarball extract_dir size

    OPS_INSTALL_STAGE_DIR=$(mktemp -d /tmp/ops-install-XXXXXX)
    tarball="${OPS_INSTALL_STAGE_DIR}/ops-source.tar.gz"
    extract_dir="${OPS_INSTALL_STAGE_DIR}/extracted"

    info "Downloading source tarball from GitHub..."
    if ! curl -fsSL --max-time 120 --connect-timeout 15 -o "$tarball" "$tarball_url" 2>&1; then
        cleanup_install_artifacts
        die "Download failed. Check network connectivity and try again."
    fi
    size=$(du -sh "$tarball" 2>/dev/null | cut -f1)
    ok "Downloaded (${size})"

    if ! tar -tzf "$tarball" >/dev/null 2>&1; then
        cleanup_install_artifacts
        die "Downloaded file is not a valid tar.gz archive. Aborting."
    fi

    mkdir -p "$extract_dir"
    tar -xzf "$tarball" -C "$extract_dir" 2>/dev/null

    OPS_INSTALL_SOURCE_ROOT=$(find "$extract_dir" -maxdepth 1 -type d -name 'ops-script-*' | head -1)
    if [[ -z "$OPS_INSTALL_SOURCE_ROOT" ]]; then
        cleanup_install_artifacts
        die "Unexpected archive structure — expected ops-script-*/ inside tarball."
    fi

    OPS_INSTALL_SOURCE_OPS="${OPS_INSTALL_SOURCE_ROOT}/${OPS_SOURCE_SUBDIR}"
    if [[ ! -d "${OPS_INSTALL_SOURCE_OPS}/bin" ]]; then
        cleanup_install_artifacts
        die "Missing ${OPS_SOURCE_SUBDIR}/bin/ inside tarball. Archive may be corrupted."
    fi

    if [[ "${OPS_SHARED_HELPERS_LOADED:-no}" != "yes" ]]; then
        # shellcheck source=/dev/null
        source "${OPS_INSTALL_SOURCE_OPS}/core/utils.sh"
        OPS_SHARED_HELPERS_LOADED="yes"
    fi
}

prepare_pre_activation_rollback_state() {
    [[ -z "${OPS_PRE_ACTIVATION_SNAPSHOT_DIR:-}" ]] || return 0

    OPS_PRE_ACTIVATION_SNAPSHOT_DIR=$(mktemp -d /tmp/ops-pre-activation-XXXXXX)
    snapshot_path_state "/etc/ssh/sshd_config" "$OPS_PRE_ACTIVATION_SNAPSHOT_DIR" "sshd-config"
    snapshot_path_state "/etc/ssh/sshd_config.d" "$OPS_PRE_ACTIVATION_SNAPSHOT_DIR" "sshd-include-dir"
    snapshot_ufw_state "$OPS_PRE_ACTIVATION_SNAPSHOT_DIR"
    OPS_PRE_ACTIVATION_ROLLBACK_ARMED="yes"
}

prepare_admin_ssh_rollback_state() {
    local admin_home="$1"

    [[ "$OPS_BOOTSTRAP_USER_CREATED" == "yes" ]] && return 0
    [[ -n "${OPS_PRE_ACTIVATION_SNAPSHOT_DIR:-}" ]] || return 0
    [[ -n "$admin_home" && -d "$admin_home" ]] || return 0
    [[ -n "${OPS_BOOTSTRAP_ADMIN_SSH_PATH:-}" ]] && return 0

    OPS_BOOTSTRAP_ADMIN_SSH_PATH="${admin_home}/.ssh"
    snapshot_path_state "$OPS_BOOTSTRAP_ADMIN_SSH_PATH" "$OPS_PRE_ACTIVATION_SNAPSHOT_DIR" "admin-ssh-dir"
}

cleanup_pre_activation_snapshots() {
    if [[ -n "${OPS_PRE_ACTIVATION_SNAPSHOT_DIR:-}" && -d "${OPS_PRE_ACTIVATION_SNAPSHOT_DIR}" ]]; then
        rm -rf "${OPS_PRE_ACTIVATION_SNAPSHOT_DIR}"
    fi
    OPS_PRE_ACTIVATION_SNAPSHOT_DIR=""
    OPS_PRE_ACTIVATION_ROLLBACK_ARMED="no"
    OPS_BOOTSTRAP_USER_CREATED="no"
    OPS_BOOTSTRAP_SUDO_ADDED="no"
    OPS_BOOTSTRAP_ADMIN_SSH_PATH=""
}

rollback_pre_activation_failure() {
    [[ "${OPS_PRE_ACTIVATION_ROLLBACK_ARMED:-no}" == "yes" ]] || return 0

    warn "Installer failed before activation completed. Restoring previous SSH, firewall, and admin bootstrap state."

    local ssh_service
    ssh_service=$(detect_ssh_service)

    restore_path_snapshot "/etc/ssh/sshd_config" "$OPS_PRE_ACTIVATION_SNAPSHOT_DIR" "sshd-config"
    restore_path_snapshot "/etc/ssh/sshd_config.d" "$OPS_PRE_ACTIVATION_SNAPSHOT_DIR" "sshd-include-dir"

    if sshd -t >/dev/null 2>&1; then
        systemctl reload "$ssh_service" >/dev/null 2>&1 || true
    else
        warn "Restored SSH config still fails validation. Manual SSH recovery may be required."
    fi

    restore_ufw_state "$OPS_PRE_ACTIVATION_SNAPSHOT_DIR"

    if [[ "$OPS_BOOTSTRAP_USER_CREATED" == "yes" && -n "${ADMIN_USER:-}" ]] && id "$ADMIN_USER" >/dev/null 2>&1; then
        userdel -r "$ADMIN_USER" >/dev/null 2>&1 || userdel "$ADMIN_USER" >/dev/null 2>&1 || true
    else
        if [[ -n "${OPS_BOOTSTRAP_ADMIN_SSH_PATH:-}" ]]; then
            restore_path_snapshot "$OPS_BOOTSTRAP_ADMIN_SSH_PATH" "$OPS_PRE_ACTIVATION_SNAPSHOT_DIR" "admin-ssh-dir"
        fi
        if [[ "$OPS_BOOTSTRAP_SUDO_ADDED" == "yes" && -n "${ADMIN_USER:-}" ]] && id "$ADMIN_USER" >/dev/null 2>&1; then
            gpasswd -d "$ADMIN_USER" sudo >/dev/null 2>&1 || deluser "$ADMIN_USER" sudo >/dev/null 2>&1 || true
        fi
    fi

    cleanup_pre_activation_snapshots
}

installer_exit_trap() {
    local exit_code=$?
    if [[ "$exit_code" -ne 0 && "${OPS_PRE_ACTIVATION_ROLLBACK_ARMED:-no}" == "yes" ]]; then
        rollback_pre_activation_failure || true
    fi
    cleanup_install_artifacts || true
}

# ── 1. Preflight checks ───────────────────────────────────────

preflight_check() {
    # Must be run as root
    if [[ "$EUID" -ne 0 ]]; then
        die "ops-install.sh must be run as root (e.g. sudo bash ops-install.sh)."
    fi

    # OS check: Ubuntu 22.04 or 24.04 only
    if [[ ! -f /etc/os-release ]]; then
        die "Cannot detect OS (/etc/os-release missing). Ubuntu 22.04/24.04 required."
    fi

    # shellcheck source=/dev/null
    source /etc/os-release

    local os_id="${ID:-unknown}"
    local os_ver="${VERSION_ID:-unknown}"

    if [[ "$os_id" != "ubuntu" ]]; then
        die "Unsupported OS: ${os_id} ${os_ver}. Only Ubuntu 22.04 / 24.04 is supported."
    fi

    if [[ "$os_ver" != "22.04" && "$os_ver" != "24.04" ]]; then
        die "Unsupported Ubuntu version: ${os_ver}. Only Ubuntu 22.04 / 24.04 is supported."
    fi

    if ! command -v systemctl > /dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
        die "Unsupported environment: systemd is required. OPS supports Ubuntu 22.04/24.04 with systemd only."
    fi

    ok "OS check passed: Ubuntu ${os_ver}"
}

# ── 2. Dependency check ───────────────────────────────────────

ensure_deps() {
    info "Checking required dependencies..."

    local -A cmd_pkg_map=(
        [curl]="curl"
        [tar]="tar"
        [awk]="gawk"
        [nproc]="coreutils"
        [df]="coreutils"
        [ss]="iproute2"
        [rsync]="rsync"
    )
    local missing_cmds=()
    local missing_pkgs=()
    local cmd pkg

    for cmd in curl tar awk nproc df ss rsync; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_cmds+=("$cmd")
            pkg="${cmd_pkg_map[$cmd]}"
            if [[ -n "$pkg" ]] && ! port_list_contains "$pkg" "${missing_pkgs[@]}"; then
                missing_pkgs+=("$pkg")
            fi
        fi
    done

    if (( ${#missing_pkgs[@]} > 0 )); then
        warn "Missing commands: ${missing_cmds[*]} — installing packages: ${missing_pkgs[*]}"
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing_pkgs[@]}"
    fi
    ok "Dependencies ready."
}

# ── 3. VPS resource detection & tier calculation ──────────────

detect_vps_info() {
    local disk_total disk_avail

    RAM_MB=$(awk '/MemTotal/ { printf "%d", $2/1024 }' /proc/meminfo)
    CPU_CORES=$(nproc)
    IFS=' ' read -r disk_total disk_avail < <(df -BG / | awk 'NR==2 { gsub("G","",$2); gsub("G","",$4); print $2, $4 }')
    DISK_GB="$disk_total"
    DISK_AVAIL_GB="$disk_avail"
    export RAM_MB CPU_CORES DISK_GB DISK_AVAIL_GB
}

compute_tier() {
    detect_vps_info

    if   (( RAM_MB < 1500 ));              then OPS_TIER="S"
    elif (( RAM_MB >= 1500 && RAM_MB < 5000 )); then OPS_TIER="M"
    else                                        OPS_TIER="L"
    fi
    export OPS_TIER

    case "$OPS_TIER" in
        S) TIER_SITES="1-2";   TIER_USERS="10-50"  ;;
        M) TIER_SITES="3-6";   TIER_USERS="50-200" ;;
        L) TIER_SITES="6+";    TIER_USERS="200+"   ;;
    esac
    export TIER_SITES TIER_USERS
}

print_vps_summary() {
    echo ""
    echo -e "${CYN}${BLD}━━━ VPS Resources ━━━${RST}"
    echo -e "  RAM:       ${RAM_MB}MB"
    echo -e "  CPUs:      ${CPU_CORES} core(s)"
    echo -e "  Disk:      ${DISK_GB}GB total, ${DISK_AVAIL_GB}GB available"
    echo -e "  OPS Tier:  ${BLD}${OPS_TIER}${RST}  (sites: ${TIER_SITES}, concurrent users/site: ~${TIER_USERS})"
    echo ""
}

# ── 4. SSH port configuration ─────────────────────────────────

# detect_ssh_state: derive live SSH ports conservatively.
# Outputs:
#   SSH_BOOTSTRAP_MODE=fresh|managed|ambiguous
#   SSH_CURRENT_PORTS=( ... )
#   SSH_BOOTSTRAP_PORTS=( ... )  # ports that must stay allowed during bootstrap
#   OPS_MANAGED_SSH_PORT / OPS_MANAGED_SSH_TRANSITION_PORT when state is safe to persist
detect_ssh_state() {
    local sshd_conf="/etc/ssh/sshd_config"
    local existing_locked_port=""
    local existing_transition_port=""
    local non22_ports=()
    local sshd_t_out port_source=""
    local has_port_22="no"

    SSH_CURRENT_PORTS=()
    SSH_BOOTSTRAP_PORTS=()
    SSH_BOOTSTRAP_MODE="fresh"
    OPS_SSH_STATE_PERSIST="no"
    OPS_MANAGED_SSH_PORT=""
    OPS_MANAGED_SSH_TRANSITION_PORT=""

    if [[ -f "${OPS_CONFIG_DIR}/ops.conf" ]]; then
        existing_locked_port=$(grep '^OPS_SSH_PORT=' "${OPS_CONFIG_DIR}/ops.conf" 2>/dev/null | head -n1 | cut -d= -f2- | sed 's/^"//; s/"$//' || true)
        existing_transition_port=$(grep '^OPS_SSH_TRANSITION_PORT=' "${OPS_CONFIG_DIR}/ops.conf" 2>/dev/null | head -n1 | cut -d= -f2- | sed 's/^"//; s/"$//' || true)
    fi

    # F-09: Use sshd -T (merged effective config) as primary detection.
    sshd_t_out=$(sshd -T 2>/dev/null || true)
    if [[ -n "$sshd_t_out" ]]; then
        port_source=$(printf '%s\n' "$sshd_t_out" | awk '/^port / {print $2}')
    elif [[ -f "$sshd_conf" ]]; then
        port_source=$(grep -E '^[[:space:]]*Port[[:space:]]+[0-9]+' "$sshd_conf" | awk '{print $2}')
    fi

    # F-01b fix: if still empty, try live socket detection via ss.
    if [[ -z "$port_source" ]] && command -v ss >/dev/null 2>&1; then
        local live_ports
        live_ports=$(ss -tlnp 2>/dev/null \
            | awk '/sshd/{match($4,/[0-9]+$/); if(RSTART) print substr($4,RSTART,RLENGTH)}' \
            | sort -un | head -5 || true)
        if [[ -n "$live_ports" ]]; then
            warn "sshd -T returned no output — using live ss port detection."
            port_source="$live_ports"
        fi
    fi

    if [[ -z "$port_source" ]] && pgrep -x sshd >/dev/null 2>&1; then
        warn "Cannot determine active SSH port(s)."
        warn "Check 'ss -tlnp' manually, then re-run: bash ops-install.sh"
        return 1
    fi

    local port
    while IFS= read -r port; do
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        if ! port_list_contains "$port" "${SSH_CURRENT_PORTS[@]}"; then
            SSH_CURRENT_PORTS+=("$port")
        fi
    done <<< "$port_source"

    if [[ ${#SSH_CURRENT_PORTS[@]} -eq 0 ]]; then
        warn "No active SSH port could be derived from the current host state."
        return 1
    fi

    for port in "${SSH_CURRENT_PORTS[@]}"; do
        if [[ "$port" == "22" ]]; then
            has_port_22="yes"
        else
            non22_ports+=("$port")
        fi
    done

    SSH_BOOTSTRAP_PORTS=("${SSH_CURRENT_PORTS[@]}")

    if [[ ${#SSH_CURRENT_PORTS[@]} -eq 1 && "${SSH_CURRENT_PORTS[0]}" == "22" ]]; then
        return 0
    fi

    if [[ ${#non22_ports[@]} -eq 1 ]]; then
        SSH_BOOTSTRAP_MODE="managed"
        OPS_MANAGED_SSH_PORT="${non22_ports[0]}"
        if [[ "$has_port_22" == "yes" ]]; then
            OPS_MANAGED_SSH_TRANSITION_PORT="22"
        fi
        OPS_SSH_STATE_PERSIST="yes"
        return 0
    fi

    SSH_BOOTSTRAP_MODE="ambiguous"
    if [[ -n "$existing_locked_port" ]] && port_list_contains "$existing_locked_port" "${SSH_CURRENT_PORTS[@]}"; then
        if [[ -n "$existing_transition_port" && "$existing_transition_port" != "$existing_locked_port" ]]; then
            if port_list_contains "$existing_transition_port" "${SSH_CURRENT_PORTS[@]}"; then
                OPS_MANAGED_SSH_TRANSITION_PORT="$existing_transition_port"
                OPS_MANAGED_SSH_PORT="$existing_locked_port"
                OPS_SSH_STATE_PERSIST="yes"
            fi
        else
            OPS_MANAGED_SSH_PORT="$existing_locked_port"
            OPS_SSH_STATE_PERSIST="yes"
        fi
    fi
}

setup_ssh_port() {
    detect_ssh_state || return 1

    if [[ "$SSH_BOOTSTRAP_MODE" != "fresh" ]]; then
        echo ""
        echo -e "${CYN}${BLD}━━━ SSH Port Configuration ━━━${RST}"

        if [[ "$SSH_BOOTSTRAP_MODE" == "ambiguous" ]]; then
            warn "Detected multiple live SSH ports: $(format_port_list "${SSH_CURRENT_PORTS[@]}")"
            if [[ "$OPS_SSH_STATE_PERSIST" == "yes" && -n "$OPS_MANAGED_SSH_PORT" ]]; then
                ok "Preserving existing OPS locked SSH port: ${OPS_MANAGED_SSH_PORT}"
                if [[ -n "$OPS_MANAGED_SSH_TRANSITION_PORT" ]]; then
                    warn "Existing OPS transition port remains recorded: ${OPS_MANAGED_SSH_TRANSITION_PORT}"
                fi
            else
                warn "Bootstrap will preserve all live SSH access and will not rewrite OPS_SSH_PORT / OPS_SSH_TRANSITION_PORT on this run."
            fi
        else
            ok "SSH port already configured: port ${OPS_MANAGED_SSH_PORT}"
            if [[ -n "$OPS_MANAGED_SSH_TRANSITION_PORT" ]]; then
                warn "Transition port ${OPS_MANAGED_SSH_TRANSITION_PORT} is still open. Use 'ops → Security → Finalise SSH port' after verifying the locked port."
            else
                ok "No SSH transition port is currently recorded."
            fi
        fi

        echo ""
        return 0
    fi

    # Fresh state — port 22 is the only effective SSH port.
    echo ""
    echo -e "${CYN}${BLD}━━━ SSH Port Configuration ━━━${RST}"
    echo "  Current SSH port is 22."
    echo "  A new port will be opened in addition to port 22 (transition period)."
    echo "  Port 22 will remain open until you manually close it via OPS security menu."
    echo ""

    local new_port
    while true; do
        read -r -p "  Enter new SSH port (> 1024, not currently in use) [default: 2222]: " new_port
        new_port="${new_port:-2222}"

        if ! [[ "$new_port" =~ ^[0-9]+$ ]] || (( new_port <= 1024 || new_port > 65535 )); then
            warn "Port must be a number between 1025 and 65535. Try again."
            continue
        fi

        if ss -H -ltn | awk '{print $4}' | grep -Eq "(^|:)${new_port}$"; then
            warn "Port ${new_port} is already in use. Choose a different port."
            continue
        fi

        break
    done

    OPS_MANAGED_SSH_PORT="$new_port"
    OPS_MANAGED_SSH_TRANSITION_PORT="22"
    OPS_SSH_STATE_PERSIST="yes"
    SSH_BOOTSTRAP_PORTS=("22" "$new_port")
    ok "New SSH port set to: ${OPS_MANAGED_SSH_PORT}"

    _configure_sshd_fresh
}

# _configure_sshd_fresh: chỉ chạy khi fresh install (port 22 là duy nhất).
detect_ssh_service() {
    if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
        echo "ssh"
    else
        echo "sshd"
    fi
}

_restore_sshd_include_backups() {
    local backup_dir="$1"
    local sshd_inc_dir="/etc/ssh/sshd_config.d"
    local backup_path target_path

    [[ -d "$backup_dir" ]] || return 0

    for backup_path in "$backup_dir"/*.conf; do
        [[ -f "$backup_path" ]] || continue
        target_path="${sshd_inc_dir}/$(basename "$backup_path")"
        cp "$backup_path" "$target_path"
    done
}

_configure_sshd_fresh() {
    local sshd_conf="/etc/ssh/sshd_config"
    info "Configuring sshd: adding port ${OPS_MANAGED_SSH_PORT} (keeping port 22 during transition)..."

    local backup="${sshd_conf}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$sshd_conf" "$backup"
    info "sshd_config backup: $backup"

    local include_backup_dir
    include_backup_dir=$(mktemp -d /tmp/ops-sshd-includes-XXXXXX)

    local tmp
    tmp=$(mktemp)
    {
        echo "Port 22"
        echo "Port ${OPS_MANAGED_SSH_PORT}"
        grep -Ev '^[[:space:]]*Port[[:space:]]+[0-9]+' "$sshd_conf"
    } > "$tmp"
    mv "$tmp" "$sshd_conf"

    # Strip conflicting SSH directives from cloud-init include files.
    # cloud-init injects PasswordAuthentication yes and PermitRootLogin
    # into /etc/ssh/sshd_config.d/ — these must be removed so OPS can
    # write 99-ops-hardening.conf with the correct hardened values.
    _strip_cloud_init_ssh_overrides "$include_backup_dir"

    if ! sshd -t > /dev/null 2>&1; then
        cp "$backup" "$sshd_conf"
        _restore_sshd_include_backups "$include_backup_dir"
        rm -rf "$include_backup_dir"
        die "sshd -t failed after adding port ${OPS_MANAGED_SSH_PORT}. Restored previous SSH config."
    fi

    local ssh_service
    ssh_service=$(detect_ssh_service)
    if ! systemctl reload "$ssh_service" > /dev/null 2>&1; then
        cp "$backup" "$sshd_conf"
        _restore_sshd_include_backups "$include_backup_dir"
        rm -rf "$include_backup_dir"
        systemctl reload "$ssh_service" > /dev/null 2>&1 || true
        die "SSH reload failed after adding port ${OPS_MANAGED_SSH_PORT}. Restored previous SSH config."
    fi

    rm -rf "$include_backup_dir"
    ok "sshd reloaded — now listening on ports 22 and ${OPS_MANAGED_SSH_PORT}."
}

# _strip_cloud_init_ssh_overrides
# Removes Port, PasswordAuthentication, PermitRootLogin, X11Forwarding and other
# directives from all sshd_config.d/ files EXCEPT 99-ops-hardening.conf.
# Port is included because _configure_sshd_fresh writes the authoritative Port
# lines to the main sshd_config; any Port directive left in sshd_config.d/ would
# cause sshd to listen on a stale cloud-init port in addition to the OPS-managed
# ports (e.g. cloud-init sets Port 5022 → after fresh‑configure sshd would listen
# on 22, the OPS-managed locked port, and 5022 if this strip were not applied).
# Idempotent: safe to call multiple times.
_strip_cloud_init_ssh_overrides() {
    local backup_dir="${1:-}"
    local sshd_inc_dir="/etc/ssh/sshd_config.d"
    [[ -d "$sshd_inc_dir" ]] || return 0

    local f
    for f in "$sshd_inc_dir"/*.conf; do
        [[ -f "$f" ]] || continue
        [[ "$(basename "$f")" == "99-ops-hardening.conf" ]] && continue
        if grep -Eq \
            '^[[:space:]]*(Port|PasswordAuthentication|PermitRootLogin|X11Forwarding|AllowTcpForwarding|AllowAgentForwarding|PermitTunnel)[[:space:]]+' \
            "$f" 2>/dev/null; then
            cp "$f" "${f}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
            if [[ -n "$backup_dir" ]]; then
                cp "$f" "${backup_dir}/$(basename "$f")"
            fi
            sed -i -E \
                '/^[[:space:]]*(Port|PasswordAuthentication|PermitRootLogin|X11Forwarding|AllowTcpForwarding|AllowAgentForwarding|PermitTunnel)[[:space:]]+/d' \
                "$f"
            ok "Stripped conflicting SSH directives from: $(basename "$f")"
        fi
    done
}

# _apply_minimum_ssh_hardening
# FIX-05: Write /etc/ssh/sshd_config.d/99-ops-hardening.conf right after
# ops-install.sh runs, so PermitRootLogin=no is enforced even before the
# user launches the Setup Wizard.
#
# Safety guards (multi-layer):
#   1. ADMIN_USER must exist and != root (lockout guard)
#   2. File already present → return 0 (idempotent guard)
#   3. Ensure Include directive is FIRST in sshd_config (first-match-wins)
#   4. Write to /tmp first, validate with `sshd -t`, then atomic mv
#   5. If sshd -t fails → warn + delete tmpfile (never apply bad config)
#   6. If reload fails → warn (SSH keeps running on old config — no lockout)
#
# PasswordAuthentication stays "yes" during installer-time hardening.
# The installer only establishes a safe transition baseline; disabling
# password auth belongs to the wizard/security flow after the operator has
# verified SSH access on the admin user and locked port.
#
# Note: Wizard security_write_sshd_hardening_include() always OVERWRITES
# this file with a fuller config later — no conflict.
_apply_minimum_ssh_hardening() {
    local hardening_conf="/etc/ssh/sshd_config.d/99-ops-hardening.conf"
    local sshd_conf="/etc/ssh/sshd_config"

    # ── Guard 1: ADMIN_USER safety check
    if [[ -z "${ADMIN_USER:-}" ]]; then
        warn "FIX-05: ADMIN_USER not set — skipping minimum SSH hardening."
        return 0
    fi
    if [[ "$ADMIN_USER" == "root" ]]; then
        warn "FIX-05: ADMIN_USER=root — skipping minimum SSH hardening to avoid lockout."
        return 0
    fi
    if ! id "$ADMIN_USER" &>/dev/null; then
        warn "FIX-05: User '${ADMIN_USER}' does not exist — skipping minimum SSH hardening."
        return 0
    fi

    # ── Guard 2: Idempotent — do not overwrite if already present
    if [[ -f "$hardening_conf" ]]; then
        ok "FIX-05: SSH hardening config already present: ${hardening_conf} — skipping."
        return 0
    fi

    # ── Guard 3: Stage any sshd_config Include change in a temp file first.
    # Do not mutate the live sshd_config until the combined config validates.
    local include_line="Include /etc/ssh/sshd_config.d/*.conf"
    local tmp_main main_changed="no"
    tmp_main=$(mktemp "${sshd_conf}.tmp.XXXXXX")

    if [[ -f "$sshd_conf" ]]; then
        local first_directive
        first_directive=$(grep -m1 -v '^[[:space:]]*#' "$sshd_conf" 2>/dev/null | grep -v '^[[:space:]]*$' || true)

        if ! grep -qF "$include_line" "$sshd_conf" 2>/dev/null; then
            {
                echo "$include_line"
                cat "$sshd_conf"
            } > "$tmp_main"
            main_changed="yes"
            info "FIX-05: Staged '${include_line}' at the top of sshd_config."
        elif [[ "$first_directive" != "$include_line" ]]; then
            {
                echo "$include_line"
                grep -v "^[[:space:]]*Include[[:space:]]" "$sshd_conf"
            } > "$tmp_main"
            main_changed="yes"
            info "FIX-05: Staged '${include_line}' as the first sshd_config directive (first-match-wins)."
        else
            cp "$sshd_conf" "$tmp_main"
        fi
    fi
    chmod 644 "$tmp_main"

    # ── Step 4: Keep PasswordAuthentication enabled during installer-time hardening.
    # SSH key presence alone is not enough to prove the operator has successfully
    # verified login on the admin user and locked port.
    local password_auth="yes"
    info "FIX-05: Installer keeps PasswordAuthentication=yes until the wizard/security flow finalizes SSH access."

    # ── Step 5: Write to tmp first (never touch the real file until validated)
    # NOTE: Port directives are intentionally NOT written here.
    # They are managed by _configure_sshd_fresh() in sshd_config main (installer)
    # and by security_write_sshd_hardening_include() in 99-ops-hardening.conf (wizard).
    # Mixing port management between the two files creates finalize/reconcile conflicts.
    mkdir -p "$(dirname "$hardening_conf")"
    local tmp_conf
    tmp_conf=$(mktemp "${hardening_conf}.tmp.XXXXXX")

    {
        echo "# Managed by OPS — written by ops-install.sh (FIX-05 minimum hardening)"
        echo "# Full hardening applied when wizard runs: Security → Harden SSH config"
        echo "# DO NOT edit manually — file will be overwritten by the Setup Wizard."
        echo ""
        echo "PermitRootLogin no"
        echo "PubkeyAuthentication yes"           # ← CRITICAL: explicit, cloud-init may have set no
        echo "PasswordAuthentication ${password_auth}"
        echo "KbdInteractiveAuthentication no"
        echo "X11Forwarding no"
        echo "AllowAgentForwarding no"
        # NOTE: No Port directive here.
        # Port is managed by _configure_sshd_fresh() in sshd_config main.
        # The wizard's security_write_sshd_hardening_include() will own Port
        # in this file after the full wizard runs. Mixing port management
        # between the two files causes finalize/reconcile conflicts.
    } > "$tmp_conf"
    chmod 600 "$tmp_conf"

    # ── Step 7: Validate the staged main config before touching the real path.
    if ! sshd -t -f "$tmp_main" > /dev/null 2>&1; then
        warn "FIX-05: Staged sshd_config validation failed before applying hardening. Skipping."
        rm -f "$tmp_main" "$tmp_conf"
        return 0
    fi

    # Now validate with the new hardening file included (symlink trick)
    local tmp_include_dir
    tmp_include_dir=$(mktemp -d /tmp/ops-sshd-test-XXXXXX)
    ln -sf "$tmp_conf" "${tmp_include_dir}/99-ops-hardening.conf"

    # Build a test sshd_config pointing at our temp dir
    local tmp_test_conf
    tmp_test_conf=$(mktemp "${sshd_conf}.test.XXXXXX")
    sed "1s|^Include /etc/ssh/sshd_config.d/\*\.conf$|Include ${tmp_include_dir}/*.conf|" \
        "$tmp_main" > "$tmp_test_conf"

    if ! sshd -t -f "$tmp_test_conf" > /dev/null 2>&1; then
        warn "FIX-05: Hardening config validation failed (sshd -t). Not applying to avoid lockout."
        warn "       Check: sshd -t -f ${tmp_conf}"
        rm -f "$tmp_main" "$tmp_conf" "$tmp_test_conf"
        rm -rf "$tmp_include_dir"
        return 0
    fi
    rm -f "$tmp_test_conf"
    rm -rf "$tmp_include_dir"

    # ── Step 8: Commit the already-validated files to their live paths
    if [[ "$main_changed" == "yes" ]]; then
        mv "$tmp_main" "$sshd_conf"
    else
        rm -f "$tmp_main"
    fi
    mv "$tmp_conf" "$hardening_conf"
    chmod 600 "$hardening_conf"

    # ── Step 9: Reload SSH to apply
    if systemctl reload ssh > /dev/null 2>&1 || systemctl reload sshd > /dev/null 2>&1; then
        ok "FIX-05: Minimum SSH hardening applied and SSH reloaded."
        ok "        PermitRootLogin=no  PasswordAuthentication=${password_auth}"
        ok "        File: ${hardening_conf}"
    else
        warn "FIX-05: Hardening file written but SSH reload failed — SSH still running (config will apply on next restart)."
        ok "        PermitRootLogin=no  PasswordAuthentication=${password_auth}"
    fi
}

configure_ufw() {
    info "Configuring UFW firewall..."

    if ! command -v ufw &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw
    fi

    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null

    # Preserve every live SSH port detected during bootstrap. Do not collapse
    # rerun state down to a guessed single port.
    local ssh_rules_added=0
    local port
    for port in "${SSH_BOOTSTRAP_PORTS[@]}"; do
        [[ -n "$port" ]] || continue
        if ufw allow "${port}/tcp" comment "ops: SSH bootstrap" >/dev/null 2>&1; then
            (( ssh_rules_added++ )) || true
        else
            warn "UFW: failed to add SSH bootstrap rule for ${port}/tcp"
        fi
    done

    if [[ "$ssh_rules_added" -eq 0 ]]; then
        die "UFW setup aborted: could not add any SSH allow rule. Enable UFW manually after verifying SSH access."
    fi

    ufw allow 80/tcp comment "ops: HTTP" >/dev/null 2>&1 || warn "UFW: could not add 80/tcp rule"
    ufw allow 443/tcp comment "ops: HTTPS" >/dev/null 2>&1 || warn "UFW: could not add 443/tcp rule"

    if ufw status 2>/dev/null | grep -qi "Status: active"; then
        info "UFW already active — rules updated."
    else
        ufw --force enable >/dev/null
    fi
    ok "UFW configured. HTTP/HTTPS open. Live SSH port(s) preserved during bootstrap."
}

# ── 5. Admin user ─────────────────────────────────────────────

# setup_admin_user: idempotent — skip hoàn toàn nếu user đã tồn tại.
setup_admin_user() {
    echo ""
    echo -e "${CYN}${BLD}━━━ Admin User Setup ━━━${RST}"

    if [[ -z "${ADMIN_USER:-}" && -f "${OPS_CONFIG_DIR}/ops.conf" ]]; then
        ADMIN_USER=$(grep '^OPS_ADMIN_USER=' "${OPS_CONFIG_DIR}/ops.conf" 2>/dev/null | head -n1 | cut -d= -f2- | sed 's/^"//; s/"$//' || true)
        if [[ -n "$ADMIN_USER" ]]; then
            if id "$ADMIN_USER" &>/dev/null; then
                info "Reusing existing OPS admin user from ops.conf: ${ADMIN_USER}"
            else
                warn "OPS admin user '${ADMIN_USER}' recorded in ops.conf does not exist — prompting for a username."
                ADMIN_USER=""
            fi
        fi
    fi

    # Nếu chưa biết ADMIN_USER (fresh install) → hỏi
    if [[ -z "${ADMIN_USER:-}" ]]; then
        echo "  A non-root admin user will be created for daily SSH access."
        echo ""
        while true; do
            read -r -p "  Enter new admin username [default: opsadmin]: " ADMIN_USER
            ADMIN_USER="${ADMIN_USER:-opsadmin}"
            if ! [[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
                warn "Username must start with a lowercase letter and contain only a-z, 0-9, _ or -. Try again."
                continue
            fi
            break
        done
        export ADMIN_USER
    fi

    # User đã tồn tại → bỏ qua toàn bộ, kể cả password
    if id "$ADMIN_USER" &>/dev/null; then
        ok "User '${ADMIN_USER}' already exists — skipping creation and password."
        # Đảm bảo sudo group (safe, idempotent)
        if ! id -nG "$ADMIN_USER" | grep -qw sudo; then
            usermod -aG sudo "$ADMIN_USER"
            OPS_BOOTSTRAP_SUDO_ADDED="yes"
            ok "User '${ADMIN_USER}' added to sudo group."
        fi
        export ADMIN_USER
        return 0
    fi

    # User chưa tồn tại → tạo mới
    info "Creating user: ${ADMIN_USER}..."
    useradd -m -s /bin/bash "$ADMIN_USER"
    OPS_BOOTSTRAP_USER_CREATED="yes"
    ok "User '${ADMIN_USER}' created."

    usermod -aG sudo "$ADMIN_USER"
    ok "User '${ADMIN_USER}' added to sudo group."

    echo ""
    info "Set a password for '${ADMIN_USER}':"
    while true; do
        passwd "$ADMIN_USER" && break || warn "Password change failed — try again."
    done
    ok "Password set for '${ADMIN_USER}'."
    export ADMIN_USER
}

# -- 5b. SSH public key setup (optional) ---------------------------
# Prevents SSH lockout if PasswordAuthentication is later disabled.
# Sets SSH_KEY_CONFIGURED=yes|no for use by the security wizard.
setup_ssh_key() {
    echo ""
    echo -e "${CYN}${BLD}=== SSH Public Key Setup (Recommended) ===${RST}"
    echo "  Adding your SSH public key NOW prevents being locked out"
    echo "  if PasswordAuthentication is disabled later via Setup Wizard."
    echo ""
    echo "  To get your public key from your local machine, run:"
    echo -e "    ${CYN}cat ~/.ssh/id_rsa.pub${RST}  or  ${CYN}cat ~/.ssh/id_ed25519.pub${RST}"
    echo ""

    local admin_home pub_key
    admin_home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)

    if [[ -z "$admin_home" || ! -d "$admin_home" ]]; then
        warn "Cannot find home directory for '${ADMIN_USER}' -- skipping SSH key setup."
        SSH_KEY_CONFIGURED="no"
        export SSH_KEY_CONFIGURED
        return 0
    fi

    # If authorized_keys already has valid content, skip.
    if installer_has_authorized_keys "${admin_home}/.ssh/authorized_keys"; then
        ok "SSH authorized_keys already populated for '${ADMIN_USER}' -- skipping."
        SSH_KEY_CONFIGURED="yes"
        export SSH_KEY_CONFIGURED
        return 0
    fi

    read -r -p "  Paste your SSH public key (or press Enter to skip): " pub_key

    if [[ -z "$pub_key" ]]; then
        warn "No SSH key added."
        warn "PasswordAuthentication will stay ENABLED until you add a key."
        warn "Add later via: ops -> Security -> Manage SSH Keys"
        SSH_KEY_CONFIGURED="no"
        export SSH_KEY_CONFIGURED
        return 0
    fi

    # Sanity check: must look like a real public key
    if ! installer_authorized_key_line_is_valid "$pub_key"; then
        warn "Input does not look like a valid SSH public key -- skipping."
        warn "Add later via: ops -> Security -> Manage SSH Keys"
        SSH_KEY_CONFIGURED="no"
        export SSH_KEY_CONFIGURED
        return 0
    fi

    prepare_admin_ssh_rollback_state "$admin_home"
    mkdir -p "${admin_home}/.ssh"
    chmod 700 "${admin_home}/.ssh"
    echo "$pub_key" >> "${admin_home}/.ssh/authorized_keys"
    chmod 600 "${admin_home}/.ssh/authorized_keys"
    chown -R "${ADMIN_USER}:${ADMIN_USER}" "${admin_home}/.ssh"

    ok "SSH public key added for '${ADMIN_USER}'."
    ok "You can now safely disable PasswordAuthentication in the Setup Wizard."
    SSH_KEY_CONFIGURED="yes"
    export SSH_KEY_CONFIGURED
}

# -- 6. Install OPS core (tarball) ---------------------------------
# Dung tarball thay vi git clone -- nhat quan voi self-update menu 16.
# Khong yeu cau git tren VPS.

cleanup_post_deploy_snapshots() {
    if [[ -n "${OPS_POST_DEPLOY_SNAPSHOT_DIR:-}" && -d "${OPS_POST_DEPLOY_SNAPSHOT_DIR}" ]]; then
        rm -rf "${OPS_POST_DEPLOY_SNAPSHOT_DIR}"
        OPS_POST_DEPLOY_SNAPSHOT_DIR=""
    fi
}

prepare_post_deploy_rollback_state() {
    OPS_POST_DEPLOY_SNAPSHOT_DIR=$(mktemp -d /tmp/ops-post-deploy-XXXXXX)

    snapshot_path_state "/etc/ops/ops.conf" "$OPS_POST_DEPLOY_SNAPSHOT_DIR" "ops-conf"
    snapshot_path_state "/etc/ops/setup.conf" "$OPS_POST_DEPLOY_SNAPSHOT_DIR" "setup-conf"
    snapshot_path_state "/etc/ops/capacity.conf" "$OPS_POST_DEPLOY_SNAPSHOT_DIR" "capacity-conf"
    snapshot_path_state "/etc/logrotate.d/ops" "$OPS_POST_DEPLOY_SNAPSHOT_DIR" "logrotate-ops"
    snapshot_path_state "/usr/local/bin/ops" "$OPS_POST_DEPLOY_SNAPSHOT_DIR" "bin-ops"
    snapshot_path_state "/usr/local/bin/ops-dashboard" "$OPS_POST_DEPLOY_SNAPSHOT_DIR" "bin-ops-dashboard"

    local admin_home
    admin_home=$(getent passwd "$ADMIN_USER" 2>/dev/null | cut -d: -f6 || true)
    if [[ -n "$admin_home" ]]; then
        snapshot_path_state "${admin_home}/.bash_profile" "$OPS_POST_DEPLOY_SNAPSHOT_DIR" "admin-bash-profile"
    fi
}

rollback_post_deploy_failure() {
    warn "Post-deploy setup failed. Restoring previous OPS runtime and operator-facing state."

    rm -rf "$OPS_INSTALL_DIR"
    if [[ -n "${OPS_INSTALL_PREVIOUS_BACKUP:-}" && -d "${OPS_INSTALL_PREVIOUS_BACKUP}" ]]; then
        if mv "${OPS_INSTALL_PREVIOUS_BACKUP}" "$OPS_INSTALL_DIR"; then
            info "Previous OPS install restored to ${OPS_INSTALL_DIR}."
        else
            warn "Failed to restore previous OPS install from ${OPS_INSTALL_PREVIOUS_BACKUP}."
        fi
        OPS_INSTALL_PREVIOUS_BACKUP=""
    fi

    restore_path_snapshot "/etc/ops/ops.conf" "$OPS_POST_DEPLOY_SNAPSHOT_DIR" "ops-conf"
    restore_path_snapshot "/etc/ops/setup.conf" "$OPS_POST_DEPLOY_SNAPSHOT_DIR" "setup-conf"
    restore_path_snapshot "/etc/ops/capacity.conf" "$OPS_POST_DEPLOY_SNAPSHOT_DIR" "capacity-conf"
    restore_path_snapshot "/etc/logrotate.d/ops" "$OPS_POST_DEPLOY_SNAPSHOT_DIR" "logrotate-ops"
    restore_path_snapshot "/usr/local/bin/ops" "$OPS_POST_DEPLOY_SNAPSHOT_DIR" "bin-ops"
    restore_path_snapshot "/usr/local/bin/ops-dashboard" "$OPS_POST_DEPLOY_SNAPSHOT_DIR" "bin-ops-dashboard"

    local admin_home
    admin_home=$(getent passwd "$ADMIN_USER" 2>/dev/null | cut -d: -f6 || true)
    if [[ -n "$admin_home" ]]; then
        restore_path_snapshot "${admin_home}/.bash_profile" "$OPS_POST_DEPLOY_SNAPSHOT_DIR" "admin-bash-profile"
    fi

    cleanup_post_deploy_snapshots
}

install_ops_core() {
    info "Installing OPS core to ${OPS_INSTALL_DIR} (via tarball)..."
    prepare_install_source_tree

    local parent_dir backup_root
    parent_dir=$(dirname "$OPS_INSTALL_DIR")
    OPS_INSTALL_CANDIDATE_ROOT="${parent_dir}/.ops-install-candidate.$$"
    backup_root=""
    OPS_INSTALL_PREVIOUS_BACKUP=""

    rm -rf "$OPS_INSTALL_CANDIDATE_ROOT"
    mkdir -p "$parent_dir" "$OPS_INSTALL_CANDIDATE_ROOT"

    if ! rsync -a --delete --exclude='*.log' \
        "${OPS_INSTALL_SOURCE_OPS}/" \
        "${OPS_INSTALL_CANDIDATE_ROOT}/"; then
        die "Failed to build the candidate OPS runtime tree."
    fi

    # Also copy install/ docs/ rules/ agents/ from source root (outside ops/)
    for extra_dir in install docs rules agents; do
        if [[ -d "${OPS_INSTALL_SOURCE_ROOT}/${extra_dir}" ]]; then
            if ! rsync -a --delete "${OPS_INSTALL_SOURCE_ROOT}/${extra_dir}/" \
                "${OPS_INSTALL_CANDIDATE_ROOT}/${extra_dir}/"; then
                die "Failed to copy '${extra_dir}' into the candidate OPS tree."
            fi
        fi
    done

    # Validate required candidate entrypoints before touching the live tree.
    for required_path in \
        "${OPS_INSTALL_CANDIDATE_ROOT}/bin/ops" \
        "${OPS_INSTALL_CANDIDATE_ROOT}/bin/ops-dashboard" \
        "${OPS_INSTALL_CANDIDATE_ROOT}/bin/ops-setup.sh"; do
        [[ -f "$required_path" ]] || die "Missing required candidate entrypoint: ${required_path}"
    done

    # Validate candidate shell scripts before touching the live tree.
    local shell_script
    while IFS= read -r -d '' shell_script; do
        if ! bash -n "$shell_script"; then
            die "Syntax check failed for candidate script: ${shell_script}"
        fi
    done < <(find "$OPS_INSTALL_CANDIDATE_ROOT" -type f -name '*.sh' -print0)

    # Validate extensionless Bash entrypoints in bin/ as well.
    local shell_entry
    while IFS= read -r -d '' shell_entry; do
        if ! bash -n "$shell_entry"; then
            die "Syntax check failed for candidate entrypoint: ${shell_entry}"
        fi
    done < <(find "${OPS_INSTALL_CANDIDATE_ROOT}/bin" -maxdepth 1 -type f ! -name '*.sh' -print0)

    # Apply permissions directly to the validated candidate tree.
    find "${OPS_INSTALL_CANDIDATE_ROOT}/bin"     -type f               -exec chmod +x {} \;
    find "${OPS_INSTALL_CANDIDATE_ROOT}/modules" -type f -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true
    find "${OPS_INSTALL_CANDIDATE_ROOT}/core"    -type f -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true
    find "${OPS_INSTALL_CANDIDATE_ROOT}/install" -type f -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true

    # F-05 fix: executable scripts (bin/, modules/, core/, install/) must be
    # owned root:root so a compromised or malicious ADMIN_USER cannot modify
    # files that subsequently execute as root (re-install, sudo paths).
    # Only non-executable content dirs (docs/, agents/) are admin-user writable.
    # SECURITY-RULES §1: non-root user must not own files that execute as root.
    chown root:root "$OPS_INSTALL_CANDIDATE_ROOT"
    chmod 755 "$OPS_INSTALL_CANDIDATE_ROOT"

    for _exec_dir in bin modules core install; do
        if [[ -d "${OPS_INSTALL_CANDIDATE_ROOT}/${_exec_dir}" ]]; then
            chown -R root:root "${OPS_INSTALL_CANDIDATE_ROOT}/${_exec_dir}"
        fi
    done

    # Non-executable content: admin user may read/write (docs, agents)
    for _data_dir in docs agents; do
        if [[ -d "${OPS_INSTALL_CANDIDATE_ROOT}/${_data_dir}" ]]; then
            chown -R "${ADMIN_USER}:${ADMIN_USER}" "${OPS_INSTALL_CANDIDATE_ROOT}/${_data_dir}"
        fi
    done
    unset _data_dir _exec_dir shell_script shell_entry required_path

    # Activate the fully prepared candidate tree atomically.
    if [[ -e "$OPS_INSTALL_DIR" ]]; then
        backup_root="${parent_dir}/.ops-install-backup.$(date +%Y%m%d_%H%M%S)"
        if ! mv "$OPS_INSTALL_DIR" "$backup_root"; then
            die "Failed to preserve the previous OPS install for rollback."
        fi
    fi

    if ! mv "$OPS_INSTALL_CANDIDATE_ROOT" "$OPS_INSTALL_DIR"; then
        if [[ -n "$backup_root" && -e "$backup_root" ]]; then
            mv "$backup_root" "$OPS_INSTALL_DIR" >/dev/null 2>&1 || warn "Failed to restore previous OPS install from ${backup_root}."
        fi
        die "Failed to activate the new OPS tree. Previous installation was restored."
    fi

    OPS_INSTALL_CANDIDATE_ROOT=""
    OPS_INSTALL_PREVIOUS_BACKUP="$backup_root"
    cleanup_install_artifacts
    ok "OPS core installed at ${OPS_INSTALL_DIR} (from tarball — no git required)."
}

cleanup_install_backup() {
    if [[ -n "${OPS_INSTALL_PREVIOUS_BACKUP:-}" && -d "${OPS_INSTALL_PREVIOUS_BACKUP}" ]]; then
        rm -rf "${OPS_INSTALL_PREVIOUS_BACKUP}"
        OPS_INSTALL_PREVIOUS_BACKUP=""
    fi
}

# ── 7. Write capacity.conf ────────────────────────────────────

write_capacity_conf() {
    mkdir -p "$OPS_CONFIG_DIR"
    local conf="${OPS_CONFIG_DIR}/capacity.conf"

    cat > "$conf" <<EOF
# OPS Capacity Profile
# Generated by ops-install.sh on $(date '+%F %T')
# DO NOT edit manually — re-run installer to refresh.

RAM_MB="${RAM_MB}"
CPU_CORES="${CPU_CORES}"
DISK_GB="${DISK_GB}"
DISK_AVAIL_GB="${DISK_AVAIL_GB}"
OPS_TIER="${OPS_TIER}"
TIER_SITES="${TIER_SITES}"
TIER_USERS="${TIER_USERS}"
EOF

    chmod 644 "$conf"
    ok "Capacity profile written to ${conf}."
}

# ── 8. Run ops-setup.sh ───────────────────────────────────────

run_setup() {
    local setup_script="${OPS_INSTALL_DIR}/bin/ops-setup.sh"
    local env_vars=()

    if [[ ! -f "$setup_script" ]]; then
        die "ops-setup.sh not found at ${setup_script}. Install may have failed."
    fi

    env_vars+=("ADMIN_USER=${ADMIN_USER}")
    if [[ "${OPS_SSH_STATE_PERSIST:-no}" == "yes" && -n "${OPS_MANAGED_SSH_PORT:-}" ]]; then
        env_vars+=("OPS_SSH_PORT=${OPS_MANAGED_SSH_PORT}")
        env_vars+=("OPS_SSH_TRANSITION_PORT=${OPS_MANAGED_SSH_TRANSITION_PORT:-}")
    else
        warn "Preserving existing OPS SSH state without rewriting ops.conf on this run."
    fi

    info "Running ops-setup.sh as root (will use ADMIN_USER=${ADMIN_USER})..."
    env "${env_vars[@]}" bash "$setup_script"
}

# ── 9. Detect server IP for final instructions ────────────────

detect_server_ip() {
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<YOUR_SERVER_IP>")
    export SERVER_IP
}

# ── Main ──────────────────────────────────────────────────────

main() {
    trap installer_exit_trap EXIT

    # F-06: Exclusive install lock — prevents two concurrent installer invocations
    # (e.g. cloud-init retry on timeout) from writing to ops.conf, sshd_config,
    # and UFW rules simultaneously. Waits up to 5 s then aborts cleanly.
    exec 9>/var/lock/ops-install.lock
    if ! flock -w 5 9; then
        die "Another OPS installation is already in progress. Please wait for it to finish, then retry."
    fi

    clear
    echo ""
    echo -e "${CYN}${BLD}╔══════════════════════════════════════╗${RST}"
    echo -e "${CYN}${BLD}║         OPS — VPS Installer          ║${RST}"
    echo -e "${CYN}${BLD}║   Production Setup & Manager v${OPS_VERSION}   ║${RST}"
    echo -e "${CYN}${BLD}╚══════════════════════════════════════╝${RST}"
    echo ""

    preflight_check
    ensure_deps
    compute_tier
    print_vps_summary

    # Confirm before proceeding
    read -r -p "Continue with OPS installation? [y/N]: " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        warn "Installation aborted by user."
        exit 0
    fi

    prepare_install_source_tree
    prepare_pre_activation_rollback_state

    setup_ssh_port
    configure_ufw

    setup_admin_user
    setup_ssh_key

    # FIX-05: Apply minimum SSH hardening right after we know ADMIN_USER
    # and SSH_KEY_CONFIGURED — before installing OPS core so even a
    # partial install leaves the server with PermitRootLogin=no.
    _apply_minimum_ssh_hardening

    install_ops_core
    prepare_post_deploy_rollback_state
    if ! run_setup; then
        rollback_post_deploy_failure
        die "ops-setup.sh failed after activating the new OPS tree. Previous state was restored."
    fi
    if ! write_capacity_conf; then
        rollback_post_deploy_failure
        die "Failed to write capacity.conf after activating the new OPS tree. Previous state was restored."
    fi
    cleanup_post_deploy_snapshots
    cleanup_install_backup
    cleanup_pre_activation_snapshots

    detect_server_ip

    echo ""
    echo -e "${GRN}${BLD}╔══════════════════════════════════════════════════════╗${RST}"
    echo -e "${GRN}${BLD}║               OPS Installation Complete              ║${RST}"
    echo -e "${GRN}${BLD}╚══════════════════════════════════════════════════════╝${RST}"
    echo ""
    echo -e "  ${BLD}IMPORTANT — Save these details:${RST}"
    echo ""
    echo -e "  Admin user : ${BLD}${ADMIN_USER}${RST}"
    if [[ "${OPS_SSH_STATE_PERSIST:-no}" == "yes" && -n "${OPS_MANAGED_SSH_PORT:-}" ]]; then
        echo -e "  SSH port   : ${BLD}${OPS_MANAGED_SSH_PORT}${RST}"
        echo -e "  SSH command: ${CYN}${BLD}ssh -p ${OPS_MANAGED_SSH_PORT} ${ADMIN_USER}@${SERVER_IP}${RST}"
        echo ""
        if [[ -n "${OPS_MANAGED_SSH_TRANSITION_PORT:-}" ]]; then
            echo -e "  ${YLW}Port ${OPS_MANAGED_SSH_TRANSITION_PORT} remains open during transition.${RST}"
            echo -e "  ${YLW}Use 'ops' menu → Security → Finalise SSH port after verifying login on port ${OPS_MANAGED_SSH_PORT}.${RST}"
        else
            echo -e "  ${GRN}No SSH transition port is currently recorded.${RST}"
        fi
        echo ""
        echo -e "  Next steps:"
        echo -e "    1. Open a NEW terminal and test:  ${CYN}ssh -p ${OPS_MANAGED_SSH_PORT} ${ADMIN_USER}@${SERVER_IP}${RST}"
        echo -e "    2. After verifying login, run:    ${CYN}ops${RST}"
        echo -e "    3. Select 'Production Setup Wizard' to complete the stack."
    else
        echo -e "  SSH ports  : ${BLD}$(format_port_list "${SSH_CURRENT_PORTS[@]}")${RST}"
        echo ""
        echo -e "  ${YLW}OPS preserved all detected live SSH ports and did not rewrite managed SSH state on this run.${RST}"
        echo -e "  ${YLW}Review Security → SSH settings before finalizing or removing any SSH port.${RST}"
        echo ""
        echo -e "  Next steps:"
        echo -e "    1. Open a NEW terminal and verify SSH on your existing live port for user ${CYN}${ADMIN_USER}${RST}"
        echo -e "    2. After verifying login, run:    ${CYN}ops${RST}"
        echo -e "    3. Review the SSH state in the Security menu before making port changes."
    fi
    echo ""
}

main
