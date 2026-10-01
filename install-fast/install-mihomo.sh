#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034

# One-click installer for mihomo (Clash Meta) on Linux and macOS.
# Downloads the release binary, sets up a config directory, a control script
# (mihomoctl) and a shell proxy environment (proxy-env.sh).
# No root required; use MODE=root (via install-root.sh style) for a system dir.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${MODE:-user}"

# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

MIHOMO_REPO="MetaCubeX/mihomo"
MIXED_PORT="17890"
CONTROLLER_PORT="19090"
WITH_SERVICE=0
START_AFTER=0
FORCE_CONFIG=0
CONFIG_URL=""
PIN_VERSION=""
PROXY_URL="${https_proxy:-${HTTPS_PROXY:-}}"

case "$MODE" in
  root) DEFAULT_DIR="/etc/mihomo" ;;
  *)    DEFAULT_DIR="${HOME}/Mihomo" ;;
esac
MIHOMO_DIR="$DEFAULT_DIR"

usage() {
  local prog="$1"
  cat <<EOF
Usage: ${prog} [options]

Install mihomo (Clash Meta) into a config directory with a control script.

Options:
      --dir PATH            Install directory (default: ${DEFAULT_DIR})
      --port PORT           Mixed HTTP/SOCKS port (default: ${MIXED_PORT})
      --controller-port P   External controller port (default: ${CONTROLLER_PORT})
      --config-url URL      Download a subscription config into config.yaml
      --force-config        Overwrite an existing config.yaml
      --version vX.Y.Z      Pin a release tag (default: latest)
      --proxy URL           HTTP(S) proxy for downloads (e.g. http://127.0.0.1:17890)
      --with-service        Install a systemd unit and enable it
      --start               Start mihomo after installing
      --dry-run             Print actions without changing anything
      --no-color            Disable ANSI colors
  -h, --help                Show this help

After install:
  source ${DEFAULT_DIR}/proxy-env.sh      # export HTTP(S)_PROXY in this shell
  ${DEFAULT_DIR}/mihomoctl start          # start/stop/status/restart
EOF
}

need() { have "$1" || die "required command not found: $1"; }

# --------------------------------------------------------------- download -----

curl_dl() {
  local url="$1" out="$2" args=(-fL --retry 3 --connect-timeout 15)
  [[ -n "$PROXY_URL" ]] && args+=(--proxy "$PROXY_URL")
  if ((DRY_RUN)); then
    printf '%s    [dry-run]%s download %s\n' "$C_DIM" "$C_RESET" "$url"
    return 0
  fi
  curl "${args[@]}" -o "$out" "$url"
}

latest_tag() {
  local args=(-sSI --max-time 20)
  [[ -n "$PROXY_URL" ]] && args+=(--proxy "$PROXY_URL")
  curl "${args[@]}" "https://github.com/${MIHOMO_REPO}/releases/latest" 2>/dev/null |
    tr -d '\r' | awk -F'/tag/' '/^[Ll]ocation:/{print $2}'
}

detect_target() {
  case "$(uname -s):$(uname -m)" in
    Linux:x86_64|Linux:amd64)   TARGET_OS="linux";  TARGET_ARCH="amd64" ;;
    Linux:aarch64|Linux:arm64)  TARGET_OS="linux";  TARGET_ARCH="arm64" ;;
    Linux:armv7l|Linux:armv7)   TARGET_OS="linux";  TARGET_ARCH="armv7" ;;
    Darwin:x86_64)              TARGET_OS="darwin"; TARGET_ARCH="amd64" ;;
    Darwin:arm64|Darwin:aarch64) TARGET_OS="darwin"; TARGET_ARCH="arm64" ;;
    *) die "unsupported platform: $(uname -s)/$(uname -m)" ;;
  esac
}

# ---------------------------------------------------------------- runtime -----

write_proxy_env() {
  local file="${MIHOMO_DIR}/proxy-env.sh"
  [[ -f "$file" ]] && { info "keeping existing $(basename "$file")"; return; }
  log "writing proxy-env.sh"
  ((DRY_RUN)) && return 0
  cat > "$file" <<EOF
# mihomo proxy environment. Usage: source proxy-env.sh
export HTTP_PROXY="http://127.0.0.1:${MIXED_PORT}"
export HTTPS_PROXY="http://127.0.0.1:${MIXED_PORT}"
export ALL_PROXY="http://127.0.0.1:${MIXED_PORT}"
export http_proxy="\$HTTP_PROXY"
export https_proxy="\$HTTPS_PROXY"
export all_proxy="\$ALL_PROXY"
export NO_PROXY="localhost,127.0.0.1,::1"
export no_proxy="\$NO_PROXY"
EOF
  chmod 0644 "$file"
}

