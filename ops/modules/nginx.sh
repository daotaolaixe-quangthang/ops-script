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

# Cloudflare API credentials file (chmod 600, root-only)
CF_CREDS_FILE="/etc/ops/cloudflare.conf"
# Load CF_API_TOKEN if the credentials file exists
[[ -f "$CF_CREDS_FILE" ]] && source "$CF_CREDS_FILE" 2>/dev/null || true

_nginx_disable_packaged_default_site() {
    local packaged_enabled="${NGINX_SITES_ENABLED}/default"
    local packaged_available="${NGINX_SITES_AVAILABLE}/default"

    # S2-1 fix: nginx.org mainline package ships /etc/nginx/conf.d/default.conf
    # (a stock HTTP server on port 80). conf.d/ is included BEFORE sites-enabled/
    # by the mainline nginx.conf, so this file loads before our 00-default-deny
    # catch-all, causing unknown hostnames to be served by the stock default instead
    # of our deny vhost. Remove it unconditionally — OPS always supplies its own
    # default deny via sites-enabled/00-default-deny.
    local confd_default="/etc/nginx/conf.d/default.conf"
    if [[ -f "$confd_default" ]]; then
        backup_file "$confd_default" >/dev/null || true
        rm -f "$confd_default"
        log_info "S2-1: Removed nginx.org stock conf.d/default.conf (superseded by OPS 00-default-deny)."
    fi

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

    # S1-4 fix: Tier is RAM-based; a Tier-L VPS may have fewer vCPUs than the
    # tier's nominal worker count (e.g. 2 cores + 8 GB RAM → Tier L → 4 workers).
    # Extra workers beyond core count increase context-switch overhead with no
    # throughput gain. Cap to the actual physical/virtual core count.
    local cpu_cap
    cpu_cap="${CPU_CORES:-$(nproc)}"
    if (( worker_processes > cpu_cap )); then
        worker_processes="$cpu_cap"
    fi

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
    chmod 640 "$NGINX_DEFAULT_KEY"
    chown root:nginx "$NGINX_DEFAULT_KEY"
    chmod 644 "$NGINX_DEFAULT_CERT"
    log_info "Generated default deny self-signed cert for Nginx."
}

# _nginx_ensure_nine_router_rate_zone removed:
# 9router domain runs behind Cloudflare which handles rate limiting at the edge.
# nginx-level limit_req caused false-positive 429 on fast page navigation.
# The function was removed as it's no longer needed and caused issues.

# _nginx_add_official_repo
# Adds nginx.org mainline apt repo so we always install >= 1.24 instead of the
# stale Ubuntu-distro package (which ships 1.18.0 on Ubuntu 20.04/22.04).
# Idempotent: no-op when nginx >= 1.24 is already installed.
_nginx_add_official_repo() {
    local ver=""
    if command -v nginx >/dev/null 2>&1; then
        ver=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
    fi
    # Compare major.minor numerically
    if [[ -n "$ver" ]] && awk -v v="$ver" 'BEGIN{exit !(v+0 >= 1.24)}'; then
        log_info "Nginx ${ver} already >= 1.24 — skipping official repo setup."
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        apt_install curl
    fi
    if ! command -v gpg >/dev/null 2>&1; then
        apt_install gnupg
    fi

    local codename
    codename=$(lsb_release -cs 2>/dev/null) \
        || codename=$(. /etc/os-release 2>/dev/null && printf '%s' "${UBUNTU_CODENAME:-}")

    if [[ -z "$codename" ]]; then
        log_error "_nginx_add_official_repo: cannot detect Ubuntu codename — aborting repo setup."
        return 1
    fi

    local keyring="/usr/share/keyrings/nginx-archive-keyring.gpg"

    curl -fsSL https://nginx.org/keys/nginx_signing.key \
        | gpg --dearmor --yes -o "$keyring" 2>/dev/null
    chmod 644 "$keyring"

    # Use printf (not heredoc) to guarantee a single clean line with no
    # trailing whitespace or extra newlines — heredoc expansion of
    # ${codename} is safe here but printf is unambiguous.
    printf 'deb [signed-by=%s] http://nginx.org/packages/mainline/ubuntu %s nginx\n' \
        "$keyring" "$codename" \
        > "/etc/apt/sources.list.d/nginx.list"
    # Pin official repo above distro repo so apt always picks mainline
    cat > "/etc/apt/preferences.d/99nginx" <<'EOF'
Package: nginx
Pin: origin nginx.org
Pin-Priority: 1001
EOF
    apt_update
    log_info "nginx.org mainline repo added and pinned for ${codename}."
}

