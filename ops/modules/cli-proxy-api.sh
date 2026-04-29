#!/usr/bin/env bash
# ============================================================
# ops/modules/cli-proxy-api.sh
# Purpose: CLIProxyAPI install, systemd service, and domain integration
# Part of: OPS - VPS Production Setup & Manager
# ============================================================
# Called by bin/ops via menu dispatch.
# Do NOT add set -euo pipefail here - inherited from bin/ops.

CLIPROXYAPI_SOURCE_REPO_URL="https://github.com/daotaolaixe-quangthang/CLIProxyAPI"
CLIPROXYAPI_RELEASE_API_URL="https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest"
CLIPROXYAPI_DIR="/opt/cli-proxy-api"
CLIPROXYAPI_RELEASES_DIR="${CLIPROXYAPI_DIR}/releases"
CLIPROXYAPI_BINARY="${CLIPROXYAPI_DIR}/cli-proxy-api"
CLIPROXYAPI_CONFIG_FILE="${CLIPROXYAPI_DIR}/config.yaml"
CLIPROXYAPI_EXAMPLE_CONFIG="${CLIPROXYAPI_DIR}/config.example.yaml"
CLIPROXYAPI_VERSION_FILE="${CLIPROXYAPI_DIR}/version.txt"
CLIPROXYAPI_SERVICE_NAME="cli-proxy-api"
CLIPROXYAPI_SERVICE_FILE="/etc/systemd/system/${CLIPROXYAPI_SERVICE_NAME}.service"
CLIPROXYAPI_STATE_FILE="${OPS_CONFIG_DIR}/cli-proxy-api.conf"
CLIPROXYAPI_CLIENT_KEY_FILE="${OPS_CONFIG_DIR}/.cli-proxy-api-key"
CLIPROXYAPI_PORT="8317"
CLIPROXYAPI_PPROF_PORT="8316"
CLIPROXYAPI_LOGS_DIR="${CLIPROXYAPI_DIR}/logs"
CLIPROXYAPI_VHOST_TEMPLATE="${OPS_ROOT}/modules/templates/nginx/cli-proxy-api.vhost.conf.tpl"
CLIPROXYAPI_QUOTA_INSPECTOR_REPO_URL="https://github.com/daotaolaixe-quangthang/CLIProxyAPI-Quota-Inspector"
CLIPROXYAPI_QUOTA_INSPECTOR_DIR="${CLIPROXYAPI_DIR}/quota-inspector"
CLIPROXYAPI_QUOTA_INSPECTOR_BINARY="${CLIPROXYAPI_QUOTA_INSPECTOR_DIR}/cpa-quota-inspector"
CLIPROXYAPI_QUOTA_INSPECTOR_GO_VERSION="1.25.0"
CLIPROXYAPI_QUOTA_INSPECTOR_GO_ROOT="/opt/ops-go/go${CLIPROXYAPI_QUOTA_INSPECTOR_GO_VERSION}"
CLIPROXYAPI_QUOTA_INSPECTOR_GO_BINARY="${CLIPROXYAPI_QUOTA_INSPECTOR_GO_ROOT}/bin/go"
CLIPROXYAPI_QUOTA_BASHRC_MARKER="# OPS: cliproxyapi quota inspector"

_cliproxyapi_runtime_user() {
    ops_runtime_user
}

_cliproxyapi_admin_home() {
    local admin_home
    admin_home=$(getent passwd "$ADMIN_USER" | cut -d: -f6 || true)
    echo "${admin_home:-/home/$ADMIN_USER}"
}

_cliproxyapi_admin_bashrc() {
    echo "$(_cliproxyapi_admin_home)/.bashrc"
}

_cliproxyapi_runtime_home() {
    ops_runtime_home "$(_cliproxyapi_runtime_user)"
}

_cliproxyapi_run_as_runtime_user() {
    local runtime_user home_dir
    runtime_user="$(_cliproxyapi_runtime_user)"
    home_dir="$(_cliproxyapi_runtime_home)"
    runuser -u "$runtime_user" -- env -i \
        HOME="$home_dir" \
        PATH="$PATH" \
        USER="$runtime_user" \
        LOGNAME="$runtime_user" \
        LANG="${LANG:-C.UTF-8}" \
        LC_ALL="${LC_ALL:-C.UTF-8}" \
        "$@"
}

_cliproxyapi_set_state() {
    local key="$1"
    local value="$2"
    ops_conf_set "cli-proxy-api.conf" "$key" "$value"
    if [[ -f "$CLIPROXYAPI_STATE_FILE" ]]; then
        chmod 640 "$CLIPROXYAPI_STATE_FILE"
        chown "$ADMIN_USER:$ADMIN_USER" "$CLIPROXYAPI_STATE_FILE"
    fi
}

_cliproxyapi_state_get() {
    local key="$1"
    ops_conf_get "cli-proxy-api.conf" "$key" 2>/dev/null || true
}

_cliproxyapi_write_quota_shell_block() {
    local admin_bashrc
    admin_bashrc="$(_cliproxyapi_admin_bashrc)"

    touch "$admin_bashrc"
    chown "$ADMIN_USER:$ADMIN_USER" "$admin_bashrc"
    if grep -q "$CLIPROXYAPI_QUOTA_BASHRC_MARKER" "$admin_bashrc" 2>/dev/null; then
        backup_file "$admin_bashrc" >/dev/null || true
        sed -i "/^${CLIPROXYAPI_QUOTA_BASHRC_MARKER}$/,/^$/d" "$admin_bashrc"
    else
        backup_file "$admin_bashrc" >/dev/null || true
    fi

    cat >> "$admin_bashrc" <<EOF

${CLIPROXYAPI_QUOTA_BASHRC_MARKER}
cpaq() {
  ${CLIPROXYAPI_QUOTA_INSPECTOR_BINARY} --summary-only --no-progress "\$@"
}
EOF
    chown "$ADMIN_USER:$ADMIN_USER" "$admin_bashrc"
}

_cliproxyapi_generate_api_key() {
    printf 'sk-%s' "$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 45)"
}

_cliproxyapi_write_client_key_file() {
    local api_key="$1"
    write_file "$CLIPROXYAPI_CLIENT_KEY_FILE" <<EOF
${api_key}
EOF
    chmod 600 "$CLIPROXYAPI_CLIENT_KEY_FILE"
    chown "$ADMIN_USER:$ADMIN_USER" "$CLIPROXYAPI_CLIENT_KEY_FILE"
}

