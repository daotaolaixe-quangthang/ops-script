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
    for cmd in curl tar awk nproc df ss; do
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

# detect_ssh_state: đọc trạng thái SSH hiện tại từ sshd_config.
# Xuất:
#   SSH_ALREADY_CONFIGURED=yes|no
#   SSH_PORT_22_OPEN=yes|no
#   SSH_CURRENT_PORTS=( ... )
#   NEW_SSH_PORT   — port non-22 đã có, hoặc rỗng nếu chưa đặt
detect_ssh_state() {
    local sshd_conf="/etc/ssh/sshd_config"
    SSH_ALREADY_CONFIGURED="no"
    SSH_PORT_22_OPEN="no"
    SSH_CURRENT_PORTS=()
    NEW_SSH_PORT=""

    if [[ ! -f "$sshd_conf" ]]; then
        return 0
    fi

    local port
    while IFS= read -r port; do
        SSH_CURRENT_PORTS+=("$port")
        if [[ "$port" == "22" ]]; then
            SSH_PORT_22_OPEN="yes"
        else
            NEW_SSH_PORT="$port"   # lấy port non-22 đầu tiên
        fi
    done < <(grep -E '^[[:space:]]*Port[[:space:]]+[0-9]+' "$sshd_conf" \
             | awk '{print $2}')

    if [[ -n "$NEW_SSH_PORT" ]]; then
        SSH_ALREADY_CONFIGURED="yes"
    fi

    export SSH_ALREADY_CONFIGURED SSH_PORT_22_OPEN NEW_SSH_PORT
}

setup_ssh_port() {
    detect_ssh_state

    if [[ "$SSH_ALREADY_CONFIGURED" == "yes" ]]; then
        echo ""
        echo -e "${CYN}${BLD}━━━ SSH Port Configuration ━━━${RST}"
        ok "SSH port đã được cấu hình: port ${NEW_SSH_PORT}."
        if [[ "$SSH_PORT_22_OPEN" == "yes" ]]; then
            warn "Port 22 vẫn mở (transition mode). Dùng 'ops → Security → Finalise SSH port' để đóng nếu cần."
        else
            ok "Port 22 đã đóng — giữ nguyên."
        fi
        echo ""
        return 0
    fi

    # Fresh state — port 22 là duy nhất, cần hỏi port mới
    echo ""
    echo -e "${CYN}${BLD}━━━ SSH Port Configuration ━━━${RST}"
    echo "  Current SSH port is 22."
    echo "  A new port will be opened in addition to port 22 (transition period)."
    echo "  Port 22 will remain open until you manually close it via OPS security menu."
    echo ""

    while true; do
        read -r -p "  Enter new SSH port (> 1024, not currently in use) [default: 2222]: " NEW_SSH_PORT
        NEW_SSH_PORT="${NEW_SSH_PORT:-2222}"

        if ! [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] || (( NEW_SSH_PORT <= 1024 || NEW_SSH_PORT > 65535 )); then
            warn "Port must be a number between 1025 and 65535. Try again."
            continue
        fi

        if ss -H -ltn | awk '{print $4}' | grep -Eq "(^|:)${NEW_SSH_PORT}$"; then
            warn "Port ${NEW_SSH_PORT} is already in use. Choose a different port."
            continue
        fi

        break
    done
    export NEW_SSH_PORT
    ok "New SSH port set to: ${NEW_SSH_PORT}"

    _configure_sshd_fresh
}

# _configure_sshd_fresh: chỉ chạy khi fresh install (port 22 là duy nhất).
_configure_sshd_fresh() {
    local sshd_conf="/etc/ssh/sshd_config"
    info "Configuring sshd: adding port ${NEW_SSH_PORT} (keeping port 22 during transition)..."

    local backup="${sshd_conf}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$sshd_conf" "$backup"
    info "sshd_config backup: $backup"

    local tmp
    tmp=$(mktemp)
    {
        echo "Port 22"
        echo "Port ${NEW_SSH_PORT}"
        grep -Ev '^[[:space:]]*Port[[:space:]]+[0-9]+' "$sshd_conf"
    } > "$tmp"
    mv "$tmp" "$sshd_conf"

    systemctl reload ssh 2>/dev/null || systemctl reload sshd
    ok "sshd reloaded — now listening on ports 22 and ${NEW_SSH_PORT}."
}

