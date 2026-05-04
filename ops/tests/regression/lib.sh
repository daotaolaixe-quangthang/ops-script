#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPS_ROOT="$(cd "${TEST_ROOT}/../.." && pwd)"
REPO_ROOT="$(cd "${OPS_ROOT}/.." && pwd)"
TEST_TMP_ROOT="${OPS_TEST_TMP_ROOT:-${REPO_ROOT}/.ops-test-tmp}"
TEST_REPORT_DIR="${OPS_TEST_REPORT_DIR:-${REPO_ROOT}/.ops-test-reports}"
TEST_ENV_DIR=""
TEST_TOTAL=0
TEST_PASSED=0
TEST_FAILED=0
TEST_SKIPPED=0
TEST_CURRENT_ID=""
TEST_CURRENT_NAME=""
TEST_SUITE_NAME="${TEST_SUITE_NAME:-unnamed}"
TEST_SUITE_FILTER="${OPS_TEST_SUITE_FILTER:-}"
TEST_CASE_FILTER="${OPS_TEST_CASE_FILTER:-}"
TEST_KEEP_TMP="${OPS_TEST_KEEP_TMP:-0}"
declare -a TEST_CASE_RESULTS=()
declare -a TEST_FAILURE_DETAILS=()

test::init() {
    mkdir -p "$TEST_TMP_ROOT" "$TEST_REPORT_DIR"
    TEST_ENV_DIR="$(mktemp -d "${TEST_TMP_ROOT}/env.XXXXXX")"
    trap 'test::cleanup' EXIT INT TERM HUP
}

test::cleanup() {
    if [[ -z "${TEST_ENV_DIR:-}" || ! -d "$TEST_ENV_DIR" ]]; then
        return 0
    fi

    case "$TEST_KEEP_TMP" in
        1|yes|true|always)
            printf '[INFO] Preserved test env: %s\n' "$TEST_ENV_DIR"
            return 0
            ;;
        fail|on-fail)
            if [[ "$TEST_FAILED" -gt 0 ]]; then
                printf '[INFO] Preserved test env after failure: %s\n' "$TEST_ENV_DIR"
                return 0
            fi
            ;;
    esac

    rm -rf "$TEST_ENV_DIR"
}

test::begin_case() {
    TEST_CURRENT_ID="$1"
    TEST_CURRENT_NAME="$2"
    TEST_TOTAL=$((TEST_TOTAL + 1))
    printf '[RUN ] %s - %s\n' "$TEST_CURRENT_ID" "$TEST_CURRENT_NAME"
}

test::pass_case() {
    TEST_PASSED=$((TEST_PASSED + 1))
    TEST_CASE_RESULTS+=("[PASS] ${TEST_CURRENT_ID} - ${TEST_CURRENT_NAME}")
    printf '[PASS] %s - %s\n' "$TEST_CURRENT_ID" "$TEST_CURRENT_NAME"
}

test::fail_case() {
    local detail="${1:-Case failed without output}"
    TEST_FAILED=$((TEST_FAILED + 1))
    TEST_CASE_RESULTS+=("[FAIL] ${TEST_CURRENT_ID} - ${TEST_CURRENT_NAME}")
    TEST_FAILURE_DETAILS+=("${TEST_CURRENT_ID} - ${TEST_CURRENT_NAME}"$'\n'"${detail}")
    printf '[FAIL] %s - %s\n' "$TEST_CURRENT_ID" "$TEST_CURRENT_NAME"
    while IFS= read -r line; do
        printf '       %s\n' "$line"
    done <<< "$detail"
}

test::skip_case() {
    local detail="${1:-Case skipped}"
    TEST_SKIPPED=$((TEST_SKIPPED + 1))
    TEST_CASE_RESULTS+=("[SKIP] ${TEST_CURRENT_ID} - ${TEST_CURRENT_NAME}")
    printf '[SKIP] %s - %s\n' "$TEST_CURRENT_ID" "$TEST_CURRENT_NAME"
    while IFS= read -r line; do
        printf '       %s\n' "$line"
    done <<< "$detail"
}

test::matches_filter() {
    local value="$1"
    local filter="$2"

    [[ -z "$filter" ]] && return 0
    [[ "$value" == "$filter" || "$value" == *"$filter"* || "$value" == $filter ]]
}

test::case_selected() {
    local case_id="$1"
    local case_name="$2"

    if ! test::matches_filter "$TEST_SUITE_NAME" "$TEST_SUITE_FILTER"; then
        return 1
    fi

    if [[ -n "$TEST_CASE_FILTER" ]]; then
        test::matches_filter "$case_id" "$TEST_CASE_FILTER" || test::matches_filter "$case_name" "$TEST_CASE_FILTER"
        return $?
    fi

    return 0
}

test::request_skip() {
    local reason="${1:-case requested skip}"
    printf '%s\n' "$reason" >&2
    return 200
}

test::require_command() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || test::request_skip "missing required command: ${cmd}"
}

test::require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        test::request_skip 'run this case as root on a disposable/live OPS host'
    fi
}

