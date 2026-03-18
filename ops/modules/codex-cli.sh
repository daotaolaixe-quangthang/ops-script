#!/usr/bin/env bash
# ============================================================
# ops/modules/codex-cli.sh
# Purpose:  Codex CLI install and configuration
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# Called by bin/ops via menu dispatch.
# Do NOT add set -euo pipefail here — inherited from bin/ops.

# ── Public menu entry ─────────────────────────────────────────
menu_codex_cli() {
    while true; do
        print_section "Codex CLI Integration"
        echo "  1) Install Codex CLI"
        echo "  2) Configure API key"
        echo "  3) Update Codex CLI"
        echo "  4) Show Codex CLI status"
        echo "  5) Remove Codex CLI"
        echo "  0) Back"
        echo ""
        read -r -p "Select: " choice
        case "$choice" in
            1) codex_install        ;;
            2) codex_configure_key  ;;
            3) codex_update         ;;
            4) codex_status         ;;
            5) codex_remove         ;;
            0) return               ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}

# ── Actions (stubs) ───────────────────────────────────────────

codex_install() {
    print_section "Install Codex CLI"
    # TODO: ensure Node.js is installed; npm install -g @openai/codex
    # TODO: ops_conf_set codex-cli.conf CODEX_INSTALLED true
    print_warn "codex_install: not implemented yet"
}

codex_configure_key() {
    print_section "Configure Codex API Key"
    # TODO: prompt_secret "Enter OpenAI API Key"
    # TODO: store in /etc/ops/.codex-api-key (chmod 0600, owned by ADMIN_USER)
    # TODO: ops_conf_set codex-cli.conf CODEX_API_KEY_SET true
    print_warn "codex_configure_key: not implemented yet"
}

codex_update() {
    print_section "Update Codex CLI"
    # TODO: npm install -g @openai/codex@latest
    print_warn "codex_update: not implemented yet"
}

codex_status() {
    print_section "Codex CLI Status"
    # TODO: codex --version; show conf from /etc/ops/codex-cli.conf
    if is_installed codex; then
        print_ok "Codex CLI installed"
        codex --version 2>/dev/null || true
    else
        print_warn "Codex CLI not installed"
    fi
}

codex_remove() {
    print_section "Remove Codex CLI"
    # TODO: npm uninstall -g @openai/codex; remove secret file; update conf
    print_warn "codex_remove: not implemented yet"
}
