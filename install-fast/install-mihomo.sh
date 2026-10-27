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
#
# start only reports success once the proxy is really listening: it watches the
# new lines of mihomo.log for bind errors, the process itself (zombies count as
# dead) and, when ss/lsof/netstat exist, the mixed-port from config.yaml.
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$DIR/mihomo"
PIDFILE="$DIR/mihomo.pid"
LOGFILE="$DIR/mihomo.log"
CONFIG="$DIR/config.yaml"
# Filled in by port_listening: listening | down | unknown (no probe tool).
PORT_STATE="unknown"
umask 077

have() { command -v "$1" >/dev/null 2>&1; }

# alive PID: the process exists and is not an unreaped zombie.
alive() {
  local pid="$1" state
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  if have ps; then
    state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')"
    case "$state" in
      ''|Z*) return 1 ;;
    esac
  fi
  return 0
}

running() {
  local pid
  [[ -f "$PIDFILE" ]] || return 1
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  alive "$pid"
}

# Mixed port declared in config.yaml; empty when absent or not a plain number.
config_port() {
  local line
  [[ -f "$CONFIG" ]] || return 0
  line="$(grep -E '^[[:space:]]*mixed-port:[[:space:]]*[0-9]+' "$CONFIG" 2>/dev/null | head -n 1 || true)"
  [[ -n "$line" ]] || return 0
  line="$(printf '%s' "${line##*:}" | tr -dc '0-9')"
  case "$line" in
    *[1-9]*) printf '%s\n' "$line" ;;
  esac
  return 0
}

# Local listening addresses, one per line, when any port tool exists.
listen_addrs() {
  if have ss; then
    ss -ltn 2>/dev/null | awk 'NR > 1 { print $4 }'
  elif have lsof; then
    lsof -nP -iTCP -sTCP:LISTEN -F n 2>/dev/null | sed -n 's/^n//p'
  elif have netstat; then
    netstat -an 2>/dev/null | awk '$NF == "LISTEN" { print $4 }'
  else
    return 2
  fi
}

# port_busy PORT: 0 when something already listens on PORT on loopback or on
# every address, which is what a mixed-port bind would collide with.
port_busy() {
  local port="$1" addrs
  case "$port" in ''|*[!0-9]*) return 1 ;; esac
  addrs="$(listen_addrs)" || return 1
  [[ -n "$addrs" ]] || return 1
  printf '%s\n' "$addrs" | awk -v p="$port" '
    {
      n = split($1, a, /[.:]/)
      if (a[n] != p) next
      addr = substr($1, 1, length($1) - length(a[n]) - 1)
      if (addr == "*" || addr == "" || addr == "0.0.0.0" || addr == "::" ||
          addr == "[::]" || addr == "[::1]" || addr ~ /^127\./) found = 1
    }
    END { exit found ? 0 : 1 }'
}

# port_listening PORT: 0 = listening, 1 = not listening, 2 = no probe tool.
port_listening() {
  local port="$1" out
  PORT_STATE="unknown"
  case "$port" in ''|*[!0-9]*) return 2 ;; esac
  if have ss && out="$(ss -ltn 2>/dev/null)"; then
    if printf '%s\n' "$out" |
      awk -v p="$port" '{ n = split($4, a, ":"); if (a[n] == p) found = 1 } END { exit found ? 0 : 1 }'; then
      PORT_STATE="listening"
      return 0
    fi
    PORT_STATE="down"
    return 1
  fi
  if have lsof; then
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      PORT_STATE="listening"
      return 0
    fi
    PORT_STATE="down"
    return 1
  fi
  if have netstat; then
    if netstat -an 2>/dev/null | grep -E "[.:]${port}[[:space:]].*LISTEN" >/dev/null 2>&1; then
      PORT_STATE="listening"
      return 0
    fi
    PORT_STATE="down"
    return 1
  fi
  return 2
}

log_offset() {
  if [[ -f "$LOGFILE" ]]; then
    wc -l < "$LOGFILE" | tr -dc '0-9'
  else
    printf '0'
  fi
}

log_since() {
  local from="${1:-0}"
  [[ -f "$LOGFILE" ]] || return 0
  tail -n "+$((from + 1))" "$LOGFILE" 2>/dev/null || true
}

# Newest bind/startup error line written after offset OFF; fails when none.
# Controller-only bind errors are ignored: they do not stop the proxy.
log_error_since() {
  local from="${1:-0}" text
  text="$(log_since "$from" |
    grep -E 'address already in use|bind: |permission denied|cannot assign requested address' |
    grep -v -i 'controller' |
    tail -n 1 || true)"
  [[ -n "$text" ]] || return 1
  printf '%s\n' "$text"
}

port_hint() {
  local port="$1"
  if [[ -n "$port" ]]; then
    printf 'stop the process using 127.0.0.1:%s, or re-run install-mihomo.sh with a different --port' "$port"
  else
    printf 'stop the process already using the proxy port, or re-run install-mihomo.sh with a different --port'
  fi
}

