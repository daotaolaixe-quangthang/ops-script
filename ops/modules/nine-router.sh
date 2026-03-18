#!/usr/bin/env bash
# ============================================================
# ops/modules/nine-router.sh
# Purpose: 9router install, PM2 service, and domain integration
# Part of:  OPS - VPS Production Setup & Manager
# ============================================================
# Called by bin/ops via menu dispatch.
# Do NOT add set -euo pipefail here - inherited from bin/ops.

NINE_ROUTER_REPO_URL="https://github.com/daotaolaixe-quangthang/9routervps.git"
NINE_ROUTER_DIR="/opt/9router"
NINE_ROUTER_DATA_DIR="/var/lib/9router"
NINE_ROUTER_PM2_NAME="nine-router"
NINE_ROUTER_PORT="20128"
NINE_ROUTER_ENV_FILE="${NINE_ROUTER_DIR}/.env"
NINE_ROUTER_PASSWORD_FILE="${OPS_CONFIG_DIR}/.nine-router-password"
NINE_ROUTER_STATE_FILE="${OPS_CONFIG_DIR}/nine-router.conf"
NINE_ROUTER_PM2_CONFIG="${NINE_ROUTER_DIR}/nine-router.ecosystem.config.js"

_nine_router_tpl_dir() {
    echo "${OPS_ROOT}/modules/templates"
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
    if ufw status 2>/dev/null | grep -q "20128"; then
        log_error "Security invariant violation: UFW has a rule containing port 20128"
        print_error "Port 20128 appears in UFW rules. Remove it immediately."
        return 1
    fi

    log_info "Verified UFW: no rule exposes port 20128"
    return 0
}

_nine_router_ensure_limit_req_zone() {
    local nginx_conf="/etc/nginx/nginx.conf"
    local zone_line='limit_req_zone $binary_remote_addr zone=nine_router:10m rate=30r/m;'

    if [[ ! -f "$nginx_conf" ]]; then
        log_error "Missing nginx config: ${nginx_conf}"
        return 1
    fi

    if grep -Fq "$zone_line" "$nginx_conf"; then
        return 0
    fi

    backup_file "$nginx_conf" >/dev/null || true

    local tmp
    tmp=$(mktemp)
    awk -v zone_line="$zone_line" '
        {
            print $0
            if (!inserted && $0 ~ /^[[:space:]]*http[[:space:]]*\{[[:space:]]*$/) {
                print "    " zone_line
                inserted = 1
            }
        }
        END {
            if (!inserted) {
                exit 7
            }
        }
    ' "$nginx_conf" > "$tmp"

    mv "$tmp" "$nginx_conf"
    log_info "Added limit_req_zone for nine-router to nginx http block"
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
HOSTNAME=0.0.0.0
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
    chown "$ADMIN_USER:$ADMIN_USER" "$NINE_ROUTER_ENV_FILE"
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

    chown "$ADMIN_USER:$ADMIN_USER" "$NINE_ROUTER_PM2_CONFIG"
}

install_nine_router() {
    print_section "Install 9router"

    ensure_dir "$OPS_CONFIG_DIR"

    if [[ -d "${NINE_ROUTER_DIR}/.git" ]]; then
        log_info "9router repo already exists at ${NINE_ROUTER_DIR}; syncing latest"
        git -C "$NINE_ROUTER_DIR" pull --ff-only
    elif [[ -e "$NINE_ROUTER_DIR" ]]; then
        log_error "${NINE_ROUTER_DIR} exists and is not a git clone"
        return 1
    else
        git clone "$NINE_ROUTER_REPO_URL" "$NINE_ROUTER_DIR"
    fi

    cd "$NINE_ROUTER_DIR"
    npm install
    npm run build

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
    chown "$ADMIN_USER:$ADMIN_USER" "$NINE_ROUTER_PASSWORD_FILE"
    log_info "9router initial password saved to ${NINE_ROUTER_PASSWORD_FILE} (0600)"
    print_warn "This password unlocks the 9router dashboard. Keep it safe."

    _nine_router_write_env "$init_password"

    mkdir -p "$NINE_ROUTER_DATA_DIR"
    chown "$ADMIN_USER:$ADMIN_USER" "$NINE_ROUTER_DATA_DIR"
    chmod 750 "$NINE_ROUTER_DATA_DIR"

    _nine_router_render_pm2_config

    if pm2 describe "$NINE_ROUTER_PM2_NAME" >/dev/null 2>&1; then
        pm2 delete "$NINE_ROUTER_PM2_NAME"
    fi

    pm2 start "$NINE_ROUTER_PM2_CONFIG"
    pm2 save

    local admin_home
    admin_home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
    if [[ -n "$admin_home" ]]; then
        pm2 startup systemd -u "$ADMIN_USER" --hp "$admin_home" >/dev/null 2>&1 || true
    fi

    _nine_router_set_state "NINE_ROUTER_INSTALLED" "yes"
    _nine_router_set_state "NINE_ROUTER_DIR" "$NINE_ROUTER_DIR"
    _nine_router_set_state "NINE_ROUTER_DATA_DIR" "$NINE_ROUTER_DATA_DIR"
    _nine_router_set_state "NINE_ROUTER_PORT" "$NINE_ROUTER_PORT"
    _nine_router_set_state "NINE_ROUTER_PM2_NAME" "$NINE_ROUTER_PM2_NAME"
    _nine_router_set_state "NINE_ROUTER_DOMAIN" ""
    _nine_router_set_state "NINE_ROUTER_SSL" "no"
    _nine_router_set_state "NINE_ROUTER_REQUIRE_API_KEY" "no"
    _nine_router_set_state "NINE_ROUTER_INSTALL_DATE" "$(date +%F)"

    _nine_router_assert_ufw_closed
    print_ok "9router installed and registered in PM2"
}

link_nine_router_domain() {
    local domain="${1:-}"
    if [[ -z "$domain" ]]; then
        prompt_input "Enter domain for 9router"
        domain="${REPLY:-}"
    fi

    if [[ -z "$domain" ]]; then
        log_error "Domain is required"
        return 1
    fi

    local nginx_tpl
    local vhost_path
    local enabled_path

    nginx_tpl="$(_nine_router_tpl_dir)/nginx/nine-router.vhost.conf.tpl"
    vhost_path="/etc/nginx/sites-available/nine-router.${domain}"
    enabled_path="/etc/nginx/sites-enabled/nine-router.${domain}"

    if [[ ! -f "$nginx_tpl" ]]; then
        log_error "Missing nginx template: ${nginx_tpl}"
        return 1
    fi

    _nine_router_ensure_limit_req_zone

    backup_file "$vhost_path" >/dev/null || true
    render_template "$nginx_tpl" \
        "DOMAIN=${domain}" \
        "NINE_ROUTER_PORT=${NINE_ROUTER_PORT}" \
        | write_file "$vhost_path"

    safe_symlink "$vhost_path" "$enabled_path"

    nginx -t
    service_enable nginx
    service_reload nginx

    local ssl_enabled="no"
    if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]] && [[ -f "/etc/letsencrypt/live/${domain}/privkey.pem" ]]; then
        if grep -q '^AUTH_COOKIE_SECURE=' "$NINE_ROUTER_ENV_FILE"; then
            sed -i 's/^AUTH_COOKIE_SECURE=.*/AUTH_COOKIE_SECURE=true/' "$NINE_ROUTER_ENV_FILE"
        else
            printf '\nAUTH_COOKIE_SECURE=true\n' >> "$NINE_ROUTER_ENV_FILE"
        fi
        pm2 restart "$NINE_ROUTER_PM2_NAME"
        ssl_enabled="yes"
        log_info "9router AUTH_COOKIE_SECURE=true (SSL active for ${domain})"
    fi

    _nine_router_set_state "NINE_ROUTER_DOMAIN" "$domain"
    _nine_router_set_state "NINE_ROUTER_SSL" "$ssl_enabled"

    _nine_router_assert_ufw_closed
    print_ok "9router linked to domain: ${domain}"
}

