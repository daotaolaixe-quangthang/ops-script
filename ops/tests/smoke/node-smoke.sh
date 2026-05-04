#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ops/tests/regression/lib.sh
source "${SCRIPT_DIR}/../regression/lib.sh"

TEST_SUITE_NAME="node-smoke"
test::init

smoke_run_verify_stack() {
    local label="$1"
    OPS_ROOT_ENV="$OPS_ROOT" TEST_TMP="$TEST_ENV_DIR" bash -c '
set -euo pipefail
label="$1"
work_dir="$TEST_TMP/${label}"
mkdir -p "$work_dir/conf"
print_section() { printf "%s\n" "$1"; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }
print_error() { printf "%s\n" "$*" >&2; }
print_warn() { printf "%s\n" "$*" >&2; }
export OPS_ROOT="$OPS_ROOT_ENV"
export OPS_CONFIG_DIR="$work_dir/conf"
export OPS_LOG_FILE="$work_dir/test.log"
export ADMIN_USER="${SUDO_USER:-${USER:-nobody}}"
export SUDO_USER="${SUDO_USER:-${USER:-nobody}}"
export USER="${USER:-nobody}"
source "$OPS_ROOT_ENV/core/env.sh"
source "$OPS_ROOT_ENV/core/ui.sh"
source "$OPS_ROOT_ENV/core/utils.sh"
source "$OPS_ROOT_ENV/core/system.sh"
source "$OPS_ROOT_ENV/modules/security.sh"
source "$OPS_ROOT_ENV/modules/nginx.sh"
source "$OPS_ROOT_ENV/modules/node.sh"
source "$OPS_ROOT_ENV/modules/php.sh"
source "$OPS_ROOT_ENV/modules/database.sh"
source "$OPS_ROOT_ENV/modules/cli-proxy-api.sh"
source "$OPS_ROOT_ENV/modules/monitoring.sh"
source "$OPS_ROOT_ENV/modules/verify.sh"
set +e
verify_stack > "$work_dir/output.txt"
status=$?
set -e
printf "%s\037%s" "$status" "$(tr "\n" "\f" < "$work_dir/output.txt")"
' bash "$label"
}

case_node_smoke_01_verify_stack_emits_pm2_runtime_summary() {
    local output status summary
    output="$(smoke_run_verify_stack node-verify)"
    IFS=$'\037' read -r status summary <<< "$output"
    test::assert_eq '0' "$status" 'verify_stack must exit 0 in node smoke flow' || return 1
    test::assert_contains "$summary" 'PM2' 'node smoke must render PM2 verify output' || return 1
    test::assert_contains "$summary" 'Runtime User' 'node smoke must render runtime-user verify output' || return 1
}

case_node_smoke_02_pm2_root_service_absent_when_pm2_units_exist() {
    local unit_list
    test::require_command systemctl || return $?
    unit_list="$(systemctl list-unit-files 'pm2-*.service' --no-legend 2>/dev/null | awk '{print $1}')"
    [[ -n "$unit_list" ]] || test::request_skip 'no PM2 systemd units are installed on this host'
    test::assert_not_contains "$unit_list" 'pm2-root.service' 'pm2-root.service must not be present in live PM2 unit inventory' || return 1
}

test::run_case 'NODE-SMOKE-01' 'verify_stack emits PM2/runtime-user summary' case_node_smoke_01_verify_stack_emits_pm2_runtime_summary
test::run_case 'NODE-SMOKE-02' 'pm2-root service stays absent when PM2 is installed' case_node_smoke_02_pm2_root_service_absent_when_pm2_units_exist

test::finish
