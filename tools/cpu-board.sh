#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR

# Compact terminal dashboard for large multi-socket Linux CPU servers.
# Works on any Linux distro; on macOS it degrades to overall CPU (no NUMA).
# No jq/python/root dependency required.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/platform.sh
source "${SCRIPT_DIR}/lib/platform.sh"

PROGRAM_NAME="${0##*/}"
WATCH_INTERVAL=""
SAMPLE_INTERVAL="0.7"
TOP_COUNT=10
COLOR_MODE="auto"
ASCII_MODE=0

usage() {
  cat <<EOF
Usage: ${PROGRAM_NAME} [options]

Show an at-a-glance CPU/NUMA/process dashboard for large Linux servers.

Options:
  -w, --watch [SECONDS]  Refresh continuously (default: 2 seconds)
      --once             Print once and exit (default)
  -n, --top COUNT        Number of users/processes to show (default: 10)
      --sample SECONDS   Sampling time in once mode (default: 0.7)
      --no-color         Disable ANSI colors
      --ascii            Use ASCII characters only
  -h, --help             Show this help

Examples:
  ${PROGRAM_NAME}
  ${PROGRAM_NAME} --watch
  ${PROGRAM_NAME} -w 1 -n 15
  NO_COLOR=1 ${PROGRAM_NAME} --ascii

Notes:
  CPU values are sampled from /proc/stat (Linux). In the process table, 100%
  CPU means one logical CPU; a multi-threaded process can exceed 100%.
  On macOS CPU comes from top and the NUMA/per-core heat map is unavailable.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

is_positive_number() {
  [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
    awk -v n="$1" 'BEGIN { exit !(n > 0) }'
}

while (($#)); do
  case "$1" in
    -w|--watch)
      WATCH_INTERVAL="2"
      if (($# > 1)) && [[ "$2" != -* ]]; then
        WATCH_INTERVAL="$2"
        shift
      fi
      ;;
    --once)
      WATCH_INTERVAL=""
      ;;
    -n|--top)
      (($# > 1)) || die "$1 requires a count"
      TOP_COUNT="$2"
      shift
      ;;
    --sample)
      (($# > 1)) || die "$1 requires seconds"
      SAMPLE_INTERVAL="$2"
      shift
      ;;
    --no-color)
      COLOR_MODE="never"
      ;;
    --ascii)
      ASCII_MODE=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1 (try --help)"
      ;;
  esac
  shift
done

[[ "$TOP_COUNT" =~ ^[1-9][0-9]*$ ]] || die "top count must be a positive integer"
is_positive_number "$SAMPLE_INTERVAL" || die "sample interval must be positive"
if [[ -n "$WATCH_INTERVAL" ]]; then
  is_positive_number "$WATCH_INTERVAL" || die "refresh interval must be positive"
fi
if ! has_procfs && ! is_macos; then
  die "cpu-board supports Linux (/proc) and macOS only (detected: ${PLATFORM})"
fi

if [[ "$COLOR_MODE" == "auto" && -t 1 && "${TERM:-dumb}" != "dumb" && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_MAGENTA=$'\033[35m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""
  C_BOLD=""
  C_DIM=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_MAGENTA=""
  C_CYAN=""
fi

if ((ASCII_MODE)); then
  BAR_FULL="#"
  BAR_EMPTY="-"
  HR_CHAR="-"
  HEAT_CHARS=("." ":" "-" "=" "+" "*" "#" "%" "@")
else
  BAR_FULL="█"
  BAR_EMPTY="░"
  HR_CHAR="─"
  HEAT_CHARS=("▁" "▂" "▃" "▄" "▅" "▆" "▇" "█" "█")
fi

repeat_char() {
  local char="$1" count="$2" out="" i
  for ((i = 0; i < count; i++)); do out+="$char"; done
  printf '%s' "$out"
}

terminal_width() {
  local width
  width="$(tput cols 2>/dev/null || true)"
  [[ "$width" =~ ^[0-9]+$ ]] || width=116
  ((width < 84)) && width=84
  ((width > 160)) && width=160
  printf '%s' "$width"
}

metric_color() {
  local value="${1%.*}"
  [[ "$value" =~ ^[0-9]+$ ]] || value=0
  if ((value >= 90)); then
    printf '%s' "$C_RED"
  elif ((value >= 65)); then
    printf '%s' "$C_YELLOW"
  else
    printf '%s' "$C_GREEN"
  fi
}

bar() {
  local value="${1%.*}" width="$2" filled empty color
  [[ "$value" =~ ^[0-9]+$ ]] || value=0
  ((value < 0)) && value=0
  ((value > 100)) && value=100
  filled=$((value * width / 100))
  ((value > 0 && filled == 0)) && filled=1
  empty=$((width - filled))
  color="$(metric_color "$value")"
  printf '%s%s%s%s%s' "$color" "$(repeat_char "$BAR_FULL" "$filled")" \
    "$C_DIM" "$(repeat_char "$BAR_EMPTY" "$empty")" "$C_RESET"
}

human_kib() {
  awk -v kib="${1:-0}" 'BEGIN {
    if (kib >= 1073741824) printf "%.1f TiB", kib/1073741824;
    else if (kib >= 1048576) printf "%.1f GiB", kib/1048576;
    else if (kib >= 1024) printf "%.1f MiB", kib/1024;
    else printf "%d KiB", kib;
  }'
}

expand_cpu_list() {
  local list="$1" part first last i
  IFS=',' read -ra parts <<<"$list"
  for part in "${parts[@]}"; do
    if [[ "$part" == *-* ]]; then
      first="${part%-*}"
      last="${part#*-}"
      for ((i = first; i <= last; i++)); do printf '%s ' "$i"; done
    elif [[ -n "$part" ]]; then
      printf '%s ' "$part"
    fi
  done
}

declare -A PREV_TOTAL PREV_IDLE CPU_UTIL

read_initial_snapshot() {
  local label user nice system idle iowait irq softirq steal rest total idle_all
  while read -r label user nice system idle iowait irq softirq steal rest; do
    [[ "$label" == cpu || "$label" =~ ^cpu[0-9]+$ ]] || continue
    total=$((user + nice + system + idle + iowait + irq + softirq + steal))
    idle_all=$((idle + iowait))
    PREV_TOTAL["$label"]="$total"
    PREV_IDLE["$label"]="$idle_all"
  done </proc/stat
}

read_cpu_sample() {
  local label user nice system idle iowait irq softirq steal rest total idle_all
  local delta_total delta_idle busy
  while read -r label user nice system idle iowait irq softirq steal rest; do
    [[ "$label" == cpu || "$label" =~ ^cpu[0-9]+$ ]] || continue
    total=$((user + nice + system + idle + iowait + irq + softirq + steal))
    idle_all=$((idle + iowait))
    delta_total=$((total - ${PREV_TOTAL[$label]:-$total}))
    delta_idle=$((idle_all - ${PREV_IDLE[$label]:-$idle_all}))
    if ((delta_total > 0)); then
      busy=$(((100 * (delta_total - delta_idle) + delta_total / 2) / delta_total))
    else
      busy=0
    fi
    ((busy < 0)) && busy=0
    ((busy > 100)) && busy=100
    CPU_UTIL["$label"]="$busy"
    PREV_TOTAL["$label"]="$total"
    PREV_IDLE["$label"]="$idle_all"
  done </proc/stat
}

init_cpu_sample() {
  if has_procfs; then
    read_initial_snapshot
  fi
}

sample_cpu() {
  if has_procfs; then
    read_cpu_sample
  else
    CPU_UTIL[cpu]="$(overall_cpu_percent)"
  fi
}

heat_char() {
  local value="${1:-0}" idx color
  idx=$((value / 13))
  ((idx > 8)) && idx=8
  color="$(metric_color "$value")"
  printf '%s%s%s' "$color" "${HEAT_CHARS[$idx]}" "$C_RESET"
}

logical_cpus="$(logical_cpus)"
sockets="$(sockets)"
physical_cores="$(physical_cores)"
((sockets > 0)) || sockets="?"
((physical_cores > 0)) || physical_cores="$logical_cpus"

declare -a NODE_NAMES NODE_CPU_LISTS
for node_path in /sys/devices/system/node/node[0-9]*; do
  [[ -r "$node_path/cpulist" ]] || continue
  NODE_NAMES+=("${node_path##*/}")
  NODE_CPU_LISTS+=("$(<"$node_path/cpulist")")
done
if ((${#NODE_NAMES[@]} == 0)); then
  NODE_NAMES=("all")
  NODE_CPU_LISTS+=("0-$((logical_cpus - 1))")
fi

render_numa() {
  local i node list cpu value sum count hot avg heat cpus_expanded
  printf '%sNUMA / logical-CPU heat map%s  %s(each cell is one logical CPU: low → high)%s\n' \
    "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
  for ((i = 0; i < ${#NODE_NAMES[@]}; i++)); do
    node="${NODE_NAMES[$i]}"
    list="${NODE_CPU_LISTS[$i]}"
    cpus_expanded="$(expand_cpu_list "$list")"
    sum=0 count=0 hot=0 heat=""
    for cpu in $cpus_expanded; do
      value="${CPU_UTIL[cpu$cpu]:-0}"
      sum=$((sum + value))
      count=$((count + 1))
      ((value >= 90)) && hot=$((hot + 1))
      heat+="$(heat_char "$value")"
    done
    ((count > 0)) && avg=$((sum / count)) || avg=0
    printf '  %-5s %3d%%  hot %2d/%-2d  %-15s  %s\n' \
      "$node" "$avg" "$hot" "$count" "$list" "$heat"
  done
}

render_memory() {
  local total available used swap_total swap_used used_pct swap_pct
  read -r total available <<<"$(mem_info_kib)"
  read -r swap_total swap_used <<<"$(swap_info_kib)"
  used=$((total - available))
  ((total > 0)) && used_pct=$((100 * used / total)) || used_pct=0
  ((swap_total > 0)) && swap_pct=$((100 * swap_used / swap_total)) || swap_pct=0
  printf '%sMemory%s  %s / %s used  %3d%%  ' "$C_BOLD" "$C_RESET" \
    "$(human_kib "$used")" "$(human_kib "$total")" "$used_pct"
  bar "$used_pct" 18
  printf '  (%s available)    %sSwap%s  %s / %s used  %3d%%\n' \
    "$(human_kib "$available")" "$C_BOLD" "$C_RESET" \
    "$(human_kib "$swap_used")" "$(human_kib "$swap_total")" "$swap_pct"
}

render_users() {
  printf '%sTop users%s  %s(sum of process %%CPU; 100%% = one logical CPU)%s\n' \
    "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
  printf '  %-16s %10s %12s %10s\n' USER CPU% RSS PROCS
  ps -A -o user=,pcpu=,rss= 2>/dev/null | awk '
    {cpu[$1]+=$2; rss[$1]+=$3; count[$1]++}
    END {for (u in cpu) printf "%-16s %10.1f %12.0f %10d\n", u, cpu[u], rss[u], count[u]}
  ' | sort -k2,2nr | awk -v n="$TOP_COUNT" '
    function human(k) {
      if (k >= 1073741824) return sprintf("%.1f TiB", k/1073741824)
      if (k >= 1048576) return sprintf("%.1f GiB", k/1048576)
      if (k >= 1024) return sprintf("%.1f MiB", k/1024)
      return sprintf("%.0f KiB", k)
    }
    NR <= n {printf "  %-16s %10s %12s %10s\n", $1, $2, human($3), $4}
  '
}

render_processes() {
  printf '%sTop processes%s  %s(%%CPU may exceed 100 for multi-threaded processes)%s\n' \
    "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
  printf '  %-8s %-14s %8s %7s %10s %-5s %s\n' PID USER CPU% MEM% RSS STAT COMMAND
  ps -A -o pid=,user=,pcpu=,pmem=,rss=,state=,comm= 2>/dev/null | \
    sort -k3,3nr | awk -v n="$TOP_COUNT" '
      function human(k) {
        if (k >= 1073741824) return sprintf("%.1fT", k/1073741824)
        if (k >= 1048576) return sprintf("%.1fG", k/1048576)
        if (k >= 1024) return sprintf("%.1fM", k/1024)
        return sprintf("%.0fK", k)
      }
      NR <= n {printf "  %-8s %-14s %8s %7s %10s %-5s %s\n", $1,$2,$3,$4,human($5),$6,$7}
    '
}

render_dashboard() {
  local width now host uptime_text load1 load5 load15 util load_ratio status status_color
  width="$(terminal_width)"
  now="$(date '+%F %T')"
  host="$(host_short)"
  uptime_text="$(uptime_pretty)"
  read -r load1 load5 load15 <<<"$(loadavg_values)"
  util="${CPU_UTIL[cpu]:-0}"
  load_ratio="$(awk -v l="$load1" -v c="$logical_cpus" 'BEGIN{if(c>0)printf "%.0f",100*l/c; else print 0}')"
  if ((util >= 90 || load_ratio >= 100)); then
    status="SATURATED"; status_color="$C_RED"
  elif ((util >= 65 || load_ratio >= 70)); then
    status="BUSY"; status_color="$C_YELLOW"
  elif ((util >= 20)); then
    status="ACTIVE"; status_color="$C_CYAN"
  else
    status="OK"; status_color="$C_GREEN"
  fi

  printf '%s%sCPU DASHBOARD%s  %s  %s%s%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" \
    "$host" "$C_DIM" "$now" "$C_RESET"
  printf '%s\n' "$(repeat_char "$HR_CHAR" "$width")"
  printf '%sCPU%s  %3d%%  ' "$C_BOLD" "$C_RESET" "$util"
  bar "$util" 28
  printf '  %s%s%s  %s logical / %s physical / %s sockets\n' \
    "$status_color" "$status" "$C_RESET" "$logical_cpus" "$physical_cores" "$sockets"
  printf '%sLoad%s  %s  %s  %s  (1/5/15 min; load1 = %s%% of logical CPUs)    %sUptime%s  %s\n' \
    "$C_BOLD" "$C_RESET" "$load1" "$load5" "$load15" "$load_ratio" \
    "$C_BOLD" "$C_RESET" "$uptime_text"
  printf '\n'
  if has_procfs; then
    render_numa
  else
    printf '%sNUMA / per-core heat map: not available on %s (overall CPU above)%s\n' \
      "$C_DIM" "$PLATFORM" "$C_RESET"
  fi
  printf '\n'
  render_memory
  printf '\n'
  render_users
  printf '\n'
  render_processes
}

cleanup() {
  if [[ -n "$WATCH_INTERVAL" && -t 1 ]]; then
    printf '\033[?25h%s' "$C_RESET"
  fi
}
trap cleanup EXIT INT TERM

init_cpu_sample
if [[ -n "$WATCH_INTERVAL" ]]; then
  [[ -t 1 ]] && printf '\033[?25l'
  while :; do
    sleep "$WATCH_INTERVAL"
    sample_cpu
    [[ -t 1 ]] && printf '\033[H\033[2J'
    render_dashboard
  done
else
  sleep "$SAMPLE_INTERVAL"
  sample_cpu
  render_dashboard
fi
