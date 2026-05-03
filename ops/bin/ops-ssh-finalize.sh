#!/usr/bin/env bash
# ============================================================
# ops/bin/ops-ssh-finalize.sh
# Purpose:  Compatibility wrapper for SSH transition finalization
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
# This script keeps the legacy entrypoint for manual use or older automation,
# but the authoritative finalize logic now lives in ops/modules/security.sh.
# ============================================================
set -euo pipefail
IFS=$'\n\t'

# Resolve the real script path first so the /usr/local/bin symlink works.
SCRIPT_PATH="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_PATH" ]]; do
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
    SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
    [[ "$SCRIPT_PATH" != /* ]] && SCRIPT_PATH="${SCRIPT_DIR}/${SCRIPT_PATH}"
done
OPS_ROOT="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"

# shellcheck source=core/env.sh
source "$OPS_ROOT/core/env.sh"
# shellcheck source=core/utils.sh
source "$OPS_ROOT/core/utils.sh"
# shellcheck source=core/ui.sh
source "$OPS_ROOT/core/ui.sh"
# shellcheck source=core/system.sh
source "$OPS_ROOT/core/system.sh"
# shellcheck source=modules/security.sh
source "$OPS_ROOT/modules/security.sh"

main() {
    security_finalize_ssh_transition
}

main "$@"
