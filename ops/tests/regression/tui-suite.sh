#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ops/tests/regression/lib.sh
source "${SCRIPT_DIR}/lib.sh"

TEST_SUITE_NAME="tui-suite"
test::init

case_tui_04_non_tty_requires_interactive_terminal() {
    local output status
    set +e
    output="$(bash "${OPS_ROOT}/bin/ops" < /dev/null 2>&1)"
    status=$?
    set -e
    if [[ "$status" -eq 0 ]]; then
        printf 'ops must exit non-zero without tty | actual=%s\n' "$status" >&2
        return 1
    fi
    if [[ "$output" == *"requires an interactive terminal"* || "$output" == *"Cannot open lock file"* ]]; then
        return 0
    fi
    printf 'unexpected output: %s\n' "$output" >&2
    return 1
}

case_tui_01_main_menu_labels_declared() {
    local file
    file="${OPS_ROOT}/bin/ops"
    test::assert_file_contains "$file" 'Production Setup Wizard' 'main menu label missing' || return 1
    test::assert_file_contains "$file" 'Node.js Services' 'main menu label missing' || return 1
    test::assert_file_contains "$file" 'Domains & Nginx' 'main menu label missing' || return 1
    test::assert_file_contains "$file" '9) System & Monitoring' 'main menu label missing' || return 1
    test::assert_file_contains "$file" 's) Security Management' 'security menu label missing' || return 1
}

case_tui_07_no_read_p_tty_antipattern() {
    local hits
    hits="$(grep -R -n -E "read[[:space:]]+-[^\r\n]*-p[^\r\n]*<[[:space:]]*/dev/tty" "${OPS_ROOT}" 2>/dev/null || true)"
    test::assert_eq "" "$hits" "TTY prompt anti-pattern must not exist in ops scripts" || return 1
}

case_tui_05_menu_calls_not_masked_with_true() {
    local file content
    file="${OPS_ROOT}/bin/ops"
    content="$(<"$file")"
    test::assert_not_contains "$content" 'menu_setup_wizard || true' 'menu must not be shielded with || true' || return 1
    test::assert_not_contains "$content" 'menu_monitoring || true' 'menu must not be shielded with || true' || return 1
    test::assert_not_contains "$content" 'menu_security || true' 'menu must not be shielded with || true' || return 1
}

case_tui_09_locking_present() {
    local file
    file="${OPS_ROOT}/bin/ops"
    test::assert_file_contains "$file" 'OPS_LOCK_FILE=' 'ops session lock missing' || return 1
    test::assert_file_contains "$file" 'flock -n 9' 'ops non-blocking lock missing' || return 1
    test::assert_file_contains "$file" 'Another ops session is already running' 'lock conflict message missing' || return 1
}

case_tui_02_invalid_option_guard_present() {
    local file
    file="${OPS_ROOT}/bin/ops"
    test::assert_file_contains "$file" 'Invalid option' 'invalid option warning missing' || return 1
}

case_tui_03_timeout_exit_contract_present() {
    local file content
    file="${OPS_ROOT}/bin/ops"
    content="$(<"$file")"
    test::assert_contains "$content" 'read -r -t 300 choice < /dev/tty' 'main menu timeout read contract missing' || return 1
    test::assert_contains "$content" 'exit 0' 'timeout path must exit cleanly' || return 1
}

case_tui_06_verify_boundary_contract_present() {
    local file
    file="${OPS_ROOT}/modules/monitoring.sh"
    test::assert_file_contains "$file" '_monitoring_menu_run()' 'monitoring wrapper missing for verify boundary' || return 1
    test::assert_file_contains "$file" 'verify_stack' 'monitoring menu must expose verify_stack action' || return 1
}

case_tui_08_back_option_present() {
    local file
    file="${OPS_ROOT}/bin/ops"
    test::assert_file_contains "$file" '0) Exit' 'main menu exit option missing' || return 1
}

case_tui_10_lock_cleanup_trap_present() {
    local file
    file="${OPS_ROOT}/bin/ops"
    test::assert_file_contains "$file" 'trap' 'lock cleanup trap missing' || return 1
    test::assert_file_contains "$file" 'rm -f "$OPS_LOCK_FILE"' 'lock cleanup path missing' || return 1
}

test::run_case 'TUI-01' 'main menu labels declared' case_tui_01_main_menu_labels_declared
test::run_case 'TUI-02' 'invalid option guard present' case_tui_02_invalid_option_guard_present
test::run_case 'TUI-03' 'timeout exit contract present' case_tui_03_timeout_exit_contract_present
test::run_case 'TUI-04' 'non-tty invocation exits cleanly' case_tui_04_non_tty_requires_interactive_terminal
test::run_case 'TUI-05' 'menu calls not masked with || true' case_tui_05_menu_calls_not_masked_with_true
test::run_case 'TUI-06' 'verify boundary wrapper present' case_tui_06_verify_boundary_contract_present
test::run_case 'TUI-07' 'tty prompt anti-pattern absent' case_tui_07_no_read_p_tty_antipattern
test::run_case 'TUI-08' 'main menu exit option present' case_tui_08_back_option_present
test::run_case 'TUI-09' 'session lock contract present' case_tui_09_locking_present
test::run_case 'TUI-10' 'session lock cleanup contract present' case_tui_10_lock_cleanup_trap_present

test::finish