# Reap a half-dead instance, drop the pidfile and report the failure on stderr.
start_failed() {
  local pid="$1" detail="$2" hint="$3" i=0
  if [[ -n "$pid" ]]; then
    if alive "$pid"; then
      kill "$pid" 2>/dev/null || true
      while alive "$pid" && ((i < 20)); do
        sleep 0.1
        i=$((i + 1))
      done
      if alive "$pid"; then kill -9 "$pid" 2>/dev/null || true; fi
    fi
    wait "$pid" 2>/dev/null || true
  fi
  rm -f "$PIDFILE"
  {
    printf 'mihomo start FAILED: %s\n' "$detail"
    printf '  log:  %s\n' "$LOGFILE"
    printf '  hint: %s\n' "$hint"
  } >&2
  return 1
}

start() {
  local port pid offset n wait_s deadline errline
  if running; then
    echo "mihomo already running (pid $(cat "$PIDFILE"))"
    return 0
  fi
  rm -f "$PIDFILE"
  if ! "$BIN" -t -d "$DIR" >/dev/null 2>&1; then
    { echo "mihomo start FAILED: config test failed"; "$BIN" -t -d "$DIR"; } >&2
    return 1
  fi
  port="$(config_port)"
  if [[ -n "$port" ]] && port_busy "$port"; then
    start_failed "" "port ${port} is already in use by another process" "$(port_hint "$port")"
    return 1
  fi
  offset="$(log_offset)"
  nohup "$BIN" -d "$DIR" >>"$LOGFILE" 2>&1 </dev/null &
  pid=$!
  echo "$pid" > "$PIDFILE"
  # Wall-clock bound: ~3s to come up when the port is known, 1s otherwise.
  wait_s=1
  if [[ -n "$port" ]]; then wait_s=3; fi
  deadline=$(( $(date +%s) + wait_s ))
  n=0
  while ((n < 100)) && (( $(date +%s) < deadline )); do
    if errline="$(log_error_since "$offset")"; then
      start_failed "$pid" "the proxy failed to bind: ${errline}" "$(port_hint "$port")"
      return 1
    fi
    if ! alive "$pid"; then
      if errline="$(log_error_since "$offset")"; then
        start_failed "$pid" "the proxy failed to bind: ${errline}" "$(port_hint "$port")"
      else
        errline="$(log_since "$offset" | grep -v '^[[:space:]]*$' | tail -n 1 || true)"
        start_failed "$pid" "mihomo exited during startup${errline:+ (last log line: ${errline})}" "check ${LOGFILE}, fix config.yaml and start again"
      fi
      return 1
    fi
    if [[ -n "$port" ]] && port_listening "$port"; then
      break
    fi
    n=$((n + 1))
    sleep 0.1
  done
  if [[ "$PORT_STATE" == "down" ]]; then
    start_failed "$pid" "mihomo is running (pid ${pid}) but nothing listens on port ${port}" "$(port_hint "$port")"
    return 1
  fi
  if ! alive "$pid"; then
    start_failed "$pid" "mihomo exited during startup" "check ${LOGFILE}, fix config.yaml and start again"
    return 1
  fi
  echo "mihomo started (pid ${pid}${port:+, 127.0.0.1:${port}})"
}

stop() {
  local pid
  if running; then
    pid="$(cat "$PIDFILE")"
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      alive "$pid" || break
      sleep 0.1
    done
    if alive "$pid"; then
      kill -9 "$pid" 2>/dev/null || true
      sleep 0.2
    fi
    if alive "$pid"; then echo "mihomo still stopping (pid ${pid})"; return 1; fi
    wait "$pid" 2>/dev/null || true
  fi
  rm -f "$PIDFILE"
  echo "mihomo stopped"
}

status() {
  local pid port i=0
  if ! running; then echo "mihomo stopped"; return 1; fi
  pid="$(cat "$PIDFILE")"
  port="$(config_port)"
  if [[ -n "$port" ]]; then
    while ((i < 10)); do
      if port_listening "$port"; then break; fi
      if [[ "$PORT_STATE" == "unknown" ]]; then break; fi
      i=$((i + 1))
      sleep 0.1
    done
    if [[ "$PORT_STATE" == "down" ]]; then
      echo "mihomo NOT working: pid ${pid} is alive but 127.0.0.1:${port} is not listening (see ${LOGFILE})" >&2
      return 1
    fi
    echo "mihomo running (pid ${pid}, 127.0.0.1:${port})"
    return 0
  fi
  echo "mihomo running (pid ${pid})"
}

case "${1:-status}" in
  start)   start ;;
  stop)    stop ;;
  restart) stop; start ;;
  status)  status ;;
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
      "${MIHOMO_DIR}/mihomoctl" start ||
        die "mihomo did not start; fix config.yaml or pick a free --port, then re-run: ${MIHOMO_DIR}/mihomoctl start"
    fi
  fi

  printf '\n%sDone.%s ' "$C_GREEN" "$C_RESET"
  printf 'Next:\n  source %s/proxy-env.sh\n  %s/mihomoctl start\n' "$MIHOMO_DIR" "$MIHOMO_DIR"
  printf 'For git over this proxy:\n  git config --global http.https://github.com/.proxy http://127.0.0.1:%s\n' "$MIXED_PORT"
}

main "$@"