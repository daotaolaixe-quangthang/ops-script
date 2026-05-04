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
    if [[ "$output" != *"requires an interactive terminal"* && "$output" != *"Cannot create lock file"* && "$output" != *"Cannot open lock file"* ]]; then
        printf 'unexpected output: %s\n' "$output" >&2
        return 1
    fi

    if command -v script >/dev/null 2>&1; then
        set +e
        output="$(script -e -q -c "bash \"${OPS_ROOT}/bin/ops\" < /dev/null" /dev/null 2>&1)"
        status=$?
        set -e
        if [[ "$status" -eq 0 ]]; then
            printf 'ops must reject redirected stdin even when a controlling tty exists | actual=%s\n' "$status" >&2
            return 1
        fi
        if [[ "$output" != *"requires an interactive terminal"* ]]; then
            printf 'unexpected mixed-tty output: %s\n' "$output" >&2
            return 1
        fi
    fi
}

case_tui_01_main_menu_labels_declared() {
    local file
    file="${OPS_ROOT}/bin/ops"
    test::assert_file_contains "$file" '1) Production Setup Wizard' 'main menu label missing' || return 1
    test::assert_file_contains "$file" '2) Node.js Services' 'main menu label missing' || return 1
    test::assert_file_contains "$file" '3) Domains & Nginx' 'main menu label missing' || return 1
    test::assert_file_contains "$file" '4) SSL Management' 'main menu label missing' || return 1
    test::assert_file_contains "$file" '5) CLIProxyAPI Management' 'main menu label missing' || return 1
    test::assert_file_contains "$file" '6) PHP / PHP-FPM Management' 'main menu label missing' || return 1
    test::assert_file_contains "$file" '7) Database Management' 'main menu label missing' || return 1
    test::assert_file_contains "$file" '8) AI Agent Integration' 'main menu label missing' || return 1
    test::assert_file_contains "$file" '9) System & Monitoring' 'main menu label missing' || return 1
    test::assert_file_contains "$file" 's) Security Management' 'security menu label missing' || return 1
    test::assert_file_contains "$file" '0) Exit' 'main menu exit option missing' || return 1
}

case_tui_07_no_read_p_tty_antipattern() {
    local hits
    hits="$(OPS_ROOT_ENV="$OPS_ROOT" python3 - <<'PY'
import os
import re
from pathlib import Path

root = Path(os.environ['OPS_ROOT_ENV'])
pattern = re.compile(r'\bread\b[^\n#]*\s-p(?:\s|$)')
for rel in ('bin', 'core', 'modules'):
    for path in sorted((root / rel).rglob('*.sh')):
        for lineno, line in enumerate(path.read_text().splitlines(), 1):
            if pattern.search(line):
                print(f'{path}:{lineno}:{line}')
PY
)"
    test::assert_eq "" "$hits" "read -p prompt anti-pattern must not exist in ops scripts" || return 1
}

case_tui_05_menu_calls_not_masked_with_true() {
    local file content failures
    local menu_modules=(
        'modules/setup-wizard.sh'
        'modules/security.sh'
        'modules/nginx.sh'
        'modules/node.sh'
        'modules/cli-proxy-api.sh'
        'modules/php.sh'
        'modules/database.sh'
        'modules/monitoring.sh'
        'modules/checks.sh'
        'modules/backup.sh'
        'modules/codex-cli.sh'
        'modules/ai-agent.sh'
    )
    file="${OPS_ROOT}/bin/ops"
    content="$(<"$file")"
    test::assert_not_contains "$content" 'menu_setup_wizard || true' 'menu must not be shielded with || true' || return 1
    test::assert_not_contains "$content" 'menu_monitoring || true' 'menu must not be shielded with || true' || return 1
    test::assert_not_contains "$content" 'menu_security || true' 'menu must not be shielded with || true' || return 1

    failures="$(test::menu_boundary_failures "$OPS_ROOT" "${menu_modules[@]}")"
    test::assert_eq "" "$failures" "public menu_* functions must absorb soft failures with a local wrapper" || return 1
}

case_tui_09_locking_present() {
    local file
    file="${OPS_ROOT}/bin/ops"
    test::assert_file_contains "$file" 'OPS_LOCK_FILE=' 'ops session lock missing' || return 1
    test::assert_file_contains "$file" 'exec 9<"$OPS_LOCK_FILE"' 'ops lock must reopen shared file read-only' || return 1
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
    test::assert_contains "$content" 'prompt_menu_choice "Select" 300 choice' 'main menu timeout read contract missing' || return 1
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
    test::assert_file_contains "$file" 'exec 9<&-' 'lock cleanup must close the lock fd' || return 1
}

test::run_case 'TUI-01' 'main menu labels declared' case_tui_01_main_menu_labels_declared
test::run_case 'TUI-02' 'invalid option guard present' case_tui_02_invalid_option_guard_present
test::run_case 'TUI-03' 'timeout exit contract present' case_tui_03_timeout_exit_contract_present
test::run_case 'TUI-04' 'interactive-terminal guard rejects tty-loss and redirected stdin' case_tui_04_non_tty_requires_interactive_terminal
test::run_case 'TUI-05' 'menu boundaries stay unmasked and wrapped' case_tui_05_menu_calls_not_masked_with_true
test::run_case 'TUI-06' 'verify boundary wrapper present' case_tui_06_verify_boundary_contract_present
test::run_case 'TUI-07' 'read -p prompt anti-pattern absent' case_tui_07_no_read_p_tty_antipattern
test::run_case 'TUI-08' 'main menu exit option present' case_tui_08_back_option_present
test::run_case 'TUI-09' 'session lock contract present' case_tui_09_locking_present
test::run_case 'TUI-10' 'session lock cleanup contract present' case_tui_10_lock_cleanup_trap_present

test::finish
