#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ops/tests/regression/lib.sh
source "${SCRIPT_DIR}/lib.sh"

TEST_SUITE_NAME="reg-suite"
test::init

REG_MENU_MODULES=(
    'modules/setup-wizard.sh'
    'modules/security.sh'
    'modules/nginx.sh'
    'modules/node.sh'
    'modules/cli-proxy-api.sh'
    'modules/php.sh'
    'modules/database.sh'
    'modules/monitoring.sh'
    'modules/checks.sh'
    'modules/backup.sh'
    'modules/codex-cli.sh'
    'modules/ai-agent.sh'
)

reg_scan_read_p_hits() {
    OPS_ROOT_ENV="$OPS_ROOT" python3 - <<'PY'
import os
import re
from pathlib import Path

root = Path(os.environ['OPS_ROOT_ENV'])
pattern = re.compile(r'\bread\b[^\n#]*\s-p(?:\s|$)')
for rel in ('bin', 'core', 'modules'):
    for path in sorted((root / rel).rglob('*.sh')):
        for lineno, line in enumerate(path.read_text().splitlines(), 1):
            if pattern.search(line):
                print(f'{path}:{lineno}:{line}')
PY
}

reg_menu_boundary_failures() {
    test::menu_boundary_failures "$OPS_ROOT" "${REG_MENU_MODULES[@]}"
}

case_reg_01_tty_prompt_antipattern_absent() {
    local hits
    hits="$(reg_scan_read_p_hits)"
    test::assert_eq "" "$hits" "prompt anti-pattern must stay absent" || return 1
}

case_reg_02_menu_boundary_wrapper_present() {
    local failures
    failures="$(reg_menu_boundary_failures)"
    test::assert_eq "" "$failures" "all public menu_* functions must normalize soft failures locally" || return 1
}

case_reg_03_verify_exit_zero_contract_documented_in_code() {
    local content output status summary
    content="$(<"${OPS_ROOT}/modules/verify.sh")"
    test::assert_contains "$content" 'return 0' 'verify functions must return 0' || return 1
    test::assert_contains "$content" '_vs_fail' 'verify fail formatter missing' || return 1
    test::assert_contains "$content" '_vs_warn' 'verify warn formatter missing' || return 1

    output="$(OPS_ROOT_ENV="$OPS_ROOT" TEST_TMP="$TEST_ENV_DIR" bash -c '
set -euo pipefail
work_dir="$TEST_TMP/verify-stack"
mkdir -p "$work_dir"
print_section() { printf "%s\n" "$1"; }
log_info() { :; }
source "$OPS_ROOT_ENV/modules/verify.sh"
_vs_check_ssh() { _vs_pass "SSH" "ok"; _vs_set_result pass; return 0; }
_vs_check_ufw() { _vs_warn "UFW" "warn" "review"; _vs_set_result warn; return 0; }
_vs_check_fail2ban() { _vs_fail "Fail2ban" "fail" "fix"; _vs_set_result fail; return 0; }
_vs_check_nginx() { _vs_pass "Nginx" "ok"; _vs_set_result pass; return 0; }
_vs_check_pm2() { _vs_pass "PM2" "ok"; _vs_set_result pass; return 0; }
_vs_check_runtime_user() { _vs_pass "Runtime User" "ok"; _vs_set_result pass; return 0; }
_vs_check_cliproxyapi() { _vs_pass "CLIProxyAPI" "ok"; _vs_set_result pass; return 0; }
_vs_check_php_fpm() { _vs_pass "PHP-FPM" "ok"; _vs_set_result pass; return 0; }
_vs_check_mariadb() { _vs_pass "MariaDB" "ok"; _vs_set_result pass; return 0; }
_vs_check_ssl() { _vs_pass "SSL" "ok"; _vs_set_result pass; return 0; }
_vs_check_sysctl_swap() { _vs_pass "Sysctl/Swap" "ok"; _vs_set_result pass; return 0; }
_vs_check_patch_state() { _vs_pass "Patch State" "ok"; _vs_set_result pass; return 0; }
_vs_check_monitoring() { return 0; }
set +e
verify_stack > "$work_dir/output.txt"
status=$?
set -e
summary="$(tr "\n" "\f" < "$work_dir/output.txt")"
printf "%s\037%s" "$status" "$summary"
')"
    IFS=$'\037' read -r status summary <<< "$output"
    test::assert_eq '0' "$status" 'verify_stack must exit 0 even when checks warn/fail' || return 1
    test::assert_contains "$summary" 'Summary:' 'verify_stack summary missing' || return 1
    test::assert_contains "$summary" '1 WARN' 'verify_stack warn tally missing' || return 1
    test::assert_contains "$summary" '1 FAIL' 'verify_stack fail tally missing' || return 1
}

case_reg_04_security_guard_present_before_disable_password_auth() {
    local content installer_content
    content="$(<"${OPS_ROOT}/modules/security.sh")"
    installer_content="$(<"${REPO_ROOT}/install/ops-install.sh")"
    test::assert_contains "$content" '_security_has_authorized_keys' 'authorized key guard missing' || return 1
    test::assert_contains "$content" 'PasswordAuthentication' 'password auth control missing' || return 1
    test::assert_contains "$installer_content" 'Installer keeps PasswordAuthentication=yes until the wizard/security flow finalizes SSH access.' 'installer must keep PasswordAuthentication=yes during bootstrap' || return 1
    test::assert_not_contains "$installer_content" 'SSH key was configured — disabling PasswordAuthentication.' 'installer must not disable password auth just because a key was pasted' || return 1
}

case_reg_05_login_hook_uses_ssh_connection_not_ssh_tty_doc_contract() {
    local content
    content="$(<"${REPO_ROOT}/docs/operator/MENU-REFERENCE.md")"
    test::assert_contains "$content" 'SSH_CONNECTION' 'login hook must use SSH_CONNECTION contract' || return 1
    test::assert_contains "$content" 'display-only' 'login hook must stay display-only' || return 1
}

case_reg_06_cliproxyapi_posture_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/verify.sh")"
    test::assert_contains "$content" '8317/tcp' 'verify must check public exposure of 8317' || return 1
    test::assert_contains "$content" 'remove allow rule and keep only nginx public' 'verify hint for 8317 exposure missing' || return 1
}

case_reg_07_pm2_startup_not_root_contract_present() {
    local content node_content
    content="$(<"${REPO_ROOT}/docs/reference/KNOWN-RISKS-PATTERNS.md")"
    node_content="$(<"${OPS_ROOT}/modules/node.sh")"
    test::assert_contains "$content" 'pm2-root.service' 'pm2 root startup regression coverage missing in KNOWN-RISKS' || return 1
    # Assert the actual code passes -u <runtime_user> — not root — to pm2 startup.
    test::assert_contains "$node_content" 'pm2 startup systemd -u "$runtime_user"' 'node_install_pm2 must pass runtime_user to pm2 startup, not root' || return 1
}

case_reg_08_pm2_runtime_user_wrapper_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/verify.sh")"
    test::assert_contains "$content" '_vs_run_as_runtime_user' 'runtime user wrapper missing' || return 1
}

case_reg_09_secret_permission_contract_present() {
    local database_content cliproxyapi_content codex_content
    database_content="$(<"${OPS_ROOT}/modules/database.sh")"
    cliproxyapi_content="$(<"${OPS_ROOT}/modules/cli-proxy-api.sh")"
    codex_content="$(<"${OPS_ROOT}/modules/codex-cli.sh")"

    test::assert_contains "$database_content" '_db_secret_owner()' 'database secret ownership helper missing' || return 1
    test::assert_contains "$database_content" 'chmod 600 "$path"' 'database secret writer must enforce 0600' || return 1
    test::assert_contains "$database_content" 'chown "$owner":"$owner" "$path"' 'database secret writer must preserve admin-owned secrets' || return 1
    test::assert_contains "$cliproxyapi_content" 'chown "$ADMIN_USER:$ADMIN_USER" "$CLIPROXYAPI_CLIENT_KEY_FILE"' 'CLIProxyAPI secret owner contract missing' || return 1
    test::assert_contains "$codex_content" 'chown "$ADMIN_USER:$ADMIN_USER" "$CODEX_API_KEY_FILE"' 'Codex secret owner contract missing' || return 1
}

case_reg_10_config_rewrite_must_validate_syntax() {
    local db_content php_content nginx_content validation_count
    db_content="$(<"${OPS_ROOT}/modules/database.sh")"
    php_content="$(<"${OPS_ROOT}/modules/php.sh")"
    nginx_content="$(<"${OPS_ROOT}/modules/nginx.sh")"
    validation_count="$(OPS_ROOT_ENV="$OPS_ROOT" python3 - <<'PY'
import os
from pathlib import Path
text = (Path(os.environ['OPS_ROOT_ENV']) / 'modules/database.sh').read_text()
print(text.count('_db_validate_mariadb_config || return 1'))
PY
)"
    test::assert_contains "$db_content" '_db_validate_mariadb_config()' 'shared MariaDB config validation helper missing' || return 1
    test::assert_eq "4" "$validation_count" 'MariaDB rewrite/restart paths must validate config before restart' || return 1
    test::assert_contains "$php_content" 'php_fpm_validate_and_apply()' 'PHP config rewrite validation/apply helper missing' || return 1
    test::assert_contains "$php_content" 'snapshot_path_state' 'PHP config rewrite snapshot helper missing' || return 1
    test::assert_contains "$php_content" 'restore_path_snapshot' 'PHP config rewrite rollback helper missing' || return 1
    test::assert_contains "$nginx_content" '_nginx_commit_vhost' 'Nginx transactional commit helper missing' || return 1
}

case_reg_11_cliproxyapi_vhost_preserves_global_rate_limit_zone() {
    local content
    content="$(<"${OPS_ROOT}/modules/templates/nginx/cli-proxy-api.vhost.conf.tpl")"
    test::assert_contains "$content" 'cli-proxy-api.' 'CLIProxyAPI vhost naming contract missing' || return 1
    test::assert_contains "$content" 'listen [::]:80;' 'CLIProxyAPI HTTP vhost must expose dual-stack listener' || return 1
    test::assert_contains "$content" 'proxy_buffering       off' 'CLIProxyAPI proxy buffering contract missing' || return 1
}

case_reg_12_pm2_logrotate_and_merge_logs_contract_present() {
    local content node_content monitoring_content
    content="$(<"${REPO_ROOT}/docs/reference/KNOWN-RISKS-PATTERNS.md")"
    node_content="$(<"${OPS_ROOT}/modules/node.sh")"
    monitoring_content="$(<"${OPS_ROOT}/modules/monitoring.sh")"
    test::assert_contains "$content" 'pm2-logrotate' 'pm2 logrotate regression contract missing' || return 1
    test::assert_contains "$content" 'merge_logs: true' 'merge_logs regression contract missing' || return 1
    test::assert_contains "$content" '/var/log/ops/pm2-<app>-{out,err}.log' 'PM2 per-app log path risk contract missing' || return 1
    # Assert inline fallback path in node.sh also sets merge_logs (template is checked by NODE-08).
    test::assert_contains "$node_content" 'merge_logs:           true' 'node.sh inline fallback ecosystem must include merge_logs: true' || return 1
    test::assert_contains "$node_content" '_node_prepare_pm2_log_files' 'node module must prepare PM2 per-app log files before app start' || return 1
    test::assert_contains "$monitoring_content" '_monitoring_reconcile_pm2_app_logs()' 'monitoring baseline must reconcile PM2 app log files for existing apps' || return 1
}

case_reg_13_pm2_read_helpers_centralized() {
    local system_content verify_content cliproxyapi_content
    system_content="$(<"${OPS_ROOT}/core/system.sh")"
    verify_content="$(<"${OPS_ROOT}/modules/verify.sh")"
    cliproxyapi_content="$(<"${OPS_ROOT}/modules/cli-proxy-api.sh")"

    test::assert_contains "$system_content" 'service_active()' 'shared systemd active helper missing' || return 1
    test::assert_contains "$system_content" 'service_restart()' 'shared systemd restart helper missing' || return 1
    test::assert_contains "$verify_content" 'systemctl is-active cli-proxy-api' 'verify must inspect CLIProxyAPI systemd status' || return 1
    test::assert_contains "$cliproxyapi_content" 'service_restart "$CLIPROXYAPI_SERVICE_NAME"' 'CLIProxyAPI service restart contract missing' || return 1
}

case_reg_14_patch_state_check_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/verify.sh")"
    test::assert_contains "$content" '_vs_check_patch_state' 'patch state check missing in verify.sh' || return 1
    test::assert_contains "$content" 'reboot-required' 'reboot-required detection missing in verify.sh' || return 1
}

case_reg_15_runtime_user_check_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/verify.sh")"
    test::assert_contains "$content" '_vs_check_runtime_user' 'runtime user check missing in verify.sh' || return 1
    test::assert_contains "$content" 'OPS_RUNTIME_USER' 'ops.conf reference missing in runtime user check' || return 1
}

case_reg_15_1_menu_boundary_contract_not_hidden_in_callers() {
    local content failures
    content="$(<"${OPS_ROOT}/bin/ops")"
    test::assert_not_contains "$content" 'menu_setup_wizard || true' 'main menu must not hide setup wizard boundary failures' || return 1
    test::assert_not_contains "$content" 'menu_monitoring || true' 'main menu must not hide monitoring boundary failures' || return 1
    test::assert_not_contains "$content" 'menu_security || true' 'main menu must not hide security boundary failures' || return 1

    failures="$(reg_menu_boundary_failures)"
    test::assert_eq "" "$failures" 'menu boundary contract must live in the menu itself, not in the caller' || return 1
}

case_reg_16_local_client_setup_contracts_present() {
    local cliproxyapi_content claude_content codex_content
    cliproxyapi_content="$(<"${OPS_ROOT}/modules/cli-proxy-api.sh")"
    claude_content="$(<"${OPS_ROOT}/modules/ai-agent.sh")"
    codex_content="$(<"${OPS_ROOT}/modules/codex-cli.sh")"

    test::assert_contains "$cliproxyapi_content" $'toggle_cliproxyapi_api_key() {\n    require_root || return 1' 'CLIProxyAPI API key toggle must require root' || return 1
    test::assert_not_contains "$cliproxyapi_content" 'service_restart "$CLIPROXYAPI_SERVICE_NAME" 10 > /dev/null || true' 'CLIProxyAPI API key activation must not swallow restart failures' || return 1
    test::assert_contains "$cliproxyapi_content" $'if ! service_active "$CLIPROXYAPI_SERVICE_NAME"; then\n        log_error "CLIProxyAPI is not active after start. Last journal entries:"' 'CLIProxyAPI start must fail when service stays inactive' || return 1
    test::assert_contains "$cliproxyapi_content" $'journalctl -u "$CLIPROXYAPI_SERVICE_NAME" -n 20 --no-pager 2>/dev/null || true\n        return 1' 'CLIProxyAPI start failure path must return non-zero' || return 1
    test::assert_not_contains "$cliproxyapi_content" '--claude-login" || true' 'CLIProxyAPI auth bootstrap must not swallow Claude login failures' || return 1
    test::assert_not_contains "$cliproxyapi_content" '--codex-login" || true' 'CLIProxyAPI auth bootstrap must not swallow Codex login failures' || return 1
    test::assert_contains "$cliproxyapi_content" 'Auth bootstrap failed for one or more providers' 'CLIProxyAPI auth bootstrap failure message missing' || return 1
    test::assert_contains "$claude_content" '_cliproxyapi_activate_api_key || return 1' 'Claude local setup must fail when API key activation fails' || return 1
    test::assert_contains "$codex_content" 'CLIProxyAPI service is not running. Install/start it from menu 5 before using Codex CLI.' 'Codex local setup must warn when CLIProxyAPI is inactive' || return 1
    test::assert_contains "$codex_content" '_cliproxyapi_activate_api_key || return 1' 'Codex local setup must fail when API key activation fails' || return 1
}

