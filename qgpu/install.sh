#!/usr/bin/env bash
# Self-contained installer for qGPU.
#
# Copies the qGPU code into a private prefix and drops a `qgpu` launcher on
# PATH, so the tool keeps working even if this repository is deleted or moved.
# Requirements at runtime: python3 (stdlib only) + nvidia-smi.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${QGPU_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/qgpu}"
BIN_DIR="${QGPU_BIN_DIR:-$HOME/.local/bin}"
ACTION="install"
DRY_RUN=0

FILES=(qgpu.py scheduler.py common.py qgpu)

log()  { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '[skip] %s\n' "$*" >&2; }
die()  { printf '[error] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: install.sh [options]

Copy qGPU into a private prefix and link a \`qgpu\` launcher into BIN_DIR.

Options:
      --prefix DIR    Code install dir (default: $PREFIX)
      --bin-dir DIR   Launcher dir   (default: $BIN_DIR)
      --remove        Remove the installed code and launcher (state is kept)
      --dry-run       Print actions without changing anything
  -h, --help          Show this help

Environment:
  QGPU_INSTALL_DIR    Same as --prefix
  QGPU_BIN_DIR        Same as --bin-dir
  QGPU_HOME           Runtime state dir (default: \$XDG_STATE_HOME/qgpu)

Examples:
  ./install.sh
  ./install.sh --prefix /opt/qgpu --bin-dir /usr/local/bin
  ./install.sh --remove
EOF
}

while (($#)); do
  case "$1" in
    --prefix)
      (($# > 1)) || die "--prefix requires a value"
      PREFIX="$2"; shift ;;
    --prefix=*) PREFIX="${1#*=}" ;;
    --bin-dir)
      (($# > 1)) || die "--bin-dir requires a value"
      BIN_DIR="$2"; shift ;;
    --bin-dir=*) BIN_DIR="${1#*=}" ;;
    --remove) ACTION="remove" ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

PREFIX="${PREFIX/#\~/$HOME}"
BIN_DIR="${BIN_DIR/#\~/$HOME}"
LAUNCHER="${BIN_DIR}/qgpu"

run() {
  if ((DRY_RUN)); then
    printf '    [dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

do_remove() {
  log "removing qGPU"
  if [[ -L "$LAUNCHER" ]]; then
    local target
    target="$(readlink -f "$LAUNCHER" 2>/dev/null || true)"
    if [[ "$target" == "${PREFIX}/"* ]]; then
      run rm -f "$LAUNCHER"
      info "removed launcher $LAUNCHER"
    else
      warn "$LAUNCHER does not point into $PREFIX; leaving it alone"
    fi
  elif [[ -e "$LAUNCHER" ]]; then
    warn "$LAUNCHER is not a symlink; leaving it alone"
  else
    info "no launcher at $LAUNCHER"
  fi
  if [[ -d "$PREFIX" ]]; then
    if [[ "$(cd "$PREFIX" && pwd)" == "$SRC_DIR" ]]; then
      warn "$PREFIX is the source tree; leaving it alone"
    else
      run rm -rf "$PREFIX"
      info "removed code dir $PREFIX"
    fi
  fi
  info "runtime state left untouched; delete it manually if you want a clean slate:"
  info "  \${QGPU_HOME:-\$XDG_STATE_HOME/qgpu}  (default ~/.local/state/qgpu)"
}

do_install() {
  log "installing qGPU"
  [[ -f "${SRC_DIR}/qgpu.py" ]] || die "qgpu.py not found next to install.sh"
  if ! command -v python3 >/dev/null 2>&1; then
    die "python3 is required (standard library only)"
  fi
  info "python3: $(command -v python3)"
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    warn "nvidia-smi not found; the scheduler will wait until a GPU driver is visible"
  fi
  info "code dir: $PREFIX"
  info "launcher: $LAUNCHER"

  run mkdir -p "$PREFIX" "$BIN_DIR"
  if [[ "$(cd "$PREFIX" 2>/dev/null && pwd)" == "$SRC_DIR" ]]; then
    info "code already lives in $PREFIX; skipping copy"
  else
    local file
    for file in "${FILES[@]}"; do
      [[ -f "${SRC_DIR}/${file}" ]] || die "missing source file: ${file}"
      run command install -m "$([[ "$file" == "qgpu" ]] && echo 755 || echo 644)" \
        "${SRC_DIR}/${file}" "${PREFIX}/${file}"
    done
  fi
  if [[ -e "$LAUNCHER" && ! -L "$LAUNCHER" ]]; then
    warn "$LAUNCHER exists and is not a symlink; leaving it alone (move it away, then re-run)"
  else
    if [[ -L "$LAUNCHER" ]]; then
      local current
      current="$(readlink -f "$LAUNCHER" 2>/dev/null || true)"
      [[ -z "$current" || "$current" == "${PREFIX}/qgpu" ]] ||
        info "replacing symlink $LAUNCHER (was -> $current)"
    fi
    run ln -sfn "${PREFIX}/qgpu" "$LAUNCHER"
  fi

  printf '\n'
  log "done"
  info "state dir: \${QGPU_HOME:-\$XDG_STATE_HOME/qgpu} (default ~/.local/state/qgpu)"
  info "next:  qgpu detect      # check the visible GPUs"
  info "       qgpu start       # start the scheduler"
  info "       qgpu submit -- python train.py"
  case ":$PATH:" in
    *":${BIN_DIR}:"*) ;;
    *) info "note: ${BIN_DIR} is not on PATH; add it to your shell profile" ;;
  esac
}

case "$ACTION" in
  install) do_install ;;
  remove) do_remove ;;
esac