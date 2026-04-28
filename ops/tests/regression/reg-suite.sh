#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ops/tests/regression/lib.sh
source "${SCRIPT_DIR}/lib.sh"

TEST_SUITE_NAME="reg-suite"
test::init

case_reg_01_tty_prompt_antipattern_absent() {
    local hits
    hits="$(grep -R -n -E "read[[:space:]]+-[^\r\n]*-p[^\r\n]*<[[:space:]]*/dev/tty" "${OPS_ROOT}" 2>/dev/null || true)"
    test::assert_eq "" "$hits" "prompt anti-pattern must stay absent" || return 1
}

case_reg_02_menu_boundary_wrapper_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/monitoring.sh")"
    test::assert_contains "$content" '_monitoring_menu_run()' 'monitoring menu wrapper missing' || return 1
    test::assert_contains "$content" 'return 0' 'monitoring menu wrapper must absorb non-zero' || return 1
}

case_reg_03_verify_exit_zero_contract_documented_in_code() {
    local content
    content="$(<"${OPS_ROOT}/modules/verify.sh")"
    test::assert_contains "$content" 'return 0' 'verify functions must return 0' || return 1
    test::assert_contains "$content" '_vs_fail' 'verify fail formatter missing' || return 1
    test::assert_contains "$content" '_vs_warn' 'verify warn formatter missing' || return 1
}

case_reg_04_security_guard_present_before_disable_password_auth() {
    local content
    content="$(<"${OPS_ROOT}/modules/security.sh")"
    test::assert_contains "$content" '_security_has_authorized_keys' 'authorized key guard missing' || return 1
    test::assert_contains "$content" 'PasswordAuthentication' 'password auth control missing' || return 1
}

case_reg_05_login_hook_uses_ssh_connection_not_ssh_tty_doc_contract() {
    local content
    content="$(<"${REPO_ROOT}/docs/operator/MENU-REFERENCE.md")"
    test::assert_contains "$content" 'SSH_CONNECTION' 'login hook must use SSH_CONNECTION contract' || return 1
}

case_reg_06_cliproxyapi_posture_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/verify.sh")"
    test::assert_contains "$content" '8317/tcp' 'verify must check public exposure of 8317' || return 1
    test::assert_contains "$content" 'remove allow rule and keep only nginx public' 'verify hint for 8317 exposure missing' || return 1
}

case_reg_07_pm2_startup_not_root_contract_present() {
    local content
    content="$(<"${REPO_ROOT}/docs/reference/KNOWN-RISKS-PATTERNS.md")"
    test::assert_contains "$content" 'pm2-root.service' 'pm2 root startup regression coverage missing' || return 1
}

case_reg_08_pm2_runtime_user_wrapper_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/verify.sh")"
    test::assert_contains "$content" '_vs_run_as_runtime_user' 'runtime user wrapper missing' || return 1
}

case_reg_09_secret_permission_contract_present() {
    local content
    content="$(<"${REPO_ROOT}/docs/reference/KNOWN-RISKS-PATTERNS.md")"
    test::assert_contains "$content" 'chmod 600 <file> && chown $ADMIN_USER:$ADMIN_USER <file>' 'secret permission contract missing' || return 1
}

case_reg_10_config_rewrite_must_validate_syntax() {
    local content
    content="$(<"${REPO_ROOT}/rules/BASH-STYLE.md")"
    test::assert_contains "$content" 'nginx -t' 'syntax validation contract missing' || return 1
}

case_reg_11_cliproxyapi_vhost_preserves_global_rate_limit_zone() {
    local content
    content="$(<"${OPS_ROOT}/modules/templates/nginx/cli-proxy-api.vhost.conf.tpl")"
    test::assert_contains "$content" 'cli-proxy-api.' 'CLIProxyAPI vhost naming contract missing' || return 1
    test::assert_contains "$content" 'proxy_buffering       off' 'CLIProxyAPI proxy buffering contract missing' || return 1
}

case_reg_12_pm2_logrotate_and_merge_logs_contract_present() {
    local content
    content="$(<"${REPO_ROOT}/docs/reference/KNOWN-RISKS-PATTERNS.md")"
    test::assert_contains "$content" 'pm2-logrotate' 'pm2 logrotate regression contract missing' || return 1
    test::assert_contains "$content" 'merge_logs: true' 'merge_logs regression contract missing' || return 1
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

case_sec_01_password_auth_guard_without_key_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/security.sh")"
    test::assert_contains "$content" "_security_has_authorized_keys" 'authorized key helper missing' || return 1
    test::assert_contains "$content" 'PasswordAuthentication will remain ENABLED to prevent SSH lockout.' 'safe password auth fallback missing' || return 1
}

