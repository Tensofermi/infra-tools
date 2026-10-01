#!/usr/bin/env bash
# shellcheck disable=SC2016

# Shared library for the install-fast installers.
# Sourced by install-user.sh (user space) and install-root.sh (system wide).
# Keep this file dependency-free: bash + coreutils + curl/wget only.

# Wrappers preset MODE before sourcing; default to user space.
MODE="${MODE:-user}"

DRY_RUN=0
MIRROR=1
USE_SUDO=0
DISABLE_COLOR=0
SELECTED="base,cli,dev,python"
PKG_MGR=""
SUDO_CMD=""
CAN_SYSTEM=0

case "$MODE" in
  root)
    BIN_DIR="/usr/local/bin"
    CONDA_PREFIX="/opt/miniforge3"
    PROFILE_FILE="/etc/profile.d/install-fast.sh"
    ;;
  *)
    BIN_DIR="${HOME}/.local/bin"
    CONDA_PREFIX="${HOME}/miniforge3"
    PROFILE_FILE="${HOME}/.bashrc"
    ;;
esac

ARCH_X86="x86_64"
ARCH_AMD="amd64"

# ---------------------------------------------------------------- logging ----

setup_colors() {
  if [[ -t 1 && "${TERM:-dumb}" != "dumb" && -z "${NO_COLOR:-}" ]] && ((DISABLE_COLOR == 0)); then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_CYAN=$'\033[36m'
  else
    C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_CYAN=""
  fi
}
setup_colors

log()  { printf '%s==>%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%s[skip]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[error]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

die() {
  err "$*"
  exit 1
}

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------------ utils ----

run() {
  if ((DRY_RUN)); then
    printf '%s    [dry-run]%s %s\n' "$C_DIM" "$C_RESET" "$*"
    return 0
  fi
  "$@"
}

download() {
  local url="$1" out="$2"
  if ((DRY_RUN)); then
    printf '%s    [dry-run]%s download %s\n' "$C_DIM" "$C_RESET" "$url"
    return 0
  fi
  if have curl; then
    curl -fL --retry 3 --connect-timeout 15 -o "$out" "$url"
  elif have wget; then
    wget -q -O "$out" "$url"
  else
    err "neither curl nor wget is available"
    return 1
  fi
}

github_asset() {
  local repo="$1" pattern="$2" json
  ((DRY_RUN)) && return 0
  json="$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null)" || return 1
  printf '%s' "$json" |
    grep -oE '"browser_download_url":[[:space:]]*"[^"]+"' |
    sed -E 's/.*"(https:[^"]+)".*/\1/' |
    grep -E "$pattern" | head -n1
}

terminal_missing() {
  local missing=() c
  for c in "$@"; do have "$c" || missing+=("$c"); done
  ((${#missing[@]})) && printf '%s' "${missing[*]}"
  return 0
}

sudo_hint() {
  case "$PKG_MGR" in
    apt)      printf 'sudo apt-get install -y %s' "$*" ;;
    dnf|yum)  printf 'sudo %s install -y %s' "$PKG_MGR" "$*" ;;
    pacman)   printf 'sudo pacman -S --needed %s' "$*" ;;
    brew)     printf 'brew install %s' "$*" ;;
    *)        printf '(no package manager detected; install manually: %s)' "$*" ;;
  esac
}

# --------------------------------------------------------------- packages ----

detect_pkg_manager() {
  if have apt-get; then PKG_MGR="apt"
  elif have dnf; then PKG_MGR="dnf"
  elif have yum; then PKG_MGR="yum"
  elif have pacman; then PKG_MGR="pacman"
  elif have brew; then PKG_MGR="brew"
  else PKG_MGR="none"; fi
}

compute_can_system() {
  SUDO_CMD=""
  if [[ "$MODE" == "root" ]]; then CAN_SYSTEM=1; return; fi
  if [[ "$PKG_MGR" == "brew" ]]; then CAN_SYSTEM=1; return; fi
  if ((USE_SUDO)) && have sudo; then SUDO_CMD="sudo"; CAN_SYSTEM=1; return; fi
  CAN_SYSTEM=0
}

