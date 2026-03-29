#!/usr/bin/env bash
# ============================================================
# ops/modules/php.sh
# Purpose:  Multi-PHP (7.4, 8.1, 8.2, 8.3) install and PHP-FPM tuning
# Part of:  OPS - VPS Production Setup & Manager
# ============================================================
# Called by bin/ops via menu dispatch.
# Do NOT add set -euo pipefail here - inherited from bin/ops.

PHP_SUPPORTED_VERSIONS=("7.4" "8.1" "8.2" "8.3")
PHP_COMMON_EXTS=(cli fpm common mysql curl gd intl mbstring opcache xml zip soap bcmath)
PHP_SITES_DIR="/etc/ops/php-sites"

php_require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        print_error "This action requires root privileges (run OPS with sudo/root)."
        return 1
    fi
}

php_is_supported_version() {
    local ver="$1"
    local candidate
    for candidate in "${PHP_SUPPORTED_VERSIONS[@]}"; do
        if [[ "$candidate" == "$ver" ]]; then
            return 0
        fi
    done
    return 1
}

php_validate_site_name() {
    local site="$1"
    if [[ ! "$site" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        print_error "Invalid site name. Allowed: letters, numbers, dot, underscore, hyphen."
        return 1
    fi
}

php_get_pool_file() {
    local site="$1"
    local ver="$2"
    echo "/etc/php/${ver}/fpm/pool.d/${site}.conf"
}

php_get_socket_path() {
    local site="$1"
    local ver="$2"
    echo "/run/php/php${ver}-fpm-${site}.sock"
}

php_pool_tuning_for_tier() {
    local tier="${OPS_TIER:-S}"
    case "$tier" in
        S)
            echo "pm=ondemand"
            echo "pm.max_children=5"
            echo "pm.process_idle_timeout=10s"
            echo "pm.max_requests=500"
            ;;
        M)
            echo "pm=dynamic"
            echo "pm.max_children=20"
            echo "pm.start_servers=4"
            echo "pm.min_spare_servers=2"
            echo "pm.max_spare_servers=8"
            echo "pm.max_requests=1000"
            ;;
        *)
            echo "pm=dynamic"
            # S2-4: Tier L — conservative 30 workers (7.8 GB VPS, ~40MB/worker).
            # Leaves headroom for MariaDB + Nginx; prevents OOM under burst.
            echo "pm.max_children=30"
            echo "pm.start_servers=5"
            echo "pm.min_spare_servers=3"
            echo "pm.max_spare_servers=10"
            echo "pm.max_requests=2000"
            ;;
    esac
}

php_ini_tuning_for_tier() {
    local tier="${OPS_TIER:-S}"
    case "$tier" in
        S)
            echo "memory_limit=128M"
            echo "opcache.memory_consumption=64"
            echo "opcache.max_accelerated_files=10000"
            ;;
        M)
            echo "memory_limit=256M"
            echo "opcache.memory_consumption=128"
            echo "opcache.max_accelerated_files=20000"
            ;;
        *)
            echo "memory_limit=512M"
            echo "opcache.memory_consumption=256"
            echo "opcache.max_accelerated_files=50000"
            ;;
    esac
    echo "opcache.enable=1"
    echo "opcache.enable_cli=1"
    echo "opcache.interned_strings_buffer=16"
    echo "opcache.revalidate_freq=2"
    echo "opcache.validate_timestamps=1"
    echo "opcache.save_comments=1"

    # Security baseline — applied regardless of tier
    echo "expose_php=Off"
    echo "display_errors=Off"
    echo "log_errors=On"
    echo "allow_url_fopen=Off"
    echo "allow_url_include=Off"
    # disable_functions: blocks common RCE vectors.
    # If your app needs exec/shell_exec, add a per-pool php_admin_value override instead.
    echo "disable_functions=exec,passthru,shell_exec,system,proc_open,popen,proc_terminate,proc_get_status,pcntl_exec,parse_ini_file,show_source"
}

