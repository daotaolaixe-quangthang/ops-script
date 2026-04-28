#!/usr/bin/env bash
# ============================================================
# ops/modules/ai-agent.sh
# Purpose:  AI Agent Integration — Claude Code CLI & Codex CLI
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# Called by bin/ops via menu dispatch.
# Do NOT add set -euo pipefail here — inherited from bin/ops.

CLAUDE_STATE_FILE="${OPS_CONFIG_DIR}/claude-code.conf"
CLAUDE_MARKER="# OPS: claude-code config"

# ── Helpers ──────────────────────────────────────────────────

_claude_admin_home() {
    local admin_home
    admin_home=$(getent passwd "$ADMIN_USER" | cut -d: -f6 || true)
    echo "${admin_home:-/home/$ADMIN_USER}"
}

_claude_bashrc() {
    echo "$(_claude_admin_home)/.bashrc"
}

_claude_set_state() {
    local key="$1"
    local value="$2"
    ops_conf_set claude-code.conf "$key" "$value"
    if [[ -f "$CLAUDE_STATE_FILE" ]]; then
        chmod 640 "$CLAUDE_STATE_FILE"
        chown "$ADMIN_USER:$ADMIN_USER" "$CLAUDE_STATE_FILE"
    fi
}

# ── Install ───────────────────────────────────────────────────

install_claude_cli() {
    log_info "Installing Claude Code CLI..."
    npm install -g @anthropic-ai/claude-code

    local version
    version=$(claude --version 2>/dev/null || echo "unknown")

    log_info "Claude Code CLI installed: $version"
    _claude_set_state "CLAUDE_INSTALLED"    "yes"
    _claude_set_state "CLAUDE_VERSION"      "$version"
    _claude_set_state "CLAUDE_INSTALL_DATE" "$(date +%Y-%m-%d)"
}

# ── Vietnamese Fix ────────────────────────────────────────────

install_claude_vietnamese_fix() {
    print_section "Install Vietnamese Fix for Claude Code CLI"
    echo ""

    local repo_url="https://github.com/daotaolaixe-quangthang/claude-code-vietnamese-fix"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    log_info "Cloning Vietnamese fix repo..."
    if ! git clone --depth=1 "$repo_url" "$tmp_dir" 2>&1; then
        log_error "Failed to clone repo: $repo_url"
        rm -rf "$tmp_dir"
        return 1
    fi

    # Run installer if available
    if [[ -f "$tmp_dir/install.sh" ]]; then
        log_info "Running install.sh ..."
        bash "$tmp_dir/install.sh"
    elif [[ -f "$tmp_dir/setup.sh" ]]; then
        log_info "Running setup.sh ..."
        bash "$tmp_dir/setup.sh"
    else
        log_warn "No install.sh / setup.sh found — listing repo contents:"
        ls -la "$tmp_dir"
    fi

    rm -rf "$tmp_dir"
    log_info "Vietnamese fix installation complete."
    _claude_set_state "CLAUDE_VIETNAMESE_FIX" "yes"
    _claude_set_state "CLAUDE_VIETNAMESE_FIX_DATE" "$(date +%Y-%m-%d)"
    echo ""
}

# ── Configure ─────────────────────────────────────────────────

