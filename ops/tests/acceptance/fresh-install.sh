#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ops/tests/regression/lib.sh
source "${SCRIPT_DIR}/../regression/lib.sh"

TEST_SUITE_NAME="acceptance-fresh-install"
OPS_ACCEPT_LIVE_TREE="${OPS_ACCEPT_LIVE_TREE:-/opt/ops}"
OPS_ACCEPT_CONFIRM_MUTATION="${OPS_ACCEPT_CONFIRM_MUTATION:-0}"
OPS_ACCEPT_ALLOW_DIRTY="${OPS_ACCEPT_ALLOW_DIRTY:-0}"
test::init

acceptance_mutation_confirmed() {
    case "$OPS_ACCEPT_CONFIRM_MUTATION" in
        1|yes|true|YES) return 0 ;;
        *) return 1 ;;
    esac
}

case_accept_fresh_01_requires_explicit_mutation_confirmation() {
    acceptance_mutation_confirmed || test::request_skip 'set OPS_ACCEPT_CONFIRM_MUTATION=YES before running destructive fresh-install acceptance on a disposable Ubuntu snapshot'
}

case_accept_fresh_02_run_repo_installer_on_clean_snapshot() {
    test::require_root || return $?
    acceptance_mutation_confirmed || return $?

    if [[ -e "$OPS_ACCEPT_LIVE_TREE" && "$OPS_ACCEPT_ALLOW_DIRTY" != "1" ]]; then
        printf '%s already exists; rerun on a clean snapshot or set OPS_ACCEPT_ALLOW_DIRTY=1\n' "$OPS_ACCEPT_LIVE_TREE" >&2
        return 1
    fi

    if ! bash "${REPO_ROOT}/install/ops-install.sh"; then
        printf 'fresh-install acceptance failed while running install/ops-install.sh\n' >&2
        return 1
    fi
}

case_accept_fresh_03_expected_artefacts_exist_after_install() {
    [[ -x /usr/local/bin/ops ]] || test::request_skip 'installer has not been run in this acceptance session yet'
    [[ -x "${OPS_ACCEPT_LIVE_TREE}/bin/ops" ]] || { printf 'missing live ops entrypoint at %s/bin/ops\n' "$OPS_ACCEPT_LIVE_TREE" >&2; return 1; }
    [[ -f /etc/ops/ops.conf ]] || { printf 'missing /etc/ops/ops.conf after install\n' >&2; return 1; }
}

test::run_case 'ACCEPT-FRESH-01' 'fresh-install acceptance requires explicit confirmation' case_accept_fresh_01_requires_explicit_mutation_confirmation
test::run_case 'ACCEPT-FRESH-02' 'repo installer runs on a clean Ubuntu snapshot when confirmed' case_accept_fresh_02_run_repo_installer_on_clean_snapshot
test::run_case 'ACCEPT-FRESH-03' 'expected OPS artefacts exist after fresh install' case_accept_fresh_03_expected_artefacts_exist_after_install

test::finish