_cliproxyapi_client_key() {
    if [[ -f "$CLIPROXYAPI_CLIENT_KEY_FILE" ]]; then
        tr -d '\r\n' < "$CLIPROXYAPI_CLIENT_KEY_FILE"
    else
        printf '%s' ""
    fi
}

_cliproxyapi_ensure_client_key() {
    local api_key
    api_key="$(_cliproxyapi_client_key)"
    if [[ -n "$api_key" ]]; then
        printf '%s' "$api_key"
        return 0
    fi

    api_key="$(_cliproxyapi_generate_api_key)"
    _cliproxyapi_write_client_key_file "$api_key"
    printf '%s' "$api_key"
}

_cliproxyapi_local_version() {
    if [[ -f "$CLIPROXYAPI_VERSION_FILE" ]]; then
        tr -d '\r\n' < "$CLIPROXYAPI_VERSION_FILE"
    else
        printf '%s' ""
    fi
}

_cliproxyapi_latest_release_json() {
    curl -fsSL --max-time 20 "$CLIPROXYAPI_RELEASE_API_URL" 2>/dev/null || true
}

_cliproxyapi_remote_version() {
    local json
    json="$(_cliproxyapi_latest_release_json)"
    if [[ -z "$json" ]]; then
        printf '%s' ""
        return 0
    fi

    printf '%s' "$json" \
        | grep -m1 '"tag_name"' \
        | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v?([^\"]+)".*/\1/'
}

_cliproxyapi_release_arch() {
    local machine
    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64)
            printf '%s' "linux_amd64"
            ;;
        aarch64|arm64)
            printf '%s' "linux_arm64"
            ;;
        *)
            return 1
            ;;
    esac
}

_cliproxyapi_version_at_least() {
    local current="$1"
    local required="$2"
    [[ "$(printf '%s\n%s\n' "$required" "$current" | sort -V | tail -n1)" == "$current" ]]
}

_cliproxyapi_go_version() {
    local go_bin="$1"
    "$go_bin" version 2>/dev/null | awk '{print $3}' | sed 's/^go//'
}

_cliproxyapi_quota_inspector_go_arch() {
    local machine
    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64)
            printf '%s' "amd64"
            ;;
        aarch64|arm64)
            printf '%s' "arm64"
            ;;
        *)
            return 1
            ;;
    esac
}

_cliproxyapi_quota_inspector_go_binary() {
    local go_bin version

    if command -v go >/dev/null 2>&1; then
        go_bin="$(command -v go)"
        version="$(_cliproxyapi_go_version "$go_bin")"
        if [[ -n "$version" ]] && _cliproxyapi_version_at_least "$version" "$CLIPROXYAPI_QUOTA_INSPECTOR_GO_VERSION"; then
            printf '%s' "$go_bin"
            return 0
        fi
    fi

    if [[ -x "$CLIPROXYAPI_QUOTA_INSPECTOR_GO_BINARY" ]]; then
        version="$(_cliproxyapi_go_version "$CLIPROXYAPI_QUOTA_INSPECTOR_GO_BINARY")"
        if [[ -n "$version" ]] && _cliproxyapi_version_at_least "$version" "$CLIPROXYAPI_QUOTA_INSPECTOR_GO_VERSION"; then
            printf '%s' "$CLIPROXYAPI_QUOTA_INSPECTOR_GO_BINARY"
            return 0
        fi
    fi

    return 1
}

_cliproxyapi_install_quota_inspector_go() {
    local go_bin arch archive download_url parent_dir temp_dir

    go_bin="$(_cliproxyapi_quota_inspector_go_binary 2>/dev/null || true)"
    if [[ -n "$go_bin" ]]; then
        printf '%s' "$go_bin"
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        apt_install curl || return 1
    fi
    if ! command -v tar >/dev/null 2>&1; then
        apt_install tar || return 1
    fi

    arch="$(_cliproxyapi_quota_inspector_go_arch)" || {
        log_error "Unsupported architecture for Go toolchain: $(uname -m)"
        return 1
    }

    archive="go${CLIPROXYAPI_QUOTA_INSPECTOR_GO_VERSION}.linux-${arch}.tar.gz"
    download_url="https://go.dev/dl/${archive}"
    parent_dir="$(dirname "$CLIPROXYAPI_QUOTA_INSPECTOR_GO_ROOT")"
    temp_dir="$(mktemp -d /tmp/ops-go-XXXXXX)"

    mkdir -p "$parent_dir"
    log_info "Installing Go ${CLIPROXYAPI_QUOTA_INSPECTOR_GO_VERSION} for Quota Inspector"

    if ! curl -fsSL "$download_url" -o "${temp_dir}/${archive}"; then
        rm -rf "$temp_dir"
        log_error "Failed to download Go toolchain from ${download_url}"
        return 1
    fi

    if ! tar -xzf "${temp_dir}/${archive}" -C "$temp_dir"; then
        rm -rf "$temp_dir"
        log_error "Failed to extract Go toolchain"
        return 1
    fi

    rm -rf "$CLIPROXYAPI_QUOTA_INSPECTOR_GO_ROOT"
    mv "${temp_dir}/go" "$CLIPROXYAPI_QUOTA_INSPECTOR_GO_ROOT"
    rm -rf "$temp_dir"

    printf '%s' "$CLIPROXYAPI_QUOTA_INSPECTOR_GO_BINARY"
}

_cliproxyapi_release_asset_url() {
    local version="$1"
    local arch="$2"
    local json line
    json="$(_cliproxyapi_latest_release_json)"
    if [[ -z "$json" ]]; then
        return 1
    fi

    line=$(printf '%s' "$json" \
        | grep -o "\"browser_download_url\"[[:space:]]*:[[:space:]]*\"[^\"]*CLIProxyAPI_${version}_${arch}\\.tar\\.gz\"" \
        | head -n1 || true)
    if [[ -z "$line" ]]; then
        return 1
    fi

    printf '%s' "$line" | sed -E 's/.*"([^\"]+)".*/\1/'
}