configure_claude_cli() {
    local bashrc
    bashrc="$(_claude_bashrc)"

    print_section "Configure Claude Code CLI for this server"
    echo ""
    echo "  1) Use CLIProxyAPI (local, recommended)"
    echo "  2) Use Anthropic API (direct)"
    echo ""
    printf "  Select mode [1]: " > /dev/tty
    local mode_choice
    read -r mode_choice < /dev/tty
    mode_choice="${mode_choice:-1}"

    local base_url api_key model

    if [[ "$mode_choice" == "1" ]]; then
        base_url="http://127.0.0.1:8317"

        # Warn if CLIProxyAPI service is not active
        if ! systemctl is-active --quiet cli-proxy-api 2>/dev/null; then
            print_warn "CLIProxyAPI service is not running. Install/start it from menu 5 before using Claude Code CLI."
            printf "  Continue anyway? [y/N]: " > /dev/tty
            local cont_ans
            read -r cont_ans < /dev/tty
            [[ "${cont_ans,,}" == "y" ]] || return 0
        fi

        if [[ -f "${OPS_CONFIG_DIR}/.cli-proxy-api-key" ]]; then
            api_key=$(tr -d '\r\n' < "${OPS_CONFIG_DIR}/.cli-proxy-api-key")
            log_info "Using CLIProxyAPI key from ${OPS_CONFIG_DIR}/.cli-proxy-api-key"
        else
            echo ""
            printf "  CLIProxyAPI key not found. Enter API Key: " > /dev/tty
            read -r -s api_key < /dev/tty
            echo ""
        fi

        if [[ -z "$api_key" ]]; then
            log_error "API Key cannot be empty"
            return 1
        fi

        printf "  Model name [claude-opus-4-5-20251101]: " > /dev/tty
        read -r model < /dev/tty
        model="${model:-claude-opus-4-5-20251101}"
    else
        printf "  Enter Base URL [https://api.anthropic.com]: " > /dev/tty
        read -r base_url < /dev/tty
        base_url="${base_url:-https://api.anthropic.com}"

        printf "  Enter API Key: " > /dev/tty
        read -r -s api_key < /dev/tty
        echo ""
        if [[ -z "$api_key" ]]; then
            log_error "API Key cannot be empty"
            return 1
        fi

        printf "  Model name [claude-opus-4-5-20251101]: " > /dev/tty
        read -r model < /dev/tty
        model="${model:-claude-opus-4-5-20251101}"
    fi

    echo ""
    log_info "Writing Claude config to $bashrc ..."

    # Ensure bashrc exists and is owned by admin
    touch "$bashrc"
    chown "$ADMIN_USER:$ADMIN_USER" "$bashrc"

    # Remove old block if exists (idempotent)
    if grep -q "$CLAUDE_MARKER" "$bashrc" 2>/dev/null; then
        backup_file "$bashrc" >/dev/null || true
        sed -i "/^${CLAUDE_MARKER}$/,/^$/d" "$bashrc"
    else
        backup_file "$bashrc" >/dev/null || true
    fi

    # Append new config block
    cat >> "$bashrc" <<EOF

${CLAUDE_MARKER}
export ANTHROPIC_BASE_URL=${base_url}
export ANTHROPIC_API_KEY=${api_key}
export ANTHROPIC_AUTH_TOKEN="\${ANTHROPIC_API_KEY}"
export ANTHROPIC_MODEL="${model}"
EOF

    chown "$ADMIN_USER:$ADMIN_USER" "$bashrc"

    # If CLIProxyAPI module is loaded and local mode is selected, ensure api-keys is enabled in config.yaml too.
    if [[ "$mode_choice" == "1" ]] && declare -F _cliproxyapi_activate_api_key >/dev/null; then
        _cliproxyapi_activate_api_key
    fi

    _claude_set_state "CLAUDE_BASE_URL" "$base_url"
    _claude_set_state "CLAUDE_MODEL"    "$model"

    log_info "Claude Code CLI configured (model: ${model}, endpoint: ${base_url})"
    echo ""
    print_warn "Reload shell to apply: source ~/.bashrc"
}

# ── Test ──────────────────────────────────────────────────────

test_claude_cli() {
    print_section "Claude Code CLI Test"

    # Version
    local version
    version=$(claude --version 2>/dev/null || echo "NOT FOUND")
    echo "  Version       : $version"

    # Env vars (sourced from admin's bashrc for display)
    local bashrc
    bashrc="$(_claude_bashrc)"
    local base_url api_key_masked model

    # shellcheck disable=SC1090
    if [[ -f "$bashrc" ]]; then
        base_url=$(  grep "^export ANTHROPIC_BASE_URL="  "$bashrc" | tail -1 | cut -d= -f2- || echo "NOT SET")
        model=$(     grep "^export ANTHROPIC_MODEL="     "$bashrc" | tail -1 | cut -d= -f2- | tr -d '"' || echo "NOT SET")
        local raw_key
        raw_key=$(   grep "^export ANTHROPIC_API_KEY="  "$bashrc" | tail -1 | cut -d= -f2- || echo "")
        if [[ -n "$raw_key" ]]; then
            api_key_masked="${raw_key:0:8}****"
        else
            api_key_masked="NOT SET"
        fi
    else
        base_url="NOT SET"
        model="NOT SET"
        api_key_masked="NOT SET"
    fi

    echo "  Base URL      : $base_url"
    echo "  Model         : $model"
    echo "  API Key       : $api_key_masked"

    # Connectivity check
    local clean_url="${base_url%/}"
    if [[ "$clean_url" != "NOT SET" ]]; then
        local http_code
        http_code=$(curl -s -o /dev/null -w '%{http_code}' \
            --max-time 5 "${clean_url}/models" 2>/dev/null || echo "ERR")
        echo "  Endpoint HTTP : $http_code"
    fi

    echo ""
}

