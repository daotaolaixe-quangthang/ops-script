#!/usr/bin/env bash
# ============================================================
# ops/modules/nine-router.sh
# Purpose: 9router install, PM2 service, and domain integration
# Part of:  OPS - VPS Production Setup & Manager
# ============================================================
# Called by bin/ops via menu dispatch.
# Do NOT add set -euo pipefail here - inherited from bin/ops.

NINE_ROUTER_REPO_URL="https://github.com/daotaolaixe-quangthang/9routervps/archive/refs/heads/vpswork.tar.gz"
NINE_ROUTER_RAW_PKG_URL="https://raw.githubusercontent.com/daotaolaixe-quangthang/9routervps/vpswork/package.json"
NINE_ROUTER_DIR="/opt/9router"
NINE_ROUTER_DATA_DIR="/var/lib/9router"
NINE_ROUTER_PM2_NAME="nine-router"
NINE_ROUTER_PORT="20128"
NINE_ROUTER_ENV_FILE="${NINE_ROUTER_DIR}/.env"
NINE_ROUTER_PASSWORD_FILE="${OPS_CONFIG_DIR}/.nine-router-password"
NINE_ROUTER_STATE_FILE="${OPS_CONFIG_DIR}/nine-router.conf"
NINE_ROUTER_PM2_CONFIG="${NINE_ROUTER_DIR}/nine-router.ecosystem.config.js"
NINE_ROUTER_LOGROTATE_FILE="/etc/logrotate.d/nine-router"

_nine_router_tpl_dir() {
    echo "${OPS_ROOT}/modules/templates"
}

# Return the version string from the locally installed package.json, or empty.
_nine_router_local_version() {
    local pkg="${NINE_ROUTER_DIR}/package.json"
    if [[ ! -f "$pkg" ]]; then
        echo ""
        return
    fi
    grep -m1 '"version"' "$pkg" | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
}

# Fetch the version string from the remote package.json (branch vpswork).
# Returns empty string on network failure (non-blocking).
_nine_router_remote_version() {
    curl -fsSL --max-time 8 "$NINE_ROUTER_RAW_PKG_URL" 2>/dev/null \
        | grep -m1 '"version"' \
        | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' \
        || echo ""
}

_nine_router_runtime_user() {
    ops_runtime_user
}

_nine_router_runtime_home() {
    ops_runtime_home "$(_nine_router_runtime_user)"
}

_nine_router_run_as_runtime_user() {
    local runtime_user home_dir
    runtime_user="$(_nine_router_runtime_user)"
    home_dir="$(_nine_router_runtime_home)"
    # S3-4 fix: use `env -i` (clean environment) so PM2 and its managed processes
    # do NOT inherit shell variables from the invoking SSH session (SSH_CONNECTION,
    # ADMIN_USER, etc.). Only whitelisted variables are passed through.
    runuser -u "$runtime_user" -- env -i \
        HOME="$home_dir" \
        PM2_HOME="$home_dir/.pm2" \
        PATH="$PATH" \
        USER="$runtime_user" \
        LOGNAME="$runtime_user" \
        LANG="${LANG:-C.UTF-8}" \
        LC_ALL="${LC_ALL:-C.UTF-8}" \
        "$@"
}

_nine_router_set_state() {
    local key="$1"
    local value="$2"
    ops_conf_set "nine-router.conf" "$key" "$value"

    if [[ -f "$NINE_ROUTER_STATE_FILE" ]]; then
        chmod 640 "$NINE_ROUTER_STATE_FILE"
        chown "$ADMIN_USER:$ADMIN_USER" "$NINE_ROUTER_STATE_FILE"
    fi
}

_nine_router_assert_ufw_closed() {
    local ufw_out
    ufw_out=$(ufw status 2>/dev/null || true)

    # Only ALLOW rules are a security violation — DENY rules are fine (correct posture).
    if printf '%s\n' "$ufw_out" | grep -Eq "20128.*ALLOW|ALLOW.*20128"; then
        log_warn "Security invariant: UFW has an ALLOW rule for port 20128 — removing it automatically"
        ufw delete allow 20128/tcp  >/dev/null 2>&1 || true
        ufw delete allow 20128      >/dev/null 2>&1 || true
        ufw delete allow 20128/udp  >/dev/null 2>&1 || true
        # Verify removal
        local ufw_recheck
        ufw_recheck=$(ufw status 2>/dev/null || true)
        if printf '%s\n' "$ufw_recheck" | grep -Eq "20128.*ALLOW|ALLOW.*20128"; then
            log_error "Security invariant violation: UFW still has an ALLOW rule for port 20128"
            print_error "Port 20128 is publicly allowed in UFW. Remove it manually: sudo ufw delete allow 20128/tcp"
            return 1
        fi
        log_info "UFW ALLOW rule for port 20128 removed automatically"
    fi

    # Also clean up any stale DENY rule (not a security issue, but keep UFW tidy)
    if printf '%s\n' "$ufw_out" | grep -Eq "20128.*DENY|DENY.*20128"; then
        log_info "Removing stale UFW DENY rule for port 20128 (unnecessary — 9router binds on 127.0.0.1 only)"
        ufw delete deny 20128/tcp >/dev/null 2>&1 || true
        ufw delete deny 20128     >/dev/null 2>&1 || true
        ufw delete deny 20128/udp >/dev/null 2>&1 || true
    fi

    log_info "Verified UFW: no rule exposes port 20128"
    return 0
}

