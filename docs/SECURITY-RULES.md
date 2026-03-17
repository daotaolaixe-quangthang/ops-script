## OPS Security Rules

This document defines non‑negotiable security rules for OPS. Any change that violates these rules is a bug and must be rejected or fixed.

### 1. SSH and user accounts

- OPS must:
  - Encourage use of a **non‑root admin user** for SSH and operations.
  - Support changing the SSH port from 22 to a user‑defined port.
  - Keep port 22 open only during the transition period.
  - Offer a guided step to close port 22 and reboot once everything is verified.
- Prompts must clearly show the **new SSH port and admin username**, for example:

  ```text
  After reboot, you MUST use:
    ssh -p <NEW_PORT> <ADMIN_USER>@<SERVER_IP_OR_HOSTNAME>
  ```

- Root login should be minimised or disabled according to best practices once the admin user is set up.

### 2. Network exposure and Nginx

- Nginx must be the **only public HTTP(S) entrypoint**.
- Backend services (Node.js apps, 9router, PHP‑FPM sockets) must:
  - Bind to localhost or Unix sockets.
  - Never listen publicly on 0.0.0.0 for production ports.
- There should be a default Nginx server that rejects unknown hosts (e.g. 444 or 404).

### 3. 9router exposure

- 9router must:
  - Bind only to loopback (e.g. `127.0.0.1:20128`).
  - Never be exposed directly through firewall.
  - Be reachable only via Nginx and, where applicable, Cloudflare Access.
- For Cloudflare Access setups:
  - Protect only the intended router domain.
  - Keep Cloudflare proxy enabled and use `Full (strict)` when applicable.
  - Treat Cloudflare Access as an additional gate, not a replacement for loopback binding and firewall rules.
- Keep a default Nginx server that rejects unknown hosts.

### 4. Firewall and fail2ban

- UFW (or equivalent firewall) must:
  - Allow only:
    - SSH port(s) in use (22 + new port during transition, then only new port).
    - HTTP (80).
    - HTTPS (443).
  - Deny other inbound ports by default.
- `fail2ban`:
  - Must be installed and enabled at least for SSH.
  - Configuration changes must be conservative; avoid breaking legitimate SSH access.

### 5. TLS and certificates

- Certbot is the default ACME client.
- Certificates should:
  - Use secure defaults (strong ciphers, modern TLS versions).
  - Be renewed automatically or via simple periodic commands.
- OPS must not:
  - Store private keys in world‑readable locations.
  - Print private keys directly to the terminal except where explicitly requested by the user.

### 6. PHP security

- PHP configuration must:
  - Disable dangerous functions where appropriate.
  - Set sensible `memory_limit`, `max_execution_time`, `post_max_size`, `upload_max_filesize`.
  - Enable and correctly tune opcache.
- PHP‑FPM pools:
  - Run under non‑root users.
  - Have file/directory permissions restricted to what applications need.

### 7. Database security

- Only MySQL/MariaDB is supported.
- Secure setup must:
  - Remove anonymous users.
  - Disable remote root login unless the user explicitly opts in.
  - Remove test databases.
  - Require passwords for all non‑local accounts.
- Database users created by OPS:
  - Should have least privilege (e.g. per‑database accounts).

### 8. File safety and backups

- Before writing or replacing critical config files, OPS must:
  - Create backup copies with clear timestamps or suffixes.
  - Fail safely on errors rather than producing partial configs.
- For Nginx, PHP‑FPM, and systemd:
  - Changes must be validated (e.g. `nginx -t`) before reloading services.
- For PM2-managed Node services:
  - Verify process health, restart behaviour, and localhost binding after changes.

### 9. Logging and secrets

- OPS must avoid:
  - Printing secrets (passwords, tokens, API keys) into logs.
  - Storing secrets in world‑readable files.
- Secrets files (e.g. `.env`, DB passwords) must have restrictive permissions (`0600` or similar).
- When prompting for secrets, prefer:
  - Hidden input (no echo).
  - Clear instructions on how to rotate or regenerate secrets.

### 10. AI and automation considerations

- AI agents modifying OPS must:
  - Respect all rules in this document and in `rules/`.
  - Avoid introducing features that weaken defaults (e.g. opening extra ports) without:
    - A clear, documented reason.
    - An explicit, opt‑in prompt to the user.
- Any new module or feature that touches security‑sensitive areas must:
  - Add or update relevant sections here.
  - Be designed opt‑in by default when risk is non‑trivial.

Security rules are intentionally conservative; usability should be improved without relaxing these guarantees unless the spec is explicitly updated.

