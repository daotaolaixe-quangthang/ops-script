#!/usr/bin/env bash
# ============================================================
# ops/install/ops-install.sh
# Purpose:  Bootstrap installer — curl -sO … && bash entry point
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# Installer URL (chốt):
#   https://raw.githubusercontent.com/daotaolaixe-quangthang/ops-script/main/install/ops-install.sh
#
# Usage (from VPS, as root):
#   curl -sO https://raw.githubusercontent.com/daotaolaixe-quangthang/ops-script/main/install/ops-install.sh
#   bash ops-install.sh
#
# This script must remain small and auditable.
# Complex logic delegates to core modules and ops-setup.sh.
# ============================================================
set -euo pipefail
IFS=$'\\n\\t'

# ── Constants ─────────────────────────────────────────────────
readonly OPS_INSTALL_DIR="/opt/ops"
readonly OPS_CONFIG_DIR="/etc/ops"
readonly OPS_REPO_URL="https://github.com/daotaolaixe-quangthang/ops-script.git"
readonly OPS_VERSION="0.1.0"
readonly OPS_SOURCE_SUBDIR="ops"

# Colours (inline — do not depend on core/ui.sh before install)
RED=$'\\033[0;31m'
GRN=$'\\033[0;32m'
YLW=$'\\033[1;33m'
CYN=$'\\033[0;36m'
BLD=$'\\033[1m'
RST=$'\\033[0m'

die()  { echo -e "${RED}[ERROR]${RST} $*" >&2; exit 1; }
info() { echo -e "${GRN}[INFO]${RST}  $*"; }
warn() { echo -e "${YLW}[WARN]${RST}  $*"; }
ok()   { echo -e "${GRN}[OK]${RST}    $*"; }

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

    ok "OS check passed: Ubuntu ${os_ver}"
}

# ── 2. Dependency check ───────────────────────────────────────