# _nine_router_ensure_limit_req_zone removed:
# Domain runs behind Cloudflare which handles rate limiting at the edge.

_nine_router_ssl_cert_ready() {
    local domain="$1"
    [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]] && [[ -f "/etc/letsencrypt/live/${domain}/privkey.pem" ]]
}

_nine_router_sync_cookie_secure() {
    local enabled="$1"
    local secure_value="false"

    if [[ ! -f "$NINE_ROUTER_ENV_FILE" ]]; then
        log_warn "Missing ${NINE_ROUTER_ENV_FILE}; skipped AUTH_COOKIE_SECURE sync"
        return 0
    fi

    if [[ "$enabled" == "yes" ]]; then
        secure_value="true"
    fi

    if grep -q '^AUTH_COOKIE_SECURE=' "$NINE_ROUTER_ENV_FILE"; then
        sed -i "s/^AUTH_COOKIE_SECURE=.*/AUTH_COOKIE_SECURE=${secure_value}/" "$NINE_ROUTER_ENV_FILE"
    else
        printf '\nAUTH_COOKIE_SECURE=%s\n' "$secure_value" >> "$NINE_ROUTER_ENV_FILE"
    fi

    if _nine_router_run_as_runtime_user pm2 describe "$NINE_ROUTER_PM2_NAME" >/dev/null 2>&1; then
        _nine_router_run_as_runtime_user pm2 restart "$NINE_ROUTER_PM2_NAME"
    fi

    log_info "9router AUTH_COOKIE_SECURE=${secure_value}"
}

# S3-2 fix: NEXT_PUBLIC_* vars are baked into the Next.js JS bundle at build
# time — they are NOT read from .env at runtime. If the .env contains
# http://localhost:PORT when the app is served over HTTPS the browser will
# block every API call (Mixed Content). This function:
#   1. Patches NEXT_PUBLIC_BASE_URL in .env to the correct public URL.
#   2. Rebuilds the app so the new value is baked into .next/standalone.
#   3. Re-creates the standalone symlinks (build output wipes them).
# Called from link_nine_router_domain (always) and, if needed, from
# update_nine_router (the URL is patched before the single build pass there).
_nine_router_sync_base_url() {
    local domain="$1"
    local ssl_enabled="$2"
    local scheme="http"
    [[ "$ssl_enabled" == "yes" ]] && scheme="https"
    local new_url="${scheme}://${domain}"

    if [[ ! -f "$NINE_ROUTER_ENV_FILE" ]]; then
        log_warn "Missing ${NINE_ROUTER_ENV_FILE}; cannot sync NEXT_PUBLIC_BASE_URL"
        return 0
    fi

    if grep -q '^NEXT_PUBLIC_BASE_URL=' "$NINE_ROUTER_ENV_FILE"; then
        sed -i "s|^NEXT_PUBLIC_BASE_URL=.*|NEXT_PUBLIC_BASE_URL=${new_url}|" "$NINE_ROUTER_ENV_FILE"
    else
        printf '\nNEXT_PUBLIC_BASE_URL=%s\n' "$new_url" >> "$NINE_ROUTER_ENV_FILE"
    fi
    log_info "NEXT_PUBLIC_BASE_URL set to ${new_url} in .env"

    # Must rebuild — NEXT_PUBLIC_* vars are baked at build time.
    log_info "Rebuilding 9router with updated NEXT_PUBLIC_BASE_URL (may take 1–2 min)..."
    _nine_router_run_as_runtime_user npm run build --prefix "$NINE_ROUTER_DIR"

    # Re-create standalone symlinks (build output wipes them).
    ln -sfn "${NINE_ROUTER_DIR}/.next/static" "${NINE_ROUTER_DIR}/.next/standalone/.next/static"
    ln -sfn "${NINE_ROUTER_DIR}/public"       "${NINE_ROUTER_DIR}/.next/standalone/public"
    log_info "Standalone symlinks re-created after rebuild"
}

