#!/usr/bin/env bash
# ============================================================
# ops/modules/codex-cli.sh
# Purpose:  Codex CLI install, configuration, and verification
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# Called by bin/ops via menu dispatch.
# Do NOT add set -euo pipefail here — inherited from bin/ops.

CODEX_STATE_FILE="${OPS_CONFIG_DIR}/codex-cli.conf"
CODEX_API_KEY_FILE="${OPS_CONFIG_DIR}/.codex-api-key"

_codex_admin_home() {
    local admin_home
    admin_home=$(getent passwd "$ADMIN_USER" | cut -d: -f6 || true)
    echo "${admin_home:-/home/$ADMIN_USER}"
}

_codex_config_dir() {
    local admin_home
    admin_home="$(_codex_admin_home)"
    echo "${admin_home}/.codex"
}

_codex_config_file() {
    echo "$(_codex_config_dir)/config.toml"
}

_codex_set_state() {
    local key="$1"
    local value="$2"

    ops_conf_set codex-cli.conf "$key" "$value"

    if [[ -f "$CODEX_STATE_FILE" ]]; then
        chmod 640 "$CODEX_STATE_FILE"
        chown "$ADMIN_USER:$ADMIN_USER" "$CODEX_STATE_FILE"
    fi
}

_codex_write_api_key_file() {
    local api_key="$1"
    write_file "$CODEX_API_KEY_FILE" <<EOF
${api_key}
EOF
    chmod 600 "$CODEX_API_KEY_FILE"
    chown "$ADMIN_USER:$ADMIN_USER" "$CODEX_API_KEY_FILE"
}

_codex_write_config_toml() {
    local content="$1"
    local config_dir
    local config_file

    config_dir="$(_codex_config_dir)"
    config_file="$(_codex_config_file)"

    mkdir -p "$config_dir"
    backup_file "$config_file" >/dev/null || true

    write_file "$config_file" <<EOF
${content}
EOF

    chown -R "$ADMIN_USER:$ADMIN_USER" "$config_dir"
    chmod 600 "$config_file"
}

install_codex_cli() {
    log_info "Installing Codex CLI..."
    npm install -g @openai/codex

    local version
    version=$(codex --version 2>/dev/null)

    log_info "Codex CLI installed: $version"
    _codex_set_state "CODEX_INSTALLED" "yes"
    _codex_set_state "CODEX_VERSION" "$version"
    _codex_set_state "CODEX_INSTALL_DATE" "$(date +%Y-%m-%d)"
}

configure_codex_with_9router() {
    local api_key
    read -r -s -p "Paste API key from 9router dashboard: " api_key
    echo

    if [[ -z "$api_key" ]]; then
        log_error "API key cannot be empty"
        return 1
    fi

    _codex_write_api_key_file "$api_key"

    _codex_write_config_toml "[model]
provider = \"openai\"
name     = \"if/kimi-k2-thinking\"

[provider.openai]
base_url = \"http://127.0.0.1:20128/v1\"
api_key  = \"${api_key}\""

    _codex_set_state "CODEX_MODE" "9router"
    _codex_set_state "CODEX_ENDPOINT" "http://127.0.0.1:20128/v1"
    _codex_set_state "CODEX_MODEL" "if/kimi-k2-thinking"
    _codex_set_state "CODEX_API_KEY_FILE" "$CODEX_API_KEY_FILE"

    log_info "Codex CLI configured to use 9router"
}

configure_codex_with_openai_api() {
    local api_key
    prompt_secret "Enter OpenAI API key"
    api_key="${SECRET:-}"
    unset SECRET

    if [[ -z "$api_key" ]]; then
        log_error "API key cannot be empty"
        return 1
    fi

    _codex_write_api_key_file "$api_key"

    _codex_set_state "CODEX_MODE" "openai-api"
    _codex_set_state "CODEX_ENDPOINT" "https://api.openai.com/v1"
    _codex_set_state "CODEX_MODEL" "gpt-5"
    _codex_set_state "CODEX_API_KEY_FILE" "$CODEX_API_KEY_FILE"

    log_info "Codex CLI configured to use OpenAI API key"
}