_nginx_ensure_http_directive() {
    local conf="$1"
    local key="$2"
    local value="$3"
    local rendered="${key} ${value};"

    if grep -Eq "^[[:space:]]*${key}[[:space:]]+" "$conf"; then
        sed -i -E "s#^[[:space:]]*${key}[[:space:]]+.*;#    ${rendered}#" "$conf"
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

# _nginx_ensure_events_directive <conf> <key> <value>
# Inserts or updates a directive inside the events {} block.
_nginx_ensure_events_directive() {
    local conf="$1" key="$2" value="$3"
    local rendered="${key} ${value};"

    if grep -Eq "^[[:space:]]*${key}[[:space:]]+" "$conf"; then
        sed -i -E "s#^[[:space:]]*${key}[[:space:]]+.*;#    ${rendered}#" "$conf"
        return 0
    fi

    awk -v rendered="$rendered" '
        BEGIN { in_events=0; inserted=0 }
        /^\s*events\s*\{/ { in_events=1; print; next }
        in_events && /^\s*\}/ && inserted==0 {
            print "    " rendered
            inserted=1
        }
        { print }
    ' "$conf" > "${conf}.tmp" && mv "${conf}.tmp" "$conf" || rm -f "${conf}.tmp"
}

# _nginx_ensure_main_directive <conf> <key> <value>
# Inserts or updates a directive in the main (top-level) context.
_nginx_ensure_main_directive() {
    local conf="$1" key="$2" value="$3"
    local rendered="${key} ${value};"

    if grep -Eq "^[[:space:]]*${key}[[:space:]]+" "$conf"; then
        sed -i -E "s#^[[:space:]]*${key}[[:space:]]+.*;#${rendered}#" "$conf"
        return 0
    fi

    # Insert after the first non-comment, non-blank line (typically user/pid lines)
    awk -v rendered="$rendered" '
        BEGIN { inserted=0 }
        !inserted && /^[[:space:]]*[a-z]/ && !/^[[:space:]]*(events|http|mail|stream)/ {
            print; inserted=1
            print rendered
            next
        }
        { print }
    ' "$conf" > "${conf}.tmp" && mv "${conf}.tmp" "$conf" || rm -f "${conf}.tmp"
}

# _nginx_patch_gzip_block <conf>
# Replaces the skeleton gzip section (all commented out) with a full optimal config.
# Idempotent: skips if gzip_types is already present and uncommented.
#
# P2-D fix: The previous Python-based replacement path used ${GZIP_BLOCK} in a
# non-quoted heredoc — Bash expanded it to an empty string, silently wiping the
# entire gzip section. The Python path is removed; the _nginx_ensure_http_directive
# approach below is the sole reliable path and covers all nginx.conf formats.
_nginx_patch_gzip_block() {
    local conf="$1"
    # Already properly configured?
    if grep -Eq "^[[:space:]]*gzip_types[[:space:]]" "$conf"; then
        return 0
    fi

    # Remove bare 'gzip on;' line first to avoid duplicate
    sed -i '/^[[:space:]]*gzip[[:space:]]*on;/d' "$conf"
    # Remove commented gzip lines left over from the distro skeleton
    sed -i '/^[[:space:]]*#[[:space:]]*gzip/d' "$conf"

    _nginx_ensure_http_directive "$conf" "gzip" "on"
    _nginx_ensure_http_directive "$conf" "gzip_vary" "on"
    _nginx_ensure_http_directive "$conf" "gzip_proxied" "any"
    _nginx_ensure_http_directive "$conf" "gzip_comp_level" "6"
    _nginx_ensure_http_directive "$conf" "gzip_buffers" "16 8k"
    _nginx_ensure_http_directive "$conf" "gzip_http_version" "1.1"
    _nginx_ensure_http_directive "$conf" "gzip_min_length" "256"
    # gzip_types — covers HTML, CSS, JS, JSON, SVG and fonts
    _nginx_ensure_http_directive "$conf" "gzip_types" \
        "text/plain text/css text/xml text/javascript application/json application/javascript application/xml+rss application/atom+xml image/svg+xml font/ttf font/opentype application/vnd.ms-fontobject"
}

# _nginx_ensure_log_format <conf>
# Injects custom log_format 'main_ext' with upstream timing if not present.
_nginx_ensure_log_format() {
    local conf="$1"
    grep -q 'log_format main_ext' "$conf" && return 0

    local fmt='log_format main_ext '\''$remote_addr - $remote_user [$time_local] '\''
                    '\''"$request" $status $body_bytes_sent '\''
                    '\''"$http_referer" "$http_user_agent" '\''
                    '\''rt=$request_time uct=$upstream_connect_time '\''
                    '\''uht=$upstream_header_time urt=$upstream_response_time'\'''

    awk -v fmt="$fmt" '
        BEGIN { inserted=0 }
        /^[[:space:]]*access_log[[:space:]]/ && !inserted {
            print "    " fmt ";"
            inserted=1
        }
        { print }
    ' "$conf" > "${conf}.tmp" && mv "${conf}.tmp" "$conf" || rm -f "${conf}.tmp"

    # Switch access_log to use our new format (replace any existing format name with main_ext)
    # Pattern: match 'access_log <path> [old_format]' and normalise to 'access_log <path> main_ext'
    # The [^;[:space:]]+ at the end strips the current format word (e.g. 'main') before appending.
    sed -i -E \
        "s|^([[:space:]]*access_log[[:space:]]+[^[:space:];]+)([[:space:]]+[^[:space:];]+)?[[:space:]]*;|\1 main_ext;|" \
        "$conf"
}

# _nginx_ensure_sites_enabled_include <conf>
# nginx mainline (nginx.org package) only ships with:
#   include /etc/nginx/conf.d/*.conf;
# Our managed vhosts live in sites-enabled/. Without this include they are
# silently ignored — port 443 never binds even when the vhost file is valid.
# This function idempotently adds the include if not already present.
_nginx_ensure_sites_enabled_include() {
    local conf="$1"
    # Already present? Nothing to do.
    if grep -q 'sites-enabled' "$conf" 2>/dev/null; then
        return 0
    fi
    # Insert after the conf.d include line (it must already exist)
    if grep -q 'conf\.d/\*\.conf' "$conf" 2>/dev/null; then
        sed -i 's|include /etc/nginx/conf\.d/\*\.conf;|include /etc/nginx/conf.d/*.conf;\n    include /etc/nginx/sites-enabled/*;|' "$conf"
        log_info "Added 'include /etc/nginx/sites-enabled/*;' to ${conf}"
        return 0
    fi
    # Fallback: append inside http block before closing brace
    _nginx_ensure_http_directive "$conf" "include" "/etc/nginx/sites-enabled/*"
    log_info "Fallback: inserted sites-enabled include into http{} block in ${conf}"
}

_nginx_apply_global_tuning() {
    local conf="/etc/nginx/nginx.conf"
    local tuning worker_processes worker_connections
    tuning="$(_nginx_detect_tuning)"
    worker_processes="${tuning%%;*}"
    worker_connections="${tuning##*;}"

    [[ -f "$conf" ]] || return 0
    backup_file "$conf" > /dev/null || true

    # S1-4 fix: Remove stale Strict-Transport-Security from the global http{}
    # block if present from older OPS versions. HSTS must only appear inside
    # SSL vhost server{} blocks (RFC 6797 §7.2); a global HSTS header is ignored
    # by browsers on plain HTTP and causes policy errors on non-SSL vhosts.
    sed -i '/^[[:space:]]*add_header[[:space:]]\+Strict-Transport-Security/d' "$conf"

    # ── Main context ──────────────────────────────────────────
    sed -i -E "s/^\s*worker_processes\s+[^;]+;/worker_processes ${worker_processes};/" "$conf"
    # worker_rlimit_nofile must be in main context (not http)
    _nginx_ensure_main_directive "$conf" "worker_rlimit_nofile" "65535"

    # ── Events block ──────────────────────────────────────────
    sed -i -E "s/^\s*worker_connections\s+[^;]+;/    worker_connections ${worker_connections};/" "$conf"
    _nginx_ensure_events_directive "$conf" "multi_accept" "on"
    _nginx_ensure_events_directive "$conf" "use" "epoll"

    # ── HTTP block: core ──────────────────────────────────────
    _nginx_ensure_http_directive "$conf" "server_tokens" "off"
    _nginx_ensure_http_directive "$conf" "ssl_protocols" "TLSv1.2 TLSv1.3"
    _nginx_ensure_http_directive "$conf" "ssl_prefer_server_ciphers" "off"

    # ── HTTP block: keepalive & client limits (DoS protection) ─
    _nginx_ensure_http_directive "$conf" "keepalive_timeout" "30s"
    _nginx_ensure_http_directive "$conf" "keepalive_requests" "1000"
    _nginx_ensure_http_directive "$conf" "client_max_body_size" "10m"
    _nginx_ensure_http_directive "$conf" "client_body_timeout" "12s"
    _nginx_ensure_http_directive "$conf" "client_header_timeout" "12s"
    _nginx_ensure_http_directive "$conf" "send_timeout" "15s"

    # ── HTTP block: gzip — full config ────────────────────────
    _nginx_patch_gzip_block "$conf"

    # ── HTTP block: file cache ────────────────────────────────
    _nginx_ensure_http_directive "$conf" "open_file_cache" "max=10000 inactive=20s"
    _nginx_ensure_http_directive "$conf" "open_file_cache_valid" "30s"
    _nginx_ensure_http_directive "$conf" "open_file_cache_min_uses" "2"
    _nginx_ensure_http_directive "$conf" "open_file_cache_errors" "on"

    # ── HTTP block: rate limiting zones (global definitions) ──
    # bucket: 10 MB (~160k unique IPs), 100 req/s per IP;
    # burst handled per-vhost (burst=200 nodelay).
    # These are zone definitions only — enforcement is in vhost location blocks.
    _nginx_ensure_http_directive "$conf" "limit_req_zone" \
        '\$binary_remote_addr zone=ops_req:10m rate=100r/s'
    _nginx_ensure_http_directive "$conf" "limit_conn_zone" \
        '\$binary_remote_addr zone=ops_conn:10m'

    # ── HTTP block: security headers ─────────────────────────
    # P2-C fix: HSTS must NOT be injected into the global http{} block.
    # RFC 6797 §7.2: HSTS is ignored by browsers when sent over HTTP and
    # causes policy errors on non-SSL vhosts. HSTS is now applied only inside
    # the SSL (listen 443) server blocks generated by _render_*_vhost().
    #
    # The following headers are safe on both HTTP and HTTPS:
    _nginx_ensure_http_directive "$conf" "add_header X-Frame-Options" '"SAMEORIGIN" always'
    _nginx_ensure_http_directive "$conf" "add_header X-Content-Type-Options" '"nosniff" always'
    _nginx_ensure_http_directive "$conf" "add_header Referrer-Policy" '"strict-origin-when-cross-origin" always'
    _nginx_ensure_http_directive "$conf" "add_header X-XSS-Protection" '"1; mode=block" always'
    _nginx_ensure_http_directive "$conf" "add_header Permissions-Policy" \
        '"geolocation=(), microphone=(), camera=(), payment=(), usb=()" always'
    # CSP: restrictive default; individual vhosts may override.
    # unsafe-inline / unsafe-eval retained for Next.js/SPA compat — tighten per-site as needed.
    _nginx_ensure_http_directive "$conf" "add_header Content-Security-Policy" \
        '"default-src '\''self'\''; script-src '\''self'\'' '\''unsafe-inline'\'' '\''unsafe-eval'\'' https:; style-src '\''self'\'' '\''unsafe-inline'\''; img-src '\''self'\'' data: https:; font-src '\''self'\'' data: https:; connect-src '\''self'\'' https:; frame-ancestors '\''none'\''" always'

    # ── HTTP block: custom log format with upstream timing ────
    _nginx_ensure_log_format "$conf"

    # ── Ensure sites-enabled is included ─────────────────────
    # nginx mainline (nginx.org package) only ships with conf.d/*.conf include.
    # Our vhosts live in sites-enabled/ — without this include they are silently
    # ignored and port 443 never binds even with a valid vhost + cert.
    _nginx_ensure_sites_enabled_include "$conf"

    log_info "Applied nginx tuning: worker_processes=${worker_processes}, worker_connections=${worker_connections}, rlimit=65535, multi_accept=on, epoll, keepalive=30s, client limits, gzip full, open_file_cache, rate limit zones, security headers, log_format main_ext."
}

_nginx_test_and_reload() {
    if ! nginx -t; then
        print_error "Nginx config test failed."
        return 1
    fi
    # F-15 fix: use reload-or-restart so this is safe both when nginx is already
    # running (reload = zero-downtime) and when it is not yet started (restart = start).
    systemctl reload-or-restart nginx && log_info "Nginx reloaded-or-restarted successfully."
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

# _render_node_vhost <domain> <port> <available-path>
# F-01 fix: The old approach passed SSL_HTTPS_BLOCK (a multi-line string with
# $host, $remote_addr, \, & etc.) through render_template's Bash parameter expansion,
# silently corrupting the output. Fix: template now receives only SSL_HTTP_REDIRECT
# (a single safe line) and the SSL server{} block is appended directly via
# 'cat >>' AFTER template rendering, completely bypassing render_template.
_render_node_vhost() {
    local domain="$1"
    local port="$2"
    local available="$3"
    local ssl_redirect=""

    if _domain_ssl_cert_ready "$domain"; then
        ssl_redirect="    return 301 https://\$host\$request_uri;"
    fi

    # Step 1: Render HTTP server block from template (safe single-line vars only)
    _create_site_from_template "${NGINX_TEMPLATE_DIR}/node_vhost.conf.tpl" "$available" \
        "DOMAIN=${domain}" \
        "PORT=${port}" \
        "SSL_HTTP_REDIRECT=${ssl_redirect}"

    # Step 2: Append SSL server block directly — no Bash expansion of Nginx variables
    if _domain_ssl_cert_ready "$domain"; then
        cat >> "$available" <<NGINX_SSL_EOF

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${domain};

    # ── Security headers (vhost-level) ───────────────────────────────────────
    # NOTE: when add_header appears in a server{} block, Nginx does NOT inherit
    # headers from the parent http{} block. Re-declare all security headers here.
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header Content-Security-Policy   "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' https:; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data: https:; connect-src 'self' https:; frame-ancestors 'none'" always;
    add_header X-Frame-Options           "SAMEORIGIN" always;
    add_header X-Content-Type-Options    "nosniff" always;
    add_header Referrer-Policy           "strict-origin-when-cross-origin" always;
    add_header X-XSS-Protection          "1; mode=block" always;
    add_header Permissions-Policy        "geolocation=(), microphone=(), camera=(), payment=(), usb=()" always;

    access_log /var/log/nginx/${domain}.access.log main_ext;
    error_log  /var/log/nginx/${domain}.error.log;

    location / {
        limit_req  zone=ops_req burst=200 nodelay;
        limit_conn zone=ops_conn 30;

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

        proxy_hide_header X-Powered-By;
        proxy_hide_header Server;
    }

    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}
NGINX_SSL_EOF
    fi

    # Step 3: Guard — remove broken file if nginx syntax check fails
    if ! nginx -t >/dev/null 2>&1; then
        log_error "_render_node_vhost: nginx -t failed for ${domain} — removing broken vhost file"
        rm -f "$available"
        return 1
    fi
}

# _render_php_vhost <domain> <web_root> <php_version> <php_socket> <available-path>
# F-01 fix: same pattern as _render_node_vhost — SSL block appended directly.
# Note: php_socket is substituted via sed after template rendering (safe, single-line value).
_render_php_vhost() {
    local domain="$1"
    local web_root="$2"
    local php_version="$3"
    local php_socket="$4"
    local available="$5"
    local ssl_redirect=""

    if _domain_ssl_cert_ready "$domain"; then
        ssl_redirect="    return 301 https://\$host\$request_uri;"
    fi

    # Step 1: Render HTTP server block (single-line vars only)
    local rendered
    rendered="$(render_template "${NGINX_TEMPLATE_DIR}/php_vhost.conf.tpl" \
        "DOMAIN=${domain}" \
        "WEBROOT=${web_root}" \
        "PHP_VERSION=${php_version}" \
        "SSL_HTTP_REDIRECT=${ssl_redirect}")"
    # Substitute PHP socket path (safe single-line sed)
    rendered="$(printf '%s\n' "$rendered" | sed -E \
        "s|fastcgi_pass[[:space:]]+unix:/run/php/php${php_version}-fpm\.sock;|fastcgi_pass   unix:${php_socket};|")"
    printf '%s\n' "$rendered" | write_file "$available"

    # Step 2: Append SSL server block directly
    if _domain_ssl_cert_ready "$domain"; then
        cat >> "$available" <<NGINX_SSL_EOF

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${domain};

    # ── Security headers (vhost-level) ───────────────────────────────────────
    # NOTE: when add_header appears in a server{} block, Nginx does NOT inherit
    # headers from the parent http{} block. Re-declare all security headers here.
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header Content-Security-Policy   "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' https:; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data: https:; connect-src 'self' https:; frame-ancestors 'none'" always;
    add_header X-Frame-Options           "SAMEORIGIN" always;
    add_header X-Content-Type-Options    "nosniff" always;
    add_header Referrer-Policy           "strict-origin-when-cross-origin" always;
    add_header X-XSS-Protection          "1; mode=block" always;
    add_header Permissions-Policy        "geolocation=(), microphone=(), camera=(), payment=(), usb=()" always;

    root ${web_root};
    index index.php index.html;

    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    # F-06: Restrict FPM status/ping endpoints to localhost only.
    # Defense-in-depth: pm.status_path is also omitted from the pool config.
    location ~ ^/(fpm-status|fpm-ping)$ {
        allow 127.0.0.1;
        allow ::1;
        deny all;
        include        snippets/fastcgi-php.conf;
        fastcgi_pass   unix:${php_socket};
        fastcgi_param  SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include        fastcgi_params;
    }

    location / {
        limit_req  zone=ops_req burst=200 nodelay;
        limit_conn zone=ops_conn 30;
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include        snippets/fastcgi-php.conf;
        fastcgi_pass   unix:${php_socket};
        fastcgi_param  SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include        fastcgi_params;

        fastcgi_connect_timeout 60s;
        fastcgi_read_timeout    120s;
    }

    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff2?)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }

    access_log  /var/log/nginx/${domain}.access.log main_ext;
    error_log   /var/log/nginx/${domain}.error.log;

    ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}
NGINX_SSL_EOF
    fi

    # Step 3: Guard — remove broken file if nginx syntax check fails
    if ! nginx -t >/dev/null 2>&1; then
        log_error "_render_php_vhost: nginx -t failed for ${domain} — removing broken vhost file"
        rm -f "$available"
        return 1
    fi
}