write_mihomoctl() {
  local file="${MIHOMO_DIR}/mihomoctl"
  log "writing mihomoctl"
  ((DRY_RUN)) && return 0
  cat > "$file" <<'EOF'
#!/usr/bin/env bash
# Control script for the mihomo instance in this directory.
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$DIR/mihomo"
PIDFILE="$DIR/mihomo.pid"
LOGFILE="$DIR/mihomo.log"
umask 077

running() {
  [[ -f "$PIDFILE" ]] || return 1
  local pid
  read -r pid < "$PIDFILE"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

start() {
  if running; then echo "mihomo running (pid $(cat "$PIDFILE"))"; return 0; fi
  if ! "$BIN" -t -d "$DIR" >/dev/null 2>&1; then
    echo "config test failed:"; "$BIN" -t -d "$DIR"; return 1
  fi
  nohup "$BIN" -d "$DIR" >>"$LOGFILE" 2>&1 </dev/null &
  echo $! > "$PIDFILE"
  sleep 1
  running || { echo "start failed: see $LOGFILE"; return 1; }
  echo "mihomo started (pid $(cat "$PIDFILE"))"
}

stop() {
  if running; then
    local pid
    read -r pid < "$PIDFILE"
    kill "$pid"
    for _ in $(seq 1 50); do running || break; sleep 0.1; done
    running && { echo "mihomo still stopping"; return 1; }
  fi
  rm -f "$PIDFILE"
  echo "mihomo stopped"
}

case "${1:-status}" in
  start)   start ;;
  stop)    stop ;;
  restart) stop; start ;;
  status)  if running; then echo "mihomo running (pid $(cat "$PIDFILE"))"; else echo "mihomo stopped"; exit 1; fi ;;
  *)       echo "Usage: $0 {start|stop|restart|status}"; exit 2 ;;
esac
EOF
  chmod 0755 "$file"
}

write_config_template() {
  local file="${MIHOMO_DIR}/config.yaml"
  if [[ -f "$file" && "$FORCE_CONFIG" -eq 0 && -z "$CONFIG_URL" ]]; then
    info "keeping existing config.yaml"
    return
  fi
  if [[ -n "$CONFIG_URL" ]]; then
    log "downloading config from subscription URL"
    curl_dl "$CONFIG_URL" "$file" || { warn "config download failed"; return 1; }
    chmod 0600 "$file"
    return
  fi
  log "writing minimal config.yaml template"
  ((DRY_RUN)) && return 0
  cat > "$file" <<EOF
# mihomo config. Fill in proxies / proxy-groups / rules, or replace this file
# with your subscription config (or re-run with --config-url URL).
mixed-port: ${MIXED_PORT}
allow-lan: false
bind-address: 127.0.0.1
external-controller: 127.0.0.1:${CONTROLLER_PORT}
mode: rule
log-level: info
proxies: []
proxy-groups: []
rules:
  - MATCH,DIRECT
EOF
  chmod 0600 "$file"
}

write_service() {
  ((WITH_SERVICE)) || return 0
  local unit
  if [[ "$MODE" == root ]]; then
    unit="/etc/systemd/system/mihomo.service"
  else
    unit="${HOME}/.config/systemd/user/mihomo.service"
  fi
  log "writing systemd unit: $unit"
  ((DRY_RUN)) && return 0
  [[ "$MODE" == root ]] || mkdir -p "${HOME}/.config/systemd/user"
  cat > "$unit" <<EOF
[Unit]
Description=mihomo (Clash Meta) proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${MIHOMO_DIR}/mihomo -d ${MIHOMO_DIR}
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=$([[ "$MODE" == root ]] && echo multi-user.target || echo default.target)
EOF
  if [[ "$MODE" == root ]]; then
    run systemctl daemon-reload
    run systemctl enable mihomo
  elif have systemctl; then
    run systemctl --user daemon-reload
    run systemctl --user enable mihomo
  fi
}

# ------------------------------------------------------------------ main ------