# ── Telegram Bot ─────────────────────────────────────────────

CLAUDE_TG_SERVICE="claude-telegram-bot"

_tg_dir() { echo "$(_claude_admin_home)/claude-telegram"; }
_tg_env() { echo "$(_tg_dir)/.env"; }

install_claude_telegram_bot() {
    print_section "Install Claude Code Telegram Bot"
    echo ""

    local repo_url="https://github.com/daotaolaixe-quangthang/claude-code-telegram"
    local tg_dir tg_env
    tg_dir="$(_tg_dir)"
    tg_env="$(_tg_env)"

    log_info "Installing Python dependencies (pip3)..."
    pip3 install --quiet git+"${repo_url}" 2>&1 || {
        log_error "pip3 install failed. Trying with uv..."
        if command -v uv &>/dev/null; then
            uv tool install git+"${repo_url}"
        else
            log_error "Neither pip3 nor uv succeeded. Aborting."
            return 1
        fi
    }

    log_info "Cloning repo to ${tg_dir} for config templates..."
    if [[ -d "${tg_dir}" ]]; then
        git -C "${tg_dir}" pull --quiet 2>&1
    else
        git clone --depth=1 "${repo_url}" "${tg_dir}" 2>&1
    fi
    chown -R "${ADMIN_USER}:${ADMIN_USER}" "${tg_dir}"

    # Copy .env.example if .env not yet present
    if [[ ! -f "${tg_env}" ]] && [[ -f "${tg_dir}/.env.example" ]]; then
        cp "${tg_dir}/.env.example" "${tg_env}"
        chmod 600 "${tg_env}"
        chown "${ADMIN_USER}:${ADMIN_USER}" "${tg_env}"
        log_info "Created ${tg_env} from example — please configure it."
    fi

    _claude_set_state "CLAUDE_TG_INSTALLED"    "yes"
    _claude_set_state "CLAUDE_TG_INSTALL_DATE" "$(date +%Y-%m-%d)"
    log_info "Claude Code Telegram Bot installed → ${tg_dir}"
    echo ""
}

