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
CLAUDE_MARKER_END="# OPS: claude-code config end"

# ── Helpers ──────────────────────────────────────────────────

_claude_admin_home() {
    local admin_home
    admin_home=$(getent passwd "$ADMIN_USER" | cut -d: -f6 || true)
    echo "${admin_home:-/home/$ADMIN_USER}"
}

_claude_bashrc() {
    echo "$(_claude_admin_home)/.bashrc"
}

_claude_api_key_file() {
    echo "$(_claude_admin_home)/.claude-api-key"
}

_claude_env_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\$}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    printf '"%s"' "$value"
}

_claude_env_append_line() {
    local file="$1"
    local key="$2"
    local value="$3"
    printf '%s=%s\n' "$key" "$(_claude_env_quote "$value")" >> "$file"
}

_claude_strip_shell_block() {
    local file="$1"
    local start_marker="$2"
    local end_marker="$3"
    local tmp has_end=0

    [[ -f "$file" ]] || return 0

    if grep -qFx "$end_marker" "$file" 2>/dev/null; then
        has_end=1
    fi

    tmp=$(mktemp "${file}.tmp.XXXXXX")
    if ! awk -v start="$start_marker" -v end="$end_marker" -v has_end="$has_end" '
        $0 == start {
            skip=1
            next
        }
        skip && has_end == 1 && $0 == end {
            skip=0
            next
        }
        skip && has_end == 0 && $0 == "" {
            skip=0
            next
        }
        !skip { print }
        END {
            if (skip && has_end == 1) {
                exit 1
            }
        }
    ' "$file" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi

    chmod --reference="$file" "$tmp" 2>/dev/null || true
    chown --reference="$file" "$tmp" 2>/dev/null || true
    mv "$tmp" "$file"
}

_claude_update_shell_block() {
    local file="$1"
    local start_marker="$2"
    local end_marker="$3"
    local block_content="$4"
    local backup_path="${file}.bak.$(date +%Y%m%d_%H%M%S)"

    touch "$file"
    chown "$ADMIN_USER:$ADMIN_USER" "$file"

    if ! bash -n "$file" 2>/dev/null; then
        log_error "Refusing to update ${file}: invalid bash syntax"
        return 1
    fi

    cp -a -- "$file" "$backup_path"

    if grep -qFx "$start_marker" "$file" 2>/dev/null; then
        if ! _claude_strip_shell_block "$file" "$start_marker" "$end_marker"; then
            cp -a -- "$backup_path" "$file"
            log_error "Refusing to rewrite malformed OPS block in ${file}. Restored ${backup_path}."
            return 1
        fi
    fi

    if [[ -n "$block_content" ]]; then
        printf '\n%s\n' "$block_content" >> "$file"
    fi

    if ! bash -n "$file" 2>/dev/null; then
        cp -a -- "$backup_path" "$file"
        log_error "Managed block update caused syntax failure in ${file}. Restored ${backup_path}."
        return 1
    fi

    chown "$ADMIN_USER:$ADMIN_USER" "$file"
}

_claude_write_api_key_file() {
    local api_key="$1"
    local api_key_file
    api_key_file="$(_claude_api_key_file)"

    write_file "$api_key_file" <<EOF
${api_key}
EOF
    chmod 600 "$api_key_file"
    chown "$ADMIN_USER:$ADMIN_USER" "$api_key_file"
}

_claude_read_api_key() {
    local api_key_file
    api_key_file="$(_claude_api_key_file)"

    [[ -f "$api_key_file" ]] || return 1
    tr -d '\r\n' < "$api_key_file"
}

