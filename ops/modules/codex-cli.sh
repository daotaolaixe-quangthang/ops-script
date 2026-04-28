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

configure_codex_with_cliproxyapi() {
    local api_key model_name cpa_key_file admin_bashrc admin_home
    cpa_key_file="${OPS_CONFIG_DIR}/.cli-proxy-api-key"
    admin_home=$(getent passwd "$ADMIN_USER" | cut -d: -f6 || true)
    admin_home="${admin_home:-/home/$ADMIN_USER}"
    admin_bashrc="${admin_home}/.bashrc"

    # Auto-read CLIProxyAPI key if available
    if [[ -f "$cpa_key_file" ]]; then
        api_key=$(tr -d '\r\n' < "$cpa_key_file")
        log_info "Using CLIProxyAPI key from $cpa_key_file"
    else
        printf "  Paste API key from CLIProxyAPI: " > /dev/tty
        read -r -s api_key < /dev/tty
        echo ""
    fi

    if [[ -z "$api_key" ]]; then
        log_error "API key cannot be empty"
        return 1
    fi

    printf "  Default model [gpt-5.4]: " > /dev/tty
    read -r model_name < /dev/tty
    model_name="${model_name:-gpt-5.4}"

    # Write correct config.toml format (env_key style, no inline secret)
    local codex_env_key="CLI_PROXY_API_KEY"
    local env_key_instructions="Set ${codex_env_key} to your CLIProxyAPI api key (from ${cpa_key_file})"

    _codex_write_config_toml "model = \"${model_name}\"
model_provider = \"cliproxyapi\"
model_reasoning_effort = \"medium\"

[model_providers.cliproxyapi]
name = \"CLIProxyAPI\"
base_url = \"http://127.0.0.1:8317/v1\"
wire_api = \"responses\"
env_key = \"${codex_env_key}\"
env_key_instructions = \"${env_key_instructions}\"

[profiles.max]
model = \"gpt-5.4\"
model_provider = \"cliproxyapi\"

[profiles.fast]
model = \"gpt-5.3-codex\"
model_provider = \"cliproxyapi\""

    # Export CLI_PROXY_API_KEY into admin ~/.bashrc
    local codex_marker="# OPS: codex-cliproxyapi env"
    touch "$admin_bashrc"
    chown "$ADMIN_USER:$ADMIN_USER" "$admin_bashrc"
    if grep -q "$codex_marker" "$admin_bashrc" 2>/dev/null; then
        backup_file "$admin_bashrc" >/dev/null || true
        sed -i "/^${codex_marker}$/,/^$/d" "$admin_bashrc"
    else
        backup_file "$admin_bashrc" >/dev/null || true
    fi
    cat >> "$admin_bashrc" <<EOF

${codex_marker}
export ${codex_env_key}=${api_key}
EOF
    chown "$ADMIN_USER:$ADMIN_USER" "$admin_bashrc"

    _codex_set_state "CODEX_MODE" "cliproxyapi"
    _codex_set_state "CODEX_ENDPOINT" "http://127.0.0.1:8317/v1"
    _codex_set_state "CODEX_MODEL" "$model_name"

    log_info "Codex CLI configured to use CLIProxyAPI (model: ${model_name})"
    print_warn "Reload shell to apply: source ~/.bashrc"
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

    prompt_input "Enter model name (e.g. gpt-4o, gpt-4, o1-mini)" "gpt-4o"
    local model_name="${REPLY:-gpt-4o}"

    _codex_write_api_key_file "$api_key"

    _codex_set_state "CODEX_MODE" "openai-api"
    _codex_set_state "CODEX_ENDPOINT" "https://api.openai.com/v1"
    _codex_set_state "CODEX_MODEL" "$model_name"
    _codex_set_state "CODEX_API_KEY_FILE" "$CODEX_API_KEY_FILE"

    log_info "Codex CLI configured to use OpenAI API key (model: ${model_name})"
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

configure_codex_custom() {
    print_section "Codex — Custom Endpoint"
    echo ""

    # Prompt Base URL
    local base_url
    printf "  Enter Base URL [https://api.openai.com/v1]: " > /dev/tty
    read -r base_url < /dev/tty
    base_url="${base_url:-https://api.openai.com/v1}"

    # Prompt API Key
    local api_key
    printf "  Enter API Key: " > /dev/tty
    read -r -s api_key < /dev/tty
    echo ""
    if [[ -z "$api_key" ]]; then
        log_error "API Key cannot be empty"
        return 1
    fi

    # Prompt Model
    local model
    printf "  Enter Model name [gpt-4o]: " > /dev/tty
    read -r model < /dev/tty
    model="${model:-gpt-4o}"

    _codex_write_api_key_file "$api_key"

    _codex_write_config_toml "[model]
provider = \"openai\"
name     = \"${model}\"

[provider.openai]
base_url = \"${base_url}\"
api_key  = \"${api_key}\""

    _codex_set_state "CODEX_MODE"         "custom"
    _codex_set_state "CODEX_ENDPOINT"     "$base_url"
    _codex_set_state "CODEX_MODEL"        "$model"
    _codex_set_state "CODEX_API_KEY_FILE" "$CODEX_API_KEY_FILE"

    log_info "Codex CLI configured with custom endpoint (model: ${model}, url: ${base_url})"
}

configure_codex_cli() {
    _configure_codex_menu_run() {
        "$@"
        return 0
    }

    while true; do
        print_section "Configure Codex for this server"
        echo "  1) Use CLIProxyAPI endpoint (recommended)"
        echo "  2) Use OpenAI API key"
        echo "  3) ChatGPT OAuth (manual login)"
        echo "  4) Custom endpoint (enter Base URL / API Key / Model)"
        echo "  0) Back"
        echo ""
        printf "  Select: " > /dev/tty
        local choice
        read -r choice < /dev/tty

        case "$choice" in
            1) _configure_codex_menu_run configure_codex_with_cliproxyapi; return 0 ;;
            2) _configure_codex_menu_run configure_codex_with_openai_api; return 0 ;;
            3) _configure_codex_menu_run configure_codex_chatgpt_oauth; return 0 ;;
            4) _configure_codex_menu_run configure_codex_custom; return 0 ;;
            0) return 0 ;;
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
    _toggle_codex_auto_env_run() {
        "$@"
        return 0
    }

    while true; do
        print_section "Enable / disable Codex CLI auto environment"
        echo "  1) Enable auto environment"
        echo "  2) Disable auto environment"
        echo "  0) Back"
        echo ""
        printf "  Select: " > /dev/tty
        local choice
        read -r choice < /dev/tty
        case "$choice" in
            1) _toggle_codex_auto_env_run enable_codex_auto_env; return 0 ;;
            2) _toggle_codex_auto_env_run disable_codex_auto_env; return 0 ;;
            0) return 0 ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}

test_codex_cli() {
    ops_load_conf codex-cli.conf

    print_section "Codex CLI Test"
    echo "Version: $(codex --version 2>/dev/null || echo 'NOT FOUND')"
    echo "Config:  $(ls "$(_codex_config_file)" 2>/dev/null || echo 'NOT CONFIGURED')"

    if [[ "${CODEX_MODE:-}" == "cliproxyapi" ]]; then
        echo "CLIProxyAPI endpoint reachable: $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8317/v1/models)"
    fi
}

menu_codex_cli() {
    _codex_menu_run() {
        "$@"
        return 0
    }

    while true; do
        print_section "Codex CLI Integration"
        echo "  1) Install Codex CLI"
        echo "  2) Configure Codex for this server"
        echo "  3) Enable / disable Codex CLI auto environment"
        echo "  4) Test Codex CLI"
        echo "  0) Back"
        echo ""
        printf "  Select: " > /dev/tty
        local choice
        read -r choice < /dev/tty
        case "$choice" in
            1) _codex_menu_run install_codex_cli ;;
            2) _codex_menu_run configure_codex_cli ;;
            3) _codex_menu_run toggle_codex_auto_env ;;
            4) _codex_menu_run test_codex_cli ;;
            0) return 0 ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}
