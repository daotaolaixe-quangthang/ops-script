#!/usr/bin/env bash
# ============================================================
# ops/core/ui.sh
# Purpose:  Menu rendering, prompts, colours, confirmation helpers
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# Source this file; do NOT execute directly.
set -euo pipefail
IFS=$'\n\t'

# ── Colours ───────────────────────────────────────────────────
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
BLU='\033[0;34m'
CYN='\033[0;36m'
BLD='\033[1m'
RST='\033[0m'

# ── Section headers ───────────────────────────────────────────
print_section() {
    echo ""
    echo -e "${CYN}${BLD}━━━ $* ━━━${RST}"
    echo ""
}

# ── Status indicators ─────────────────────────────────────────
print_ok()    { echo -e "  ${GRN}✓${RST} $*"; }
print_warn()  { echo -e "  ${YLW}⚠${RST} $*"; }
print_error() { echo -e "  ${RED}✗${RST} $*"; }
print_err()   { print_error "$@"; }

# ── Prompt helpers ────────────────────────────────────────────

# prompt_input <label> [default]
# Reads freeform text; stores result in REPLY.
prompt_input() {
    local label="$1"
    local default="${2:-}"
    if [[ -n "$default" ]]; then
        read -r -p "${label} [${default}]: " REPLY
        REPLY="${REPLY:-$default}"
    else
        read -r -p "${label}: " REPLY
    fi
}

prompt_text() {
    prompt_input "$@"
}

# prompt_confirm <question>
# Returns 0 (yes) or 1 (no). Treats anything other than y/Y as no.
prompt_confirm() {
    local label="${1:-Are you sure?}"
    read -r -p "${label} [y/N]: " ans
    [[ "${ans,,}" == "y" ]]
}

confirm() {
    prompt_confirm "$@"
}

# prompt_secret <label>
# Reads a secret without echoing; stores result in SECRET.
prompt_secret() {
    local label="${1:-Enter secret}"
    read -r -s -p "${label}: " SECRET
    echo
}

# ── Generic menu helper ───────────────────────────────────────
# Usage: show_menu "Title" "Item 1" "Item 2" ...
# Selection stored in MENU_CHOICE.
show_menu() {
    local title="$1"
    shift
    print_section "$title"
    local i=1
    for item in "$@"; do
        echo -e "  ${BLD}${i})${RST} $item"
        (( i++ ))
    done
    echo -e "  ${BLD}0)${RST} Back / Exit"
    echo ""
    read -r -p "Select option: " MENU_CHOICE
}
