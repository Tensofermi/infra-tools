#!/usr/bin/env bash

# Human-readable Docker dashboard for shared Linux servers.
# The host user who ran `docker run` is not recorded by Docker; OWNER is inferred.
set -uo pipefail

PROGRAM_NAME="${0##*/}"
SHOW_ALL=0
SHOW_SIDECARS=0
WATCH_INTERVAL=""
COLOR_MODE="auto"
TARGET=""

usage() {
  cat <<EOF
Usage: ${PROGRAM_NAME} [options] [CONTAINER]

Show an at-a-glance Docker dashboard, or detailed information for one container.

Options:
  -a, --all              Include stopped containers
      --sidecars         Include Harbor network sidecars
  -w, --watch [SECONDS]  Refresh continuously (default: 2 seconds)
      --once             Print once and exit (default)
      --no-color         Disable ANSI colors
  -h, --help             Show this help

Examples:
  ${PROGRAM_NAME}
  ${PROGRAM_NAME} -a
  ${PROGRAM_NAME} --sidecars
  ${PROGRAM_NAME} harbor-container
  ${PROGRAM_NAME} -w 2

OWNER* is inferred from Compose working directories and bind-mount paths.
Docker does not store the host account that originally ran docker run.
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
    -a|--all) SHOW_ALL=1 ;;
    --sidecars) SHOW_SIDECARS=1 ;;
    -w|--watch)
      WATCH_INTERVAL="2"
      if (($# > 1)) && [[ "$2" != -* ]] && is_positive_number "$2"; then
        WATCH_INTERVAL="$2"
        shift
      fi
      ;;
    --once) WATCH_INTERVAL="" ;;
    --no-color) COLOR_MODE="never" ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *)
      [[ -z "$TARGET" ]] || die "only one container can be inspected at a time"
      TARGET="$1"
      ;;
  esac
  shift
done

[[ -z "$WATCH_INTERVAL" ]] || is_positive_number "$WATCH_INTERVAL" ||
  die "refresh interval must be a positive number"
command -v docker >/dev/null 2>&1 || die "docker was not found"
command -v jq >/dev/null 2>&1 || die "jq was not found"
docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon"

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
  C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_MAGENTA="" C_CYAN=""
fi

terminal_width() {
  local width
  width="${COLUMNS:-$(tput cols 2>/dev/null || true)}"
  [[ "$width" =~ ^[0-9]+$ ]] || width=120
  ((width < 90)) && width=90
  ((width > 180)) && width=180
  printf '%s' "$width"
}

hr() {
  local width i
  width="$(terminal_width)"
  for ((i=0; i<width; i++)); do printf '─'; done
  printf '\n'
}

