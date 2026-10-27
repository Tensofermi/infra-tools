#!/usr/bin/env bash
#
# Install the node monitor into MONITOR_HOME (default ~/gpu-monitor).
#
#   ./install.sh [MACHINE_NAME] [--cron]
#
# Writes the programs, an env file and small wrappers; with --cron it also adds
# the two crontab lines if they are not already there. Nothing is started and no
# system file is touched.
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
machine=""
with_cron=0
dry_run=0
retention="${MONITOR_RETENTION_DAYS:-7}"
home_dir="${MONITOR_HOME:-$HOME/gpu-monitor}"
# The wrappers below re-source this file, so the path is baked in at install
# time: a custom MONITOR_HOME must not leave them reading ~/gpu-monitor/env.
env_file="$home_dir/env"

log()  { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '[skip] %s\n' "$*" >&2; }
die()  { printf '[error] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: install.sh [MACHINE_NAME] [options]

Install the collector, the archiver and the read-only dashboard into
\${MONITOR_HOME:-\$HOME/gpu-monitor}. Nothing is started automatically.

Options:
      --cron              also add the collect/archive crontab lines (idempotent)
      --prefix DIR        install root (default: \$MONITOR_HOME or ~/gpu-monitor)
      --retention DAYS    gzip samples older than DAYS (default: 7, 0 = off)
      --dry-run           print actions without changing anything
  -h, --help              show this help

Environment:
  MONITOR_HOME            same as --prefix
  MONITOR_RETENTION_DAYS  same as --retention

Examples:
  ./install.sh                          # machine name = hostname -s
  ./install.sh gpu-01 --cron            # collect every minute via cron
  ./install.sh gpu-01 --prefix /data/monitor --dry-run
EOF
}

while (($#)); do
  case "$1" in
    --cron)      with_cron=1 ;;
    --dry-run)   dry_run=1 ;;
    --prefix)
      (($# > 1)) || die "--prefix requires a value"
      home_dir="$2"; shift ;;
    --prefix=*)  home_dir="${1#*=}" ;;
    --retention)
      (($# > 1)) || die "--retention requires a value"
      retention="$2"; shift ;;
    --retention=*) retention="${1#*=}" ;;
    -h|--help)   usage; exit 0 ;;
    -*)          die "unknown option: $1 (try --help)" ;;
    *)
      [[ -z "$machine" ]] || die "unexpected argument: $1"
      machine="$1" ;;
  esac
  shift
done

home_dir="${home_dir/#\~/$HOME}"
env_file="$home_dir/env"
machine="${machine:-$(hostname -s)}"

