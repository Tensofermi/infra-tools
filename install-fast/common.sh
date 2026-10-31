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
SELECTED="base,cli,dev,python,vcs,qgpu,monitor"
PKG_MGR=""
SUDO_CMD=""
CAN_SYSTEM=0

# install-fast/ lives next to the component directories it can wire up.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QGPU_SRC="${REPO_ROOT}/qgpu"
MONITOR_SRC="${REPO_ROOT}/monitor"

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

# GitHub 镜像兜底设置（见下面的 download()）。
# 国内直连 GitHub 经常是"TCP 握手成功但一个字节都不给"，curl 会一直挂着，
# 看上去就是"下载特别慢"；这几条镜像只要在原始 URL 前面拼一个前缀即可转发。
#   GH_MIRROR=<一个前缀>           只用这一个
#   GH_MIRRORS="<空格分隔的多个>"   按顺序尝试
#   DISABLE_GH_MIRROR=1 / --no-mirror  完全关闭
GH_MIRRORS_DEFAULT="https://gh-proxy.com https://ghfast.top"
GH_MIN_SPEED="${GH_MIN_SPEED:-1024}"   # 低于 1 KB/s …
GH_STALL_SECS="${GH_STALL_SECS:-10}"    # …持续 10 秒就放弃这次传输
GH_CONNECT_SECS="${GH_CONNECT_SECS:-6}"  # 连接超时（直连不通时别在这儿磨"时间）

# Miniforge 的官方地址在 github.com/latest/download：国内实测 13 KB/s，128 MB 要下
# 一个多小时，看着就像卡死。清华 / 北外 / 南大用 tunasync 把 conda-forge/miniforge
# 的 release 完整同步到国内（同一文件名），实测 10 MB/s 以上，且 sha256 与官方一致。
# 这几个排在 GitHub 之前尝试；--no-mirror 时只用官方地址。
CONDA_MIRRORS_DEFAULT="https://mirrors.bfsu.edu.cn/github-release/conda-forge/miniforge/LatestRelease
https://mirrors.tuna.tsinghua.edu.cn/github-release/conda-forge/miniforge/LatestRelease
https://mirror.nju.edu.cn/github-release/conda-forge/miniforge/LatestRelease"

# 兜底版本：GitHub API 取不到 latest 时用（release 资产名里带版本号）。
GH_CLI_FALLBACK_VERSION="2.103.3"
GLAB_FALLBACK_VERSION="1.126.0"

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

# ------------------------------------------------------- github mirrors ----

gh_mirror_list() { # 一行一个可用镜像前缀
  ((MIRROR)) || return 0
  ((${DISABLE_GH_MIRROR:-0})) && return 0
  if [[ -n "${GH_MIRROR:-}" ]]; then
    printf '%s\n' "$GH_MIRROR"
    return 0
  fi
  local m
  for m in ${GH_MIRRORS:-$GH_MIRRORS_DEFAULT}; do printf '%s\n' "$m"; done
}

is_github_url() {
  case "$1" in
    https://github.com/*|https://api.github.com/*|https://raw.githubusercontent.com/*) return 0 ;;
  esac
  return 1
}

mirror_name() { printf '%s' "${1#*://}" | cut -d/ -f1; }

# 带"卡死保护"的 curl。比 connect-timeout 关键得多的是 speed-limit：
# 连接早建好了只是不给数据时，只有它能在有限时间内做判断。
# 不重试：外层还有镜像链，在死链上重试只是把失败时间乘 3。
curl_stall() { # url out
  local url="$1" out="$2"
  local -a quiet=(-fsSL)
  # 下载动辄几十 MB：接在终端上时给进度条，否则用户会以为卡死了。
  [[ -t 2 ]] && quiet=(-fL --progress-bar)
  curl "${quiet[@]}" --retry 0 --connect-timeout "$GH_CONNECT_SECS" \
    --speed-limit "$GH_MIN_SPEED" --speed-time "$GH_STALL_SECS" -o "$out" "$url"
}

# 直连 → 各镜像（仅对 GitHub 域名），成功返回 0。
# GH_MIRROR_FIRST=1 时把镜像排在前面：国内直连 GitHub 往往只是 6 秒白等。
_fetch_candidate() { # url out label
  local url="$1" out="$2" label="$3"
  [[ "$label" == direct ]] || info "改用镜像 ${label}"
  rm -f "$out"
  curl_stall "$url" "$out"
}