shorten() {
  local value="$1" limit="$2"
  if ((${#value} > limit)); then
    printf '%s…' "${value:0:limit-1}"
  else
    printf '%s' "$value"
  fi
}

human_bytes() {
  numfmt --to=iec-i --suffix=B "${1:-0}" 2>/dev/null || printf '%s B' "${1:-0}"
}

owner_from_path() {
  local path="$1" candidate owner
  case "$path" in
    /home/*/*|/home/*)
      candidate="${path#/home/}"; candidate="${candidate%%/*}"
      getent passwd "$candidate" >/dev/null 2>&1 && { printf '%s|path:%s' "$candidate" "$path"; return; }
      ;;
    /mnt/nvme/*/*|/mnt/nvme/*)
      candidate="${path#/mnt/nvme/}"; candidate="${candidate%%/*}"
      getent passwd "$candidate" >/dev/null 2>&1 && { printf '%s|path:%s' "$candidate" "$path"; return; }
      ;;
  esac
  if [[ -e "$path" ]]; then
    owner="$(stat -c %U "$path" 2>/dev/null || true)"
    [[ -n "$owner" && "$owner" != "root" ]] && { printf '%s|owner:%s' "$owner" "$path"; return; }
  fi
  return 1
}

infer_owner() {
  local json="$1" path result
  path="$(jq -r '.[0].Config.Labels["com.docker.compose.project.working_dir"] // empty' <<<"$json")"
  if [[ -n "$path" ]] && result="$(owner_from_path "$path")"; then
    printf '%s' "$result"
    return
  fi
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if result="$(owner_from_path "$path")"; then
      printf '%s' "$result"
      return
    fi
  done < <(jq -r '.[0].Mounts[]? | select(.Type == "bind") | .Source' <<<"$json")
  printf '?|no reliable path clue'
}

state_text() {
  local status="$1" health="$2"
  case "$status" in
    running)
      if [[ "$health" == "unhealthy" ]]; then printf '%sUNHEALTHY%s' "$C_RED" "$C_RESET"
      elif [[ "$health" == "healthy" ]]; then printf '%shealthy%s' "$C_GREEN" "$C_RESET"
      else printf '%srunning%s' "$C_GREEN" "$C_RESET"; fi
      ;;
    exited|dead) printf '%s%s%s' "$C_RED" "$status" "$C_RESET" ;;
    paused|restarting) printf '%s%s%s' "$C_YELLOW" "$status" "$C_RESET" ;;
    *) printf '%s' "$status" ;;
  esac
}

compact_age() {
  sed -E \
    -e 's/^About //' \
    -e 's/^Less than a second/<1s/' \
    -e 's/ seconds?/s/' \
    -e 's/ minutes?/m/' \
    -e 's/ hours?/h/' \
    -e 's/ days?/d/' \
    -e 's/ weeks?/w/' \
    -e 's/ months?/mo/' \
    -e 's/ years?/y/' \
    -e 's/ ago$//'
}

percent_color() {
  local value="${1%%%}" warn="$2" high="$3"
  [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf '%s' "$C_DIM"; return; }
  awk -v v="$value" -v h="$high" 'BEGIN { exit !(v >= h) }' && { printf '%s' "$C_RED"; return; }
  awk -v v="$value" -v w="$warn" 'BEGIN { exit !(v >= w) }' && { printf '%s' "$C_YELLOW"; return; }
  printf '%s' "$C_GREEN"
}

cpu_color() {
  local value="${1%%%}"
  [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf '%s' "$C_DIM"; return; }
  awk -v v="$value" 'BEGIN { exit !(v >= 200) }' && { printf '%s' "$C_MAGENTA"; return; }
  awk -v v="$value" 'BEGIN { exit !(v >= 70) }' && { printf '%s' "$C_YELLOW"; return; }
  printf '%s' "$C_GREEN"
}

print_header() {
  local info containers running paused stopped images version driver root
  info="$(docker info --format '{{json .}}')"
  containers="$(jq -r '.Containers' <<<"$info")"
  running="$(jq -r '.ContainersRunning' <<<"$info")"
  paused="$(jq -r '.ContainersPaused' <<<"$info")"
  stopped="$(jq -r '.ContainersStopped' <<<"$info")"
  images="$(jq -r '.Images' <<<"$info")"
  version="$(jq -r '.ServerVersion' <<<"$info")"
  driver="$(jq -r '.Driver' <<<"$info")"
  root="$(jq -r '.DockerRootDir' <<<"$info")"
  printf '%s%sDocker dashboard%s  %s%s%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$C_DIM" "$(date '+%F %T %Z')" "$C_RESET"
  printf '%sHost%s %s  %sDocker%s %s  %sStorage%s %s  %sRoot%s %s\n' \
    "$C_DIM" "$C_RESET" "$(hostname)" "$C_DIM" "$C_RESET" "$version" \
    "$C_DIM" "$C_RESET" "$driver" "$C_DIM" "$C_RESET" "$root"
  printf '%s%s%s total  %s%s running%s  %s%s paused%s  %s%s stopped%s  %s%s images%s\n' \
    "$C_BOLD" "$containers" "$C_RESET" "$C_GREEN" "$running" "$C_RESET" \
    "$C_YELLOW" "$paused" "$C_RESET" "$C_RED" "$stopped" "$C_RESET" \
    "$C_BLUE" "$images" "$C_RESET"
}

print_table() {
  local ids id json name image status health state age owner_pair owner cpu mem mem_pct
  local name_w image_w width status_color cpu_c mem_c hidden=0
  local -A CPU MEM MEM_PCT
  while IFS='|' read -r id cpu mem mem_pct; do
    [[ -n "$id" ]] || continue
    CPU["$id"]="$cpu"
    mem="${mem%% / *}"
    mem="${mem//KiB/K}"; mem="${mem//MiB/M}"; mem="${mem//GiB/G}"; mem="${mem//TiB/T}"
    MEM["$id"]="$mem"
    MEM_PCT["$id"]="$mem_pct"
  done < <(docker stats --no-stream --format '{{.ID}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}' 2>/dev/null || true)

  if ((SHOW_ALL)); then ids="$(docker ps -aq)"; else ids="$(docker ps -q)"; fi
  printf '\n%s%sCONTAINERS%s%s\n' "$C_BOLD" "$C_CYAN" "$([[ $SHOW_ALL -eq 1 ]] && printf ' (ALL)' || true)" "$C_RESET"
  if [[ -z "$ids" ]]; then
    printf '%sNo containers found.%s\n' "$C_DIM" "$C_RESET"
    return
  fi

  width="$(terminal_width)"
  if ((width < 110)); then name_w=20; image_w=13; else name_w=31; image_w=30; fi
  printf '%s%-*s  %-9s  %-10s  %-7s  %8s  %9s  %-*s%s\n' \
    "$C_BOLD$C_DIM" "$name_w" 'NAME' 'OWNER*' 'STATE' 'AGE' 'CPU' 'MEM' "$image_w" 'IMAGE' "$C_RESET"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    json="$(docker inspect "$id")"
    name="$(jq -r '.[0].Name | ltrimstr("/")' <<<"$json")"
    image="$(jq -r '.[0].Config.Image' <<<"$json")"
    if ((SHOW_SIDECARS == 0)) && [[ "$name" == *harbor-docker-egress-control-sidecar* || "$image" == *harbor-docker-egress-control-sidecar* ]]; then
      ((hidden+=1))
      continue
    fi
    status="$(jq -r '.[0].State.Status' <<<"$json")"
    health="$(jq -r '.[0].State.Health.Status // empty' <<<"$json")"
    age="$(docker ps -a --filter "id=$id" --format '{{.RunningFor}}' | head -n1 | compact_age)"
    owner_pair="$(infer_owner "$json")"; owner="${owner_pair%%|*}"
    cpu="${CPU[$id]:--}"; mem="${MEM[$id]:--}"; mem_pct="${MEM_PCT[$id]:--}"
    case "$status/$health" in
      running/healthy) state='healthy'; status_color="$C_GREEN" ;;
      running/unhealthy) state='unhealthy'; status_color="$C_RED" ;;
      running/*) state='running'; status_color="$C_GREEN" ;;
      exited/*|dead/*) state="$status"; status_color="$C_RED" ;;
      paused/*|restarting/*) state="$status"; status_color="$C_YELLOW" ;;
      *) state="$status"; status_color="$C_DIM" ;;
    esac
    cpu_c="$(cpu_color "$cpu")"; mem_c="$(percent_color "$mem_pct" 70 90)"
    printf '%-*s  %s%-9s%s  %s%-10s%s  %-7s  %s%8s%s  %s%9s%s  %s%-*s%s\n' \
      "$name_w" "$(shorten "$name" "$name_w")" \
      "$C_CYAN" "$(shorten "$owner" 9)" "$C_RESET" \
      "$status_color" "$(shorten "$state" 10)" "$C_RESET" \
      "$(shorten "$age" 7)" \
      "$cpu_c" "$cpu" "$C_RESET" \
      "$mem_c" "$mem" "$C_RESET" \
      "$C_BLUE" "$image_w" "$(shorten "$image" "$image_w")" "$C_RESET"
  done <<<"$ids"
  if ((hidden > 0)); then
    printf '%s… %s Harbor network sidecar(s) hidden; use --sidecars to show them.%s\n' "$C_DIM" "$hidden" "$C_RESET"
  fi
  printf '\n%sCPU:%s %sgreen <70%%%s  %syellow ≥70%%%s  %smagenta ≥200%%%s    ' \
    "$C_DIM" "$C_RESET" "$C_GREEN" "$C_RESET" "$C_YELLOW" "$C_RESET" "$C_MAGENTA" "$C_RESET"
  printf '%sMEM:%s %sgreen <70%%%s  %syellow ≥70%%%s  %sred ≥90%%%s\n' \
    "$C_DIM" "$C_RESET" "$C_GREEN" "$C_RESET" "$C_YELLOW" "$C_RESET" "$C_RED" "$C_RESET"
  printf '%s* OWNER is inferred. Details: %s CONTAINER%s\n' "$C_DIM" "$PROGRAM_NAME" "$C_RESET"
}

print_detail() {
  local json id name image created status health pid started finished restart internal_user owner_pair owner evidence
  local command_line project service workdir ports mounts networks env_count memory nano cpuset gpus log_driver
  json="$(docker inspect "$TARGET" 2>/dev/null)" || die "container not found: $TARGET"
  id="$(jq -r '.[0].Id[0:12]' <<<"$json")"
  name="$(jq -r '.[0].Name | ltrimstr("/")' <<<"$json")"
  image="$(jq -r '.[0].Config.Image' <<<"$json")"
  created="$(jq -r '.[0].Created' <<<"$json")"
  status="$(jq -r '.[0].State.Status' <<<"$json")"
  health="$(jq -r '.[0].State.Health.Status // "not configured"' <<<"$json")"
  pid="$(jq -r '.[0].State.Pid' <<<"$json")"
  started="$(jq -r '.[0].State.StartedAt' <<<"$json")"
  finished="$(jq -r '.[0].State.FinishedAt' <<<"$json")"
  restart="$(jq -r '.[0].RestartCount' <<<"$json")"
  internal_user="$(jq -r '.[0].Config.User // empty' <<<"$json")"; [[ -n "$internal_user" ]] || internal_user='image default (usually root)'
  owner_pair="$(infer_owner "$json")"; owner="${owner_pair%%|*}"; evidence="${owner_pair#*|}"
  command_line="$(jq -r '.[0] | ((.Path // "") + " " + ((.Args // []) | join(" "))) ' <<<"$json")"
  project="$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // "-"' <<<"$json")"
  service="$(jq -r '.[0].Config.Labels["com.docker.compose.service"] // "-"' <<<"$json")"
  workdir="$(jq -r '.[0].Config.Labels["com.docker.compose.project.working_dir"] // "-"' <<<"$json")"
  ports="$(jq -r '.[0].NetworkSettings.Ports // {} | to_entries[]? | .key as $p | if .value == null then "\($p) (not published)" else .value[] | "\(.HostIp):\(.HostPort) -> \($p)" end' <<<"$json")"
  mounts="$(jq -r '.[0].Mounts[]? | "\(.Type): \(.Source) -> \(.Destination) \(.Mode)"' <<<"$json")"
  networks="$(jq -r '.[0].NetworkSettings.Networks // {} | to_entries[]? | "\(.key): \(.value.IPAddress // "-")"' <<<"$json")"
  env_count="$(jq -r '.[0].Config.Env // [] | length' <<<"$json")"
  memory="$(jq -r '.[0].HostConfig.Memory' <<<"$json")"
  nano="$(jq -r '.[0].HostConfig.NanoCpus' <<<"$json")"
  cpuset="$(jq -r '.[0].HostConfig.CpusetCpus // empty' <<<"$json")"
  gpus="$(jq -r '.[0].HostConfig.DeviceRequests // [] | map(.Count // 0) | add // 0' <<<"$json")"
  log_driver="$(jq -r '.[0].HostConfig.LogConfig.Type // "default"' <<<"$json")"

  printf '%s%sContainer details%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"; hr
  printf '%-18s %s (%s)\n' 'Name / ID:' "$name" "$id"
  printf '%-18s %s\n' 'Image:' "$image"
  printf '%-18s ' 'State:'; state_text "$status" "$health"; printf '  health=%s  restarts=%s  pid=%s\n' "$health" "$restart" "$pid"
  printf '%-18s %s\n' 'Created:' "$created"
  printf '%-18s %s\n' 'Started:' "$started"
  [[ "$status" == "running" ]] || printf '%-18s %s\n' 'Finished:' "$finished"
  printf '%-18s %s\n' 'Command:' "$command_line"
  printf '\n%sOwnership / identity%s\n' "$C_BOLD" "$C_RESET"
  printf '%-18s %s %s(inferred)%s\n' 'Host owner*:' "$owner" "$C_YELLOW" "$C_RESET"
  printf '%-18s %s\n' 'Evidence:' "$evidence"
  printf '%-18s %s\n' 'Container user:' "$internal_user"
  printf '%sDocker does not retain the host user who originally invoked docker run/create.%s\n' "$C_DIM" "$C_RESET"
  printf '\n%sCompose%s\n' "$C_BOLD" "$C_RESET"
  printf '%-18s %s\n%-18s %s\n%-18s %s\n' 'Project:' "$project" 'Service:' "$service" 'Working dir:' "$workdir"
  printf '\n%sResources%s\n' "$C_BOLD" "$C_RESET"
  printf '%-18s %s\n' 'Memory limit:' "$([[ "$memory" == 0 ]] && printf 'unlimited' || human_bytes "$memory")"
  printf '%-18s %s\n' 'CPU limit:' "$([[ "$nano" == 0 ]] && printf 'unlimited' || awk -v n="$nano" 'BEGIN { printf "%.2f CPUs", n/1000000000 }')"
  printf '%-18s %s\n%-18s %s\n%-18s %s\n' 'CPU set:' "${cpuset:--}" 'GPU requests:' "$gpus" 'Log driver:' "$log_driver"
  printf '\n%sPorts%s\n%s\n' "$C_BOLD" "$C_RESET" "${ports:--}"
  printf '\n%sNetworks%s\n%s\n' "$C_BOLD" "$C_RESET" "${networks:--}"
  printf '\n%sMounts%s\n%s\n' "$C_BOLD" "$C_RESET" "${mounts:--}"
  printf '\nEnvironment: %s variables (values hidden; use docker inspect if needed)\n' "$env_count"
}

render() {
  if [[ -n "$TARGET" ]]; then print_detail; else print_header; hr; print_table; fi
}

if [[ -n "$WATCH_INTERVAL" ]]; then
  while true; do
    printf '\033[H\033[2J'
    render
    sleep "$WATCH_INTERVAL"
  done
else
  render
fi
