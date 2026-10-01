#!/usr/bin/env bash

# Terminal dashboard for NVIDIA GPUs. No jq/python dependency required.
set -uo pipefail

PROGRAM_NAME="${0##*/}"
WATCH_INTERVAL=""
COLOR_MODE="auto"
ASCII_MODE=0

usage() {
  cat <<EOF
Usage: ${PROGRAM_NAME} [options]

Show an at-a-glance NVIDIA GPU dashboard.

Options:
  -w, --watch [SECONDS]  Refresh continuously (default: 2 seconds)
      --once             Print once and exit (default)
      --no-color         Disable ANSI colors
      --ascii            Use ASCII bars instead of Unicode blocks
  -h, --help             Show this help

Examples:
  ${PROGRAM_NAME}
  ${PROGRAM_NAME} --watch
  ${PROGRAM_NAME} -w 1
  NO_COLOR=1 ${PROGRAM_NAME}
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

is_positive_number() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v n="$1" 'BEGIN { exit !(n > 0) }'
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

if [[ -n "$WATCH_INTERVAL" ]] && ! is_positive_number "$WATCH_INTERVAL"; then
  die "refresh interval must be a positive number"
fi

command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi was not found"

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
  C_WHITE=$'\033[37m'
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
  C_WHITE=""
fi

if ((ASCII_MODE)); then
  BAR_FULL="#"
  BAR_EMPTY="-"
  HR_CHAR="-"
else
  BAR_FULL="█"
  BAR_EMPTY="░"
  HR_CHAR="─"
fi

trim() {
  local value="$*"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

is_number() {
  [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
}

repeat_char() {
  local char="$1"
  local count="$2"
  local out=""
  local i
  for ((i = 0; i < count; i++)); do
    out+="$char"
  done
  printf '%s' "$out"
}

terminal_width() {
  local width
  width="$(tput cols 2>/dev/null || true)"
  if ! [[ "$width" =~ ^[0-9]+$ ]]; then
    width=110
  fi
  ((width < 78)) && width=78
  ((width > 140)) && width=140
  printf '%s' "$width"
}

number_or_zero() {
  if is_number "$1"; then
    printf '%s' "$1"
  else
    printf '0'
  fi
}

round_number() {
  if is_number "$1"; then
    awk -v n="$1" 'BEGIN { printf "%.0f", n }'
  else
    printf '0'
  fi
}

percentage() {
  local numerator denominator
  numerator="$(number_or_zero "$1")"
  denominator="$(number_or_zero "$2")"
  awk -v a="$numerator" -v b="$denominator" 'BEGIN {
    if (b <= 0) print 0;
    else {
      p = 100 * a / b;
      if (p < 0) p = 0;
      if (p > 100) p = 100;
      printf "%.0f", p;
    }
  }'
}

mib_to_gib() {
  if is_number "$1"; then
    awk -v mib="$1" 'BEGIN { printf "%.1f", mib / 1024 }'
  else
    printf '?'
  fi
}

metric_color() {
  local value
  value="$(round_number "$1")"
  if ((value >= 90)); then
    printf '%s' "$C_RED"
  elif ((value >= 65)); then
    printf '%s' "$C_YELLOW"
  else
    printf '%s' "$C_GREEN"
  fi
}

bar() {
  local value="$1"
  local width="$2"
  local numeric filled empty color
  numeric="$(round_number "$value")"
  ((numeric < 0)) && numeric=0
  ((numeric > 100)) && numeric=100
  filled=$((numeric * width / 100))
  ((numeric > 0 && filled == 0)) && filled=1
  empty=$((width - filled))
  color="$(metric_color "$numeric")"
  printf '%s%s%s%s%s' \
    "$color" \
    "$(repeat_char "$BAR_FULL" "$filled")" \
    "$C_DIM" \
    "$(repeat_char "$BAR_EMPTY" "$empty")" \
    "$C_RESET"
}

gpu_status() {
  local util mem temp
  util="$(round_number "$1")"
  mem="$(round_number "$2")"
  temp="$(round_number "$3")"

  if ((temp >= 85)); then
    printf '%sHOT%s' "$C_RED" "$C_RESET"
  elif ((mem >= 95)); then
    printf '%sFULL%s' "$C_RED" "$C_RESET"
  elif ((util < 10 && mem < 10)); then
    printf '%sFREE%s' "$C_GREEN" "$C_RESET"
  elif ((util >= 80)); then
    printf '%sBUSY%s' "$C_YELLOW" "$C_RESET"
  else
    printf '%sACTIVE%s' "$C_CYAN" "$C_RESET"
  fi
}

system_memory_summary() {
  if command -v free >/dev/null 2>&1; then
    free -h 2>/dev/null | awk '/^Mem:/ { print $3 "/" $2 }'
  else
    printf 'n/a'
  fi
}

render_dashboard() {
  local width bar_width horizontal gpu_data
  local driver cuda_version gpu_count host now load system_mem
  local idx uuid name temp util_gpu util_mem mem_used mem_total power power_limit pstate fan
  local mem_pct used_gib total_gib util_bar mem_bar status temp_text power_text fan_text

  width="$(terminal_width)"
  bar_width=22
  ((width < 100)) && bar_width=16
  horizontal="$(repeat_char "$HR_CHAR" "$width")"

  gpu_data="$(nvidia-smi \
    --query-gpu=index,uuid,name,temperature.gpu,utilization.gpu,utilization.memory,memory.used,memory.total,power.draw,power.limit,pstate,fan.speed \
    --format=csv,noheader,nounits 2>/dev/null)" || {
      printf '%sUnable to query NVIDIA GPUs. Check the driver and permissions.%s\n' "$C_RED" "$C_RESET" >&2
      return 1
    }

  [[ -n "$gpu_data" ]] || {
    printf '%sNo NVIDIA GPU was reported by nvidia-smi.%s\n' "$C_YELLOW" "$C_RESET"
    return 1
  }

  driver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n 1 | tr -d '[:space:]')"
  cuda_version="$(nvidia-smi 2>/dev/null | sed -n 's/.*CUDA Version:[[:space:]]*\([^ ]*\).*/\1/p' | head -n 1)"
  gpu_count="$(printf '%s\n' "$gpu_data" | awk 'NF { n++ } END { print n+0 }')"
  host="$(hostname -s 2>/dev/null || hostname)"
  now="$(date '+%Y-%m-%d %H:%M:%S')"
  load="$(awk '{ print $1 ", " $2 ", " $3 }' /proc/loadavg 2>/dev/null || printf 'n/a')"
  system_mem="$(system_memory_summary)"

  printf '%s%sNVIDIA GPU DASHBOARD%s  %s%s%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$C_BOLD" "$host" "$C_RESET"
  printf '%s\n' "$horizontal"
  printf ' %sTime%s %-19s   %sGPUs%s %-3s   %sDriver%s %-12s   %sCUDA%s %-8s\n' \
    "$C_DIM" "$C_RESET" "$now" "$C_DIM" "$C_RESET" "$gpu_count" \
    "$C_DIM" "$C_RESET" "${driver:-n/a}" "$C_DIM" "$C_RESET" "${cuda_version:-n/a}"
  printf ' %sLoad%s %-18s   %sRAM%s %-13s   %sUser%s %s\n' \
    "$C_DIM" "$C_RESET" "$load" "$C_DIM" "$C_RESET" "$system_mem" \
    "$C_DIM" "$C_RESET" "${USER:-$(id -un)}"
  printf '%s\n' "$horizontal"

  declare -A UUID_TO_INDEX=()

  while IFS=',' read -r idx uuid name temp util_gpu util_mem mem_used mem_total power power_limit pstate fan; do
    idx="$(trim "$idx")"
    uuid="$(trim "$uuid")"
    name="$(trim "$name")"
    temp="$(trim "$temp")"
    util_gpu="$(trim "$util_gpu")"
    util_mem="$(trim "$util_mem")"
    mem_used="$(trim "$mem_used")"
    mem_total="$(trim "$mem_total")"
    power="$(trim "$power")"
    power_limit="$(trim "$power_limit")"
    pstate="$(trim "$pstate")"
    fan="$(trim "$fan")"

    UUID_TO_INDEX["$uuid"]="$idx"
    mem_pct="$(percentage "$mem_used" "$mem_total")"
    used_gib="$(mib_to_gib "$mem_used")"
    total_gib="$(mib_to_gib "$mem_total")"
    util_bar="$(bar "$util_gpu" "$bar_width")"
    mem_bar="$(bar "$mem_pct" "$bar_width")"
    status="$(gpu_status "$util_gpu" "$mem_pct" "$temp")"

    if is_number "$temp"; then temp_text="${temp}°C"; else temp_text="n/a"; fi
    if is_number "$power"; then
      if is_number "$power_limit"; then power_text="${power}/${power_limit} W"; else power_text="${power} W"; fi
    else
      power_text="n/a"
    fi
    if is_number "$fan"; then fan_text="${fan}%"; else fan_text="n/a"; fi

    printf '%sGPU %-2s%s  %-42s  [%s]\n' "$C_BOLD" "$idx" "$C_RESET" "$name" "$status"
    printf '  UTIL  [%s] %3s%%     MEM   [%s] %3s%%\n' "$util_bar" "$(round_number "$util_gpu")" "$mem_bar" "$mem_pct"
    printf '  VRAM  %5s / %-5s GiB   TEMP  %-7s   POWER  %-18s   STATE  %-4s   FAN  %s\n' \
      "$used_gib" "$total_gib" "$temp_text" "$power_text" "$pstate" "$fan_text"
    printf '  %sMemory-controller utilization: %s%%%s\n' "$C_DIM" "$(round_number "$util_mem")" "$C_RESET"
    printf '%s\n' "$horizontal"
  done <<< "$gpu_data"

  printf '%s%sGPU PROCESSES%s\n' "$C_BOLD" "$C_MAGENTA" "$C_RESET"
  printf ' %-4s %-8s %-12s %10s  %s\n' "GPU" "PID" "USER" "GPU MEM" "PROCESS"
  printf ' %-4s %-8s %-12s %10s  %s\n' "---" "--------" "------------" "----------" "----------------------------------------"

  local process_data gpu_uuid pid process_name used_memory process_gpu process_user display_name found_process
  process_data="$(nvidia-smi \
    --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory \
    --format=csv,noheader,nounits 2>/dev/null || true)"
  found_process=0

  if [[ -n "$process_data" ]]; then
    while IFS=',' read -r gpu_uuid pid process_name used_memory; do
      gpu_uuid="$(trim "$gpu_uuid")"
      pid="$(trim "$pid")"
      process_name="$(trim "$process_name")"
      used_memory="$(trim "$used_memory")"
      process_gpu="${UUID_TO_INDEX[$gpu_uuid]:-?}"
      process_user="$(ps -o user= -p "$pid" 2>/dev/null | awk 'NR==1 { print $1 }')"
      process_user="${process_user:-?}"
      display_name="$process_name"
      ((${#display_name} > 52)) && display_name="…${display_name: -51}"

      if [[ "$process_user" == "${USER:-$(id -un)}" ]]; then
        printf '%s' "$C_GREEN"
      fi
      printf ' %-4s %-8s %-12s %8s MiB  %s%s\n' \
        "$process_gpu" "$pid" "$process_user" "$used_memory" "$display_name" "$C_RESET"
      found_process=1
    done <<< "$process_data"
  fi

  if ((found_process == 0)); then
    printf ' %sNo active compute processes.%s\n' "$C_DIM" "$C_RESET"
  fi

  if [[ -n "$WATCH_INTERVAL" ]]; then
    printf '\n%sRefreshing every %ss — press Ctrl-C to exit.%s\n' "$C_DIM" "$WATCH_INTERVAL" "$C_RESET"
  fi
}

if [[ -n "$WATCH_INTERVAL" ]]; then
  trap 'printf "\033[?25h\033[0m\n"; exit 0' INT TERM EXIT
  printf '\033[?25l'
  while :; do
    printf '\033[H\033[2J'
    render_dashboard || true
    sleep "$WATCH_INTERVAL"
  done
else
  render_dashboard
fi