# php_set_ini_key <file> <key> <value>
#
# Sets (or adds) a key=value pair in a PHP ini-style file.
#
# INTENTIONAL BEHAVIOR — F-17: The grep/sed patterns below match BOTH active
# keys (key = value) AND commented-out keys (; key = value).  This is by
# design: many distributions ship security-relevant settings commented out
# (e.g. "; display_errors = On") and OPS must activate and override them.
#
# This is safe because OPS only ever calls this function with values that are
# already security-correct (expose_php=Off, display_errors=Off, etc.).  Even
# if a sysadmin left a commented line like "; expose_php = On", OPS will turn
# it into "expose_php = Off" — still the correct direction.
#
# DO NOT change the ";?" part of the regex without understanding this contract.
# If you need to preserve a deliberately commented-out key, remove it from
# php_ini_tuning_for_tier / php_pool_tuning_for_tier instead.
php_set_ini_key() {
    local file="$1"
    local key="$2"
    local value="$3"
    local key_regex

    if [[ ! -f "$file" ]]; then
        return 0
    fi

    key_regex=$(printf '%s' "$key" | sed 's/[][(){}.^$*+?|\\/]/\\&/g')

    # ;? intentionally matches both active and commented-out keys — see above.
    if grep -Eq "^[[:space:]]*;?[[:space:]]*${key_regex}[[:space:]]*=" "$file"; then
        sed -i -E "s|^[[:space:]]*;?[[:space:]]*${key_regex}[[:space:]]*=.*|${key} = ${value}|" "$file"
    else
        printf '\n%s = %s\n' "$key" "$value" >> "$file"
    fi
}

php_ensure_ondrej_ppa() {
    if [[ ! -f "/etc/apt/sources.list.d/ondrej-ubuntu-php.list" ]]; then
        # P4-C: python3-launchpadlib is required by add-apt-repository on Ubuntu 24.04.
        # It was removed from the default image; without it the PPA addition fails.
        apt_install software-properties-common python3-launchpadlib
        add-apt-repository ppa:ondrej/php -y
    fi
    apt_update
}

# php_disable_default_www_pool <ver>
#
# S2-4: The distro ships /etc/php/{ver}/fpm/pool.d/www.conf with pm.max_children=5
# (a hard-coded default that ignores server tier/RAM completely).  OPS manages all
# pools via named site pools; the www pool is redundant and wastes worker slots
# under concurrent load, causing 502s on servers with enough RAM.
# Disable it by renaming to .disabled so php-fpm ignores it, but it can be
# manually re-enabled if needed.
php_disable_default_www_pool() {
    local ver="$1"
    local www_pool="/etc/php/${ver}/fpm/pool.d/www.conf"
    if [[ -f "$www_pool" ]]; then
        mv "$www_pool" "${www_pool}.disabled"
        log_info "php_disable_default_www_pool: disabled ${www_pool} (S2-4: prevents 5-worker bottleneck)"
        print_ok "Disabled default www pool for PHP ${ver} (prevents pm.max_children=5 bottleneck)."
    fi
}

# install_php_version <ver>
install_php_version() {
    local ver="$1"
    local packages=()
    local ext

    php_require_root || return 1
    if ! php_is_supported_version "$ver"; then
        print_error "Unsupported PHP version: $ver. Allowed: ${PHP_SUPPORTED_VERSIONS[*]}"
        return 1
    fi

    php_ensure_ondrej_ppa

    for ext in "${PHP_COMMON_EXTS[@]}"; do
        packages+=("php${ver}-${ext}")
    done

    apt_install "${packages[@]}"
    service_enable "php${ver}-fpm"
    service_start "php${ver}-fpm"
    # S2-4: Disable the distro default www pool before tuning so it never
    # competes with OPS-managed site pools at pm.max_children=5.
    php_disable_default_www_pool "$ver"
    tune_php "$ver"
    print_ok "Installed PHP ${ver} with common extensions."
    log_info "install_php_version: PHP ${ver} installed"
}