ensure_deps() {
    info "Checking required dependencies..."
    local missing=()
    for cmd in curl git awk nproc df ss; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done

    if (( ${#missing[@]} > 0 )); then
        warn "Missing: ${missing[*]} — installing..."
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
    fi
    ok "Dependencies ready."
}

# ── 3. VPS resource detection & tier calculation ──────────────

detect_vps_info() {
    RAM_MB=$(awk '/MemTotal/ { printf "%d", $2/1024 }' /proc/meminfo)
    CPU_CORES=$(nproc)
    DISK_GB=$(df -BG / | awk 'NR==2 { gsub("G","",$2); print $2 }')
    DISK_AVAIL=$(df -BG / | awk 'NR==2 { gsub("G","",$4); print $4 }')
    export RAM_MB CPU_CORES DISK_GB DISK_AVAIL
}

compute_tier() {
    detect_vps_info

    if   (( RAM_MB < 1500 ));              then OPS_TIER="S"
    elif (( RAM_MB >= 1500 && RAM_MB < 5000 )); then OPS_TIER="M"
    else                                        OPS_TIER="L"
    fi
    export OPS_TIER

    # Recommended sites / concurrent users per tier
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
    echo -e "  Disk:      ${DISK_GB}GB total, ${DISK_AVAIL}GB available"
    echo -e "  OPS Tier:  ${BLD}${OPS_TIER}${RST}  (sites: ${TIER_SITES}, concurrent users/site: ~${TIER_USERS})"
    echo ""
}

# ── 4. SSH port configuration ─────────────────────────────────

prompt_ssh_port() {
    echo -e "${CYN}${BLD}━━━ SSH Port Configuration ━━━${RST}"
    echo "  Current SSH port is 22."
    echo "  A new port will be opened in addition to port 22 (transition period)."
    echo "  Port 22 will remain open until you manually close it via OPS security menu."
    echo ""

    while true; do
        read -r -p "  Enter new SSH port (> 1024, not currently in use) [default: 2222]: " NEW_SSH_PORT
        NEW_SSH_PORT="${NEW_SSH_PORT:-2222}"

        # Validate: must be a number > 1024 and <= 65535
        if ! [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] || (( NEW_SSH_PORT <= 1024 || NEW_SSH_PORT > 65535 )); then
            warn "Port must be a number between 1025 and 65535. Try again."
            continue
        fi

        # Validate: port must not already be in use
        if ss -H -ltn | awk '{print $4}' | grep -Eq "(^|:)${NEW_SSH_PORT}$"; then
            warn "Port ${NEW_SSH_PORT} is already in use. Choose a different port."
            continue
        fi

        break
    done

    export NEW_SSH_PORT
    ok "New SSH port set to: ${NEW_SSH_PORT}"
}

configure_sshd() {
    local sshd_conf="/etc/ssh/sshd_config"
    info "Configuring sshd to listen on port ${NEW_SSH_PORT} (keeping port 22)..."

    # Backup existing config
    local backup="${sshd_conf}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$sshd_conf" "$backup"
    info "sshd_config backup: $backup"

    # Enforce transition ports idempotently: Port 22 + Port <NEW>
    local tmp
    tmp=$(mktemp)
    {
        echo "Port 22"
        echo "Port ${NEW_SSH_PORT}"
        grep -Ev '^[[:space:]]*Port[[:space:]]+[0-9]+' "$sshd_conf"
    } > "$tmp"
    mv "$tmp" "$sshd_conf"

    systemctl reload ssh || systemctl reload sshd
    ok "sshd reloaded — now listening on ports 22 and ${NEW_SSH_PORT}."
}

configure_ufw() {
    info "Configuring UFW firewall..."

    # Install UFW if missing
    if ! command -v ufw &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw
    fi

    # Ensure baseline policy without destructive reset
    ufw default deny incoming   >/dev/null
    ufw default allow outgoing  >/dev/null

    # Allow both SSH ports during transition
    ufw allow 22/tcp   comment "ops: SSH legacy port (transition)" >/dev/null
    ufw allow "${NEW_SSH_PORT}/tcp" comment "ops: SSH new port" >/dev/null

    # Allow HTTP and HTTPS for future use
    ufw allow 80/tcp  comment "ops: HTTP"  >/dev/null
    ufw allow 443/tcp comment "ops: HTTPS" >/dev/null

    if ufw status 2>/dev/null | grep -qi "Status: active"; then
        info "UFW already active — rules updated."
    else
        ufw --force enable >/dev/null
    fi
    ok "UFW enabled. Ports open: 22, ${NEW_SSH_PORT}, 80, 443."
}

# ── 5. Admin user creation ────────────────────────────────────

prompt_admin_user() {
    echo ""
    echo -e "${CYN}${BLD}━━━ Admin User Setup ━━━${RST}"
    echo "  A non-root admin user will be created for daily SSH access."
    echo ""

    while true; do
        read -r -p "  Enter new admin username [default: opsadmin]: " ADMIN_USER
        ADMIN_USER="${ADMIN_USER:-opsadmin}"

        # Validate: must be a valid unix username
        if ! [[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
            warn "Username must start with a lowercase letter and contain only a-z, 0-9, _ or -. Try again."
            continue
        fi

        break
    done
    export ADMIN_USER
}

create_admin_user() {
    if id "$ADMIN_USER" &>/dev/null; then
        warn "User '${ADMIN_USER}' already exists — skipping user creation."
    else
        info "Creating user: ${ADMIN_USER}..."
        useradd -m -s /bin/bash "$ADMIN_USER"
        ok "User '${ADMIN_USER}' created."
    fi

    # Ensure user is in sudo group
    if ! id -nG "$ADMIN_USER" | grep -qw sudo; then
        usermod -aG sudo "$ADMIN_USER"
        ok "User '${ADMIN_USER}' added to sudo group."
    fi

    # Set password
    echo ""
    info "Set a password for '${ADMIN_USER}':"
    while true; do
        passwd "$ADMIN_USER" && break || warn "Password change failed — try again."
    done
    ok "Password set for '${ADMIN_USER}'."
}

# ── 6. Clone OPS core ─────────────────────────────────────────

install_ops_core() {
    info "Installing OPS core to ${OPS_INSTALL_DIR}..."

    if [[ -d "${OPS_INSTALL_DIR}/.git" ]]; then
        warn "OPS already cloned at ${OPS_INSTALL_DIR} — pulling latest changes..."
        git -C "$OPS_INSTALL_DIR" pull --ff-only
    else
        # Ensure parent exists and is not occupied by a non-git dir
        if [[ -d "$OPS_INSTALL_DIR" ]]; then
            warn "${OPS_INSTALL_DIR} exists but is not a git repo — backing up..."
            mv "$OPS_INSTALL_DIR" "${OPS_INSTALL_DIR}.bak.$(date +%Y%m%d_%H%M%S)"
        fi
        git clone --depth=1 "$OPS_REPO_URL" "$OPS_INSTALL_DIR"
    fi

    # Repo source layout keeps runtime files under ./ops/. Promote to /opt/ops.
    if [[ -d "${OPS_INSTALL_DIR}/${OPS_SOURCE_SUBDIR}/bin" ]]; then
        info "Promoting ${OPS_SOURCE_SUBDIR}/ runtime tree to ${OPS_INSTALL_DIR}..."
        cp -a "${OPS_INSTALL_DIR}/${OPS_SOURCE_SUBDIR}/." "${OPS_INSTALL_DIR}/"
    fi

    [[ -x "${OPS_INSTALL_DIR}/bin/ops-setup.sh" ]] || die "Missing ${OPS_INSTALL_DIR}/bin/ops-setup.sh after clone/promote."

    # Make all scripts executable
    find "${OPS_INSTALL_DIR}/bin" -type f -exec chmod +x {} \;
    find "${OPS_INSTALL_DIR}/install" -type f -name "*.sh" -exec chmod +x {} \;

    # Set ownership to admin user
    chown -R "${ADMIN_USER}:${ADMIN_USER}" "$OPS_INSTALL_DIR"

    ok "OPS core installed at ${OPS_INSTALL_DIR}."
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

    if [[ ! -f "$setup_script" ]]; then
        die "ops-setup.sh not found at ${setup_script}. Clone may have failed."
    fi

    info "Running ops-setup.sh as root (will use ADMIN_USER=${ADMIN_USER})..."
    ADMIN_USER="$ADMIN_USER" \
    OPS_VERSION="$OPS_VERSION" \
    bash "$setup_script"
}

# ── 9. Detect server IP for final instructions ────────────────

detect_server_ip() {
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<YOUR_SERVER_IP>")
    export SERVER_IP
}

# ── Main ──────────────────────────────────────────────────────

main() {
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

    prompt_ssh_port
    configure_sshd
    configure_ufw

    prompt_admin_user
    create_admin_user

    write_capacity_conf
    install_ops_core
    run_setup

    detect_server_ip

    echo ""
    echo -e "${GRN}${BLD}╔══════════════════════════════════════════════════════╗${RST}"
    echo -e "${GRN}${BLD}║               OPS Installation Complete              ║${RST}"
    echo -e "${GRN}${BLD}╚══════════════════════════════════════════════════════╝${RST}"
    echo ""
    echo -e "  ${BLD}IMPORTANT — Save these details:${RST}"
    echo ""
    echo -e "  ${BLD}After reboot use: ssh -p ${NEW_SSH_PORT} ${ADMIN_USER}@${SERVER_IP}${RST}"
    echo ""
    echo -e "  SSH login command:"
    echo -e "  ${CYN}${BLD}  ssh -p ${NEW_SSH_PORT} ${ADMIN_USER}@${SERVER_IP}${RST}"
    echo ""
    echo -e "  ${YLW}⚠  Port 22 remains open during transition.${RST}"
    echo -e "  ${YLW}   Use 'ops' menu → Security → Finalise SSH port to close port 22.${RST}"
    echo ""
    echo -e "  Next steps:"
    echo -e "    1. Open a NEW terminal and test:  ${CYN}ssh -p ${NEW_SSH_PORT} ${ADMIN_USER}@${SERVER_IP}${RST}"
    echo -e "    2. After verifying login, run:    ${CYN}ops${RST}"
    echo -e "    3. Select 'Production Setup Wizard' to complete the stack."
    echo ""
}

main
