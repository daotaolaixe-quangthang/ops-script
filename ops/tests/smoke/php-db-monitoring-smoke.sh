#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ops/tests/regression/lib.sh
source "${SCRIPT_DIR}/../regression/lib.sh"

TEST_SUITE_NAME="php-db-monitoring-smoke"
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

case_platform_smoke_01_verify_stack_emits_php_db_monitoring_summary() {
    local output status summary
    output="$(smoke_run_verify_stack platform-verify)"
    IFS=$'\037' read -r status summary <<< "$output"
    test::assert_eq '0' "$status" 'verify_stack must exit 0 in php/db/monitoring smoke flow' || return 1
    test::assert_contains "$summary" 'PHP-FPM' 'platform smoke must render PHP-FPM verify output' || return 1
    test::assert_contains "$summary" 'Database' 'platform smoke must render database verify output' || return 1
    test::assert_contains "$summary" 'OS Patches' 'platform smoke must render patch-state verify output' || return 1
}

case_platform_smoke_02_php_fpm_configs_validate_if_present() {
    local cmd found=0
    while IFS= read -r cmd; do
        [[ -n "$cmd" ]] || continue
        found=1
        if ! "$cmd" -t >/dev/null 2>&1; then
            printf '%s -t failed on the live host\n' "$cmd" >&2
            return 1
        fi
    done < <(compgen -c | awk '/^php-fpm[0-9]+\.[0-9]+$/ {print $0}' | sort -u)
    [[ "$found" -eq 1 ]] || test::request_skip 'no php-fpm<version> binaries are installed on this host'
}

case_platform_smoke_03_ops_logrotate_debug_if_present() {
    test::require_command logrotate || return $?
    [[ -f /etc/logrotate.d/ops ]] || test::request_skip '/etc/logrotate.d/ops is not present on this host'
    if ! logrotate -d /etc/logrotate.d/ops >/dev/null 2>&1; then
        printf 'logrotate -d /etc/logrotate.d/ops failed on the live host\n' >&2
        return 1
    fi
}

test::run_case 'PLATFORM-SMOKE-01' 'verify_stack emits PHP/DB/monitoring summary' case_platform_smoke_01_verify_stack_emits_php_db_monitoring_summary
test::run_case 'PLATFORM-SMOKE-02' 'php-fpm configs validate when installed' case_platform_smoke_02_php_fpm_configs_validate_if_present
test::run_case 'PLATFORM-SMOKE-03' 'OPS logrotate config debugs cleanly when present' case_platform_smoke_03_ops_logrotate_debug_if_present

test::finish