case_sec_02_disable_password_auth_requires_key_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/security.sh")"
    test::assert_contains "$content" 'Disable PasswordAuthentication after transition completes?' 'disable password auth prompt missing' || return 1
}

case_sec_03_transition_keeps_two_ports_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/security.sh")"
    test::assert_contains "$content" 'OPS_SSH_TRANSITION_PORT' 'transition port state missing' || return 1
    test::assert_contains "$content" 'security_write_sshd_hardening_include "$new_port" "$password_auth" "$old_port"' 'two-port transition contract missing' || return 1
}

case_sec_04_finalize_transition_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/security.sh")"
    test::assert_contains "$content" 'Finalize SSH transition and remove old port' 'finalize SSH prompt missing' || return 1
    test::assert_contains "$content" 'security_finalize_ssh_transition()' 'finalize SSH handler missing' || return 1
    test::assert_contains "$content" 'Old SSH port ${old_port} removed from managed config and firewall.' 'port finalization success message missing' || return 1
}

case_sec_05_ufw_baseline_ports_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/security.sh")"
    test::assert_contains "$content" 'ufw allow 80/tcp' 'HTTP allow baseline missing' || return 1
    test::assert_contains "$content" 'ufw allow 443/tcp' 'HTTPS allow baseline missing' || return 1
}

case_sec_06_ufw_must_not_allow_8317() {
    local content
    content="$(<"${OPS_ROOT}/modules/cli-proxy-api.sh")"
    test::assert_contains "$content" 'ufw delete allow 8317/tcp' '8317 ALLOW cleanup missing' || return 1
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
    test::assert_contains "$content" 'AllowAgentForwarding no' 'agent forwarding hardening missing' || return 1
}

case_ins_01_02_installer_os_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/install/ops-install.sh")"
    test::assert_contains "$content" '22.04' 'Ubuntu 22.04 support contract missing' || return 1
    test::assert_contains "$content" '24.04' 'Ubuntu 24.04 support contract missing' || return 1
}

case_ins_03_unsupported_os_rejected_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/install/ops-install.sh")"
    test::assert_contains "$content" 'Unsupported OS' 'unsupported OS rejection missing' || return 1
}

case_ins_04_existing_admin_user_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/install/ops-install.sh")"
    test::assert_contains "$content" 'id "$ADMIN_USER"' 'existing admin user detection missing' || return 1
}

case_ins_05_rerun_setup_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/bin/ops-setup.sh")"
    test::assert_contains "$content" 'ensure_dir "$OPS_CONFIG_DIR"' 'setup idempotent config dir contract missing' || return 1
    test::assert_contains "$content" 'safe_symlink' 'symlink idempotence contract missing' || return 1
}

case_ins_06_07_08_login_hook_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/bin/ops-setup.sh")"
    test::assert_contains "$content" 'SSH_CONNECTION' 'login hook must key off SSH_CONNECTION' || return 1
    test::assert_not_contains "$content" 'SSH_TTY' 'stale SSH_TTY-only login hook contract must stay absent' || return 1
}

case_ins_09_installer_rollback_contract_present() {
    local content
    content="$(<"${REPO_ROOT}/docs/operator/RUNBOOKS.md")"
    test::assert_contains "$content" 'SSH port transition and finalisation' 'SSH rollback runbook missing' || return 1
}

case_web_01_nginx_install_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/nginx.sh")"
    test::assert_contains "$content" 'systemctl reload-or-restart nginx' 'nginx reload-or-restart contract missing' || return 1
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
    content="$(<"${REPO_ROOT}/docs/operator/TEST-CASES.md")"
    test::assert_contains "$content" 'WEB-05' 'WEB-05 testcase missing' || return 1
    test::assert_contains "$content" 'giu `/var/www/<domain>`' 'web root preservation contract missing' || return 1
}

case_web_06_nginx_reload_blocked_on_error_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/nginx.sh")"
    test::assert_contains "$content" 'nginx -t' 'nginx syntax validation missing' || return 1
}

case_web_07_ssl_issue_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/nginx.sh")"
    test::assert_contains "$content" 'certbot' 'certbot integration missing' || return 1
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
    test::assert_contains "$tpl_content" 'proxy_buffering       off' 'CLIProxyAPI nginx boundary contract missing' || return 1
    test::assert_contains "$verify_content" '/v1/models returned JSON' 'CLIProxyAPI localhost verify contract missing' || return 1
}

