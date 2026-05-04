#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_FILTER="${OPS_TEST_SUITE_FILTER:-}"

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --profile)
            [[ "$#" -ge 2 ]] || { printf '[FAIL] Missing value for %s\n' "$1" >&2; exit 1; }
            PROFILE_FILTER="$2"
            shift 2
            ;;
        *)
            PROFILE_FILTER="${PROFILE_FILTER:-$1}"
            shift
            ;;
    esac
done

profile_selected() {
    local profile_name="$1"

    [[ -z "$PROFILE_FILTER" ]] && return 0
    [[ "$profile_name" == "$PROFILE_FILTER" || "$profile_name" == *"$PROFILE_FILTER"* || "$profile_name" == $PROFILE_FILTER ]]
}

discover_profiles() {
    local profile_path profile_name discovered=0
    shopt -s nullglob
    for profile_path in "${SCRIPT_DIR}"/*.sh; do
        profile_name="$(basename "$profile_path")"
        case "$profile_name" in
            run-all.sh) continue ;;
        esac
        profile_name="${profile_name%.sh}"
        if profile_selected "$profile_name"; then
            printf '%s\n' "$profile_path"
            discovered=1
        fi
    done
    shopt -u nullglob

    if [[ "$discovered" -eq 0 ]]; then
        printf '[FAIL] No acceptance profiles matched filter: %s\n' "${PROFILE_FILTER:-<all>}" >&2
        return 1
    fi
}

run_profile() {
    local profile_name="$1"
    local profile_path="$2"

    printf '[RUN ] acceptance profile %s\n' "$profile_name"
    if bash "$profile_path"; then
        return 0
    fi

    printf '[FAIL] %s failed\n' "$profile_name" >&2
    return 1
}

mapfile -t profile_paths < <(discover_profiles)

failures=0
for profile_path in "${profile_paths[@]}"; do
    profile_name="$(basename "$profile_path" .sh)"
    run_profile "$profile_name" "$profile_path" || failures=$((failures + 1))
done

if [[ "$failures" -ne 0 ]]; then
    printf '[FAIL] %s acceptance profile(s) failed\n' "$failures" >&2
    exit 1
fi

printf '[PASS] All acceptance profiles passed\n'