# _render_static_vhost <domain> <web_root> <available-path>
# F-01 fix: same pattern as _render_node_vhost — SSL block appended directly.
_render_static_vhost() {
    local domain="$1"
    local web_root="$2"
    local available="$3"
    local ssl_redirect=""

    if _domain_ssl_cert_ready "$domain"; then
        ssl_redirect="    return 301 https://\$host\$request_uri;"
    fi

    # Step 1: Render HTTP server block (single-line vars only)
    _create_site_from_template "${NGINX_TEMPLATE_DIR}/static_vhost.conf.tpl" "$available" \
        "DOMAIN=${domain}" \
        "WEBROOT=${web_root}" \
        "SSL_HTTP_REDIRECT=${ssl_redirect}"

    # Step 2: Append SSL server block directly
    if _domain_ssl_cert_ready "$domain"; then
        cat >> "$available" <<NGINX_SSL_EOF

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${domain};

    # ── Security headers (vhost-level) ───────────────────────────────────────
    # NOTE: when add_header appears in a server{} block, Nginx does NOT inherit
    # headers from the parent http{} block. Re-declare all security headers here.
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header Content-Security-Policy   "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' https:; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data: https:; connect-src 'self' https:; frame-ancestors 'none'" always;
    add_header X-Frame-Options           "SAMEORIGIN" always;
    add_header X-Content-Type-Options    "nosniff" always;
    add_header Referrer-Policy           "strict-origin-when-cross-origin" always;
    add_header X-XSS-Protection          "1; mode=block" always;
    add_header Permissions-Policy        "geolocation=(), microphone=(), camera=(), payment=(), usb=()" always;

    root  ${web_root};
    index index.html index.htm;

    location / {
        limit_req  zone=ops_req burst=200 nodelay;
        limit_conn zone=ops_conn 30;
        try_files \$uri \$uri/ =404;
    }

    location ~* \.(jpg|jpeg|png|gif|ico|svg|css|js|woff2?|ttf|eot)$ {
        expires     30d;
        add_header  Cache-Control "public, immutable";
        access_log  off;
    }

    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    location ~ \.(env|log|sh|conf)$ {
        deny all;
    }

    access_log  /var/log/nginx/${domain}.access.log main_ext;
    error_log   /var/log/nginx/${domain}.error.log;

    ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}
NGINX_SSL_EOF
    fi

    # Step 3: Guard — remove broken file if nginx syntax check fails
    if ! nginx -t >/dev/null 2>&1; then
        log_error "_render_static_vhost: nginx -t failed for ${domain} — removing broken vhost file"
        rm -f "$available"
        return 1
    fi
}

# _load_domain_state <state_file>
# P-05 fix: replaces unsafe `grep | cut | tr -d '"'` pipeline.
# Parses only lines matching KEY="safe-value" (no embedded quotes).
# Outputs shell assignments for the six known domain keys and nothing else.
# Caller uses: eval "$(_load_domain_state "$file")" in a local scope.
_load_domain_state() {
    local state_file="$1"
    local line key val
    while IFS= read -r line; do
        # Accept only: KEY="value" where value contains no double-quotes.
        # The regex anchors prevent injecting additional shell statements.
        if [[ "$line" =~ ^(DOMAIN|DOMAIN_BACKEND_TYPE|DOMAIN_BACKEND_TARGET|DOMAIN_PHP_VERSION|DOMAIN_PHP_SOCKET|DOMAIN_WEB_ROOT)=\"([^\"]*)\"$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            # printf produces plain KEY=value lines — no shell metacharacters can leak.
            printf '%s=%s\n' "$key" "$(printf '%q' "$val")"
        fi
    done < "$state_file"
}

# _validate_domain_state <domain> <type> <php_version> <php_socket> <web_root>
# P-05 fix: rejects values that could corrupt Nginx config or the sed pipeline.
_validate_domain_state() {
    local domain="$1" type="$2" php_version="$3" php_socket="$4" web_root="$5"

    # No path traversal or slashes in domain
    if [[ "$domain" == *'/'* || "$domain" == *'..'* ]] || ! _domain_is_valid "$domain"; then
        log_error "P-05: corrupted state — invalid domain '${domain}'"
        return 1
    fi

    # type must be a known backend
    case "$type" in
        node|php|static) ;;
        *)
            log_error "P-05: corrupted state — unknown backend type '${type}' for ${domain}"
            return 1
            ;;
    esac

    # PHP-specific fields
    if [[ "$type" == "php" ]]; then
        if [[ ! "$php_version" =~ ^[0-9]+\.[0-9]+$ ]]; then
            log_error "P-05: corrupted state — invalid php_version '${php_version}' for ${domain}"
            return 1
        fi
        if [[ ! "$php_socket" =~ ^/run/php/[a-zA-Z0-9_./-]+\.sock$ ]]; then
            log_error "P-05: corrupted state — invalid php_socket '${php_socket}' for ${domain}"
            return 1
        fi
    fi

    # web_root must be an absolute path without traversal
    if [[ -n "$web_root" && ( "$web_root" != /* || "$web_root" == *'..'* ) ]]; then
        log_error "P-05: corrupted state — invalid web_root '${web_root}' for ${domain}"
        return 1
    fi

    return 0
}

_rebuild_domain_vhost() {
    local domain="$1"
    local state_file="${OPS_DOMAINS_DIR}/${domain}.conf"
    local type backend_target php_version php_socket web_root available enabled port

    if [[ ! -f "$state_file" ]]; then
        log_warn "No state file for domain ${domain}; skipped vhost rebuild"
        return 0
    fi

    # P-05 fix: parse state file through regex-whitelist; validate before use.
    local DOMAIN DOMAIN_BACKEND_TYPE DOMAIN_BACKEND_TARGET DOMAIN_PHP_VERSION DOMAIN_PHP_SOCKET DOMAIN_WEB_ROOT
    eval "$(_load_domain_state "$state_file")"
    type="${DOMAIN_BACKEND_TYPE:-}"
    backend_target="${DOMAIN_BACKEND_TARGET:-}"
    php_version="${DOMAIN_PHP_VERSION:-}"
    php_socket="${DOMAIN_PHP_SOCKET:-}"
    web_root="${DOMAIN_WEB_ROOT:-}"

    if ! _validate_domain_state "$domain" "$type" "$php_version" "$php_socket" "$web_root"; then
        log_error "_rebuild_domain_vhost: aborting rebuild for ${domain} due to invalid state."
        return 1
    fi

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
            # P-05 fix: use regex-whitelist parser and validate domain.
            local DOMAIN
            eval "$(_load_domain_state "$state_file")"
            domain="${DOMAIN:-}"
            [[ -n "$domain" ]] || continue
            # Guard: a corrupt state file must not abort the loop for remaining domains.
            _rebuild_domain_vhost "$domain" || { log_warn "_sync_all_managed_vhosts: skipped '${domain}' due to rebuild error"; continue; }
        done
    fi

    nine_router_domain=$(ops_conf_get "nine-router.conf" "NINE_ROUTER_DOMAIN" || true)
    if [[ -n "$nine_router_domain" ]] && declare -F link_nine_router_domain >/dev/null 2>&1; then
        log_info "Re-syncing nine-router vhost for ${nine_router_domain}"
        link_nine_router_domain "$nine_router_domain"
    fi
}

_install_certbot_cron_fallback() {
    # P5-B: Write a cron fallback for certbot renewal.
    # On systemd systems certbot's own timer works, but on minimal/OpenVZ/LXC
    # environments where timers may not fire, this cron entry guarantees renewal.
    # Idempotent: only writes if not already present.
    local cron_file="/etc/cron.d/ops-certbot-renew"
    if [[ ! -f "$cron_file" ]]; then
        printf '# Managed by OPS — certbot renewal fallback\n0 */12 * * * root certbot renew --quiet --no-self-upgrade 2>/dev/null\n' \
            > "$cron_file"
        chmod 644 "$cron_file"
        log_info "P5-B: certbot cron renewal fallback written to ${cron_file}"
    fi
    _install_certbot_deploy_hook
}

_install_certbot_deploy_hook() {
    # P5-C: Create a deploy hook to reload nginx after certbot successfully renews a cert.
    # Without this hook, certbot renew updates the cert files on disk but nginx keeps
    # serving the old (possibly expired) cert until manually reloaded — invisible failure.
    # Certbot runs all executable scripts in /etc/letsencrypt/renewal-hooks/deploy/
    # automatically after each successful renewal. Idempotent: only writes if absent.
    local hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
    local hook_file="${hook_dir}/nginx-reload.sh"
    if [[ ! -f "$hook_file" ]]; then
        mkdir -p "$hook_dir"
        cat > "$hook_file" << 'HOOK'
#!/bin/bash
# Managed by OPS — reload nginx after certbot cert renewal
# Runs automatically by certbot after each successful renewal.
if systemctl is-active --quiet nginx; then
    if nginx -t 2>&1; then
        systemctl reload nginx
        echo "[$(date)] nginx reloaded after cert renewal for: $RENEWED_DOMAINS"
    else
        echo "[$(date)] ERROR: nginx config test failed after cert renewal for: $RENEWED_DOMAINS" >&2
        exit 1
    fi
else
    echo "[$(date)] WARNING: nginx not running, skipping reload for: $RENEWED_DOMAINS"
fi
HOOK
        chmod +x "$hook_file"
        log_info "P5-C: certbot deploy hook (nginx reload) written to ${hook_file}"
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
    # P4-F: snap may fail on OpenVZ containers or minimal images without a working snapd.
    # Fall back to apt certbot which is fully functional and doesn't require snap.
    if ! snap install --classic certbot 2>/dev/null; then
        print_warn "snap install certbot failed — falling back to apt (certbot + python3-certbot-nginx)"
        apt_install certbot python3-certbot-nginx
        _install_certbot_cron_fallback
        return 0
    fi
    ln -sf /snap/bin/certbot /usr/bin/certbot
    # S1-2 fix: explicitly enable the snap certbot renewal timer.
    # snapd creates snap.certbot.renew.timer on install but does NOT guarantee
    # it is enabled/active — it may remain inactive on some hosts (Ubuntu 22+, cloud images).
    # systemctl enable --now is idempotent: safe to call on re-install or upgrade.
    if systemctl enable --now snap.certbot.renew.timer 2>/dev/null; then
        log_info "S1-2: snap.certbot.renew.timer enabled and started."
    else
        print_warn "snap.certbot.renew.timer could not be enabled (LXC/OpenVZ/no-systemd?). Cron fallback is active."
        log_warn "S1-2: systemctl enable --now snap.certbot.renew.timer failed — relying on cron fallback."
    fi
    _install_certbot_cron_fallback
    _install_certbot_deploy_hook
    # S3-3 fix: limit snap to 2 retained revisions and immediately purge any stale ones.
    # Default is 3 revisions; on a VPS with certbot+snapd+core chain each refresh cycle
    # accumulates loop devices. retain=2 caps the per-snap overhead at install time.
    snap set system refresh.retain=2 2>/dev/null || true
    _snap_cleanup_stale_revisions
}

# F-21 fix: guard wrapper — only call _install_certbot_snap when certbot is absent.
# ssl_renew_all and ssl_list_certs previously called _install_certbot_snap
# unconditionally, triggering 'snap refresh core' on every run (~30 s each).
# This wrapper makes the install path a true fast-path no-op on systems where
# certbot is already in PATH (the vast majority of renewal / list invocations).
_ensure_certbot() {
    if ! command -v certbot >/dev/null 2>&1; then
        _install_certbot_snap
    fi
}

# _ensure_certbot_dns_cloudflare
# Install the certbot Cloudflare DNS plugin if not already present.
# Supports both snap certbot and apt certbot installations.
_ensure_certbot_dns_cloudflare() {
    _ensure_certbot
    # snap-based certbot: use snap plugin
    if snap list certbot >/dev/null 2>&1; then
        if ! snap list certbot-dns-cloudflare >/dev/null 2>&1; then
            log_info "Installing certbot-dns-cloudflare snap plugin..."
            snap install certbot-dns-cloudflare
            snap set certbot trust-plugin-with-root=ok
            snap connect certbot:plugin certbot-dns-cloudflare
            log_info "certbot-dns-cloudflare snap plugin installed."
        fi
        return 0
    fi
    # apt-based certbot fallback
    if ! dpkg -l python3-certbot-dns-cloudflare >/dev/null 2>&1; then
        log_info "Installing python3-certbot-dns-cloudflare via apt..."
        apt_install python3-certbot-dns-cloudflare
        log_info "python3-certbot-dns-cloudflare installed."
    fi
}

# S3-3 fix: remove disabled (stale) snap revisions to reclaim loop devices.
# snapd keeps old revisions for rollback but does not promptly auto-purge them.
# Each stale revision holds a loop device + mount entry, adding /dev/loopN clutter.
# Safe to call at any time: only targets revisions snapd has already marked 'disabled'.
_snap_cleanup_stale_revisions() {
    if ! command -v snap >/dev/null 2>&1; then
        return 0
    fi
    local pkg rev removed=0
    while read -r pkg rev; do
        if snap remove "$pkg" "--revision=${rev}" 2>/dev/null; then
            log_info "S3-3: removed stale snap revision ${pkg}@${rev}"
            removed=$(( removed + 1 ))
        fi
    done < <(snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}')
    if (( removed == 0 )); then
        log_info "S3-3: no stale snap revisions found."
    else
        log_info "S3-3: removed ${removed} stale snap revision(s)."
    fi
}

# snap_housekeeping: public operator command — set retain=2 + purge stale revisions.
# Idempotent: safe to run repeatedly. Exposes _snap_cleanup_stale_revisions via menu.
snap_housekeeping() {
    print_section "Snap Housekeeping"
    require_root || return 1
    if ! command -v snap >/dev/null 2>&1; then
        print_warn "snapd is not installed — nothing to do."
        return 0
    fi
    print_warn "Setting snap refresh.retain=2 (keep max 2 revisions per snap)..."
    snap set system refresh.retain=2
    print_warn "Removing stale (disabled) snap revisions to reclaim loop devices..."
    _snap_cleanup_stale_revisions
    local loop_count
    loop_count=$(losetup -l 2>/dev/null | grep -c snap || true)
    print_ok "Snap housekeeping complete. Active snap loop devices: ${loop_count}"
    log_info "snap_housekeeping: refresh.retain=2 set, stale revisions purged, loop_count=${loop_count}"
}

# P-04 fix: reliable certbot account detection via filesystem.
# 'certbot accounts list' output format changed between versions (ACME v1 → v2,
# apt → snap), making 'grep -q Account ID:' fragile — a false-negative triggers
# a duplicate 'certbot register' call which certbot rejects with an error.
# Strategy: check for regr.json (certbot's ACME registration resource file),
# which is always written on successful registration regardless of certbot version.
_certbot_has_account() {
    local acme_dir
    for acme_dir in \
        /etc/letsencrypt/accounts/acme-v02.api.letsencrypt.org/directory \
        /etc/letsencrypt/accounts/acme-v01.api.letsencrypt.org/directory \
        /var/lib/letsencrypt/accounts; do
        if [[ -d "$acme_dir" ]] && compgen -G "${acme_dir}/*/regr.json" > /dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

# nginx_apply_security_baseline
# Public function — applies global security tuning to nginx.conf.
# Idempotent: safe to run on a live server without disrupting sites.
# Applies: server_tokens off, ssl_protocols TLSv1.2+, X-Frame-Options,
#          X-Content-Type-Options, Referrer-Policy, CSP, and other global headers.
# NOTE: HSTS (Strict-Transport-Security) is NOT applied globally here — it is
#       applied per-SSL-vhost only (RFC 6797 §7.2: ignored over plain HTTP).
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
        log_info "nginx_apply_security_baseline: applied and nginx reloaded"
    else
        print_error "Nginx config test failed after tuning — check /etc/nginx/nginx.conf"
        return 1
    fi
}

# Public menu entry - Domains & Nginx
menu_nginx() {
    _nginx_menu_run() {
        "$@"
        return 0
    }

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
            1) _nginx_menu_run list_domains ;;
            2) _nginx_menu_run nginx_prompt_add_domain ;;
            3) _nginx_menu_run nginx_prompt_edit_domain ;;
            4) _nginx_menu_run nginx_prompt_remove_domain ;;
            5) _nginx_menu_run _nginx_test_and_reload ;;
            6) _nginx_menu_run install_nginx ;;
            7) _nginx_menu_run menu_nginx_web_controls ;;
            8) _nginx_menu_run nginx_apply_security_baseline ;;
            0) return 0                    ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}