# configure_php_pool <site> <ver>
configure_php_pool() {
    local site="$1"
    local ver="$2"
    local socket pool_file key value

    php_require_root || return 1
    php_validate_site_name "$site" || return 1
    if ! php_is_supported_version "$ver"; then
        print_error "Unsupported PHP version: $ver. Allowed: ${PHP_SUPPORTED_VERSIONS[*]}"
        return 1
    fi
    if [[ ! -d "/etc/php/${ver}/fpm" ]]; then
        print_error "php${ver}-fpm is not installed."
        return 1
    fi

    socket="$(php_get_socket_path "$site" "$ver")"
    pool_file="$(php_get_pool_file "$site" "$ver")"

    # P-02: idempotency guard — pool file already exists.
    # configure_php_pool previously overwrote silently; now we prompt, consistent
    # with add_domain (F-03) and node_add_app.
    # FORCE_OVERWRITE=1 bypasses the prompt for scripted/unattended callers.
    if [[ -f "$pool_file" ]]; then
        if [[ "${FORCE_OVERWRITE:-0}" != "1" ]]; then
            print_warn "PHP-FPM pool '${site}' (PHP ${ver}) already exists: $pool_file"
            print_warn "Re-running will overwrite any manual customisations (env vars, memory limits, security settings, etc)."
            local _pool_ow_ans
            read -r -p "Overwrite existing pool config for '${site}'? [y/N]: " _pool_ow_ans
            if [[ "${_pool_ow_ans,,}" != "y" ]]; then
                print_warn "Aborted. Existing pool config for '${site}' was NOT changed."
                return 0
            fi
        fi
        log_info "P-02: Overwriting existing PHP-FPM pool for '${site}' (FORCE_OVERWRITE=${FORCE_OVERWRITE:-0})."
    fi

    backup_file "$pool_file" >/dev/null 2>&1 || true
    write_file "$pool_file" <<EOF_POOL
[${site}]
user = www-data
group = www-data
listen = ${socket}
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
; F-06: pm.status_path and ping.path intentionally omitted.
; If you re-enable them, the Nginx vhost MUST include a location block
; that restricts access to 127.0.0.1 only. See nginx.sh _render_php_vhost.
chdir = /
; P3-B: clear_env=yes prevents FPM workers inheriting parent env secrets.
; If your app needs specific env vars, add explicit lines below this pool config, e.g.:
;   env[DB_PASSWORD] = secret
;   env[APP_ENV] = production
clear_env = yes
security.limit_extensions = .php .phtml
EOF_POOL

    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        php_set_ini_key "$pool_file" "$key" "$value"
    done < <(php_pool_tuning_for_tier)

    ensure_dir "$PHP_SITES_DIR"
    write_file "${PHP_SITES_DIR}/${site}.conf" <<EOF_SITE
SITE_NAME="${site}"
SITE_DIR=""
SITE_PHP_VERSION="${ver}"
SITE_FPM_POOL="${site}"
SITE_FPM_SOCKET="${socket}"
SITE_DOMAIN=""
SITE_CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF_SITE

    chmod 0644 "${PHP_SITES_DIR}/${site}.conf"

    if ! "php-fpm${ver}" -t; then
        print_error "php-fpm${ver} config test failed."
        return 1
    fi

    service_restart "php${ver}-fpm"
    print_ok "Configured PHP-FPM pool '${site}' for PHP ${ver}."
    log_info "configure_php_pool: pool '${site}' configured for PHP ${ver}"

    # F-08: Sync domain state file + rebuild Nginx vhost when the PHP version changes.
    # Without this, the Nginx vhost continues pointing to the OLD php socket path
    # (e.g. php8.1-fpm-site.sock) after a PHP upgrade -> 502 Bad Gateway.
    # The domain conf file uses the same slug as the site name.
    local dom_conf="${OPS_CONFIG_DIR}/domains/${site}.conf"
    if [[ -f "$dom_conf" ]]; then
        local old_socket old_version
        old_socket=$(grep '^DOMAIN_PHP_SOCKET=' "$dom_conf" 2>/dev/null | cut -d= -f2- | tr -d '"')
        old_version=$(grep '^DOMAIN_PHP_VERSION=' "$dom_conf" 2>/dev/null | cut -d= -f2- | tr -d '"')

        if [[ "$old_socket" != "$socket" || "$old_version" != "$ver" ]]; then
            log_info "configure_php_pool: syncing domain state for ${site}: socket ${old_socket} -> ${socket}, version ${old_version} -> ${ver}"
            sed -i "s|^DOMAIN_PHP_SOCKET=.*|DOMAIN_PHP_SOCKET=\"${socket}\"|"   "$dom_conf"
            sed -i "s|^DOMAIN_PHP_VERSION=.*|DOMAIN_PHP_VERSION=\"${ver}\"|"    "$dom_conf"

            # Rebuild Nginx vhost with updated socket — requires nginx.sh functions to be loaded.
            if declare -f _rebuild_domain_vhost >/dev/null 2>&1; then
                if _rebuild_domain_vhost "$site"; then
                    if declare -f _nginx_test_and_reload >/dev/null 2>&1; then
                        _nginx_test_and_reload || print_warn "Nginx reload failed after socket update for ${site}."
                    fi
                else
                    print_warn "Vhost rebuild failed for ${site} — check /etc/nginx/sites-available/${site}"
                fi
            else
                print_warn "nginx.sh not loaded — run 'Domains & Nginx → Rebuild vhost' for ${site} manually."
            fi
        fi
    fi
}