case_reg_27_tty_prompt_contract_stays_centralized() {
    local ui_content hits
    ui_content="$(<"${OPS_ROOT}/core/ui.sh")"
    test::assert_contains "$ui_content" 'prompt_menu_choice()' 'shared menu choice helper missing in core/ui.sh' || return 1
    test::assert_contains "$ui_content" 'tty_read()' 'shared tty read helper missing in core/ui.sh' || return 1
    test::assert_contains "$ui_content" 'tty_write()' 'shared tty write helper missing in core/ui.sh' || return 1

    hits="$(reg_scan_read_p_hits)"
    test::assert_eq "" "$hits" 'tty prompt code must not regress to read -p usage' || return 1
}

case_sec_01_password_auth_guard_without_key_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/security.sh")"
    test::assert_contains "$content" "_security_has_authorized_keys" 'authorized key helper missing' || return 1
    test::assert_contains "$content" 'PasswordAuthentication will remain ENABLED to prevent SSH lockout.' 'safe password auth fallback missing' || return 1
    test::assert_contains "$content" 'Falling back to PasswordAuthentication=yes during the port change to prevent SSH lockout.' 'port-change key revalidation fallback missing' || return 1
}

case_sec_02_disable_password_auth_requires_key_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/security.sh")"
    test::assert_contains "$content" 'Disable PasswordAuthentication after transition completes?' 'disable password auth prompt missing' || return 1
}

case_sec_03_transition_keeps_two_ports_contract_present() {
    local content installer_content output keep_transition no_transition keep_yes
    content="$(<"${OPS_ROOT}/modules/security.sh")"
    installer_content="$(<"${REPO_ROOT}/install/ops-install.sh")"
    test::assert_contains "$content" 'OPS_SSH_TRANSITION_PORT' 'transition port state missing' || return 1
    test::assert_contains "$content" 'security_effective_password_auth()' 'transition password-auth helper missing' || return 1
    test::assert_contains "$content" 'Transition safety: keep only managed transition ports until login is verified on port $new_port.' 'transition safety contract missing' || return 1
    test::assert_contains "$installer_content" 'SSH_BOOTSTRAP_MODE="ambiguous"' 'installer must model ambiguous multi-port bootstrap state explicitly' || return 1
    test::assert_contains "$installer_content" 'SSH_BOOTSTRAP_PORTS=("${SSH_CURRENT_PORTS[@]}")' 'installer must preserve all detected live SSH ports during bootstrap' || return 1
    test::assert_contains "$installer_content" 'Bootstrap will preserve all live SSH access and will not rewrite OPS_SSH_PORT / OPS_SSH_TRANSITION_PORT on this run.' 'installer multi-port preservation contract missing' || return 1

    output="$(OPS_ROOT_ENV="$OPS_ROOT" TEST_TMP="$TEST_ENV_DIR" bash -c '
set -euo pipefail
work_dir="$TEST_TMP/security-transition"
mkdir -p "$work_dir/conf"
export OPS_ROOT="$OPS_ROOT_ENV"
export OPS_CONFIG_DIR="$work_dir/conf"
export OPS_LOG_FILE="$work_dir/test.log"
export ADMIN_USER="nobody"
export SUDO_USER="nobody"
export USER="nobody"
source "$OPS_ROOT_ENV/core/env.sh"
source "$OPS_ROOT_ENV/modules/security.sh"
printf "%s\037%s\037%s" \
    "$(security_effective_password_auth no 2222 22)" \
    "$(security_effective_password_auth no 2222 2222)" \
    "$(security_effective_password_auth yes 2222 '')"
')"
    IFS=$'\037' read -r keep_transition no_transition keep_yes <<< "$output"
    test::assert_eq 'yes' "$keep_transition" 'transition port must force PasswordAuthentication=yes until finalize' || return 1
    test::assert_eq 'no' "$no_transition" 'steady-state port must honor desired password auth after transition closes' || return 1
    test::assert_eq 'yes' "$keep_yes" 'desired yes state must remain yes without a transition port' || return 1
}

case_sec_04_finalize_transition_contract_present() {
    local content wrapper_content
    content="$(<"${OPS_ROOT}/modules/security.sh")"
    wrapper_content="$(<"${OPS_ROOT}/bin/ops-ssh-finalize.sh")"
    test::assert_contains "$content" 'Finalize SSH transition and remove old port' 'finalize SSH prompt missing' || return 1
    test::assert_contains "$content" 'UFW finalize failed while closing the old SSH transition port. Restoring previous SSH and firewall state.' 'finalize must roll back when UFW finalization fails' || return 1
    test::assert_contains "$content" 'security_apply_fail2ban_ssh_state' 'finalize must refresh fail2ban before success' || return 1
    test::assert_contains "$content" 'apt_install fail2ban' 'finalize must install fail2ban when it is absent' || return 1
    test::assert_contains "$content" 'fail2ban-client status sshd' 'finalize must require active fail2ban sshd jail before success' || return 1
    test::assert_contains "$content" 'Cannot finalize SSH transition while PasswordAuthentication is still enabled for the final steady state.' 'finalize must refuse insecure steady-state password auth' || return 1
    test::assert_contains "$content" "Use Security -> Manage SSH Keys and choose 'Disable PasswordAuthentication after transition completes' first." 'finalize must guide operators to disable password auth before steady state' || return 1
    test::assert_contains "$content" 'Cannot finalize SSH transition: no valid SSH key is authorized for' 'finalize must require a valid admin SSH key before success' || return 1
    test::assert_contains "$content" 'Restoring previous SSH, firewall, fail2ban, and OPS SSH state.' 'finalize rollback message missing' || return 1
    test::assert_contains "$content" 'Old SSH port ${old_port} removed from managed config and firewall.' 'port finalization success message missing' || return 1
    test::assert_contains "$wrapper_content" 'security_finalize_ssh_transition' 'legacy finalize wrapper must use the gated finalize path' || return 1
    test::assert_not_contains "$wrapper_content" 'security_finalize_ssh_transition_apply' 'legacy finalize wrapper must not bypass the finalize confirmation gate' || return 1
}

case_sec_05_ufw_baseline_ports_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/security.sh")"
    test::assert_contains "$content" 'ufw_allow 80/tcp "HTTP"' 'HTTP allow baseline wrapper missing' || return 1
    test::assert_contains "$content" 'ufw_allow 443/tcp "HTTPS"' 'HTTPS allow baseline wrapper missing' || return 1
}

case_sec_06_ufw_must_not_allow_8317() {
    local content security_content
    content="$(<"${OPS_ROOT}/modules/cli-proxy-api.sh")"
    security_content="$(<"${OPS_ROOT}/modules/security.sh")"
    test::assert_contains "$content" 'ufw delete allow 8317/tcp' '8317 ALLOW cleanup missing' || return 1
    test::assert_contains "$security_content" 'ufw delete allow 8317/tcp' 'security module must remove public ALLOW 8317/tcp rules' || return 1
    test::assert_not_contains "$security_content" 'ufw_deny 8317/tcp' 'security module must not force a DENY 8317/tcp rule' || return 1
}

case_sec_07_fail2ban_tracks_managed_ports() {
    local content
    content="$(<"${OPS_ROOT}/modules/verify.sh")"
    test::assert_contains "$content" 'sshd jail ports do not match OPS state' 'fail2ban managed port verify missing' || return 1
}

case_sec_08_permit_root_login_disabled_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/security.sh")"
    test::assert_contains "$content" 'PermitRootLogin no' 'PermitRootLogin hardening missing' || return 1
}

case_sec_09_forwarding_disabled_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/security.sh")"
    test::assert_contains "$content" 'X11Forwarding no' 'X11 forwarding hardening missing' || return 1
    test::assert_contains "$content" 'echo "${val:-no}"' 'TCP forwarding must default to no when OPS state is unset' || return 1
    test::assert_contains "$content" 'AllowAgentForwarding no' 'agent forwarding hardening missing' || return 1
}

case_sec_09_1_keep_current_port_22_contract_present() {
    local content validation_call_count
    content="$(<"${OPS_ROOT}/modules/security.sh")"
    validation_call_count="$(OPS_ROOT_ENV="$OPS_ROOT" python3 - <<'PY'
import os
from pathlib import Path
text = (Path(os.environ['OPS_ROOT_ENV']) / 'modules/security.sh').read_text()
print(text.count('security_validate_ssh_port "$new_port" "$current_port"'))
PY
)"

    test::assert_eq "3" "$validation_call_count" 'all SSH port entry points must pass current port to the validator' || return 1
    test::assert_contains "$content" 'unless you are preserving the current managed port' 'keep-current-port privileged-port exception missing' || return 1
}

case_sec_09_2_authorized_key_matchers_cover_modern_key_types() {
    local security_content installer_content
    security_content="$(<"${OPS_ROOT}/modules/security.sh")"
    installer_content="$(<"${REPO_ROOT}/install/ops-install.sh")"

    test::assert_contains "$security_content" 'sk-ecdsa-sha2-nistp256@openssh\.com' 'security SSH key matcher must cover security key-backed ECDSA keys' || return 1
    test::assert_contains "$security_content" '_security_authorized_key_line_is_valid "$new_key"' 'security SSH key add path must reuse the shared matcher' || return 1
    test::assert_contains "$installer_content" 'installer_authorized_key_line_is_valid()' 'installer SSH key matcher helper missing' || return 1
    test::assert_contains "$installer_content" 'sk-ecdsa-sha2-nistp256@openssh\.com' 'installer SSH key matcher must cover security key-backed ECDSA keys' || return 1
}

case_sec_09_3_ssh_state_persists_only_after_full_success() {
    local failures
    failures="$(OPS_ROOT_ENV="$OPS_ROOT" python3 - <<'PY'
import os
from pathlib import Path
text = (Path(os.environ['OPS_ROOT_ENV']) / 'modules/security.sh').read_text()
issues = []

apply_start = text.index('security_apply_sshd_hardening() {')
apply_end = text.index('menu_security() {', apply_start)
apply_body = text[apply_start:apply_end]
if apply_body.index('security_restore_ssh_ops_state "$new_port" "$new_transition_port"') < apply_body.index('security_apply_fail2ban_ssh_state "$new_port" "$new_transition_port"'):
    issues.append('apply flow persists OPS SSH state before fail2ban succeeds')

finalize_start = text.index('security_finalize_ssh_transition_apply() {')
finalize_end = text.index('security_finalize_ssh_transition() {', finalize_start)
finalize_body = text[finalize_start:finalize_end]
if finalize_body.index('security_restore_ssh_ops_state "$new_port" ""') < finalize_body.index('security_apply_fail2ban_ssh_state "$new_port" ""'):
    issues.append('finalize flow persists OPS SSH state before fail2ban succeeds')

print('\n'.join(issues))
PY
)"

    test::assert_eq "" "$failures" 'SSH state must persist only after UFW/fail2ban success in apply and finalize flows' || return 1
}

case_sec_09_4_host_baseline_swap_contract_present() {
    local security_content
    security_content="$(<"${OPS_ROOT}/modules/security.sh")"

    test::assert_contains "$security_content" 'security_apply_sysctl_baseline || return 1' 'host baseline must fail when sysctl apply fails' || return 1
    test::assert_contains "$security_content" 'security_ensure_swap || return 1' 'host baseline must fail when swap provisioning fails' || return 1
    test::assert_not_contains "$security_content" 'swapon "$SECURITY_SWAP_FILE" >/dev/null 2>&1 || true' 'swap activation must not swallow failures' || return 1
    test::assert_contains "$security_content" '_swapfile_escaped' 'swap fstab matching must be semantic, not exact-string only' || return 1
}

case_ins_01_02_installer_os_contract_present() {
    local content legacy_content
    content="$(<"${REPO_ROOT}/install/ops-install.sh")"
    legacy_content="$(<"${REPO_ROOT}/ops/install/ops-install.sh")"
    test::assert_contains "$content" '22.04' 'Ubuntu 22.04 support contract missing' || return 1
    test::assert_contains "$content" '24.04' 'Ubuntu 24.04 support contract missing' || return 1
    test::assert_contains "$legacy_content" 'Use install/ops-install.sh from the repo root.' 'legacy installer wrapper contract missing' || return 1
}

case_ins_03_unsupported_os_rejected_contract_present() {
    local content
    content="$(<"${REPO_ROOT}/install/ops-install.sh")"
    test::assert_contains "$content" 'Unsupported OS' 'unsupported OS rejection missing' || return 1
}

case_ins_04_existing_admin_user_contract_present() {
    local content
    content="$(<"${REPO_ROOT}/install/ops-install.sh")"
    test::assert_contains "$content" 'OPS_ADMIN_USER' 'installer must reuse persisted OPS admin user when available' || return 1
    test::assert_contains "$content" 'id "$ADMIN_USER"' 'existing admin user detection missing' || return 1
}

case_ins_05_rerun_setup_contract_present() {
    local content utils_content
    content="$(<"${OPS_ROOT}/bin/ops-setup.sh")"
    utils_content="$(<"${OPS_ROOT}/core/utils.sh")"
    test::assert_contains "$content" 'ensure_dir "$OPS_CONFIG_DIR"' 'setup idempotent config dir contract missing' || return 1
    test::assert_contains "$content" 'safe_symlink' 'symlink idempotence contract missing' || return 1
    test::assert_contains "$utils_content" 'Refusing to replace non-OPS symlink' 'safe_symlink must refuse foreign symlink takeover' || return 1
    test::assert_contains "$utils_content" 'Refusing to replace regular file at' 'safe_symlink must refuse foreign file takeover' || return 1
    test::assert_contains "$content" 'chown root:root "$OPS_LOG_DIR"' 'setup must harden log directory ownership on rerun' || return 1
    test::assert_contains "$content" 'chmod 755 "$OPS_LOG_DIR"' 'setup must keep log directory non-group-writable' || return 1
    test::assert_contains "$content" 'chmod 640 "$OPS_LOG_FILE"' 'setup must enforce root-owned ops log permissions' || return 1
    test::assert_contains "$content" 'cmp -s "$tmp" "$lr_file"' 'logrotate reconcile must be content-aware' || return 1
    test::assert_contains "$content" 'write_file "$lr_file" < "$tmp"' 'logrotate reconcile must rewrite managed content atomically' || return 1
    test::assert_contains "$content" 'detect_admin_user' 'ops-setup rerun must reuse shared persisted admin-user resolution' || return 1
    test::assert_contains "$content" 'if [[ ${OPS_SSH_PORT+x} ]]; then' 'ops-setup rerun must preserve OPS_SSH_PORT when env is absent' || return 1
    test::assert_contains "$content" 'if [[ ${OPS_SSH_TRANSITION_PORT+x} ]]; then' 'ops-setup rerun must preserve OPS_SSH_TRANSITION_PORT when env is absent' || return 1
    test::assert_contains "$content" '# OPS login hook end' 'ops-setup must manage the login hook as a bounded block' || return 1
    test::assert_not_contains "$content" 'Login hook ${hook_version} already present in ${profile} — skipping.' 'ops-setup must not accept OPS_HOOK_V3 alone as a valid hook' || return 1
    test::assert_contains "$content" '/etc/sudoers.d/99-ops-ssh-finalize' 'ops-setup must reconcile the legacy auto-finalize sudoers rule' || return 1
    test::assert_contains "$content" $'setup_login_hook\n    cleanup_legacy_ssh_finalize_sudoers' 'legacy sudoers cleanup must run only after hook migration succeeds' || return 1
}