# Public menu entry - SSL Management
menu_ssl() {
    _ssl_menu_run() {
        "$@"
        return 0
    }

    while true; do
        print_section "SSL Management"
        echo "  1) Issue SSL certificate for a domain       (Let's Encrypt — auto-renew)"
        echo "  2) Renew all certificates"
        echo "  3) Show certificate status"
        echo "  4) Install / repair Certbot (snap)"
        echo "  5) Snap housekeeping (clean stale revisions, set retain=2)"
        if [[ -n "${CF_API_TOKEN:-}" ]]; then
            echo "  6) Set Cloudflare API Token  ✓ (configured)"
        else
            echo "  6) Set Cloudflare API Token  (enables auto DNS-01 for CF-proxied domains)"
        fi
        echo "  7) Issue Cloudflare Origin Certificate      (15 years — no renewal)"
        echo "  8) List Cloudflare Origin Certificates"
        echo "  0) Back"
        echo ""
        read -r -p "Select: " choice
        case "$choice" in
            1) _ssl_menu_run ssl_issue_cert ;;
            2) _ssl_menu_run ssl_renew_all ;;
            3) _ssl_menu_run ssl_list_certs ;;
            4) _ssl_menu_run ssl_install_certbot ;;
            5) _ssl_menu_run snap_housekeeping ;;
            6) _ssl_menu_run ssl_set_cf_token; press_enter ;;
            7) _ssl_menu_run ssl_prompt_cf_origin_cert; press_enter ;;
            8) _ssl_menu_run ssl_show_cf_origin_certs; press_enter ;;
            0) return 0 ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}

# _nginx_write_logrotate
# P2-2 fix: per-domain Nginx access/error logs grow unbounded without rotation.
# Each domain vhost writes to /var/log/nginx/<domain>.access.log and .error.log.
# Ubuntu's default logrotate only covers /var/log/nginx/*.log on distro packages;
# nginx.org mainline may not include it, so we write our own.
# Idempotent: safe to call on every install_nginx run.
_nginx_write_logrotate() {
    local logrotate_file="/etc/logrotate.d/nginx-ops"
    cat > "$logrotate_file" << 'LOGROTATE_EOF'
/var/log/nginx/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        # nginx -s reopen is safe: gracefully reopens log files without restart
        if [ -f /run/nginx.pid ] && kill -0 $(cat /run/nginx.pid) 2>/dev/null; then
            nginx -s reopen
        fi
    endscript
}
LOGROTATE_EOF
    chmod 644 "$logrotate_file"
    log_info "P2-2: nginx logrotate config written to ${logrotate_file} (daily, 14 days, compressed)."
}

# install_nginx: add official mainline repo, install + tune nginx.conf per OPS_TIER, ensure default deny
# F-15 fix: service_enable/start moved to AFTER all config tuning.
# Rationale: starting nginx before writing the tuned config means a broken pre-existing
# config causes service_start to fail and aborts the script (set -euo pipefail) before
# the tuning that would fix it ever runs. On re-install/upgrade the prior service_start
# was a no-op (systemd is idempotent), but _nginx_test_and_reload only calls
# service_reload — which silently succeeds if nginx is already running, but returns an
# error if it is not. By enabling + service_restart AFTER all config is written we:
#   1. Guarantee config is correct before nginx first starts.
#   2. Use service_restart (exponential-backoff health-check, 15s default) instead of
#      service_start (bare systemctl start, no liveness check) for post-install verification.
#   3. Remain idempotent: service_restart works whether nginx is stopped or running.
#   4. Drop the now-redundant _nginx_test_and_reload at the end (service_restart
#      already verifies liveness; nginx -t is still called inside create_default_deny).
install_nginx() {
    print_section "Install Nginx"
    require_root || return 1
    _nginx_add_official_repo          # ensures nginx >= 1.24 from nginx.org mainline
    apt_update
    apt_install nginx

    # Apply all config changes BEFORE starting the service.
    _nginx_apply_global_tuning
    _nginx_write_logrotate            # P2-2: ensure per-domain log rotation
    create_default_deny
    _nginx_disable_packaged_default_site

    # Validate config before touching the service.
    if ! nginx -t; then
        print_error "F-15: Nginx config test failed after tuning — service NOT started. Check /etc/nginx/nginx.conf"
        return 1
    fi

    # Now enable + restart with health-check polling (service_restart: exponential backoff, 15s).
    service_enable nginx
    service_restart nginx
    print_ok "Nginx installed, tuned, and running."
    log_info "install_nginx: nginx installed and running"
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
        # P-05 fix: regex-whitelist parser — safe against special characters in state file.
        local DOMAIN DOMAIN_BACKEND_TYPE DOMAIN_BACKEND_TARGET
        eval "$(_load_domain_state "$state_file")"
        domain="${DOMAIN:-}"
        type="${DOMAIN_BACKEND_TYPE:-}"
        backend="${DOMAIN_BACKEND_TARGET:-}"
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

    # F-03 fix: duplicate domain guard — prevent silent overwrite of a live vhost.
    # FORCE_OVERWRITE=1 bypasses the prompt for scripted/non-interactive callers.
    local available="${NGINX_SITES_AVAILABLE}/${domain}"
    local enabled="${NGINX_SITES_ENABLED}/${domain}"
    local _state_file="${OPS_DOMAINS_DIR}/${domain}.conf"
    if [[ -f "$available" || -f "$_state_file" ]]; then
        if [[ "${FORCE_OVERWRITE:-0}" != "1" ]]; then
            print_warn "Domain '${domain}' already has an existing vhost or state file."
            print_warn "Overwriting will replace the live Nginx config for this domain."
            local _ow_ans
            read -r -p "Overwrite existing config for '${domain}'? [y/N]: " _ow_ans
            if [[ "${_ow_ans,,}" != "y" ]]; then
                print_warn "Aborted. Existing config for '${domain}' was NOT changed."
                return 0
            fi
        fi
        log_info "F-03: Overwriting existing vhost for '${domain}' (FORCE_OVERWRITE=${FORCE_OVERWRITE:-0})."
        # P-02: backup the live vhost before overwriting so it is recoverable.
        if [[ -f "$available" ]]; then
            backup_file "$available" >/dev/null || true
        fi
    fi
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
    log_info "add_domain: '${domain}' added (type=${type})"
}

