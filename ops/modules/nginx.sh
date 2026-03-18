#!/usr/bin/env bash
# ============================================================
# ops/modules/nginx.sh
# Purpose:  Nginx install, global tuning, vhost management, SSL helpers
# Part of:  OPS - VPS Production Setup & Manager
# ============================================================
# Called by bin/ops via menu dispatch.
# Do NOT add set -euo pipefail here - inherited from bin/ops.

NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
OPS_DOMAINS_DIR="/etc/ops/domains"
NGINX_TEMPLATE_DIR="${OPS_ROOT}/modules/templates/nginx"
NGINX_DEFAULT_DENY_NAME="00-default-deny"
NGINX_DEFAULT_CERT_DIR="/etc/nginx/ssl"
NGINX_DEFAULT_CERT="${NGINX_DEFAULT_CERT_DIR}/ops-default.crt"
NGINX_DEFAULT_KEY="${NGINX_DEFAULT_CERT_DIR}/ops-default.key"

_nginx_detect_tuning() {
    local worker_processes worker_connections
    case "${OPS_TIER:-M}" in
        S)
            worker_processes="1"
            worker_connections="2048"
            ;;
        M)
            worker_processes="2"
            worker_connections="4096"
            ;;
        L)
            worker_processes="4"
            worker_connections="8192"
            ;;
        *)
            worker_processes="${CPU_CORES:-1}"
            worker_connections="4096"
            ;;
    esac
    printf '%s;%s\n' "$worker_processes" "$worker_connections"
}

_nginx_ensure_default_tls_cert() {
    ensure_dir "$NGINX_DEFAULT_CERT_DIR"
    if [[ -f "$NGINX_DEFAULT_CERT" && -f "$NGINX_DEFAULT_KEY" ]]; then
        return 0
    fi

    if ! command -v openssl >/dev/null 2>&1; then
        apt_install openssl
    fi

    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -subj "/CN=ops-default-deny" \
        -keyout "$NGINX_DEFAULT_KEY" \
        -out "$NGINX_DEFAULT_CERT"
    chmod 600 "$NGINX_DEFAULT_KEY"
    chmod 644 "$NGINX_DEFAULT_CERT"
    log_info "Generated default deny self-signed cert for Nginx."
}