configure_ufw() {
    info "Configuring UFW firewall..."

    if ! command -v ufw &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw
    fi

    ufw default deny incoming   >/dev/null
    ufw default allow outgoing  >/dev/null

    # Allow SSH port(s) per current sshd state
    if [[ -n "$NEW_SSH_PORT" ]]; then
        ufw allow "${NEW_SSH_PORT}/tcp" comment "ops: SSH port" >/dev/null
    fi

    # Allow port 22 only if sshd still has it open
    if [[ "$SSH_PORT_22_OPEN" == "yes" || "$SSH_ALREADY_CONFIGURED" == "no" ]]; then
        ufw allow 22/tcp comment "ops: SSH legacy port (transition)" >/dev/null
    fi

    ufw allow 80/tcp  comment "ops: HTTP"  >/dev/null
    ufw allow 443/tcp comment "ops: HTTPS" >/dev/null

    if ufw status 2>/dev/null | grep -qi "Status: active"; then
        info "UFW already active — rules updated."
    else
        ufw --force enable >/dev/null
    fi
    ok "UFW configured. HTTP/HTTPS open. SSH port(s) allowed per current sshd state."
}

# ── 5. Admin user ─────────────────────────────────────────────

# setup_admin_user: idempotent — skip hoàn toàn nếu user đã tồn tại.
setup_admin_user() {
    echo ""
    echo -e "${CYN}${BLD}━━━ Admin User Setup ━━━${RST}"

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
            ok "User '${ADMIN_USER}' added to sudo group."
        fi
        export ADMIN_USER
        return 0
    fi

    # User chưa tồn tại → tạo mới
    info "Creating user: ${ADMIN_USER}..."
    useradd -m -s /bin/bash "$ADMIN_USER"
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

# ── 6. Install OPS core (tarball) ─────────────────────────────
# Dùng tarball thay vì git clone — nhất quán với self-update menu 16.
# Không yêu cầu git trên VPS.

install_ops_core() {
    info "Installing OPS core to ${OPS_INSTALL_DIR} (via tarball)..."

    local tarball_url="https://github.com/${OPS_GITHUB_REPO}/archive/refs/heads/${OPS_GITHUB_BRANCH}.tar.gz"
    local tmp_dir
    tmp_dir=$(mktemp -d /tmp/ops-install-XXXXXX)
    local tarball="${tmp_dir}/ops-source.tar.gz"

    # ── Step 1: Download
    info "Downloading source tarball from GitHub..."
    if ! curl -fsSL --max-time 120 --connect-timeout 15 \
            -o "$tarball" "$tarball_url" 2>&1; then
        rm -rf "$tmp_dir"
        die "Download failed. Check network connectivity and try again."
    fi
    local size
    size=$(du -sh "$tarball" 2>/dev/null | cut -f1)
    ok "Downloaded (${size})"

    # ── Step 2: Verify
    if ! tar -tzf "$tarball" >/dev/null 2>&1; then
        rm -rf "$tmp_dir"
        die "Downloaded file is not a valid tar.gz archive. Aborting."
    fi

    # ── Step 3: Extract
    local extract_dir="${tmp_dir}/extracted"
    mkdir -p "$extract_dir"
    tar -xzf "$tarball" -C "$extract_dir" 2>/dev/null

    # GitHub tarballs extract as <repo>-<branch>/
    local source_root
    source_root=$(find "$extract_dir" -maxdepth 1 -type d -name "ops-script-*" | head -1)
    if [[ -z "$source_root" ]]; then
        rm -rf "$tmp_dir"
        die "Unexpected archive structure — expected ops-script-*/ inside tarball."
    fi

    # Runtime files are in ops/ inside tarball
    local source_ops="${source_root}/${OPS_SOURCE_SUBDIR}"
    if [[ ! -d "${source_ops}/bin" ]]; then
        rm -rf "$tmp_dir"
        die "Missing ${OPS_SOURCE_SUBDIR}/bin/ inside tarball. Archive may be corrupted."
    fi

    # ── Step 4: Apply to OPS_INSTALL_DIR
    mkdir -p "$OPS_INSTALL_DIR"

    if command -v rsync >/dev/null 2>&1; then
        rsync -a --exclude='*.log' \
            "${source_ops}/" \
            "${OPS_INSTALL_DIR}/" 2>&1 | grep -v '^sending\|^sent\|^total\|speedup' || true
    else
        cp -a "${source_ops}/." "${OPS_INSTALL_DIR}/"
    fi

    # Also copy install/ docs/ rules/ agents/ from source root (outside ops/)
    for extra_dir in install docs rules agents; do
        if [[ -d "${source_root}/${extra_dir}" ]]; then
            if command -v rsync >/dev/null 2>&1; then
                rsync -a "${source_root}/${extra_dir}/" \
                    "${OPS_INSTALL_DIR}/${extra_dir}/" 2>/dev/null || true
            else
                mkdir -p "${OPS_INSTALL_DIR}/${extra_dir}"
                cp -a "${source_root}/${extra_dir}/." "${OPS_INSTALL_DIR}/${extra_dir}/"
            fi
        fi
    done

    # ── Step 5: Permissions
    find "${OPS_INSTALL_DIR}/bin"     -type f             -exec chmod +x {} \;
    find "${OPS_INSTALL_DIR}/modules" -type f -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true
    find "${OPS_INSTALL_DIR}/core"    -type f -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true
    find "${OPS_INSTALL_DIR}/install" -type f -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true

    [[ -f "${OPS_INSTALL_DIR}/bin/ops-setup.sh" ]] \
        || die "Missing bin/ops-setup.sh after install. Tarball may be incomplete."
    chmod +x "${OPS_INSTALL_DIR}/bin/ops-setup.sh"

    # ── Step 6: Cleanup + ownership
    rm -rf "$tmp_dir"
    chown -R "${ADMIN_USER}:${ADMIN_USER}" "$OPS_INSTALL_DIR"

    ok "OPS core installed at ${OPS_INSTALL_DIR} (from tarball — no git required)."
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
        die "ops-setup.sh not found at ${setup_script}. Install may have failed."
    fi

    info "Running ops-setup.sh as root (will use ADMIN_USER=${ADMIN_USER})..."
    ADMIN_USER="$ADMIN_USER" \
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

    setup_ssh_port
    configure_ufw

    setup_admin_user

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
    echo -e "  Admin user : ${BLD}${ADMIN_USER}${RST}"
    echo -e "  SSH port   : ${BLD}${NEW_SSH_PORT:-22}${RST}"
    echo -e "  SSH command: ${CYN}${BLD}ssh -p ${NEW_SSH_PORT:-22} ${ADMIN_USER}@${SERVER_IP}${RST}"
    echo ""
    if [[ "$SSH_PORT_22_OPEN" == "yes" && "$SSH_ALREADY_CONFIGURED" == "yes" ]]; then
        echo -e "  ${YLW}⚠  Port 22 vẫn mở (transition mode).${RST}"
        echo -e "  ${YLW}   Dùng 'ops → Security → Finalise SSH port' để đóng nếu muốn.${RST}"
    elif [[ "$SSH_PORT_22_OPEN" == "no" && "$SSH_ALREADY_CONFIGURED" == "yes" ]]; then
        echo -e "  ${GRN}✓  Port 22 đã đóng — giữ nguyên.${RST}"
    else
        echo -e "  ${YLW}⚠  Port 22 remains open during transition.${RST}"
        echo -e "  ${YLW}   Use 'ops' menu → Security → Finalise SSH port to close port 22.${RST}"
    fi
    echo ""
    echo -e "  Next steps:"
    echo -e "    1. Open a NEW terminal and test:  ${CYN}ssh -p ${NEW_SSH_PORT:-22} ${ADMIN_USER}@${SERVER_IP}${RST}"
    echo -e "    2. After verifying login, run:    ${CYN}ops${RST}"
    echo -e "    3. Select 'Production Setup Wizard' to complete the stack."
    echo ""
}

main