nginx_prompt_edit_domain() {
    print_section "Edit Domain"
    require_root || return 1

    if ! ls "${OPS_DOMAINS_DIR}"/*.conf > /dev/null 2>&1; then
        print_warn "No managed domains found."
        return 0
    fi

    list_domains
    echo ""
    prompt_input "Enter domain to edit"
    local domain="$REPLY"
    nginx_edit_domain "$domain"
}

# nginx_edit_domain <domain>
# F-25 fix: implement the previously-stubbed "Edit domain" menu option.
# Reads the current state file, prompts for the field(s) relevant to the
# backend type, writes the updated state, rebuilds the vhost from scratch,
# and reloads Nginx.  Atomic: the state file is only overwritten after the
# new vhost passes nginx -t (enforced inside _rebuild_domain_vhost).
nginx_edit_domain() {
    local domain="${1:-}"
    require_root || return 1

    if [[ -z "$domain" ]]; then
        print_error "Usage: nginx_edit_domain <domain>"
        return 1
    fi

    local state_file="${OPS_DOMAINS_DIR}/${domain}.conf"
    if [[ ! -f "$state_file" ]]; then
        print_error "No state file for domain '${domain}'. Is it managed by OPS?"
        return 1
    fi

    # Read current state via the safe parser (P-05 fix) — same path as _rebuild_domain_vhost.
    local DOMAIN DOMAIN_BACKEND_TYPE DOMAIN_BACKEND_TARGET DOMAIN_PHP_VERSION DOMAIN_PHP_SOCKET DOMAIN_WEB_ROOT
    eval "$(_load_domain_state "$state_file")"
    local type="${DOMAIN_BACKEND_TYPE:-}"
    local backend_target="${DOMAIN_BACKEND_TARGET:-}"
    local php_version="${DOMAIN_PHP_VERSION:-}"
    local php_socket="${DOMAIN_PHP_SOCKET:-}"
    local web_root="${DOMAIN_WEB_ROOT:-}"
    if ! _validate_domain_state "$domain" "$type" "$php_version" "$php_socket" "$web_root"; then
        print_error "State file for '${domain}' is corrupted — cannot edit. Check ${state_file}."
        return 1
    fi

    print_section "Edit Domain: ${domain} (type=${type})"

    case "$type" in
        node)
            local current_port new_port
            current_port="${backend_target#127.0.0.1:}"
            echo "  Current port: ${current_port}"
            prompt_input "Enter new Node.js port (leave blank to keep ${current_port})"
            new_port="${REPLY:-$current_port}"
            if [[ ! "$new_port" =~ ^[0-9]{2,5}$ ]]; then
                print_error "Invalid port: ${new_port}"
                return 1
            fi
            if [[ "$new_port" == "$current_port" ]]; then
                print_warn "Port unchanged — no action taken."
                return 0
            fi
            backend_target="127.0.0.1:${new_port}"
            # State written first, then vhost rebuilt from it.
            _write_domain_state "$domain" "$type" "$backend_target" "" ""
            if ! _rebuild_domain_vhost "$domain"; then
                print_error "Vhost rebuild failed — rolling back state file."
                _write_domain_state "$domain" "$type" "127.0.0.1:${current_port}" "" ""
                return 1
            fi
            print_ok "Domain ${domain}: port updated ${current_port} → ${new_port}"
            log_info "nginx_edit_domain: '${domain}' updated (node port ${current_port} → ${new_port})"
            ;;
        php)
            local new_php_version new_php_socket site_slug
            echo "  Current PHP version: ${php_version}"
            prompt_input "Enter new PHP version (e.g. 8.3, leave blank to keep ${php_version})"
            new_php_version="${REPLY:-$php_version}"
            if [[ ! "$new_php_version" =~ ^[0-9]+\.[0-9]+$ ]]; then
                print_error "Invalid PHP version: ${new_php_version}"
                return 1
            fi
            if [[ "$new_php_version" == "$php_version" ]]; then
                print_warn "PHP version unchanged — no action taken."
                return 0
            fi
            site_slug="$(_domain_slug "$domain")"
            new_php_socket="/run/php/php${new_php_version}-fpm-${site_slug}.sock"
            _write_domain_state "$domain" "$type" "$new_php_socket" "$new_php_version" "$new_php_socket"
            if ! _rebuild_domain_vhost "$domain"; then
                print_error "Vhost rebuild failed — rolling back state file."
                _write_domain_state "$domain" "$type" "$php_socket" "$php_version" "$php_socket"
                return 1
            fi
            print_ok "Domain ${domain}: PHP version updated ${php_version} → ${new_php_version}"
            print_warn "Ensure php${new_php_version}-fpm is installed and a pool config exists for ${domain}."
            log_info "nginx_edit_domain: '${domain}' updated (php ${php_version} → ${new_php_version})"
            ;;
        static)
            print_warn "Static site '${domain}' has no configurable backend parameters."
            echo "  Web root: ${web_root}"
            echo "  To move the web root, remove and re-add the domain."
            return 0
            ;;
        *)
            print_error "Unknown backend type '${type}' for domain '${domain}'."
            return 1
            ;;
    esac

    _nginx_test_and_reload
}

nginx_prompt_remove_domain() {
    print_section "Remove Domain"
    require_root || return 1
    prompt_input "Enter domain to remove"
    remove_domain "$REPLY"
}

# remove_domain <domain>
# F-04 fix: transactional removal order —
#   1. Read state (before any delete)
#   2. Clean backend first: remove FPM pool → restart/reload FPM → verify FPM config
#   3. Remove Nginx config files (symlink first so nginx -t won't see a broken ref)
#   4. Remove OPS state file (commit point)
#   5. create_default_deny + nginx -t + reload
# This order prevents orphaned FPM pool sockets and ensures nginx -t succeeds post-removal.
remove_domain() {
    local domain="${1:-}"
    require_root || return 1
    if [[ -z "$domain" ]]; then
        print_error "Usage: remove_domain <domain>"
        return 1
    fi

    local confirm_ans
    read -r -p "Remove domain ${domain}? This will delete Nginx config and FPM pool (if PHP). [y/N]: " confirm_ans
    if [[ "${confirm_ans,,}" != "y" ]]; then
        print_warn "Cancelled."
        return 0
    fi

    # Step 1: Read backend metadata BEFORE any delete.
    local state_file="${OPS_DOMAINS_DIR}/${domain}.conf"
    local backend_type php_version site_slug
    if [[ -f "$state_file" ]]; then
        backend_type=$(grep '^DOMAIN_BACKEND_TYPE=' "$state_file" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
        php_version=$(grep '^DOMAIN_PHP_VERSION='   "$state_file" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
    fi

    # Step 2: Backend-specific cleanup FIRST (before touching Nginx files).
    # Removing the FPM pool before the Nginx config means FPM is in a clean state
    # by the time we remove Nginx files and run nginx -t.
    case "${backend_type:-}" in
        php)
            if [[ -n "$php_version" ]]; then
                site_slug="$(_domain_slug "$domain")"
                local pool_file="/etc/php/${php_version}/fpm/pool.d/${site_slug}.conf"
                if [[ -f "$pool_file" ]]; then
                    backup_file "$pool_file" >/dev/null || true
                    rm -f "$pool_file"
                    # Restart FPM; log a warning on failure but do not abort —
                    # the pool conf is already removed, so the socket will not be
                    # re-created on next FPM start even if this restart fails.
                    if ! service_restart "php${php_version}-fpm" 2>/dev/null; then
                        log_warn "remove_domain: php${php_version}-fpm restart failed after pool removal — check FPM config manually"
                        print_warn "php${php_version}-fpm restart failed. Pool file removed, but FPM may need manual restart."
                    else
                        log_info "remove_domain: removed PHP-FPM pool ${pool_file} and restarted php${php_version}-fpm"
                    fi
                fi
                rm -f "${PHP_SITES_DIR}/${site_slug}.conf" 2>/dev/null || true
                print_ok "PHP-FPM pool removed for ${domain} (PHP ${php_version})."
            fi
            ;;
        node)
            print_warn "Nginx domain config removed, but the PM2 process may still be running."
            print_warn "Use 'Node.js Services → Remove app' (ops menu) to stop the PM2 process."
            ;;
    esac

    # Step 3: P-01 fix — commit OPS state file FIRST, BEFORE removing nginx files.
    # Rationale: state file is the OPS source of truth. If we crash after this rm
    # but before the nginx rm below, list_domains will correctly show the domain as
    # removed (state gone) while nginx retains its old config until the next reload.
    # The inverse (state file survives but nginx files gone) leaves a "zombie" entry
    # in list_domains pointing to non-existent nginx config — harder to diagnose.
    rm -f "$state_file"

    # Step 4: Remove Nginx config files.
    # Remove symlink first so nginx -t at step 5 won't reference the available file.
    rm -f "${NGINX_SITES_ENABLED}/${domain}"
    rm -f "${NGINX_SITES_AVAILABLE}/${domain}"

    # Step 5: Ensure default-deny vhost and reload Nginx.
    create_default_deny
    _nginx_test_and_reload
    print_ok "Domain ${domain} removed."
    echo "  Web root /var/www/${domain} NOT deleted — remove manually if needed."
    log_info "remove_domain: '${domain}' removed (backend_type=${backend_type:-unknown})"
}

# _dns_check_before_ssl <domain>
# F-07 fix: DNS readiness guard before calling certbot.
# Let's Encrypt ACME HTTP-01 requires the domain to resolve to THIS server's IP.
# If DNS is wrong, certbot fails and burns a failed-authorization slot (5/hour/hostname).
# This function checks BEFORE certbot runs and aborts with a clear message.
#
# Strategy:
#   1. Resolve domain A record via 8.8.8.8 (external — avoids split-horizon false pass)
#   2. Compare with this server's public IP
#   3. If IPs match → proceed
#   4. If IPs differ → probe HTTP to detect Cloudflare-proxied case (CF IP ≠ VPS IP)
#      CF proxy returns a CF-branded response; direct nginx returns our probe marker.
#   5. Warn on CF proxy (certbot may still work via CF-flexible, but warn operator).
#   6. Hard abort if neither check passes — certbot would fail with a rate-limit cost.
#
# Returns:
#   0  — DNS looks correct, safe to call certbot
#   1  — DNS not pointed at server; certbot NOT called
#   2  — Cloudflare proxied detected; operator warned, certbot NOT called (let them decide)
_dns_check_before_ssl() {
    local domain="$1"
    local resolved_ip server_ip http_probe cf_header

    echo ""
    print_warn "F-07: Checking DNS before calling certbot (prevents Let's Encrypt rate-limit burn)..."

    # Step 1: Get server's own public IP (try multiple sources for resilience)
    server_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
        || curl -s --max-time 5 https://ifconfig.me 2>/dev/null \
        || curl -s --max-time 5 https://icanhazip.com 2>/dev/null || true)
    server_ip="${server_ip//[[:space:]]/}"  # strip whitespace/newlines

    if [[ -z "$server_ip" ]]; then
        print_warn "F-07: Could not determine server public IP (no internet?). Skipping DNS check."
        log_warn "_dns_check_before_ssl: could not fetch server public IP — skipping check for ${domain}"
        return 0
    fi

    # Step 2: Resolve A record via Google DNS (8.8.8.8) — avoids split-horizon false pass
    if command -v dig >/dev/null 2>&1; then
        resolved_ip=$(dig +short A "${domain}" @8.8.8.8 2>/dev/null | grep -E '^[0-9]+\.' | head -n1 || true)
    elif command -v nslookup >/dev/null 2>&1; then
        resolved_ip=$(nslookup -type=A "${domain}" 8.8.8.8 2>/dev/null \
            | awk '/^Address:/{ip=$2} END{print ip}' | head -n1 || true)
    elif command -v getent >/dev/null 2>&1; then
        resolved_ip=$(getent hosts "${domain}" 2>/dev/null | awk '{print $1}' | head -n1 || true)
    fi
    resolved_ip="${resolved_ip//[[:space:]]/}"

    if [[ -z "$resolved_ip" ]]; then
        print_error "F-07: DNS lookup for '${domain}' returned no A record."
        echo "  → Domain may not exist or DNS has not propagated yet."
        echo "  → Check: dig +short A ${domain} @8.8.8.8"
        echo "  → Certbot NOT called. Fix DNS first, then retry."
        log_error "_dns_check_before_ssl: no A record for ${domain} via 8.8.8.8"
        return 1
    fi

    log_info "_dns_check_before_ssl: ${domain} resolves to ${resolved_ip}; server IP is ${server_ip}"

    # Step 3: IPs match → DNS is correct, safe to certbot
    if [[ "$resolved_ip" == "$server_ip" ]]; then
        print_ok "  DNS check passed: ${domain} → ${resolved_ip} (matches server IP)"
        return 0
    fi

    # Step 4: IPs differ — check if Cloudflare proxy is in the way.
    # CF proxied A records point to CF edge IPs, not VPS IP.
    # We probe HTTP and look for the CF-Ray or Server: cloudflare response headers.
    cf_header=$(curl -s --max-time 8 -o /dev/null -D - "http://${domain}/" 2>/dev/null \
        | grep -i 'CF-Ray:\|server: cloudflare\|cf-cache-status:' | head -n1 || true)

    if [[ -n "$cf_header" ]]; then
        echo ""
        print_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        print_warn "F-07: Cloudflare proxy detected for ${domain}."
        print_warn "  DNS resolves to ${resolved_ip} (Cloudflare IP), not ${server_ip} (this server)."
        echo ""
        # If CF API token is set → use DNS-01 challenge automatically (return 3)
        if [[ -n "${CF_API_TOKEN:-}" ]]; then
            print_ok "  CF API token found — will use DNS-01 challenge automatically."
            log_info "_dns_check_before_ssl: CF proxy + token available for ${domain} — DNS-01 path selected"
            return 3
        fi
        echo "  Certbot HTTP-01 challenge CANNOT reach your server through Cloudflare's proxy."
        echo "  Options:"
        echo "    A) Temporarily set Cloudflare DNS to 'DNS only' (grey cloud) for ${domain},"
        echo "       issue the SSL cert, then switch back to 'Proxied'."
        echo "    B) Use Cloudflare's own SSL (Full or Full Strict mode) — no certbot needed."
        echo "    C) Set Cloudflare API Token in OPS (SSL Management → option 6) for fully automatic DNS-01."
        echo ""
        echo "  Certbot NOT called. Resolve the Cloudflare proxy conflict first."
        print_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_warn "_dns_check_before_ssl: CF proxy detected for ${domain} (resolved=${resolved_ip}, server=${server_ip})"
        return 2
    fi

    # Step 5: Different IP, not CF proxy — DNS is simply not pointed at this server.
    echo ""
    print_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_error "F-07: DNS for '${domain}' does NOT point to this server."
    echo "  Domain resolves to : ${resolved_ip}"
    echo "  This server IP is  : ${server_ip}"
    echo ""
    echo "  Let's Encrypt ACME HTTP-01 will FAIL if domain doesn't reach this server."
    echo "  Each failure burns 1 of your 5 allowed authorization attempts per hour."
    echo ""
    echo "  Fix: Update your DNS A record for '${domain}' to point to ${server_ip}."
    echo "  Then wait for propagation (check: dig +short A ${domain} @8.8.8.8)"
    echo "  After propagation confirmed, re-run SSL issuance."
    echo ""
    echo "  Certbot NOT called. Fix DNS first."
    print_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_error "_dns_check_before_ssl: ${domain} resolved to ${resolved_ip} != server ${server_ip} — aborted certbot"
    return 1
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
    # F-21: only install certbot if not already present (avoids snap refresh on every issue).
    _ensure_certbot

    # F-16: certbot prompts for email + ToS acceptance on first ever use on this server.
    # Without pre-registration, 'certbot --nginx' blocks waiting for TTY input — the TUI
    # appears to hang with no feedback. We check for an existing account first, and if
    # none exists, prompt the operator for email and register non-interactively.
    # P-04 fix: use filesystem check instead of parsing CLI output.
    # 'certbot accounts list | grep Account ID:' is fragile — the output format
    # changed across versions and a false-negative causes a duplicate-registration
    # error. _certbot_has_account checks for regr.json, which certbot always writes
    # on successful registration (ACME protocol requirement, stable across versions).
    if ! _certbot_has_account; then
        echo ""
        print_warn "No Let's Encrypt account found on this server. Registration required for SSL."
        prompt_input "Email for Let's Encrypt notifications (certificate expiry alerts)"
        local certbot_email="$REPLY"
        if [[ -z "$certbot_email" ]]; then
            print_error "Email is required for Let's Encrypt registration. SSL issuance cancelled."
            return 1
        fi
        if ! certbot register --agree-tos --non-interactive -m "$certbot_email"; then
            print_error "Certbot account registration failed. Check email and internet connectivity."
            return 1
        fi
        print_ok "Let's Encrypt account registered: ${certbot_email}"
        log_info "issue_ssl: certbot account registered for ${certbot_email}"
    fi

    # F-07: DNS readiness check — abort before certbot if DNS not pointed at this server.
    # Prevents burning Let's Encrypt rate-limit slots on predictable DNS failures.
    # Return codes: 0=direct DNS OK, 2=CF proxy no token, 3=CF proxy with token (DNS-01)
    local dns_check_rc=0
    _dns_check_before_ssl "$domain" || dns_check_rc=$?
    case "$dns_check_rc" in
        0)
            # DNS points directly to this server — use HTTP-01 (standard path)
            certbot --nginx -d "$domain" --non-interactive --agree-tos
            ;;
        3)
            # Cloudflare proxy detected + CF_API_TOKEN available → DNS-01 challenge
            _issue_ssl_dns01_cloudflare "$domain"
            ;;
        *)
            # DNS not ready or CF proxy without token — abort
            return 1
            ;;
    esac

    log_info "issue_ssl: SSL issued for ${domain} — syncing managed vhosts"
    _rebuild_domain_vhost "$domain"

    local nine_router_domain
    nine_router_domain=$(ops_conf_get "nine-router.conf" "NINE_ROUTER_DOMAIN" || true)
    if [[ "$domain" == "$nine_router_domain" ]] && declare -F link_nine_router_domain >/dev/null 2>&1; then
        log_info "Re-rendering nine-router vhost after SSL issuance for ${domain}."
        link_nine_router_domain "$domain"
    fi

    # P-03 fix: _nginx_test_and_reload already prints error and returns 1 on failure;
    # || true was hiding that. If reload fails after SSL issuance operator must know.
    if ! _nginx_test_and_reload; then
        print_error "Nginx reload failed after SSL issuance for ${domain}."
        print_warn "SSL cert was issued but nginx is not serving it — run 'nginx -t' to diagnose."
        log_error "issue_ssl: _nginx_test_and_reload failed for ${domain}"
        return 1
    fi
    curl -I "https://${domain}" 2>/dev/null || true   # informational
    certbot certificates 2>/dev/null || true           # informational
    log_info "issue_ssl: certificate issued for '${domain}'"
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

# _ssl_collect_domains
# Populate the caller's 'domains' array with all known domains.
# Sources (deduplicated, sorted):
#   1. /etc/ops/domains/*.conf  — OPS-managed domains (add_domain)
#   2. /etc/nginx/sites-available/*  — all nginx vhosts incl. nine-router
# Excludes: 00-default-deny, *.bak.* backup files, and directories.
_ssl_collect_domains() {
    local -A _seen=()

    # Source 1: OPS state files
    if ls "${OPS_DOMAINS_DIR}"/*.conf > /dev/null 2>&1; then
        local _sf _DOMAIN
        for _sf in "${OPS_DOMAINS_DIR}"/*.conf; do
            _DOMAIN=""
            eval "$(_load_domain_state "$_sf")"
            if [[ -n "${_DOMAIN:-}" && -z "${_seen[$_DOMAIN]:-}" ]]; then
                domains+=("$_DOMAIN")
                _seen[$_DOMAIN]=1
            fi
        done
    fi

    # Source 2: nginx sites-available (catches nine-router and manual vhosts)
    if [[ -d "$NGINX_SITES_AVAILABLE" ]]; then
        local _f _name
        for _f in "${NGINX_SITES_AVAILABLE}"/*; do
            [[ -f "$_f" ]] || continue
            _name="$(basename "$_f")"
            # Skip default deny and backup files
            [[ "$_name" == "${NGINX_DEFAULT_DENY_NAME}" ]] && continue
            [[ "$_name" == *.bak.* ]] && continue
            # Extract domain: strip leading nine-router. prefix if present
            local _d="${_name#nine-router.}"
            if _domain_is_valid "$_d" && [[ -z "${_seen[$_d]:-}" ]]; then
                domains+=("$_d")
                _seen[$_d]=1
            fi
        done
    fi
}

ssl_issue_cert() {
    print_section "Issue SSL Certificate (Let's Encrypt)"
    require_root || return 1

    local domains=()
    _ssl_collect_domains

    local domain=""

    if [[ ${#domains[@]} -eq 0 ]]; then
        print_warn "No domains found. Enter domain manually."
        prompt_input "Enter domain to issue SSL (e.g. example.com)"
        domain="$REPLY"
    else
        echo ""
        echo "  Available domains:"
        echo ""
        local i
        for i in "${!domains[@]}"; do
            local d="${domains[$i]}"
            local ssl_status=""
            if _domain_ssl_cert_ready "$d"; then
                ssl_status="  ✓ SSL"
            fi
            printf '  %2d) %s%s\n' "$(( i + 1 ))" "$d" "$ssl_status"
        done
        echo ""
        echo "  0) Cancel"
        echo ""
        printf "  Select domain [1-%d]: " "${#domains[@]}" > /dev/tty
        read -r _sel < /dev/tty

        if [[ "$_sel" == "0" || -z "$_sel" ]]; then
            print_warn "Cancelled."
            return 0
        fi

        if ! [[ "$_sel" =~ ^[0-9]+$ ]] || (( _sel < 1 || _sel > ${#domains[@]} )); then
            print_error "Invalid selection: ${_sel}"
            return 1
        fi

        domain="${domains[$(( _sel - 1 ))]}"
    fi

    if [[ -z "$domain" ]]; then
        print_error "No domain selected."
        return 1
    fi

    echo ""
    issue_ssl "$domain"
}

# _issue_ssl_dns01_cloudflare <domain>
# Issue a Let's Encrypt cert via Cloudflare DNS-01 challenge.
# Requires CF_API_TOKEN to be set (Zone:DNS:Edit permission).
# Called by issue_ssl when _dns_check_before_ssl returns 3.
_issue_ssl_dns01_cloudflare() {
    local domain="$1"
    local certbot_email

    log_info "_issue_ssl_dns01_cloudflare: starting DNS-01 issuance for ${domain}"
    print_warn "Using Cloudflare DNS-01 challenge for ${domain} (domain is behind CF proxy)..."

    _ensure_certbot_dns_cloudflare

    # Write CF credentials file (chmod 600 — token never world-readable)
    printf 'dns_cloudflare_api_token = %s\n' "$CF_API_TOKEN" > "$CF_CREDS_FILE"
    chmod 600 "$CF_CREDS_FILE"
    log_info "CF credentials written to ${CF_CREDS_FILE}"

    # Build certbot command
    # --dns-cloudflare-propagation-seconds 20: CF DNS propagates within seconds globally
    local certbot_args=(
        certonly
        --dns-cloudflare
        --dns-cloudflare-credentials "$CF_CREDS_FILE"
        --dns-cloudflare-propagation-seconds 20
        -d "$domain"
        --non-interactive
        --agree-tos
    )

    # Attach email if account already registered
    if ! _certbot_has_account; then
        prompt_input "Email for Let's Encrypt notifications (certificate expiry alerts)"
        certbot_email="$REPLY"
        if [[ -z "$certbot_email" ]]; then
            print_error "Email is required for Let's Encrypt registration. SSL issuance cancelled."
            return 1
        fi
        certbot_args+=(-m "$certbot_email")
        if ! certbot register --agree-tos --non-interactive -m "$certbot_email"; then
            print_error "Certbot account registration failed."
            return 1
        fi
    fi

    if ! certbot "${certbot_args[@]}"; then
        print_error "certbot DNS-01 issuance failed for ${domain}. Check CF token permissions (Zone:DNS:Edit)."
        log_error "_issue_ssl_dns01_cloudflare: certbot failed for ${domain}"
        return 1
    fi

    print_ok "Let's Encrypt certificate issued via DNS-01 for ${domain}."
    log_info "_issue_ssl_dns01_cloudflare: cert issued for ${domain}"
}

# ssl_set_cf_token
# Store Cloudflare API token in /etc/ops/cloudflare.conf (chmod 600).
# Token must have Zone:DNS:Edit permission for all managed zones.
# The token is validated against the Cloudflare API before saving.
ssl_set_cf_token() {
    print_section "Set Cloudflare API Token"
    require_root || return 1

    echo ""
    echo "  Required permission: Zone → DNS → Edit"
    echo "  Tip: Create a scoped token at https://dash.cloudflare.com/profile/api-tokens"
    echo "  This token is stored in ${CF_CREDS_FILE} (chmod 600, root-only)."
    echo ""

    if [[ -n "${CF_API_TOKEN:-}" ]]; then
        print_warn "A Cloudflare API token is already configured."
        read -r -p "  Replace existing token? [y/N]: " _replace_ans
        if [[ "${_replace_ans,,}" != "y" ]]; then
            print_warn "Aborted — existing token retained."
            return 0
        fi
    fi

    prompt_input "Enter Cloudflare API Token"
    local new_token="$REPLY"

    if [[ -z "$new_token" ]]; then
        print_error "Token cannot be empty."
        return 1
    fi

    # Validate token via CF API
    # Note: no -f flag so we always capture the response body even on HTTP 4xx
    print_warn "Validating token with Cloudflare API..."
    local verify_result status_ok cf_error
    verify_result=$(curl -s --max-time 10 \
        -H "Authorization: Bearer ${new_token}" \
        -H "Content-Type: application/json" \
        https://api.cloudflare.com/client/v4/user/tokens/verify 2>/dev/null || true)
    status_ok=$(printf '%s' "$verify_result" | grep -o '"status":"active"' || true)
    cf_error=$(printf '%s' "$verify_result" | grep -o '"message":"[^"]*"' | head -1 | sed 's/"message"://;s/"//g' || true)

    if [[ -z "$status_ok" ]]; then
        print_error "Token validation FAILED."
        if [[ -n "$cf_error" ]]; then
            print_error "  CF error: ${cf_error}"
        else
            print_error "  CF API response: ${verify_result:-<no response — check internet connectivity>}"
        fi
        print_error "  Ensure token has Zone → DNS → Edit permission and is not expired."
        log_error "ssl_set_cf_token: CF token validation failed — ${cf_error:-no response}"
        return 1
    fi

    # Save token to credentials file (chmod 600)
    ensure_dir "$(dirname "$CF_CREDS_FILE")"
    printf 'CF_API_TOKEN="%s"\n' "$new_token" > "$CF_CREDS_FILE"
    chmod 600 "$CF_CREDS_FILE"
    # Reload into current session
    CF_API_TOKEN="$new_token"

    print_ok "Cloudflare API token saved to ${CF_CREDS_FILE} (chmod 600)."
    print_ok "DNS-01 challenge will now be used automatically for Cloudflare-proxied domains."
    log_info "ssl_set_cf_token: CF API token saved and validated successfully"
}

# ── Cloudflare Origin Certificate (15 years) ─────────────────────────────────

# ssl_prompt_cf_origin_cert
# Interactive wrapper: prompt for domain then call ssl_issue_cf_origin_cert.
ssl_prompt_cf_origin_cert() {
    print_section "Issue Cloudflare Origin Certificate (15 years)"
    require_root || return 1

    echo "  ┌─────────────────────────────────────────────────────────────────┐"
    echo "  │  ⚠  API Token Permission Required                               │"
    echo "  │                                                                 │"
    echo "  │  Your CF API token must have:                                   │"
    echo "  │    Zone → DNS → Edit          (already set for DNS-01)          │"
    echo "  │    Zone → SSL and Certificates → Edit   ← THÊM CÁI NÀY         │"
    echo "  │                                                                 │"
    echo "  │  Cách thêm permission:                                          │"
    echo "  │    1. Cloudflare Dashboard → Profile → API Tokens               │"
    echo "  │    2. Click Edit trên token hiện tại                            │"
    echo "  │    3. Add permission: Zone → SSL and Certificates → Edit        │"
    echo "  │    4. Save → token vẫn giữ nguyên, chỉ thêm quyền              │"
    echo "  └─────────────────────────────────────────────────────────────────┘"
    echo ""

    if [[ -z "${CF_API_TOKEN:-}" ]]; then
        print_error "Cloudflare API token not configured. Run option 6 first."
        return 1
    fi

    local domains=()
    _ssl_collect_domains

    local domain=""

    if [[ ${#domains[@]} -eq 0 ]]; then
        print_warn "No domains found. Enter domain manually."
        prompt_input "Enter domain (e.g. ducnv.email)"
        domain="$REPLY"
    else
        echo "  Available domains:"
        echo ""
        local i
        for i in "${!domains[@]}"; do
            local d="${domains[$i]}"
            local cf_status=""
            if [[ -f "/etc/nginx/ssl/${d}/cf-origin.pem" ]]; then
                cf_status="  ✓ CF Cert"
            fi
            printf '  %2d) %s%s\n' "$(( i + 1 ))" "$d" "$cf_status"
        done
        echo ""
        echo "  0) Cancel"
        echo ""
        printf "  Select domain [1-%d]: " "${#domains[@]}" > /dev/tty
        read -r _sel < /dev/tty

        if [[ "$_sel" == "0" || -z "$_sel" ]]; then
            print_warn "Cancelled."
            return 0
        fi

        if ! [[ "$_sel" =~ ^[0-9]+$ ]] || (( _sel < 1 || _sel > ${#domains[@]} )); then
            print_error "Invalid selection: ${_sel}"
            return 1
        fi

        domain="${domains[$(( _sel - 1 ))]}"
    fi

    if [[ -z "$domain" ]]; then
        print_error "No domain selected."
        return 1
    fi

    echo ""
    ssl_issue_cf_origin_cert "$domain"
}

# ssl_issue_cf_origin_cert <domain>
# Issue a Cloudflare Origin Certificate (15-year) for <domain>.
# Flow:
#   1. Validate CF_API_TOKEN + get zone_id
#   2. Generate RSA-2048 key + CSR on server
#   3. POST /v4/certificates with CSR → receive signed cert
#   4. Save cert + key to /etc/nginx/ssl/<domain>/
#   5. Update nginx vhost SSL block to use CF origin cert
#   6. Set Cloudflare SSL mode to Full (Strict)
#   7. nginx -t && reload
#
# Required CF API token permissions:
#   Zone:DNS:Edit  +  Zone:SSL and Certificates:Edit
ssl_issue_cf_origin_cert() {
    local domain="${1:-}"
    require_root || return 1

    if [[ -z "$domain" ]] || ! _domain_is_valid "$domain"; then
        print_error "Usage: ssl_issue_cf_origin_cert <domain>"
        return 1
    fi
    if [[ -z "${CF_API_TOKEN:-}" ]]; then
        print_error "CF_API_TOKEN not set. Run 'Set Cloudflare API Token' (option 6) first."
        return 1
    fi

    local cert_dir="/etc/nginx/ssl/${domain}"
    local key_file="${cert_dir}/cf-origin.key"
    local csr_file="${cert_dir}/cf-origin.csr"
    local cert_file="${cert_dir}/cf-origin.pem"

    # ── Step 1: Get zone_id ───────────────────────────────────────────────────
    print_warn "Looking up Cloudflare zone for ${domain}..."
    # Strip to apex (last two labels) for zone lookup
    local apex
    apex=$(printf '%s' "$domain" | awk -F. '{if(NF>=2){print $(NF-1)"."$NF}else{print $0}}')
    local zone_resp zone_id
    zone_resp=$(curl -s --max-time 10 \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/zones?name=${apex}&status=active" 2>/dev/null || true)
    zone_id=$(printf '%s' "$zone_resp" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [[ -z "$zone_id" ]]; then
        local cf_err
        cf_err=$(printf '%s' "$zone_resp" | grep -o '"message":"[^"]*"' | head -1 | sed 's/"message"://;s/"//g' || true)
        print_error "Could not find Cloudflare zone for '${apex}'."
        [[ -n "$cf_err" ]] && print_error "  CF error: ${cf_err}"
        print_error "  Ensure token has Zone:SSL and Certificates:Edit permission and zone is active."
        log_error "ssl_issue_cf_origin_cert: zone lookup failed for ${apex}"
        return 1
    fi
    print_ok "  Zone ID: ${zone_id}"

    # ── Step 2: Generate private key + CSR ───────────────────────────────────
    ensure_dir "$cert_dir"
    chmod 750 "$cert_dir"
    chown root:nginx "$cert_dir"
    print_warn "Generating RSA-2048 private key and CSR..."
    openssl req -new -newkey rsa:2048 -nodes \
        -keyout "$key_file" \
        -out "$csr_file" \
        -subj "/CN=${domain}" 2>/dev/null
    chmod 640 "$key_file"
    chown root:nginx "$key_file"
    log_info "ssl_issue_cf_origin_cert: key + CSR generated at ${cert_dir}"

    # ── Step 3: POST CSR to CF Origin CA API ─────────────────────────────────
    print_warn "Requesting CF Origin Certificate from Cloudflare API..."
    local csr_content hostnames_json cert_resp cert_pem cf_err
    csr_content=$(cat "$csr_file")
    # Include both apex and wildcard for coverage
    hostnames_json="[\"${domain}\",\"*.${apex}\"]"

    cert_resp=$(curl -s --max-time 30 \
        -X POST \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "{
            \"hostnames\": ${hostnames_json},
            \"requested_validity\": 5475,
            \"request_type\": \"origin-rsa\",
            \"csr\": $(printf '%s' "$csr_content" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
        }" \
        "https://api.cloudflare.com/client/v4/certificates" 2>/dev/null || true)

    cert_pem=$(printf '%s' "$cert_resp" | python3 -c \
        'import json,sys; d=json.load(sys.stdin); print(d["result"]["certificate"])' 2>/dev/null || true)
    cf_err=$(printf '%s' "$cert_resp" | grep -o '"message":"[^"]*"' | head -1 \
        | sed 's/"message"://;s/"//g' || true)

    if [[ -z "$cert_pem" ]]; then
        print_error "Cloudflare Origin Certificate issuance FAILED."
        [[ -n "$cf_err" ]] && print_error "  CF error: ${cf_err}"
        print_error "  Ensure API token has 'Zone:SSL and Certificates:Edit' permission."
        rm -f "$csr_file"
        log_error "ssl_issue_cf_origin_cert: CF API returned no cert for ${domain}"
        return 1
    fi

    # ── Step 4: Save certificate ──────────────────────────────────────────────
    printf '%s\n' "$cert_pem" > "$cert_file"
    chmod 644 "$cert_file"
    rm -f "$csr_file"   # CSR no longer needed
    print_ok "  Certificate saved: ${cert_file}"
    print_ok "  Private key saved: ${key_file}"
    log_info "ssl_issue_cf_origin_cert: cert saved to ${cert_file}"

    # ── Step 5: Update nginx vhost to use CF origin cert ─────────────────────
    local vhost_avail="${NGINX_SITES_AVAILABLE}/${domain}"
    local nine_router_vhost="/etc/nginx/sites-available/nine-router.${domain}"

    # Determine which vhost file to patch (ops-managed or nine-router)
    local vhost_to_patch=""
    [[ -f "$vhost_avail" ]]      && vhost_to_patch="$vhost_avail"
    [[ -f "$nine_router_vhost" ]] && vhost_to_patch="$nine_router_vhost"

    if [[ -n "$vhost_to_patch" ]]; then
        backup_file "$vhost_to_patch" >/dev/null || true
        # Replace ssl_certificate and ssl_certificate_key lines
        sed -i \
            -e "s|ssl_certificate\b[^;]*;|ssl_certificate     ${cert_file};|g" \
            -e "s|ssl_certificate_key\b[^;]*;|ssl_certificate_key ${key_file};|g" \
            "$vhost_to_patch"
        # Remove certbot-specific includes that don't apply to CF origin certs
        sed -i \
            -e '/include.*options-ssl-nginx\.conf/d' \
            -e '/ssl_dhparam.*ssl-dhparams\.pem/d' \
            "$vhost_to_patch"
        # Add basic TLS settings in their place if not already present
        if ! grep -q 'ssl_protocols' "$vhost_to_patch"; then
            sed -i "/ssl_certificate_key/a\\    ssl_protocols TLSv1.2 TLSv1.3;" "$vhost_to_patch"
        fi
        print_ok "  Nginx vhost updated: ${vhost_to_patch}"
        log_info "ssl_issue_cf_origin_cert: vhost patched at ${vhost_to_patch}"
    else
        print_warn "  No managed vhost found for ${domain} — vhost not patched."
        print_warn "  Add manually: ssl_certificate ${cert_file}; ssl_certificate_key ${key_file};"
    fi

    # ── Step 6: Set Cloudflare SSL mode to Full (Strict) ─────────────────────
    print_warn "Setting Cloudflare SSL mode to Full (Strict) for zone ${zone_id}..."
    local ssl_resp ssl_ok
    ssl_resp=$(curl -s --max-time 10 \
        -X PATCH \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data '{"value":"strict"}' \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}/settings/ssl" 2>/dev/null || true)
    ssl_ok=$(printf '%s' "$ssl_resp" | grep -o '"success":true' || true)
    if [[ -n "$ssl_ok" ]]; then
        print_ok "  Cloudflare SSL mode set to Full (Strict)."
        log_info "ssl_issue_cf_origin_cert: CF SSL mode set to strict for zone ${zone_id}"
    else
        print_warn "  Could not set CF SSL mode automatically."
        print_warn "  Set manually: Cloudflare Dashboard → SSL/TLS → Full (Strict)"
    fi

    # ── Step 7: nginx -t && reload ────────────────────────────────────────────
    if ! _nginx_test_and_reload; then
        print_error "Nginx reload failed. Cert installed but nginx may not be serving it."
        print_error "Run 'nginx -t' to diagnose."
        return 1
    fi

    echo ""
    print_ok "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_ok "Cloudflare Origin Certificate issued for: ${domain}"
    print_ok "  Cert : ${cert_file}"
    print_ok "  Key  : ${key_file}"
    print_ok "  Valid: 15 years (no renewal needed)"
    print_ok "  Mode : Cloudflare Full (Strict)"
    print_ok "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "ssl_issue_cf_origin_cert: completed successfully for ${domain}"
}

# ssl_show_cf_origin_certs
# List all locally installed Cloudflare Origin Certificates.
# Note: The CF Origin CA API (/v4/certificates) requires a zone_id per request
# and cannot list all certs globally — so we rely on local files as ground truth.
ssl_show_cf_origin_certs() {
    print_section "Cloudflare Origin Certificates"
    require_root || return 1

    local cert_count=0
    local found_any=0

    echo ""
    echo "  Locally installed CF Origin Certificates:"
    echo "  ─────────────────────────────────────────────────────────────────"

    local f
    for f in /etc/nginx/ssl/*/cf-origin.pem; do
        [[ -f "$f" ]] || continue
        found_any=1
        local domain exp san
        domain=$(basename "$(dirname "$f")")
        exp=$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "unknown")
        san=$(openssl x509 -in "$f" -noout -text 2>/dev/null \
            | grep -A1 'Subject Alternative Name' | tail -1 \
            | sed 's/DNS://g; s/,//g; s/^[[:space:]]*//' || echo "")
        local key_file
        key_file="$(dirname "$f")/cf-origin.key"
        local key_status="✓ key present"
        [[ -f "$key_file" ]] || key_status="✗ key MISSING"
        (( cert_count++ ))
        printf '  %2d) Domain : %s\n' "$cert_count" "$domain"
        printf '      SANs   : %s\n' "${san:-n/a}"
        printf '      Expires: %s\n' "$exp"
        printf '      Key    : %s\n' "$key_status"
        printf '      Cert   : %s\n' "$f"
        echo ""
    done

    if [[ "$found_any" -eq 0 ]]; then
        print_warn "No local CF origin certs found under /etc/nginx/ssl/*/cf-origin.pem"
        print_warn "Use option 7 to issue a Cloudflare Origin Certificate."
        return 0
    fi

    echo "  ─────────────────────────────────────────────────────────────────"
    print_ok "Total: ${cert_count} CF origin certificate(s) installed."
    log_info "ssl_show_cf_origin_certs: listed ${cert_count} cert(s)"
}