case_ins_06_07_08_login_hook_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/bin/ops-setup.sh")"
    test::assert_contains "$content" 'SSH_CONNECTION' 'login hook must key off SSH_CONNECTION' || return 1
    test::assert_not_contains "$content" 'SSH_TTY' 'stale SSH_TTY-only login hook contract must stay absent' || return 1
    test::assert_contains "$content" 'OPS_HOOK_V3' 'current login hook version marker missing' || return 1
    test::assert_contains "$content" 'Refusing to rewrite incomplete OPS login hook block' 'login hook must fail closed on incomplete managed blocks' || return 1
    test::assert_contains "$content" '# OPS login hook end' 'login hook end marker missing' || return 1
}

case_ins_09_installer_rollback_contract_present() {
    local content runbook_content
    content="$(<"${REPO_ROOT}/install/ops-install.sh")"
    runbook_content="$(<"${REPO_ROOT}/docs/operator/RUNBOOKS.md")"
    test::assert_contains "$content" 'OPS_PRE_ACTIVATION_ROLLBACK_ARMED' 'installer must track pre-activation rollback state before mutation' || return 1
    test::assert_contains "$content" 'Installer failed before activation completed. Restoring previous SSH, firewall, and admin bootstrap state.' 'installer pre-activation rollback contract missing' || return 1
    test::assert_contains "$content" 'admin-ssh-dir' 'installer must snapshot bootstrap SSH key state for existing admin users' || return 1
    test::assert_contains "$content" 'OPS_INSTALL_PREVIOUS_BACKUP' 'installer rollback backup tracking missing' || return 1
    test::assert_contains "$content" 'OPS_POST_DEPLOY_SNAPSHOT_DIR' 'installer must snapshot operator-facing state before post-deploy setup' || return 1
    test::assert_contains "$content" '/etc/sudoers.d/99-ops-ssh-finalize' 'installer post-deploy rollback must snapshot legacy finalize sudoers state' || return 1
    test::assert_contains "$content" 'ssh-finalize-sudoers' 'installer post-deploy rollback must restore legacy finalize sudoers state' || return 1
    test::assert_contains "$content" 'Failed to activate the new OPS tree. Previous installation was restored.' 'installer activation rollback message missing' || return 1
    test::assert_contains "$content" 'ops-setup.sh failed after activating the new OPS tree. Previous state was restored.' 'installer must restore previous state when ops-setup fails after activation' || return 1
    test::assert_contains "$content" 'Failed to write capacity.conf after activating the new OPS tree. Previous state was restored.' 'installer must restore previous state when capacity.conf write fails after activation' || return 1
    test::assert_contains "$content" 'Syntax check failed for candidate entrypoint' 'installer must validate extensionless candidate entrypoints' || return 1
    test::assert_contains "$runbook_content" 'Installer bootstrap rollback before activation' 'installer pre-activation rollback runbook missing' || return 1
    test::assert_contains "$runbook_content" 'SSH port transition and finalisation' 'SSH rollback runbook missing' || return 1
}

case_web_01_nginx_install_contract_present() {
    # L-05 fix: REG-24 migrated bare systemctl calls to service_reload/service_restart
    # wrappers. Assert the current contract phrases instead of the legacy string.
    local content
    content="$(<"${OPS_ROOT}/modules/nginx.sh")"
    test::assert_contains "$content" 'service_reload nginx' 'nginx service_reload contract missing' || return 1
    test::assert_contains "$content" 'service_restart nginx' 'nginx service_restart contract missing' || return 1
}

case_web_02_node_domain_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/nginx.sh")"
    test::assert_contains "$content" 'node_vhost.conf.tpl' 'node vhost template contract missing' || return 1
}

case_web_03_php_domain_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/nginx.sh")"
    test::assert_contains "$content" 'php_vhost.conf.tpl' 'php vhost template contract missing' || return 1
}

case_web_04_static_domain_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/nginx.sh")"
    test::assert_contains "$content" 'static_vhost.conf.tpl' 'static vhost template contract missing' || return 1
}

case_web_05_remove_domain_keeps_root_contract_present() {
    local content
    content="$(<"${REPO_ROOT}/docs/reference/TEST-CASES.md")"
    test::assert_contains "$content" 'WEB-05' 'WEB-05 testcase missing' || return 1
    test::assert_contains "$content" 'giu `/var/www/<domain>`' 'web root preservation contract missing' || return 1
}

case_web_06_nginx_reload_blocked_on_error_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/nginx.sh")"
    test::assert_contains "$content" 'nginx_validate' 'shared nginx validation wrapper missing' || return 1
}

case_web_07_ssl_issue_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/nginx.sh")"
    test::assert_contains "$content" 'certbot' 'certbot integration missing' || return 1
    test::assert_contains "$content" '_rebuild_domain_vhost "$domain"' 'SSL issuance must rebuild managed vhosts from OPS state' || return 1
    test::assert_contains "$content" 'DOMAIN_SSL_MODE="cloudflare_origin"' 'Cloudflare origin cert flow must persist ssl mode in OPS domain state' || return 1
}

case_web_08_ssl_status_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/verify.sh")"
    test::assert_contains "$content" 'expires in' 'SSL expiry status reporting missing' || return 1
}

case_web_09_web_10_cliproxyapi_nginx_boundary_contract_present() {
    local tpl_content verify_content
    tpl_content="$(<"${OPS_ROOT}/modules/templates/nginx/cli-proxy-api.vhost.conf.tpl")"
    verify_content="$(<"${OPS_ROOT}/modules/verify.sh")"
    test::assert_contains "$tpl_content" 'listen [::]:80;' 'CLIProxyAPI HTTP vhost must expose dual-stack listener' || return 1
    test::assert_contains "$tpl_content" 'proxy_buffering       off' 'CLIProxyAPI nginx boundary contract missing' || return 1
    test::assert_not_contains "$tpl_content" '{{SSL_HTTPS_BLOCK}}' 'CLIProxyAPI template must not carry dead SSL_HTTPS_BLOCK placeholder' || return 1
    test::assert_contains "$verify_content" '/v1/models returned JSON' 'CLIProxyAPI localhost verify contract missing' || return 1
}

case_web_11_transactional_vhost_commit_contract_present() {
    local content real_ip_tpl arch_content inventory_content menu_content output parsed_ok parsed_bad valid_state invalid_state
    content="$(<"${OPS_ROOT}/modules/nginx.sh")"
    real_ip_tpl="$(<"${OPS_ROOT}/modules/templates/nginx/cloudflare-real-ip.conf.tpl")"
    arch_content="$(<"${REPO_ROOT}/docs/reference/ARCHITECTURE.md")"
    inventory_content="$(<"${REPO_ROOT}/docs/reference/RUNTIME-ARTEFACT-INVENTORY.md")"
    menu_content="$(<"${REPO_ROOT}/docs/operator/MENU-REFERENCE.md")"
    test::assert_contains "$content" '_nginx_commit_vhost()' 'Transactional vhost commit helper missing' || return 1
    test::assert_contains "$content" 'snapshot_path_state "$available" "$snapshot_root" "available"' 'Transactional vhost commit must snapshot live available config before mutation' || return 1
    test::assert_contains "$content" 'restore_path_snapshot "$available" "$snapshot_root" "available"' 'Transactional vhost commit must restore live config on failure' || return 1
    test::assert_contains "$content" 'safe_symlink "$available" "$enabled"' 'Transactional vhost commit must update symlinks through the safe helper' || return 1
    test::assert_contains "$content" '_nginx_commit_vhost "$NGINX_DEFAULT_DENY_NAME" "$staged"' 'Default deny vhost must use transactional commit helper' || return 1
    test::assert_contains "$content" 'create_default_deny || return 1' 'Callers must fail closed when default deny vhost refresh fails' || return 1
    test::assert_contains "$content" '_nginx_write_cf_real_ip_snippet "$snippet" "$ranges"' 'Cloudflare real IP snippet must be generated from live CIDR ranges' || return 1
    test::assert_contains "$real_ip_tpl" '{{LAST_REFRESH}}' 'Cloudflare real IP template must expose LAST_REFRESH placeholder' || return 1
    test::assert_contains "$real_ip_tpl" '{{REAL_IP_RANGES}}' 'Cloudflare real IP template must expose REAL_IP_RANGES placeholder' || return 1
    test::assert_contains "$content" 'render_template "$tpl" "VALUE=${header_value}" | write_file "$snippet"' 'Custom powered-by snippet must use template rendering and atomic writes' || return 1
    test::assert_contains "$content" 'double quotes, backslashes, or newlines' 'Custom powered-by header validation missing' || return 1
    test::assert_contains "$arch_content" 'HTTP base `server {}` block only' 'Architecture docs must describe HTTP-only nginx templates with TLS appended at render time' || return 1
    test::assert_contains "$inventory_content" '/etc/nginx/ssl/ops-default.crt' 'Runtime inventory must document default deny self-signed cert artefact' || return 1
    test::assert_contains "$menu_content" 'explicit `include` snippet' 'Operator docs must state that nginx snippets need explicit include lines' || return 1

    output="$(OPS_ROOT_ENV="$OPS_ROOT" TEST_TMP="$TEST_ENV_DIR" bash -c '
set -euo pipefail
work_dir="$TEST_TMP/nginx-domain-state"
mkdir -p "$work_dir/conf"
state_ok="$work_dir/example.com.conf"
state_bad="$work_dir/injected.conf"
cat > "$state_ok" <<'"'"'EOF_STATE_OK'"'"'
DOMAIN="example.com"
DOMAIN_BACKEND_TYPE="php"
DOMAIN_PHP_VERSION="8.2"
DOMAIN_PHP_SOCKET="/run/php/php8.2-fpm-example.sock"
DOMAIN_PHP_POOL="example"
DOMAIN_WEB_ROOT="/var/www/example.com"
EOF_STATE_OK
cat > "$state_bad" <<'"'"'EOF_STATE_BAD'"'"'
DOMAIN="example.com"
DOMAIN_BACKEND_TYPE="php"
DOMAIN_PHP_VERSION="8.2"; touch /tmp/pwned
EOF_STATE_BAD
export OPS_ROOT="$OPS_ROOT_ENV"
export OPS_CONFIG_DIR="$work_dir/conf"
export OPS_LOG_FILE="$work_dir/test.log"
export ADMIN_USER="nobody"
export SUDO_USER="nobody"
export USER="nobody"
source "$OPS_ROOT_ENV/core/env.sh"
source "$OPS_ROOT_ENV/core/ui.sh"
source "$OPS_ROOT_ENV/core/utils.sh"
source "$OPS_ROOT_ENV/modules/php.sh"
source "$OPS_ROOT_ENV/modules/nginx.sh"
parsed_ok="$(_load_domain_state "$state_ok" | tr "\n" "\f")"
parsed_bad="$(_load_domain_state "$state_bad" | tr "\n" "\f")"
if _validate_domain_state "example.com" "php" "8.2" "/run/php/php8.2-fpm-example.sock" "example" "/var/www/example.com" >/dev/null 2>&1; then
    valid_state=pass
else
    valid_state=fail
fi
if _validate_domain_state "bad/host" "php" "8.2" "/run/php/php8.2-fpm-example.sock" "example" "/var/www/example.com" >/dev/null 2>&1; then
    invalid_state=pass
else
    invalid_state=fail
fi
printf "%s\037%s\037%s\037%s" "$parsed_ok" "$parsed_bad" "$valid_state" "$invalid_state"
')"
    IFS=$'\037' read -r parsed_ok parsed_bad valid_state invalid_state <<< "$output"
    test::assert_contains "$parsed_ok" 'DOMAIN=example.com' '_load_domain_state must parse known keys from valid state' || return 1
    test::assert_contains "$parsed_bad" 'DOMAIN_BACKEND_TYPE=php' '_load_domain_state may keep valid whitelisted assignments before malformed lines' || return 1
    test::assert_not_contains "$parsed_bad" 'touch /tmp/pwned' '_load_domain_state must never emit malformed or injectable payload text' || return 1
    test::assert_not_contains "$parsed_bad" 'DOMAIN_PHP_VERSION' '_load_domain_state must drop malformed assignments instead of forwarding them' || return 1
    test::assert_eq 'pass' "$valid_state" '_validate_domain_state must accept coherent PHP domain state' || return 1
    test::assert_eq 'fail' "$invalid_state" '_validate_domain_state must reject invalid domains before render/commit' || return 1
}

case_node_01_node_lts_install_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/node.sh")"
    # Assert the safe manual GPG path, NOT the download-and-execute pattern (setup_lts.x).
    test::assert_contains "$content" 'nodesource-repo.gpg.key' 'NodeSource manual GPG key download missing (safe install required)' || return 1
    test::assert_contains "$content" 'gpg --dearmor' 'NodeSource GPG dearmor step missing' || return 1
    test::assert_contains "$content" 'deb.nodesource.com' 'NodeSource apt sources.list entry missing' || return 1
}

case_node_02_pm2_not_root_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/verify.sh")"
    test::assert_contains "$content" 'daemon running as root' 'PM2 non-root verify missing' || return 1
}

case_node_03_04_05_06_07_node_menu_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/node.sh")"
    test::assert_contains "$content" 'pm2 list' 'node service list helper missing' || return 1
    test::assert_contains "$content" 'pm2 restart' 'node restart helper missing' || return 1
    test::assert_contains "$content" 'pm2 logs' 'node logs helper missing' || return 1
    test::assert_contains "$content" 'pm2 delete' 'node remove helper missing' || return 1
}

case_node_08_09_10_pm2_template_contract_present() {
    local tpl_content node_content
    tpl_content="$(<"${OPS_ROOT}/modules/templates/pm2/ecosystem.config.js.tpl")"
    node_content="$(<"${OPS_ROOT}/modules/node.sh")"
    test::assert_contains "$tpl_content" 'merge_logs: true' 'PM2 merge_logs contract missing' || return 1
    test::assert_contains "$tpl_content" 'cwd: "{{APP_DIR}}"' 'PM2 template cwd must use APP_DIR placeholder' || return 1
    test::assert_contains "$tpl_content" '/var/log/ops/pm2-{{APP_NAME}}-out.log' 'PM2 template must write stdout to OPS per-app log path' || return 1
    test::assert_contains "$tpl_content" '/var/log/ops/pm2-{{APP_NAME}}-err.log' 'PM2 template must write stderr to OPS per-app log path' || return 1
    test::assert_contains "$node_content" 'pm2-logrotate' 'PM2 logrotate contract missing' || return 1
    test::assert_contains "$tpl_content" 'max_memory_restart' 'PM2 max_memory_restart contract missing' || return 1
    # NODE-10: template must include node_args to cap V8 heap (KNOWN-RISKS §22).
    test::assert_contains "$tpl_content" 'node_args' 'PM2 template must include node_args for V8 heap cap (NODE-10 / KNOWN-RISKS §22)' || return 1
    test::assert_contains "$tpl_content" 'NODE_ARGS_MAX_OLD_SPACE' 'PM2 template node_args must use NODE_ARGS_MAX_OLD_SPACE placeholder' || return 1
    test::assert_contains "$node_content" '"APP_DIR=${app_dir}"' 'node app render must pass APP_DIR into PM2 template' || return 1
    test::assert_contains "$node_content" '_node_assert_ecosystem_safe_value "App directory" "$app_dir"' 'node app render must validate app directory before templating' || return 1
    test::assert_contains "$node_content" '_node_assert_pm2_name_safe "$pm2_name"' 'node app render must validate PM2 process names' || return 1
    test::assert_contains "$node_content" '_node_prepare_pm2_log_files "$pm2_name"' 'node app add flow must pre-create PM2 per-app log files before pm2 start' || return 1
    test::assert_contains "$node_content" 'node_reconcile_pm2_log_files()' 'node module must expose PM2 app log reconcile helper for existing apps' || return 1
    test::assert_contains "$node_content" '| write_file "$eco_dest"' 'node app template render must use atomic write_file helper' || return 1
}