_claude_probe_url() {
    local clean_url="${1%/}"

    if [[ "$clean_url" == */v1 ]]; then
        echo "${clean_url}/models"
    else
        echo "${clean_url}/v1/models"
    fi
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
    print_warn "This action clones and executes third-party code from GitHub."
    print_warn "Review the repository before using it on a production host."
    if ! prompt_confirm "Continue installing the Vietnamese fix?"; then
        log_info "Vietnamese fix installation cancelled."
        return 0
    fi

    local repo_url="https://github.com/daotaolaixe-quangthang/claude-code-vietnamese-fix"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    log_info "Cloning Vietnamese fix repo..."
    if ! git clone --depth=1 "$repo_url" "$tmp_dir" 2>&1; then
        log_error "Failed to clone repo: $repo_url"
        rm -rf "$tmp_dir"
        return 1
    fi

    local install_status=0

    # Run installer if available
    if [[ -f "$tmp_dir/install.sh" ]]; then
        log_info "Running install.sh ..."
        if bash "$tmp_dir/install.sh"; then
            :
        else
            install_status=$?
            log_error "install.sh failed."
        fi
    elif [[ -f "$tmp_dir/setup.sh" ]]; then
        log_info "Running setup.sh ..."
        if bash "$tmp_dir/setup.sh"; then
            :
        else
            install_status=$?
            log_error "setup.sh failed."
        fi
    else
        log_warn "No install.sh / setup.sh found — listing repo contents:"
        ls -la "$tmp_dir"
    fi

    rm -rf "$tmp_dir"
    if (( install_status != 0 )); then
        return "$install_status"
    fi

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

    local base_url api_key model api_key_file

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

        # Auto-generate CLIProxyAPI client key if not yet created
        if declare -F _cliproxyapi_ensure_client_key >/dev/null; then
            _cliproxyapi_ensure_client_key > /dev/null
        fi

        if [[ -f "${OPS_CONFIG_DIR}/.cli-proxy-api-key" ]]; then
            api_key=$(tr -d '\r\n' < "${OPS_CONFIG_DIR}/.cli-proxy-api-key")
            log_info "Using CLIProxyAPI key from ${OPS_CONFIG_DIR}/.cli-proxy-api-key"
        else
            echo ""
            prompt_secret "  CLIProxyAPI key not found. Enter API Key" || return 1
            api_key="${SECRET:-}"
            unset SECRET
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

        prompt_secret "  Enter API Key" || return 1
        api_key="${SECRET:-}"
        unset SECRET
        if [[ -z "$api_key" ]]; then
            log_error "API Key cannot be empty"
            return 1
        fi

        printf "  Model name [claude-opus-4-5-20251101]: " > /dev/tty
        read -r model < /dev/tty
        model="${model:-claude-opus-4-5-20251101}"
    fi

    if [[ "$mode_choice" == "1" ]] && declare -F _cliproxyapi_activate_api_key >/dev/null; then
        _cliproxyapi_activate_api_key || return 1
    fi

    api_key_file="$(_claude_api_key_file)"
    _claude_write_api_key_file "$api_key"

    echo ""
    log_info "Writing Claude config to $bashrc ..."

    local quoted_base_url quoted_model quoted_api_key_file block_content
    printf -v quoted_base_url '%q' "$base_url"
    printf -v quoted_model '%q' "$model"
    printf -v quoted_api_key_file '%q' "$api_key_file"

    block_content="${CLAUDE_MARKER}
export ANTHROPIC_BASE_URL=${quoted_base_url}
export ANTHROPIC_MODEL=${quoted_model}
if [[ -f ${quoted_api_key_file} ]]; then
    export ANTHROPIC_API_KEY=\"\$(tr -d '\\r\\n' < ${quoted_api_key_file})\"
    export ANTHROPIC_AUTH_TOKEN=\"\${ANTHROPIC_API_KEY}\"
else
    unset ANTHROPIC_API_KEY
    unset ANTHROPIC_AUTH_TOKEN
fi
${CLAUDE_MARKER_END}"
    _claude_update_shell_block "$bashrc" "$CLAUDE_MARKER" "$CLAUDE_MARKER_END" "$block_content" || return 1

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

    local base_url api_key_status model
    local api_key_file probe_url

    ops_load_conf claude-code.conf
    base_url="${CLAUDE_BASE_URL:-NOT SET}"
    model="${CLAUDE_MODEL:-NOT SET}"
    api_key_file="$(_claude_api_key_file)"

    if [[ -s "$api_key_file" ]]; then
        api_key_status="SET"
    else
        api_key_status="NOT SET"
    fi

    echo "  Base URL      : $base_url"
    echo "  Model         : $model"
    echo "  API Key File  : $api_key_file"
    echo "  API Key       : $api_key_status"

    # Connectivity check
    if [[ "$base_url" != "NOT SET" ]]; then
        local http_code
        probe_url="$(_claude_probe_url "$base_url")"
        http_code=$(curl -s -o /dev/null -w '%{http_code}' \
            --max-time 5 "$probe_url" 2>/dev/null || echo "ERR")
        echo "  Probe URL     : $probe_url"
        echo "  Endpoint HTTP : $http_code"
    fi

    echo ""
}