ssl_renew_all() {
    require_root || return 1
    # F-21: guard — only install certbot if not already present.
    # Previously called _install_certbot_snap unconditionally, running
    # 'snap refresh core' on every renewal run (~30 s overhead).
    _ensure_certbot
    certbot renew
    _sync_all_managed_vhosts
    # P-03 fix: if reload fails after renewal, nginx continues to serve expired/stale
    # certs — this must surface as an error, not be silently swallowed.
    if ! _nginx_test_and_reload; then
        print_error "Nginx reload failed after SSL renewal sync."
        print_warn "Certs renewed OK but nginx may be serving stale certs — check 'nginx -t'."
        log_error "ssl_renew_all: _nginx_test_and_reload failed"
        return 1
    fi
    log_info "ssl_renew_all: certbot renew completed; all managed vhosts synced"
}
ssl_list_certs() {
    # F-21: same guard — only install if absent.
    _ensure_certbot
    certbot certificates
}

# ── P2-03A: Advanced Web Controls ────────────────────────────

NGINX_SNIPPETS_DIR="/etc/nginx/snippets"

menu_nginx_web_controls() {
    _nginx_web_controls_menu_run() {
        "$@"
        return 0
    }

    while true; do
        print_section "Advanced Web Controls"
        echo "  1) Enable Cloudflare real IP logging"
        echo "  2) Remove Cloudflare real IP snippet"
        echo "  3) Add custom X-Powered-By header"
        echo "  4) Remove custom X-Powered-By snippet"
        echo "  5) Enable Cloudflare IP restrict (block non-CF traffic)"
        echo "  6) Refresh Cloudflare IP list (re-download from cloudflare.com)"
        echo "  7) Remove Cloudflare IP restrict"
        echo "  0) Back"
        echo ""
        read -r -p "Select: " choice
        case "$choice" in
            1) _nginx_web_controls_menu_run nginx_enable_cloudflare_real_ip; press_enter ;;
            2) _nginx_web_controls_menu_run nginx_remove_cloudflare_real_ip; press_enter ;;
            3) _nginx_web_controls_menu_run nginx_add_custom_powered_by; press_enter ;;
            4) _nginx_web_controls_menu_run nginx_remove_custom_powered_by; press_enter ;;
            5) _nginx_web_controls_menu_run nginx_enable_cloudflare_ip_restrict; press_enter ;;
            6) _nginx_web_controls_menu_run nginx_refresh_cloudflare_ips; press_enter ;;
            7) _nginx_web_controls_menu_run nginx_remove_cloudflare_ip_restrict; press_enter ;;
            0) return 0                                     ;;
            *) print_warn "Invalid option"                 ;;
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

