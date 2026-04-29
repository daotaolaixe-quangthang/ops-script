#!/usr/bin/env bash
# ============================================================
# ops/install/ops-install.sh
# Purpose:  Compatibility wrapper for the canonical installer
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
set -euo pipefail
IFS=$'\n\t'

RED=$'\033[0;31m'
RST=$'\033[0m'

die() { echo -e "${RED}[ERROR]${RST} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CANONICAL_INSTALLER="${REPO_ROOT}/install/ops-install.sh"

if [[ ! -f "$CANONICAL_INSTALLER" ]]; then
    die "Canonical installer not found at ${CANONICAL_INSTALLER}. Use install/ops-install.sh from the repo root."
fi

exec bash "$CANONICAL_INSTALLER" "$@"