fetch_with_mirrors() { # url out
  local url="$1" out="$2" m
  local -a mirrors=()
  if is_github_url "$url"; then
    while read -r m; do
      [[ -n "$m" ]] || continue
      mirrors+=("$m")
    done < <(gh_mirror_list)
  fi

  if ((${#mirrors[@]})) && ((${GH_MIRROR_FIRST:-0})); then
    for m in "${mirrors[@]}"; do
      _fetch_candidate "${m%/}/${url}" "$out" "$(mirror_name "$m")" && return 0
    done
    _fetch_candidate "$url" "$out" direct
    return $?
  fi

  _fetch_candidate "$url" "$out" direct && return 0
  if ((${#mirrors[@]})); then
    for m in "${mirrors[@]}"; do
      _fetch_candidate "${m%/}/${url}" "$out" "$(mirror_name "$m")" && return 0
    done
  fi
  return 1
}

download() {
  local url="$1" out="$2" m t0 size
  if ((DRY_RUN)); then
    printf '%s    [dry-run]%s download %s\n' "$C_DIM" "$C_RESET" "$url"
    return 0
  fi
  t0=$SECONDS
  if have curl; then
    fetch_with_mirrors "$url" "$out" || { err "download failed: $url"; return 1; }
  elif have wget; then
    rm -f "$out"
    wget -q -O "$out" "$url" && return 0
    rm -f "$out"
    is_github_url "$url" || { err "download failed: $url"; return 1; }
    while read -r m; do
      [[ -n "$m" ]] || continue
      info "直连失败，改用镜像 $(mirror_name "$m")"
      wget -q -O "$out" "${m%/}/${url}" && break
      rm -f "$out"
    done < <(gh_mirror_list)
    [[ -s "$out" ]] || { err "download failed: $url"; return 1; }
  else
    err "neither curl nor wget is available"
    return 1
  fi
  size="$(wc -c <"$out" 2>/dev/null || echo 0)"
  local secs=$((SECONDS - t0))
  ((secs > 0)) || secs=1
  info "$(basename "$out") 已下载 ${size} 字节 / ${secs}s ($((size / secs / 1024)) KB/s)"
}

# GitHub API 文本（releases/latest 之类）。api.github.com 直连常年 403/超时，
# 同样走一遍镜像；只接受看起来像 release JSON 的响应，避免把错误页当成数据。
curl_api_text() { # url -> JSON on stdout
  local url="$1" m body
  if body="$(curl -fsSL --connect-timeout "$GH_CONNECT_SECS" --speed-limit "$GH_MIN_SPEED" \
    --speed-time "$GH_STALL_SECS" "$url" 2>/dev/null)" &&
    [[ "$body" == *browser_download_url* ]]; then
    printf '%s' "$body"
    return 0
  fi
  is_github_url "$url" || return 1
  while read -r m; do
    [[ -n "$m" ]] || continue
    if body="$(curl -fsSL --connect-timeout "$GH_CONNECT_SECS" --speed-limit "$GH_MIN_SPEED" \
      --speed-time "$GH_STALL_SECS" "${m%/}/${url}" 2>/dev/null)" &&
      [[ "$body" == *browser_download_url* ]]; then
      printf '%s' "$body"
      return 0
    fi
  done < <(gh_mirror_list)
  return 1
}

# 纯文本抓取（sha256、GitLab release API 之类）。这些地址国内可直连，
# 所以不走镜像链，但同样用连接超时兜住不通的情况。
fetch_text() { # url -> body on stdout
  local url="$1"
  if have curl; then
    curl -fsSL --connect-timeout "$GH_CONNECT_SECS" --max-time 60 "$url"
  elif have wget; then
    wget -q -O - "$url"
  else
    return 1
  fi
}

# 尽力而为的校验：拿不到 sha256 就跳过（镜像站偶尔缺 .sha256），
# 拿到了就必须匹配 —— 一个 128 MB 的安装脚本装到一半才发现坏了更糟。
verify_sha256() { # file sumurl
  local file="$1" sumurl="$2" want got
  [[ -n "$sumurl" ]] || return 0
  have sha256sum || have shasum || return 0
  want="$(fetch_text "$sumurl" 2>/dev/null | grep -oE '[0-9a-fA-F]{64}' | head -n1)" || true
  [[ ${#want} -eq 64 ]] || { info "跳过 sha256 校验（拿不到校验文件）"; return 0; }
  if have sha256sum; then
    got="$(sha256sum "$file" | cut -d' ' -f1)"
  else
    got="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  fi
  got="$(printf '%s' "$got" | tr '[:upper:]' '[:lower:]')"
  want="$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')"
  if [[ "$got" == "$want" ]]; then
    info "sha256 校验通过"
    return 0
  fi
  err "sha256 不匹配：期望 ${want}，实际 ${got}"
  return 1
}

github_asset() {
  local repo="$1" pattern="$2" json
  ((DRY_RUN)) && return 0
  json="$(curl_api_text "https://api.github.com/repos/${repo}/releases/latest")" || return 1
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

  # 先国内镜像（快两个数量级），再回落到 GitHub + GH 代理链。
  ((DRY_RUN)) && { info "would download ${name} from cn mirror (fallback: github) and run it"; return 0; }

  local -a candidates=()
  local m
  if ((MIRROR)); then
    while read -r m; do
      [[ -n "$m" ]] || continue
      candidates+=("${m%/}/${name}")
    done <<<"${CONDA_MIRRORS:-$CONDA_MIRRORS_DEFAULT}"
  fi
  candidates+=("$url")

  local got=0
  for m in "${candidates[@]}"; do
    info "尝试 $(printf '%s' "$m" | cut -d/ -f3)"
    if download "$m" "$tmp" && [[ -s "$tmp" ]] &&
       verify_sha256 "$tmp" "${m}.sha256"; then
      got=1
      break
    fi
    rm -f "$tmp"
  done
  if ((got == 0)); then
    warn "miniforge download failed"
    info "手动下载 ${name} 后运行: sh ${name} -b -p ${CONDA_PREFIX}"
    return 1
  fi
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

# ------------------------------------------------------------ vcs clients ----
# gh 与 glab 都是单文件 Go 二进制，官方 release 里有静态链接的 tar.gz，
# 直接摆进 BIN_DIR 即可，不依赖发行版仓库（apt 里 Ubuntu 22.04+ 才有 gh，glab 基本没有）。
# 两者都不需要 root，和 install-fast 的用户态风格一致。

# release 资产名里的架构标记：amd64 / arm64
arch_deb() {
  case "$(uname -m)" in
    x86_64|amd64)   printf 'amd64' ;;
    aarch64|arm64)  printf 'arm64' ;;
    armv7l|armv6l)  printf 'armv6' ;;
    i386|i686)      printf '386' ;;
    *)              printf 'amd64' ;;
  esac
}

install_gh_binary() {
  if have gh; then info "gh already installed ($(gh --version 2>/dev/null | head -n1))"; return 0; fi
  local os arch url
  os="$(uname -s)"; arch="$(arch_deb)"
  if [[ "$os" == Darwin ]]; then
    if ((CAN_SYSTEM)) && [[ "$PKG_MGR" == brew ]]; then
      pkg_install gh
    else
      warn "install gh with: brew install gh"
    fi
    return 0
  fi
  [[ "$os" == Linux ]] || { warn "unsupported OS for gh"; return 1; }

  log "installing gh (GitHub CLI)"
  url="$(github_asset cli/cli "gh_.*_linux_${arch}\.tar\.gz")"
  if [[ -z "$url" ]]; then
    url="https://github.com/cli/cli/releases/download/v${GH_CLI_FALLBACK_VERSION}/gh_${GH_CLI_FALLBACK_VERSION}_linux_${arch}.tar.gz"
    info "release API 不可用，回落到 v${GH_CLI_FALLBACK_VERSION}"
  fi
  # 实测：直连 github.com 约 13 KB/s，gh-proxy 约 90 KB/s → 镜像优先。
  if ! GH_MIRROR_FIRST=1 install_tarball_bin "$url" "gh" "gh"; then
    warn "gh install failed; 手动装: sudo apt-get install -y gh 或 https://github.com/cli/cli/releases"
    return 1
  fi
}

install_glab_binary() {
  if have glab; then info "glab already installed ($(glab --version 2>/dev/null | head -n1))"; return 0; fi
  local os arch url json
  os="$(uname -s)"; arch="$(arch_deb)"
  if [[ "$os" == Darwin ]]; then
    if ((CAN_SYSTEM)) && [[ "$PKG_MGR" == brew ]]; then
      pkg_install glab
    else
      warn "install glab with: brew install glab"
    fi
    return 0
  fi
  [[ "$os" == Linux ]] || { warn "unsupported OS for glab"; return 1; }

  log "installing glab (GitLab CLI)"
  # glab 的源码仓库在 gitlab.com（GitHub 上的 gitlab-org/cli 已 404），
  # 所以不走 GitHub 镜像链；gitlab.com 国内直连可用（实测 ~190 KB/s）。
  url=""
  json="$(fetch_text 'https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases?per_page=1' 2>/dev/null)" || true
  if [[ -n "$json" ]]; then
    url="$(printf '%s' "$json" |
      grep -oE "https://gitlab\\.com/[^\"\\\\]*glab_[0-9.]+_linux_${arch}\\.tar\\.gz" | head -n1)" || true
  fi
  if [[ -z "$url" ]]; then
    url="https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_FALLBACK_VERSION}/downloads/glab_${GLAB_FALLBACK_VERSION}_linux_${arch}.tar.gz"
    info "release API 不可用，回落到 v${GLAB_FALLBACK_VERSION}"
  fi
  if ! install_tarball_bin "$url" "glab" "glab"; then
    warn "glab install failed; 手动装: https://gitlab.com/gitlab-org/cli/-/releases"
    return 1
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

do_vcs() {
  log "version control CLIs (gh / glab)"
  install_gh_binary
  install_glab_binary
  if have gh || have glab; then
    info "登录（只需一次）：gh auth login  /  glab auth login"
  fi
}

do_qgpu() {
  log "qGPU job queue (qgpu)"
  if [[ "$MODE" == "root" ]]; then
    warn "qGPU keeps per-user state; run ./install-fast/install-user.sh --only qgpu"
    return 0
  fi
  local installer="${QGPU_SRC}/install.sh"
  if [[ ! -f "$installer" ]]; then
    warn "qgpu/install.sh not found under ${QGPU_SRC}"
    return 0
  fi
  local -a flags=(--bin-dir "$BIN_DIR")
  ((DRY_RUN)) && flags+=(--dry-run)
  if ! bash "$installer" "${flags[@]}"; then
    warn "qgpu installer failed (python3 is required); re-run: bash ${installer}"
    return 0
  fi
}

do_monitor() {
  log "node monitor (monitor)"
  if [[ "$MODE" == "root" ]]; then
    warn "the node monitor writes per-user history and a user crontab; run ./install-fast/install-user.sh --only monitor"
    return 0
  fi
  local installer="${MONITOR_SRC}/install.sh"
  if [[ ! -f "$installer" ]]; then
    warn "monitor/install.sh not found under ${MONITOR_SRC}"
    return 0
  fi
  local -a flags=(--prefix "$HOME/gpu-monitor")
  ((DRY_RUN)) && flags+=(--dry-run)
  if ! bash "$installer" "${flags[@]}"; then
    warn "monitor installer failed (python3 is required); re-run: bash ${installer}"
    return 0
  fi
  info "cron lines are printed above; re-run with --cron to add them: bash ${installer} --cron"
}

list_groups() {
  cat <<EOF
Groups:
  base    git curl wget unzip zip ca-certificates jq
  cli     tree ripgrep(rg) fd fzf tmux htop
  dev     g++/build-essential make gdb cmake ninja pkg-config
  python  uv + conda (Miniforge, includes mamba)
  vcs     gh (GitHub CLI) + glab (GitLab CLI), installed into BIN_DIR
  qgpu    qGPU per-user GPU job queue CLI (needs python3 + nvidia-smi)
  monitor cron-driven node monitor + local dashboard (needs python3)
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
  local -a tools=(git curl wget jq tree rg fd fzf tmux htop g++ make cmake uv conda gh glab)
  # qgpu installs into the user prefix only; root mode skips it, so do not report it missing.
  [[ "$MODE" == "root" ]] || tools+=(qgpu)
  for t in "${tools[@]}"; do
    if path="$(tool_path "$t")"; then
      printf '  %s%-6s%s %s\n' "$C_GREEN" "$t" "$C_RESET" "$path"
    else
      printf '  %s%-6s%s not found\n' "$C_DIM" "$t" "$C_RESET"
    fi
  done
  # The monitor is a cron-driven collector, not a PATH tool: report its home.
  if [[ "$MODE" != "root" && -x "${HOME}/gpu-monitor/collect.sh" ]]; then
    printf '  %s%-6s%s %s\n' "$C_GREEN" "monitor" "$C_RESET" "${HOME}/gpu-monitor"
  fi
}

# ------------------------------------------------------------------- main ----

usage() {
  local prog="$1"
  cat <<EOF
Usage: ${prog} [options]

One-shot installer for a fresh dev/GPU server. Idempotent: safe to re-run.

Options:
      --only GROUPS     Comma list: base,cli,dev,python,vcs,qgpu,monitor (default: all)
      --skip GROUPS     Remove groups from the default set
      --dry-run         Print actions without changing anything
      --no-mirror       Do not use China mirrors (pip/uv/conda/HF and GitHub)

Environment:
      GH_MIRROR=PREFIX  Use one GitHub mirror prefix (e.g. https://gh-proxy.com)
      GH_MIRRORS="A B"  Try these GitHub mirror prefixes in order
      DISABLE_GH_MIRROR=1  Never fall back to GitHub mirrors
      GH_MIRROR_FIRST=1    Try the GitHub mirrors before the direct URL
      GH_STALL_SECS=10  Abort a transfer that stays below 1 KB/s for N seconds
      GH_CONNECT_SECS=6 Connect timeout per download attempt
      CONDA_MIRRORS="A B"  Miniforge mirrors tried before GitHub
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
      base|cli|dev|python|vcs|qgpu|monitor) "do_$g" ;;
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
