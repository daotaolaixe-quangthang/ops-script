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

_nginx_disable_packaged_default_site() {
    local packaged_enabled="${NGINX_SITES_ENABLED}/default"
    local packaged_available="${NGINX_SITES_AVAILABLE}/default"

    if [[ -L "$packaged_enabled" ]]; then
        rm -f "$packaged_enabled"
        log_info "Disabled packaged nginx default site symlink: ${packaged_enabled}"
        return 0
    fi

    # If the distro dropped a real file into sites-enabled/default, move it aside so
    # our managed default deny server remains the only default_server on :80/:443.
    if [[ -f "$packaged_enabled" ]]; then
        backup_file "$packaged_enabled" >/dev/null || true
        rm -f "$packaged_enabled"
        log_info "Removed packaged nginx default site file: ${packaged_enabled}"
        return 0
    fi

    if [[ -f "$packaged_available" ]]; then
        log_info "Packaged nginx default site remains available but disabled: ${packaged_available}"
    fi
}

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

# _nginx_ensure_nine_router_rate_zone removed:
# 9router domain runs behind Cloudflare which handles rate limiting at the edge.
# nginx-level limit_req caused false-positive 429 on fast page navigation.
# The function was removed as it's no longer needed and caused issues.

_nginx_ensure_http_directive() {
    local conf="$1"
    local key="$2"
    local value="$3"
    local rendered="${key} ${value};"

    if grep -Eq "^[[:space:]]*${key}[[:space:]]+" "$conf"; then
        sed -i -E "s|^[[:space:]]*${key}[[:space:]]+.*;|    ${rendered}|" "$conf"
        return 0
    fi

    if awk -v rendered="$rendered" '
        BEGIN { inserted=0 }
        /^\s*http\s*\{/ && inserted==0 {
            print
            print "    " rendered
            inserted=1
            next
        }
        { print }
        END { if (inserted==0) exit 2 }
    ' "$conf" > "${conf}.tmp"; then
        mv "${conf}.tmp" "$conf"
    else
        rm -f "${conf}.tmp"
        return 1
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

    _nginx_ensure_http_directive "$conf" "server_tokens" "off"
    _nginx_ensure_http_directive "$conf" "ssl_protocols" "TLSv1.2 TLSv1.3"
    _nginx_ensure_http_directive "$conf" "ssl_prefer_server_ciphers" "off"
    _nginx_ensure_http_directive "$conf" "add_header Strict-Transport-Security" '"max-age=31536000; includeSubDomains" always'
    _nginx_ensure_http_directive "$conf" "add_header X-Frame-Options" '"SAMEORIGIN" always'
    _nginx_ensure_http_directive "$conf" "add_header X-Content-Type-Options" '"nosniff" always'
    _nginx_ensure_http_directive "$conf" "add_header Referrer-Policy" '"strict-origin-when-cross-origin" always'

    log_info "Applied nginx tuning: worker_processes=${worker_processes}, worker_connections=${worker_connections}, TLS/security baseline enforced."
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

_domain_ssl_cert_ready() {
    local domain="$1"
    [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]] && [[ -f "/etc/letsencrypt/live/${domain}/privkey.pem" ]]
}

_render_node_vhost() {
    local domain="$1"
    local port="$2"
    local available="$3"
    local ssl_http_block=""
    local ssl_https_block=""

    if _domain_ssl_cert_ready "$domain"; then
        ssl_http_block="    return 301 https://\$host\$request_uri;"
        ssl_https_block=$(cat <<EOF
server {
    listen 443 ssl;
    server_name ${domain};

    access_log /var/log/nginx/${domain}.access.log;
    error_log  /var/log/nginx/${domain}.error.log;

    location / {
        proxy_pass         http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection 'upgrade';
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;

        proxy_connect_timeout 60s;
        proxy_send_timeout    60s;
        proxy_read_timeout    60s;
    }

    location ~ /\\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}
EOF
)
    fi

    _create_site_from_template "${NGINX_TEMPLATE_DIR}/node_vhost.conf.tpl" "$available" \
        "DOMAIN=${domain}" \
        "PORT=${port}" \
        "SSL_HTTP_BLOCK=${ssl_http_block}" \
        "SSL_HTTPS_BLOCK=${ssl_https_block}"
}

_render_php_vhost() {
    local domain="$1"
    local web_root="$2"
    local php_version="$3"
    local php_socket="$4"
    local available="$5"
    local rendered ssl_http_block="" ssl_https_block=""

    if _domain_ssl_cert_ready "$domain"; then
        ssl_http_block="    return 301 https://\$host\$request_uri;"
        ssl_https_block=$(cat <<EOF
server {
    listen 443 ssl;
    server_name ${domain};

    root ${web_root};
    index index.php index.html;

    location ~ /\\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \\.php$ {
        include        snippets/fastcgi-php.conf;
        fastcgi_pass   unix:${php_socket};
        fastcgi_param  SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include        fastcgi_params;

        fastcgi_connect_timeout 60s;
        fastcgi_read_timeout    120s;
    }

    location ~* \\.(jpg|jpeg|png|gif|ico|css|js|woff2?)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }

    access_log  /var/log/nginx/${domain}.access.log;
    error_log   /var/log/nginx/${domain}.error.log;

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}
EOF
)
    fi

    rendered="$(render_template "${NGINX_TEMPLATE_DIR}/php_vhost.conf.tpl" \
        "DOMAIN=${domain}" \
        "WEBROOT=${web_root}" \
        "PHP_VERSION=${php_version}" \
        "SSL_HTTP_BLOCK=${ssl_http_block}" \
        "SSL_HTTPS_BLOCK=${ssl_https_block}")"
    rendered="$(printf '%s\n' "$rendered" | sed -E "s|fastcgi_pass[[:space:]]+unix:/run/php/php${php_version}-fpm\\.sock;|fastcgi_pass   unix:${php_socket};|")"
    printf '%s\n' "$rendered" | write_file "$available"
}

