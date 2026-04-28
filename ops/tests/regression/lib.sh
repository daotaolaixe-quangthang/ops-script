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
TEST_CURRENT_ID=""
TEST_CURRENT_NAME=""
TEST_SUITE_NAME="${TEST_SUITE_NAME:-unnamed}"

test::init() {
    mkdir -p "$TEST_TMP_ROOT" "$TEST_REPORT_DIR"
    TEST_ENV_DIR="$(mktemp -d "${TEST_TMP_ROOT}/env.XXXXXX")"
    trap 'test::cleanup' EXIT INT TERM HUP
}

test::cleanup() {
    if [[ -n "${TEST_ENV_DIR:-}" && -d "$TEST_ENV_DIR" ]]; then
        rm -rf "$TEST_ENV_DIR"
    fi
}

test::begin_case() {
    TEST_CURRENT_ID="$1"
    TEST_CURRENT_NAME="$2"
    TEST_TOTAL=$((TEST_TOTAL + 1))
    printf '[RUN ] %s - %s\n' "$TEST_CURRENT_ID" "$TEST_CURRENT_NAME"
}

test::pass_case() {
    TEST_PASSED=$((TEST_PASSED + 1))
    printf '[PASS] %s - %s\n' "$TEST_CURRENT_ID" "$TEST_CURRENT_NAME"
}

test::fail_case() {
    TEST_FAILED=$((TEST_FAILED + 1))
    printf '[FAIL] %s - %s\n' "$TEST_CURRENT_ID" "$TEST_CURRENT_NAME"
    printf '       %s\n' "$1"
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

test::run_case() {
    local case_id="$1"
    local case_name="$2"
    shift 2
    test::begin_case "$case_id" "$case_name"
    if "$@"; then
        test::pass_case
    else
        test::fail_case "See stderr for assertion details"
    fi
}

test::write_report() {
    local report_path="$TEST_REPORT_DIR/${TEST_SUITE_NAME}.report.txt"
    {
        printf 'Suite: %s\n' "$TEST_SUITE_NAME"
        printf 'Total: %s\n' "$TEST_TOTAL"
        printf 'Passed: %s\n' "$TEST_PASSED"
        printf 'Failed: %s\n' "$TEST_FAILED"
    } > "$report_path"
    printf '[INFO] Report written: %s\n' "$report_path"
}

test::finish() {
    test::write_report
    if [[ "$TEST_FAILED" -gt 0 ]]; then
        printf '[FAIL] Suite %s failed (%s/%s failed)\n' "$TEST_SUITE_NAME" "$TEST_FAILED" "$TEST_TOTAL"
        return 1
    fi
    printf '[PASS] Suite %s passed (%s cases)\n' "$TEST_SUITE_NAME" "$TEST_TOTAL"
    return 0
}