configure_claude_telegram_bot() {
    local tg_dir tg_env bashrc
    tg_dir="$(_tg_dir)"
    tg_env="$(_tg_env)"
    bashrc="$(_claude_bashrc)"

    print_section "Configure Claude Code Telegram Bot"
    echo ""
    echo "  ── Hướng dẫn ──────────────────────────────────────────────"
    echo "  Bot Token  : Nhắn tin @BotFather trên Telegram → /newbot"
    echo "  User ID    : Nhắn tin @userinfobot trên Telegram để lấy ID"
    echo "  API Key    : Tự động copy từ cấu hình Claude Code CLI"
    echo "  ─────────────────────────────────────────────────────────────"
    echo ""

    # Ensure install dir exists
    if [[ ! -d "${tg_dir}" ]]; then
        log_error "Telegram bot not installed. Run install first."
        return 1
    fi

    # ── User inputs ───────────────────────────────────────────

    # Bot Token
    local bot_token
    read -r -s -p "  Telegram Bot Token (from @BotFather): " bot_token
    echo ""
    if [[ -z "$bot_token" ]]; then
        log_error "Bot token cannot be empty"
        return 1
    fi

    # Bot Username
    local bot_username
    printf "  Telegram Bot Username (without @): " > /dev/tty
    read -r bot_username < /dev/tty
    bot_username="${bot_username:-my_claude_bot}"

    # Allowed Users
    local allowed_users
    printf "  Allowed Telegram User IDs (comma-separated, from @userinfobot): " > /dev/tty
    read -r allowed_users < /dev/tty
    if [[ -z "$allowed_users" ]]; then
        log_error "At least one allowed user ID is required."
        return 1
    fi

    # Approved directory (default: admin home)
    local admin_home
    admin_home="$(_claude_admin_home)"
    local approved_dir
    printf "  Approved directory [${admin_home}]: " > /dev/tty
    read -r approved_dir < /dev/tty
    approved_dir="${approved_dir:-${admin_home}}"

    # ── Auto-copy ANTHROPIC_* from Claude Code CLI bashrc ─────
    local api_key base_url model
    if [[ -f "$bashrc" ]]; then
        api_key=$(grep  "^export ANTHROPIC_API_KEY="  "$bashrc" | tail -1 | cut -d= -f2-)
        base_url=$(grep "^export ANTHROPIC_BASE_URL=" "$bashrc" | tail -1 | cut -d= -f2-)
        model=$(grep    "^export ANTHROPIC_MODEL="    "$bashrc" | tail -1 | cut -d= -f2- | tr -d '"')
    fi

    echo ""
    log_info "Writing ${tg_env} ..."
    if [[ -n "$api_key" ]];  then log_info "  ANTHROPIC_API_KEY  : ${api_key:0:8}****"; fi
    if [[ -n "$base_url" ]]; then log_info "  ANTHROPIC_BASE_URL : ${base_url}"; fi
    if [[ -n "$model" ]];    then log_info "  ANTHROPIC_MODEL    : ${model}"; fi

    mkdir -p "${tg_dir}"

    # Build .env
    cat > "${tg_env}" <<EOF
TELEGRAM_BOT_TOKEN=${bot_token}
TELEGRAM_BOT_USERNAME=${bot_username}
APPROVED_DIRECTORY=${approved_dir}
ALLOWED_USERS=${allowed_users}
AGENTIC_MODE=true
VERBOSE_LEVEL=1
EOF

    # Append ANTHROPIC_* only if available from Claude Code CLI
    if [[ -n "$api_key" ]];  then echo "ANTHROPIC_API_KEY=${api_key}"   >> "${tg_env}"; fi
    if [[ -n "$base_url" ]]; then echo "ANTHROPIC_BASE_URL=${base_url}" >> "${tg_env}"; fi
    if [[ -n "$model" ]];    then echo "ANTHROPIC_MODEL=${model}"       >> "${tg_env}"; fi

    chmod 600 "${tg_env}"
    chown "${ADMIN_USER}:${ADMIN_USER}" "${tg_env}"

    _claude_set_state "CLAUDE_TG_BOT_USERNAME"  "$bot_username"
    _claude_set_state "CLAUDE_TG_ALLOWED_USERS" "$allowed_users"
    _claude_set_state "CLAUDE_TG_APPROVED_DIR"  "$approved_dir"
    log_info "Telegram bot configured → ${tg_env}"
    echo ""
    print_warn "Run 'Start Telegram bot' from the menu to launch."
    echo ""
}

start_claude_telegram_bot() {
    print_section "Start Claude Code Telegram Bot"
    echo ""

    local tg_dir tg_env
    tg_dir="$(_tg_dir)"
    tg_env="$(_tg_env)"

    if [[ ! -f "${tg_env}" ]]; then
        log_error ".env not found. Run Configure first."
        return 1
    fi

    # Use systemd service if available, else nohup
    if systemctl list-unit-files "${CLAUDE_TG_SERVICE}.service" &>/dev/null; then
        systemctl start "${CLAUDE_TG_SERVICE}" && log_info "Service ${CLAUDE_TG_SERVICE} started." || log_error "systemctl start failed."
        return
    fi

    # Fallback: run via nohup as admin user
    local log_file
    log_file="$(_claude_admin_home)/claude-telegram-bot.log"
    local pid_file="/var/run/claude-telegram-bot.pid"

    if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        log_warn "Bot is already running (PID $(cat "$pid_file"))"
        return
    fi

    log_info "Starting bot in background..."
    sudo -u "${ADMIN_USER}" bash -c \
        "cd '${tg_dir}' && nohup python3 -m claude_code_telegram >> '${log_file}' 2>&1 & echo \$! > '${pid_file}'"
    sleep 1
    if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        log_info "Bot started (PID $(cat "$pid_file")). Log: ${log_file}"
    else
        log_error "Bot failed to start. Check ${log_file}"
    fi
    echo ""
}

