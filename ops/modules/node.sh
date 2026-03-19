#!/usr/bin/env bash
# ============================================================
# ops/modules/node.sh
# Purpose:  Node.js LTS install, PM2 setup, Node service management
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# Called by bin/ops via menu dispatch.
# Do NOT add set -euo pipefail here — inherited from bin/ops.
#
# State contract (per PHASE-01-IMPLEMENTATION-SPEC.md §P1-06):
#   /etc/ops/apps/<appname>.conf  — per-app record
#
# Schema: APP_NAME APP_DIR APP_PORT APP_ENTRY APP_PM2_NAME
#         APP_NODE_ENV APP_DOMAIN APP_CREATED

# ── Public menu entry ─────────────────────────────────────────
menu_node() {
    while true; do
        print_section "Node.js Services"
        echo "  1) Install Node.js LTS"
        echo "  2) Install / update PM2"
        echo "  3) List Node.js apps (PM2)"
        echo "  4) Add Node.js app"
        echo "  5) Remove Node.js app"
        echo "  6) Restart app"
        echo "  7) Show app logs"
        echo "  0) Back"
        echo ""
        read -r -p "Select: " choice
        case "$choice" in
            1) node_install         ;;
            2) node_install_pm2     ;;
            3) node_list_apps       ;;
            4) node_add_app         ;;
            5) node_remove_app      ;;
            6) node_restart_app     ;;
            7) node_show_logs       ;;
            0) return               ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}

# ── Internal helpers ──────────────────────────────────────────

# _node_apps_dir: returns /etc/ops/apps
_node_apps_dir() { echo "${OPS_CONFIG_DIR:-/etc/ops}/apps"; }

_node_runtime_user() {
    local runtime_user
    runtime_user="$(ops_conf_get "ops.conf" "OPS_RUNTIME_USER" 2>/dev/null || true)"
    if [[ -z "$runtime_user" ]]; then
        runtime_user="$(ops_conf_get "ops.conf" "OPS_ADMIN_USER" 2>/dev/null || true)"
    fi
    if [[ -z "$runtime_user" ]]; then
        runtime_user="${ADMIN_USER:-${SUDO_USER:-$(whoami)}}"
    fi
    echo "$runtime_user"
}

_node_runtime_home() {
    local runtime_user="$(_node_runtime_user)"
    getent passwd "$runtime_user" | cut -d: -f6
}

_node_require_runtime_user() {
    local runtime_user="$(_node_runtime_user)"
    if ! id "$runtime_user" >/dev/null 2>&1; then
        print_error "OPS runtime user does not exist: ${runtime_user}"
        return 1
    fi
}

_node_run_as_runtime_user() {
    local runtime_user home_dir
    runtime_user="$(_node_runtime_user)"
    home_dir="$(_node_runtime_home)"
    runuser -u "$runtime_user" -- env HOME="$home_dir" PM2_HOME="$home_dir/.pm2" PATH="$PATH" "$@"
}

_node_reconcile_app_ownership() {
    local app_dir="$1"
    local runtime_user="$(_node_runtime_user)"
    if [[ -d "$app_dir" ]]; then
        chown -R "${runtime_user}:${runtime_user}" "$app_dir"
    fi
}