_cliproxyapi_prepare_directories() {
    local runtime_user runtime_home auth_dir
    runtime_user="$(_cliproxyapi_runtime_user)"
    runtime_home="$(_cliproxyapi_runtime_home)"
    auth_dir="${runtime_home}/.cli-proxy-api"

    ensure_dir "$OPS_CONFIG_DIR"
    mkdir -p "$CLIPROXYAPI_DIR" "$CLIPROXYAPI_RELEASES_DIR" "$CLIPROXYAPI_LOGS_DIR" "$auth_dir"
    chown -R "$runtime_user:$runtime_user" "$CLIPROXYAPI_DIR" "$auth_dir"
    chmod 750 "$auth_dir"
}

_cliproxyapi_install_latest_release() {
    local arch version asset_url archive release_dir temp_dir binary_source config_source runtime_user
    runtime_user="$(_cliproxyapi_runtime_user)"

    if ! command -v curl >/dev/null 2>&1; then
        apt_install curl
    fi
    if ! command -v tar >/dev/null 2>&1; then
        apt_install tar
    fi

    arch="$(_cliproxyapi_release_arch)" || {
        log_error "Unsupported architecture: $(uname -m)"
        return 1
    }

    version="$(_cliproxyapi_remote_version)"
    if [[ -z "$version" ]]; then
        log_error "Could not resolve latest CLIProxyAPI release"
        return 1
    fi

    asset_url="$(_cliproxyapi_release_asset_url "$version" "$arch")"
    if [[ -z "$asset_url" ]]; then
        log_error "Could not find release asset for ${arch}"
        return 1
    fi

    _cliproxyapi_prepare_directories

    archive="$(mktemp /tmp/cli-proxy-api-XXXXXX.tar.gz)"
    temp_dir="$(mktemp -d /tmp/cli-proxy-api-XXXXXX)"
    release_dir="${CLIPROXYAPI_RELEASES_DIR}/${version}"

    log_info "Downloading CLIProxyAPI ${version} from ${asset_url}"
    curl -fsSL "$asset_url" -o "$archive"

    rm -rf "$release_dir"
    mkdir -p "$release_dir"
    tar -xzf "$archive" -C "$temp_dir"
    cp -a "$temp_dir"/. "$release_dir"/

    binary_source=$(find "$release_dir" -maxdepth 4 -type f \( -name 'CLIProxyAPI' -o -name 'cli-proxy-api' \) | head -n1 || true)
    if [[ -z "$binary_source" ]]; then
        rm -f "$archive"
        rm -rf "$temp_dir"
        log_error "CLIProxyAPI binary not found in release archive"
        return 1
    fi

    cp "$binary_source" "$CLIPROXYAPI_BINARY"
    chmod 755 "$CLIPROXYAPI_BINARY"

    config_source=$(find "$release_dir" -maxdepth 4 -type f -name 'config.example.yaml' | head -n1 || true)
    if [[ -n "$config_source" ]]; then
        cp "$config_source" "$CLIPROXYAPI_EXAMPLE_CONFIG"
        chown "$runtime_user:$runtime_user" "$CLIPROXYAPI_EXAMPLE_CONFIG"
        chmod 640 "$CLIPROXYAPI_EXAMPLE_CONFIG"
    fi

    write_file "$CLIPROXYAPI_VERSION_FILE" <<EOF
${version}
EOF
    chown "$runtime_user:$runtime_user" "$CLIPROXYAPI_VERSION_FILE"
    chmod 640 "$CLIPROXYAPI_VERSION_FILE"
    chown -R "$runtime_user:$runtime_user" "$CLIPROXYAPI_DIR"

    rm -f "$archive"
    rm -rf "$temp_dir"

    printf '%s' "$version"
}

_cliproxyapi_write_config() {
    local runtime_user runtime_home require_api_key request_logs api_keys_yaml logs_max_total_size_mb
    runtime_user="$(_cliproxyapi_runtime_user)"
    runtime_home="$(_cliproxyapi_runtime_home)"
    require_api_key="$(_cliproxyapi_state_get CLIPROXYAPI_REQUIRE_API_KEY)"
    request_logs="$(_cliproxyapi_state_get CLIPROXYAPI_REQUEST_LOGS)"

    api_keys_yaml="api-keys: []"
    if [[ "$require_api_key" == "yes" ]]; then
        api_keys_yaml=$(cat <<EOF
api-keys:
  - "$(_cliproxyapi_ensure_client_key)"
EOF
)
    fi

    logs_max_total_size_mb=0
    if [[ "$request_logs" == "yes" ]]; then
        logs_max_total_size_mb=500
    fi

    backup_file "$CLIPROXYAPI_CONFIG_FILE" >/dev/null || true
    write_file "$CLIPROXYAPI_CONFIG_FILE" <<EOF
host: "127.0.0.1"
port: ${CLIPROXYAPI_PORT}
tls:
  enable: false
  cert: ""
  key: ""
remote-management:
  allow-remote: false
  secret-key: ""
  disable-control-panel: false
  panel-github-repository: "https://github.com/router-for-me/Cli-Proxy-API-Management-Center"
auth-dir: "${runtime_home}/.cli-proxy-api"
${api_keys_yaml}
debug: false
pprof:
  enable: false
  addr: "127.0.0.1:${CLIPROXYAPI_PPROF_PORT}"
commercial-mode: false
logging-to-file: $( [[ "$request_logs" == "yes" ]] && printf 'true' || printf 'false' )
logs-max-total-size-mb: ${logs_max_total_size_mb}
error-logs-max-files: 10
usage-statistics-enabled: false
proxy-url: ""
force-model-prefix: false
passthrough-headers: true
request-retry: 3
max-retry-credentials: 0
max-retry-interval: 30
disable-cooling: false
quota-exceeded:
  switch-project: true
  switch-preview-model: true
  antigravity-credits: true
routing:
  strategy: "round-robin"
  session-affinity: true
  session-affinity-ttl: "12h"
ws-auth: false
enable-gemini-cli-endpoint: false
nonstream-keepalive-interval: 30
streaming:
  keepalive-seconds: 30
  bootstrap-retries: 3
oauth-model-alias:
  codex:
    - name: "gpt-5.4"
      alias: "claude-opus-4-5-20251101"
    - name: "gpt-5.4"
      alias: "claude-sonnet-4-6"
    - name: "gpt-5.4-mini"
      alias: "claude-haiku-4-5-20251001"
    - name: "gpt-5.4-mini"
      alias: "claude-3-5-haiku-20241022"
    - name: "gpt-5.3-codex"
      alias: "claude-sonnet-4-5"
  antigravity:
    - name: "claude-sonnet-4-6"
      alias: "claude-opus-4-5-20251101"
    - name: "claude-sonnet-4-6"
      alias: "claude-opus-4-7"
    - name: "claude-sonnet-4-6"
      alias: "claude-sonnet-4-6"
    - name: "claude-sonnet-4-6"
      alias: "claude-haiku-4-5-20251001"
payload:
  filter:
    - models:
        - name: "*"
          protocol: "antigravity"
      params:
        - "tools.#.input_schema.propertyNames"
        - "tools.#.input_schema.additionalProperties"
        - "tools.#.input_schema.patternProperties"
EOF
    chown "$runtime_user:$runtime_user" "$CLIPROXYAPI_CONFIG_FILE"
    chmod 640 "$CLIPROXYAPI_CONFIG_FILE"
}