case_php_01_php_versions_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/php.sh")"
    test::assert_contains "$content" 'PHP_SUPPORTED_VERSIONS=("7.4" "8.1" "8.2" "8.3")' 'PHP supported versions contract missing' || return 1
    test::assert_contains "$content" 'Cannot remove PHP ${ver} while it is still referenced by OPS state.' 'PHP version removal guard missing' || return 1
    test::assert_contains "$content" 'Default CLI currently points to /usr/bin/php${ver}' 'PHP version removal must block current CLI default' || return 1
}

case_php_02_php_pool_socket_contract_present() {
    local php_content nginx_content tpl_content
    php_content="$(<"${OPS_ROOT}/modules/php.sh")"
    nginx_content="$(<"${OPS_ROOT}/modules/nginx.sh")"
    tpl_content="$(<"${OPS_ROOT}/modules/templates/nginx/php_vhost.conf.tpl")"
    test::assert_contains "$php_content" 'php_get_socket_path()' 'PHP socket helper missing' || return 1
    test::assert_contains "$php_content" 'echo "/run/php/php${ver}-fpm-${site}.sock"' 'PHP socket naming contract missing' || return 1
    test::assert_contains "$php_content" 'php_socket_matches_contract()' 'PHP socket/version/pool contract helper missing' || return 1
    test::assert_contains "$php_content" 'php_verify_domain_contracts_for_version()' 'PHP verify must audit domain/pool/socket/vhost coherence' || return 1
    test::assert_contains "$nginx_content" 'DOMAIN_PHP_POOL' 'domain state must persist explicit PHP pool identity' || return 1
    test::assert_contains "$nginx_content" 'prompt_input "Enter PHP-FPM pool name" "$domain"' 'PHP domain add flow must prompt for pool name' || return 1
    test::assert_contains "$nginx_content" 'configure_php_pool "$php_pool" "$php_version" "$domain" "$web_root" 1' 'PHP domain add flow must configure the explicit pool name' || return 1
    test::assert_contains "$nginx_content" '"PHP_SOCKET=${php_socket}"' 'PHP domain render must pass explicit socket path into nginx template' || return 1
    test::assert_contains "$tpl_content" 'unix:{{PHP_SOCKET}};' 'PHP vhost template must render explicit PHP socket placeholders' || return 1
    test::assert_contains "$php_content" 'pool file ${pool_file} points listen=' 'PHP verify must compare pool listen socket with expected contract' || return 1
    test::assert_contains "$nginx_content" "php_socket '\${php_socket}' does not match version/pool contract '\${expected_socket}'" 'PHP domain state validation must reject socket/pool/version drift' || return 1
}

case_php_03_php_domain_state_contract_present() {
    local php_content nginx_content
    php_content="$(<"${OPS_ROOT}/modules/php.sh")"
    nginx_content="$(<"${OPS_ROOT}/modules/nginx.sh")"
    test::assert_contains "$php_content" 'SITE_DIR="${site_dir}"' 'PHP site state must persist site directory' || return 1
    test::assert_contains "$php_content" 'SITE_DOMAIN="${site_domain}"' 'PHP site state must persist site domain' || return 1
    test::assert_contains "$nginx_content" 'echo "  Current pool name : ${php_pool}"' 'PHP domain edit flow must surface the stored pool name' || return 1
    test::assert_contains "$nginx_content" '[[ -n "$php_pool" ]] || php_pool="$(_php_pool_from_socket "$php_socket")"' 'PHP domain flows must fall back to stored socket-derived pool names for legacy state' || return 1
    test::assert_contains "$nginx_content" '_restore_php_pool_snapshot "$php_snapshot_root" "$php_target_pool_file" "$php_state_file" "$php_version" "$php_previous_pool_file" "$php_previous_version"' 'PHP add-domain flow must restore PHP state on Nginx commit failure' || return 1
    test::assert_contains "$nginx_content" '_validate_domain_state "$domain" "${backend_type:-}" "$php_version" "$php_socket" "$php_pool" ""' 'PHP domain removal must validate current state before cleanup' || return 1
    test::assert_contains "$nginx_content" 'snapshot_root=$(mktemp -d "/tmp/ops-nginx-remove.${domain}.XXXXXX")' 'PHP domain removal must snapshot current state before deleting files' || return 1
    test::assert_contains "$nginx_content" 'print_error "remove_domain: failed to commit removal for ${domain}. Restored the previous domain and PHP state."' 'PHP domain removal must restore prior state on failure' || return 1
}

case_php_04_fpm_only_hardening_contract_present() {
    local php_content security_content
    php_content="$(<"${OPS_ROOT}/modules/php.sh")"
    security_content="$(<"${REPO_ROOT}/docs/operator/SECURITY-RULES.md")"
    test::assert_contains "$php_content" 'php_ini_cli_tuning()' 'PHP CLI tuning helper missing' || return 1
    test::assert_contains "$php_content" 'php_ini_fpm_security_tuning()' 'PHP FPM security tuning helper missing' || return 1
    test::assert_contains "$php_content" 'echo "opcache.enable_cli=1"' 'CLI tuning must stay separate from FPM hardening' || return 1
    test::assert_contains "$php_content" 'echo "allow_url_fopen=Off"' 'FPM hardening must disable allow_url_fopen' || return 1
    test::assert_contains "$php_content" 'pm.status_path and ping.path intentionally omitted' 'Default PHP-FPM pool baseline must keep status/ping disabled' || return 1
    test::assert_contains "$security_content" 'security-sensitive hardening' 'security rules must document FPM-only PHP hardening scope' || return 1
    test::assert_contains "$security_content" 'pm.status_path' 'security rules must document PHP-FPM status/ping lockdown' || return 1
    test::assert_contains "$security_content" 'localhost-only Nginx location' 'security rules must require localhost-only exposure if status/ping is re-enabled' || return 1
}

case_php_05_per_pool_override_contract_present() {
    local php_content risk_content security_content
    php_content="$(<"${OPS_ROOT}/modules/php.sh")"
    risk_content="$(<"${REPO_ROOT}/docs/reference/KNOWN-RISKS-PATTERNS.md")"
    security_content="$(<"${REPO_ROOT}/docs/operator/SECURITY-RULES.md")"
    test::assert_contains "$php_content" 'keep custom per-pool directives such as env[...], php_admin_value, and php_admin_flag entries.' 'PHP pool refresh must preserve custom per-pool directives' || return 1
    test::assert_contains "$php_content" 'cp -a "$old_pool_file" "$pool_file"' 'PHP pool migration must seed from the old pool file to preserve overrides' || return 1
    test::assert_contains "$risk_content" 'php_admin_value disable_functions ""' 'disable_functions workaround must stay per-pool' || return 1
    test::assert_contains "$risk_content" 'php_admin_value allow_url_fopen On' 'allow_url_fopen workaround must stay per-pool' || return 1
    test::assert_contains "$security_content" 'php_admin_flag' 'security rules must require preserving php_admin_flag overrides' || return 1
}

case_php_06_transaction_and_diagnostics_contract_present() {
    local php_content
    php_content="$(<"${OPS_ROOT}/modules/php.sh")"
    test::assert_contains "$php_content" 'snapshot_path_state "$pool_file"' 'PHP pool changes must snapshot the current pool config' || return 1
    test::assert_contains "$php_content" 'restore_path_snapshot "/etc/php/${ver}/fpm/php.ini"' 'PHP tuning must restore php.ini on failure' || return 1
    test::assert_contains "$php_content" 'if service_active "$svc"; then' 'PHP-FPM apply path must detect active service before deciding reload vs restart' || return 1
    test::assert_contains "$php_content" 'service_reload "$svc" 15' 'PHP-FPM apply path must prefer reload for active services' || return 1
    test::assert_contains "$php_content" 'service_restart "$svc"' 'PHP-FPM apply path must fall back to restart when the service is inactive' || return 1
    test::assert_contains "$php_content" "printf 'Default CLI: '" 'PHP verify output must label default CLI version' || return 1
    test::assert_contains "$php_content" "printf 'Target CLI : '" 'PHP verify output must label target CLI version' || return 1
    test::assert_contains "$php_content" 'service_status "php${ver}-fpm" || true' 'PHP verify output must include FPM service status' || return 1
    test::assert_contains "$php_content" 'echo "PHP domain contract checks:"' 'PHP verify output must include domain contract diagnostics' || return 1
}

case_db_01_02_03_04_05_db_contracts_present() {
    local database_content verify_content
    database_content="$(<"${OPS_ROOT}/modules/database.sh")"
    verify_content="$(<"${OPS_ROOT}/modules/verify.sh")"
    test::assert_contains "$database_content" 'DB_ROOT_AUTH_MODE="socket"' 'DB install must default to unix_socket root auth' || return 1
    test::assert_contains "$database_content" '_db_secret_owner()' 'DB secret ownership helper missing' || return 1
    test::assert_contains "$database_content" 'ops_conf_unset "database.conf" "DB_ROOT_PASSWORD_FILE"' 'DB config must clear stale root password metadata when socket auth is active' || return 1
    test::assert_contains "$database_content" 'chmod 600 "$path"' 'DB secret files must be 0600' || return 1
    test::assert_contains "$database_content" 'bind-address = 127.0.0.1' 'DB bind-address contract missing' || return 1
    test::assert_contains "$database_content" '_db_set_bind_localhost || return 1' 'db_secure/db_apply_tuning must re-assert bind-address baseline' || return 1
    test::assert_contains "$database_content" 'prompt_confirm "Restart MariaDB now?"' 'db_secure must require explicit restart confirmation' || return 1
    test::assert_contains "$database_content" 'prompt_confirm "Restart MariaDB ngay bay gio de ap dung tuning?"' 'db_apply_tuning must require explicit restart confirmation' || return 1
    test::assert_contains "$database_content" 'DB_REDO_RESIZE_PENDING=1' 'redo-log resize cancel path must block restart' || return 1
    test::assert_contains "$database_content" 'credential_files_to_remove' 'db_drop must track OPS credential files for cleanup' || return 1
    test::assert_contains "$database_content" '%s/%s__%s.conf' 'DB credential files must be keyed by db and user' || return 1
    test::assert_contains "$database_content" 'Password was left unchanged.' 'existing-user rerun safety message missing' || return 1
    test::assert_contains "$database_content" 'No new credentials file was written because OPS cannot safely recover the current password.' 'existing-user rerun must not persist fake credentials' || return 1
    test::assert_contains "$database_content" 'CREATE DATABASE' 'DB create database helper missing' || return 1
    test::assert_contains "$verify_content" '_vs_db_query()' 'verify must use a DB query helper instead of socket-only inline reads' || return 1
    test::assert_contains "$verify_content" '.db-root-password' 'verify must support legacy DB root password fallback' || return 1
}

case_db_06_backup_helper_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/backup.sh")"
    test::assert_contains "$content" '/var/backups/ops/db' 'DB backup output path missing' || return 1
    test::assert_contains "$content" 'individual per-database files' 'dump-all backup contract must stay per-database' || return 1
    test::assert_contains "$content" 'sudo mysql --database="<dbname>"' 'restore guidance must show a valid DB restore command' || return 1
    test::assert_contains "$content" 'chmod 700 /etc/ops/db-credentials' 'restore guidance must repair db-credentials directory permissions' || return 1
    test::assert_contains "$content" 'chown <ADMIN_USER>:<ADMIN_USER>' 'restore guidance must repair admin-owned secret ownership' || return 1
}

case_cpa_01_02_03_04_05_06_07_08_09_cliproxyapi_contracts_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/cli-proxy-api.sh")"
    test::assert_contains "$content" 'CLIProxyAPI/releases/latest' 'CLIProxyAPI release install contract missing' || return 1
    test::assert_contains "$content" 'host: "127.0.0.1"' 'CLIProxyAPI loopback bind contract missing' || return 1
    test::assert_contains "$content" '.cli-proxy-api-key' 'CLIProxyAPI secret file contract missing' || return 1
    test::assert_contains "$content" 'proxy_buffering       off' 'CLIProxyAPI nginx proxy contract missing' || return 1
    test::assert_contains "$content" 'create_default_deny || return 1' 'CLIProxyAPI domain link must fail closed if default deny refresh fails' || return 1
    test::assert_not_contains "$content" '"SSL_HTTPS_BLOCK="' 'CLIProxyAPI vhost render must not pass dead SSL_HTTPS_BLOCK placeholder' || return 1
    test::assert_contains "$content" 'api-keys:' 'CLIProxyAPI API key toggle contract missing' || return 1
    test::assert_contains "$content" 'remote-management:' 'CLIProxyAPI remote management contract missing' || return 1
    test::assert_contains "$content" 'service_restart "$CLIPROXYAPI_SERVICE_NAME"' 'CLIProxyAPI service restart contract missing' || return 1
    test::assert_contains "$content" 'oauth-model-alias:' 'CLIProxyAPI oauth model alias contract missing' || return 1
    test::assert_contains "$content" 'payload:' 'CLIProxyAPI payload filter contract missing' || return 1
    test::assert_contains "$content" 'tools.#.input_schema.propertyNames' 'CLIProxyAPI payload filter propertyNames path missing' || return 1
    test::assert_contains "$content" $'- name: "claude-sonnet-4-6"\n      alias: "claude-sonnet-4-6"' 'CLIProxyAPI antigravity self-alias contract missing' || return 1
}

case_cpa_10_11_12_13_quota_helper_contracts_present() {
    local cpa_content user_guide_content menu_reference_content
    cpa_content="$(<"${OPS_ROOT}/modules/cli-proxy-api.sh")"
    user_guide_content="$(<"${REPO_ROOT}/USER_GUIDE.md")"
    menu_reference_content="$(<"${REPO_ROOT}/docs/operator/MENU-REFERENCE.md")"

    test::assert_contains "$cpa_content" 'CLIPROXYAPI_QUOTA_BASHRC_MARKER' 'Quota bashrc marker contract missing' || return 1
    test::assert_contains "$cpa_content" '_cliproxyapi_install_quota_inspector_go || return 1' 'Quota install must ensure Go before resolving binary path' || return 1
    test::assert_contains "$cpa_content" 'go_bin="$(_cliproxyapi_quota_inspector_go_binary)"' 'Quota install must resolve Go binary after ensure step' || return 1
    test::assert_not_contains "$cpa_content" 'go_bin="$(_cliproxyapi_install_quota_inspector_go)"' 'Quota install must not capture installer log output into go binary path' || return 1
    test::assert_contains "$cpa_content" 'cpaq() {' 'Quota shortcut function contract missing' || return 1
    test::assert_contains "$cpa_content" 'CLIPROXYAPI_QUOTA_INSPECTOR_BINARY=' 'Quota shortcut binary constant missing' || return 1
    test::assert_contains "$cpa_content" 'cpa-quota-inspector' 'Quota shortcut binary name contract missing' || return 1
    test::assert_contains "$cpa_content" '--summary-only' 'Quota shortcut summary flag contract missing' || return 1
    test::assert_contains "$cpa_content" '--no-progress' 'Quota shortcut no-progress flag contract missing' || return 1
    test::assert_contains "$cpa_content" 'echo "  14) Check quota"' 'CLIProxyAPI menu quota entry missing' || return 1
    test::assert_contains "$cpa_content" 'export CPA_MANAGEMENT_KEY' 'Quota management key warning contract missing' || return 1

    test::assert_contains "$user_guide_content" '| 14) Check quota |' 'USER_GUIDE check quota menu doc missing' || return 1
    test::assert_contains "$user_guide_content" 'cpaq()' 'USER_GUIDE quota shortcut doc missing' || return 1

    test::assert_contains "$menu_reference_content" '14. **Check quota**' 'MENU-REFERENCE quota menu doc missing' || return 1
    test::assert_contains "$menu_reference_content" 'cpaq()' 'MENU-REFERENCE quota shortcut doc missing' || return 1
}