_nginx_ensure_nine_router_rate_zone() {
    local conf="/etc/nginx/nginx.conf"
    local marker='limit_req_zone $binary_remote_addr zone=nine_router_api:10m rate=30r/m;'

    grep -Fq "$marker" "$conf" && return 0
    backup_file "$conf" >/dev/null || true

    if awk -v marker="$marker" '
        BEGIN { inserted=0 }
        /^\s*http\s*\{/ && inserted==0 {
            print
            print "    " marker
            inserted=1
            next
        }
        { print }
        END { if (inserted==0) exit 2 }
    ' "$conf" > "${conf}.tmp"; then
        mv "${conf}.tmp" "$conf"
        log_info "Added nine_router_api limit_req_zone to nginx.conf."
    else
        rm -f "${conf}.tmp"
        log_warn "Could not inject nine_router_api limit_req_zone automatically."
    fi
}

_nginx_apply_global_tuning() {
    local conf="/etc/nginx/nginx.conf"
    local tuning worker_processes worker_connections
    tuning="$(_nginx_detect_tuning)"
    worker_processes="${tuning%%;*}"
    worker_connections="${tuning##*;}"

    [[ -f "$conf" ]] || return 0
    backup_file "$conf" >/dev/null || true

    sed -i -E "s/^\s*worker_processes\s+[^;]+;/worker_processes ${worker_processes};/" "$conf"
    sed -i -E "s/^\s*worker_connections\s+[^;]+;/    worker_connections ${worker_connections};/" "$conf"

    _nginx_ensure_nine_router_rate_zone
    log_info "Applied nginx tuning: worker_processes=${worker_processes}, worker_connections=${worker_connections}."
}

_nginx_test_and_reload() {
    if ! nginx -t; then
        print_error "Nginx config test failed."
        return 1
    fi
    service_reload nginx
    print_ok "Nginx reloaded successfully."
}

_domain_is_valid() {
    local domain="$1"
    [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

_domain_slug() {
    local domain="$1"
    echo "$domain" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

_write_domain_state() {
    local domain="$1"
    local type="$2"
    local backend_target="${3:-}"
    local php_version="${4:-}"
    local php_socket="${5:-}"

    ensure_dir "$OPS_DOMAINS_DIR"
    write_file "${OPS_DOMAINS_DIR}/${domain}.conf" <<EOF
DOMAIN="${domain}"
DOMAIN_BACKEND_TYPE="${type}"
DOMAIN_BACKEND_TARGET="${backend_target}"
DOMAIN_PHP_VERSION="${php_version}"
DOMAIN_PHP_SOCKET="${php_socket}"
DOMAIN_WEB_ROOT="/var/www/${domain}"
DOMAIN_CREATED="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
}

_create_site_from_template() {
    local template="$1"
    local output="$2"
    shift 2
    render_template "$template" "$@" | write_file "$output"
}

_install_certbot_snap() {
    if ! command -v snap >/dev/null 2>&1; then
        apt_update
        apt_install snapd
        systemctl enable --now snapd
    fi
    snap install core || true
    snap refresh core || true
    snap install --classic certbot || true
    ln -sf /snap/bin/certbot /usr/bin/certbot
}

# Public menu entry - Domains & Nginx
menu_nginx() {
    while true; do
        print_section "Domains & Nginx Management"
        echo "  1) List domains"
        echo "  2) Add new domain"
        echo "  3) Edit domain"
        echo "  4) Remove domain"
        echo "  5) Test Nginx config & reload"
        echo "  6) Install / update Nginx"
        echo "  0) Back"
        echo ""
        read -r -p "Select: " choice
        case "$choice" in
            1) list_domains ;;
            2) nginx_prompt_add_domain ;;
            3) print_warn "Edit domain: not implemented yet." ;;
            4) nginx_prompt_remove_domain ;;
            5) _nginx_test_and_reload ;;
            6) install_nginx ;;
            0) return ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}

# Public menu entry - SSL Management
menu_ssl() {
    while true; do
        print_section "SSL Management"
        echo "  1) Issue SSL certificate for a domain"
        echo "  2) Renew all certificates"
        echo "  3) Show certificate status"
        echo "  4) Install / repair Certbot (snap)"
        echo "  0) Back"
        echo ""
        read -r -p "Select: " choice
        case "$choice" in
            1) ssl_issue_cert ;;
            2) ssl_renew_all ;;
            3) ssl_list_certs ;;
            4) ssl_install_certbot ;;
            0) return ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}

# install_nginx: install + tune nginx.conf per OPS_TIER, ensure default deny
install_nginx() {
    print_section "Install Nginx"
    apt_update
    apt_install nginx
    service_enable nginx
    service_start nginx

    _nginx_apply_global_tuning
    create_default_deny
    _nginx_test_and_reload
}

# create_default_deny: always keep a default deny vhost enabled
create_default_deny() {
    print_section "Ensure Default Deny Vhost"
    _nginx_ensure_default_tls_cert

    local tpl="${NGINX_TEMPLATE_DIR}/default-deny.conf.tpl"
    local available="${NGINX_SITES_AVAILABLE}/${NGINX_DEFAULT_DENY_NAME}"
    local enabled="${NGINX_SITES_ENABLED}/${NGINX_DEFAULT_DENY_NAME}"

    _create_site_from_template "$tpl" "$available" \
        "SELF_SIGNED_CERT=${NGINX_DEFAULT_CERT}" \
        "SELF_SIGNED_KEY=${NGINX_DEFAULT_KEY}"

    safe_symlink "$available" "$enabled"
    log_info "Default deny vhost is present and enabled."
}