_cliproxyapi_write_service() {
    local runtime_user runtime_home
    runtime_user="$(_cliproxyapi_runtime_user)"
    runtime_home="$(_cliproxyapi_runtime_home)"

    backup_file "$CLIPROXYAPI_SERVICE_FILE" >/dev/null || true
    write_file "$CLIPROXYAPI_SERVICE_FILE" <<EOF
[Unit]
Description=CLIProxyAPI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${runtime_user}
Group=${runtime_user}
WorkingDirectory=${CLIPROXYAPI_DIR}
Environment=HOME=${runtime_home}
ExecStart=${CLIPROXYAPI_BINARY}
Restart=on-failure
RestartSec=10
NoNewPrivileges=true
PrivateTmp=true
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$CLIPROXYAPI_SERVICE_FILE"
    systemctl daemon-reload
}

_cliproxyapi_assert_ufw_closed() {
    local ufw_out ufw_recheck
    ufw_out=$(ufw status 2>/dev/null || true)

    if printf '%s\n' "$ufw_out" | grep -Eq "8317.*ALLOW|ALLOW.*8317"; then
        log_warn "Security invariant: UFW has an ALLOW rule for port 8317 - removing it automatically"
        ufw delete allow 8317/tcp >/dev/null 2>&1 || true
        ufw delete allow 8317 >/dev/null 2>&1 || true
        ufw delete allow 8317/udp >/dev/null 2>&1 || true
        ufw_recheck=$(ufw status 2>/dev/null || true)
        if printf '%s\n' "$ufw_recheck" | grep -Eq "8317.*ALLOW|ALLOW.*8317"; then
            log_error "Security invariant violation: UFW still has an ALLOW rule for port 8317"
            print_error "Port 8317 is publicly allowed in UFW. Remove it manually: sudo ufw delete allow 8317/tcp"
            return 1
        fi
        log_info "UFW ALLOW rule for port 8317 removed automatically"
    fi

    if printf '%s\n' "$ufw_out" | grep -Eq "8317.*DENY|DENY.*8317"; then
        log_info "Removing stale UFW DENY rule for port 8317"
        ufw delete deny 8317/tcp >/dev/null 2>&1 || true
        ufw delete deny 8317 >/dev/null 2>&1 || true
        ufw delete deny 8317/udp >/dev/null 2>&1 || true
    fi

    log_info "Verified UFW: no rule exposes port 8317"
    return 0
}

_cliproxyapi_ssl_cert_ready() {
    local domain="$1"
    [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]] && [[ -f "/etc/letsencrypt/live/${domain}/privkey.pem" ]]
}

_cliproxyapi_remove_legacy_domain_files() {
    : # no-op on fresh installs
}

_cliproxyapi_render_vhost() {
    local domain="$1"
    local vhost_path enabled_path ssl_http_block ssl_https_block ssl_enabled
    vhost_path="/etc/nginx/sites-available/cli-proxy-api.${domain}"
    enabled_path="/etc/nginx/sites-enabled/cli-proxy-api.${domain}"
    ssl_enabled="no"
    ssl_http_block=""
    ssl_https_block=""

    if [[ ! -f "$CLIPROXYAPI_VHOST_TEMPLATE" ]]; then
        log_error "Missing nginx template: ${CLIPROXYAPI_VHOST_TEMPLATE}"
        return 1
    fi

    if _cliproxyapi_ssl_cert_ready "$domain"; then
        ssl_enabled="yes"
        ssl_http_block="    return 301 https://\$host\$request_uri;"
        ssl_https_block=$(cat <<EOF
server {
    listen 443 ssl;
    http2 on;
    server_name ${domain};

    access_log /var/log/nginx/cli-proxy-api.access.log;
    error_log  /var/log/nginx/cli-proxy-api.error.log;

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    add_header Content-Security-Policy "default-src 'self'; frame-ancestors 'none'" always;
    add_header Permissions-Policy        "geolocation=(), microphone=(), camera=(), payment=(), usb=()" always;
    add_header X-XSS-Protection          "1; mode=block" always;
    add_header Referrer-Policy           "strict-origin-when-cross-origin" always;
    add_header X-Content-Type-Options    "nosniff" always;
    add_header X-Frame-Options           "SAMEORIGIN" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    location / {
        proxy_pass         http://127.0.0.1:${CLIPROXYAPI_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection 'upgrade';
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;

        proxy_connect_timeout 10s;
        proxy_read_timeout    120s;
        proxy_send_timeout    60s;
        proxy_buffering       off;
    }
}
EOF
)
    fi

    backup_file "$vhost_path" >/dev/null || true
    render_template "$CLIPROXYAPI_VHOST_TEMPLATE" \
        "DOMAIN=${domain}" \
        "CLIPROXYAPI_PORT=${CLIPROXYAPI_PORT}" \
        "SSL_HTTP_BLOCK=${ssl_http_block}" \
        "SSL_HTTPS_BLOCK=${ssl_https_block}" \
        | write_file "$vhost_path"

    safe_symlink "$vhost_path" "$enabled_path"
    _cliproxyapi_remove_legacy_domain_files "$domain"
    printf '%s' "$ssl_enabled"
}