case_cpa_14_bootstrap_auth_submenu_contract_present() {
    local cpa_content user_guide_content menu_reference_content
    cpa_content="$(<"${OPS_ROOT}/modules/cli-proxy-api.sh")"
    user_guide_content="$(<"${REPO_ROOT}/USER_GUIDE.md")"
    menu_reference_content="$(<"${REPO_ROOT}/docs/operator/MENU-REFERENCE.md")"

    test::assert_contains "$cpa_content" 'menu_cliproxyapi_bootstrap_auth()' 'CLIProxyAPI bootstrap submenu function missing' || return 1
    test::assert_contains "$cpa_content" 'echo "  1) Antigravity"' 'CLIProxyAPI bootstrap submenu missing Antigravity entry' || return 1
    test::assert_contains "$cpa_content" 'echo "  2) Gemini"' 'CLIProxyAPI bootstrap submenu missing Gemini entry' || return 1
    test::assert_contains "$cpa_content" 'echo "  3) Claude Code"' 'CLIProxyAPI bootstrap submenu missing Claude Code entry' || return 1
    test::assert_contains "$cpa_content" 'echo "  4) Codex"' 'CLIProxyAPI bootstrap submenu missing Codex entry' || return 1
    test::assert_contains "$cpa_content" 'bootstrap_cliproxyapi_auth antigravity' 'CLIProxyAPI bootstrap submenu must dispatch Antigravity auth' || return 1
    test::assert_contains "$cpa_content" 'bootstrap_cliproxyapi_auth gemini' 'CLIProxyAPI bootstrap submenu must dispatch Gemini auth' || return 1
    test::assert_contains "$cpa_content" 'bootstrap_cliproxyapi_auth claude-code' 'CLIProxyAPI bootstrap submenu must dispatch Claude Code auth' || return 1
    test::assert_contains "$cpa_content" 'bootstrap_cliproxyapi_auth codex' 'CLIProxyAPI bootstrap submenu must dispatch Codex auth' || return 1
    test::assert_contains "$cpa_content" '--antigravity-login' 'CLIProxyAPI Antigravity auth flag contract missing' || return 1
    test::assert_contains "$cpa_content" 'Launching Gemini provider login' 'CLIProxyAPI Gemini auth label contract missing' || return 1
    test::assert_contains "$cpa_content" '--login' 'CLIProxyAPI Gemini auth flag contract missing' || return 1
    test::assert_contains "$cpa_content" 'Launching Claude Code provider login' 'CLIProxyAPI Claude Code auth label contract missing' || return 1
    test::assert_contains "$cpa_content" '--claude-login' 'CLIProxyAPI Claude Code auth flag contract missing' || return 1
    test::assert_contains "$cpa_content" '--codex-login' 'CLIProxyAPI Codex auth flag contract missing' || return 1

    test::assert_contains "$user_guide_content" '| 13) Bootstrap auth providers |' 'USER_GUIDE bootstrap auth menu doc missing' || return 1
    test::assert_contains "$user_guide_content" 'Antigravity / Gemini / Claude Code / Codex' 'USER_GUIDE bootstrap auth submenu doc missing' || return 1
    test::assert_contains "$user_guide_content" '--antigravity-login' 'USER_GUIDE Antigravity auth flag doc missing' || return 1
    test::assert_contains "$user_guide_content" '--claude-login' 'USER_GUIDE Claude Code auth flag doc missing' || return 1

    test::assert_contains "$menu_reference_content" '13. **Bootstrap auth providers**' 'MENU-REFERENCE bootstrap auth doc missing' || return 1
    test::assert_contains "$menu_reference_content" 'Antigravity' 'MENU-REFERENCE bootstrap auth submenu missing Antigravity' || return 1
    test::assert_contains "$menu_reference_content" 'Gemini' 'MENU-REFERENCE bootstrap auth submenu missing Gemini' || return 1
    test::assert_contains "$menu_reference_content" 'Claude Code' 'MENU-REFERENCE bootstrap auth submenu missing Claude Code' || return 1
    test::assert_contains "$menu_reference_content" 'Codex' 'MENU-REFERENCE bootstrap auth submenu missing Codex' || return 1
    test::assert_contains "$menu_reference_content" '--antigravity-login' 'MENU-REFERENCE Antigravity auth flag doc missing' || return 1
    test::assert_contains "$menu_reference_content" '--claude-login' 'MENU-REFERENCE Claude Code auth flag doc missing' || return 1
}

case_mon_01_02_03_04_05_monitoring_contracts_present() {
    local monitoring_content checks_content verify_content
    monitoring_content="$(<"${OPS_ROOT}/modules/monitoring.sh")"
    checks_content="$(<"${OPS_ROOT}/modules/checks.sh")"
    verify_content="$(<"${OPS_ROOT}/modules/verify.sh")"
    test::assert_contains "$verify_content" 'return 0   # verify action never exits the menu due to WARN/FAIL counts' 'MON-01 verify exit-zero contract missing' || return 1
    test::assert_contains "$monitoring_content" 'Quick logs' 'monitoring quick logs contract missing' || return 1
    test::assert_contains "$monitoring_content" '_monitoring_menu_run()' 'monitoring menu wrapper missing' || return 1
    test::assert_contains "$checks_content" 'checks_install_cron()' 'scheduled checks install contract missing' || return 1
    test::assert_contains "$checks_content" '_checks_send_telegram' 'notification disable/test path contract missing' || return 1
}

case_mon_06_monitoring_baseline_contract_present() {
    local monitoring_content wizard_content
    monitoring_content="$(<"${OPS_ROOT}/modules/monitoring.sh")"
    wizard_content="$(<"${OPS_ROOT}/modules/setup-wizard.sh")"
    test::assert_contains "$monitoring_content" 'monitoring_apply_baseline()' 'monitoring baseline helper missing' || return 1
    test::assert_contains "$monitoring_content" '_monitoring_reconcile_ops_log_path' 'monitoring baseline must reconcile the OPS log path' || return 1
    test::assert_contains "$monitoring_content" '_monitoring_reconcile_ops_logrotate' 'monitoring baseline must reconcile OPS logrotate state' || return 1
    test::assert_contains "$monitoring_content" '/etc/logrotate.d/nginx-ops' 'monitoring baseline must check nginx logrotate readiness' || return 1
    test::assert_contains "$monitoring_content" '/etc/logrotate.d/php*-fpm' 'monitoring baseline must check PHP-FPM logrotate readiness' || return 1
    test::assert_contains "$monitoring_content" '_monitoring_ensure_pm2_logrotate' 'monitoring baseline must ensure PM2 logrotate when PM2 is present' || return 1
    test::assert_contains "$monitoring_content" '_monitoring_reconcile_pm2_app_logs' 'monitoring baseline must reconcile PM2 app log files' || return 1
    test::assert_contains "$monitoring_content" 'Monitoring baseline completed with follow-up required.' 'monitoring baseline must fail closed when follow-up is required' || return 1
    test::assert_contains "$monitoring_content" 'return 1' 'monitoring baseline must return non-zero when baseline reconciliation is incomplete' || return 1
    test::assert_contains "$wizard_content" 'monitoring_apply_baseline || return 1' 'setup wizard monitoring step must fail closed when baseline apply fails' || return 1
    test::assert_contains "$wizard_content" '_wizard_mark_done "MONITORING"' 'setup wizard monitoring step must mark done only after baseline success' || return 1
}

case_file_01_02_03_04_file_contracts_present() {
    local utils_content codex_content database_content setup_content claude_content
    utils_content="$(<"${OPS_ROOT}/core/utils.sh")"
    codex_content="$(<"${OPS_ROOT}/modules/codex-cli.sh")"
    database_content="$(<"${OPS_ROOT}/modules/database.sh")"
    setup_content="$(<"${OPS_ROOT}/bin/ops-setup.sh")"
    claude_content="$(<"${OPS_ROOT}/modules/ai-agent.sh")"
    test::assert_contains "$utils_content" 'backup_file' 'backup helper missing' || return 1
    test::assert_contains "$utils_content" 'write_file' 'safe write helper missing' || return 1
    test::assert_contains "$codex_content" 'chmod 600 "$CODEX_API_KEY_FILE"' 'Codex secret permission contract missing in codex-cli module' || return 1
    test::assert_contains "$claude_content" 'chmod 600 "$api_key_file"' 'Claude secret permission contract missing in ai-agent module' || return 1
    test::assert_contains "$claude_content" 'chmod 600 "${tg_env}"' 'Telegram env permission contract missing in ai-agent module' || return 1
    test::assert_contains "$database_content" 'db-credentials' 'database credential secret path contract missing' || return 1
    test::assert_contains "$setup_content" 'OPS_CONFIG_DIR' 'shell-sourceable config contract missing' || return 1
    test::assert_contains "$codex_content" 'cp -a -- "$file" "$backup_path"' 'Codex managed shell rewrites must create backups' || return 1
    test::assert_contains "$codex_content" 'bash -n "$file"' 'Codex managed shell rewrites must validate bash syntax' || return 1
    test::assert_contains "$claude_content" 'cp -a -- "$file" "$backup_path"' 'Claude managed shell rewrites must create backups' || return 1
    test::assert_contains "$claude_content" 'bash -n "$file"' 'Claude managed shell rewrites must validate bash syntax' || return 1
}

case_file_05_web_root_ownership_contract_present() {
    local nginx_content
    nginx_content="$(<"${OPS_ROOT}/modules/nginx.sh")"
    test::assert_contains "$nginx_content" 'if [[ "$type" == "static" || "$type" == "php" ]]; then' 'web root ownership contract must apply to static and PHP domains only' || return 1
    test::assert_contains "$nginx_content" 'ensure_dir "$web_root"' 'web root ownership contract must create the web root before applying permissions' || return 1
    test::assert_contains "$nginx_content" 'chown "$ADMIN_USER":"www-data" "$web_root"' 'web root ownership contract must set admin:www-data ownership' || return 1
    test::assert_contains "$nginx_content" 'chmod 755 "$web_root"' 'web root ownership contract must enforce 0755 mode' || return 1
}

case_reg_17_admin_user_resolution_prefers_persisted_then_sudo_user() {
    local output persisted_user persisted_result sudo_user sudo_result
    output="$(OPS_ROOT_ENV="$OPS_ROOT" TEST_TMP="$TEST_ENV_DIR" bash -c '
set -euo pipefail
pick_two_users() {
    local users=()
    local user
    for user in nobody daemon www-data backup mail; do
        if id "$user" >/dev/null 2>&1; then
            users+=("$user")
        fi
        if [[ "${#users[@]}" -ge 2 ]]; then
            break
        fi
    done
    if [[ "${#users[@]}" -lt 2 ]]; then
        printf "need two known non-root users" >&2
        return 1
    fi
    printf "%s\037%s" "${users[0]}" "${users[1]}"
}

IFS=$'"'"'\037'"'"' read -r persisted_user sudo_user <<< "$(pick_two_users)"
conf_dir="$TEST_TMP/conf-admin"
mkdir -p "$conf_dir"
printf "OPS_ADMIN_USER=%q\n" "$persisted_user" > "$conf_dir/ops.conf"

export OPS_ROOT="$OPS_ROOT_ENV"
export OPS_CONFIG_DIR="$conf_dir"
export ADMIN_USER=""
export SUDO_USER="$sudo_user"
export USER="root"
source "$OPS_ROOT_ENV/core/env.sh"
persisted_result="$ADMIN_USER"

rm -f "$conf_dir/ops.conf"
export ADMIN_USER=""
export SUDO_USER="$sudo_user"
export USER="$persisted_user"
detect_admin_user
sudo_result="$ADMIN_USER"

printf "%s\037%s\037%s\037%s" "$persisted_user" "$persisted_result" "$sudo_user" "$sudo_result"
')"
    IFS=$'\037' read -r persisted_user persisted_result sudo_user sudo_result <<< "$output"
    test::assert_eq "$persisted_user" "$persisted_result" 'detect_admin_user must prefer persisted OPS_ADMIN_USER over SUDO_USER' || return 1
    test::assert_eq "$sudo_user" "$sudo_result" 'detect_admin_user must prefer SUDO_USER over USER fallback' || return 1
}

case_reg_18_ops_conf_roundtrip_and_metadata_preserved() {
    local output complex empty mode expected
    expected='value "quoted" $HOME path\segment &'
    output="$(OPS_ROOT_ENV="$OPS_ROOT" TEST_TMP="$TEST_ENV_DIR" bash -c '
set -euo pipefail
conf_dir="$TEST_TMP/conf-roundtrip"
mkdir -p "$conf_dir"
conf_file="$conf_dir/test.conf"
: > "$conf_file"
chmod 640 "$conf_file"

export OPS_ROOT="$OPS_ROOT_ENV"
export OPS_CONFIG_DIR="$conf_dir"
export ADMIN_USER="nobody"
export SUDO_USER="nobody"
export USER="nobody"
source "$OPS_ROOT_ENV/core/env.sh"

ops_conf_set test.conf COMPLEX "value \"quoted\" \$HOME path\\segment &"
ops_conf_set test.conf EMPTY ""
complex=$(ops_conf_get test.conf COMPLEX)
empty=$(ops_conf_get test.conf EMPTY)
mode=$(stat -c "%a" "$conf_file")
printf "%s\037%s\037%s" "$complex" "${empty:-__EMPTY__}" "$mode"
')"
    IFS=$'\037' read -r complex empty mode <<< "$output"
    test::assert_eq "$expected" "$complex" 'ops_conf_set/get must round-trip quoted shell values' || return 1
    test::assert_eq '__EMPTY__' "$empty" 'ops_conf_get must preserve explicit empty values' || return 1
    test::assert_eq '640' "$mode" 'ops_conf_set must preserve existing file mode when rewriting' || return 1
}

case_reg_19_write_file_preserves_existing_mode_and_keeps_new_files_private() {
    local output existing_mode new_mode rewritten
    output="$(OPS_ROOT_ENV="$OPS_ROOT" TEST_TMP="$TEST_ENV_DIR" bash -c '
set -euo pipefail
work_dir="$TEST_TMP/write-file"
mkdir -p "$work_dir"
existing_file="$work_dir/existing.conf"
new_file="$work_dir/new.conf"
printf "old\n" > "$existing_file"
chmod 640 "$existing_file"

export OPS_ROOT="$OPS_ROOT_ENV"
export OPS_CONFIG_DIR="$work_dir/conf"
export OPS_LOG_FILE="$work_dir/test.log"
export ADMIN_USER="nobody"
export SUDO_USER="nobody"
export USER="nobody"
source "$OPS_ROOT_ENV/core/env.sh"
source "$OPS_ROOT_ENV/core/utils.sh"

write_file "$existing_file" >/dev/null <<'"'"'EOF_EXISTING'"'"'
new
EOF_EXISTING
write_file "$new_file" >/dev/null <<'"'"'EOF_NEW'"'"'
secret
EOF_NEW

printf "%s\037%s\037%s" "$(stat -c "%a" "$existing_file")" "$(stat -c "%a" "$new_file")" "$(tr -d "\n" < "$existing_file")"
')"
    IFS=$'\037' read -r existing_mode new_mode rewritten <<< "$output"
    test::assert_eq '640' "$existing_mode" 'write_file must preserve existing mode on rewrite' || return 1
    test::assert_eq '600' "$new_mode" 'write_file must keep newly created files private by default' || return 1
    test::assert_eq 'new' "$rewritten" 'write_file must replace file contents' || return 1
}

