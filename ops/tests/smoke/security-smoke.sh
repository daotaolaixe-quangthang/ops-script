#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ops/tests/regression/lib.sh
source "${SCRIPT_DIR}/../regression/lib.sh"

TEST_SUITE_NAME="security-smoke"
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

case_security_smoke_01_verify_stack_live_security_summary() {
    local output status summary
    test::require_command sshd || return $?
    test::require_command ss || return $?
    output="$(smoke_run_verify_stack security-verify)"
    IFS=$'\037' read -r status summary <<< "$output"
    test::assert_eq '0' "$status" 'verify_stack must exit 0 in security smoke flow' || return 1
    test::assert_contains "$summary" 'SSH' 'security smoke must render SSH verify output' || return 1
    test::assert_contains "$summary" 'UFW' 'security smoke must render UFW verify output' || return 1
    test::assert_contains "$summary" 'fail2ban' 'security smoke must render fail2ban verify output' || return 1
}

case_security_smoke_02_sshd_config_valid_if_present() {
    test::require_command sshd || return $?
    test::require_root || return $?
    if ! sshd -t >/dev/null 2>&1; then
        printf 'sshd -t failed on the live host\n' >&2
        return 1
    fi
}

test::run_case 'SEC-SMOKE-01' 'verify_stack emits security summary on live host' case_security_smoke_01_verify_stack_live_security_summary
test::run_case 'SEC-SMOKE-02' 'sshd config validates on live host' case_security_smoke_02_sshd_config_valid_if_present

test::finish
