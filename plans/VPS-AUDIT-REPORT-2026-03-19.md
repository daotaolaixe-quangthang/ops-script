# VPS Audit Report

- Audit date: 2026-03-19 UTC
- Target host: `justatee`
- Environment: VPS sandbox intended to mirror production readiness for `ops-script`
- Auditor mode: live CLI verification on host
- Scope: VPS security, application security, runtime consistency, and performance stability

---

## 1. Executive Summary

This report documents a live audit performed directly on the sandbox VPS before real production deployment of the `ops-script` stack.

### Overall Verdict

**Current status: NOT READY for real production deployment yet**

The VPS is in a reasonably healthy state from a raw resource and basic service perspective, but it still has several important gaps in security hardening and production operations.

### High-Level Assessment

| Area | Status | Summary |
|---|---|---|
| OS and baseline runtime | Acceptable | Ubuntu 22.04 LTS, stable uptime, low load |
| VPS security hardening | Needs work | SSH is too permissive, multiple SSH ports are open |
| Firewall posture | Partial | UFW is enabled, but rules are overly broad for SSH |
| Intrusion resistance | Partial | `fail2ban` exists, but only minimal jail coverage is active |
| Application runtime security | Needs work | Node apps and PM2 run as `root` |
| Web stack consistency | Needs work | `nginx` config is valid but service is inactive |
| Database safety | Critical issue | MariaDB process found running with `--skip-grant-tables` |
| TLS readiness | Good | Let's Encrypt certificates are valid |
| Performance and capacity | Good | CPU, RAM, disk, and I/O currently healthy |
| Patch state | Needs work | Multiple packages upgradable, reboot required |

### Key Blocking Issues Before Production

1. SSH permits root login and password authentication
2. Multiple SSH ports are exposed in the firewall
3. PM2 and applications are running under `root`
4. MariaDB rescue-style process is still running with auth bypass flags
5. `nginx` deployment state is inconsistent with enabled vhosts
6. The system still requires security updates and reboot

---

## 2. Audit Methodology

The audit was performed by running live CLI inspection commands directly on the VPS. No assumptions were made from documentation alone.

### Audit objectives

- Verify actual operating-system hardening
- Verify actual network exposure and firewall posture
- Verify actual SSH security settings
- Verify active service state against intended architecture
- Verify runtime ownership and process privileges
- Verify TLS and web stack readiness
- Verify system performance headroom and stability signals
- Identify gaps relative to production best practices

### Commands and inspection areas used

The live audit included checks for:

- OS and host identity
- Running services
- Users and sudo group membership
- Effective SSH daemon settings
- UFW, nftables, iptables exposure
- `fail2ban` status
- Listening sockets
- Package inventory for web and database stack
- `nginx` syntax and enablement
- PM2 process state and startup behavior
- Node and PHP process inspection
- TLS certificate state
- Recent system errors and SSH attack patterns
- CPU, memory, swap, disk, load, `vmstat`
- `sysctl` hardening values
- Pending updates and reboot requirement

---

## 3. System Baseline

### OS and host

- Hostname: `justatee`
- OS: Ubuntu 22.04.4 LTS
- Kernel: `5.15.0-105-generic`
- Virtualization: KVM
- Uptime during audit: approximately 1 day

### User accounts observed

The following non-system users were identified:

- `ops`
- `opsadmin`

Both users are in the `sudo` group.

### Initial interpretation

This is a standard Ubuntu VPS baseline and generally suitable for production hosting. The operating system choice is fine. The main concerns are not OS compatibility, but hardening and operational consistency.

---

## 4. Security Audit Findings

## 4.1 SSH Hardening

### Observed effective SSH settings

Effective SSH daemon output showed:

- `port 22`
- `port 2222`
- `permitrootlogin yes`
- `passwordauthentication yes`
- `pubkeyauthentication yes`
- `x11forwarding yes`
- `allowtcpforwarding yes`
- `allowagentforwarding yes`
- `clientaliveinterval 0`
- `maxauthtries 6`
- `maxsessions 10`

