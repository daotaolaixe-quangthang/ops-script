#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ops/tests/regression/lib.sh
source "${SCRIPT_DIR}/../regression/lib.sh"

TEST_SUITE_NAME="acceptance-high-risk-runtime"
test::init

acceptance_run_verify_stack() {
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

case_accept_runtime_01_verify_stack_reports_all_high_risk_layers() {
    local output status summary
    output="$(acceptance_run_verify_stack runtime-verify)"
    IFS=$'\037' read -r status summary <<< "$output"
    test::assert_eq '0' "$status" 'verify_stack must exit 0 during runtime acceptance' || return 1
    test::assert_contains "$summary" 'SSH' 'runtime acceptance must render SSH verify output' || return 1
    test::assert_contains "$summary" 'Nginx' 'runtime acceptance must render Nginx verify output' || return 1
    test::assert_contains "$summary" 'PHP-FPM' 'runtime acceptance must render PHP-FPM verify output' || return 1
    test::assert_contains "$summary" 'Database' 'runtime acceptance must render database verify output' || return 1
    test::assert_contains "$summary" 'CLIProxyAPI' 'runtime acceptance must render CLIProxyAPI verify output' || return 1
}

case_accept_runtime_02_sshd_config_valid_if_present() {
    test::require_command sshd || return $?
    test::require_root || return $?
    if ! sshd -t >/dev/null 2>&1; then
        printf 'sshd -t failed during runtime acceptance\n' >&2
        return 1
    fi
}

case_accept_runtime_03_nginx_config_valid_if_present() {
    test::require_command nginx || return $?
    test::require_root || return $?
    if ! nginx -t >/dev/null 2>&1; then
        printf 'nginx -t failed during runtime acceptance\n' >&2
        return 1
    fi
}

case_accept_runtime_04_cliproxyapi_loopback_only_if_listening() {
    local listeners
    test::require_command ss || return $?
    listeners="$(ss -tln 2>/dev/null | awk '$4 ~ /:8317$/ {print $4}')"
    [[ -n "$listeners" ]] || test::request_skip 'port 8317 is not listening on this host'
    while IFS= read -r listener; do
        case "$listener" in
            127.0.0.1:8317|[::1]:8317) ;;
            *)
                printf 'CLIProxyAPI listener is public or unexpected: %s\n' "$listener" >&2
                return 1
                ;;
        esac
    done <<< "$listeners"
}

test::run_case 'ACCEPT-RUNTIME-01' 'verify_stack reports all high-risk layers' case_accept_runtime_01_verify_stack_reports_all_high_risk_layers
test::run_case 'ACCEPT-RUNTIME-02' 'sshd config validates during runtime acceptance' case_accept_runtime_02_sshd_config_valid_if_present
test::run_case 'ACCEPT-RUNTIME-03' 'nginx config validates during runtime acceptance' case_accept_runtime_03_nginx_config_valid_if_present
test::run_case 'ACCEPT-RUNTIME-04' 'CLIProxyAPI stays loopback-only when listening' case_accept_runtime_04_cliproxyapi_loopback_only_if_listening

test::finish