toggle_require_api_key() {
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

    pm2 restart "$NINE_ROUTER_PM2_NAME"
    _nine_router_set_state "NINE_ROUTER_REQUIRE_API_KEY" "$state_value"

    _nine_router_assert_ufw_closed
    print_ok "REQUIRE_API_KEY=${require_api_key} applied"
}

verify_nine_router() {
    print_section "Verify 9router"

    local pm2_line
    pm2_line=$(pm2 status "$NINE_ROUTER_PM2_NAME" 2>/dev/null | grep "$NINE_ROUTER_PM2_NAME" | head -n1 || true)
    if [[ -z "$pm2_line" ]] || [[ "$pm2_line" != *"online"* ]]; then
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

    if [[ ! -d "${NINE_ROUTER_DIR}/.git" ]]; then
        log_error "9router is not installed in ${NINE_ROUTER_DIR}"
        return 1
    fi

    cd "$NINE_ROUTER_DIR"
    pm2 stop "$NINE_ROUTER_PM2_NAME" || true
    git pull origin main
    npm install
    npm run build
    pm2 start "$NINE_ROUTER_PM2_NAME"
    pm2 save

    _nine_router_assert_ufw_closed
    print_ok "9router updated"
}

# Backward-compatible wrappers for old menu/action names.
nine_router_install() { install_nine_router; }
nine_router_configure() { link_nine_router_domain "${1:-}"; }
nine_router_update() { update_nine_router; }

nine_router_restart() {
    print_section "Restart 9router"
    pm2 restart "$NINE_ROUTER_PM2_NAME"
    _nine_router_assert_ufw_closed
}

nine_router_start() {
    print_section "Start 9router"
    pm2 start "$NINE_ROUTER_PM2_NAME"
    _nine_router_assert_ufw_closed
}

nine_router_stop() {
    print_section "Stop 9router"
    pm2 stop "$NINE_ROUTER_PM2_NAME"
}

nine_router_status() {
    print_section "9router Status"
    pm2 status "$NINE_ROUTER_PM2_NAME" || true
    _nine_router_assert_ufw_closed || true
}

nine_router_logs() {
    print_section "9router Logs"
    pm2 logs "$NINE_ROUTER_PM2_NAME" --lines 50
}

menu_nine_router() {
    while true; do
        print_section "9router Management"
        echo "  1) Install 9router"
        echo "  2) Update 9router"
        echo "  3) Link 9router to a domain"
        echo "  4) Start 9router"
        echo "  5) Stop 9router"
        echo "  6) Restart 9router"
        echo "  7) View 9router logs"
        echo "  8) Enable API key requirement"
        echo "  9) Disable API key requirement"
        echo "  10) Verify 9router"
        echo "  0) Back"
        echo ""
        read -r -p "Select: " choice
        case "$choice" in
            1) install_nine_router ;;
            2) update_nine_router ;;
            3) link_nine_router_domain ;;
            4) nine_router_start ;;
            5) nine_router_stop ;;
            6) nine_router_restart ;;
            7) nine_router_logs ;;
            8) toggle_require_api_key on ;;
            9) toggle_require_api_key off ;;
            10) verify_nine_router ;;
            0) return ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}