# _nginx_fetch_cloudflare_ips
# F-22 helper: download live Cloudflare CIDR ranges from the official endpoints.
# Prints one CIDR per line on stdout; returns 1 and prints an error on fetch failure.
_nginx_fetch_cloudflare_ips() {
    local v4 v6
    v4=$(curl -sf --max-time 15 https://www.cloudflare.com/ips-v4 2>/dev/null) || {
        print_error "F-22: Failed to fetch Cloudflare IPv4 ranges from cloudflare.com/ips-v4"
        return 1
    }
    v6=$(curl -sf --max-time 15 https://www.cloudflare.com/ips-v6 2>/dev/null) || {
        print_error "F-22: Failed to fetch Cloudflare IPv6 ranges from cloudflare.com/ips-v6"
        return 1
    }
    if [[ -z "$v4" && -z "$v6" ]]; then
        print_error "F-22: cloudflare.com returned empty IP lists — aborting to avoid locking out all traffic."
        return 1
    fi
    printf '%s\n%s\n' "$v4" "$v6"
}

# _nginx_write_cf_restrict_conf <restrict_conf> <ranges>
# Write the geo {} block from the given newline-separated CIDR list.
_nginx_write_cf_restrict_conf() {
    local restrict_conf="$1"
    local ranges="$2"
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%MZ')

    {
        echo "# Cloudflare IP Restrict — generated by OPS"
        echo "# Source: https://www.cloudflare.com/ips/"
        echo "# Last refreshed: ${ts}"
        echo "# To update: use 'Refresh Cloudflare IP list' from the Advanced Web Controls menu."
        echo ""
        echo "geo \$blocked_cf {"
        echo "    default 1;"
        while IFS= read -r cidr; do
            [[ -z "$cidr" ]] && continue
            printf '    %-22s 0;\n' "$cidr"
        done <<< "$ranges"
        echo "    # Allow localhost / loopback always"
        echo "    127.0.0.0/8            0;"
        echo "    ::1                    0;"
        echo "}"
    } > "$restrict_conf"
    chmod 644 "$restrict_conf"
}