group_pkgs() {
  case "${1}:${PKG_MGR}" in
    base:apt)          echo "ca-certificates curl wget git unzip zip jq" ;;
    base:dnf|base:yum) echo "ca-certificates curl wget git unzip zip jq" ;;
    base:pacman)       echo "ca-certificates curl wget git unzip zip jq" ;;
    base:brew)         echo "jq unzip zip" ;;

    cli:apt)           echo "tree ripgrep fd-find fzf tmux htop" ;;
    cli:dnf|cli:yum)   echo "tree ripgrep fd-find fzf tmux htop" ;;
    cli:pacman)        echo "tree ripgrep fd fzf tmux htop" ;;
    cli:brew)          echo "tree ripgrep fd fzf tmux htop" ;;

    dev:apt)           echo "build-essential g++ gdb cmake ninja-build pkg-config" ;;
    dev:dnf|dev:yum)   echo "gcc-c++ make gdb cmake ninja-build pkgconf-pkg-config" ;;
    dev:pacman)        echo "base-devel gdb cmake ninja pkgconf" ;;
    dev:brew)          echo "gcc gdb cmake ninja pkg-config" ;;
    *)                 echo "" ;;
  esac
}

pkg_install() {
  local pkgs=("$@")
  ((${#pkgs[@]})) || return 0
  [[ "$PKG_MGR" == "none" ]] && { warn "no package manager found; cannot install: ${pkgs[*]}"; return 1; }
  log "package install: ${pkgs[*]}"
  case "$PKG_MGR" in
    apt)
      run $SUDO_CMD env DEBIAN_FRONTEND=noninteractive apt-get update -y &&
        run $SUDO_CMD env DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
      ;;
    dnf|yum) run $SUDO_CMD "$PKG_MGR" install -y "${pkgs[@]}" ;;
    pacman)  run $SUDO_CMD pacman -Sy --noconfirm --needed "${pkgs[@]}" ;;
    brew)    run brew install "${pkgs[@]}" ;;
  esac
}

fix_fd_alias() {
  have fdfind || return 0
  have fd && return 0
  log "linking fdfind -> $BIN_DIR/fd"
  ((DRY_RUN)) && return 0
  mkdir -p "$BIN_DIR"
  ln -sf "$(command -v fdfind)" "$BIN_DIR/fd"
}

# ------------------------------------------------------ user-land install ----

install_tarball_bin() {
  local url="$1" glob="$2" name="$3" tmp archive bin
  tmp="$(mktemp -d)"
  archive="$tmp/archive.tar.gz"
  log "downloading ${name}"
  if ! download "$url" "$archive"; then
    warn "download failed for ${name}: $url"
    rm -rf "$tmp"
    return 1
  fi
  ((DRY_RUN)) && { rm -rf "$tmp"; return 0; }
  if ! tar -xzf "$archive" -C "$tmp" 2>/dev/null; then
    warn "could not extract ${name} archive"
    rm -rf "$tmp"
    return 1
  fi
  bin="$(find "$tmp" -type f -name "$glob" -perm -u+x | head -n1)"
  if [[ -z "$bin" ]]; then
    warn "${name} binary not found in archive"
    rm -rf "$tmp"
    return 1
  fi
  mkdir -p "$BIN_DIR"
  install -m 0755 "$bin" "$BIN_DIR/$name"
  log "installed ${name} -> ${BIN_DIR}/${name}"
  rm -rf "$tmp"
}

install_rg_binary() {
  have rg && { info "rg already installed"; return; }
  if [[ "$(uname -s)" != "Linux" ]]; then
    warn "install ripgrep with: brew install ripgrep"
    return
  fi
  local url
  url="$(github_asset BurntSushi/ripgrep "ripgrep-.*-${ARCH_X86}-unknown-linux-gnu.tar.gz")"
  [[ -n "$url" ]] || url="https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep-14.1.1-${ARCH_X86}-unknown-linux-gnu.tar.gz"
  install_tarball_bin "$url" "rg" "rg"
}

install_fd_binary() {
  have fd && { info "fd already installed"; return; }
  if [[ "$(uname -s)" != "Linux" ]]; then
    warn "install fd with: brew install fd"
    return
  fi
  local url
  url="$(github_asset sharkdp/fd "fd-v.*-${ARCH_X86}-unknown-linux-gnu.tar.gz")"
  [[ -n "$url" ]] || url="https://github.com/sharkdp/fd/releases/download/v10.2.0/fd-v10.2.0-${ARCH_X86}-unknown-linux-gnu.tar.gz"
  install_tarball_bin "$url" "fd" "fd"
}