_cliproxyapi_show_login_guidance() {
    local runtime_user runtime_home
    runtime_user="$(_cliproxyapi_runtime_user)"
    runtime_home="$(_cliproxyapi_runtime_home)"

    echo ""
    echo "Next auth/bootstrap commands:"
    echo "  Antigravity : sudo -u ${runtime_user} env HOME=${runtime_home} ${CLIPROXYAPI_BINARY} --antigravity-login"
    echo "  Gemini      : sudo -u ${runtime_user} env HOME=${runtime_home} ${CLIPROXYAPI_BINARY} --login"
    echo "  Claude Code : sudo -u ${runtime_user} env HOME=${runtime_home} ${CLIPROXYAPI_BINARY} --claude-login"
    echo "  Codex       : sudo -u ${runtime_user} env HOME=${runtime_home} ${CLIPROXYAPI_BINARY} --codex-login"
    echo ""
    echo "Source repo: ${CLIPROXYAPI_SOURCE_REPO_URL}"
    echo "Config file: ${CLIPROXYAPI_CONFIG_FILE}"
    echo "Local endpoint: http://127.0.0.1:${CLIPROXYAPI_PORT}/v1"
}

install_cliproxyapi_quota_inspector() {
    print_section "Install CLIProxyAPI-Quota-Inspector"
    require_root || return 1

    local go_bin runtime_user
    runtime_user="$(_cliproxyapi_runtime_user)"

    if ! command -v git >/dev/null 2>&1; then
        apt_install git || return 1
    fi

    go_bin="$(_cliproxyapi_install_quota_inspector_go)" || return 1
    mkdir -p "$CLIPROXYAPI_DIR"

    if [[ -d "${CLIPROXYAPI_QUOTA_INSPECTOR_DIR}/.git" ]]; then
        log_info "Updating Quota Inspector repo..."
        if ! git -C "$CLIPROXYAPI_QUOTA_INSPECTOR_DIR" pull --ff-only; then
            log_error "Failed to update Quota Inspector repo"
            return 1
        fi
    elif [[ -d "$CLIPROXYAPI_QUOTA_INSPECTOR_DIR" ]]; then
        log_error "${CLIPROXYAPI_QUOTA_INSPECTOR_DIR} exists but is not a git repo"
        return 1
    else
        log_info "Cloning Quota Inspector repo..."
        if ! git clone --depth=1 "$CLIPROXYAPI_QUOTA_INSPECTOR_REPO_URL" "$CLIPROXYAPI_QUOTA_INSPECTOR_DIR"; then
            log_error "Failed to clone Quota Inspector repo"
            return 1
        fi
    fi

    log_info "Building Quota Inspector binary..."
    if ! (
        cd "$CLIPROXYAPI_QUOTA_INSPECTOR_DIR" &&
        GOTOOLCHAIN=local "$go_bin" build -o "$CLIPROXYAPI_QUOTA_INSPECTOR_BINARY" .
    ); then
        log_error "Failed to build Quota Inspector binary"
        return 1
    fi

    chmod 755 "$CLIPROXYAPI_QUOTA_INSPECTOR_BINARY"
    chown -R "$runtime_user:$runtime_user" "$CLIPROXYAPI_QUOTA_INSPECTOR_DIR"
    _cliproxyapi_write_quota_shell_block

    print_ok "CLIProxyAPI-Quota-Inspector installed"
    echo "  Repo   : ${CLIPROXYAPI_QUOTA_INSPECTOR_DIR}"
    echo "  Binary : ${CLIPROXYAPI_QUOTA_INSPECTOR_BINARY}"
    echo "  Shell  : cpaq (installed into $(_cliproxyapi_admin_bashrc))"
    echo "  Reload : source ~/.bashrc"
    echo "  Run    : cpaq"
    echo "  Note   : Nếu CPA bật management auth thì export CPA_MANAGEMENT_KEY rồi chạy lại"
}

install_cliproxyapi() {
    print_section "Install CLIProxyAPI"
    require_root || return 1

    if [[ -x "$CLIPROXYAPI_BINARY" ]]; then
        print_warn "CLIProxyAPI is already installed at ${CLIPROXYAPI_DIR}."
        if ! prompt_confirm "Cài lại từ đầu?"; then
            print_warn "Installation cancelled."
            return 0
        fi
        service_stop "$CLIPROXYAPI_SERVICE_NAME" >/dev/null 2>&1 || true
    fi

    local version
    version="$(_cliproxyapi_install_latest_release)" || return 1

    if [[ -z "$(_cliproxyapi_state_get CLIPROXYAPI_REQUIRE_API_KEY)" ]]; then
        _cliproxyapi_set_state "CLIPROXYAPI_REQUIRE_API_KEY" "no"
    fi
    if [[ -z "$(_cliproxyapi_state_get CLIPROXYAPI_REQUEST_LOGS)" ]]; then
        _cliproxyapi_set_state "CLIPROXYAPI_REQUEST_LOGS" "no"
    fi

    _cliproxyapi_write_config
    _cliproxyapi_write_service

    service_enable "$CLIPROXYAPI_SERVICE_NAME"
    service_restart "$CLIPROXYAPI_SERVICE_NAME" 30 || service_start "$CLIPROXYAPI_SERVICE_NAME"

    _cliproxyapi_set_state "CLIPROXYAPI_INSTALLED" "yes"
    _cliproxyapi_set_state "CLIPROXYAPI_VERSION" "$version"
    _cliproxyapi_set_state "CLIPROXYAPI_PORT" "$CLIPROXYAPI_PORT"
    _cliproxyapi_set_state "CLIPROXYAPI_SERVICE_NAME" "$CLIPROXYAPI_SERVICE_NAME"
    _cliproxyapi_set_state "CLIPROXYAPI_RUNTIME_USER" "$(_cliproxyapi_runtime_user)"
    _cliproxyapi_set_state "CLIPROXYAPI_CONFIG_FILE" "$CLIPROXYAPI_CONFIG_FILE"
    _cliproxyapi_set_state "CLIPROXYAPI_AUTH_DIR" "$(_cliproxyapi_runtime_home)/.cli-proxy-api"
    _cliproxyapi_set_state "CLIPROXYAPI_INSTALL_DATE" "$(date +%F)"

    [[ -n "$(_cliproxyapi_state_get CLIPROXYAPI_DOMAIN)" ]] || _cliproxyapi_set_state "CLIPROXYAPI_DOMAIN" ""
    [[ -n "$(_cliproxyapi_state_get CLIPROXYAPI_SSL)" ]] || _cliproxyapi_set_state "CLIPROXYAPI_SSL" "no"

    _cliproxyapi_assert_ufw_closed || return 1
    print_ok "CLIProxyAPI installed and registered in systemd"
    _cliproxyapi_show_login_guidance

    if prompt_confirm "Cài thêm CLIProxyAPI-Quota-Inspector để check quota?"; then
        if ! install_cliproxyapi_quota_inspector; then
            print_warn "CLIProxyAPI đã cài xong nhưng Quota Inspector chưa cài được."
        fi
    fi
}