case_node_01_node_lts_install_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/node.sh")"
    test::assert_contains "$content" 'setup_lts.x' 'NodeSource LTS setup contract missing' || return 1
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
    test::assert_contains "$node_content" 'pm2-logrotate' 'PM2 logrotate contract missing' || return 1
    test::assert_contains "$tpl_content" 'max_memory_restart' 'PM2 max_memory_restart contract missing' || return 1
}

case_php_01_php_versions_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/php.sh")"
    test::assert_contains "$content" '7.4' 'PHP 7.4 support contract missing' || return 1
    test::assert_contains "$content" '8.3' 'PHP 8.3 support contract missing' || return 1
}

case_php_02_03_php_pool_and_domain_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/php.sh")"
    test::assert_contains "$content" 'php_get_socket_path()' 'PHP socket helper missing' || return 1
    test::assert_contains "$content" 'echo "/run/php/php${ver}-fpm-${site}.sock"' 'PHP socket naming contract missing' || return 1
}

case_php_04_05_06_php_override_contract_present() {
    local content
    content="$(<"${REPO_ROOT}/docs/operator/TEST-CASES.md")"
    test::assert_contains "$content" 'PHP-04' 'PHP regression testcase coverage missing' || return 1
    test::assert_contains "$content" 'PHP-06' 'PHP pool override testcase coverage missing' || return 1
}

case_db_01_02_03_04_05_db_contracts_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/database.sh")"
    test::assert_contains "$content" '.db-root-password' 'DB root secret file contract missing' || return 1
    test::assert_contains "$content" 'bind-address = 127.0.0.1' 'DB bind-address contract missing' || return 1
    test::assert_contains "$content" 'CREATE DATABASE' 'DB create database helper missing' || return 1
}

case_db_06_backup_helper_contract_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/backup.sh")"
    test::assert_contains "$content" '/var/backups/ops/db' 'DB backup output path missing' || return 1
}

