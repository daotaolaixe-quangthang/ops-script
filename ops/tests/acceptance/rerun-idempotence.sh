#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ops/tests/regression/lib.sh
source "${SCRIPT_DIR}/../regression/lib.sh"

TEST_SUITE_NAME="acceptance-rerun-idempotence"
OPS_ACCEPT_LIVE_TREE="${OPS_ACCEPT_LIVE_TREE:-/opt/ops}"
OPS_ACCEPT_CONFIRM_MUTATION="${OPS_ACCEPT_CONFIRM_MUTATION:-0}"
test::init

acceptance_mutation_confirmed() {
    case "$OPS_ACCEPT_CONFIRM_MUTATION" in
        1|yes|true|YES) return 0 ;;
        *) return 1 ;;
    esac
}

case_accept_rerun_01_live_tree_present() {
    [[ -x "${OPS_ACCEPT_LIVE_TREE}/bin/ops-setup.sh" ]] || test::request_skip "live OPS tree not found at ${OPS_ACCEPT_LIVE_TREE}; run fresh-install acceptance first"
}

case_accept_rerun_02_ops_setup_reruns_cleanly_when_confirmed() {
    test::require_root || return $?
    acceptance_mutation_confirmed || test::request_skip 'set OPS_ACCEPT_CONFIRM_MUTATION=YES before rerunning ops-setup.sh on a disposable Ubuntu snapshot'
    [[ -x "${OPS_ACCEPT_LIVE_TREE}/bin/ops-setup.sh" ]] || return 200

    bash "${OPS_ACCEPT_LIVE_TREE}/bin/ops-setup.sh"
    bash "${OPS_ACCEPT_LIVE_TREE}/bin/ops-setup.sh"
}

case_accept_rerun_03_managed_entrypoints_and_logs_still_exist() {
    [[ -x /usr/local/bin/ops ]] || test::request_skip 'managed symlink /usr/local/bin/ops is not present on this host'
    [[ -x /usr/local/bin/ops-dashboard ]] || { printf 'missing /usr/local/bin/ops-dashboard after rerun\n' >&2; return 1; }
    [[ -d /var/log/ops ]] || { printf 'missing /var/log/ops after rerun\n' >&2; return 1; }
    [[ -f /etc/ops/ops.conf ]] || { printf 'missing /etc/ops/ops.conf after rerun\n' >&2; return 1; }
}

test::run_case 'ACCEPT-RERUN-01' 'live OPS tree is present before rerun acceptance' case_accept_rerun_01_live_tree_present
test::run_case 'ACCEPT-RERUN-02' 'ops-setup.sh reruns cleanly when confirmed' case_accept_rerun_02_ops_setup_reruns_cleanly_when_confirmed
test::run_case 'ACCEPT-RERUN-03' 'managed entrypoints and logs still exist after rerun' case_accept_rerun_03_managed_entrypoints_and_logs_still_exist

test::finish