update_cliproxyapi() {
    print_section "Update CLIProxyAPI"
    require_root || return 1

    if [[ ! -x "$CLIPROXYAPI_BINARY" ]]; then
        log_error "CLIProxyAPI is not installed in ${CLIPROXYAPI_DIR}"
        return 1
    fi

    local local_ver remote_ver was_active version
    local_ver="$(_cliproxyapi_local_version)"
    remote_ver="$(_cliproxyapi_remote_version)"

    if [[ -n "$local_ver" && -n "$remote_ver" ]]; then
        echo "  Installed : ${local_ver}"
        echo "  Available : ${remote_ver}"
        if [[ "$local_ver" == "$remote_ver" ]]; then
            print_ok "CLIProxyAPI is already up to date (${local_ver})"
            if ! prompt_confirm "Update anyway?"; then
                return 0
            fi
        else
            print_warn "New version available: ${local_ver} -> ${remote_ver}"
        fi
    else
        log_warn "Could not compare versions; proceeding with update"
    fi

    was_active="no"
    if service_active "$CLIPROXYAPI_SERVICE_NAME"; then
        was_active="yes"
        service_stop "$CLIPROXYAPI_SERVICE_NAME" || true
    fi

    version="$(_cliproxyapi_install_latest_release)" || return 1
    _cliproxyapi_write_config
    _cliproxyapi_write_service

    if [[ "$was_active" == "yes" ]]; then
        service_start "$CLIPROXYAPI_SERVICE_NAME"
    fi

    _cliproxyapi_set_state "CLIPROXYAPI_VERSION" "$version"
    _cliproxyapi_assert_ufw_closed || return 1
    print_ok "CLIProxyAPI updated to ${version}"
}

link_cliproxyapi_domain() {
    require_root || return 1
    local domain="${1:-}"
    if [[ -z "$domain" ]]; then
        prompt_input "Enter domain for CLIProxyAPI"
        domain="${REPLY:-}"
    fi

    if [[ -z "$domain" ]]; then
        log_error "Domain is required"
        return 1
    fi

    create_default_deny

    local ssl_enabled
    ssl_enabled="$(_cliproxyapi_render_vhost "$domain")" || return 1

    nginx -t
    service_enable nginx
    service_reload nginx

    _cliproxyapi_set_state "CLIPROXYAPI_DOMAIN" "$domain"
    _cliproxyapi_set_state "CLIPROXYAPI_SSL" "$ssl_enabled"

    _cliproxyapi_assert_ufw_closed || return 1
    print_ok "CLIProxyAPI linked to domain: ${domain}"
}

_cliproxyapi_activate_api_key() {
    require_root || return 1
    if [[ ! -x "$CLIPROXYAPI_BINARY" ]]; then
        return 0
    fi
    _cliproxyapi_ensure_client_key > /dev/null
    _cliproxyapi_set_state "CLIPROXYAPI_REQUIRE_API_KEY" "yes"
    _cliproxyapi_write_config
    if service_active "$CLIPROXYAPI_SERVICE_NAME"; then
        service_restart "$CLIPROXYAPI_SERVICE_NAME" 10
        log_info "CLIProxyAPI reloaded with API key enabled"
    fi
}

toggle_cliproxyapi_api_key() {
    require_root || return 1
    local mode="${1:-}"
    local state_value

    case "$mode" in
        on)  state_value="yes" ;;
        off) state_value="no" ;;
        *)
            print_error "Usage: toggle_cliproxyapi_api_key <on|off>"
            return 1
            ;;
    esac

    if [[ ! -x "$CLIPROXYAPI_BINARY" ]]; then
        log_error "Install CLIProxyAPI first."
        return 1
    fi

    _cliproxyapi_set_state "CLIPROXYAPI_REQUIRE_API_KEY" "$state_value"
    _cliproxyapi_write_config
    service_restart "$CLIPROXYAPI_SERVICE_NAME" 30

    _cliproxyapi_assert_ufw_closed || return 1
    print_ok "API key requirement ${state_value}"
    if [[ "$state_value" == "yes" ]]; then
        print_warn "Client API key saved at ${CLIPROXYAPI_CLIENT_KEY_FILE}"
    fi
}

toggle_cliproxyapi_request_logs() {
    require_root || return 1
    local mode="${1:-}"
    local state_value

    case "$mode" in
        on)  state_value="yes" ;;
        off) state_value="no" ;;
        *)
            print_error "Usage: toggle_cliproxyapi_request_logs <on|off>"
            return 1
            ;;
    esac

    if [[ ! -x "$CLIPROXYAPI_BINARY" ]]; then
        log_error "Install CLIProxyAPI first."
        return 1
    fi

    _cliproxyapi_set_state "CLIPROXYAPI_REQUEST_LOGS" "$state_value"
    _cliproxyapi_write_config
    service_restart "$CLIPROXYAPI_SERVICE_NAME" 30

    _cliproxyapi_assert_ufw_closed || return 1
    print_ok "Request logging ${state_value}"
}

_cliproxyapi_verify_models_json() {
    local api_key curl_args response
    api_key="$(_cliproxyapi_client_key)"
    curl_args=( -fsS --max-time 5 )
    if [[ "$(_cliproxyapi_state_get CLIPROXYAPI_REQUIRE_API_KEY)" == "yes" ]] && [[ -n "$api_key" ]]; then
        curl_args+=( -H "Authorization: Bearer ${api_key}" )
    fi

    response=$(curl "${curl_args[@]}" "http://127.0.0.1:${CLIPROXYAPI_PORT}/v1/models" 2>/dev/null || true)
    if [[ -z "$response" ]]; then
        return 1
    fi
    printf '%s' "$response" | grep -qE '^[[:space:]]*[\[{]'
}