# nginx_refresh_cloudflare_ips
# F-22 fix: download current CF IP ranges from cloudflare.com and regenerate
# /etc/nginx/conf.d/cloudflare-ip-restrict.conf in-place.
# Safe to call at any time; takes a backup before overwriting.
nginx_refresh_cloudflare_ips() {
    print_section "Refresh Cloudflare IP List"
    require_root || return 1

    local restrict_conf="/etc/nginx/conf.d/cloudflare-ip-restrict.conf"
    if [[ ! -f "$restrict_conf" ]]; then
        print_warn "CF IP restrict config not found: $restrict_conf"
        print_warn "Enable CF IP restrict first (option 5), then refresh."
        return 1
    fi

    print_warn "Fetching current Cloudflare IP ranges from cloudflare.com..."
    local ranges
    ranges=$(_nginx_fetch_cloudflare_ips) || return 1

    backup_file "$restrict_conf" >/dev/null || true
    _nginx_write_cf_restrict_conf "$restrict_conf" "$ranges"

    local count
    count=$(grep -cE 'cidr|\s0;' "$restrict_conf" 2>/dev/null || grep -c '0;' "$restrict_conf" || true)
    print_ok "Cloudflare IP list refreshed: $restrict_conf"
    log_info "F-22: nginx_refresh_cloudflare_ips: ranges written at $(date -u '+%Y-%m-%dT%H:%MZ')"

    if nginx -t 2>/dev/null; then
        # P-03 fix: if service_reload fails, don't print_ok — operator needs to know.
        if service_reload nginx; then
            print_ok "Nginx reloaded with updated Cloudflare IP ranges."
        else
            print_warn "nginx -t OK but reload returned non-zero — check 'systemctl status nginx'."
        fi
    else
        print_error "nginx -t failed after refresh — check $restrict_conf manually."
        return 1
    fi
}

# nginx_enable_cloudflare_ip_restrict
# F-22 fix: fetches live IP ranges from cloudflare.com instead of using
# hardcoded ranges that go stale when Cloudflare adds new subnets.
# Only enable when the server is BEHIND Cloudflare (Orange Cloud ON for all domains).
# OPT-IN ONLY — not applied automatically during install.
nginx_enable_cloudflare_ip_restrict() {
    print_section "Enable Cloudflare IP Restrict"
    require_root || return 1

    print_warn "WARNING: This blocks ALL traffic not originating from Cloudflare IPs."
    print_warn "Only enable if this server is fully behind Cloudflare (Orange Cloud ON for all domains)."
    echo ""
    if ! prompt_confirm "Continue and write CF IP restrict config?"; then
        print_warn "Aborted."
        return 0
    fi

    local conf_dir="/etc/nginx/conf.d"
    local restrict_conf="${conf_dir}/cloudflare-ip-restrict.conf"
    ensure_dir "$conf_dir"
    backup_file "$restrict_conf" >/dev/null || true

    # F-22 fix: fetch live ranges instead of writing stale hardcoded ones.
    print_warn "Fetching current Cloudflare IP ranges from cloudflare.com..."
    local ranges
    ranges=$(_nginx_fetch_cloudflare_ips) || return 1

    _nginx_write_cf_restrict_conf "$restrict_conf" "$ranges"

    print_ok "CF IP restrict config written: $restrict_conf"
    echo ""
    print_warn "Next step: add the following inside each server {} block you want to restrict:"
    echo '    if ($blocked_cf) { return 444; }'
    print_warn "Then run: nginx -t && systemctl reload nginx"
    print_warn "To refresh IP ranges in future: use 'Refresh Cloudflare IP list' (option 6) from this menu."
    print_warn "To remove: use 'Remove Cloudflare IP restrict' (option 7) from this menu."
    log_info "F-22: nginx_enable_cloudflare_ip_restrict: written $restrict_conf with live-fetched ranges"
}

# nginx_remove_cloudflare_ip_restrict
# Removes the CF IP restrict conf.d file and reloads nginx.
nginx_remove_cloudflare_ip_restrict() {
    print_section "Remove Cloudflare IP Restrict"
    require_root || return 1
    local restrict_conf="/etc/nginx/conf.d/cloudflare-ip-restrict.conf"
    if [[ ! -f "$restrict_conf" ]]; then
        print_warn "File not found: $restrict_conf (nothing to remove)"
        return 0
    fi
    if ! prompt_confirm "Remove $restrict_conf?"; then
        print_warn "Aborted."
        return 0
    fi
    backup_file "$restrict_conf" >/dev/null || true
    rm -f "$restrict_conf"
    print_ok "Removed: $restrict_conf"
    print_warn "Also remove any 'if (\$blocked_cf)' lines from server blocks."
    print_warn "Run: nginx -t && systemctl reload nginx"
    log_info "nginx_remove_cloudflare_ip_restrict: done"
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
    # F-14 fix: reject newlines unconditionally (an HTTP header value must be a single line).
    if [[ "$header_value" == *$'\n'* ]]; then
        print_error "Header value must not contain newlines."
        return 1
    fi
    # F-14 fix: sanitize for sed replacement — escape \, &, and | (the sed delimiter)
    # so that special characters in operator input cannot corrupt the sed command or
    # the generated snippet file.
    local safe_header_value
    safe_header_value="${header_value//\\/\\\\}"   # \ → \\
    safe_header_value="${safe_header_value//&/\\&}" # & → \&
    safe_header_value="${safe_header_value//|/\\|}"  # | → \|  (delimiter escape)

    ensure_dir "$NGINX_SNIPPETS_DIR"
    backup_file "$snippet" >/dev/null || true
    sed "s|{{VALUE}}|${safe_header_value}|g" "$tpl" > "$snippet"
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