case_reg_20_backup_file_preserves_metadata() {
    local output original_ts backup_ts backup_mode backup_content
    output="$(OPS_ROOT_ENV="$OPS_ROOT" TEST_TMP="$TEST_ENV_DIR" bash -c '
set -euo pipefail
work_dir="$TEST_TMP/backup-file"
mkdir -p "$work_dir"
target="$work_dir/source.conf"
printf "payload\n" > "$target"
chmod 640 "$target"
touch -t 202401020304.05 "$target"

export OPS_ROOT="$OPS_ROOT_ENV"
export OPS_CONFIG_DIR="$work_dir/conf"
export OPS_LOG_FILE="$work_dir/test.log"
export ADMIN_USER="nobody"
export SUDO_USER="nobody"
export USER="nobody"
source "$OPS_ROOT_ENV/core/env.sh"
source "$OPS_ROOT_ENV/core/utils.sh"

backup_path="$(backup_file "$target" | tail -n 1)"
printf "%s\037%s\037%s\037%s" "$(stat -c "%Y" "$target")" "$(stat -c "%Y" "$backup_path")" "$(stat -c "%a" "$backup_path")" "$(tr -d "\n" < "$backup_path")"
')"
    IFS=$'\037' read -r original_ts backup_ts backup_mode backup_content <<< "$output"
    test::assert_eq "$original_ts" "$backup_ts" 'backup_file must preserve source timestamps for rollback' || return 1
    test::assert_eq '640' "$backup_mode" 'backup_file must preserve file mode' || return 1
    test::assert_eq 'payload' "$backup_content" 'backup_file must preserve file content' || return 1
}

case_reg_21_safe_symlink_replaces_ops_managed_links_only() {
    local output managed_target foreign_target
    output="$(OPS_ROOT_ENV="$OPS_ROOT" TEST_TMP="$TEST_ENV_DIR" bash -c '
set -euo pipefail
work_dir="$TEST_TMP/safe-symlink"
mkdir -p "$work_dir"
managed_link="$work_dir/ops"
foreign_link="$work_dir/foreign"
ln -s /opt/ops/releases/old/ops "$managed_link"
ln -s /usr/local/bin/custom-ops "$foreign_link"

export OPS_ROOT="$OPS_ROOT_ENV"
export OPS_CONFIG_DIR="$work_dir/conf"
export OPS_LOG_FILE="$work_dir/test.log"
export ADMIN_USER="nobody"
export SUDO_USER="nobody"
export USER="nobody"
source "$OPS_ROOT_ENV/core/env.sh"
source "$OPS_ROOT_ENV/core/utils.sh"

safe_symlink /opt/ops/bin/ops "$managed_link" >/dev/null
managed_target="$(readlink "$managed_link")"
if safe_symlink /opt/ops/bin/ops "$foreign_link" >/dev/null; then
    printf "foreign symlink takeover should fail" >&2
    exit 1
fi
foreign_target="$(readlink "$foreign_link")"
printf "%s\037%s" "$managed_target" "$foreign_target"
')"
    IFS=$'\037' read -r managed_target foreign_target <<< "$output"
    test::assert_eq '/opt/ops/bin/ops' "$managed_target" 'safe_symlink must update OPS-managed links in place' || return 1
    test::assert_eq '/usr/local/bin/custom-ops' "$foreign_target" 'safe_symlink must refuse foreign symlink takeover' || return 1
}

case_reg_22_runtime_user_fails_closed_without_non_root_candidate() {
    local status message
    status="$(OPS_ROOT_ENV="$OPS_ROOT" TEST_TMP="$TEST_ENV_DIR" bash -c '
set -euo pipefail
work_dir="$TEST_TMP/runtime-user"
mkdir -p "$work_dir"
printf "OPS_RUNTIME_USER=root\nOPS_ADMIN_USER=root\n" > "$work_dir/ops.conf"

export OPS_ROOT="$OPS_ROOT_ENV"
export OPS_CONFIG_DIR="$work_dir"
export OPS_LOG_FILE="$work_dir/test.log"
export ADMIN_USER="root"
export SUDO_USER="root"
export USER="root"
source "$OPS_ROOT_ENV/core/env.sh"
export ADMIN_USER=""
source "$OPS_ROOT_ENV/core/utils.sh"
source "$OPS_ROOT_ENV/core/system.sh"

if ops_runtime_user >/dev/null 2>"$work_dir/runtime.err"; then
    printf success
else
    printf fail
fi
')"
    test::assert_eq 'fail' "$status" 'ops_runtime_user must fail closed when only root candidates exist' || return 1
}

case_reg_23_prompt_helpers_fail_cleanly_without_tty() {
    local output status message
    output="$(OPS_ROOT_ENV="$OPS_ROOT" TEST_TMP="$TEST_ENV_DIR" bash -c '
set -euo pipefail
work_dir="$TEST_TMP/prompt-no-tty"
mkdir -p "$work_dir"
source "$OPS_ROOT_ENV/core/ui.sh"
tty_is_available() { return 1; }

set +e
prompt_confirm "Proceed?" >/dev/null 2>"$work_dir/prompt.err"
status=$?
set -e
message="$(<"$work_dir/prompt.err")"
printf "%s\037%s" "$status" "$message"
')"
    IFS=$'\037' read -r status message <<< "$output"
    test::assert_eq '1' "$status" 'prompt_confirm must fail cleanly when no tty is available' || return 1
    test::assert_contains "$message" 'Interactive terminal unavailable.' 'prompt helpers must emit a controlled non-tty error' || return 1
}

case_reg_24_high_risk_callers_use_shared_wrappers() {
    local cliproxyapi_content node_content security_content nginx_content
    cliproxyapi_content="$(<"${OPS_ROOT}/modules/cli-proxy-api.sh")"
    node_content="$(<"${OPS_ROOT}/modules/node.sh")"
    security_content="$(<"${OPS_ROOT}/modules/security.sh")"
    nginx_content="$(<"${OPS_ROOT}/modules/nginx.sh")"

    test::assert_contains "$cliproxyapi_content" '_nginx_commit_vhost "$vhost_name" "$staged_file" || return 1' 'CLIProxyAPI domain link must delegate validation/reload/rollback to the shared transactional wrapper' || return 1
    test::assert_not_contains "$cliproxyapi_content" $'    nginx -t\n    service_enable nginx\n    service_reload nginx' 'CLIProxyAPI domain link must not bypass nginx_validate via legacy direct reload sequence' || return 1

    test::assert_contains "$node_content" 'if nginx_validate > /dev/null 2>&1; then' 'Node app removal must validate nginx through shared wrapper' || return 1
    test::assert_not_contains "$node_content" 'if nginx -t > /dev/null 2>&1; then' 'Node app removal must not bypass nginx_validate' || return 1

    test::assert_contains "$security_content" 'ufw_allow 80/tcp "HTTP"' 'Security UFW baseline must use shared allow wrapper for HTTP' || return 1
    test::assert_contains "$security_content" 'ufw_allow 443/tcp "HTTPS"' 'Security UFW baseline must use shared allow wrapper for HTTPS' || return 1
    test::assert_contains "$security_content" 'ufw delete allow 8317/tcp' 'Security UFW baseline must remove public ALLOW 8317/tcp rules' || return 1
    test::assert_not_contains "$security_content" 'ufw_deny 8317/tcp' 'Security UFW baseline must not force a DENY rule for 8317/tcp' || return 1
    test::assert_contains "$security_content" 'if ! service_reload "$ssh_svc" >/dev/null 2>&1; then' 'Security SSH toggles must gate success on shared reload wrapper' || return 1
    test::assert_not_contains "$security_content" 'service_reload "$ssh_svc" >/dev/null 2>&1 || true' 'Security SSH toggles must not swallow shared reload failures' || return 1
    test::assert_not_contains "$security_content" 'systemctl reload "$ssh_svc" >/dev/null 2>&1 || true' 'Security SSH toggles must not bypass service_reload' || return 1
    test::assert_contains "$security_content" 'ufw_status' 'Security status views must use the shared UFW status wrapper where verbose output is shown' || return 1

    test::assert_contains "$nginx_content" 'nginx_status() { nginx_validate && service_status nginx || true; }' 'Nginx status must validate through shared wrapper' || return 1
    test::assert_contains "$nginx_content" 'if ! nginx_validate; then' 'Nginx helper paths must use shared validation wrapper' || return 1
    test::assert_not_contains "$nginx_content" $'_nginx_test_and_reload() {\n    if ! nginx -t; then' 'Nginx reload helper must not bypass nginx_validate' || return 1
}

case_reg_25_capacity_detection_tracks_total_and_available_disk() {
    local output disk_total disk_avail expected_total expected_avail
    output="$(OPS_ROOT_ENV="$OPS_ROOT" TEST_TMP="$TEST_ENV_DIR" bash -c '
set -euo pipefail
work_dir="$TEST_TMP/capacity-detect"
mkdir -p "$work_dir/conf"

export OPS_ROOT="$OPS_ROOT_ENV"
export OPS_CONFIG_DIR="$work_dir/conf"
export OPS_LOG_FILE="$work_dir/test.log"
export ADMIN_USER="root"
export SUDO_USER="root"
export USER="root"
source "$OPS_ROOT_ENV/core/env.sh"

expected_total="$(df -BG / | awk '\''NR==2 { gsub("G","",$2); print $2 }'\'')"
expected_avail="$(df -BG / | awk '\''NR==2 { gsub("G","",$4); print $4 }'\'')"
printf "%s\037%s\037%s\037%s" "$DISK_GB" "${DISK_AVAIL_GB:-}" "$expected_total" "$expected_avail"
')"
    IFS=$'\037' read -r disk_total disk_avail expected_total expected_avail <<< "$output"
    test::assert_eq "$expected_total" "$disk_total" 'detect_resources must keep DISK_GB as total root disk' || return 1
    test::assert_eq "$expected_avail" "$disk_avail" 'detect_resources must expose DISK_AVAIL_GB as available root disk' || return 1
}

case_reg_26_capacity_schema_and_docs_aligned() {
    local env_content install_content monitoring_content perf_content arch_content inventory_content flow_content
    env_content="$(<"${OPS_ROOT}/core/env.sh")"
    install_content="$(<"${REPO_ROOT}/install/ops-install.sh")"
    monitoring_content="$(<"${OPS_ROOT}/modules/monitoring.sh")"
    perf_content="$(<"${REPO_ROOT}/docs/reference/PERF-TUNING.md")"
    arch_content="$(<"${REPO_ROOT}/docs/reference/ARCHITECTURE.md")"
    inventory_content="$(<"${REPO_ROOT}/docs/reference/RUNTIME-ARTEFACT-INVENTORY.md")"
    flow_content="$(<"${REPO_ROOT}/docs/operator/FLOW-INSTALL.md")"

    test::assert_contains "$env_content" 'DISK_AVAIL_GB=' 'core env must expose available disk as a distinct field' || return 1
    test::assert_contains "$install_content" 'DISK_AVAIL_GB="${DISK_AVAIL_GB}"' 'installer must persist available disk separately in capacity.conf' || return 1
    test::assert_contains "$monitoring_content" 'DISK_AVAIL_GB="${DISK_AVAIL_GB}"' 'monitoring refresh must persist available disk separately in capacity.conf' || return 1
    test::assert_contains "$monitoring_content" 'Disk:       %s GB total, %s GB available' 'monitoring refresh output must show both total and available disk' || return 1
    test::assert_contains "$perf_content" 'Define rough tiers based on RAM only.' 'performance tuning docs must describe RAM-only tier selection' || return 1
    test::assert_contains "$perf_content" '>= 1500 MB and < 5000 MB RAM' 'performance tuning docs must keep the exact M-tier boundary' || return 1
    test::assert_contains "$flow_content" 'Compute `OPS_TIER` from RAM only' 'install flow docs must describe RAM-only tier selection' || return 1
    test::assert_contains "$flow_content" 'shell-sourceable key=value file' 'install flow docs must keep capacity.conf shell-sourceable' || return 1
    test::assert_contains "$arch_content" 'DISK_AVAIL_GB' 'architecture docs must include the available disk field in capacity.conf schema' || return 1
    test::assert_contains "$inventory_content" 'shell-sourceable key=value' 'runtime inventory docs must keep capacity.conf format aligned' || return 1
}

case_reg_28_ownership_sensitive_writers_normalize_modes() {
    local php_content cliproxyapi_content nginx_content
    php_content="$(<"${OPS_ROOT}/modules/php.sh")"
    cliproxyapi_content="$(<"${OPS_ROOT}/modules/cli-proxy-api.sh")"
    nginx_content="$(<"${OPS_ROOT}/modules/nginx.sh")"

    test::assert_contains "$php_content" 'chmod 0644 "$pool_file"' 'PHP pool writer must normalize new pool files to 0644' || return 1
    test::assert_contains "$php_content" 'chown root:root "$pool_file"' 'PHP pool writer must normalize pool ownership to root:root' || return 1
    test::assert_contains "$cliproxyapi_content" 'chmod 0644 "$staged_file"' 'CLIProxyAPI staged vhost writer must normalize nginx vhost mode before commit' || return 1
    test::assert_contains "$cliproxyapi_content" 'chown root:root "$staged_file"' 'CLIProxyAPI staged vhost writer must normalize nginx vhost ownership before commit' || return 1
    test::assert_contains "$nginx_content" 'chmod 0644 "$state_file"' 'Domain state writer must normalize state-file mode' || return 1
    test::assert_contains "$nginx_content" 'chown root:root "$state_file"' 'Domain state writer must normalize state-file ownership' || return 1
    test::assert_contains "$nginx_content" 'chmod 0644 "$output"' 'Template-based nginx writers must normalize config mode' || return 1
    test::assert_contains "$nginx_content" 'chown root:root "$output"' 'Template-based nginx writers must normalize config ownership' || return 1
    test::assert_contains "$nginx_content" 'chmod 0644 "$available"' 'PHP vhost writer must normalize generated config mode after append' || return 1
    test::assert_contains "$nginx_content" 'chown root:root "$available"' 'PHP vhost writer must normalize generated config ownership after append' || return 1
}

case_reg_29_rollback_helpers_shared_and_installer_stages_once() {
    local utils_content security_content install_content
    utils_content="$(<"${OPS_ROOT}/core/utils.sh")"
    security_content="$(<"${OPS_ROOT}/modules/security.sh")"
    install_content="$(<"${REPO_ROOT}/install/ops-install.sh")"

    test::assert_contains "$utils_content" 'snapshot_path_state()' 'shared snapshot helper missing from core/utils.sh' || return 1
    test::assert_contains "$utils_content" 'restore_path_snapshot()' 'shared restore helper missing from core/utils.sh' || return 1
    test::assert_contains "$utils_content" 'snapshot_ufw_state()' 'shared UFW snapshot helper missing from core/utils.sh' || return 1
    test::assert_contains "$utils_content" 'restore_ufw_state()' 'shared UFW restore helper missing from core/utils.sh' || return 1

    test::assert_not_contains "$security_content" 'security_snapshot_path()' 'security module must not keep its own path snapshot implementation' || return 1
    test::assert_not_contains "$security_content" 'security_restore_path_snapshot()' 'security module must not keep its own path restore implementation' || return 1
    test::assert_not_contains "$install_content" 'installer_snapshot_path()' 'installer must not keep its own path snapshot implementation' || return 1
    test::assert_not_contains "$install_content" 'installer_restore_path_snapshot()' 'installer must not keep its own path restore implementation' || return 1
    test::assert_contains "$install_content" 'source "${OPS_INSTALL_SOURCE_OPS}/core/utils.sh"' 'installer must load shared rollback helpers from the staged source tree' || return 1
    test::assert_not_contains "$install_content" 'staged_root=' 'installer must not build an intermediate staged-root mirror' || return 1
    test::assert_contains "$install_content" 'Failed to build the candidate OPS runtime tree.' 'installer must build the candidate tree directly from extracted source' || return 1
}

