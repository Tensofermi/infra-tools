#!/usr/bin/env bash

# Install shell aliases for the infra-tools dashboards (cpu-board, gpu-board,
# docker-board) into ~/.bashrc, and into ~/.zshrc when zsh is in use.
# Idempotent: the managed block is replaced on every run, so re-running after
# moving the repo refreshes the paths. No dependencies beyond bash + awk.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROGRAM_NAME="${0##*/}"
ACTION="install"
COLOR_MODE="auto"

START_MARK="# >>> infra-tools >>>"
END_MARK="# <<< infra-tools <<<"

usage() {
  cat <<EOF
Usage: ${PROGRAM_NAME} [options]

Install aliases for the infra-tools dashboards into your shell rc files
(~/.bashrc always, ~/.zshrc too when zsh is your shell or the file exists).

Aliases installed:
  ccc   -> ${SCRIPT_DIR}/cpu-board.sh
  ggg   -> ${SCRIPT_DIR}/gpu-board.sh
  ddd   -> ${SCRIPT_DIR}/docker-board.sh

Options:
      --remove     Remove the aliases block from the rc files
      --no-color   Disable ANSI colors
  -h, --help       Show this help

The block is wrapped in "${START_MARK}" / "${END_MARK}" markers and is
replaced on every run, so it never clobbers your other shell configuration.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --remove) ACTION="remove" ;;
    --no-color) COLOR_MODE="never" ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

if [[ "$COLOR_MODE" == "auto" && -t 1 && "${TERM:-dumb}" != "dumb" && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'
  C_CYAN=$'\033[36m'
  C_YELLOW=$'\033[33m'
else
  C_RESET="" C_BOLD="" C_GREEN="" C_CYAN="" C_YELLOW=""
fi

log()  { printf '%s==>%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
info() { printf '    %s\n' "$*"; }

# Single-quote a value for safe embedding in an alias definition.
shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# rc files to manage: ~/.bashrc always, ~/.zshrc when zsh is around.
RC_FILES=("${HOME}/.bashrc")
if [[ -f "${HOME}/.zshrc" || "${SHELL:-}" == */zsh ]]; then
  RC_FILES+=("${HOME}/.zshrc")
fi

strip_block() {
  # Print stdin with any existing managed block removed.
  awk -v s="$START_MARK" -v e="$END_MARK" '
    index($0, s) { skip = 1 }
    skip && index($0, e) { skip = 0; next }
    !skip { print }
  '
}

install_rc() {
  local rc="$1" tmp
  tmp="$(mktemp)"
  if [[ -f "$rc" ]]; then
    strip_block <"$rc" >"$tmp"
  fi
  {
    cat "$tmp"
    printf '%s\n' "$START_MARK"
    printf '# infra-tools dashboards (installed by %s; re-run it to refresh paths)\n' "${SCRIPT_DIR}/install-aliases.sh"
    printf 'alias ccc=%s\n' "$(shell_quote "${SCRIPT_DIR}/cpu-board.sh")"
    printf 'alias ggg=%s\n' "$(shell_quote "${SCRIPT_DIR}/gpu-board.sh")"
    printf 'alias ddd=%s\n' "$(shell_quote "${SCRIPT_DIR}/docker-board.sh")"
    printf '%s\n' "$END_MARK"
  } >"$rc"
  rm -f "$tmp"
}

remove_rc() {
  local rc="$1"
  [[ -f "$rc" ]] || return 0
  grep -qF "$START_MARK" "$rc" || return 0
  local tmp
  tmp="$(mktemp)"
  strip_block <"$rc" >"$tmp"
  cat "$tmp" >"$rc"
  rm -f "$tmp"
}

for rc in "${RC_FILES[@]}"; do
  if [[ "$ACTION" == "remove" ]]; then
    remove_rc "$rc"
    log "removed infra-tools block from $rc"
  else
    install_rc "$rc"
    log "installed aliases into $rc"
  fi
done

if [[ "$ACTION" == "remove" ]]; then
  printf '\n%sDone.%s Open a new shell for the change to take effect.\n' "$C_GREEN" "$C_RESET"
else
  printf '\n%sDone.%s Aliases available in new shells, or load them now with:\n' "$C_GREEN" "$C_RESET"
  for rc in "${RC_FILES[@]}"; do
    printf '  %ssource %s%s\n' "$C_BOLD" "$rc" "$C_RESET"
  done
  printf '\nThen run: %sccc%s (cpu) / %sggg%s (gpu) / %sddd%s (docker)  (add -h for options)\n' \
    "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
  printf '%sNote: gpu-board needs an NVIDIA host with nvidia-smi; docker-board needs docker + jq.%s\n' \
    "$C_YELLOW" "$C_RESET"
fi
