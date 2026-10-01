#!/usr/bin/env bash
# shellcheck disable=SC1091

# One-click, system-wide installer. Re-executes itself with sudo when needed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E bash "${SCRIPT_DIR}/${BASH_SOURCE[0]##*/}" "$@"
  fi
  printf 'Error: root privileges are required and sudo is not available\n' >&2
  exit 1
fi

# shellcheck disable=SC2034
MODE="root"

# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

main "$@"