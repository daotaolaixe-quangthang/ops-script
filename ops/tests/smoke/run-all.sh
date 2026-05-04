#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_FILTER="${OPS_TEST_SUITE_FILTER:-}"

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --layer|--suite)
            [[ "$#" -ge 2 ]] || { printf '[FAIL] Missing value for %s\n' "$1" >&2; exit 1; }
            SUITE_FILTER="$2"
            shift 2
            ;;
        *)
            SUITE_FILTER="${SUITE_FILTER:-$1}"
            shift
            ;;
    esac
done

suite_selected() {
    local suite_name="$1"

    [[ -z "$SUITE_FILTER" ]] && return 0
    [[ "$suite_name" == "$SUITE_FILTER" || "$suite_name" == *"$SUITE_FILTER"* || "$suite_name" == $SUITE_FILTER ]]
}

discover_suites() {
    local suite_path suite_name discovered=0
    shopt -s nullglob
    for suite_path in "${SCRIPT_DIR}"/*.sh; do
        suite_name="$(basename "$suite_path")"
        case "$suite_name" in
            run-all.sh) continue ;;
        esac
        suite_name="${suite_name%.sh}"
        if suite_selected "$suite_name"; then
            printf '%s\n' "$suite_path"
            discovered=1
        fi
    done
    shopt -u nullglob

    if [[ "$discovered" -eq 0 ]]; then
        printf '[FAIL] No smoke suites matched filter: %s\n' "${SUITE_FILTER:-<all>}" >&2
        return 1
    fi
}

run_suite() {
    local suite_name="$1"
    local suite_path="$2"

    printf '[RUN ] smoke suite %s\n' "$suite_name"
    if bash "$suite_path"; then
        return 0
    fi

    printf '[FAIL] %s failed\n' "$suite_name" >&2
    return 1
}

mapfile -t suite_paths < <(discover_suites)

failures=0
for suite_path in "${suite_paths[@]}"; do
    suite_name="$(basename "$suite_path" .sh)"
    run_suite "$suite_name" "$suite_path" || failures=$((failures + 1))
done

if [[ "$failures" -ne 0 ]]; then
    printf '[FAIL] %s smoke suite(s) failed\n' "$failures" >&2
    exit 1
fi

printf '[PASS] All smoke suites passed\n'