configure_codex_chatgpt_oauth() {
    print_section "ChatGPT OAuth (manual step required)"
    print_warn "OPS can only install Codex CLI. OAuth login must be done by operator."
    echo "1) Run: codex"
    echo "2) Complete browser login flow"
    echo "3) Return and run: codex --version"

    _codex_set_state "CODEX_MODE" "chatgpt-oauth"
    _codex_set_state "CODEX_ENDPOINT" ""
    _codex_set_state "CODEX_MODEL" ""
    _codex_set_state "CODEX_API_KEY_FILE" ""
}

configure_codex_cli() {
    while true; do
        print_section "Configure Codex for this server"
        echo "  1) Use 9router endpoint (recommended)"
        echo "  2) Use OpenAI API key"
        echo "  3) ChatGPT OAuth (manual login)"
        echo "  0) Back"
        echo ""
        read -r -p "Select: " choice

        case "$choice" in
            1) configure_codex_with_9router; return ;;
            2) configure_codex_with_openai_api; return ;;
            3) configure_codex_chatgpt_oauth; return ;;
            0) return ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}

enable_codex_auto_env() {
    local marker="# OPS: codex-cli auto env"
    local profile="/home/$ADMIN_USER/.bash_profile"

    touch "$profile"
    chown "$ADMIN_USER:$ADMIN_USER" "$profile"

    if grep -q "$marker" "$profile" 2>/dev/null; then
        log_warn "Codex auto env already enabled"
        return
    fi

    backup_file "$profile" >/dev/null || true

    cat >> "$profile" <<EOF

${marker}
if [[ -f /etc/ops/.codex-api-key ]]; then
    export OPENAI_API_KEY="\$(cat /etc/ops/.codex-api-key)"
fi
EOF

    _codex_set_state "CODEX_AUTO_ENV" "yes"
    log_info "Codex auto env enabled"
}

disable_codex_auto_env() {
    local profile="/home/$ADMIN_USER/.bash_profile"

    if [[ ! -f "$profile" ]]; then
        _codex_set_state "CODEX_AUTO_ENV" "no"
        log_info "Codex auto env disabled"
        return
    fi

    backup_file "$profile" >/dev/null || true
    sed -i '/# OPS: codex-cli auto env/,/^fi$/d' "$profile"
    _codex_set_state "CODEX_AUTO_ENV" "no"
    log_info "Codex auto env disabled"
}

toggle_codex_auto_env() {
    while true; do
        print_section "Enable / disable Codex CLI auto environment"
        echo "  1) Enable auto environment"
        echo "  2) Disable auto environment"
        echo "  0) Back"
        echo ""
        read -r -p "Select: " choice
        case "$choice" in
            1) enable_codex_auto_env; return ;;
            2) disable_codex_auto_env; return ;;
            0) return ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}

test_codex_cli() {
    ops_load_conf codex-cli.conf

    print_section "Codex CLI Test"
    echo "Version: $(codex --version 2>/dev/null || echo 'NOT FOUND')"
    echo "Config:  $(ls "$(_codex_config_file)" 2>/dev/null || echo 'NOT CONFIGURED')"

    if [[ "${CODEX_MODE:-}" == "9router" ]]; then
        echo "9router endpoint reachable: $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:20128/v1/models)"
    fi
}

menu_codex_cli() {
    while true; do
        print_section "Codex CLI Integration"
        echo "  1) Install Codex CLI"
        echo "  2) Configure Codex for this server"
        echo "  3) Enable / disable Codex CLI auto environment"
        echo "  4) Test Codex CLI"
        echo "  0) Back"
        echo ""
        read -r -p "Select: " choice
        case "$choice" in
            1) install_codex_cli ;;
            2) configure_codex_cli ;;
            3) toggle_codex_auto_env ;;
            4) test_codex_cli ;;
            0) return ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}