_render_static_vhost() {
    local domain="$1"
    local web_root="$2"
    local available="$3"
    local ssl_http_block=""
    local ssl_https_block=""

    if _domain_ssl_cert_ready "$domain"; then
        ssl_http_block="    return 301 https://\$host\$request_uri;"
        ssl_https_block=$(cat <<EOF
server {
    listen 443 ssl;
    server_name ${domain};

    root  ${web_root};
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~* \\.(jpg|jpeg|png|gif|ico|svg|css|js|woff2?|ttf|eot)$ {
        expires     30d;
        add_header  Cache-Control "public, immutable";
        access_log  off;
    }

    location ~ /\\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    location ~ \\.(env|log|sh|conf)$ {
        deny all;
    }

    access_log  /var/log/nginx/${domain}.access.log;
    error_log   /var/log/nginx/${domain}.error.log;

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}
EOF
)
    fi

    _create_site_from_template "${NGINX_TEMPLATE_DIR}/static_vhost.conf.tpl" "$available" \
        "DOMAIN=${domain}" \
        "WEBROOT=${web_root}" \
        "SSL_HTTP_BLOCK=${ssl_http_block}" \
        "SSL_HTTPS_BLOCK=${ssl_https_block}"
}

_rebuild_domain_vhost() {
    local domain="$1"
    local state_file="${OPS_DOMAINS_DIR}/${domain}.conf"
    local type backend_target php_version php_socket web_root available enabled port

    if [[ ! -f "$state_file" ]]; then
        log_warn "No state file for domain ${domain}; skipped vhost rebuild"
        return 0
    fi

    type=$(grep '^DOMAIN_BACKEND_TYPE=' "$state_file" | head -n1 | cut -d= -f2- | tr -d '"')
    backend_target=$(grep '^DOMAIN_BACKEND_TARGET=' "$state_file" | head -n1 | cut -d= -f2- | tr -d '"')
    php_version=$(grep '^DOMAIN_PHP_VERSION=' "$state_file" | head -n1 | cut -d= -f2- | tr -d '"')
    php_socket=$(grep '^DOMAIN_PHP_SOCKET=' "$state_file" | head -n1 | cut -d= -f2- | tr -d '"')
    web_root=$(grep '^DOMAIN_WEB_ROOT=' "$state_file" | head -n1 | cut -d= -f2- | tr -d '"')

    available="${NGINX_SITES_AVAILABLE}/${domain}"
    enabled="${NGINX_SITES_ENABLED}/${domain}"

    case "$type" in
        node)
            port="${backend_target#127.0.0.1:}"
            _render_node_vhost "$domain" "$port" "$available"
            ;;
        php)
            _render_php_vhost "$domain" "$web_root" "$php_version" "$php_socket" "$available"
            ;;
        static)
            _render_static_vhost "$domain" "$web_root" "$available"
            ;;
        *)
            log_warn "Unsupported backend type '${type}' for ${domain}; skipped vhost rebuild"
            return 0
            ;;
    esac

    safe_symlink "$available" "$enabled"
    log_info "Rebuilt vhost for ${domain} (type=${type}, ssl=$(_domain_ssl_cert_ready "$domain" && echo yes || echo no))"
}