install_fzf_binary() {
  have fzf && { info "fzf already installed"; return; }
  if [[ "$(uname -s)" != "Linux" ]]; then
    warn "install fzf with: brew install fzf"
    return
  fi
  local url
  url="$(github_asset junegunn/fzf "fzf-.*-linux_${ARCH_AMD}.tar.gz")"
  [[ -n "$url" ]] || url="https://github.com/junegunn/fzf/releases/download/v0.56.3/fzf-0.56.3-linux_${ARCH_AMD}.tar.gz"
  install_tarball_bin "$url" "fzf" "fzf"
}

install_jq_binary() {
  have jq && { info "jq already installed"; return; }
  if [[ "$(uname -s)" != "Linux" ]]; then
    warn "install jq with: brew install jq"
    return
  fi
  log "downloading jq"
  mkdir -p "$BIN_DIR"
  ((DRY_RUN)) && { printf '%s    [dry-run]%s install jq -> %s\n' "$C_DIM" "$C_RESET" "$BIN_DIR/jq"; return 0; }
  if download "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-${ARCH_AMD}" "$BIN_DIR/jq"; then
    chmod 0755 "$BIN_DIR/jq"
    log "installed jq -> ${BIN_DIR}/jq"
  else
    warn "jq download failed"
  fi
}

install_tree_source() {
  have tree && { info "tree already installed"; return; }
  if ! have make || { ! have cc && ! have gcc && ! have clang; }; then
    warn "tree needs a C compiler + make; try: $(sudo_hint tree)"
    return
  fi
  local tmp
  tmp="$(mktemp -d)"
  log "building tree from source"
  if ((DRY_RUN)); then
    info "would clone and build tree"
    rm -rf "$tmp"
    return 0
  fi
  if git clone --depth 1 https://github.com/Old-Man-Programmer/tree.git "$tmp/tree" >/dev/null 2>&1 &&
     make -C "$tmp/tree" >/dev/null 2>&1; then
    mkdir -p "$BIN_DIR"
    install -m 0755 "$tmp/tree/tree" "$BIN_DIR/tree"
    log "installed tree -> ${BIN_DIR}/tree"
  else
    warn "tree build failed; try: $(sudo_hint tree)"
  fi
  rm -rf "$tmp"
}

install_uv() {
  have uv && { info "uv already installed ($(uv --version 2>/dev/null))"; return; }
  local tmp
  tmp="$(mktemp)"
  log "installing uv"
  if ! download "https://astral.sh/uv/install.sh" "$tmp"; then
    warn "uv installer download failed"
    rm -f "$tmp"
    return 1
  fi
  ((DRY_RUN)) && { info "would install uv into $BIN_DIR"; rm -f "$tmp"; return 0; }
  env UV_INSTALL_DIR="$BIN_DIR" UV_NO_MODIFY_PATH=1 sh "$tmp" || warn "uv install failed"
  rm -f "$tmp"
}

install_conda() {
  if [[ -x "$CONDA_PREFIX/bin/conda" ]]; then
    info "conda already installed at $CONDA_PREFIX"
    return
  fi
  local os arch name url tmp
  case "$(uname -s)" in
    Linux)  os="Linux" ;;
    Darwin) os="MacOSX" ;;
    *) warn "unsupported OS for conda"; return 1 ;;
  esac
  case "${os}:$(uname -m)" in
    Linux:x86_64|Linux:amd64)   arch="x86_64" ;;
    Linux:aarch64|Linux:arm64)  arch="aarch64" ;;
    MacOSX:x86_64)              arch="x86_64" ;;
    MacOSX:arm64|MacOSX:aarch64) arch="arm64" ;;
    *) warn "unsupported arch for conda: $(uname -m)"; return 1 ;;
  esac
  name="Miniforge3-${os}-${arch}.sh"
  url="https://github.com/conda-forge/miniforge/releases/latest/download/${name}"
  tmp="$(mktemp -d)/miniforge.sh"
  log "installing conda (Miniforge) -> $CONDA_PREFIX"
  if ! download "$url" "$tmp"; then
    warn "miniforge download failed"
    return 1
  fi
  ((DRY_RUN)) && { info "would run miniforge installer"; return 0; }
  mkdir -p "$(dirname "$CONDA_PREFIX")"
  if [[ "$MODE" == "root" ]]; then
    env CONDA_DIR="$CONDA_PREFIX" sh "$tmp" -b -p "$CONDA_PREFIX" || warn "conda install failed"
  else
    sh "$tmp" -b -p "$CONDA_PREFIX" || warn "conda install failed"
  fi
  if [[ -x "$CONDA_PREFIX/bin/conda" && "$MODE" != "root" ]]; then
    "$CONDA_PREFIX/bin/conda" init bash >/dev/null 2>&1 || true
  fi
}