_nine_router_install_logrotate() {
    write_file "$NINE_ROUTER_LOGROTATE_FILE" <<'EOF'
/opt/9router/logs/*.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    copytruncate
}
EOF
    chmod 644 "$NINE_ROUTER_LOGROTATE_FILE"
    log_info "logrotate config installed: ${NINE_ROUTER_LOGROTATE_FILE}"
}

_nine_router_remove_logrotate() {
    if [[ -f "$NINE_ROUTER_LOGROTATE_FILE" ]]; then
        rm -f "$NINE_ROUTER_LOGROTATE_FILE"
        log_info "logrotate config removed: ${NINE_ROUTER_LOGROTATE_FILE}"
    fi
}

_nine_router_render_vhost() {
    local domain="$1"
    local nginx_tpl
    local vhost_path
    local enabled_path
    local ssl_enabled="no"
    local ssl_http_block=""
    local ssl_https_block=""

    nginx_tpl="$(_nine_router_tpl_dir)/nginx/nine-router.vhost.conf.tpl"
    vhost_path="/etc/nginx/sites-available/nine-router.${domain}"
    enabled_path="/etc/nginx/sites-enabled/nine-router.${domain}"

    if [[ ! -f "$nginx_tpl" ]]; then
        log_error "Missing nginx template: ${nginx_tpl}"
        return 1
    fi

    if _nine_router_ssl_cert_ready "$domain"; then
        ssl_enabled="yes"
        ssl_http_block="    return 301 https://\$host\$request_uri;"
        ssl_https_block=$(cat <<EOF
server {
    listen 443 ssl;
    http2 on;
    server_name ${domain};

    access_log /var/log/nginx/nine-router.access.log;
    error_log  /var/log/nginx/nine-router.error.log;

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    # ── Security headers (vhost-level override) ──────────────────────────────
    # When add_header appears in server{} block, headers from http{} are NOT
    # inherited. Re-declare all security headers + relax style-src / font-src
    # for Google Fonts Material Symbols used by the 9router dashboard.
    add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' https:; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; img-src 'self' data: https:; font-src 'self' data: https://fonts.gstatic.com; connect-src 'self' https:; frame-ancestors 'none'" always;
    add_header Permissions-Policy        "geolocation=(), microphone=(), camera=(), payment=(), usb=()" always;
    add_header X-XSS-Protection          "1; mode=block" always;
    add_header Referrer-Policy           "strict-origin-when-cross-origin" always;
    add_header X-Content-Type-Options    "nosniff" always;
    add_header X-Frame-Options           "SAMEORIGIN" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    location / {
        proxy_pass         http://127.0.0.1:${NINE_ROUTER_PORT};
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
    render_template "$nginx_tpl" \
        "DOMAIN=${domain}" \
        "NINE_ROUTER_PORT=${NINE_ROUTER_PORT}" \
        "SSL_HTTP_BLOCK=${ssl_http_block}" \
        "SSL_HTTPS_BLOCK=${ssl_https_block}" \
        | write_file "$vhost_path"

    safe_symlink "$vhost_path" "$enabled_path"
}

_nine_router_write_env() {
    local init_password="$1"
    local jwt_secret
    local api_key_secret
    local machine_id_salt

    jwt_secret=$(openssl rand -hex 32)
    api_key_secret=$(openssl rand -hex 32)
    machine_id_salt=$(openssl rand -hex 16)

    backup_file "$NINE_ROUTER_ENV_FILE" >/dev/null || true
    write_file "$NINE_ROUTER_ENV_FILE" <<EOF
PORT=${NINE_ROUTER_PORT}
HOSTNAME=127.0.0.1
NODE_ENV=production
DATA_DIR=${NINE_ROUTER_DATA_DIR}
JWT_SECRET=${jwt_secret}
INITIAL_PASSWORD=${init_password}
NEXT_PUBLIC_BASE_URL=http://localhost:${NINE_ROUTER_PORT}
NEXT_PUBLIC_CLOUD_URL=https://9router.com
API_KEY_SECRET=${api_key_secret}
MACHINE_ID_SALT=${machine_id_salt}
ENABLE_REQUEST_LOGS=false
AUTH_COOKIE_SECURE=false
REQUIRE_API_KEY=false
EOF

    chmod 600 "$NINE_ROUTER_ENV_FILE"
    chown "$(_nine_router_runtime_user):$(_nine_router_runtime_user)" "$NINE_ROUTER_ENV_FILE"
}

_nine_router_render_pm2_config() {
    local pm2_tpl
    pm2_tpl="$(_nine_router_tpl_dir)/pm2/nine-router.ecosystem.config.js.tpl"

    if [[ ! -f "$pm2_tpl" ]]; then
        log_error "Missing PM2 template: ${pm2_tpl}"
        return 1
    fi

    backup_file "$NINE_ROUTER_PM2_CONFIG" >/dev/null || true
    render_template "$pm2_tpl" \
        "NINE_ROUTER_DIR=${NINE_ROUTER_DIR}" \
        "NINE_ROUTER_PORT=${NINE_ROUTER_PORT}" \
        | write_file "$NINE_ROUTER_PM2_CONFIG"

    chown "$(_nine_router_runtime_user):$(_nine_router_runtime_user)" "$NINE_ROUTER_PM2_CONFIG"
}

install_nine_router() {
    print_section "Install 9router"
    require_root || return 1

    ensure_dir "$OPS_CONFIG_DIR"

    if [[ -e "$NINE_ROUTER_DIR" ]]; then
        if [[ -d "$NINE_ROUTER_DIR" ]]; then
            print_warn "9router is already installed at ${NINE_ROUTER_DIR}."
        else
            print_warn "${NINE_ROUTER_DIR} exists but is not a directory."
        fi
        if ! prompt_confirm "Xóa và cài lại từ đầu?"; then
            print_warn "Installation cancelled."
            return 0
        fi
        log_info "Removing ${NINE_ROUTER_DIR} for fresh install..."
        if _nine_router_run_as_runtime_user pm2 describe "$NINE_ROUTER_PM2_NAME" >/dev/null 2>&1; then
            _nine_router_run_as_runtime_user pm2 delete "$NINE_ROUTER_PM2_NAME" || true
        fi
        rm -rf "$NINE_ROUTER_DIR"
        log_info "Removed ${NINE_ROUTER_DIR}"
    fi

    # Download source archive from branch vpswork, extract, then remove archive.
    local _archive
    _archive="$(mktemp /tmp/nine-router-XXXXXX.tar.gz)"
    log_info "Downloading 9router archive from branch vpswork..."
    curl -fsSL "$NINE_ROUTER_REPO_URL" -o "$_archive"

    log_info "Extracting archive to ${NINE_ROUTER_DIR}..."
    mkdir -p "$NINE_ROUTER_DIR"
    tar -xzf "$_archive" --strip-components=1 -C "$NINE_ROUTER_DIR"

    rm -f "$_archive"
    log_info "Archive removed"

    # Fix ownership BEFORE running npm as runtime user — tar extracts as root,
    # so the runtime user cannot write node_modules without this chown.
    local _rt_user
    _rt_user="$(_nine_router_runtime_user)"
    chown -R "${_rt_user}:${_rt_user}" "$NINE_ROUTER_DIR"
    log_info "Set ${NINE_ROUTER_DIR} ownership to ${_rt_user} before npm install"

    cd "$NINE_ROUTER_DIR"
    # Run as runtime user so node_modules is not root-owned
    # (prevents permission errors during future updates/restarts)
    _nine_router_run_as_runtime_user npm install --prefix "$NINE_ROUTER_DIR"
    _nine_router_run_as_runtime_user npm run build --prefix "$NINE_ROUTER_DIR"

    # Next.js standalone output requires static assets and public/ to be
    # symlinked into the standalone directory — they are NOT copied by the build.
    ln -sfn "${NINE_ROUTER_DIR}/.next/static" "${NINE_ROUTER_DIR}/.next/standalone/.next/static"
    ln -sfn "${NINE_ROUTER_DIR}/public"       "${NINE_ROUTER_DIR}/.next/standalone/public"
    log_info "Symlinked .next/static and public/ into standalone output"

    prompt_secret "Enter 9router dashboard initial password"
    local init_password="${SECRET:-}"
    unset SECRET

    if [[ -z "$init_password" ]]; then
        log_error "Initial password cannot be empty"
        return 1
    fi

    write_file "$NINE_ROUTER_PASSWORD_FILE" <<EOF
${init_password}
EOF
    chmod 600 "$NINE_ROUTER_PASSWORD_FILE"
    chown "$(_nine_router_runtime_user):$(_nine_router_runtime_user)" "$NINE_ROUTER_PASSWORD_FILE"
    log_info "9router initial password saved to ${NINE_ROUTER_PASSWORD_FILE} (0600)"
    print_warn "This password unlocks the 9router dashboard. Keep it safe."

    _nine_router_write_env "$init_password"

    # Harden file permissions on app directory
    local _runtime_user
    _runtime_user="$(_nine_router_runtime_user)"
    # Restrict .env.example — no need for world-readable (was 644)
    if [[ -f "${NINE_ROUTER_DIR}/.env.example" ]]; then
        chmod 640 "${NINE_ROUTER_DIR}/.env.example"
        log_info "Restricted .env.example to 640"
    fi
    # Set runtime user as owner of the app dir so PM2 can write logs/cache
    chown -R "${_runtime_user}:${_runtime_user}" "${NINE_ROUTER_DIR}" 2>/dev/null || true
    # Re-enforce .env is strictly 600 owned by runtime user (chown -R above covers it, belt+suspenders)
    chmod 600 "$NINE_ROUTER_ENV_FILE"
    chown "${_runtime_user}:${_runtime_user}" "$NINE_ROUTER_ENV_FILE"
    log_info "9router app dir ownership set to ${_runtime_user}, .env.example restricted to 640"

    mkdir -p "$NINE_ROUTER_DATA_DIR"
    chown "$(_nine_router_runtime_user):$(_nine_router_runtime_user)" "$NINE_ROUTER_DATA_DIR"
    chmod 750 "$NINE_ROUTER_DATA_DIR"

    _nine_router_render_pm2_config

    if _nine_router_run_as_runtime_user pm2 describe "$NINE_ROUTER_PM2_NAME" >/dev/null 2>&1; then
        _nine_router_run_as_runtime_user pm2 delete "$NINE_ROUTER_PM2_NAME"
    fi

    _nine_router_run_as_runtime_user pm2 start "$NINE_ROUTER_PM2_CONFIG"
    _nine_router_run_as_runtime_user pm2 save

    local runtime_user runtime_home
    runtime_user="$(_nine_router_runtime_user)"
    runtime_home="$(_nine_router_runtime_home)"
    if [[ -n "$runtime_home" ]]; then
        pm2 startup systemd -u "$runtime_user" --hp "$runtime_home" >/dev/null 2>&1 || true
    fi

    _nine_router_set_state "NINE_ROUTER_INSTALLED" "yes"
    _nine_router_set_state "NINE_ROUTER_DIR" "$NINE_ROUTER_DIR"
    _nine_router_set_state "NINE_ROUTER_DATA_DIR" "$NINE_ROUTER_DATA_DIR"
    _nine_router_set_state "NINE_ROUTER_PORT" "$NINE_ROUTER_PORT"
    _nine_router_set_state "NINE_ROUTER_PM2_NAME" "$NINE_ROUTER_PM2_NAME"
    _nine_router_set_state "NINE_ROUTER_RUNTIME_USER" "$(_nine_router_runtime_user)"
    _nine_router_set_state "NINE_ROUTER_DOMAIN" ""
    _nine_router_set_state "NINE_ROUTER_SSL" "no"
    _nine_router_set_state "NINE_ROUTER_REQUIRE_API_KEY" "no"
    _nine_router_set_state "NINE_ROUTER_REQUEST_LOGS" "no"
    _nine_router_set_state "NINE_ROUTER_INSTALL_DATE" "$(date +%F)"

    _nine_router_assert_ufw_closed
    print_ok "9router installed and registered in PM2"
}

link_nine_router_domain() {
    require_root || return 1
    local domain="${1:-}"
    if [[ -z "$domain" ]]; then
        prompt_input "Enter domain for 9router"
        domain="${REPLY:-}"
    fi

    if [[ -z "$domain" ]]; then
        log_error "Domain is required"
        return 1
    fi

    # Rate limiting removed: domain runs behind Cloudflare
    create_default_deny

    local ssl_enabled="no"
    if _nine_router_ssl_cert_ready "$domain"; then ssl_enabled="yes"; fi
    _nine_router_render_vhost "$domain" || return 1

    nginx -t
    service_enable nginx
    service_reload nginx

    _nine_router_sync_cookie_secure "$ssl_enabled"

    # S3-2: update NEXT_PUBLIC_BASE_URL to the correct scheme+domain and rebuild
    # so the new URL is baked into the Next.js bundle (NEXT_PUBLIC_* are build-time).
    _nine_router_sync_base_url "$domain" "$ssl_enabled"

    # Reload PM2 to pick up the rebuilt standalone server.
    if _nine_router_run_as_runtime_user pm2 describe "$NINE_ROUTER_PM2_NAME" > /dev/null 2>&1; then
        _nine_router_run_as_runtime_user pm2 reload "$NINE_ROUTER_PM2_NAME" --update-env
    fi

    _nine_router_set_state "NINE_ROUTER_DOMAIN" "$domain"
    _nine_router_set_state "NINE_ROUTER_SSL" "$ssl_enabled"

    _nine_router_assert_ufw_closed
    print_ok "9router linked to domain: ${domain}"
}

toggle_require_api_key() {
    require_root || return 1
    local mode="${1:-}"
    local require_api_key
    local state_value

    case "$mode" in
        on)
            require_api_key="true"
            state_value="yes"
            ;;
        off)
            require_api_key="false"
            state_value="no"
            ;;
        *)
            print_error "Usage: toggle_require_api_key <on|off>"
            return 1
            ;;
    esac

    if [[ ! -f "$NINE_ROUTER_ENV_FILE" ]]; then
        log_error "Missing ${NINE_ROUTER_ENV_FILE}. Install 9router first."
        return 1
    fi

    if grep -q '^REQUIRE_API_KEY=' "$NINE_ROUTER_ENV_FILE"; then
        sed -i "s/^REQUIRE_API_KEY=.*/REQUIRE_API_KEY=${require_api_key}/" "$NINE_ROUTER_ENV_FILE"
    else
        printf '\nREQUIRE_API_KEY=%s\n' "$require_api_key" >> "$NINE_ROUTER_ENV_FILE"
    fi

    _nine_router_run_as_runtime_user pm2 restart "$NINE_ROUTER_PM2_NAME"
    _nine_router_set_state "NINE_ROUTER_REQUIRE_API_KEY" "$state_value"

    _nine_router_assert_ufw_closed
    print_ok "REQUIRE_API_KEY=${require_api_key} applied"
}