Config file inspection confirmed:

- `/etc/ssh/sshd_config` contains:
  - `Port 22`
  - `Port 2222`
  - `PermitRootLogin yes`
  - `PasswordAuthentication yes`
  - `X11Forwarding yes`
- There is conflicting include behavior in `/etc/ssh/sshd_config.d/`:
  - `60-cloudimg-settings.conf` contains `PasswordAuthentication no`
  - `50-cloud-init.conf` contains `PasswordAuthentication yes`

### Risk assessment

**Severity: Critical**

This SSH posture is too permissive for an internet-facing production VPS.

### Why this is risky

- `PermitRootLogin yes` allows direct root SSH access
- `PasswordAuthentication yes` increases brute-force risk significantly
- Multiple SSH ports increase attack surface and configuration drift
- `X11Forwarding yes` is unnecessary on most servers
- `AllowTcpForwarding` and `AllowAgentForwarding` should be disabled unless explicitly needed
- `ClientAliveInterval 0` provides no idle timeout control

### Production best-practice target

- Use a single SSH port only
- Disable direct root login
- Disable password authentication once key access is confirmed
- Disable X11 forwarding
- Disable agent and TCP forwarding unless operationally required
- Consider `AllowUsers` restriction

### Recommended actions

**Priority: P0**

1. Standardize `/etc/ssh/sshd_config`
2. Keep only one SSH port
3. Set `PermitRootLogin no`
4. Set `PasswordAuthentication no`
5. Set `X11Forwarding no`
6. Review `AllowTcpForwarding no`
7. Review `AllowAgentForwarding no`
8. Add `ClientAliveInterval` and `ClientAliveCountMax`
9. Validate access in a second SSH session before reloading SSH

---

## 4.2 Firewall Posture

### Observed UFW state

UFW is active with:

- default deny incoming
- default allow outgoing

Open inbound ports observed:

- `22/tcp`
- `2292/tcp`
- `80/tcp`
- `443/tcp`
- `2222/tcp`
- `2201/tcp`
- `2202/tcp`
- `2203/tcp`

IPv6 equivalents are also open.

### Risk assessment

**Severity: High**

### Why this is risky

- Multiple SSH ports remain exposed simultaneously
- It is unclear which port is canonical for admin access
- Extra open ports create administrative confusion and unnecessary exposure
- Broad allow rules reduce confidence in the final intended production perimeter

### Positive findings

- UFW is enabled
- Default inbound posture is deny
- nftables/iptables integration is active
- Firewall is actually enforcing policy

### Recommended actions

**Priority: P0**

1. Keep only the single SSH port actively used in production
2. Remove old test and migration SSH ports from UFW
3. Keep only `80/tcp` and `443/tcp` for web if needed
4. Re-check IPv6 parity after changes
5. Ensure every open port maps to an active required service

---

## 4.3 Fail2ban and Attack Resistance

### Observed state

`fail2ban` is installed and running.

Current jail list:

- `sshd`

Firewall chain output confirmed active blocks from several attacking IP addresses.

### Log evidence

Recent logs show repeated hostile traffic patterns against SSH, including:

- timeout before authentication
- invalid protocol identifiers
- malformed public key packets
- HTTP requests sent to SSH port
- repeated connection resets and scan-like behavior

### Risk assessment

**Severity: Medium**

### Interpretation

The VPS is exposed to real-world internet scanning right now. `fail2ban` is helping, but the current protection is narrow.

### Recommended actions

**Priority: P1**

1. Keep SSH jail active
2. Tune ban parameters if needed
3. Add `nginx`-related jails when public web entry is finalized
4. Add auth-related jails if applications expose authentication endpoints
5. Review log retention for incident response usefulness

---

## 4.4 Kernel and Network Hardening

### Observed `sysctl` values

Positive values observed:

- `net.ipv4.ip_forward = 0`
- `net.ipv4.tcp_syncookies = 1`
- `net.ipv4.conf.all.accept_redirects = 0`
- `net.ipv4.conf.default.accept_redirects = 0`
- `net.ipv4.conf.all.accept_source_route = 0`
- `net.ipv4.conf.default.accept_source_route = 0`
- `net.ipv6.conf.all.accept_redirects = 0`
- `kernel.kptr_restrict = 1`
- `kernel.dmesg_restrict = 1`
- `kernel.randomize_va_space = 2`

Less ideal values observed:

- `net.ipv4.conf.all.send_redirects = 1`
- `net.ipv4.conf.default.send_redirects = 1`
- `vm.swappiness = 60`
- `rp_filter = 2`

### Risk assessment

**Severity: Medium**

### Interpretation

The host is partially hardened, but not fully tuned as a clean production internet-facing baseline.

### Recommended actions

**Priority: P1**

1. Set `net.ipv4.conf.all.send_redirects = 0`
2. Set `net.ipv4.conf.default.send_redirects = 0`
3. Review reverse path filtering settings for the network design
4. Revisit `vm.swappiness` after swap strategy is decided
5. Maintain hardened settings in persistent `sysctl.d` configuration

---

## 4.5 OS Patch and Hardening Services

### Observed state

- `apparmor.service` is active
- `unattended-upgrades.service` is active
- Multiple packages are upgradable
- `/var/run/reboot-required` is present

### Risk assessment

**Severity: High**

### Interpretation

Security support services are present, which is good. However, the machine still has unapplied updates and requires a reboot, so the host should not yet be considered fully patched.

### Recommended actions

**Priority: P0**

1. Apply pending updates
2. Review whether any packages affect SSH, kernel, firewall, or database behavior
3. Reboot in a controlled window
4. Re-run validation after reboot

---

## 5. Application and Runtime Security Findings

## 5.1 PM2 and Node Runtime Ownership

### Observed state

`pm2 ls` showed active processes:

- `hello-node`
- `nine-router`

Observed PM2 characteristics:

- PM2 daemon runs as `root`
- PM2 startup configuration generated `pm2-root.service`
- Dump file exists in `/root/.pm2/dump.pm2`
- Runtime environment for apps is stored under root-owned PM2 state

### Risk assessment

**Severity: Critical**

### Why this is risky

- Running Node applications as `root` increases impact of any app compromise
- PM2 state and restart automation become tightly coupled to the root account
- It is easier for environment contamination to occur when root sessions drive app processes

### Recommended production model

Run applications under a dedicated least-privilege service account, such as:

- `ops`, if that is the intended app operator
- or a dedicated account like `opsapp`

### Recommended actions

**Priority: P0**

1. Stop using root-owned PM2 as the long-term production runtime
2. Create or select a non-root service account
3. Move PM2 ecosystem and logs to that account
4. Rebuild PM2 startup under that user
5. Ensure app directories and writable paths are owned correctly

---

## 5.2 Application File Ownership and Deployment Permissions

### Observed state

- `/srv`
- `/srv/apps`
- `/srv/apps/hello-node`

These paths are owned by `root:root`.

### Risk assessment

**Severity: High**

### Why this matters

Root-owned app deployment trees usually indicate one of two things:

- deploys are being done as root
- app runtime may require root access for ordinary operations

Both are undesirable in production unless there is a very specific reason.

### Recommended actions

**Priority: P0**

1. Decide intended deployment user
2. Move app ownership to least-privilege user or group model
3. Restrict write access only where necessary
4. Review permissions on `.env`, config, logs, uploads, and build artifacts

---

## 5.3 Web Layer Readiness and Consistency

### Observed state

- `nginx` is installed
- `nginx -t` passed successfully
- `nginx.service` is enabled but inactive
- Active sites exist in `/etc/nginx/sites-enabled`
- Site definitions reference:
  - `ducnv.email`
  - `sub.ducnv.email`
  - `php.ducnv.email`
- Proxy targets include:
  - `127.0.0.1:20128`
  - `127.0.0.1:3000`

### Risk assessment

**Severity: High**

### Interpretation