run() {
  if ((dry_run)); then
    printf '    [dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

# Wrappers are written with an unquoted heredoc so the install path is baked in,
# while \$MONITOR_HOME / \$MONITOR_PORT stay runtime variables.
write_wrapper() {
  local path="$1"
  run mkdir -p "$(dirname "$path")"
  if ((dry_run)); then
    printf '    [dry-run] write %s\n' "$path"
    cat >/dev/null
    return 0
  fi
  cat >"$path"
  chmod 700 "$path"
}

log "installing the node monitor"
command -v python3 >/dev/null 2>&1 || die "python3 is required (standard library only)"
if ! command -v nvidia-smi >/dev/null 2>&1; then
  warn "nvidia-smi not found; GPU fields will be recorded as null until a driver is visible"
fi
info "python3  : $(command -v python3)"
info "machine  : $machine"
info "home dir : $home_dir"
info "retention: ${retention}d"
((dry_run)) && info "dry-run: no changes will be made"

run mkdir -p "$home_dir/bin" "$home_dir/data" "$home_dir/log"
for program in collect.py archive.py dashboard.py; do
  run install -m 700 "$SOURCE_DIR/bin/$program" "$home_dir/bin/$program"
done

if ((dry_run)); then
  printf '    [dry-run] write %s\n' "$env_file"
else
  cat >"$env_file" <<ENV
# Sourced by the wrappers below and by crontab entries.
export MONITOR_MACHINE="$machine"
export MONITOR_HOME="$home_dir"
export MONITOR_DATA_DIR="$home_dir/data"
export MONITOR_RETENTION_DAYS="$retention"
export MONITOR_HOST="127.0.0.1"
export MONITOR_PORT="8899"
ENV
  chmod 600 "$env_file"
fi

write_wrapper "$home_dir/collect.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
. "$env_file"
# One sample per minute; a slow run must not stack up behind the next one.
flock -n "\$MONITOR_HOME/collector.lock" "\$MONITOR_HOME/bin/collect.py"
SH

write_wrapper "$home_dir/archive.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
. "$env_file"
"\$MONITOR_HOME/bin/archive.py"
SH

write_wrapper "$home_dir/dashboard-start.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
. "$env_file"
if [[ -f "\$MONITOR_HOME/dashboard.pid" ]] && kill -0 "\$(cat "\$MONITOR_HOME/dashboard.pid")" 2>/dev/null; then
  echo "already running on \$MONITOR_HOST:\$MONITOR_PORT"
  exit 0
fi
"\$MONITOR_HOME/collect.sh" >/dev/null || true
nohup "\$MONITOR_HOME/bin/dashboard.py" > "\$MONITOR_HOME/log/dashboard.log" 2>&1 &
echo \$! > "\$MONITOR_HOME/dashboard.pid"
echo "started on http://\$MONITOR_HOST:\$MONITOR_PORT/"
SH

write_wrapper "$home_dir/dashboard-stop.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
. "$env_file"
if [[ -f "\$MONITOR_HOME/dashboard.pid" ]] && kill -0 "\$(cat "\$MONITOR_HOME/dashboard.pid")" 2>/dev/null; then
  kill "\$(cat "\$MONITOR_HOME/dashboard.pid")"
  rm -f "\$MONITOR_HOME/dashboard.pid"
  echo "stopped"
else
  echo "not running"
fi
SH

write_wrapper "$home_dir/status.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
. "$env_file"
if [[ -f "\$MONITOR_HOME/dashboard.pid" ]] && kill -0 "\$(cat "\$MONITOR_HOME/dashboard.pid")" 2>/dev/null; then
  echo "dashboard: running on http://\$MONITOR_HOST:\$MONITOR_PORT/"
else
  echo "dashboard: not running"
fi
latest="\$MONITOR_DATA_DIR/latest.json"
if [[ -f "\$latest" ]]; then
  python3 - "\$latest" <<'PY'
import json, sys
from datetime import datetime
from pathlib import Path
d = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
p, s = d["payload"], d["summary"]
print(f"machine  : {p['machine']}")
print(f"last sample: {p['collected_at']}")
print(f"status   : {s['status']}  gpus={s['gpu_count']}  util avg/peak={s['avg_util']}/{s['max_util']}%")
print(f"memory   : {s['mem_used_pct']}%  swap={s['swap_used_pct']}%  power={s['total_power_w']}W  maxtemp={s['max_temp_c']}C")
print(f"disk risk: {s['disk_risk'] or 'none'}")
PY
else
  echo "no sample yet: \$MONITOR_HOME/collect.sh"
fi
SH

printf '\n'
log "done"
info "files   : $home_dir/{bin,data,log}"
info "wrappers: collect.sh archive.sh dashboard-start.sh dashboard-stop.sh status.sh"

cron_lines=(
  "* * * * * $home_dir/collect.sh >> $home_dir/log/collect.log 2>&1"
  "10 0 * * * $home_dir/archive.sh >> $home_dir/log/archive.log 2>&1"
)

if ((with_cron)) && ((!dry_run)); then
  current="$(crontab -l 2>/dev/null || true)"
  # Older deployments of gpu-monitor used different wrapper names; say so
  # instead of letting both generations collect into the same data dir.
  for legacy in collect_once.sh archive_daily.sh start.sh; do
    if grep -qF "$home_dir/$legacy" <<<"$current"; then
      warn "crontab still runs $home_dir/$legacy (old gpu-monitor layout)"
      info "  remove that line with: crontab -e"
      break
    fi
  done
  added=0
  for line in "${cron_lines[@]}"; do
    if ! grep -Fqx "$line" <<<"$current"; then
      current="$(printf '%s\n%s\n' "$current" "$line")"
      added=$((added + 1))
    fi
  done
  if ((added > 0)); then
    printf '%s\n' "$current" | crontab -
    info "crontab: ${added} line(s) added"
  else
    info "crontab: already present"
  fi
else
  info "cron lines (add with --cron, or paste into crontab -e):"
  for line in "${cron_lines[@]}"; do
    info "  $line"
  done
fi

info "next:  $home_dir/collect.sh                    # one sample now"
info "       $home_dir/status.sh                     # is it recording?"
info "       $home_dir/dashboard-start.sh            # http://127.0.0.1:8899/"
