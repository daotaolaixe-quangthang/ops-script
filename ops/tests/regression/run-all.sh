#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "${SCRIPT_DIR}/tui-suite.sh"
bash "${SCRIPT_DIR}/reg-suite.sh"

printf '[PASS] All regression suites passed\n'