# ── Telegram Bot ─────────────────────────────────────────────

CLAUDE_TG_SERVICE="claude-telegram-bot"

_tg_dir() { echo "$(_claude_admin_home)/claude-telegram"; }
_tg_env() { echo "$(_tg_dir)/.env"; }
_tg_running_pids() {
    local tg_dir tg_venv
    tg_dir="$(_tg_dir)"
    tg_venv="${tg_dir}/.venv"
    ps -u "${ADMIN_USER}" -o pid=,args= | awk -v pat="${tg_venv}/bin/claude-telegram-bot" 'index($0, pat) && index($0, "bash -c") == 0 {print $1}'
}

install_claude_telegram_bot() {
    print_section "Install Claude Code Telegram Bot"
    echo ""
    print_warn "This action clones and installs third-party code from GitHub via pip."
    print_warn "Review the repository before using it on a production host."
    if ! prompt_confirm "Continue installing the Telegram bot?"; then
        log_info "Telegram bot installation cancelled."
        return 0
    fi

    local repo_url="https://github.com/daotaolaixe-quangthang/claude-code-telegram"
    local tg_dir tg_env tg_venv python_bin
    tg_dir="$(_tg_dir)"
    tg_env="$(_tg_env)"
    tg_venv="${tg_dir}/.venv"

    log_info "Cloning repo to ${tg_dir} for config templates..."
    if [[ -d "${tg_dir}/.git" ]]; then
        git -C "${tg_dir}" pull --quiet 2>&1 || {
            log_error "Failed to update existing Telegram bot repo."
            return 1
        }
    elif [[ -d "${tg_dir}" ]]; then
        log_error "${tg_dir} exists but is not a git repo. Remove it or choose another admin home."
        return 1
    else
        git clone --depth=1 "${repo_url}" "${tg_dir}" 2>&1 || {
            log_error "Failed to clone Telegram bot repo."
            return 1
        }
    fi

    if command -v python3.11 &>/dev/null; then
        python_bin="$(command -v python3.11)"
    elif command -v python3 &>/dev/null && python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
        python_bin="$(command -v python3)"
    else
        log_info "Python 3.11+ not found. Installing required packages..."
        apt_update
        apt_install python3.11 python3.11-venv || {
            log_error "Failed to install Python 3.11 packages."
            return 1
        }
        python_bin="$(command -v python3.11 || true)"
        if [[ -z "${python_bin}" ]]; then
            log_error "Python 3.11 installation finished, but python3.11 was not found in PATH."
            return 1
        fi
    fi

    log_info "Creating virtual environment with ${python_bin}..."
    rm -rf "${tg_venv}"
    "${python_bin}" -m venv "${tg_venv}" || {
        log_error "Failed to create virtual environment at ${tg_venv}."
        return 1
    }

    log_info "Installing Telegram bot Python package..."
    "${tg_venv}/bin/pip" install --quiet --upgrade pip setuptools wheel || {
        log_error "Failed to bootstrap pip inside ${tg_venv}."
        return 1
    }
    "${tg_venv}/bin/pip" install --quiet "${tg_dir}" || {
        log_error "Failed to install Telegram bot package into ${tg_venv}."
        return 1
    }

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
    local tg_dir tg_env
    tg_dir="$(_tg_dir)"
    tg_env="$(_tg_env)"

    print_section "Configure Claude Code Telegram Bot"
    echo ""
    echo "  ── Hướng dẫn ──────────────────────────────────────────────"
    echo "  Bot Token  : Nhắn tin @BotFather trên Telegram → /newbot"
    echo "  User ID    : Nhắn tin @userinfobot trên Telegram để lấy ID"
    echo "  API Key    : Tự động copy từ cấu hình Claude Code CLI"
    echo "  Lưu ý      : Nên chọn thư mục hẹp hơn toàn bộ admin home cho production"
    echo "  ─────────────────────────────────────────────────────────────"
    echo ""

    # Ensure install dir exists
    if [[ ! -d "${tg_dir}" ]]; then
        log_error "Telegram bot not installed. Run install first."
        return 1
    fi

    # ── User inputs ───────────────────────────────────────────

    # Bot Token
    prompt_secret "  Telegram Bot Token (from @BotFather)" || return 1
    local bot_token="${SECRET:-}"
    unset SECRET
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

    # Approved directory (default: OPS root if available)
    local admin_home default_approved_dir approved_dir
    admin_home="$(_claude_admin_home)"
    default_approved_dir="${OPS_ROOT:-${admin_home}}"
    printf "  Approved directory [${default_approved_dir}]: " > /dev/tty
    read -r approved_dir < /dev/tty
    approved_dir="${approved_dir:-${default_approved_dir}}"

    # ── Auto-copy ANTHROPIC_* from canonical Claude config ─────
    local api_key="" base_url="" model=""
    ops_load_conf claude-code.conf
    base_url="${CLAUDE_BASE_URL:-}"
    model="${CLAUDE_MODEL:-}"
    if ! api_key="$(_claude_read_api_key 2>/dev/null)"; then
        api_key=""
    fi

    echo ""
    log_info "Writing ${tg_env} ..."
    if [[ -n "$base_url" ]]; then log_info "  ANTHROPIC_BASE_URL : ${base_url}"; fi
    if [[ -n "$model" ]];    then log_info "  ANTHROPIC_MODEL    : ${model}"; fi

    mkdir -p "${tg_dir}"
    chown "${ADMIN_USER}:${ADMIN_USER}" "${tg_dir}"

    # Build .env
    write_file "${tg_env}" <<EOF
EOF
    _claude_env_append_line "${tg_env}" "TELEGRAM_BOT_TOKEN" "$bot_token"
    _claude_env_append_line "${tg_env}" "TELEGRAM_BOT_USERNAME" "$bot_username"
    _claude_env_append_line "${tg_env}" "APPROVED_DIRECTORY" "$approved_dir"
    _claude_env_append_line "${tg_env}" "ALLOWED_USERS" "$allowed_users"
    _claude_env_append_line "${tg_env}" "AGENTIC_MODE" "true"
    _claude_env_append_line "${tg_env}" "VERBOSE_LEVEL" "1"

    # Append ANTHROPIC_* only if available from Claude Code CLI
    if [[ -n "$api_key" ]];  then _claude_env_append_line "${tg_env}" "ANTHROPIC_API_KEY" "$api_key"; fi
    if [[ -n "$base_url" ]]; then _claude_env_append_line "${tg_env}" "ANTHROPIC_BASE_URL" "$base_url"; fi
    if [[ -n "$model" ]];    then _claude_env_append_line "${tg_env}" "ANTHROPIC_MODEL" "$model"; fi

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

    local tg_dir tg_env tg_venv log_file pid_file running_pids launch_cmd
    local quoted_tg_dir quoted_tg_binary quoted_log_file quoted_pid_file quoted_api_key_file api_key_file
    tg_dir="$(_tg_dir)"
    tg_env="$(_tg_env)"
    tg_venv="${tg_dir}/.venv"
    log_file="$(_claude_admin_home)/claude-telegram-bot.log"
    pid_file="${tg_dir}/claude-telegram-bot.pid"
    api_key_file="$(_claude_api_key_file)"

    if [[ ! -f "${tg_env}" ]]; then
        log_error ".env not found. Run Configure first."
        return 1
    fi
    if [[ ! -x "${tg_venv}/bin/claude-telegram-bot" ]]; then
        log_error "Bot executable not found. Run Install first."
        return 1
    fi

    # Use systemd service if available, else nohup
    if systemctl list-unit-files "${CLAUDE_TG_SERVICE}.service" &>/dev/null; then
        systemctl start "${CLAUDE_TG_SERVICE}" && log_info "Service ${CLAUDE_TG_SERVICE} started." || log_error "systemctl start failed."
        return
    fi

    running_pids="$(_tg_running_pids)"
    if [[ -n "$running_pids" ]]; then
        log_warn "Bot is already running (PIDs $(tr '\n' ' ' <<< "$running_pids"))"
        return
    fi

    touch "${log_file}"
    chown "${ADMIN_USER}:${ADMIN_USER}" "${log_file}"
    chmod 600 "${log_file}"

    log_info "Starting bot in background..."
    printf -v quoted_tg_dir '%q' "$tg_dir"
    printf -v quoted_tg_binary '%q' "${tg_venv}/bin/claude-telegram-bot"
    printf -v quoted_log_file '%q' "$log_file"
    printf -v quoted_pid_file '%q' "$pid_file"
    printf -v quoted_api_key_file '%q' "$api_key_file"
    launch_cmd="umask 077 && cd ${quoted_tg_dir}"
    if [[ -f "$api_key_file" ]]; then
        launch_cmd+=" && export ANTHROPIC_API_KEY=\"\$(tr -d '\\r\\n' < ${quoted_api_key_file})\""
    fi
    launch_cmd+=" && nohup ${quoted_tg_binary} >> ${quoted_log_file} 2>&1 < /dev/null & echo \$! > ${quoted_pid_file}"
    ops_run_as_user "$ADMIN_USER" bash -c "$launch_cmd"
    sleep 1
    if [[ -f "${pid_file}" ]]; then
        chmod 600 "${pid_file}"
        chown "${ADMIN_USER}:${ADMIN_USER}" "${pid_file}"
    fi

    running_pids="$(_tg_running_pids)"
    if [[ -n "$running_pids" ]]; then
        log_info "Bot started (PIDs $(tr '\n' ' ' <<< "$running_pids")). Log: ${log_file}"
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

    local tg_dir pid_file running_pids pid
    tg_dir="$(_tg_dir)"
    pid_file="${tg_dir}/claude-telegram-bot.pid"
    running_pids="$(_tg_running_pids)"

    if [[ -n "$running_pids" ]]; then
        while IFS= read -r pid; do
            [[ -n "$pid" ]] || continue
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" && log_info "Bot stopped (PID ${pid})" || log_error "Failed to kill PID ${pid}"
            fi
        done <<< "$running_pids"
        rm -f "$pid_file"
    else
        log_warn "No running bot process found."
        rm -f "$pid_file"
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

    local tg_dir pid_file running_pids running_count tracked_pid
    tg_dir="$(_tg_dir)"
    pid_file="${tg_dir}/claude-telegram-bot.pid"
    running_pids="$(_tg_running_pids)"

    if [[ -n "$running_pids" ]]; then
        running_count=$(wc -l <<< "$running_pids")
        echo "  Status : RUNNING (PIDs $(tr '\n' ' ' <<< "$running_pids"))"
        if (( running_count > 1 )); then
            echo "  Warning: Multiple bot instances detected (${running_count})"
        fi
    elif [[ -f "$pid_file" ]]; then
        tracked_pid=$(cat "$pid_file")
        echo "  Status : STOPPED (stale PID file: ${tracked_pid})"
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