stop_claude_telegram_bot() {
    print_section "Stop Claude Code Telegram Bot"
    echo ""

    if systemctl list-unit-files "${CLAUDE_TG_SERVICE}.service" &>/dev/null; then
        systemctl stop "${CLAUDE_TG_SERVICE}" && log_info "Service stopped." || log_error "systemctl stop failed."
        return
    fi

    local pid_file="/var/run/claude-telegram-bot.pid"
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" && log_info "Bot stopped (PID ${pid})" || log_error "Failed to kill PID ${pid}"
        else
            log_warn "PID ${pid} not running."
        fi
        rm -f "$pid_file"
    else
        log_warn "No PID file found. Bot may not be running."
    fi
    echo ""
}

status_claude_telegram_bot() {
    print_section "Claude Code Telegram Bot — Status"
    echo ""

    # systemd
    if systemctl list-unit-files "${CLAUDE_TG_SERVICE}.service" &>/dev/null; then
        systemctl status "${CLAUDE_TG_SERVICE}" --no-pager 2>&1 | head -20
        echo ""
        return
    fi

    local pid_file="/var/run/claude-telegram-bot.pid"
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            echo "  Status : RUNNING (PID ${pid})"
        else
            echo "  Status : STOPPED (stale PID file)"
        fi
    else
        echo "  Status : STOPPED"
    fi

    local log_file
    log_file="$(_claude_admin_home)/claude-telegram-bot.log"
    if [[ -f "$log_file" ]]; then
        echo ""
        echo "  --- Last 10 log lines ---"
        tail -10 "$log_file" | sed 's/^/  /'
    fi
    echo ""
}

menu_telegram_bot() {
    _telegram_bot_menu_run() {
        "$@"
        return 0
    }

    while true; do
        print_section "Claude Code Telegram Bot"
        echo "  1) Install Telegram Bot"
        echo "  2) Configure Telegram Bot"
        echo "  3) Start Telegram Bot"
        echo "  4) Stop Telegram Bot"
        echo "  5) Status / Logs"
        echo "  0) Back"
        echo ""
        printf "  Select: " > /dev/tty
        local choice
        read -r choice < /dev/tty
        case "$choice" in
            1) _telegram_bot_menu_run install_claude_telegram_bot ;;
            2) _telegram_bot_menu_run configure_claude_telegram_bot ;;
            3) _telegram_bot_menu_run start_claude_telegram_bot ;;
            4) _telegram_bot_menu_run stop_claude_telegram_bot ;;
            5) _telegram_bot_menu_run status_claude_telegram_bot ;;
            0) return 0 ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}

# ── Menus ─────────────────────────────────────────────────────

menu_claude_cli() {
    _claude_cli_menu_run() {
        "$@"
        return 0
    }

    while true; do
        print_section "Claude Code CLI Integration"
        echo "  1) Install Claude Code CLI"
        echo "  2) Configure environment Claude for this server"
        echo "  3) Test Claude Code CLI"
        echo "  4) Install Vietnamese fix for Claude Code CLI"
        echo "  5) Claude Code Telegram Bot"
        echo "  0) Back"
        echo ""
        printf "  Select: " > /dev/tty
        local choice
        read -r choice < /dev/tty
        case "$choice" in
            1) _claude_cli_menu_run install_claude_cli ;;
            2) _claude_cli_menu_run configure_claude_cli ;;
            3) _claude_cli_menu_run test_claude_cli ;;
            4) _claude_cli_menu_run install_claude_vietnamese_fix ;;
            5) _claude_cli_menu_run menu_telegram_bot ;;
            0) return 0 ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}

menu_ai_agent() {
    _ai_agent_menu_run() {
        "$@"
        return 0
    }

    while true; do
        print_section "AI Agent Integration"
        echo "  1) Codex CLI Integration"
        echo "  2) Claude Code CLI Integration"
        echo "  0) Back"
        echo ""
        printf "  Select: " > /dev/tty
        local choice
        read -r choice < /dev/tty
        case "$choice" in
            1) _ai_agent_menu_run menu_codex_cli ;;
            2) _ai_agent_menu_run menu_claude_cli ;;
            0) return 0 ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}
