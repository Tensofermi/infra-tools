#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR

# Human-readable Docker dashboard for shared Linux servers.
# The host user who ran `docker run` is not recorded by Docker; OWNER is inferred.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/platform.sh
source "${SCRIPT_DIR}/lib/platform.sh"

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

# Truncates "$1" to "$2" characters into the variable named "$3". Output goes
# to a variable because this runs once per row and a subshell per column is
# measurable on hundreds of containers.
shorten() {
  local value="$1" limit="$2"
  if ((${#value} > limit)); then
    printf -v "$3" '%s…' "${value:0:limit-1}"
  else
    printf -v "$3" '%s' "$value"
  fi
}

human_bytes() {
  human_bytes_iec "${1:-0}"
}

# Owner inference results: OWNER_ID is the inferred account ("?" when nothing
# matched) and OWNER_EVIDENCE the path or file owner it came from.
OWNER_ID=""
OWNER_EVIDENCE=""

# Sets OWNER_ID/OWNER_EVIDENCE from one path; returns 1 when it holds no clue.
owner_from_path() {
  local path="$1" candidate owner
  case "$path" in
    /home/*/*|/home/*)
      candidate="${path#/home/}"; candidate="${candidate%%/*}"
      if user_exists "$candidate"; then OWNER_ID="$candidate"; OWNER_EVIDENCE="path:$path"; return 0; fi
      ;;
    /mnt/nvme/*/*|/mnt/nvme/*)
      candidate="${path#/mnt/nvme/}"; candidate="${candidate%%/*}"
      if user_exists "$candidate"; then OWNER_ID="$candidate"; OWNER_EVIDENCE="path:$path"; return 0; fi
      ;;
  esac
  if [[ -e "$path" ]]; then
    owner="$(file_owner "$path" || true)"
    if [[ -n "$owner" && "$owner" != "root" ]]; then OWNER_ID="$owner"; OWNER_EVIDENCE="owner:$path"; return 0; fi
  fi
  return 1
}

# JSON filter for the paths OWNER can be inferred from, best clue first: the
# Compose project working dir, then every bind-mount source. Also interpolated
# into the row collector of print_table, so both views agree on the ordering.
JQ_OWNER_PATHS='[ (.Config.Labels["com.docker.compose.project.working_dir"] // empty) ] + [ .Mounts[]? | select(.Type == "bind") | .Source ]'

# Prints the owner path candidates of one `docker inspect` result array.
owner_paths_from_inspect() {
  jq -r ".[0] | ${JQ_OWNER_PATHS}"' | join("\u001e")'
}

# Sets OWNER_ID/OWNER_EVIDENCE from "\x1e"-joined candidate paths (best clue
# first). Falls back to "?", the same marker the table always showed.
infer_owner() {
  local rest="${1:-}" path
  OWNER_ID="?"
  OWNER_EVIDENCE="no reliable path clue"
  while [[ -n "$rest" ]]; do
    path="${rest%%$'\x1e'*}"
    if [[ "$rest" == *$'\x1e'* ]]; then rest="${rest#*$'\x1e'}"; else rest=""; fi
    [[ -n "$path" ]] || continue
    owner_from_path "$path" && return 0
  done
  return 0
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
  local ids ages stats rows line name image status health state age
  local short_name short_owner short_state short_age short_image
  local cpu mem cpu_level mem_level name_w image_w width status_color cpu_c mem_c hidden=0
  local -a fields

  if ((SHOW_ALL)); then ids="$(docker ps -aq)"; else ids="$(docker ps -q)"; fi
  if [[ -n "$ids" ]]; then
    # Collection is batched: `docker ps`, `docker ps -a`, `docker stats` and
    # one bulk `docker inspect`, however many containers there are. Per-container
    # docker calls made this unusable on hosts with hundreds of containers
    # (each CLI round-trip costs ~60 ms).
    ages="$(docker ps -a --format '{{.ID}}|{{.RunningFor}}')"
    stats="$(docker stats --no-stream --format '{{.ID}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}' 2>/dev/null || true)"
    # shellcheck disable=SC2086  # one container id per argument
    rows="$(docker inspect --format '{{json .}}' $ids 2>/dev/null |
      jq -n -r --arg ages "$ages" --arg stats "$stats" '
        # "id|value" lines -> {id: [values]}, so the per-row lookups below are
        # plain object indexing instead of a process per container. Keys are the
        # 12-char id prefix, which is also what the row lookup uses.
        def keyed:
          split("\n")
          | map(select(length > 0) | split("|"))
          | map({key: .[0][0:12], value: .[1:]})
          | from_entries;
        # Same rewrites as `docker ps` RunningFor -> the compact AGE column.
        def age_text:
          sub("^About "; "")
          | sub("^Less than a second"; "<1s")
          | sub(" seconds?"; "s") | sub(" minutes?"; "m") | sub(" hours?"; "h")
          | sub(" days?"; "d") | sub(" weeks?"; "w") | sub(" months?"; "mo")
          | sub(" years?"; "y")
          | sub(" ago$"; "");
        def level($warn; $high):
          (sub("%$"; "")) as $v
          | if ($v | test("^[0-9]+(\\.[0-9]+)?$")) then
              ($v | tonumber) as $n
              | if $n >= $high then "high" elif $n >= $warn then "warn" else "ok" end
            else "dim" end;
        ($ages | keyed) as $age_by_id
        | ($stats | keyed) as $stats_by_id
        | inputs
        | .Id[0:12] as $id
        | ($stats_by_id[$id] // null) as $s
        | [ ((.Name // "") | ltrimstr("/")),
            (.Config.Image // ""),
            (.State.Status // ""),
            (.State.Health.Status // ""),
            (($age_by_id[$id] // [""])[0] | age_text),
            (if $s == null then "-" else $s[0] end),
            (if $s == null then "-"
             else ($s[1] | split(" / ")[0] | sub("KiB"; "K") | sub("MiB"; "M")
                   | sub("GiB"; "G") | sub("TiB"; "T"))
             end),
            (if $s == null then "dim" else ($s[0] | level(70; 200)) end),
            (if $s == null then "dim" else ($s[2] | level(70; 90)) end)
          ]
          + [ ('"${JQ_OWNER_PATHS}"') | join("\u001e") ]
        | map(tostring) | join("\u001f")
      ')"
  fi

  printf '\n%s%sCONTAINERS%s%s\n' "$C_BOLD" "$C_CYAN" "$([[ $SHOW_ALL -eq 1 ]] && printf ' (ALL)' || true)" "$C_RESET"
  if [[ -z "$ids" ]]; then
    printf '%sNo containers found.%s\n' "$C_DIM" "$C_RESET"
    return
  fi

  width="$(terminal_width)"
  if ((width < 110)); then name_w=20; image_w=13; else name_w=31; image_w=30; fi
  printf '%s%-*s  %-9s  %-10s  %-7s  %8s  %9s  %-*s%s\n' \
    "$C_BOLD$C_DIM" "$name_w" 'NAME' 'OWNER*' 'STATE' 'AGE' 'CPU' 'MEM' "$image_w" 'IMAGE' "$C_RESET"
  # One "\x1f"-separated row per container: name image status health age cpu mem
  # cpu_level mem_level owner_paths. Fields come from the batched collector above.
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    IFS=$'\x1f' read -r -a fields <<<"$line"
    name="${fields[0]:-}"
    image="${fields[1]:-}"
    status="${fields[2]:-}"
    health="${fields[3]:-}"
    age="${fields[4]:-}"
    cpu="${fields[5]:--}"
    mem="${fields[6]:--}"
    cpu_level="${fields[7]:-dim}"
    mem_level="${fields[8]:-dim}"
    if ((SHOW_SIDECARS == 0)) && [[ "$name" == *harbor-docker-egress-control-sidecar* || "$image" == *harbor-docker-egress-control-sidecar* ]]; then
      ((hidden+=1))
      continue
    fi
    infer_owner "${fields[9]:-}"
    owner="$OWNER_ID"
    case "$status/$health" in
      running/healthy) state='healthy'; status_color="$C_GREEN" ;;
      running/unhealthy) state='unhealthy'; status_color="$C_RED" ;;
      running/*) state='running'; status_color="$C_GREEN" ;;
      exited/*|dead/*) state="$status"; status_color="$C_RED" ;;
      paused/*|restarting/*) state="$status"; status_color="$C_YELLOW" ;;
      *) state="$status"; status_color="$C_DIM" ;;
    esac
    case "$cpu_level" in
      high) cpu_c="$C_MAGENTA" ;;
      warn) cpu_c="$C_YELLOW" ;;
      ok) cpu_c="$C_GREEN" ;;
      *) cpu_c="$C_DIM" ;;
    esac
    case "$mem_level" in
      high) mem_c="$C_RED" ;;
      warn) mem_c="$C_YELLOW" ;;
      ok) mem_c="$C_GREEN" ;;
      *) mem_c="$C_DIM" ;;
    esac
    shorten "$name" "$name_w" short_name
    shorten "$owner" 9 short_owner
    shorten "$state" 10 short_state
    shorten "$age" 7 short_age
    shorten "$image" "$image_w" short_image
    printf '%-*s  %s%-9s%s  %s%-10s%s  %-7s  %s%8s%s  %s%9s%s  %s%-*s%s\n' \
      "$name_w" "$short_name" \
      "$C_CYAN" "$short_owner" "$C_RESET" \
      "$status_color" "$short_state" "$C_RESET" \
      "$short_age" \
      "$cpu_c" "$cpu" "$C_RESET" \
      "$mem_c" "$mem" "$C_RESET" \
      "$C_BLUE" "$image_w" "$short_image" "$C_RESET"
  done <<<"$rows"
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
  local json id name image created status health pid started finished restart internal_user owner evidence
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
  infer_owner "$(owner_paths_from_inspect <<<"$json")"; owner="$OWNER_ID"; evidence="$OWNER_EVIDENCE"
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