_sync_all_managed_vhosts() {
    local state_file domain nine_router_domain

    ensure_dir "$OPS_DOMAINS_DIR"

    if ls "${OPS_DOMAINS_DIR}"/*.conf >/dev/null 2>&1; then
        for state_file in "${OPS_DOMAINS_DIR}"/*.conf; do
            domain=$(grep '^DOMAIN=' "$state_file" | head -n1 | cut -d= -f2- | tr -d '"')
            [[ -n "$domain" ]] || continue
            _rebuild_domain_vhost "$domain"
        done
    fi

    nine_router_domain=$(ops_conf_get "nine-router.conf" "NINE_ROUTER_DOMAIN" || true)
    if [[ -n "$nine_router_domain" ]] && declare -F link_nine_router_domain >/dev/null 2>&1; then
        log_info "Re-syncing nine-router vhost for ${nine_router_domain}"
        link_nine_router_domain "$nine_router_domain"
    fi
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

# nginx_apply_security_baseline
# Public function — applies global security tuning to nginx.conf.
# Idempotent: safe to run on a live server without disrupting sites.
# Applies: server_tokens off, ssl_protocols TLSv1.2+, HSTS, X-Frame-Options,
#          X-Content-Type-Options, Referrer-Policy.
nginx_apply_security_baseline() {
    print_section "Apply Nginx Security Baseline"
    require_root || return 1
    if ! command -v nginx >/dev/null 2>&1; then
        print_error "Nginx is not installed."
        return 1
    fi
    _nginx_apply_global_tuning
    if nginx -t >/dev/null 2>&1; then
        service_reload nginx
        print_ok "Nginx security baseline applied and reloaded."
    else
        print_error "Nginx config test failed after tuning — check /etc/nginx/nginx.conf"
        return 1
    fi
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
        echo "  7) Advanced web controls"
        echo "  8) Apply security baseline (server_tokens, TLS, headers)"
        echo "  0) Back"
        echo ""
        read -r -p "Select: " choice
        case "$choice" in
            1) list_domains                 ;;
            2) nginx_prompt_add_domain      ;;
            3) print_warn "Edit domain: not implemented yet." ;;
            4) nginx_prompt_remove_domain   ;;
            5) _nginx_test_and_reload       ;;
            6) install_nginx               ;;
            7) menu_nginx_web_controls     ;;
            8) nginx_apply_security_baseline ;;
            0) return                      ;;
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
    require_root || return 1
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

    _nginx_disable_packaged_default_site
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
    require_root || return 1
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
    require_root || return 1

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
            _render_node_vhost "$domain" "$port" "$available"
            if [[ -n "$pm2_service" ]]; then
                log_info "Operator selected PM2 service: ${pm2_service}"
            fi
            ;;
        php)
            local site_slug
            prompt_input "Enter PHP version (e.g. 8.2)"
            php_version="$REPLY"
            if [[ ! "$php_version" =~ ^[0-9]+\.[0-9]+$ ]]; then
                print_error "Invalid PHP version: $php_version"
                return 1
            fi
            site_slug="$(_domain_slug "$domain")"
            php_socket="/run/php/php${php_version}-fpm-${site_slug}.sock"
            backend_target="$php_socket"
            _render_php_vhost "$domain" "$web_root" "$php_version" "$php_socket" "$available"
            ;;
        static)
            backend_target="$web_root"
            _render_static_vhost "$domain" "$web_root" "$available"
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
    require_root || return 1
    prompt_input "Enter domain to remove"
    remove_domain "$REPLY"
}

# remove_domain <domain>
remove_domain() {
    local domain="${1:-}"
    require_root || return 1
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
    require_root || return 1
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

    log_info "Post-issue SSL sync for managed vhosts"
    _rebuild_domain_vhost "$domain"

    local nine_router_domain
    nine_router_domain=$(ops_conf_get "nine-router.conf" "NINE_ROUTER_DOMAIN" || true)
    if [[ "$domain" == "$nine_router_domain" ]] && declare -F link_nine_router_domain >/dev/null 2>&1; then
        log_info "Re-rendering nine-router vhost after SSL issuance for ${domain}."
        link_nine_router_domain "$domain"
    fi

    _nginx_test_and_reload || true
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
    require_root || return 1
    _install_certbot_snap
    certbot renew
    log_info "Post-renew SSL sync for all managed vhosts"
    _sync_all_managed_vhosts
    _nginx_test_and_reload || true
}
ssl_list_certs() {
    _install_certbot_snap
    certbot certificates
}

# ── P2-03A: Advanced Web Controls ────────────────────────────

NGINX_SNIPPETS_DIR="/etc/nginx/snippets"

menu_nginx_web_controls() {
    while true; do
        print_section "Advanced Web Controls"
        echo "  1) Enable Cloudflare real IP logging"
        echo "  2) Remove Cloudflare real IP snippet"
        echo "  3) Add custom X-Powered-By header"
        echo "  4) Remove custom X-Powered-By snippet"
        echo "  0) Back"
        echo ""
        read -r -p "Select: " choice
        case "$choice" in
            1) nginx_enable_cloudflare_real_ip || true; press_enter ;;
            2) nginx_remove_cloudflare_real_ip || true; press_enter ;;
            3) nginx_add_custom_powered_by     || true; press_enter ;;
            4) nginx_remove_custom_powered_by  || true; press_enter ;;
            0) return                                  ;;
            *) print_warn "Invalid option"             ;;
        esac
    done
}

nginx_enable_cloudflare_real_ip() {
    print_section "Enable Cloudflare Real IP Logging"
    require_root || return 1

    local tpl="${NGINX_TEMPLATE_DIR}/cloudflare-real-ip.conf.tpl"
    local snippet="${NGINX_SNIPPETS_DIR}/cloudflare-real-ip.conf"

    if [[ ! -f "$tpl" ]]; then
        print_error "Template not found: $tpl"
        return 1
    fi

    ensure_dir "$NGINX_SNIPPETS_DIR"
    backup_file "$snippet" >/dev/null || true
    cp "$tpl" "$snippet"
    chmod 644 "$snippet"

    print_ok "Snippet installed: $snippet"
    echo ""
    print_warn "Next step: add the following to each server {} block behind Cloudflare:"
    echo "    include /etc/nginx/snippets/cloudflare-real-ip.conf;"
    print_warn "Then run: nginx -t && systemctl reload nginx"
    print_warn "Rollback: remove the include line and run 'Remove Cloudflare real IP snippet'."
    log_info "nginx_enable_cloudflare_real_ip: snippet installed at $snippet"
}

nginx_remove_cloudflare_real_ip() {
    print_section "Remove Cloudflare Real IP Snippet"
    require_root || return 1
    local snippet="${NGINX_SNIPPETS_DIR}/cloudflare-real-ip.conf"
    if [[ ! -f "$snippet" ]]; then
        print_warn "Snippet not found: $snippet (nothing to remove)"
        return 0
    fi
    if ! prompt_confirm "Remove $snippet?"; then
        print_warn "Aborted."
        return 0
    fi
    backup_file "$snippet" >/dev/null || true
    rm -f "$snippet"
    print_ok "Removed: $snippet"
    print_warn "Also remove any 'include .../cloudflare-real-ip.conf' lines from your site configs."
    print_warn "Run: nginx -t && systemctl reload nginx"
    log_info "nginx_remove_cloudflare_real_ip: done"
}

nginx_add_custom_powered_by() {
    print_section "Add Custom X-Powered-By Header"
    require_root || return 1

    local tpl="${NGINX_TEMPLATE_DIR}/custom-powered-by.conf.tpl"
    local snippet="${NGINX_SNIPPETS_DIR}/custom-powered-by.conf"

    if [[ ! -f "$tpl" ]]; then
        print_error "Template not found: $tpl"
        return 1
    fi

    prompt_input "X-Powered-By value (e.g. 'MyApp/2.0')"
    local header_value="$REPLY"
    if [[ -z "$header_value" ]]; then
        print_error "Header value cannot be empty."
        return 1
    fi

    ensure_dir "$NGINX_SNIPPETS_DIR"
    backup_file "$snippet" >/dev/null || true
    sed "s|{{VALUE}}|${header_value}|g" "$tpl" > "$snippet"
    chmod 644 "$snippet"

    print_ok "Snippet installed: $snippet"
    echo ""
    print_warn "Next step: add to the relevant server {} block:"
    echo "    include /etc/nginx/snippets/custom-powered-by.conf;"
    print_warn "Also set expose_php = Off in php.ini to hide the default PHP header."
    print_warn "Run: nginx -t && systemctl reload nginx"
    log_info "nginx_add_custom_powered_by: header_value=[redacted]"
}

nginx_remove_custom_powered_by() {
    print_section "Remove Custom X-Powered-By Snippet"
    require_root || return 1
    local snippet="${NGINX_SNIPPETS_DIR}/custom-powered-by.conf"
    if [[ ! -f "$snippet" ]]; then
        print_warn "Snippet not found: $snippet (nothing to remove)"
        return 0
    fi
    if ! prompt_confirm "Remove $snippet?"; then
        print_warn "Aborted."
        return 0
    fi
    backup_file "$snippet" >/dev/null || true
    rm -f "$snippet"
    print_ok "Removed: $snippet"
    print_warn "Also remove any 'include .../custom-powered-by.conf' lines from site configs."
    print_warn "Run: nginx -t && systemctl reload nginx"
    log_info "nginx_remove_custom_powered_by: done"
}