case_reg_30_security_state_changes_fail_closed() {
    local security_content
    security_content="$(<"${OPS_ROOT}/modules/security.sh")"

    test::assert_contains "$security_content" 'ops_conf_set "ops.conf" "OPS_SSH_TCP_FORWARDING" "$tcp_forwarding"' 'SSH OPS state restore must include TCP forwarding' || return 1
    test::assert_not_contains "$security_content" 'sysctl -p "$SECURITY_SYSCTL_OPS_CONF" >/dev/null 2>&1 || true' 'Security sysctl baseline must not swallow live apply failures' || return 1
    test::assert_contains "$security_content" 'if [[ "$current_password_auth" == "no" ]] && ! _security_has_authorized_keys "$admin_user"; then' 'SSH port change must revalidate key presence before preserving key-only auth' || return 1
    test::assert_contains "$security_content" 'That SSH public key is already authorized.' 'SSH key add path must reject duplicate keys' || return 1
    test::assert_contains "$security_content" 'if [[ -f "$auth_keys" ]] && ! backup_file "$auth_keys" >/dev/null 2>&1; then' 'SSH key add path must back up authorized_keys before mutation' || return 1
    test::assert_contains "$security_content" 'if ! backup_file "$auth_keys" >/dev/null 2>&1; then' 'SSH key remove path must back up authorized_keys before mutation' || return 1
    test::assert_not_contains "$security_content" $'ops_conf_set "ops.conf" "OPS_SSH_TCP_FORWARDING" "yes"\n                security_write_sshd_hardening_include' 'TCP forwarding enable must not persist ops.conf before sshd validation and reload' || return 1
    test::assert_not_contains "$security_content" $'ops_conf_set "ops.conf" "OPS_SSH_TCP_FORWARDING" "no"\n                security_write_sshd_hardening_include' 'TCP forwarding disable must not persist ops.conf before sshd validation and reload' || return 1
}

case_reg_31_setup_wizard_flow_stays_fail_closed() {
    local wizard_content monitoring_content
    wizard_content="$(<"${OPS_ROOT}/modules/setup-wizard.sh")"
    monitoring_content="$(<"${OPS_ROOT}/modules/monitoring.sh")"

    test::assert_contains "$wizard_content" 'echo "  8) Install Logging & Monitoring"' 'setup wizard must expose the monitoring step in the menu' || return 1
    test::assert_contains "$wizard_content" 'apt_upgrade' 'setup wizard step 0 must offer apt upgrade' || return 1
    test::assert_contains "$wizard_content" 'jq logrotate ufw fail2ban' 'setup wizard step 0 must install jq and logrotate with the base tools' || return 1
    test::assert_contains "$wizard_content" '_wizard_clear_done "$step_key"' 'setup wizard reruns must clear stale done flags before re-apply' || return 1
    test::assert_contains "$wizard_content" 'WIZARD_PHP_VERSIONS_LAST_RUN="$(_wizard_detect_installed_php_versions)"' 'setup wizard must preserve PHP verification context on reruns' || return 1
    test::assert_contains "$wizard_content" 'WIZARD_PHP_VERSIONS_LAST_RUN="${versions_to_install[*]}"' 'setup wizard must record selected PHP versions for final verification' || return 1
    test::assert_contains "$wizard_content" 'WIZARD_DONE_FULL_WIZARD was not written' 'setup wizard must fail closed when final verification is incomplete' || return 1
    test::assert_contains "$wizard_content" 'for step in system_update security nginx node php database monitoring verification; do' 'setup wizard summary must include monitoring and verification steps' || return 1
    test::assert_contains "$wizard_content" '/etc/logrotate.d/nginx-ops' 'setup wizard must validate the OPS-managed nginx logrotate artefact' || return 1
    test::assert_contains "$monitoring_content" 'monitoring_apply_baseline()' 'monitoring baseline helper missing' || return 1
    test::assert_contains "$monitoring_content" '/etc/logrotate.d/ops' 'monitoring baseline must reconcile OPS logrotate state' || return 1
    test::assert_contains "$monitoring_content" '/etc/logrotate.d/nginx-ops' 'monitoring baseline must validate the OPS-managed nginx logrotate artefact' || return 1
    if [[ -e "${OPS_ROOT}/modules/templates/logrotate/ops-log-rotation.sh" ]]; then
        printf 'orphaned ops-log-rotation.sh must be removed from the active tree\n' >&2
        return 1
    fi
}

case_reg_32_cf_credentials_split_contract_present() {
    local nginx_content
    nginx_content="$(<"${OPS_ROOT}/modules/nginx.sh")"

    test::assert_contains "$nginx_content" 'CF_CERTBOT_CREDS_FILE="/etc/ops/cloudflare-certbot.ini"' 'Cloudflare DNS-01 flow must use a dedicated certbot credentials file' || return 1
    test::assert_contains "$nginx_content" 'CF_CREDS_FILE is shell-sourceable only — NEVER overwrite it with INI format.' 'Cloudflare token state must remain separated from certbot INI credentials' || return 1
    test::assert_contains "$nginx_content" "printf 'dns_cloudflare_api_token = %s\\n' \"\$CF_API_TOKEN\" > \"\$CF_CERTBOT_CREDS_FILE\"" 'DNS-01 issuance must write INI credentials to the dedicated certbot file' || return 1
    test::assert_contains "$nginx_content" "printf 'CF_API_TOKEN=\"%s\"\\n' \"\$new_token\" > \"\$CF_CREDS_FILE\"" 'Cloudflare token save path must keep cloudflare.conf shell-sourceable' || return 1
    test::assert_not_contains "$nginx_content" "printf 'dns_cloudflare_api_token = %s\\n' \"\$new_token\" > \"\$CF_CREDS_FILE\"" 'Cloudflare token save path must not overwrite cloudflare.conf with certbot INI format' || return 1
}

case_reg_33_ai_shell_secret_contracts_present() {
    local codex_content claude_content
    codex_content="$(<"${OPS_ROOT}/modules/codex-cli.sh")"
    claude_content="$(<"${OPS_ROOT}/modules/ai-agent.sh")"

    test::assert_contains "$codex_content" '_codex_admin_bash_profile()' 'Codex bash_profile helper missing' || return 1
    test::assert_not_contains "$codex_content" '/home/$ADMIN_USER/.bash_profile' 'Codex must not hardcode /home/$ADMIN_USER/.bash_profile' || return 1
    test::assert_contains "$codex_content" "tr -d '\\\\r\\\\n' < \${quoted_key_file}" 'Codex managed shell blocks must load secrets from canonical files' || return 1
    test::assert_not_contains "$codex_content" 'export CLI_PROXY_API_KEY="${api_key}"' 'Codex must not inline raw CLIProxyAPI secrets into shell blocks' || return 1
    test::assert_not_contains "$codex_content" 'api_key = "' 'Codex config templates must not inline api_key in TOML' || return 1

    test::assert_contains "$claude_content" 'api_key_status="SET"' 'Claude CLI test must report API key presence, not secret contents' || return 1
    test::assert_contains "$claude_content" 'echo "  API Key       : $api_key_status"' 'Claude CLI test output must stay status-only' || return 1
    test::assert_contains "$claude_content" '_claude_env_quote()' 'Telegram env writer must use shared dotenv quoting helper' || return 1
    test::assert_contains "$claude_content" '_claude_env_append_line "${tg_env}" "TELEGRAM_BOT_TOKEN" "$bot_token"' 'Telegram env writer must write quoted dotenv entries' || return 1
    test::assert_contains "$claude_content" 'ops_run_as_user "$ADMIN_USER" bash -c "$launch_cmd"' 'Telegram fallback launch must run as admin user' || return 1
    test::assert_contains "$claude_content" 'Continue installing the Vietnamese fix?' 'Vietnamese fix install must require explicit confirmation' || return 1
    test::assert_contains "$claude_content" 'This action clones and executes third-party code from GitHub.' 'Vietnamese fix install must warn before executing third-party code' || return 1
    test::assert_contains "$claude_content" 'Continue installing the Telegram bot?' 'Telegram bot install must require explicit confirmation' || return 1
    test::assert_contains "$claude_content" 'This action clones and installs third-party code from GitHub via pip.' 'Telegram bot install must warn before executing third-party code' || return 1
}

case_reg_34_ai_runtime_docs_aligned() {
    local codex_spec claude_spec architecture_content inventory_content trace_content menu_reference_content user_guide_content
    codex_spec="$(<"${REPO_ROOT}/docs/reference/CODEX-CLI-SPEC.md")"
    claude_spec="$(<"${REPO_ROOT}/docs/reference/CLAUDE-CODE-SPEC.md")"
    architecture_content="$(<"${REPO_ROOT}/docs/reference/ARCHITECTURE.md")"
    inventory_content="$(<"${REPO_ROOT}/docs/reference/RUNTIME-ARTEFACT-INVENTORY.md")"
    trace_content="$(<"${REPO_ROOT}/docs/reference/SOURCE-TO-RUNTIME-TRACE.md")"
    menu_reference_content="$(<"${REPO_ROOT}/docs/operator/MENU-REFERENCE.md")"
    user_guide_content="$(<"${REPO_ROOT}/USER_GUIDE.md")"

    test::assert_contains "$codex_spec" '/etc/ops/.cli-proxy-api-key' 'Codex spec must document the CLIProxyAPI canonical key path' || return 1
    test::assert_contains "$codex_spec" '/etc/ops/.codex-api-key' 'Codex spec must document the direct/custom canonical key path' || return 1
    test::assert_contains "$codex_spec" 'http://127.0.0.1:8317/v1' 'Codex spec must preserve the local /v1 endpoint contract' || return 1

    test::assert_contains "$claude_spec" '~/.claude-api-key' 'Claude spec must document the canonical Claude key path' || return 1
    test::assert_not_contains "$claude_spec" 'masked API key' 'Claude spec must not claim test output prints masked API key content' || return 1
    test::assert_contains "$claude_spec" 'secret-file presence status' 'Claude spec must describe secret-file presence status, not key previews' || return 1
    test::assert_contains "$claude_spec" '~/claude-telegram/claude-telegram-bot.pid' 'Claude spec must document the Telegram PID path' || return 1
    test::assert_contains "$claude_spec" '~/claude-telegram-bot.log' 'Claude spec must document the Telegram log path' || return 1
    test::assert_contains "$claude_spec" 'http://127.0.0.1:8317' 'Claude spec must preserve the local endpoint without /v1' || return 1

    test::assert_contains "$architecture_content" '~/.claude-api-key' 'Architecture doc must include the canonical Claude key path' || return 1
    test::assert_contains "$inventory_content" '~/claude-telegram/.env' 'Runtime inventory must include the Telegram env path' || return 1
    test::assert_contains "$trace_content" '~/claude-telegram/claude-telegram-bot.pid' 'Source-to-runtime trace must include the Telegram PID path' || return 1
    test::assert_contains "$menu_reference_content" 'CLIProxyAPI, OpenAI API key, ChatGPT OAuth, custom endpoint' 'Menu reference must document all four Codex modes' || return 1
    test::assert_contains "$user_guide_content" '~/.claude-api-key' 'User guide must document the canonical Claude key path' || return 1
}

case_reg_35_snapshot_restore_helpers_roundtrip() {
    local output restored missing_state
    output="$(OPS_ROOT_ENV="$OPS_ROOT" TEST_TMP="$TEST_ENV_DIR" bash -c '
set -euo pipefail
work_dir="$TEST_TMP/snapshot-restore"
mkdir -p "$work_dir/conf" "$work_dir/snap"
target="$work_dir/target.conf"
missing="$work_dir/missing.conf"
printf "before\n" > "$target"
chmod 640 "$target"
export OPS_ROOT="$OPS_ROOT_ENV"
export OPS_CONFIG_DIR="$work_dir/conf"
export OPS_LOG_FILE="$work_dir/test.log"
export ADMIN_USER="nobody"
export SUDO_USER="nobody"
export USER="nobody"
source "$OPS_ROOT_ENV/core/env.sh"
source "$OPS_ROOT_ENV/core/utils.sh"
snapshot_path_state "$target" "$work_dir/snap" "target"
printf "after\n" > "$target"
restore_path_snapshot "$target" "$work_dir/snap" "target"
snapshot_path_state "$missing" "$work_dir/snap" "missing"
printf "ghost\n" > "$missing"
restore_path_snapshot "$missing" "$work_dir/snap" "missing"
printf "%s\037%s" "$(tr -d "\n" < "$target")" "$(if [[ -e "$missing" ]]; then printf present; else printf removed; fi)"
')"
    IFS=$'\037' read -r restored missing_state <<< "$output"
    test::assert_eq 'before' "$restored" 'restore_path_snapshot must restore previous file content' || return 1
    test::assert_eq 'removed' "$missing_state" 'restore_path_snapshot must remove paths that were absent at snapshot time' || return 1
}

case_reg_36_render_template_escapes_special_replacements() {
    local output rendered
    output="$(OPS_ROOT_ENV="$OPS_ROOT" TEST_TMP="$TEST_ENV_DIR" bash -c '
set -euo pipefail
work_dir="$TEST_TMP/render-template"
mkdir -p "$work_dir/conf"
tpl="$work_dir/sample.tpl"
cat > "$tpl" <<'"'"'EOF_TPL'"'"'
value={{VALUE}}|path={{PATH}}
EOF_TPL
export OPS_ROOT="$OPS_ROOT_ENV"
export OPS_CONFIG_DIR="$work_dir/conf"
export OPS_LOG_FILE="$work_dir/test.log"
export ADMIN_USER="nobody"
export SUDO_USER="nobody"
export USER="nobody"
source "$OPS_ROOT_ENV/core/env.sh"
source "$OPS_ROOT_ENV/core/utils.sh"
rendered="$(render_template "$tpl" "VALUE=A&B\\C" "PATH=/srv/app&logs")"
printf "%s" "$rendered"
')"
    rendered="$output"
    test::assert_eq 'value=A&B\C|path=/srv/app&logs' "$rendered" 'render_template must preserve ampersands and backslashes in replacement values' || return 1
}

case_reg_37_ops_conf_unset_preserves_other_keys_and_mode() {
    local output keep_value drop_value mode contents
    output="$(OPS_ROOT_ENV="$OPS_ROOT" TEST_TMP="$TEST_ENV_DIR" bash -c '
set -euo pipefail
work_dir="$TEST_TMP/ops-conf-unset"
mkdir -p "$work_dir/conf"
conf_file="$work_dir/conf/test.conf"
cat > "$conf_file" <<'"'"'EOF_CONF'"'"'
KEEP=alpha
DROP=beta
EOF_CONF
chmod 640 "$conf_file"
export OPS_ROOT="$OPS_ROOT_ENV"
export OPS_CONFIG_DIR="$work_dir/conf"
export OPS_LOG_FILE="$work_dir/test.log"
export ADMIN_USER="nobody"
export SUDO_USER="nobody"
export USER="nobody"
source "$OPS_ROOT_ENV/core/env.sh"
ops_conf_unset test.conf DROP
printf "%s\037%s\037%s\037%s" \
    "$(ops_conf_get test.conf KEEP)" \
    "$(ops_conf_get test.conf DROP)" \
    "$(stat -c "%a" "$conf_file")" \
    "$(tr "\n" "\f" < "$conf_file")"
')"
    IFS=$'\037' read -r keep_value drop_value mode contents <<< "$output"
    test::assert_eq 'alpha' "$keep_value" 'ops_conf_unset must preserve unrelated keys' || return 1
    test::assert_eq '' "$drop_value" 'ops_conf_unset must remove the requested key' || return 1
    test::assert_eq '640' "$mode" 'ops_conf_unset must preserve file mode metadata' || return 1
    test::assert_not_contains "$contents" 'DROP=' 'ops_conf_unset must remove the deleted key from file contents' || return 1
}