# ---------------------------------------------------------------- groups -----

install_group_pkgs() {
  local -a pkgs
  read -ra pkgs < <(group_pkgs "$1")
  ((${#pkgs[@]})) || { warn "no packages mapped for group '$1' on $PKG_MGR"; return 0; }
  pkg_install "${pkgs[@]}"
}

do_base() {
  log "base tools"
  if ((CAN_SYSTEM)); then
    install_group_pkgs base
  else
    local missing
    missing="$(terminal_missing curl wget git)"
    [[ -n "$missing" ]] && warn "missing base commands: ${missing} (need root/pkg manager)"
    have jq || install_jq_binary
  fi
}

do_cli() {
  log "cli tools"
  if ((CAN_SYSTEM)); then
    install_group_pkgs cli
    fix_fd_alias
  else
    install_rg_binary
    install_fd_binary
    install_fzf_binary
    install_tree_source
    have tmux || warn "tmux needs root: $(sudo_hint tmux)"
    have htop || warn "htop needs root: $(sudo_hint htop)"
  fi
}

do_dev() {
  log "dev toolchain"
  if ((CAN_SYSTEM)); then
    install_group_pkgs dev
  else
    warn "g++/make/cmake need root: $(sudo_hint build-essential g++ gdb cmake ninja-build pkg-config)"
  fi
}

do_python() {
  log "python tooling"
  install_uv
  install_conda
}

list_groups() {
  cat <<EOF
Groups:
  base    git curl wget unzip zip ca-certificates jq
  cli     tree ripgrep(rg) fd fzf tmux htop
  dev     g++/build-essential make gdb cmake ninja pkg-config
  python  uv + conda (Miniforge, includes mamba)
EOF
}

# ------------------------------------------------------------------ config ---

write_profile() {
  [[ -n "$PROFILE_FILE" ]] || return 0
  log "updating PATH in $PROFILE_FILE"
  if ((DRY_RUN)); then
    info "[dry-run] would write managed block to $PROFILE_FILE"
    return 0
  fi
  local start="# >>> install-fast >>>" end="# <<< install-fast >>>" tmp
  tmp="$(mktemp)"
  if [[ -f "$PROFILE_FILE" ]]; then
    awk -v s="$start" -v e="$end" '
      index($0, s) { skip = 1 }
      skip && index($0, e) { skip = 0; next }
      !skip { print }
    ' "$PROFILE_FILE" > "$tmp"
  fi
  local dir="${PROFILE_FILE%/*}"
  [[ -d "$dir" ]] || mkdir -p "$dir"
  {
    cat "$tmp"
    printf '%s\n' "$start"
    printf 'export PATH="%s:$PATH"\n' "$BIN_DIR"
    if [[ -d "$CONDA_PREFIX/bin" ]]; then
      printf 'export PATH="%s:$PATH"\n' "$CONDA_PREFIX/bin"
    fi
    ((MIRROR)) && printf 'export UV_DEFAULT_INDEX="https://pypi.tuna.tsinghua.edu.cn/simple"\n'
    ((MIRROR)) && printf 'export HF_ENDPOINT="https://hf-mirror.com"\n'
    printf '%s\n' "$end"
  } > "$PROFILE_FILE"
  rm -f "$tmp"
}

configure_mirrors() {
  ((MIRROR)) || return 0
  local pip_conf
  if [[ "$MODE" == "root" ]]; then pip_conf="/etc/pip.conf"; else pip_conf="${HOME}/.config/pip/pip.conf"; fi
  log "configuring mirrors (pip / uv / conda / HF)"
  if [[ -f "$pip_conf" ]]; then
    info "keeping existing $pip_conf"
  elif ((DRY_RUN)); then
    info "[dry-run] would write $pip_conf"
  else
    mkdir -p "${pip_conf%/*}"
    cat > "$pip_conf" <<'EOF'
[global]
index-url = https://pypi.tuna.tsinghua.edu.cn/simple
EOF
  fi
  if [[ -x "$CONDA_PREFIX/bin/conda" && ! -f "$CONDA_PREFIX/.condarc" && "$MODE" != "root" ]]; then
    ((DRY_RUN)) || cat > "$CONDA_PREFIX/.condarc" <<'EOF'
channels:
  - conda-forge
custom_channels:
  conda-forge: https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud
show_channel_urls: true
EOF
  fi
}

# ----------------------------------------------------------------- verify ----

tool_path() {
  local t="$1"
  if have "$t"; then command -v "$t"; return; fi
  if [[ -x "$CONDA_PREFIX/bin/$t" ]]; then printf '%s' "$CONDA_PREFIX/bin/$t"; return; fi
  if [[ -x "$BIN_DIR/$t" ]]; then printf '%s' "$BIN_DIR/$t"; return; fi
  return 1
}

verify() {
  printf '\n%sInstalled tool summary%s\n' "$C_BOLD" "$C_RESET"
  local t path
  for t in git curl wget jq tree rg fd fzf tmux htop g++ make cmake uv conda; do
    if path="$(tool_path "$t")"; then
      printf '  %s%-6s%s %s\n' "$C_GREEN" "$t" "$C_RESET" "$path"
    else
      printf '  %s%-6s%s not found\n' "$C_DIM" "$t" "$C_RESET"
    fi
  done
}

# ------------------------------------------------------------------- main ----

usage() {
  local prog="$1"
  cat <<EOF
Usage: ${prog} [options]

One-shot installer for a fresh dev/GPU server. Idempotent: safe to re-run.

Options:
      --only GROUPS     Comma list: base,cli,dev,python (default: all)
      --skip GROUPS     Remove groups from the default set
      --dry-run         Print actions without changing anything
      --no-mirror       Do not write pip/uv/conda/HF China mirrors
      --use-sudo        (user mode) allow sudo for system packages
      --no-color        Disable ANSI colors
      --list            Show available groups
  -h, --help            Show this help

Examples:
  ${prog}
  ${prog} --only base,cli,python
  ${prog} --skip dev --dry-run
EOF
}

parse_args() {
  local prog="$1"; shift
  while (($#)); do
    case "$1" in
      --only)
        (($# > 1)) || die "--only requires a value"
        SELECTED="$2"; shift ;;
      --skip)
        (($# > 1)) || die "--skip requires a value"
        local skip="$2" g kept=""
        local -a _g
        IFS=',' read -ra _g <<<"$SELECTED"
        for g in "${_g[@]}"; do
          [[ ",$skip," == *",$g,"* ]] || kept+="${kept:+,}$g"
        done
        SELECTED="$kept"; shift ;;
      --dry-run)   DRY_RUN=1 ;;
      --no-mirror) MIRROR=0 ;;
      --use-sudo)  USE_SUDO=1 ;;
      --no-color)  DISABLE_COLOR=1 ;;
      --list)      list_groups; exit 0 ;;
      -h|--help)   usage "$prog"; exit 0 ;;
      *)           die "unknown option: $1 (try --help)" ;;
    esac
    shift
  done
  setup_colors
}