toggle_request_logs() {
    require_root || return 1
    local mode="${1:-}"
    local enable_logs
    local state_value

    case "$mode" in
        on)
            enable_logs="true"
            state_value="yes"
            ;;
        off)
            enable_logs="false"
            state_value="no"
            ;;
        *)
            print_error "Usage: toggle_request_logs <on|off>"
            return 1
            ;;
    esac

    if [[ ! -f "$NINE_ROUTER_ENV_FILE" ]]; then
        log_error "Missing ${NINE_ROUTER_ENV_FILE}. Install 9router first."
        return 1
    fi

    if grep -q '^ENABLE_REQUEST_LOGS=' "$NINE_ROUTER_ENV_FILE"; then
        sed -i "s/^ENABLE_REQUEST_LOGS=.*/ENABLE_REQUEST_LOGS=${enable_logs}/" "$NINE_ROUTER_ENV_FILE"
    else
        printf '\nENABLE_REQUEST_LOGS=%s\n' "$enable_logs" >> "$NINE_ROUTER_ENV_FILE"
    fi

    if [[ "$mode" == "on" ]]; then
        mkdir -p "${NINE_ROUTER_DIR}/logs"
        chown "$(_nine_router_runtime_user):$(_nine_router_runtime_user)" "${NINE_ROUTER_DIR}/logs"
        _nine_router_install_logrotate
    else
        _nine_router_remove_logrotate
    fi

    _nine_router_run_as_runtime_user pm2 restart "$NINE_ROUTER_PM2_NAME"
    _nine_router_set_state "NINE_ROUTER_REQUEST_LOGS" "$state_value"

    _nine_router_assert_ufw_closed
    print_ok "ENABLE_REQUEST_LOGS=${enable_logs} applied"
}

