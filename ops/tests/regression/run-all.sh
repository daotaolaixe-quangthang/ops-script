#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPS_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO_ROOT="$(cd "${OPS_ROOT}/.." && pwd)"
TEST_REPORT_DIR="${OPS_TEST_REPORT_DIR:-${REPO_ROOT}/.ops-test-reports}"
SUITE_FILTER="${OPS_TEST_SUITE_FILTER:-${1:-}}"

syntax_preflight() {
    local file failed=0
    shopt -s nullglob
    local targets=(
        "${REPO_ROOT}/install/ops-install.sh"
        "${OPS_ROOT}/install/ops-install.sh"
        "${OPS_ROOT}/bin"/*
        "${OPS_ROOT}/core"/*.sh
        "${OPS_ROOT}/modules"/*.sh
        "${SCRIPT_DIR}"/*.sh
        "${OPS_ROOT}/tests/smoke"/*.sh
        "${OPS_ROOT}/tests/acceptance"/*.sh
    )

    printf '[RUN ] bash -n preflight\n'
    for file in "${targets[@]}"; do
        [[ -f "$file" ]] || continue
        if ! bash -n "$file"; then
            printf '[FAIL] bash -n %s\n' "$file" >&2
            failed=1
        fi
    done
    shopt -u nullglob

    if [[ "$failed" -ne 0 ]]; then
        printf '[FAIL] Syntax preflight failed\n' >&2
        return 1
    fi
    printf '[PASS] bash -n preflight\n'
}

suite_selected() {
    local suite_name="$1"

    [[ -z "$SUITE_FILTER" ]] && return 0
    [[ "$suite_name" == "$SUITE_FILTER" || "$suite_name" == *"$SUITE_FILTER"* || "$suite_name" == $SUITE_FILTER ]]
}

discover_suites() {
    local suite_path suite_name discovered=0
    shopt -s nullglob
    for suite_path in "${SCRIPT_DIR}"/*.sh; do
        [[ -f "$suite_path" ]] || continue
        suite_name="$(basename "$suite_path")"
        case "$suite_name" in
            lib.sh|run-all.sh) continue ;;
        esac
        suite_name="${suite_name%.sh}"
        if suite_selected "$suite_name"; then
            printf '%s\n' "$suite_path"
            discovered=1
        fi
    done
    shopt -u nullglob

    if [[ "$discovered" -eq 0 ]]; then
        printf '[FAIL] No regression suites matched filter: %s\n' "${SUITE_FILTER:-<all>}" >&2
        return 1
    fi
}

run_suite() {
    local suite_name="$1"
    local suite_path="$2"

    printf '[RUN ] suite %s\n' "$suite_name"
    if bash "$suite_path"; then
        return 0
    fi

    printf '[FAIL] %s failed\n' "$suite_name" >&2
    return 1
}

print_report_summary() {
    if [[ -d "$TEST_REPORT_DIR" ]]; then
        printf '[INFO] Reports directory: %s\n' "$TEST_REPORT_DIR"
    fi
}

syntax_preflight

mapfile -t suite_paths < <(discover_suites)

failures=0
for suite_path in "${suite_paths[@]}"; do
    suite_name="$(basename "$suite_path" .sh)"
    run_suite "$suite_name" "$suite_path" || failures=$((failures + 1))
done

print_report_summary

if [[ "$failures" -ne 0 ]]; then
    printf '[FAIL] %s regression suite(s) failed\n' "$failures" >&2
    exit 1
fi

printf '[PASS] All regression suites passed\n'