verify_cliproxyapi() {
    print_section "Verify CLIProxyAPI"
    require_root || { log_error "Must run as root"; return 0; }

    local all_ok=true

    if ! service_active "$CLIPROXYAPI_SERVICE_NAME"; then
        log_error "Service ${CLIPROXYAPI_SERVICE_NAME} is not active"
        all_ok=false
    else
        print_ok "Systemd service is active"
    fi

    local listening_public listening_local
    listening_public=$(ss -tln 2>/dev/null | awk '$4 ~ /:8317$/ {print $4}' | grep -E '(^0\.0\.0\.0:8317$|^\[::\]:8317$)' || true)
    listening_local=$(ss -tln 2>/dev/null | awk '$4 ~ /:8317$/ {print $4}' | grep -E '(^127\.0\.0\.1:8317$|^\[::1\]:8317$)' || true)

    if [[ -n "$listening_public" ]]; then
        log_error "CLIProxyAPI is binding publicly on 8317 (${listening_public})"
        all_ok=false
    elif [[ -z "$listening_local" ]]; then
        log_error "CLIProxyAPI is not listening on loopback 8317"
        all_ok=false
    else
        print_ok "Service is listening on loopback only"
    fi

    if ! _cliproxyapi_verify_models_json; then
        log_error "Local /v1/models did not return JSON"
        all_ok=false
    else
        print_ok "Local /v1/models endpoint returned JSON"
    fi

    _cliproxyapi_assert_ufw_closed || true

    if [[ "$all_ok" == "true" ]]; then
        print_ok "Verification passed"
    else
        log_warn "Verification completed with errors. See above."
    fi
    return 0
}

cliproxyapi_start() {
    print_section "Start CLIProxyAPI"
    require_root || return 1
    service_start "$CLIPROXYAPI_SERVICE_NAME"
    sleep 2
    if ! service_active "$CLIPROXYAPI_SERVICE_NAME"; then
        log_error "CLIProxyAPI is not active after start. Last journal entries:"
        journalctl -u "$CLIPROXYAPI_SERVICE_NAME" -n 20 --no-pager 2>/dev/null || true
        return 1
    fi
    print_ok "CLIProxyAPI is active"
    _cliproxyapi_assert_ufw_closed
}

cliproxyapi_stop() {
    print_section "Stop CLIProxyAPI"
    require_root || return 1
    service_stop "$CLIPROXYAPI_SERVICE_NAME"
}

cliproxyapi_restart() {
    print_section "Restart CLIProxyAPI"
    require_root || return 1
    service_restart "$CLIPROXYAPI_SERVICE_NAME" 30
    _cliproxyapi_assert_ufw_closed
}

cliproxyapi_status() {
    print_section "CLIProxyAPI Status"
    service_status "$CLIPROXYAPI_SERVICE_NAME" || true
    _cliproxyapi_assert_ufw_closed || true
}

cliproxyapi_logs() {
    print_section "CLIProxyAPI Logs"
    journalctl -u "$CLIPROXYAPI_SERVICE_NAME" -n 50 --no-pager || true
}

_cliproxyapi_show_status() {
    local installed_label domain ssl_val domain_label service_status_label api_key_label request_logs_label local_ver

    if [[ -x "$CLIPROXYAPI_BINARY" ]]; then
        local_ver="$(_cliproxyapi_local_version)"
        installed_label="Installed (${CLIPROXYAPI_DIR}) v${local_ver:-?}"
    else
        installed_label="Not installed"
    fi

    domain="$(_cliproxyapi_state_get CLIPROXYAPI_DOMAIN)"
    if [[ -n "$domain" ]]; then
        ssl_val="$(_cliproxyapi_state_get CLIPROXYAPI_SSL)"
        if [[ "$ssl_val" == "yes" ]]; then
            domain_label="${domain} (SSL)"
        else
            domain_label="${domain} (no SSL)"
        fi
    else
        domain_label="not configured"
    fi

    service_status_label=$(systemctl is-active "$CLIPROXYAPI_SERVICE_NAME" 2>/dev/null || echo "inactive")

    if [[ "$(_cliproxyapi_state_get CLIPROXYAPI_REQUIRE_API_KEY)" == "yes" ]]; then
        api_key_label="enabled"
    else
        api_key_label="disabled"
    fi

    if [[ "$(_cliproxyapi_state_get CLIPROXYAPI_REQUEST_LOGS)" == "yes" ]]; then
        request_logs_label="enabled"
    else
        request_logs_label="disabled"
    fi

    echo "  Installation  : ${installed_label}"
    echo "  Source repo    : ${CLIPROXYAPI_SOURCE_REPO_URL}"
    echo "  Local address  : 127.0.0.1:${CLIPROXYAPI_PORT}"
    echo "  Domain         : ${domain_label}"
    echo "  Service        : ${service_status_label}"
    echo "  API Key        : ${api_key_label}"
    echo "  Request logs   : ${request_logs_label}"
    echo ""
}

bootstrap_cliproxyapi_auth() {
    local provider="${1:-all}"
    local runtime_user runtime_home all_ok
    runtime_user="$(_cliproxyapi_runtime_user)"
    runtime_home="$(_cliproxyapi_runtime_home)"
    all_ok=true

    if [[ ! -x "$CLIPROXYAPI_BINARY" ]]; then
        log_error "CLIProxyAPI binary not found. Install first."
        return 1
    fi

    case "$provider" in
        antigravity)
            log_info "Launching Antigravity provider login as ${runtime_user} ..."
            _cliproxyapi_run_as_runtime_user bash -c "cd '${CLIPROXYAPI_DIR}' && '${CLIPROXYAPI_BINARY}' --antigravity-login"
            ;;
        gemini|login)
            log_info "Launching Gemini provider login as ${runtime_user} ..."
            _cliproxyapi_run_as_runtime_user bash -c "cd '${CLIPROXYAPI_DIR}' && '${CLIPROXYAPI_BINARY}' --login"
            ;;
        claude|claude-code)
            log_info "Launching Claude Code provider login as ${runtime_user} ..."
            _cliproxyapi_run_as_runtime_user bash -c "cd '${CLIPROXYAPI_DIR}' && '${CLIPROXYAPI_BINARY}' --claude-login"
            ;;
        codex)
            log_info "Launching Codex provider login as ${runtime_user} ..."
            _cliproxyapi_run_as_runtime_user bash -c "cd '${CLIPROXYAPI_DIR}' && '${CLIPROXYAPI_BINARY}' --codex-login"
            ;;
        all|*)
            log_info "Launching Antigravity provider login as ${runtime_user} ..."
            if ! _cliproxyapi_run_as_runtime_user bash -c "cd '${CLIPROXYAPI_DIR}' && '${CLIPROXYAPI_BINARY}' --antigravity-login"; then
                all_ok=false
            fi
            echo ""
            log_info "Launching Gemini provider login as ${runtime_user} ..."
            if ! _cliproxyapi_run_as_runtime_user bash -c "cd '${CLIPROXYAPI_DIR}' && '${CLIPROXYAPI_BINARY}' --login"; then
                all_ok=false
            fi
            echo ""
            log_info "Launching Claude Code provider login as ${runtime_user} ..."
            if ! _cliproxyapi_run_as_runtime_user bash -c "cd '${CLIPROXYAPI_DIR}' && '${CLIPROXYAPI_BINARY}' --claude-login"; then
                all_ok=false
            fi
            echo ""
            log_info "Launching Codex provider login as ${runtime_user} ..."
            if ! _cliproxyapi_run_as_runtime_user bash -c "cd '${CLIPROXYAPI_DIR}' && '${CLIPROXYAPI_BINARY}' --codex-login"; then
                all_ok=false
            fi
            ;;
    esac
    echo ""
    if [[ "$all_ok" != "true" ]]; then
        log_error "Auth bootstrap failed for one or more providers. Auth state is stored at ${runtime_home}/.cli-proxy-api"
        return 1
    fi
    log_info "Auth bootstrap complete. Auth stored at ${runtime_home}/.cli-proxy-api"
}