verify_nine_router() {
    print_section "Verify 9router"
    require_root || return 1

    local pm2_status
    pm2_status=$(ops_pm2_process_status "$NINE_ROUTER_PM2_NAME" 2>/dev/null || echo "not-found")
    if [[ "$pm2_status" != "online" ]]; then
        log_error "PM2 process ${NINE_ROUTER_PM2_NAME} is not online"
        return 1
    fi
    print_ok "PM2 process is online"

    local models_response
    models_response=$(curl -fsS "http://127.0.0.1:${NINE_ROUTER_PORT}/v1/models" || true)
    if [[ -z "$models_response" ]] || ! printf '%s' "$models_response" | grep -qE '^[[:space:]]*[\[{]'; then
        log_error "9router /v1/models did not return JSON"
        return 1
    fi
    print_ok "Local /v1/models endpoint returned JSON"

    _nine_router_assert_ufw_closed
    print_ok "Verification passed"
}

update_nine_router() {
    print_section "Update 9router"
    require_root || return 1

    if [[ ! -d "$NINE_ROUTER_DIR" ]]; then
        log_error "9router is not installed in ${NINE_ROUTER_DIR}"
        return 1
    fi

    # ── Version check ─────────────────────────────────────────────
    local local_ver remote_ver
    local_ver="$(_nine_router_local_version)"
    log_info "Checking remote version (branch vpswork)..."
    remote_ver="$(_nine_router_remote_version)"

    if [[ -n "$local_ver" && -n "$remote_ver" ]]; then
        echo -e "  Installed : ${BLD}${local_ver}${RST}"
        echo -e "  Available : ${BLD}${remote_ver}${RST}"
        if [[ "$local_ver" == "$remote_ver" ]]; then
            print_ok "9router is already up to date (${local_ver})"
            if ! prompt_confirm "Update anyway?"; then
                return 0
            fi
        else
            print_warn "New version available: ${local_ver} → ${remote_ver}"
        fi
    else
        log_warn "Could not compare versions (offline or package.json missing); proceeding with update"
    fi

    _nine_router_run_as_runtime_user pm2 stop "$NINE_ROUTER_PM2_NAME" || true

    # Preserve .env and data; re-download source archive from branch vpswork.
    local _archive
    _archive="$(mktemp /tmp/nine-router-XXXXXX.tar.gz)"
    log_info "Downloading 9router archive from branch vpswork..."
    curl -fsSL "$NINE_ROUTER_REPO_URL" -o "$_archive"

    log_info "Extracting update to ${NINE_ROUTER_DIR}..."
    tar -xzf "$_archive" --strip-components=1 -C "$NINE_ROUTER_DIR"

    rm -f "$_archive"
    log_info "Archive removed"

    # Re-apply ownership after extracting new archive (tar overwrites as root).
    local _rt_user2
    _rt_user2="$(_nine_router_runtime_user)"
    chown -R "${_rt_user2}:${_rt_user2}" "$NINE_ROUTER_DIR"
    log_info "Set ${NINE_ROUTER_DIR} ownership to ${_rt_user2} before npm install"

    cd "$NINE_ROUTER_DIR"
    _nine_router_run_as_runtime_user npm install --prefix "$NINE_ROUTER_DIR"

    # S3-2: patch NEXT_PUBLIC_BASE_URL in .env BEFORE the build so the correct
    # URL is baked into the bundle in a single pass (Option B — no double build).
    local _linked_domain _linked_ssl _linked_scheme
    _linked_domain="$(ops_conf_get "nine-router.conf" "NINE_ROUTER_DOMAIN" 2>/dev/null || true)"
    _linked_ssl="$(ops_conf_get    "nine-router.conf" "NINE_ROUTER_SSL"    2>/dev/null || true)"
    if [[ -n "$_linked_domain" ]] && [[ -f "$NINE_ROUTER_ENV_FILE" ]]; then
        _linked_scheme="http"
        [[ "${_linked_ssl:-no}" == "yes" ]] && _linked_scheme="https"
        local _new_url="${_linked_scheme}://${_linked_domain}"
        if grep -q '^NEXT_PUBLIC_BASE_URL=' "$NINE_ROUTER_ENV_FILE"; then
            sed -i "s|^NEXT_PUBLIC_BASE_URL=.*|NEXT_PUBLIC_BASE_URL=${_new_url}|" "$NINE_ROUTER_ENV_FILE"
        else
            printf '\nNEXT_PUBLIC_BASE_URL=%s\n' "$_new_url" >> "$NINE_ROUTER_ENV_FILE"
        fi
        log_info "S3-2: NEXT_PUBLIC_BASE_URL set to ${_new_url} before build"
    fi

    _nine_router_run_as_runtime_user npm run build --prefix "$NINE_ROUTER_DIR"

    # Re-create standalone symlinks after every update
    ln -sfn "${NINE_ROUTER_DIR}/.next/static" "${NINE_ROUTER_DIR}/.next/standalone/.next/static"
    ln -sfn "${NINE_ROUTER_DIR}/public"       "${NINE_ROUTER_DIR}/.next/standalone/public"
    log_info "Symlinked .next/static and public/ into standalone output"

    # Re-render PM2 ecosystem config (picks up any template changes in the update)
    _nine_router_render_pm2_config

    # Graceful reload: replaces workers one at a time (zero-downtime where possible)
    if _nine_router_run_as_runtime_user pm2 describe "$NINE_ROUTER_PM2_NAME" >/dev/null 2>&1; then
        _nine_router_run_as_runtime_user pm2 reload "$NINE_ROUTER_PM2_NAME" --update-env
    else
        _nine_router_run_as_runtime_user pm2 start "$NINE_ROUTER_PM2_CONFIG"
    fi
    _nine_router_run_as_runtime_user pm2 save

    _nine_router_assert_ufw_closed
    print_ok "9router updated to ${remote_ver:-unknown}"
}