main() {
  local prog="${0##*/}"
  parse_args "$prog" "$@"

  detect_pkg_manager
  compute_can_system

  printf '%s%sinstall-fast%s (%s mode)  pkg=%s  bin=%s\n' \
    "$C_BOLD" "$C_CYAN" "$C_RESET" "$MODE" "$PKG_MGR" "$BIN_DIR"
  ((DRY_RUN)) && info "dry-run: no changes will be made"
  [[ "$PKG_MGR" == "none" && "$MODE" != "root" ]] &&
    info "no package manager: will install as much as possible in user space"

  ((DRY_RUN)) || mkdir -p "$BIN_DIR"

  local g
  local -a _groups
  IFS=',' read -ra _groups <<<"$SELECTED"
  for g in "${_groups[@]}"; do
    case "$g" in
      "") ;;
      base|cli|dev|python) "do_$g" ;;
      *) warn "unknown group: $g" ;;
    esac
  done

  write_profile
  configure_mirrors
  verify

  printf '\n%sDone.%s ' "$C_GREEN" "$C_RESET"
  if [[ "$MODE" != "root" ]]; then
    printf 'Run: %ssource %s%s\n' "$C_BOLD" "$PROFILE_FILE" "$C_RESET"
  else
    printf 'Open a new shell to load %s%s%s\n' "$C_BOLD" "$PROFILE_FILE" "$C_RESET"
  fi
}