menu_cliproxyapi_bootstrap_auth() {
    while true; do
        print_section "Bootstrap auth providers"
        echo "  1) Antigravity"
        echo "  2) Gemini"
        echo "  3) Claude Code"
        echo "  4) Codex"
        echo ""
        echo "  Ghi chú:"
        echo "    Antigravity = --antigravity-login"
        echo "    Gemini      = --login"
        echo "    Claude Code = --claude-login"
        echo "    Codex       = --codex-login"
        echo ""
        echo "  0) Back"
        echo ""
        printf "  Select: " > /dev/tty
        local choice
        read -r choice < /dev/tty
        case "$choice" in
            1) bootstrap_cliproxyapi_auth antigravity; press_enter ;;
            2) bootstrap_cliproxyapi_auth gemini; press_enter ;;
            3) bootstrap_cliproxyapi_auth claude-code; press_enter ;;
            4) bootstrap_cliproxyapi_auth codex; press_enter ;;
            0) return 0 ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}

check_cliproxyapi_quota() {
    print_section "Check CLIProxyAPI quota"
    require_root || return 1

    if [[ ! -x "$CLIPROXYAPI_BINARY" ]]; then
        log_error "Install CLIProxyAPI first."
        return 1
    fi

    if [[ ! -x "$CLIPROXYAPI_QUOTA_INSPECTOR_BINARY" ]]; then
        print_warn "CLIProxyAPI-Quota-Inspector is not installed."
        if ! prompt_confirm "Cài ngay bây giờ?"; then
            return 0
        fi
        install_cliproxyapi_quota_inspector || return 1
    fi

    _cliproxyapi_write_quota_shell_block

    if ! service_active "$CLIPROXYAPI_SERVICE_NAME"; then
        print_warn "CLIProxyAPI service is not active. Kết quả có thể thất bại."
    fi

    if ! "$CLIPROXYAPI_QUOTA_INSPECTOR_BINARY" --summary-only --no-progress; then
        log_error "Quota check failed"
        if [[ -z "${CPA_MANAGEMENT_KEY:-}" && -z "${MANAGEMENT_PASSWORD:-}" ]]; then
            print_warn "Nếu CPA bật management auth, hãy export CPA_MANAGEMENT_KEY rồi chạy lại."
        fi
        return 1
    fi

    echo ""
    echo "  Gợi ý dùng nhanh:"
    echo "  cpaq --filter-provider codex"
    echo "  cpaq --filter-provider gemini-cli"
}

menu_cliproxyapi() {
    _cliproxyapi_menu_run() {
        "$@"
        return 0
    }

    while true; do
        print_section "CLIProxyAPI Management"
        _cliproxyapi_show_status
        echo "  1) Install CLIProxyAPI"
        echo "  2) Update CLIProxyAPI"
        echo "  3) Link CLIProxyAPI to a domain"
        echo "  4) Start CLIProxyAPI"
        echo "  5) Stop CLIProxyAPI"
        echo "  6) Restart CLIProxyAPI"
        echo "  7) View CLIProxyAPI logs"
        echo "  8) Enable API key requirement"
        echo "  9) Disable API key requirement"
        echo "  10) Enable request logging"
        echo "  11) Disable request logging"
        echo "  12) Verify CLIProxyAPI"
        echo "  13) Bootstrap auth providers"
        echo "  14) Check quota"
        echo "  0) Back"
        echo ""
        printf "  Select: " > /dev/tty
        local choice
        read -r choice < /dev/tty
        case "$choice" in
            1)  _cliproxyapi_menu_run install_cliproxyapi; press_enter ;;
            2)  _cliproxyapi_menu_run update_cliproxyapi; press_enter ;;
            3)  _cliproxyapi_menu_run link_cliproxyapi_domain; press_enter ;;
            4)  _cliproxyapi_menu_run cliproxyapi_start; press_enter ;;
            5)  _cliproxyapi_menu_run cliproxyapi_stop; press_enter ;;
            6)  _cliproxyapi_menu_run cliproxyapi_restart; press_enter ;;
            7)  _cliproxyapi_menu_run cliproxyapi_logs; press_enter ;;
            8)  _cliproxyapi_menu_run toggle_cliproxyapi_api_key on; press_enter ;;
            9)  _cliproxyapi_menu_run toggle_cliproxyapi_api_key off; press_enter ;;
            10) _cliproxyapi_menu_run toggle_cliproxyapi_request_logs on; press_enter ;;
            11) _cliproxyapi_menu_run toggle_cliproxyapi_request_logs off; press_enter ;;
            12) _cliproxyapi_menu_run verify_cliproxyapi; press_enter ;;
            13) _cliproxyapi_menu_run menu_cliproxyapi_bootstrap_auth ;;
            14) _cliproxyapi_menu_run check_cliproxyapi_quota; press_enter ;;
            0)  return 0 ;;
            *)  print_warn "Invalid option" ;;
        esac
    done
}