Configuration exists for a proper reverse-proxy entrypoint, but the service itself is not running. This is an operational inconsistency and creates uncertainty about how traffic is expected to reach the applications in a production cutover.

### Recommended actions

**Priority: P1**

1. Confirm intended ingress architecture
2. If `nginx` is the production entrypoint, ensure it is active and boot-persistent
3. Verify HTTP to HTTPS behavior and default deny vhost behavior
4. Confirm all enabled vhosts correspond to actively intended workloads
5. Remove stale sites or test remnants

---

## 5.4 TLS Certificate State

### Observed state

Let's Encrypt live certificates were found and valid for:

- `sub.ducnv.email`
- `php.ducnv.email`

Observed validity windows indicate active non-expired certificates.

### Risk assessment

**Severity: Low**

### Positive findings

- TLS issuance is functioning
- Certificate paths are correctly present in `nginx` site definitions
- Renewal timer exists through snap-based certbot timer

### Recommendations

**Priority: P2**

1. Verify renewal by dry-run in maintenance workflow
2. Confirm all production hostnames required for go-live have certificates
3. Ensure post-renew reload hooks are working if `nginx` becomes active

---

## 5.5 Database Safety

### Observed state

MariaDB package is installed.

Service state:

- `mariadb.service` is inactive

But process inspection found a running MariaDB server process:

- `/usr/sbin/mariadbd ... --skip-grant-tables --skip-networking --skip-log-error ...`

Config files show intended bind-address is local-only `127.0.0.1`, but the current running process is clearly not a normal managed service runtime.

### Risk assessment

**Severity: Critical**

### Why this is a blocker

`--skip-grant-tables` disables normal privilege enforcement. Even if `--skip-networking` reduces remote exposure, leaving the database in this state is unacceptable for a production baseline.

It also indicates operational drift: the service manager thinks MariaDB is down, but a manually launched process is still running.

### Recommended actions

**Priority: P0**

1. Determine why MariaDB was launched in rescue mode
2. Stop the rescue process safely
3. Start MariaDB only through the managed service unit if it is needed
4. Validate normal authentication behavior
5. Verify no app depends on the temporary bypass state
6. If MariaDB is not needed, remove or fully disable it cleanly

---

## 6. Performance and Stability Findings

## 6.1 CPU and Load

### Observed state

- 2 vCPU
- CPU model: AMD EPYC 7763
- Load averages were low during audit
- `vmstat` showed mostly idle CPU and negligible I/O wait

### Assessment

**Status: Good**

The system currently has ample CPU headroom for the observed workload.

---

## 6.2 Memory and Swap

### Observed state

- Total RAM: 7.8 GiB
- Used RAM during audit: about 1.6 GiB
- Available RAM: about 5.9 GiB
- Swap: none configured

### Assessment

**Status: Mixed**

Memory headroom is currently very comfortable. However, lack of swap increases risk of abrupt OOM kills during traffic spikes, runaway processes, or memory fragmentation scenarios.

### Recommended actions

**Priority: P1**

1. Add small swap space, for example 1 to 2 GiB, unless there is a firm reason not to
2. Tune `vm.swappiness` after swap is added
3. Monitor Node and PHP memory behavior under real load

---

## 6.3 Disk Capacity and Filesystem

### Observed state

- Root disk size: about 91 GiB
- Used: about 7.3 GiB
- Available: about 83 GiB
- Inode usage: low

### Assessment

**Status: Good**

Disk capacity and inode consumption are healthy.

---

## 6.4 Runtime Process Footprint

### Observed processes of interest

- `next-server` for `nine-router`
- `node /srv/apps/hello-node/index.js`
- `php-fpm`
- PM2 daemon
- MariaDB rescue process

### Observed concern

A large share of active memory and CPU in the session came from the remote IDE tooling attached to the host, but this is expected during active administration and does not by itself indicate app instability.

### Assessment

**Status: Stable with operational caveats**

The main risk is not capacity but process governance and privilege model.

---

## 7. Production Readiness Scorecard