# Backward-compatible wrappers for old menu/action names.
nine_router_install() { install_nine_router; }
nine_router_configure() { link_nine_router_domain "${1:-}"; }
nine_router_update() { update_nine_router; }

nine_router_restart() {
    print_section "Restart 9router"
    require_root || return 1
    _nine_router_run_as_runtime_user pm2 restart "$NINE_ROUTER_PM2_NAME"
    _nine_router_assert_ufw_closed
}

nine_router_start() {
    print_section "Start 9router"
    require_root || return 1
    _nine_router_run_as_runtime_user pm2 start "$NINE_ROUTER_PM2_NAME"
    _nine_router_assert_ufw_closed
}

nine_router_stop() {
    print_section "Stop 9router"
    require_root || return 1
    _nine_router_run_as_runtime_user pm2 stop "$NINE_ROUTER_PM2_NAME"
}

nine_router_status() {
    print_section "9router Status"
    _nine_router_run_as_runtime_user pm2 status "$NINE_ROUTER_PM2_NAME" || true
    _nine_router_assert_ufw_closed || true
}

nine_router_logs() {
    print_section "9router Logs"
    _nine_router_run_as_runtime_user pm2 logs "$NINE_ROUTER_PM2_NAME" --lines 50
}

_nine_router_show_status() {
    local installed_label domain pm2_status restarts api_key log_lines
    local runtime_user pm2_json pm2_entry

    # ── Installation & version ────────────────────────────────────
    local local_ver_status
    if [[ -d "$NINE_ROUTER_DIR" ]] && [[ -f "${NINE_ROUTER_DIR}/package.json" ]]; then
        local_ver_status="$(_nine_router_local_version)"
        installed_label="${GRN}✓ Installed${RST}  (${NINE_ROUTER_DIR})  v${local_ver_status:-?}"
    else
        local_ver_status=""
        installed_label="${RED}✗ Not installed${RST}"
    fi

    # ── Domain ───────────────────────────────────────────────────
    domain="$(ops_conf_get "nine-router.conf" "NINE_ROUTER_DOMAIN" 2>/dev/null || true)"
    local domain_label
    if [[ -n "$domain" ]]; then
        local ssl_val
        ssl_val="$(ops_conf_get "nine-router.conf" "NINE_ROUTER_SSL" 2>/dev/null || true)"
        if [[ "$ssl_val" == "yes" ]]; then
            domain_label="${GRN}${domain}${RST}  (SSL ✓)"
        else
            domain_label="${YLW}${domain}${RST}  (no SSL)"
        fi
    else
        domain_label="${BLD}—${RST}  (not configured)"
    fi

    # ── PM2: status + restarts ────────────────────────────────────
    pm2_json="$(_nine_router_run_as_runtime_user pm2 jlist 2>/dev/null || true)"

    # Split multi-process JSON array into one-object-per-line, then grep our process.
    # pm2 jlist returns: [{...},{...}] — we split on },{ boundary.
    local pm2_proc_line
    pm2_proc_line=""
    if [[ -n "$pm2_json" ]]; then
        pm2_proc_line=$(echo "$pm2_json" \
            | sed 's/},{/}\n{/g' \
            | grep '"nine-router"' \
            | head -n1 || true)
    fi

    if [[ -n "$pm2_proc_line" ]]; then
        pm2_status=$(echo "$pm2_proc_line" | grep -o '"status":"[^"]*"' | head -n1 | cut -d: -f2 | tr -d '"\n' || true)
        restarts=$(echo "$pm2_proc_line" | grep -o '"restart_time":[0-9]*' | head -n1 | cut -d: -f2 | tr -d '\n' || true)

        local pm2_status_label
        case "${pm2_status:-}"
        in
            online)   pm2_status_label="${GRN}✓ online${RST}" ;;
            stopping) pm2_status_label="${YLW}⏸ stopping${RST}" ;;
            stopped)  pm2_status_label="${YLW}■ stopped${RST}" ;;
            errored)  pm2_status_label="${RED}✗ errored${RST}" ;;
            *)        pm2_status_label="${YLW}${pm2_status:-unknown}${RST}" ;;
        esac

        restarts="${restarts:-0}"
    else
        pm2_status_label="${BLD}—${RST}  (not registered)"
        restarts="${BLD}—${RST}"
    fi

    # ── API Key requirement ───────────────────────────────────────
    local api_key_raw
    api_key_raw="$(ops_conf_get "nine-router.conf" "NINE_ROUTER_REQUIRE_API_KEY" 2>/dev/null || true)"
    if [[ "$api_key_raw" == "yes" ]]; then
        api_key="${GRN}enabled${RST}"
    elif [[ "$api_key_raw" == "no" ]]; then
        api_key="${YLW}disabled${RST}"
    else
        api_key="${BLD}—${RST}"
    fi

    # ── Request logs status ───────────────────────────────────────
    local req_logs_raw req_logs_label
    req_logs_raw="$(ops_conf_get "nine-router.conf" "NINE_ROUTER_REQUEST_LOGS" 2>/dev/null || true)"
    if [[ "$req_logs_raw" == "yes" ]]; then
        req_logs_label="${GRN}enabled${RST}  (logrotate: daily/14d)"
    elif [[ "$req_logs_raw" == "no" ]]; then
        req_logs_label="${YLW}disabled${RST}"
    else
        req_logs_label="${BLD}—${RST}"
    fi

    # ── Log line count ────────────────────────────────────────────────────────
    # Log paths are set by the PM2 ecosystem config (error_file / out_file)
    local out_log err_log total_lines
    out_log="/var/log/ops/${NINE_ROUTER_PM2_NAME}.out.log"
    err_log="/var/log/ops/${NINE_ROUTER_PM2_NAME}.err.log"
    total_lines=0
    if [[ -f "$out_log" ]]; then
        total_lines=$(( total_lines + $(wc -l < "$out_log" 2>/dev/null || echo 0) ))
    fi
    if [[ -f "$err_log" ]]; then
        total_lines=$(( total_lines + $(wc -l < "$err_log" 2>/dev/null || echo 0) ))
    fi

    # ── Render ────────────────────────────────────────────────────
    echo -e "  ${BLD}📦 Installation  :${RST} ${installed_label}"
    echo -e "  ${BLD}🌐 Local address  :${RST} 127.0.0.1:${NINE_ROUTER_PORT}  (loopback-only)"
    echo -e "  ${BLD}🔗 Domain         :${RST} ${domain_label}"
    echo -e "  ${BLD}🚦 PM2 Status     :${RST} ${pm2_status_label}"
    echo -e "  ${BLD}🔄 Restarts       :${RST} ${restarts}"
    echo -e "  ${BLD}🔑 API Key        :${RST} ${api_key}"
    echo -e "  ${BLD}📝 Request logs   :${RST} ${req_logs_label}"
    echo -e "  ${BLD}📋 Log lines      :${RST} ${total_lines}"
    echo ""
}