# set_php_cli_default <ver>
set_php_cli_default() {
    local ver="$1"
    local php_bin="/usr/bin/php${ver}"

    php_require_root || return 1
    if ! php_is_supported_version "$ver"; then
        print_error "Unsupported PHP version: $ver. Allowed: ${PHP_SUPPORTED_VERSIONS[*]}"
        return 1
    fi
    if [[ ! -x "$php_bin" ]]; then
        print_error "Binary not found: ${php_bin}."
        return 1
    fi

    update-alternatives --set php "$php_bin"
    print_ok "Default PHP CLI is now ${php_bin}."
}

# tune_php <ver>
tune_php() {
    local ver="$1"
    local ini_file key value

    php_require_root || return 1
    if ! php_is_supported_version "$ver"; then
        print_error "Unsupported PHP version: $ver. Allowed: ${PHP_SUPPORTED_VERSIONS[*]}"
        return 1
    fi

    for ini_file in "/etc/php/${ver}/fpm/php.ini" "/etc/php/${ver}/cli/php.ini"; do
        if [[ ! -f "$ini_file" ]]; then
            continue
        fi
        backup_file "$ini_file" >/dev/null 2>&1 || true
        while IFS='=' read -r key value; do
            [[ -z "$key" ]] && continue
            php_set_ini_key "$ini_file" "$key" "$value"
        done < <(php_ini_tuning_for_tier)
    done

    if [[ -x "/usr/sbin/php-fpm${ver}" || -x "/usr/bin/php-fpm${ver}" ]]; then
        if ! "php-fpm${ver}" -t; then
            print_error "php-fpm${ver} config test failed after tuning."
            return 1
        fi
        service_restart "php${ver}-fpm"
    fi

    print_ok "Applied PHP tuning for version ${ver} (Tier: ${OPS_TIER:-S})."
    print_warn "SECURITY: allow_url_fopen=Off is now enforced. PHP apps using file_get_contents() for remote URLs must use cURL instead."
    print_warn "SECURITY: disable_functions blocks exec/shell_exec/system. Add php_admin_value overrides per-pool if your app requires them."
    log_info "tune_php: PHP ${ver} tuned (tier=${OPS_TIER:-S})"
}

php_verify_version() {
    local ver="$1"
    print_section "Verify PHP ${ver}"
    php -v | head -n 1 || true
    "php-fpm${ver}" -t || true
    service_status "php${ver}-fpm" || true
}

php_is_installed_version() {
    local ver="$1"
    [[ -x "/usr/bin/php${ver}" ]] && [[ -d "/etc/php/${ver}" ]]
}

