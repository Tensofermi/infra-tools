#!/usr/bin/env bash
# Self-contained installer for the `proxy` control CLI (mihomo / Clash Meta).
#
# Copies the CLI and its shell integration next to the mihomo instance — by
# default ~/Mihomo, the same directory install-fast/install-mihomo.sh uses —
# links a `proxy` launcher into BIN_DIR, and wires a managed block into the
# shell rc files so `proxy on` can export HTTP(S)_PROXY into the *current*
# shell.
#
# `proxy on` has to mutate the environment of your interactive shell, which a
# child process cannot do. That is why there is a launcher (for `proxy status`
# and friends) *and* a sourced function (for `on` / `off`).
#
# Runtime requirements: bash, curl, python3. mihomo itself comes from
# install-fast/install-mihomo.sh.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${MIHOMO_DIR:-$HOME/Mihomo}"
BIN_DIR="${PROXY_BIN_DIR:-$HOME/.local/bin}"
ACTION="install"
DRY_RUN=0
PREFIX_GIVEN=0
WITH_RC=1
SUB_FILE=""
NO_PROXY_EXTRA=""

FILES=(proxy proxy-shell.sh)
START_MARK="# >>> infra-tools proxy >>>"
END_MARK="# <<< infra-tools proxy <<<"
# Hand-rolled block from before the CLI lived in this repo; dropped on install
# so the shell does not source the library twice.
LEGACY_START="# >>> proxy cli (mihomo) >>>"
LEGACY_END="# <<< proxy cli (mihomo) <<<"

log()  { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '[skip] %s\n' "$*" >&2; }
die()  { printf '[error] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: install.sh [options]

Install the `proxy` CLI into the mihomo directory and wire it into your shell.

Options:
      --prefix DIR    Where mihomo lives (default: $PREFIX)
      --bin-dir DIR   Launcher dir       (default: $BIN_DIR)
      --rc FILE       Extra rc file to wire up (repeatable)
      --sub-file FILE Subscription link file for `proxy update`
                      (default: $PREFIX/subscription)
      --no-proxy LIST Extra hosts that must bypass the proxy, comma separated
      --no-rc         Do not touch any rc file (print the lines to add instead)
      --remove        Remove the CLI, the launcher and the rc block
      --dry-run       Print actions without changing anything
  -h, --help          Show this help

Environment:
  MIHOMO_DIR          Same as --prefix (also read by the CLI at runtime)
  PROXY_BIN_DIR       Same as --bin-dir

Examples:
  ./install.sh                                  # ~/Mihomo + ~/.local/bin
  ./install.sh --prefix /etc/mihomo --no-rc
  ./install.sh --remove
EOF
}

EXTRA_RC=()
while (($#)); do
  case "$1" in
    --prefix)   (($# > 1)) || die "--prefix requires a value";   PREFIX="$2"; PREFIX_GIVEN=1; shift ;;
    --prefix=*) PREFIX="${1#*=}" ;;
    --bin-dir)  (($# > 1)) || die "--bin-dir requires a value";  BIN_DIR="$2"; shift ;;
    --bin-dir=*) BIN_DIR="${1#*=}" ;;
    --rc)       (($# > 1)) || die "--rc requires a path";        EXTRA_RC+=("$2"); shift ;;
    --rc=*)     EXTRA_RC+=("${1#*=}") ;;
    --sub-file) (($# > 1)) || die "--sub-file requires a path";  SUB_FILE="$2"; shift ;;
    --sub-file=*) SUB_FILE="${1#*=}" ;;
    --no-proxy) (($# > 1)) || die "--no-proxy requires a list";   NO_PROXY_EXTRA="$2"; shift ;;
    --no-proxy=*) NO_PROXY_EXTRA="${1#*=}" ;;
    --no-rc)    WITH_RC=0 ;;
    --remove)   ACTION="remove" ;;
    --dry-run)  DRY_RUN=1 ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

# Expand a leading ~ the way the shell would.
PREFIX="${PREFIX/#\~/$HOME}"
BIN_DIR="${BIN_DIR/#\~/$HOME}"
PREFIX="${PREFIX%/}"
LAUNCHER="${BIN_DIR}/proxy"

