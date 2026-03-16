## Bash Style Guide for OPS

This guide defines how Bash scripts in OPS should be written so that they are predictable, safe, and easy for AI agents to modify.

### 1. Shell options and shebang

- Use this shebang for all executable scripts:

  ```bash
  #!/usr/bin/env bash
  ```

- At the top of each script, enable strict mode:

  ```bash
  set -euo pipefail
  IFS=$'\n\t'
  ```

- For functions that may legitimately handle non‑zero exit codes, explicitly capture and handle them instead of disabling `set -e`.

### 2. Functions and naming

- Use `snake_case` for function and variable names:
  - `run_production_wizard`, `install_node_runtime`, `create_nginx_vhost`.
- Group related functions in the same file; prefer modules over giant monolithic scripts.
- Keep functions short and focused on a single responsibility.

### 3. Globals and configuration

- Centralise configuration in:
  - `core/env.sh` for global constants and environment detection.
  - `/etc/ops/*.conf` for persistent runtime configuration.
- Avoid scattered global variables across modules.
- When adding new config keys:
  - Document them in `ARCHITECTURE.md` or module‑specific docs.

### 4. User interaction

- All prompts must be clear and explicit, for example:

  ```bash
  read -r -p "Do you want to apply these changes and reboot now? [y/N]: " answer
  ```

- For yes/no prompts, treat anything other than an explicit `y`/`Y` as “no”.
- When asking for secrets (passwords, API keys), disable echo.

### 5. Error handling and logging

- Prefer helper functions in `core/utils.sh`, such as:
  - `log_info`, `log_warn`, `log_error`.
  - `backup_file_safely`, `write_file_atomically`.
- On failure:
  - Print a clear error.
  - Avoid leaving partial configs; roll back to backups where possible.

### 6. Idempotence

- Scripts must be safe to run multiple times:
  - Check before creating users, directories, or symlinks.
  - Detect existing services and configs rather than blindly overwriting.
- Wizards and installers should detect existing state and offer to update instead of re‑creating from scratch.

### 7. External commands

- Always check for the presence of required commands (`command -v nginx`, `command -v mysql`, etc.) and install them or exit with instructions.
- When using `apt`, use non‑interactive flags and handle errors clearly.
- Validate critical changes:
  - `nginx -t` before `systemctl reload nginx`.
  - DB syntax checks where applicable.

### 8. File paths

- Do not hard‑code paths beyond what is specified in `ARCHITECTURE.md`.
- Use variables for key paths (`OPS_ROOT`, `OPS_CONFIG_DIR`, etc.) and initialise them in `core/env.sh`.

### 9. Comments and readability

- Comments should explain **why** something is done, not restate obvious code.
- Avoid large commented‑out blocks of dead code; remove them unless needed for documentation.

### 10. AI‑specific notes

- AI agents editing scripts must:
  - Preserve the shebang and strict mode settings.
  - Keep style consistent with existing functions in the same file.
  - Prefer adding new small functions instead of inlining complex logic.