menu_php() {
    while true; do
        print_section "PHP / PHP-FPM Management"
        echo "  1) List installed PHP versions"
        echo "  2) Install or remove PHP versions"
        echo "  3) Configure PHP-FPM pools"
        echo "  4) Set default PHP CLI version"
        echo "  5) Show PHP-FPM status"
        echo "  6) Reset .htaccess (PHP sites only)"
        echo "  0) Back"
        echo ""
        read -r -p "Select: " choice
        case "$choice" in
            1) php_list_versions        || true; press_enter ;;
            2) php_manage_version       || true; press_enter ;;
            3) php_configure_pool       || true; press_enter ;;
            4) php_set_default          || true; press_enter ;;
            5) php_fpm_status           || true; press_enter ;;
            6) php_reset_htaccess_menu  || true; press_enter ;;
            0) return                           ;;
            *) print_warn "Invalid option"      ;;
        esac
    done
}

php_manage_version() {
    print_section "Install or Remove PHP Version"
    prompt_input "Action (install/remove)" "install"
    local action="${REPLY,,}"

    prompt_input "PHP version (7.4 | 8.1 | 8.2 | 8.3)" "8.2"
    local ver="$REPLY"

    if ! php_is_supported_version "$ver"; then
        print_error "Unsupported PHP version: $ver."
        return 1
    fi

    case "$action" in
        install)
            install_php_version "$ver" || return 1
            php_verify_version "$ver"
            ;;
        remove)
            php_require_root || return 1
            apt_remove "php${ver}-cli" "php${ver}-fpm" "php${ver}-common" \
                "php${ver}-mysql" "php${ver}-curl" "php${ver}-gd" "php${ver}-intl" \
                "php${ver}-mbstring" "php${ver}-opcache" "php${ver}-xml" "php${ver}-zip" \
                "php${ver}-soap" "php${ver}-bcmath" || true
            print_ok "Requested removal for PHP ${ver} packages."
            log_info "php_manage_version: PHP ${ver} removed"
            ;;
        *)
            print_error "Invalid action: ${action}. Use install or remove."
            return 1
            ;;
    esac
}

php_list_versions() {
    local ver svc
    print_section "Installed PHP Versions"

    for ver in "${PHP_SUPPORTED_VERSIONS[@]}"; do
        svc="php${ver}-fpm"
        if php_is_installed_version "$ver"; then
            if service_active "$svc"; then
                print_ok "PHP ${ver}: installed, ${svc} active"
            else
                print_warn "PHP ${ver}: installed, ${svc} not active"
            fi
        else
            print_warn "PHP ${ver}: not installed"
        fi
    done

    if command -v php >/dev/null 2>&1; then
        echo ""
        php -v | head -n 1 || true
    fi
}

php_configure_pool() {
    print_section "Configure PHP-FPM Pool"
    prompt_input "Site name (pool name)" ""
    local site="$REPLY"
    prompt_input "PHP version (7.4 | 8.1 | 8.2 | 8.3)" "8.2"
    local ver="$REPLY"

    configure_php_pool "$site" "$ver" || return 1
    php_verify_version "$ver"
}

php_set_default() {
    print_section "Set Default PHP Version"
    prompt_input "PHP version for CLI default" "8.2"
    local ver="$REPLY"

    set_php_cli_default "$ver" || return 1
    php -v | head -n 1 || true
}

php_apply_tuning() {
    print_section "Apply PHP-FPM Tuning (Tier: ${OPS_TIER:-?})"
    prompt_input "PHP version to tune (7.4 | 8.1 | 8.2 | 8.3 or all)" "all"
    local ver="$REPLY"
    local v

    if [[ "$ver" == "all" ]]; then
        for v in "${PHP_SUPPORTED_VERSIONS[@]}"; do
            if php_is_installed_version "$v"; then
                tune_php "$v"
            fi
        done
        return 0
    fi

    tune_php "$ver"
}

php_fpm_status() {
    local ver svc
    print_section "PHP-FPM Status"
    for ver in "${PHP_SUPPORTED_VERSIONS[@]}"; do
        svc="php${ver}-fpm"
        if systemctl list-unit-files | grep -q "^${svc}\\.service"; then
            service_status "$svc" || true
        fi
    done
}