run() {
  if ((DRY_RUN)); then
    printf '    [dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

# Double-quote a path for embedding in shell code.
dq() { printf '"%s"' "$(printf '%s' "$1" | sed -e 's/[\\"$`]/\\&/g')"; }

# Atomic replace: write a temp file in the same directory, then mv over the
# destination. A killed installer must never leave a half-written ~/.bashrc.
replace_file() { # dest  (content on stdin)
  local dest="$1" tmp m
  tmp="$(mktemp "${dest}.XXXXXX")"
  cat >"$tmp"
  m="$(stat -c %a "$dest" 2>/dev/null || stat -f %Lp "$dest" 2>/dev/null || true)"
  chmod "${m:-644}" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$dest"
}

# Resolve a symlink by hand: BSD/macOS readlink has no -f.
link_target() { # path -> target path (absolute when possible)
  local p="$1" t d
  t="$(readlink "$p" 2>/dev/null || true)"
  [[ -n "$t" ]] || return 1
  case "$t" in
    /*) printf '%s' "$t" ;;
    *) d="$(cd "$(dirname "$p")" && pwd)"; printf '%s/%s' "$d" "$t" ;;
  esac
}

# Where the installed CLI's instance directory is recorded (read by proxy itself).
marker_file() { printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/infra-tools/mihomo-dir"; }

# rc files to manage: ~/.bashrc always, ~/.zshrc when zsh is around, plus --rc.
rc_files() {
  local rc
  local -a files=("${HOME}/.bashrc")
  if [[ -f "${HOME}/.zshrc" || "${SHELL:-}" == */zsh ]]; then
    files+=("${HOME}/.zshrc")
  fi
  for rc in ${EXTRA_RC[@]+"${EXTRA_RC[@]}"}; do
    rc="${rc/#\~/$HOME}"
    files+=("$rc")
  done
  printf '%s\n' "${files[@]}" | awk '!seen[$0]++'
}

# Print stdin with the block between the given markers removed.
strip_block() { # [start end]
  awk -v s="${1:-$START_MARK}" -v e="${2:-$END_MARK}" '
    substr($0, 1, length(s)) == s { skip = 1 }
    skip && substr($0, 1, length(e)) == e { skip = 0; next }
    !skip { print }
  '
}

install_rc() {
  local rc="$1" tmp
  mkdir -p "$(dirname "$rc")"
  tmp="$(mktemp "${rc}.body.XXXXXX")"
  if [[ -f "$rc" ]]; then
    strip_block "$LEGACY_START" "$LEGACY_END" <"$rc" | strip_block >"$tmp"
  fi
  {
    cat "$tmp"
    printf '%s\n' "$START_MARK"
    printf '# infra-tools proxy CLI (written by %s/install.sh; re-run it to refresh this block)\n' "$SRC_DIR"
    printf 'export PROXY_CLI_BIN=%s\n' "$(dq "${PREFIX}/proxy")"
    [[ -n "$SUB_FILE" ]] && printf 'export PROXY_SUB_FILE=%s\n' "$(dq "$SUB_FILE")"
    [[ -n "$NO_PROXY_EXTRA" ]] && printf 'export PROXY_NO_PROXY=%s\n' "$(dq "$NO_PROXY_EXTRA")"
    printf '[ -f %s ] && . %s\n' "$(dq "${PREFIX}/proxy-shell.sh")" "$(dq "${PREFIX}/proxy-shell.sh")"
    printf '%s\n' "$END_MARK"
  } | replace_file "$rc"
  rm -f "$tmp"
}

remove_rc() {
  local rc="$1"
  [[ -f "$rc" ]] || return 0
  grep -qF "$START_MARK" "$rc" || return 0
  strip_block <"$rc" | replace_file "$rc"
}

do_remove() {
  log "removing the proxy CLI"
  if [[ -L "$LAUNCHER" ]]; then
    local target want
    target="$(link_target "$LAUNCHER" || true)"; want="$(cd "$PREFIX" 2>/dev/null && pwd)/proxy"
    if [[ "$target" == "${PREFIX}/proxy" || "$target" == "$want" ]]; then
      run rm -f "$LAUNCHER"
      info "removed launcher $LAUNCHER"
    else
      warn "$LAUNCHER points at ${target:-?}, not ${PREFIX}/proxy; leaving it alone"
    fi
  elif [[ -e "$LAUNCHER" ]]; then
    warn "$LAUNCHER is not a symlink; leaving it alone"
  else
    info "no launcher at $LAUNCHER"
  fi

  local f
  for f in "${FILES[@]}"; do
    [[ -e "${PREFIX}/${f}" ]] || continue
    run rm -f "${PREFIX}/${f}"
    info "removed ${PREFIX}/${f}"
  done

  local marker; marker="$(marker_file)"
  if [[ -f "$marker" ]] && [[ "$(cat "$marker")" == "$PREFIX" ]]; then
    run rm -f "$marker"
    info "removed instance-dir marker ${marker}"
  fi

  if ((WITH_RC)); then
    local rc
    while IFS= read -r rc; do
      remove_rc "$rc"
      info "removed the managed block from $rc"
    done < <(rc_files)
  fi

  # mihomo, config.yaml, logs and the subscription are deliberately untouched.
  info "mihomo, config.yaml and caches in ${PREFIX} were left alone"
  info "(the mihomo directory itself is never deleted)"
}

do_install() {
  log "installing the proxy CLI"
  local f
  for f in "${FILES[@]}"; do
    [[ -f "${SRC_DIR}/${f}" ]] || die "missing source file: ${f}"
  done

  command -v curl >/dev/null 2>&1 ||
    warn "curl not found; the CLI needs it to reach the mihomo controller and probe nodes"
  command -v python3 >/dev/null 2>&1 ||
    warn "python3 not found; the CLI needs it to parse the mihomo controller JSON"
  if [[ ! -x "${PREFIX}/mihomo" ]]; then
    warn "no mihomo binary at ${PREFIX}/mihomo yet"
    info "install it first:  bash install-fast/install-mihomo.sh --start"
  elif [[ ! -x "${PREFIX}/mihomoctl" ]]; then
    warn "no mihomoctl at ${PREFIX}/mihomoctl (re-run install-mihomo.sh to get it)"
  fi

  info "prefix  : $PREFIX"
  info "launcher: $LAUNCHER"

  run mkdir -p "$PREFIX" "$BIN_DIR"
  if [[ "$(cd "$PREFIX" 2>/dev/null && pwd)" == "$(cd "$SRC_DIR" && pwd)" ]]; then
    info "source and target are the same directory; skipping the copy"
  else
    run install -m 0755 "${SRC_DIR}/proxy" "${PREFIX}/proxy"
    run install -m 0644 "${SRC_DIR}/proxy-shell.sh" "${PREFIX}/proxy-shell.sh"
  fi

  if [[ -e "$LAUNCHER" && ! -L "$LAUNCHER" ]]; then
    warn "$LAUNCHER exists and is not a symlink; leaving it alone (move it away, then re-run)"
  else
    run ln -sfn "${PREFIX}/proxy" "$LAUNCHER"
  fi

  # The CLI looks for ~/Mihomo by default; an install under --prefix records the
  # real directory here so `proxy` still finds config.yaml / the pid file.
  local marker; marker="$(marker_file)"
  if [[ "$PREFIX" == "${HOME}/Mihomo" ]]; then
    if [[ -f "$marker" ]]; then
      run rm -f "$marker"
      info "dropped stale instance-dir marker"
    fi
  else
    run mkdir -p "$(dirname "$marker")"
    if ((DRY_RUN)); then
      printf '    [dry-run] would record %s in %s\n' "$PREFIX" "$marker"
    else
      printf '%s\n' "$PREFIX" >"$marker"
      info "recorded instance dir in $marker"
    fi
  fi

  if ((WITH_RC)); then
    local rc
    while IFS= read -r rc; do
      run install_rc "$rc"
      info "wired up $rc"
    done < <(rc_files)
  else
    info "--no-rc: add these two lines to your rc file yourself:"
    printf '        export PROXY_CLI_BIN=%s\n' "$(dq "${PREFIX}/proxy")"
    printf '        . %s\n' "$(dq "${PREFIX}/proxy-shell.sh")"
  fi

  printf '\n'
  log "done"
  info "open a new shell (or source your rc file), then:"
  info "  proxy on        # start mihomo, pick a node, export HTTP(S)_PROXY"
  info "  proxy status    # VPN / node / egress / this shell"
  info "  proxy off       # stop mihomo and clear the environment"
  case ":$PATH:" in
    *":${BIN_DIR}:"*) ;;
    *) info "note: ${BIN_DIR} is not on PATH; add it to your shell profile" ;;
  esac
  info "runtime requirements: curl + python3; mihomo binary from install-fast/install-mihomo.sh"
}

# --remove without --prefix: fall back to the instance dir recorded at install
# time, otherwise an install made with `--prefix /data/mihomo` could never be
# removed without repeating the same --prefix.
if [[ "$ACTION" == "remove" ]] && ((!PREFIX_GIVEN)); then
  _marker="$(marker_file)"
  if [[ -r "$_marker" ]]; then
    IFS= read -r PREFIX <"$_marker"
  fi
fi

case "$ACTION" in
  install) do_install ;;
  remove)  do_remove ;;
esac
