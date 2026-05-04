#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ops/tests/regression/lib.sh
source "${SCRIPT_DIR}/../regression/lib.sh"

TEST_SUITE_NAME="tui-smoke"
test::init

case_tui_smoke_01_non_tty_guard_live_entrypoint() {
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
}

case_tui_smoke_02_controlling_tty_still_rejects_redirected_stdin() {
    local output status
    test::require_command script || return $?

    set +e
    output="$(script -e -q -c "bash \"${OPS_ROOT}/bin/ops\" < /dev/null" /dev/null 2>&1)"
    status=$?
    set -e
    if [[ "$status" -eq 0 ]]; then
        printf 'ops must reject redirected stdin even with a controlling tty | actual=%s\n' "$status" >&2
        return 1
    fi
    if [[ "$output" != *"requires an interactive terminal"* ]]; then
        printf 'unexpected mixed-tty output: %s\n' "$output" >&2
        return 1
    fi
}

test::run_case 'TUI-SMOKE-01' 'ops rejects non-interactive launch on live entrypoint' case_tui_smoke_01_non_tty_guard_live_entrypoint
test::run_case 'TUI-SMOKE-02' 'ops rejects redirected stdin even with controlling tty' case_tui_smoke_02_controlling_tty_still_rejects_redirected_stdin

test::finish
