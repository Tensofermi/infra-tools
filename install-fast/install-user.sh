#!/usr/bin/env bash
# shellcheck disable=SC1091

# One-click, user-space installer. Needs no root.
# Anything that can only come from the system package manager is reported
# with the exact command to run (or pass --use-sudo to do it automatically).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034
MODE="user"

# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

main "$@"