menu_nine_router() {
    _nine_router_menu_run() {
        "$@"
        return 0
    }

    while true; do
        print_section "9router Management"
        _nine_router_show_status
        echo "  1) Install 9router"
        echo "  2) Update 9router"
        echo "  3) Link 9router to a domain"
        echo "  4) Start 9router"
        echo "  5) Stop 9router"
        echo "  6) Restart 9router"
        echo "  7) View 9router logs"
        echo "  8) Enable API key requirement"
        echo "  9) Disable API key requirement"
        echo "  10) Enable request logging"
        echo "  11) Disable request logging"
        echo "  12) Verify 9router"
        echo "  0) Back"
        echo ""
        read -r -p "Select: " choice
        case "$choice" in
            1) _nine_router_menu_run install_nine_router ;;
            2) _nine_router_menu_run update_nine_router ;;
            3) _nine_router_menu_run link_nine_router_domain ;;
            4) _nine_router_menu_run nine_router_start ;;
            5) _nine_router_menu_run nine_router_stop ;;
            6) _nine_router_menu_run nine_router_restart ;;
            7) _nine_router_menu_run nine_router_logs ;;
            8) _nine_router_menu_run toggle_require_api_key on ;;
            9) _nine_router_menu_run toggle_require_api_key off ;;
            10) _nine_router_menu_run toggle_request_logs on ;;
            11) _nine_router_menu_run toggle_request_logs off ;;
            12) _nine_router_menu_run verify_nine_router ;;
            0) return 0 ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}
