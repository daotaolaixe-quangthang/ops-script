## OPS Project Rules

These rules define how this project should evolve. Human contributors and AI agents must follow them when adding or modifying code.

### 1. Scope and philosophy

- OPS exists to:
  - Turn a fresh Ubuntu VPS into a **secure, production‑ready** stack.
  - Provide a **menu‑driven interface** to manage Node.js apps, 9router, PHP, and DB.
  - Remain **lighter and simpler** than full control panels.
- OPS favours:
  - **Security and correctness over convenience**.
  - **Idempotent** scripts (safe to run multiple times).
  - **Explicit prompts** for destructive or high‑risk actions.

### 2. Languages and dependencies

- Implementation language for core and modules: **Bash**.
- External tools:
  - System packages via `apt` (Nginx, PHP, MySQL/MariaDB, certbot, etc.).
  - Node.js + PM2 for Node services.
- No heavy additional runtimes (Python/Go/Node CLIs) should be required for OPS itself unless:
  - Strong justification is documented.
  - The dependency footprint is acceptable for small VPS instances.

### 3. OS support

- Supported OS: Ubuntu 22.04 and 24.04.
- Scripts may detect and reject unsupported OSes with a clear message.
- Any future OS additions must update:
  - `docs/ARCHITECTURE.md`
  - `docs/FLOW-INSTALL.md`
  - Module implementations as needed.

### 4. Structure and separation of concerns

- Keep the installer (`install/ops-install.sh`) **small and auditable**.
- Put reusable logic in `core/` and `modules/`, not in the installer.
- Each module owns a clear responsibility (Node, PHP, DB, etc.) and exposes:
  - Functions for wizard orchestration.
  - Functions for menu actions.
- Do not create deeply nested scripts with hidden side effects; keep flows explicit.

### 5. User experience

- Menus and prompts must:
  - Use **clear, concise English**.
  - Avoid jargon when possible.
  - Explain side effects before making impactful changes (reboot, port changes, firewall rules).
- Default options should be **safe** and production‑friendly.
- Always show the **SSH port and username** when changing SSH configuration.

### 6. Logging and diagnostics

- Major operations (install, configure, upgrade) should log to:
  - `/var/log/ops/ops.log` (or module‑specific files).
- Logs should contain:
  - Commands executed (sanitised for secrets).
  - Success/failure with error messages.
- Logs must **not** contain secrets such as passwords or API keys.

### 7. Backwards compatibility

- When changing behaviour that may affect existing installations:
  - Prefer additive changes (new options, new menus) over breaking existing ones.
  - Provide migration paths or clear upgrade notes in `docs/`.
- Avoid renaming or moving key entrypoints (`ops`, installer URL) without updating docs and announcing change.

### 8. Testing and verification

- Scripts that change service configs must:
  - Validate configs before reload (`nginx -t`, `php-fpm -t` if available).
  - Check service status after restart (`systemctl is-active`).
- Where feasible, provide simple “verify” commands directly in menus.

### 9. AI agent behaviour

- AI agents working on this repo must:
  - Read `docs/ARCHITECTURE.md`, `docs/FLOW-INSTALL.md`, `docs/SECURITY-RULES.md`, and this file before writing code.
  - Respect existing structure and naming conventions.
  - Prefer **small, incremental changes** with clear commit messages (when applicable).
  - Avoid introducing new environment variables, paths, or conventions without documenting them.

### 10. Documentation first

- For meaningful changes (new module, new menu, changed behaviour):
  - Update relevant docs in `docs/` and rules in `rules/` **before** or together with code changes.
- Documentation is part of the contract; code must match it.

