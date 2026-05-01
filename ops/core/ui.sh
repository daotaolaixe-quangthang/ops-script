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

tty_is_available() {
    [[ -r /dev/tty && -w /dev/tty ]]
}

_tty_require_available() {
    if tty_is_available; then
        return 0
    fi
    echo "[ERROR] Interactive terminal unavailable." >&2
    return 1
}

tty_write() {
    local message="${1:-}"
    _tty_require_available || return 1
    printf "%s" "$message" > /dev/tty
}

tty_read() {
    local target_var="${1:-REPLY}"
    local timeout="${2:-}"
    local value=""

    _tty_require_available || return 1

    if [[ -n "$timeout" ]]; then
        if ! read -r -t "$timeout" value < /dev/tty; then
            return 1
        fi
    else
        read -r value < /dev/tty
    fi

    printf -v "$target_var" '%s' "$value"
}

prompt_menu_choice() {
    local label="${1:-Select}"
    local timeout="${2:-}"
    local target_var="${3:-REPLY}"

    tty_write "${label}: " || return 1
    tty_read "$target_var" "$timeout"
}

# prompt_input <label> [default]
# Reads freeform text; stores result in REPLY.
prompt_input() {
    local label="$1"
    local default="${2:-}"
    if [[ -n "$default" ]]; then
        tty_write "${label} [${default}]: " || return 1
        tty_read REPLY || return 1
        REPLY="${REPLY:-$default}"
    else
        tty_write "${label}: " || return 1
        tty_read REPLY || return 1
    fi
}

prompt_text() {
    prompt_input "$@"
}

# prompt_confirm <question>
# Returns 0 (yes) or 1 (no). Treats anything other than y/Y as no.
prompt_confirm() {
    local label="${1:-Are you sure?}"
    local ans=""
    tty_write "${label} [y/N]: " || return 1
    tty_read ans || return 1
    [[ "${ans,,}" == "y" ]]
}

confirm() {
    prompt_confirm "$@"
}

# prompt_secret <label>
# Reads a secret without echoing; stores result in SECRET.
prompt_secret() {
    local label="${1:-Enter secret}"
    tty_write "${label}: " || return 1
    if ! read -r -s SECRET < /dev/tty; then
        return 1
    fi
    printf '\n' > /dev/tty
}

# press_enter
# Pauses and waits for user to press Enter before returning to menu.
# Use after any non-interactive action so output stays visible.
press_enter() {
    if ! tty_is_available; then
        return 0
    fi
    echo ""
    tty_write "  Press Enter to return to menu..." || return 0
    tty_read _press_enter_dummy || true
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
        i=$(( i + 1 ))
    done
    echo -e "  ${BLD}0)${RST} Back / Exit"
    echo ""
    prompt_menu_choice "Select option" "" MENU_CHOICE
}
