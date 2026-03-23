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

    # Prompt Base URL
    local base_url
    read -r -p "  Enter Base URL [https://api.anthropic.com/v1]: " base_url
    base_url="${base_url:-https://api.anthropic.com/v1}"

    # Prompt API Key
    local api_key
    read -r -s -p "  Enter API Key: " api_key
    echo ""
    if [[ -z "$api_key" ]]; then
        log_error "API Key cannot be empty"
        return 1
    fi

    # Prompt Model
    local model
    read -r -p "  Enter Model name [claude-opus-4-5]: " model
    model="${model:-claude-opus-4-5}"

    echo ""
    log_info "Writing Claude config to $bashrc ..."

    # Ensure bashrc exists and is owned by admin
    touch "$bashrc"
    chown "$ADMIN_USER:$ADMIN_USER" "$bashrc"

    # Remove old block if exists (idempotent)
    if grep -q "$CLAUDE_MARKER" "$bashrc" 2>/dev/null; then
        backup_file "$bashrc" >/dev/null || true
        # Delete from marker line to the next blank line after the last export
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

# ── Menus ─────────────────────────────────────────────────────

menu_claude_cli() {
    while true; do
        print_section "Claude Code CLI Integration"
        echo "  1) Install Claude Code CLI"
        echo "  2) Configure environment Claude for this server"
        echo "  3) Test Claude Code CLI"
        echo "  4) Install Vietnamese fix for Claude Code CLI"
        echo "  0) Back"
        echo ""
        read -r -p "Select: " choice
        case "$choice" in
            1) install_claude_cli           || true ;;
            2) configure_claude_cli         || true ;;
            3) test_claude_cli              || true ;;
            4) install_claude_vietnamese_fix || true ;;
            0) return ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}

menu_ai_agent() {
    while true; do
        print_section "AI Agent Integration"
        echo "  1) Codex CLI Integration"
        echo "  2) Claude Code CLI Integration"
        echo "  0) Back"
        echo ""
        read -r -p "Select: " choice
        case "$choice" in
            1) menu_codex_cli  || true ;;
            2) menu_claude_cli || true ;;
            0) return ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}