# ── P2-03A: .htaccess factory reset (PHP-secondary only) ────

php_reset_htaccess_menu() {
    print_section ".htaccess Factory Reset"
    print_warn "This resets .htaccess for a PHP site web root."
    print_warn "Only applicable to PHP-backend sites. Backup is made automatically."
    echo ""

    # List PHP sites from OPS state
    local found=0 state_file site_name site_dir domain
    for state_file in "${PHP_SITES_DIR:-/etc/ops/php-sites}/"*.conf; do
        [[ -f "$state_file" ]] || continue
        site_name=$(grep '^SITE_NAME=' "$state_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
        site_dir=$(grep '^SITE_DIR=' "$state_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
        domain=$(grep '^SITE_DOMAIN=' "$state_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
        echo "  - ${site_name} (${domain:-?}) → ${site_dir:-/var/www/${site_name}}"
        found=1
    done

    # Also check domain state files for php-type sites
    for state_file in "${OPS_CONFIG_DIR:-/etc/ops}/domains/"*.conf; do
        [[ -f "$state_file" ]] || continue
        local dtype
        dtype=$(grep '^DOMAIN_BACKEND_TYPE=' "$state_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
        [[ "$dtype" != "php" ]] && continue
        domain=$(grep '^DOMAIN=' "$state_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
        local web_root
        web_root=$(grep '^DOMAIN_WEB_ROOT=' "$state_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
        echo "  - ${domain} → ${web_root:-/var/www/${domain}}"
        found=1
    done

    if [[ "$found" -eq 0 ]]; then
        print_warn "No PHP sites found in OPS state."
        echo ""
    fi

    prompt_input "Web root path to reset .htaccess (e.g. /var/www/mysite.com)"
    local web_root="$REPLY"

    if [[ -z "$web_root" ]]; then
        print_error "Web root path cannot be empty."
        return 1
    fi
    if [[ ! -d "$web_root" ]]; then
        print_error "Directory not found: $web_root"
        return 1
    fi

    php_reset_htaccess "$web_root"
}

# php_reset_htaccess <web_root>
php_reset_htaccess() {
    local web_root="${1:-}"
    if [[ -z "$web_root" || ! -d "$web_root" ]]; then
        print_error "Invalid web root: $web_root"
        return 1
    fi

    local htaccess="${web_root}/.htaccess"

    # Backup existing .htaccess before reset
    if [[ -f "$htaccess" ]]; then
        backup_file "$htaccess" >/dev/null 2>&1 || true
        print_warn "Backed up existing .htaccess"
    fi

    if ! prompt_confirm "Reset .htaccess in ${web_root}?"; then
        print_warn "Aborted."
        return 0
    fi

    # Write sensible secure default .htaccess
    cat > "$htaccess" <<'HTACCESS_EOF'
# .htaccess — reset by OPS (factory default)
# Secure baseline: denies access to sensitive files, passes everything else to index.php
# Adjust for your framework (WordPress, Laravel, etc.) as needed.

# Deny access to dot-files (except .well-known for ACME)
<FilesMatch "^\.(?!well-known)">>
    Require all denied
</FilesMatch>

# Deny access to common sensitive files
<FilesMatch "\.(env|json|lock|log|sql|bak|conf|ini|sh)$">
    Require all denied
</FilesMatch>

# Standard PHP front-controller rewrite
Options -Indexes

<IfModule mod_rewrite.c>
    RewriteEngine On
    RewriteBase /
    RewriteCond %{REQUEST_FILENAME} !-f
    RewriteCond %{REQUEST_FILENAME} !-d
    RewriteRule ^ index.php [L]
</IfModule>
HTACCESS_EOF

    chown "${ADMIN_USER:-www-data}":www-data "$htaccess" 2>/dev/null || true
    chmod 644 "$htaccess"

    print_ok ".htaccess reset complete: $htaccess"
    print_warn "If you use WordPress or Laravel, you may need to re-apply their specific rewrite rules."
    log_info "php_reset_htaccess: reset ${htaccess}"
}