| Control Area | Result | Notes |
|---|---|---|
| Single-purpose SSH exposure | Fail | Too many SSH ports open |
| Root SSH login disabled | Fail | Root login allowed |
| Password SSH disabled | Fail | Password auth enabled |
| Firewall default deny inbound | Pass | UFW deny inbound is active |
| Only required ports exposed | Fail | SSH rule set is overly broad |
| Intrusion prevention active | Partial | `fail2ban` present, limited scope |
| Reverse proxy configured | Partial | `nginx` config valid but inactive |
| TLS certificates valid | Pass | Let's Encrypt certs valid |
| App runtime non-root | Fail | PM2 and apps run as root |
| Database managed safely | Fail | MariaDB rescue process with bypass flags |
| OS patches current | Fail | Updates pending, reboot required |
| AppArmor active | Pass | Service active |
| System resource headroom | Pass | CPU, RAM, disk healthy |
| Swap safety margin | Partial | No swap configured |
| Service state consistency | Fail | Enabled configs do not match active services |

---

## 8. Prioritized Remediation Plan

## P0: Mandatory before production deployment

1. Harden SSH
   - disable root SSH login
   - disable password auth after confirming keys
   - disable X11 forwarding
   - disable unnecessary forwarding features
   - keep only one SSH port

2. Clean firewall rules
   - remove all obsolete SSH ports
   - verify IPv4 and IPv6 symmetry

3. Fix MariaDB state
   - stop rescue-mode process
   - restore managed service behavior or remove DB if unused
   - confirm authentication is enforced

4. Remove root from app runtime
   - move PM2 to non-root user
   - re-own app directories appropriately
   - rebuild startup persistence under least privilege

5. Apply updates and reboot
   - patch OS packages
   - reboot
   - revalidate all services after boot

## P1: Strongly recommended before go-live

1. Finalize ingress architecture
   - ensure `nginx` is truly in use or remove stale config
2. Expand `fail2ban` coverage
3. Add swap and tune memory behavior
4. Harden remaining `sysctl` values
5. Verify log rotation and service restart persistence

## P2: Standardization and resilience improvements

1. Document final network exposure and ports
2. Standardize systemd and PM2 ownership model
3. Review secrets and file permissions
4. Test certificate renewal workflow
5. Test backup and restore for database and app state

---

## 9. Recommended Next Audit After Fixes

After remediation, a second live audit should verify at minimum:

- `sshd -T` reflects final hardened values
- only one SSH port is listening and allowed in UFW
- `pm2 ls` shows non-root user ownership
- `systemctl status nginx` is active if used
- `systemctl status mariadb` matches actual process state
- no `--skip-grant-tables` process exists
- `apt list --upgradable` is clean or near-clean
- reboot-required flag is gone
- swap exists if chosen
- public endpoints respond correctly over TLS

---

## 10. Final Conclusion

This sandbox VPS is **close in infrastructure capacity**, but **not yet acceptable as a hardened production deployment target**.

The most important blockers are:

- permissive SSH configuration
- excessive SSH exposure in the firewall
- root-owned PM2 and application runtime
- MariaDB rescue process with authentication bypass
- patching and reboot still pending
- web stack service state not yet operationally clean

Once those blockers are resolved and a short re-audit is performed, the host can move much closer to true production readiness.

---

## Appendix A. Key Live Findings Snapshot

### SSH

- ports: `22`, `2222`
- root login: enabled
- password authentication: enabled
- X11 forwarding: enabled

### Firewall

Open inbound ports included:

- `22`
- `2292`
- `80`
- `443`
- `2222`
- `2201`
- `2202`
- `2203`

### Fail2ban

- installed and active
- jail list: `sshd`

### Web stack

- `nginx` installed
- `nginx -t` successful
- `nginx.service` inactive

### Runtime

- PM2 active
- Node apps active
- PM2 and Node run as root

### Database

- MariaDB service inactive
- MariaDB process running manually with rescue flags

### TLS

- valid Let's Encrypt certificates found

### Resources

- low load
- RAM healthy
- disk healthy
- no swap

### Patching

- multiple packages upgradable
- reboot required