case_cpa_01_02_03_04_05_06_07_08_cliproxyapi_contracts_present() {
    local content
    content="$(<"${OPS_ROOT}/modules/cli-proxy-api.sh")"
    test::assert_contains "$content" 'CLIProxyAPI/releases/latest' 'CLIProxyAPI release install contract missing' || return 1
    test::assert_contains "$content" 'host: "127.0.0.1"' 'CLIProxyAPI loopback bind contract missing' || return 1
    test::assert_contains "$content" '.cli-proxy-api-key' 'CLIProxyAPI secret file contract missing' || return 1
    test::assert_contains "$content" 'proxy_buffering       off' 'CLIProxyAPI nginx proxy contract missing' || return 1
    test::assert_contains "$content" 'api-keys:' 'CLIProxyAPI API key toggle contract missing' || return 1
    test::assert_contains "$content" 'remote-management:' 'CLIProxyAPI remote management contract missing' || return 1
    test::assert_contains "$content" 'service_restart "$CLIPROXYAPI_SERVICE_NAME"' 'CLIProxyAPI service restart contract missing' || return 1
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

case_file_01_02_03_04_file_contracts_present() {
    local utils_content codex_content setup_content
    utils_content="$(<"${OPS_ROOT}/core/utils.sh")"
    codex_content="$(<"${OPS_ROOT}/modules/codex-cli.sh")"
    setup_content="$(<"${OPS_ROOT}/bin/ops-setup.sh")"
    test::assert_contains "$utils_content" 'backup_file' 'backup helper missing' || return 1
    test::assert_contains "$utils_content" 'write_file' 'safe write helper missing' || return 1
    test::assert_contains "$codex_content" 'chmod 600' 'secret permission contract missing in codex-cli module' || return 1
    test::assert_contains "$setup_content" 'OPS_CONFIG_DIR' 'shell-sourceable config contract missing' || return 1
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
test::run_case 'SEC-01' 'password auth guard without key present' case_sec_01_password_auth_guard_without_key_present
test::run_case 'SEC-02' 'disable password auth requires key contract present' case_sec_02_disable_password_auth_requires_key_contract_present
test::run_case 'SEC-03' 'SSH transition keeps two ports contract present' case_sec_03_transition_keeps_two_ports_contract_present
test::run_case 'SEC-04' 'SSH finalize transition contract present' case_sec_04_finalize_transition_contract_present
test::run_case 'SEC-05' 'UFW baseline ports contract present' case_sec_05_ufw_baseline_ports_present
test::run_case 'SEC-06' 'CLIProxyAPI port 8317 must not be allowed' case_sec_06_ufw_must_not_allow_8317
test::run_case 'SEC-07' 'fail2ban tracks managed ports' case_sec_07_fail2ban_tracks_managed_ports
test::run_case 'SEC-08' 'PermitRootLogin disabled contract present' case_sec_08_permit_root_login_disabled_contract_present
test::run_case 'SEC-09' 'forwarding disabled contract present' case_sec_09_forwarding_disabled_contract_present
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
test::run_case 'PHP-01' 'PHP versions contract present' case_php_01_php_versions_contract_present
test::run_case 'PHP-02' 'PHP pool/socket contract present' case_php_02_03_php_pool_and_domain_contract_present
test::run_case 'PHP-03' 'PHP domain contract present' case_php_02_03_php_pool_and_domain_contract_present
test::run_case 'PHP-04' 'PHP override regression coverage present' case_php_04_05_06_php_override_contract_present
test::run_case 'PHP-05' 'PHP URL fopen regression coverage present' case_php_04_05_06_php_override_contract_present
test::run_case 'PHP-06' 'PHP per-pool override contract present' case_php_04_05_06_php_override_contract_present
test::run_case 'DB-01' 'DB install contract present' case_db_01_02_03_04_05_db_contracts_present
test::run_case 'DB-02' 'DB secret permission contract present' case_db_01_02_03_04_05_db_contracts_present
test::run_case 'DB-03' 'DB secure setup contract present' case_db_01_02_03_04_05_db_contracts_present
test::run_case 'DB-04' 'DB bind posture contract present' case_db_01_02_03_04_05_db_contracts_present
test::run_case 'DB-05' 'DB create user/db contract present' case_db_01_02_03_04_05_db_contracts_present
test::run_case 'DB-06' 'DB backup helper contract present' case_db_06_backup_helper_contract_present
test::run_case 'CPA-01' 'CLIProxyAPI install contract present' case_cpa_01_02_03_04_05_06_07_08_cliproxyapi_contracts_present
test::run_case 'CPA-02' 'CLIProxyAPI loopback bind contract present' case_cpa_01_02_03_04_05_06_07_08_cliproxyapi_contracts_present
test::run_case 'CPA-03' 'CLIProxyAPI secret permission contract present' case_cpa_01_02_03_04_05_06_07_08_cliproxyapi_contracts_present
test::run_case 'CPA-04' 'CLIProxyAPI domain link contract present' case_cpa_01_02_03_04_05_06_07_08_cliproxyapi_contracts_present
test::run_case 'CPA-05' 'CLIProxyAPI verify contract present' case_cpa_01_02_03_04_05_06_07_08_cliproxyapi_contracts_present
test::run_case 'CPA-06' 'CLIProxyAPI API key toggle contract present' case_cpa_01_02_03_04_05_06_07_08_cliproxyapi_contracts_present
test::run_case 'CPA-07' 'CLIProxyAPI update preserve-state contract present' case_cpa_01_02_03_04_05_06_07_08_cliproxyapi_contracts_present
test::run_case 'CPA-08' 'CLIProxyAPI SSL/vhost re-render contract present' case_cpa_01_02_03_04_05_06_07_08_cliproxyapi_contracts_present
test::run_case 'MON-01' 'verify exit-zero contract present' case_mon_01_02_03_04_05_monitoring_contracts_present
test::run_case 'MON-02' 'quick logs contract present' case_mon_01_02_03_04_05_monitoring_contracts_present
test::run_case 'MON-03' 'monitoring menu boundary contract present' case_mon_01_02_03_04_05_monitoring_contracts_present
test::run_case 'MON-04' 'scheduled checks idempotence contract present' case_mon_01_02_03_04_05_monitoring_contracts_present
test::run_case 'MON-05' 'notification disable-path contract present' case_mon_01_02_03_04_05_monitoring_contracts_present
test::run_case 'FILE-01' 'secret file contract present' case_file_01_02_03_04_file_contracts_present
test::run_case 'FILE-02' 'no-secret-output contract present' case_file_01_02_03_04_file_contracts_present
test::run_case 'FILE-03' 'shell-sourceable config contract present' case_file_01_02_03_04_file_contracts_present
test::run_case 'FILE-04' 'backup-before-rewrite contract present' case_file_01_02_03_04_file_contracts_present

test::finish