test::assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    if [[ "$expected" != "$actual" ]]; then
        printf 'assert_eq failed: %s | expected=%s actual=%s\n' "$message" "$expected" "$actual" >&2
        return 1
    fi
}

test::assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        printf 'assert_contains failed: %s | needle=%s\n' "$message" "$needle" >&2
        return 1
    fi
}

test::assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf 'assert_not_contains failed: %s | needle=%s\n' "$message" "$needle" >&2
        return 1
    fi
}

test::assert_file_contains() {
    local file_path="$1"
    local needle="$2"
    local message="$3"
    if [[ ! -f "$file_path" ]]; then
        printf 'assert_file_contains failed: missing file %s | %s\n' "$file_path" "$message" >&2
        return 1
    fi
    if ! grep -Fq -- "$needle" "$file_path"; then
        printf 'assert_file_contains failed: %s | needle=%s file=%s\n' "$message" "$needle" "$file_path" >&2
        return 1
    fi
}

test::assert_file_not_contains() {
    local file_path="$1"
    local needle="$2"
    local message="$3"
    if [[ ! -f "$file_path" ]]; then
        printf 'assert_file_not_contains failed: missing file %s | %s\n' "$file_path" "$message" >&2
        return 1
    fi
    if grep -Fq -- "$needle" "$file_path"; then
        printf 'assert_file_not_contains failed: %s | needle=%s file=%s\n' "$message" "$needle" "$file_path" >&2
        return 1
    fi
}

test::menu_boundary_failures() {
    local ops_root="$1"
    shift
    local module_list
    module_list="$(printf '%s\n' "$@")"
    OPS_ROOT_ENV="$ops_root" TEST_MENU_MODULES_ENV="$module_list" python3 - <<'PY'
import os
from pathlib import Path

root = Path(os.environ['OPS_ROOT_ENV'])
files = [line for line in os.environ['TEST_MENU_MODULES_ENV'].splitlines() if line]

for rel in files:
    path = root / rel
    lines = path.read_text().splitlines()
    for idx, line in enumerate(lines):
        stripped = line.strip()
        if not stripped.startswith('menu_') or not stripped.endswith('{'):
            continue

        depth = 0
        body_lines = []
        for body_idx in range(idx, len(lines)):
            current = lines[body_idx]
            depth += current.count('{')
            if body_idx > idx:
                body_lines.append(current)
            depth -= current.count('}')
            if body_idx > idx and depth == 0:
                break

        body = '\n'.join(body_lines)
        if '_menu_run() {' not in body or 'return 0' not in body:
            print(f'{rel}:{idx + 1}:{stripped.split("(")[0]}')
PY
}

test::run_case() {
    local case_id="$1"
    local case_name="$2"
    local output status
    shift 2
    test::begin_case "$case_id" "$case_name"

    if ! test::case_selected "$case_id" "$case_name"; then
        test::skip_case "filtered out by suite/case selection"
        return 0
    fi

    set +e
    output="$("$@" 2>&1)"
    status=$?
    set -e
    if [[ "$status" -eq 0 ]]; then
        test::pass_case
        return 0
    fi
    if [[ "$status" -eq 200 ]]; then
        [[ -n "$output" ]] || output="case requested skip"
        test::skip_case "$output"
        return 0
    fi
    [[ -n "$output" ]] || output="case exited with status ${status}"
    test::fail_case "$output"
    return 0
}

test::report_path() {
    printf '%s/%s.report.txt\n' "$TEST_REPORT_DIR" "$TEST_SUITE_NAME"
}

test::write_report() {
    local report_path
    report_path="$(test::report_path)"
    {
        local line detail
        printf 'Suite: %s\n' "$TEST_SUITE_NAME"
        printf 'Total: %s\n' "$TEST_TOTAL"
        printf 'Passed: %s\n' "$TEST_PASSED"
        printf 'Failed: %s\n' "$TEST_FAILED"
        printf 'Skipped: %s\n' "$TEST_SKIPPED"
        printf '\nCases:\n'
        for line in "${TEST_CASE_RESULTS[@]}"; do
            printf '%s\n' "$line"
        done
        if [[ "${#TEST_FAILURE_DETAILS[@]}" -gt 0 ]]; then
            printf '\nFailure details:\n'
            for detail in "${TEST_FAILURE_DETAILS[@]}"; do
                printf -- '---\n%s\n' "$detail"
            done
        fi
    } > "$report_path"
    printf '[INFO] Report written: %s\n' "$report_path"
}

test::finish() {
    test::write_report
    if [[ "$TEST_FAILED" -gt 0 ]]; then
        printf '[FAIL] Suite %s failed (%s failed, %s skipped, %s total)\n' "$TEST_SUITE_NAME" "$TEST_FAILED" "$TEST_SKIPPED" "$TEST_TOTAL"
        return 1
    fi
    printf '[PASS] Suite %s passed (%s passed, %s skipped, %s total)\n' "$TEST_SUITE_NAME" "$TEST_PASSED" "$TEST_SKIPPED" "$TEST_TOTAL"
    return 0
}