test::run_case 'REG-01' 'tty prompt anti-pattern absent' case_reg_01_tty_prompt_antipattern_absent
test::run_case 'REG-02' 'menu boundary wrapper present' case_reg_02_menu_boundary_wrapper_present
test::run_case 'REG-03' 'verify exit-zero contract present' case_reg_03_verify_exit_zero_contract_documented_in_code
test::run_case 'REG-04' 'ssh key guard present before disabling password auth' case_reg_04_security_guard_present_before_disable_password_auth
test::run_case 'REG-05' 'login hook contract uses SSH_CONNECTION' case_reg_05_login_hook_uses_ssh_connection_not_ssh_tty_doc_contract
test::run_case 'REG-06' 'CLIProxyAPI exposure regression guarded' case_reg_06_cliproxyapi_posture_contract_present
test::run_case 'REG-07' 'pm2 startup non-root contract documented' case_reg_07_pm2_startup_not_root_contract_present
test::run_case 'REG-08' 'pm2 runtime user wrapper present' case_reg_08_pm2_runtime_user_wrapper_present
test::run_case 'REG-09' 'secret permission contract present' case_reg_09_secret_permission_contract_present
test::run_case 'REG-10' 'config rewrite validates syntax' case_reg_10_config_rewrite_must_validate_syntax
test::run_case 'REG-11' 'CLIProxyAPI nginx boundary contract preserved' case_reg_11_cliproxyapi_vhost_preserves_global_rate_limit_zone
test::run_case 'REG-12' 'pm2 log contracts preserved' case_reg_12_pm2_logrotate_and_merge_logs_contract_present
test::run_case 'REG-13' 'pm2 read helpers centralized' case_reg_13_pm2_read_helpers_centralized
test::run_case 'REG-14' 'patch state check present in verify' case_reg_14_patch_state_check_present
test::run_case 'REG-15' 'runtime user check present in verify' case_reg_15_runtime_user_check_present
test::run_case 'REG-15.1' 'menu boundary contract stays local to menus' case_reg_15_1_menu_boundary_contract_not_hidden_in_callers
test::run_case 'REG-16' 'local client setup contracts present' case_reg_16_local_client_setup_contracts_present
test::run_case 'REG-17' 'admin user resolution prefers persisted and sudo state' case_reg_17_admin_user_resolution_prefers_persisted_then_sudo_user
test::run_case 'REG-18' 'ops conf round-trip and metadata contract present' case_reg_18_ops_conf_roundtrip_and_metadata_preserved
test::run_case 'REG-19' 'write_file preserves existing mode and keeps new files private' case_reg_19_write_file_preserves_existing_mode_and_keeps_new_files_private
test::run_case 'REG-20' 'backup_file preserves rollback metadata' case_reg_20_backup_file_preserves_metadata
test::run_case 'REG-21' 'safe_symlink only updates OPS-managed links' case_reg_21_safe_symlink_replaces_ops_managed_links_only
test::run_case 'REG-22' 'runtime user fails closed without non-root candidate' case_reg_22_runtime_user_fails_closed_without_non_root_candidate
test::run_case 'REG-23' 'prompt helpers fail cleanly without tty' case_reg_23_prompt_helpers_fail_cleanly_without_tty
test::run_case 'REG-24' 'high-risk callers use shared wrappers' case_reg_24_high_risk_callers_use_shared_wrappers
test::run_case 'REG-25' 'capacity detection tracks total and available disk' case_reg_25_capacity_detection_tracks_total_and_available_disk
test::run_case 'REG-26' 'capacity schema and docs stay aligned' case_reg_26_capacity_schema_and_docs_aligned
test::run_case 'REG-27' 'tty prompt contract stays centralized' case_reg_27_tty_prompt_contract_stays_centralized
test::run_case 'REG-28' 'ownership-sensitive writers normalize modes' case_reg_28_ownership_sensitive_writers_normalize_modes
test::run_case 'REG-29' 'rollback helpers shared and installer stages once' case_reg_29_rollback_helpers_shared_and_installer_stages_once
test::run_case 'REG-30' 'security state changes fail closed' case_reg_30_security_state_changes_fail_closed
test::run_case 'REG-31' 'setup wizard flow stays fail closed' case_reg_31_setup_wizard_flow_stays_fail_closed
test::run_case 'REG-32' 'Cloudflare credentials split contract present' case_reg_32_cf_credentials_split_contract_present
test::run_case 'REG-33' 'AI shell secret contract present' case_reg_33_ai_shell_secret_contracts_present
test::run_case 'REG-34' 'AI runtime docs stay aligned' case_reg_34_ai_runtime_docs_aligned
test::run_case 'REG-35' 'snapshot/restore helpers round-trip state' case_reg_35_snapshot_restore_helpers_roundtrip
test::run_case 'REG-36' 'template rendering preserves special replacement values' case_reg_36_render_template_escapes_special_replacements
test::run_case 'REG-37' 'ops_conf_unset preserves other keys and file mode' case_reg_37_ops_conf_unset_preserves_other_keys_and_mode
test::run_case 'SEC-01' 'password auth guard without key present' case_sec_01_password_auth_guard_without_key_present
test::run_case 'SEC-02' 'disable password auth requires key contract present' case_sec_02_disable_password_auth_requires_key_contract_present
test::run_case 'SEC-03' 'SSH transition keeps two ports contract present' case_sec_03_transition_keeps_two_ports_contract_present
test::run_case 'SEC-04' 'SSH finalize transition contract present' case_sec_04_finalize_transition_contract_present
test::run_case 'SEC-05' 'UFW baseline ports contract present' case_sec_05_ufw_baseline_ports_present
test::run_case 'SEC-06' 'CLIProxyAPI port 8317 must not be allowed' case_sec_06_ufw_must_not_allow_8317
test::run_case 'SEC-07' 'fail2ban tracks managed ports' case_sec_07_fail2ban_tracks_managed_ports
test::run_case 'SEC-08' 'PermitRootLogin disabled contract present' case_sec_08_permit_root_login_disabled_contract_present
test::run_case 'SEC-09' 'forwarding disabled contract present' case_sec_09_forwarding_disabled_contract_present
test::run_case 'SEC-09.1' 'keeping current port 22 stays allowed' case_sec_09_1_keep_current_port_22_contract_present
test::run_case 'SEC-09.2' 'authorized key matchers cover modern key types' case_sec_09_2_authorized_key_matchers_cover_modern_key_types
test::run_case 'SEC-09.3' 'SSH state persists only after full success' case_sec_09_3_ssh_state_persists_only_after_full_success
test::run_case 'SEC-09.4' 'host baseline swap contract present' case_sec_09_4_host_baseline_swap_contract_present
test::run_case 'INS-01' 'installer Ubuntu support contract present' case_ins_01_02_installer_os_contract_present
test::run_case 'INS-02' 'installer Ubuntu support contract present for 24.04' case_ins_01_02_installer_os_contract_present
test::run_case 'INS-03' 'unsupported OS rejection contract present' case_ins_03_unsupported_os_rejected_contract_present
test::run_case 'INS-04' 'existing admin user contract present' case_ins_04_existing_admin_user_contract_present
test::run_case 'INS-05' 'setup rerun contract present' case_ins_05_rerun_setup_contract_present
test::run_case 'INS-06' 'interactive login hook contract present' case_ins_06_07_08_login_hook_contract_present
test::run_case 'INS-07' 'non-interactive login hook guard contract present' case_ins_06_07_08_login_hook_contract_present
test::run_case 'INS-08' 'SSH_CONNECTION login hook contract present' case_ins_06_07_08_login_hook_contract_present
test::run_case 'INS-09' 'installer rollback runbook contract present' case_ins_09_installer_rollback_contract_present
test::run_case 'WEB-01' 'nginx install contract present' case_web_01_nginx_install_contract_present
test::run_case 'WEB-02' 'node domain contract present' case_web_02_node_domain_contract_present
test::run_case 'WEB-03' 'php domain contract present' case_web_03_php_domain_contract_present
test::run_case 'WEB-04' 'static domain contract present' case_web_04_static_domain_contract_present
test::run_case 'WEB-05' 'domain removal preserves web root contract present' case_web_05_remove_domain_keeps_root_contract_present
test::run_case 'WEB-06' 'nginx reload blocked on syntax error contract present' case_web_06_nginx_reload_blocked_on_error_contract_present
test::run_case 'WEB-07' 'SSL issue contract present' case_web_07_ssl_issue_contract_present
test::run_case 'WEB-08' 'SSL status contract present' case_web_08_ssl_status_contract_present
test::run_case 'WEB-09' 'CLIProxyAPI nginx boundary contract present' case_web_09_web_10_cliproxyapi_nginx_boundary_contract_present
test::run_case 'WEB-10' 'nginx remains sole public entrypoint contract present' case_web_09_web_10_cliproxyapi_nginx_boundary_contract_present
test::run_case 'WEB-11' 'transactional vhost commit contract present' case_web_11_transactional_vhost_commit_contract_present
test::run_case 'NODE-01' 'Node LTS install contract present' case_node_01_node_lts_install_contract_present
test::run_case 'NODE-02' 'PM2 non-root contract present' case_node_02_pm2_not_root_contract_present
test::run_case 'NODE-03' 'Node service list contract present' case_node_03_04_05_06_07_node_menu_contract_present
test::run_case 'NODE-04' 'Node add app contract present' case_node_03_04_05_06_07_node_menu_contract_present
test::run_case 'NODE-05' 'Node restart contract present' case_node_03_04_05_06_07_node_menu_contract_present
test::run_case 'NODE-06' 'Node logs contract present' case_node_03_04_05_06_07_node_menu_contract_present
test::run_case 'NODE-07' 'Node remove contract present' case_node_03_04_05_06_07_node_menu_contract_present
test::run_case 'NODE-08' 'PM2 merge_logs contract present' case_node_08_09_10_pm2_template_contract_present
test::run_case 'NODE-09' 'PM2 logrotate contract present' case_node_08_09_10_pm2_template_contract_present
test::run_case 'NODE-10' 'PM2 memory contract present' case_node_08_09_10_pm2_template_contract_present
test::run_case 'PHP-01' 'PHP versions/removal guard contract present' case_php_01_php_versions_contract_present
test::run_case 'PHP-02' 'PHP pool/socket contract present' case_php_02_php_pool_socket_contract_present
test::run_case 'PHP-03' 'PHP domain state contract present' case_php_03_php_domain_state_contract_present
test::run_case 'PHP-04' 'PHP FPM-only hardening contract present' case_php_04_fpm_only_hardening_contract_present
test::run_case 'PHP-05' 'PHP per-pool override contract present' case_php_05_per_pool_override_contract_present
test::run_case 'PHP-06' 'PHP rollback/diagnostics contract present' case_php_06_transaction_and_diagnostics_contract_present
test::run_case 'DB-01' 'DB install contract present' case_db_01_02_03_04_05_db_contracts_present
test::run_case 'DB-02' 'DB secret permission contract present' case_db_01_02_03_04_05_db_contracts_present
test::run_case 'DB-03' 'DB secure setup contract present' case_db_01_02_03_04_05_db_contracts_present
test::run_case 'DB-04' 'DB bind posture contract present' case_db_01_02_03_04_05_db_contracts_present
test::run_case 'DB-05' 'DB create user/db contract present' case_db_01_02_03_04_05_db_contracts_present
test::run_case 'DB-06' 'DB backup helper contract present' case_db_06_backup_helper_contract_present
test::run_case 'CPA-01' 'CLIProxyAPI install contract present' case_cpa_01_02_03_04_05_06_07_08_09_cliproxyapi_contracts_present
test::run_case 'CPA-02' 'CLIProxyAPI loopback bind contract present' case_cpa_01_02_03_04_05_06_07_08_09_cliproxyapi_contracts_present
test::run_case 'CPA-03' 'CLIProxyAPI secret permission contract present' case_cpa_01_02_03_04_05_06_07_08_09_cliproxyapi_contracts_present
test::run_case 'CPA-04' 'CLIProxyAPI domain link contract present' case_cpa_01_02_03_04_05_06_07_08_09_cliproxyapi_contracts_present
test::run_case 'CPA-05' 'CLIProxyAPI verify contract present' case_cpa_01_02_03_04_05_06_07_08_09_cliproxyapi_contracts_present
test::run_case 'CPA-06' 'CLIProxyAPI API key toggle contract present' case_cpa_01_02_03_04_05_06_07_08_09_cliproxyapi_contracts_present
test::run_case 'CPA-07' 'CLIProxyAPI update preserve-state contract present' case_cpa_01_02_03_04_05_06_07_08_09_cliproxyapi_contracts_present
test::run_case 'CPA-08' 'CLIProxyAPI SSL/vhost re-render contract present' case_cpa_01_02_03_04_05_06_07_08_09_cliproxyapi_contracts_present
test::run_case 'CPA-09' 'CLIProxyAPI schema contract present' case_cpa_01_02_03_04_05_06_07_08_09_cliproxyapi_contracts_present
test::run_case 'CPA-10' 'Quota shortcut helper contract present' case_cpa_10_11_12_13_quota_helper_contracts_present
test::run_case 'CPA-11' 'Quota shortcut defaults contract present' case_cpa_10_11_12_13_quota_helper_contracts_present
test::run_case 'CPA-12' 'Quota management key warning contract present' case_cpa_10_11_12_13_quota_helper_contracts_present
test::run_case 'CPA-13' 'CLIProxyAPI quota menu doc contract present' case_cpa_10_11_12_13_quota_helper_contracts_present
test::run_case 'CPA-14' 'CLIProxyAPI bootstrap auth submenu contract present' case_cpa_14_bootstrap_auth_submenu_contract_present
test::run_case 'MON-01' 'verify exit-zero contract present' case_mon_01_02_03_04_05_monitoring_contracts_present
test::run_case 'MON-02' 'quick logs contract present' case_mon_01_02_03_04_05_monitoring_contracts_present
test::run_case 'MON-03' 'monitoring menu boundary contract present' case_mon_01_02_03_04_05_monitoring_contracts_present
test::run_case 'MON-04' 'scheduled checks idempotence contract present' case_mon_01_02_03_04_05_monitoring_contracts_present
test::run_case 'MON-05' 'notification disable-path contract present' case_mon_01_02_03_04_05_monitoring_contracts_present
test::run_case 'MON-06' 'monitoring baseline contract present' case_mon_06_monitoring_baseline_contract_present
test::run_case 'FILE-01' 'secret file contract present' case_file_01_02_03_04_file_contracts_present
test::run_case 'FILE-02' 'no-secret-output contract present' case_file_01_02_03_04_file_contracts_present
test::run_case 'FILE-03' 'shell-sourceable config contract present' case_file_01_02_03_04_file_contracts_present
test::run_case 'FILE-04' 'backup-before-rewrite contract present' case_file_01_02_03_04_file_contracts_present
test::run_case 'FILE-05' 'web root ownership contract present' case_file_05_web_root_ownership_contract_present

test::finish