list_domains() {
    print_section "Domain List"
    ensure_dir "$OPS_DOMAINS_DIR"
    if ! ls "${OPS_DOMAINS_DIR}"/*.conf >/dev/null 2>&1; then
        print_warn "No domain state files found in ${OPS_DOMAINS_DIR}"
        return 0
    fi

    local state_file domain type backend
    for state_file in "${OPS_DOMAINS_DIR}"/*.conf; do
        domain=$(grep '^DOMAIN=' "$state_file" | head -n1 | cut -d= -f2- | tr -d '"')
        type=$(grep '^DOMAIN_BACKEND_TYPE=' "$state_file" | head -n1 | cut -d= -f2- | tr -d '"')
        backend=$(grep '^DOMAIN_BACKEND_TARGET=' "$state_file" | head -n1 | cut -d= -f2- | tr -d '"')
        echo "  - ${domain} (${type}) ${backend:+-> ${backend}}"
    done
}

nginx_prompt_add_domain() {
    print_section "Add New Domain"
    prompt_input "Enter domain (e.g. example.com)"
    local domain="$REPLY"

    echo "  1) Node.js"
    echo "  2) PHP site"
    echo "  3) Static site"
    read -r -p "Select backend type: " _type_choice

    local type
    case "$_type_choice" in
        1) type="node" ;;
        2) type="php" ;;
        3) type="static" ;;
        *) print_warn "Invalid backend type."; return 1 ;;
    esac

    add_domain "$domain" "$type"
}

# add_domain <domain> <type>
add_domain() {
    local domain="${1:-}"
    local type="${2:-}"

    if [[ -z "$domain" || -z "$type" ]]; then
        print_error "Usage: add_domain <domain> <node|php|static>"
        return 1
    fi
    if ! _domain_is_valid "$domain"; then
        print_error "Invalid domain: $domain"
        return 1
    fi
    case "$type" in
        node|php|static) ;;
        *)
            print_error "Invalid type '$type'. Use node|php|static."
            return 1
            ;;
    esac

    ensure_dir "$NGINX_SITES_AVAILABLE"
    ensure_dir "$NGINX_SITES_ENABLED"
    ensure_dir "$OPS_DOMAINS_DIR"

    local available="${NGINX_SITES_AVAILABLE}/${domain}"
    local enabled="${NGINX_SITES_ENABLED}/${domain}"
    local web_root="/var/www/${domain}"
    local backend_target=""
    local php_version=""
    local php_socket=""
    local tpl

    if [[ "$type" == "static" || "$type" == "php" ]]; then
        ensure_dir "$web_root"
        chown "$ADMIN_USER":"www-data" "$web_root"
        chmod 755 "$web_root"
        log_info "Prepared web root ${web_root} with ${ADMIN_USER}:www-data and 755."
    fi

    case "$type" in
        node)
            local pm2_service port
            prompt_input "Enter PM2 service name (optional)"
            pm2_service="$REPLY"
            prompt_input "Enter Node.js port (localhost)"
            port="$REPLY"
            if [[ ! "$port" =~ ^[0-9]{2,5}$ ]]; then
                print_error "Invalid port: $port"
                return 1
            fi
            backend_target="127.0.0.1:${port}"
            tpl="${NGINX_TEMPLATE_DIR}/node_vhost.conf.tpl"
            _create_site_from_template "$tpl" "$available" \
                "DOMAIN=${domain}" \
                "PORT=${port}"
            if [[ -n "$pm2_service" ]]; then
                log_info "Operator selected PM2 service: ${pm2_service}"
            fi
            ;;
        php)
            local site_slug rendered
            prompt_input "Enter PHP version (e.g. 8.2)"
            php_version="$REPLY"
            if [[ ! "$php_version" =~ ^[0-9]+\.[0-9]+$ ]]; then
                print_error "Invalid PHP version: $php_version"
                return 1
            fi
            site_slug="$(_domain_slug "$domain")"
            php_socket="/run/php/php${php_version}-fpm-${site_slug}.sock"
            backend_target="$php_socket"
            tpl="${NGINX_TEMPLATE_DIR}/php_vhost.conf.tpl"
            rendered="$(render_template "$tpl" \
                "DOMAIN=${domain}" \
                "WEBROOT=${web_root}" \
                "PHP_VERSION=${php_version}")"
            rendered="$(printf '%s\n' "$rendered" | sed -E "s|fastcgi_pass[[:space:]]+unix:/run/php/php${php_version}-fpm\\.sock;|fastcgi_pass   unix:${php_socket};|")"
            printf '%s\n' "$rendered" | write_file "$available"
            ;;
        static)
            backend_target="$web_root"
            tpl="${NGINX_TEMPLATE_DIR}/static_vhost.conf.tpl"
            _create_site_from_template "$tpl" "$available" \
                "DOMAIN=${domain}" \
                "WEBROOT=${web_root}"
            ;;
    esac

    safe_symlink "$available" "$enabled"
    create_default_deny
    _write_domain_state "$domain" "$type" "$backend_target" "$php_version" "$php_socket"

    _nginx_test_and_reload
    print_ok "Domain added: ${domain} (${type})"
    print_warn "SSL not issued here. Use SSL Management to issue certificate."
}

nginx_prompt_remove_domain() {
    print_section "Remove Domain"
    prompt_input "Enter domain to remove"
    remove_domain "$REPLY"
}

# remove_domain <domain>
remove_domain() {
    local domain="${1:-}"
    if [[ -z "$domain" ]]; then
        print_error "Usage: remove_domain <domain>"
        return 1
    fi

    local confirm_ans
    read -r -p "Remove domain ${domain}? This will delete Nginx config. [y/N]: " confirm_ans
    if [[ "${confirm_ans,,}" != "y" ]]; then
        print_warn "Cancelled."
        return 0
    fi

    rm -f "${NGINX_SITES_ENABLED}/${domain}"
    rm -f "${NGINX_SITES_AVAILABLE}/${domain}"
    rm -f "${OPS_DOMAINS_DIR}/${domain}.conf"

    create_default_deny
    _nginx_test_and_reload
    echo "Web root /var/www/${domain} NOT deleted — remove manually if needed."
}

# issue_ssl <domain>
issue_ssl() {
    local domain="${1:-}"
    if [[ -z "$domain" ]]; then
        print_error "Usage: issue_ssl <domain>"
        return 1
    fi
    if ! _domain_is_valid "$domain"; then
        print_error "Invalid domain: $domain"
        return 1
    fi

    create_default_deny
    _install_certbot_snap
    certbot --nginx -d "$domain"

    local nine_router_domain
    nine_router_domain=$(ops_conf_get "nine-router.conf" "NINE_ROUTER_DOMAIN" || true)
    if [[ "$domain" == "$nine_router_domain" ]] && [[ -f /opt/9router/.env ]]; then
        sed -i 's/AUTH_COOKIE_SECURE=false/AUTH_COOKIE_SECURE=true/g' /opt/9router/.env
        pm2 restart nine-router
        ops_conf_set "nine-router.conf" "NINE_ROUTER_SSL" "yes"
        log_info "Enabled AUTH_COOKIE_SECURE=true for 9router and restarted PM2 app."
    fi

    nginx -t || true
    curl -I "https://${domain}" || true
    certbot certificates || true
}

# Backward-compatible wrappers used by current callers.
nginx_install() { install_nginx; }
nginx_apply_tuning() { _nginx_apply_global_tuning; _nginx_test_and_reload; }
nginx_list_vhosts() { list_domains; }
nginx_create_node_vhost() {
    if [[ -n "${1:-}" ]]; then
        add_domain "$1" "node"
    else
        prompt_input "Enter domain"
        add_domain "$REPLY" "node"
    fi
}
nginx_create_php_vhost() {
    if [[ -n "${1:-}" ]]; then
        add_domain "$1" "php"
    else
        prompt_input "Enter domain"
        add_domain "$REPLY" "php"
    fi
}
nginx_create_static_vhost() {
    if [[ -n "${1:-}" ]]; then
        add_domain "$1" "static"
    else
        prompt_input "Enter domain"
        add_domain "$REPLY" "static"
    fi
}
nginx_remove_vhost() {
    if [[ -n "${1:-}" ]]; then
        remove_domain "$1"
    else
        nginx_prompt_remove_domain
    fi
}
nginx_status() { nginx -t && service_status nginx || true; }
ssl_install_certbot() { _install_certbot_snap; }
ssl_issue_cert() {
    prompt_input "Enter domain to issue SSL"
    issue_ssl "$REPLY"
}
ssl_renew_all() {
    _install_certbot_snap
    certbot renew
}
ssl_list_certs() {
    _install_certbot_snap
    certbot certificates
}