main() {
  local prog="${0##*/}" arg
  local -a argv=("$@")
  local i=0
  while ((i < ${#argv[@]})); do
    arg="${argv[$i]}"
    case "$arg" in
      --dir)              ((i + 1 < ${#argv[@]})) || die "--dir requires a path"; MIHOMO_DIR="${argv[$((i + 1))]}"; ((i++)) ;;
      --port)             ((i + 1 < ${#argv[@]})) || die "--port requires a value"; MIXED_PORT="${argv[$((i + 1))]}"; ((i++)) ;;
      --controller-port)  ((i + 1 < ${#argv[@]})) || die "--controller-port requires a value"; CONTROLLER_PORT="${argv[$((i + 1))]}"; ((i++)) ;;
      --config-url)       ((i + 1 < ${#argv[@]})) || die "--config-url requires a URL"; CONFIG_URL="${argv[$((i + 1))]}"; ((i++)) ;;
      --proxy)            ((i + 1 < ${#argv[@]})) || die "--proxy requires a URL"; PROXY_URL="${argv[$((i + 1))]}"; ((i++)) ;;
      --version)          ((i + 1 < ${#argv[@]})) || die "--version requires a tag"; PIN_VERSION="${argv[$((i + 1))]}"; ((i++)) ;;
      --force-config)     FORCE_CONFIG=1 ;;
      --with-service)     WITH_SERVICE=1 ;;
      --start)            START_AFTER=1 ;;
      --dry-run)          DRY_RUN=1 ;;
      --no-color)         DISABLE_COLOR=1 ;;
      -h|--help)          setup_colors; usage "$prog"; exit 0 ;;
      *)                  die "unknown option: ${arg} (try --help)" ;;
    esac
    ((i++))
  done
  setup_colors

  need curl
  have gzip || die "gzip is required to unpack the mihomo binary"
  detect_target

  local tag asset url
  if [[ -n "$PIN_VERSION" ]]; then
    tag="$PIN_VERSION"
  else
    tag="$(latest_tag)"
    [[ -n "$tag" ]] || die "could not resolve the latest release (network?); pass --version vX.Y.Z or --proxy URL"
  fi
  asset="mihomo-${TARGET_OS}-${TARGET_ARCH}-${tag}.gz"
  url="https://github.com/${MIHOMO_REPO}/releases/download/${tag}/${asset}"

  printf '%s%smihomo installer%s (%s mode)\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$MODE"
  info "target : ${TARGET_OS}/${TARGET_ARCH}"
  info "release: ${tag}"
  info "dir    : ${MIHOMO_DIR}"
  info "port   : ${MIXED_PORT} (controller ${CONTROLLER_PORT})"
  ((DRY_RUN)) && info "dry-run: no changes will be made"

  ((DRY_RUN)) || mkdir -p "$MIHOMO_DIR"
  chmod 0700 "$MIHOMO_DIR" 2>/dev/null || true

  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT

  log "downloading mihomo ${tag} (${asset})"
  if ! curl_dl "$url" "$tmp/mihomo.gz"; then
    rm -rf "$tmp"
    die "download failed: $url"
  fi
  if ((DRY_RUN)); then
    info "[dry-run] would install ${MIHOMO_DIR}/mihomo"
  else
    gzip -dc "$tmp/mihomo.gz" > "$tmp/mihomo" || die "failed to unpack mihomo"
    install -m 0755 "$tmp/mihomo" "${MIHOMO_DIR}/mihomo"
    log "installed ${MIHOMO_DIR}/mihomo ($("${MIHOMO_DIR}/mihomo" -v 2>/dev/null | head -1))"
  fi
  rm -rf "$tmp"
  trap - EXIT

  write_config_template
  write_proxy_env
  write_mihomoctl
  write_service

  if ((START_AFTER)); then
    if ((DRY_RUN)); then
      info "[dry-run] would run mihomoctl start"
    else
      "${MIHOMO_DIR}/mihomoctl" start || warn "mihomo did not start; check config.yaml"
    fi
  fi

  printf '\n%sDone.%s ' "$C_GREEN" "$C_RESET"
  printf 'Next:\n  source %s/proxy-env.sh\n  %s/mihomoctl start\n' "$MIHOMO_DIR" "$MIHOMO_DIR"
  printf 'For git over this proxy:\n  git config --global http.https://github.com/.proxy http://127.0.0.1:%s\n' "$MIXED_PORT"
}

main "$@"