# _node_list_conf_names: lists registered app names (from /etc/ops/apps/*.conf)
_node_list_conf_names() {
    local apps_dir
    apps_dir=$(_node_apps_dir)
    if [[ ! -d "$apps_dir" ]]; then
        return 0
    fi
    local f
    for f in "$apps_dir"/*.conf; do
        [[ -f "$f" ]] || continue
        basename "$f" .conf
    done
}

# _node_write_app_conf <appname> key=value ...
_node_write_app_conf() {
    local appname="$1"
    shift
    local apps_dir
    apps_dir=$(_node_apps_dir)
    ensure_dir "$apps_dir"
    local conf="$apps_dir/${appname}.conf"
    # Write fresh conf (clobber if re-added — caller handles backup)
    {
        echo "APP_NAME=\"${appname}\""
        for kv in "$@"; do
            echo "${kv%%=*}=\"${kv#*=}\""
        done
        echo "APP_RUNTIME_USER=\"$(_node_runtime_user)\""
    } > "$conf"
    chmod 640 "$conf"
    log_info "Wrote app conf: $conf"
}

# _node_load_app_conf <appname>  — sources app conf into current shell
_node_load_app_conf() {
    local appname="$1"
    local conf
    conf="$(_node_apps_dir)/${appname}.conf"
    if [[ ! -f "$conf" ]]; then
        print_error "App not found in registry: $appname"
        return 1
    fi
    # shellcheck source=/dev/null
    source "$conf"
}

# _node_pick_app [prompt_label]  — interactive picker; sets REPLY to app name
_node_pick_app() {
    local label="${1:-App name}"
    local names
    mapfile -t names < <(_node_list_conf_names)
    if [[ ${#names[@]} -eq 0 ]]; then
        print_warn "No registered Node.js apps found."
        return 1
    fi
    echo ""
    echo "  Registered apps:"
    local i=1
    for n in "${names[@]}"; do
        echo "    ${i}) ${n}"
        (( i++ ))
    done
    echo ""
    prompt_input "$label (name or #)"
    # If numeric, resolve to name
    if [[ "$REPLY" =~ ^[0-9]+$ ]]; then
        local idx=$(( REPLY - 1 ))
        if [[ -n "${names[$idx]+_}" ]]; then
            REPLY="${names[$idx]}"
        else
            print_error "Invalid selection: $REPLY"
            return 1
        fi
    fi
}

# ── Actions ───────────────────────────────────────────────────

# P1-06 task 1: Install Node.js LTS via nodesource apt (chốt)
node_install() {
    print_section "Install Node.js LTS"

    if command -v node >/dev/null 2>&1; then
        print_ok "Node.js already installed: $(node --version)"
        if ! prompt_confirm "Re-install / upgrade?"; then
            return 0
        fi
    fi

    log_info "Fetching nodesource setup script (LTS)…"
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
    apt_install nodejs

    if command -v node >/dev/null 2>&1; then
        print_ok "Node.js installed: $(node --version)"
        print_ok "npm:              $(npm --version)"
        log_info "node_install: success $(node --version)"
    else
        print_error "node binary not found after install."
        log_error "node_install: node not found post-install"
        return 1
    fi
}

# P1-06 task 2+3: Install PM2 global + configure startup
node_install_pm2() {
    print_section "Install / Update PM2"

    if ! command -v node >/dev/null 2>&1; then
        print_error "Node.js is not installed. Run option 1 first."
        return 1
    fi

    _node_require_runtime_user || return 1

    log_info "Installing pm2 globally…"
    npm install -g pm2

    if ! command -v pm2 >/dev/null 2>&1; then
        print_error "pm2 binary not found after npm install."
        return 1
    fi
    print_ok "PM2 installed: $(pm2 --version)"

    local runtime_user home_dir startup_cmd
    runtime_user="$(_node_runtime_user)"
    home_dir="$(_node_runtime_home)"

    log_info "Configuring PM2 systemd startup for runtime user: $runtime_user"
    startup_cmd=$(pm2 startup systemd -u "$runtime_user" --hp "$home_dir" | grep 'sudo env' | head -n1 || true)
    if [[ -n "$startup_cmd" ]]; then
        eval "$startup_cmd"
        log_info "PM2 startup command executed: $startup_cmd"
    else
        log_warn "Could not extract PM2 startup command — may already be configured."
    fi

    _node_run_as_runtime_user pm2 ping >/dev/null 2>&1 || true
    _node_run_as_runtime_user pm2 save || true
    ops_conf_set "ops.conf" "OPS_RUNTIME_USER" "$runtime_user"
    print_ok "PM2 startup configured for runtime user: $runtime_user"
    log_info "node_install_pm2: done user=$runtime_user"
}

# P1-06 task 4 (list): Show PM2 process list + registered conf
node_list_apps() {
    print_section "Node.js Apps"

    echo ""
    echo "  ── PM2 process list ──────────────────────────────"
    if command -v pm2 >/dev/null 2>&1; then
        pm2 list --no-interaction 2>/dev/null || print_warn "PM2 not running or no processes."
    else
        print_warn "PM2 not installed."
    fi

    echo ""
    echo "  ── Registered apps (/etc/ops/apps/) ──────────────"
    local names
    mapfile -t names < <(_node_list_conf_names)
    if [[ ${#names[@]} -eq 0 ]]; then
        print_warn "No apps registered yet."
    else
        for n in "${names[@]}"; do
            local conf
            conf="$(_node_apps_dir)/${n}.conf"
            local port dir
            port=$(grep '^APP_PORT=' "$conf" 2>/dev/null | cut -d= -f2- | tr -d '"' || echo "?")
            dir=$(grep '^APP_DIR='  "$conf" 2>/dev/null | cut -d= -f2- | tr -d '"' || echo "?")
            echo "    • ${n}  port=${port}  dir=${dir}"
        done
    fi
    echo ""
}

# P1-06 task 4 (create): Add/register a new Node.js app
node_add_app() {
    print_section "Add Node.js App"

    if ! command -v pm2 >/dev/null 2>&1; then
        print_error "PM2 not installed. Run option 2 first."
        return 1
    fi
    _node_require_runtime_user || return 1

    # Gather inputs
    prompt_input "App name (slug, no spaces)"
    local app_name="$REPLY"
    if [[ -z "$app_name" || "$app_name" =~ [[:space:]] ]]; then
        print_error "Invalid app name."
        return 1
    fi

    local conf_path
    conf_path="$(_node_apps_dir)/${app_name}.conf"
    if [[ -f "$conf_path" ]]; then
        print_warn "App '$app_name' already registered."
        if ! prompt_confirm "Overwrite / re-register?"; then
            return 0
        fi
        backup_file "$conf_path"
    fi

    prompt_input "App directory (absolute path, e.g. /srv/apps/myapp)"
    local app_dir="$REPLY"
    if [[ ! -d "$app_dir" ]]; then
        print_warn "Directory does not exist: $app_dir"
        if ! prompt_confirm "Create it now?"; then
            return 1
        fi
        ensure_dir "$app_dir"
    fi
    _node_reconcile_app_ownership "$app_dir"

    prompt_input "Entry point (relative to app dir, e.g. dist/index.js)" "index.js"
    local app_entry="$REPLY"

    local app_port=""
    while true; do
        prompt_input "Port (localhost only, e.g. 3000)"
        app_port="$REPLY"
        if [[ "$app_port" =~ ^[0-9]+$ ]]; then
            break
        fi
        print_error "Port must be numeric. Please try again."
    done

    prompt_input "PM2 process name" "$app_name"
    local pm2_name="$REPLY"

    local app_env="production"
    prompt_input "NODE_ENV" "$app_env"
    app_env="$REPLY"

    # Write /etc/ops/apps/<app>.conf
    _node_write_app_conf "$app_name" \
        "APP_DIR=${app_dir}" \
        "APP_PORT=${app_port}" \
        "APP_ENTRY=${app_entry}" \
        "APP_PM2_NAME=${pm2_name}" \
        "APP_NODE_ENV=${app_env}" \
        "APP_DOMAIN=" \
        "APP_CREATED=$(date '+%Y-%m-%d %H:%M:%S')"

    # Render ecosystem.config.js from template if available
    local tpl="${OPS_ROOT:-/opt/ops}/modules/templates/pm2/ecosystem.config.js.tpl"
    local eco_dest="${app_dir}/ecosystem.config.js"
    if [[ -f "$tpl" ]]; then
        local app_path="${app_dir%/}/${app_entry}"
        render_template "$tpl" \
            "APP_NAME=${pm2_name}" \
            "APP_PATH=${app_path}" \
            "APP_PORT=${app_port}" \
            "INSTANCES=1" \
            "EXEC_MODE=fork" \
            "NODE_ENV=${app_env}" \
            > "$eco_dest"
        print_ok "Rendered: $eco_dest"
    else
        # Inline fallback ecosystem.config.js
        cat > "$eco_dest" <<EOF
module.exports = {
  apps: [{
    name:    '${pm2_name}',
    script:  '${app_entry}',
    cwd:     '${app_dir}',
    env: {
      NODE_ENV: '${app_env}',
      PORT:     '${app_port}',
    },
    listen_timeout: 8000,
    kill_timeout:   3000,
  }]
};
EOF
        print_ok "Created minimal ecosystem.config.js (template not found)"
    fi

    _node_reconcile_app_ownership "$app_dir"

    # Start with PM2
    log_info "Starting app with PM2 as runtime user: $(_node_runtime_user) -> pm2 start $eco_dest"
    _node_run_as_runtime_user pm2 start "$eco_dest"
    _node_run_as_runtime_user pm2 save

    print_ok "App '${app_name}' registered and started on 127.0.0.1:${app_port} using runtime user $(_node_runtime_user)"
    print_warn "To expose via Nginx, use the Domains & Nginx menu."
    log_info "node_add_app: registered $app_name port=$app_port dir=$app_dir"
}

# P1-06: Remove an app
node_remove_app() {
    print_section "Remove Node.js App"

    if ! _node_pick_app "App to remove"; then
        return 1
    fi
    local app_name="$REPLY"

    if ! prompt_confirm "Remove app '${app_name}' from PM2 and registry?"; then
        return 0
    fi

    # Load conf to get PM2 name
    # shellcheck source=/dev/null
    if _node_load_app_conf "$app_name"; then
        local pm2_name="${APP_PM2_NAME:-$app_name}"
        if command -v pm2 >/dev/null 2>&1; then
            _node_run_as_runtime_user pm2 delete "$pm2_name" 2>/dev/null || true
            _node_run_as_runtime_user pm2 save
            print_ok "PM2 process '${pm2_name}' removed."
        fi
    fi

    local conf_path
    conf_path="$(_node_apps_dir)/${app_name}.conf"
    backup_file "$conf_path"
    rm -f "$conf_path"
    print_ok "App '${app_name}' removed from registry."
    log_info "node_remove_app: removed $app_name"
}

# P1-06: Restart a PM2 app
node_restart_app() {
    print_section "Restart Node.js App"

    if ! _node_pick_app "App to restart"; then
        return 1
    fi
    local app_name="$REPLY"

    # shellcheck source=/dev/null
    _node_load_app_conf "$app_name" || return 1
    local pm2_name="${APP_PM2_NAME:-$app_name}"

    _node_run_as_runtime_user pm2 restart "$pm2_name"
    print_ok "Restarted: ${pm2_name}"
    log_info "node_restart_app: $pm2_name restarted"
}

# P1-06: Show logs for a PM2 app
node_show_logs() {
    print_section "App Logs"

    if ! _node_pick_app "App to view logs"; then
        return 1
    fi
    local app_name="$REPLY"

    # shellcheck source=/dev/null
    _node_load_app_conf "$app_name" || return 1
    local pm2_name="${APP_PM2_NAME:-$app_name}"

    prompt_input "Lines to display" "100"
    local lines="$REPLY"
    [[ "$lines" =~ ^[0-9]+$ ]] || lines=100

    _node_run_as_runtime_user pm2 logs "$pm2_name" --lines "$lines" --nostream
    log_info "node_show_logs: $pm2_name $lines lines"
}
