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

php_get_site_state_file() {
    local site="$1"
    echo "${PHP_SITES_DIR}/${site}.conf"
}

php_load_site_state() {
    local state_file="$1"
    local line key val
    while IFS= read -r line; do
        if [[ "$line" =~ ^(SITE_NAME|SITE_DIR|SITE_PHP_VERSION|SITE_FPM_POOL|SITE_FPM_SOCKET|SITE_DOMAIN|SITE_CREATED)=\"([^\"]*)\"$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            printf '%s=%s\n' "$key" "$(printf '%q' "$val")"
        fi
    done < "$state_file"
}

php_conf_get_key() {
    local file="$1"
    local key="$2"
    local line
    [[ -f "$file" ]] || return 0
    while IFS= read -r line; do
        if [[ "$line" =~ ^${key}=\"([^\"]*)\"$ ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            return 0
        fi
    done < "$file"
}

php_write_site_state() {
    local site="$1"
    local ver="$2"
    local socket="$3"
    local site_domain="${4:-}"
    local site_dir="${5:-}"
    local state_file existing_created=""

    state_file="$(php_get_site_state_file "$site")"
    if [[ -f "$state_file" ]]; then
        local SITE_NAME SITE_DIR SITE_PHP_VERSION SITE_FPM_POOL SITE_FPM_SOCKET SITE_DOMAIN SITE_CREATED
        eval "$(php_load_site_state "$state_file")"
        existing_created="${SITE_CREATED:-}"
        [[ -z "$site_domain" ]] && site_domain="${SITE_DOMAIN:-}"
        [[ -z "$site_dir" ]] && site_dir="${SITE_DIR:-}"
    fi

    if [[ -z "$site_dir" ]]; then
        if [[ -n "$site_domain" ]]; then
            site_dir="/var/www/${site_domain}"
        else
            site_dir="/var/www/${site}"
        fi
    fi
    [[ -n "$existing_created" ]] || existing_created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    ensure_dir "$PHP_SITES_DIR"
    write_file "$state_file" <<EOF_SITE
SITE_NAME="${site}"
SITE_DIR="${site_dir}"
SITE_PHP_VERSION="${ver}"
SITE_FPM_POOL="${site}"
SITE_FPM_SOCKET="${socket}"
SITE_DOMAIN="${site_domain}"
SITE_CREATED="${existing_created}"
EOF_SITE

    chmod 0644 "$state_file"
    chown root:root "$state_file" 2>/dev/null || true
}

php_write_pool_file_baseline() {
    local pool_file="$1"
    local site="$2"
    local socket="$3"

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
}

php_apply_pool_baseline() {
    local pool_file="$1"
    local site="$2"
    local socket="$3"
    local key value

    if [[ ! -f "$pool_file" ]]; then
        php_write_pool_file_baseline "$pool_file" "$site" "$socket"
    fi

    php_set_ini_key "$pool_file" "user" "www-data"
    php_set_ini_key "$pool_file" "group" "www-data"
    php_set_ini_key "$pool_file" "listen" "$socket"
    php_set_ini_key "$pool_file" "listen.owner" "www-data"
    php_set_ini_key "$pool_file" "listen.group" "www-data"
    php_set_ini_key "$pool_file" "listen.mode" "0660"
    php_set_ini_key "$pool_file" "chdir" "/"
    php_set_ini_key "$pool_file" "clear_env" "yes"
    php_set_ini_key "$pool_file" "security.limit_extensions" ".php .phtml"

    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        php_set_ini_key "$pool_file" "$key" "$value"
    done < <(php_pool_tuning_for_tier)

    chmod 0644 "$pool_file"
    chown root:root "$pool_file" 2>/dev/null || true
}

php_fpm_binary_exists() {
    local ver="$1"
    [[ -x "/usr/sbin/php-fpm${ver}" || -x "/usr/bin/php-fpm${ver}" ]]
}

php_socket_matches_contract() {
    local socket="$1"
    local ver="$2"
    local pool="$3"

    if [[ ! "$socket" =~ ^/run/php/php([0-9]+\.[0-9]+)-fpm-([A-Za-z0-9._-]+)\.sock$ ]]; then
        return 1
    fi

    [[ "${BASH_REMATCH[1]}" == "$ver" && "${BASH_REMATCH[2]}" == "$pool" ]]
}

php_read_vhost_fastcgi_sockets() {
    local vhost_file="$1"
    [[ -f "$vhost_file" ]] || return 0

    awk '
        /fastcgi_pass[[:space:]]+unix:/ {
            line=$0
            sub(/.*unix:/, "", line)
            sub(/;.*/, "", line)
            print line
        }
    ' "$vhost_file" | sort -u
}

php_fpm_validate_config() {
    local ver="$1"
    php_fpm_binary_exists "$ver" || return 0
    "php-fpm${ver}" -t
}

php_fpm_validate_and_apply() {
    local ver="$1"
    local svc="php${ver}-fpm"

    php_fpm_binary_exists "$ver" || return 0
    php_fpm_validate_config "$ver" || return 1

    if service_active "$svc"; then
        service_reload "$svc" 15
    else
        service_restart "$svc"
    fi
}

php_verify_domain_contracts_for_version() {
    local ver="$1"
    local state_file domain type domain_ver domain_socket domain_pool expected_socket
    local pool_file pool_listen site_state_file site_ver site_socket site_domain vhost_file fastcgi_sockets
    local checked=0 issues=0

    for state_file in "${OPS_CONFIG_DIR:-/etc/ops}/domains/"*.conf; do
        [[ -f "$state_file" ]] || continue
        type="$(php_conf_get_key "$state_file" "DOMAIN_BACKEND_TYPE")"
        [[ "$type" == "php" ]] || continue

        domain_ver="$(php_conf_get_key "$state_file" "DOMAIN_PHP_VERSION")"
        [[ "$domain_ver" == "$ver" ]] || continue

        checked=1
        domain="$(php_conf_get_key "$state_file" "DOMAIN")"
        domain_socket="$(php_conf_get_key "$state_file" "DOMAIN_PHP_SOCKET")"
        domain_pool="$(php_conf_get_key "$state_file" "DOMAIN_PHP_POOL")"
        if [[ -z "$domain_pool" && "$domain_socket" =~ ^/run/php/php[0-9]+\.[0-9]+-fpm-([A-Za-z0-9._-]+)\.sock$ ]]; then
            domain_pool="${BASH_REMATCH[1]}"
        fi
        [[ -n "$domain_pool" ]] || domain_pool="$(php_conf_get_key "$state_file" "DOMAIN")"

        if [[ -z "$domain_pool" ]] || ! php_socket_matches_contract "$domain_socket" "$domain_ver" "$domain_pool"; then
            print_warn "PHP domain ${domain:-$(basename "$state_file" .conf)} has mismatched state: version=${domain_ver:-empty}, pool=${domain_pool:-empty}, socket=${domain_socket:-empty}."
            issues=1
            continue
        fi

        expected_socket="$(php_get_socket_path "$domain_pool" "$domain_ver")"
        if [[ "$domain_socket" != "$expected_socket" ]]; then
            print_warn "PHP domain ${domain} uses socket ${domain_socket}, expected ${expected_socket}."
            issues=1
        fi

        pool_file="$(php_get_pool_file "$domain_pool" "$domain_ver")"
        if [[ ! -f "$pool_file" ]]; then
            print_warn "PHP domain ${domain} is missing pool file ${pool_file}."
            issues=1
        else
            pool_listen="$(awk -F= '/^[[:space:]]*listen[[:space:]]*=/{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' "$pool_file")"
            if [[ "$pool_listen" != "$expected_socket" ]]; then
                print_warn "PHP domain ${domain} pool file ${pool_file} points listen=${pool_listen:-empty}, expected ${expected_socket}."
                issues=1
            fi
        fi

        site_state_file="$(php_get_site_state_file "$domain_pool")"
        if [[ ! -f "$site_state_file" ]]; then
            print_warn "PHP domain ${domain} is missing pool state ${site_state_file}."
            issues=1
        else
            site_ver="$(php_conf_get_key "$site_state_file" "SITE_PHP_VERSION")"
            site_socket="$(php_conf_get_key "$site_state_file" "SITE_FPM_SOCKET")"
            site_domain="$(php_conf_get_key "$site_state_file" "SITE_DOMAIN")"
            if [[ "$site_ver" != "$domain_ver" || "$site_socket" != "$expected_socket" || "$site_domain" != "$domain" ]]; then
                print_warn "PHP domain ${domain} has drift between domain state and ${site_state_file}."
                issues=1
            fi
        fi

        vhost_file="/etc/nginx/sites-available/${domain}"
        fastcgi_sockets="$(php_read_vhost_fastcgi_sockets "$vhost_file")"
        if [[ -z "$fastcgi_sockets" ]]; then
            print_warn "PHP domain ${domain} has no fastcgi_pass socket in ${vhost_file}."
            issues=1
        elif [[ "$fastcgi_sockets" != "$expected_socket" ]]; then
            print_warn "PHP domain ${domain} fastcgi_pass drift in ${vhost_file}: ${fastcgi_sockets//$'\n'/, }."
            issues=1
        else
            print_ok "PHP domain ${domain}: pool/socket/vhost contract OK (${domain_pool})."
        fi
    done

    if (( checked == 0 )); then
        echo "No managed PHP domains use PHP ${ver}."
    elif (( issues == 0 )); then
        print_ok "All managed PHP domains using PHP ${ver} passed pool/socket/vhost checks."
    fi
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

php_ini_common_tuning_for_tier() {
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
    echo "opcache.interned_strings_buffer=16"
    echo "opcache.revalidate_freq=2"
    echo "opcache.validate_timestamps=1"
    echo "opcache.save_comments=1"
}

php_ini_cli_tuning() {
    echo "opcache.enable_cli=1"
}

php_ini_fpm_security_tuning() {
    # Security baseline — applied to FPM only.
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
# php_ini_common_tuning_for_tier / php_ini_fpm_security_tuning / php_pool_tuning_for_tier instead.
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

# configure_php_pool <site> <ver> [site_domain] [site_dir] [skip_domain_sync]
configure_php_pool() {
    local site="$1"
    local ver="$2"
    local site_domain="${3:-}"
    local site_dir="${4:-}"
    local skip_domain_sync="${5:-0}"
    local socket pool_file state_file snapshot_root old_ver="" old_pool_file="" dom_conf=""
    local domain_backend_type="" domain_ssl_mode="none" domain_web_root=""

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
    state_file="$(php_get_site_state_file "$site")"

    if [[ -f "$state_file" ]]; then
        local SITE_NAME SITE_DIR SITE_PHP_VERSION SITE_FPM_POOL SITE_FPM_SOCKET SITE_DOMAIN SITE_CREATED
        eval "$(php_load_site_state "$state_file")"
        old_ver="${SITE_PHP_VERSION:-}"
        [[ -z "$site_domain" ]] && site_domain="${SITE_DOMAIN:-}"
        [[ -z "$site_dir" ]] && site_dir="${SITE_DIR:-}"
    fi
    if [[ -n "$old_ver" && "$old_ver" != "$ver" ]]; then
        old_pool_file="$(php_get_pool_file "$site" "$old_ver")"
    fi

    if [[ -z "$site_domain" && -f "${OPS_CONFIG_DIR}/domains/${site}.conf" ]]; then
        site_domain="$site"
    fi
    if [[ -n "$site_domain" ]]; then
        dom_conf="${OPS_CONFIG_DIR}/domains/${site_domain}.conf"
        if [[ -f "$dom_conf" ]]; then
            domain_backend_type="$(php_conf_get_key "$dom_conf" "DOMAIN_BACKEND_TYPE")"
            domain_ssl_mode="$(php_conf_get_key "$dom_conf" "DOMAIN_SSL_MODE")"
            domain_web_root="$(php_conf_get_key "$dom_conf" "DOMAIN_WEB_ROOT")"
            [[ -z "$site_dir" ]] && site_dir="$domain_web_root"
        fi
    fi
    [[ -n "$domain_ssl_mode" ]] || domain_ssl_mode="none"
    if [[ -z "$site_dir" ]]; then
        if [[ -n "$site_domain" ]]; then
            site_dir="/var/www/${site_domain}"
        else
            site_dir="/var/www/${site}"
        fi
    fi

    # P-02: idempotency guard — existing pool config is updated in place so
    # custom per-pool directives survive, but OPS-managed keys will be refreshed.
    if [[ -f "$pool_file" ]]; then
        if [[ "${FORCE_OVERWRITE:-0}" != "1" ]]; then
            print_warn "PHP-FPM pool '${site}' (PHP ${ver}) already exists: $pool_file"
            print_warn "Re-running will refresh OPS-managed keys but keep custom per-pool directives such as env[...], php_admin_value, and php_admin_flag entries."
            if ! prompt_confirm "Refresh OPS-managed pool config for '${site}'?"; then
                print_warn "Aborted. Existing pool config for '${site}' was NOT changed."
                return 0
            fi
        fi
        log_info "P-02: Refreshing PHP-FPM pool for '${site}' (FORCE_OVERWRITE=${FORCE_OVERWRITE:-0})."
    fi

    snapshot_root=$(mktemp -d "/tmp/ops-php-pool.${site}.XXXXXX")
    snapshot_path_state "$pool_file" "$snapshot_root" "pool-current"
    snapshot_path_state "$state_file" "$snapshot_root" "site-state"
    if [[ -n "$old_pool_file" && "$old_pool_file" != "$pool_file" ]]; then
        snapshot_path_state "$old_pool_file" "$snapshot_root" "pool-previous"
    fi
    if [[ -n "$dom_conf" && -f "$dom_conf" ]]; then
        snapshot_path_state "$dom_conf" "$snapshot_root" "domain-state"
    fi

    if [[ ! -f "$pool_file" && -n "$old_pool_file" && "$old_pool_file" != "$pool_file" && -f "$old_pool_file" ]]; then
        ensure_dir "$(dirname "$pool_file")"
        cp -a "$old_pool_file" "$pool_file"
        log_info "configure_php_pool: seeded PHP ${ver} pool '${site}' from ${old_pool_file} to preserve custom overrides during version migration"
    fi

    backup_file "$pool_file" >/dev/null 2>&1 || true
    php_apply_pool_baseline "$pool_file" "$site" "$socket"

    if ! php_fpm_validate_and_apply "$ver"; then
        restore_path_snapshot "$pool_file" "$snapshot_root" "pool-current"
        restore_path_snapshot "$state_file" "$snapshot_root" "site-state"
        if [[ -n "$old_pool_file" && "$old_pool_file" != "$pool_file" ]]; then
            restore_path_snapshot "$old_pool_file" "$snapshot_root" "pool-previous"
        fi
        php_fpm_validate_and_apply "$ver" >/dev/null 2>&1 || true
        if [[ -n "$old_ver" && "$old_ver" != "$ver" ]]; then
            php_fpm_validate_and_apply "$old_ver" >/dev/null 2>&1 || true
        fi
        rm -rf "$snapshot_root"
        print_error "php${ver}-fpm validation/restart failed. Restored the previous pool config."
        return 1
    fi

    if [[ -n "$old_pool_file" && "$old_pool_file" != "$pool_file" && -f "$old_pool_file" ]]; then
        backup_file "$old_pool_file" >/dev/null 2>&1 || true
        rm -f "$old_pool_file"
        if ! php_fpm_validate_and_apply "$old_ver"; then
            restore_path_snapshot "$pool_file" "$snapshot_root" "pool-current"
            restore_path_snapshot "$state_file" "$snapshot_root" "site-state"
            restore_path_snapshot "$old_pool_file" "$snapshot_root" "pool-previous"
            php_fpm_validate_and_apply "$ver" >/dev/null 2>&1 || true
            php_fpm_validate_and_apply "$old_ver" >/dev/null 2>&1 || true
            rm -rf "$snapshot_root"
            print_error "Failed to retire the old PHP ${old_ver} pool for '${site}'. Restored the previous pool layout."
            return 1
        fi
    fi

    php_write_site_state "$site" "$ver" "$socket" "$site_domain" "$site_dir"

    if [[ "$skip_domain_sync" != "1" && -n "$dom_conf" && -f "$dom_conf" ]]; then
        if [[ "$domain_backend_type" != "php" ]]; then
            restore_path_snapshot "$pool_file" "$snapshot_root" "pool-current"
            restore_path_snapshot "$state_file" "$snapshot_root" "site-state"
            if [[ -n "$old_pool_file" && "$old_pool_file" != "$pool_file" ]]; then
                restore_path_snapshot "$old_pool_file" "$snapshot_root" "pool-previous"
            fi
            restore_path_snapshot "$dom_conf" "$snapshot_root" "domain-state"
            php_fpm_validate_and_apply "$ver" >/dev/null 2>&1 || true
            if [[ -n "$old_ver" && "$old_ver" != "$ver" ]]; then
                php_fpm_validate_and_apply "$old_ver" >/dev/null 2>&1 || true
            fi
            rm -rf "$snapshot_root"
            print_error "Domain state for ${site_domain} is not a PHP backend. Pool update was rolled back."
            return 1
        fi
        if ! declare -f _write_domain_state >/dev/null 2>&1 || ! declare -f _rebuild_domain_vhost >/dev/null 2>&1; then
            restore_path_snapshot "$pool_file" "$snapshot_root" "pool-current"
            restore_path_snapshot "$state_file" "$snapshot_root" "site-state"
            if [[ -n "$old_pool_file" && "$old_pool_file" != "$pool_file" ]]; then
                restore_path_snapshot "$old_pool_file" "$snapshot_root" "pool-previous"
            fi
            restore_path_snapshot "$dom_conf" "$snapshot_root" "domain-state"
            php_fpm_validate_and_apply "$ver" >/dev/null 2>&1 || true
            if [[ -n "$old_ver" && "$old_ver" != "$ver" ]]; then
                php_fpm_validate_and_apply "$old_ver" >/dev/null 2>&1 || true
            fi
            rm -rf "$snapshot_root"
            print_error "Nginx domain helpers are unavailable. Rolled back the PHP pool change for ${site_domain}."
            return 1
        fi

        _write_domain_state "$site_domain" "php" "$socket" "$ver" "$socket" "$site" "$domain_ssl_mode" "${domain_web_root:-$site_dir}"
        if ! _rebuild_domain_vhost "$site_domain"; then
            restore_path_snapshot "$pool_file" "$snapshot_root" "pool-current"
            restore_path_snapshot "$state_file" "$snapshot_root" "site-state"
            if [[ -n "$old_pool_file" && "$old_pool_file" != "$pool_file" ]]; then
                restore_path_snapshot "$old_pool_file" "$snapshot_root" "pool-previous"
            fi
            restore_path_snapshot "$dom_conf" "$snapshot_root" "domain-state"
            php_fpm_validate_and_apply "$ver" >/dev/null 2>&1 || true
            if [[ -n "$old_ver" && "$old_ver" != "$ver" ]]; then
                php_fpm_validate_and_apply "$old_ver" >/dev/null 2>&1 || true
            fi
            rm -rf "$snapshot_root"
            print_error "Failed to rebuild the Nginx PHP vhost for ${site_domain}. Rolled back the pool change."
            return 1
        fi
    fi

    rm -rf "$snapshot_root"
    print_ok "Configured PHP-FPM pool '${site}' for PHP ${ver}."
    log_info "configure_php_pool: pool '${site}' configured for PHP ${ver}"
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
    local ini_file key value snapshot_root

    php_require_root || return 1
    if ! php_is_supported_version "$ver"; then
        print_error "Unsupported PHP version: $ver. Allowed: ${PHP_SUPPORTED_VERSIONS[*]}"
        return 1
    fi

    snapshot_root=$(mktemp -d "/tmp/ops-php-ini.${ver}.XXXXXX")
    for ini_file in "/etc/php/${ver}/fpm/php.ini" "/etc/php/${ver}/cli/php.ini"; do
        [[ -f "$ini_file" ]] || continue
        backup_file "$ini_file" >/dev/null 2>&1 || true
        snapshot_path_state "$ini_file" "$snapshot_root" "$(basename "$(dirname "$ini_file")")-php-ini"

        while IFS='=' read -r key value; do
            [[ -z "$key" ]] && continue
            php_set_ini_key "$ini_file" "$key" "$value"
        done < <(php_ini_common_tuning_for_tier)

        if [[ "$ini_file" == *"/cli/php.ini" ]]; then
            while IFS='=' read -r key value; do
                [[ -z "$key" ]] && continue
                php_set_ini_key "$ini_file" "$key" "$value"
            done < <(php_ini_cli_tuning)
        fi

        if [[ "$ini_file" == *"/fpm/php.ini" ]]; then
            while IFS='=' read -r key value; do
                [[ -z "$key" ]] && continue
                php_set_ini_key "$ini_file" "$key" "$value"
            done < <(php_ini_fpm_security_tuning)
        fi
    done

    if ! php_fpm_validate_and_apply "$ver"; then
        restore_path_snapshot "/etc/php/${ver}/fpm/php.ini" "$snapshot_root" "fpm-php-ini"
        restore_path_snapshot "/etc/php/${ver}/cli/php.ini" "$snapshot_root" "cli-php-ini"
        php_fpm_validate_and_apply "$ver" >/dev/null 2>&1 || true
        rm -rf "$snapshot_root"
        print_error "php${ver}-fpm config test failed after tuning. Restored the previous php.ini files."
        return 1
    fi

    rm -rf "$snapshot_root"
    print_ok "Applied PHP tuning for version ${ver} (Tier: ${OPS_TIER:-S})."
    print_warn "SECURITY: PHP-FPM allow_url_fopen=Off is now enforced. Apps using file_get_contents() for remote URLs should use cURL or a per-pool override."
    print_warn "SECURITY: PHP-FPM disable_functions blocks exec/shell_exec/system. Add php_admin_value overrides per-pool if your app requires them."
    log_info "tune_php: PHP ${ver} tuned (tier=${OPS_TIER:-S})"
}

php_verify_version() {
    local ver="$1"
    local target_cli="/usr/bin/php${ver}"
    print_section "Verify PHP ${ver}"

    if command -v php >/dev/null 2>&1; then
        printf 'Default CLI: '
        php -v | head -n 1 || true
    fi
    if [[ -x "$target_cli" ]]; then
        printf 'Target CLI : '
        "$target_cli" -v | head -n 1 || true
    fi
    php_fpm_validate_config "$ver" || true
    service_status "php${ver}-fpm" || true
    echo ""
    echo "PHP domain contract checks:"
    php_verify_domain_contracts_for_version "$ver"
}

php_is_installed_version() {
    local ver="$1"
    [[ -x "/usr/bin/php${ver}" ]] && [[ -d "/etc/php/${ver}" ]]
}

menu_php() {
    _php_menu_run() {
        "$@"
        return 0
    }

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
        prompt_menu_choice "Select" "" choice
        case "$choice" in
            1) _php_menu_run php_list_versions; press_enter ;;
            2) _php_menu_run php_manage_version; press_enter ;;
            3) _php_menu_run php_configure_pool; press_enter ;;
            4) _php_menu_run php_set_default; press_enter ;;
            5) _php_menu_run php_fpm_status; press_enter ;;
            6) _php_menu_run php_reset_htaccess_menu; press_enter ;;
            0) return 0                         ;;
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
            local state_file domain_name pool_name cli_target
            local -a domain_blockers=() pool_blockers=()

            for state_file in "${OPS_CONFIG_DIR:-/etc/ops}/domains/"*.conf; do
                [[ -f "$state_file" ]] || continue
                [[ "$(php_conf_get_key "$state_file" "DOMAIN_PHP_VERSION")" == "$ver" ]] || continue
                domain_name="$(php_conf_get_key "$state_file" "DOMAIN")"
                domain_blockers+=("${domain_name:-$(basename "$state_file" .conf)}")
            done

            for state_file in "${PHP_SITES_DIR:-/etc/ops/php-sites}/"*.conf; do
                [[ -f "$state_file" ]] || continue
                [[ "$(php_conf_get_key "$state_file" "SITE_PHP_VERSION")" == "$ver" ]] || continue
                pool_name="$(php_conf_get_key "$state_file" "SITE_FPM_POOL")"
                pool_blockers+=("${pool_name:-$(basename "$state_file" .conf)}")
            done

            cli_target="$(readlink -f "$(command -v php 2>/dev/null)" 2>/dev/null || true)"
            if (( ${#domain_blockers[@]} > 0 || ${#pool_blockers[@]} > 0 )) || [[ "$cli_target" == "/usr/bin/php${ver}" ]]; then
                print_error "Cannot remove PHP ${ver} while it is still referenced by OPS state."
                if (( ${#domain_blockers[@]} > 0 )); then
                    echo "  Domains using PHP ${ver}:"
                    printf '    - %s\n' "${domain_blockers[@]}"
                fi
                if (( ${#pool_blockers[@]} > 0 )); then
                    echo "  Pools using PHP ${ver}:"
                    printf '    - %s\n' "${pool_blockers[@]}"
                fi
                if [[ "$cli_target" == "/usr/bin/php${ver}" ]]; then
                    echo "  Default CLI currently points to /usr/bin/php${ver}"
                fi
                print_warn "Migrate the domains/pools to another PHP version and switch the CLI default before retrying removal."
                return 1
            fi

            apt_remove "php${ver}-cli" "php${ver}-fpm" "php${ver}-common" \
                "php${ver}-mysql" "php${ver}-curl" "php${ver}-gd" "php${ver}-intl" \
                "php${ver}-mbstring" "php${ver}-opcache" "php${ver}-xml" "php${ver}-zip" \
                "php${ver}-soap" "php${ver}-bcmath" || return 1
            print_ok "Removed PHP ${ver} packages."
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
