#!/usr/bin/env bash

# Portable helpers shared by the boards (Linux + macOS).
# Sourced, not executed. Depends only on bash, awk and core system tools.

have() { command -v "$1" >/dev/null 2>&1; }

platform_os() {
  case "$(uname -s)" in
    Linux*)   printf 'linux' ;;
    Darwin*)  printf 'macos' ;;
    FreeBSD*) printf 'freebsd' ;;
    *)        printf 'unknown' ;;
  esac
}

PLATFORM="$(platform_os)"

is_linux() { [[ "$PLATFORM" == "linux" ]]; }
is_macos() { [[ "$PLATFORM" == "macos" ]]; }

# True when a Linux /proc filesystem with per-CPU stats is readable.
has_procfs() { [[ -r /proc/stat ]]; }

host_short() {
  if have hostname; then
    hostname -s 2>/dev/null || hostname | cut -d. -f1
  else
    uname -n | cut -d. -f1
  fi
}

# "3 weeks, 2 days, 9 hours" (no leading "up ")
uptime_pretty() {
  if have uptime && uptime -p >/dev/null 2>&1; then
    uptime -p | sed 's/^up //'
    return
  fi
  if is_macos; then
    local boot now up
    boot="$(sysctl -n kern.boottime 2>/dev/null | sed -E 's/.*sec = ([0-9]+).*/\1/')"
    if [[ -n "$boot" ]]; then
      now="$(date +%s)"
      up=$((now - boot))
      printf '%d days %02d:%02d' $((up / 86400)) $(((up % 86400) / 3600)) $(((up % 3600) / 60))
      return
    fi
  fi
  printf 'n/a'
}

# Prints "load1 load5 load15"
loadavg_values() {
  if is_linux && [[ -r /proc/loadavg ]]; then
    awk '{print $1, $2, $3}' /proc/loadavg
  elif is_macos; then
    sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1, $2, $3}'
  elif have uptime; then
    uptime | sed -E 's/.*load averages?: //'
  else
    printf '0 0 0'
  fi
}

logical_cpus() {
  if is_macos; then
    sysctl -n hw.logicalcpu 2>/dev/null && return
  fi
  getconf _NPROCESSORS_ONLN 2>/dev/null ||
    awk '/^processor/{n++} END{print n+0}' /proc/cpuinfo 2>/dev/null ||
    printf '1'
}

physical_cores() {
  if is_macos; then
    sysctl -n hw.physicalcpu 2>/dev/null && return
  fi
  if [[ -r /proc/cpuinfo ]]; then
    awk -F: '
      /physical id/{gsub(/ /,"",$2); socket=$2}
      /core id/{gsub(/ /,"",$2); seen[socket ":" $2]=1}
      END{for(i in seen)n++; print n+0}' /proc/cpuinfo
  else
    printf '0'
  fi
}

sockets() {
  if is_macos; then
    sysctl -n hw.packages 2>/dev/null && return
    printf '1'; return
  fi
  if [[ -r /proc/cpuinfo ]]; then
    awk -F: '/physical id/{gsub(/ /,"",$2); seen[$2]=1} END{for(i in seen)n++; print n+0}' /proc/cpuinfo
  else
    printf '0'
  fi
}

# Parse a human size like "2048.00M" / "1.5GiB" into KiB.
to_kib() {
  awk -v s="${1:-0}" 'BEGIN {
    u = substr(s, length(s), 1); n = s; gsub(/[A-Za-z]/, "", n); n += 0;
    if (u == "T" || u == "t") n *= 1024 * 1024 * 1024;
    else if (u == "G" || u == "g") n *= 1024 * 1024;
    else if (u == "M" || u == "m") n *= 1024;
    else if (u == "B" || u == "b") n /= 1024;
    printf "%d", n;
  }'
}

# Prints "total_kib available_kib"
mem_info_kib() {
  if is_linux && [[ -r /proc/meminfo ]]; then
    awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t+0, a+0}' /proc/meminfo
    return
  fi
  if is_macos; then
    local total page
    total=$(( $(sysctl -n hw.memsize 2>/dev/null || printf 0) / 1024 ))
    page="$(vm_stat 2>/dev/null | awk '/page size of/{print $8}')"
    [[ -n "$page" ]] || page=4096
    vm_stat 2>/dev/null | awk -v p="$page" -v total="$total" '
      /Pages free/       {free=$3+0}
      /Pages inactive/   {inactive=$3+0}
      /Pages speculative/{spec=$3+0}
      /Pages purgeable/  {purge=$3+0}
      END{ avail=(free+inactive+spec+purge)*p/1024; printf "%d %d", total, avail }'
    return
  fi
  printf '0 0'
}

# Prints "swap_total_kib swap_used_kib"
swap_info_kib() {
  if is_linux && [[ -r /proc/meminfo ]]; then
    awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{print t+0, (t-f)+0}' /proc/meminfo
    return
  fi
  if is_macos; then
    local out t u
    out="$(sysctl -n vm.swapusage 2>/dev/null)"
    t="$(printf '%s' "$out" | awk '{print $3}')"
    u="$(printf '%s' "$out" | awk '{print $6}')"
    printf '%d %d' "$(to_kib "$t")" "$(to_kib "$u")"
    return
  fi
  printf '0 0'
}

# Overall CPU busy percentage. Linux reads /proc/stat; macOS uses top.
overall_cpu_percent() {
  if is_linux && [[ -r /proc/stat ]]; then
    local a b
    a="$(awk '/^cpu /{for(i=2;i<=NF;i++)t+=$i; print $5+$6, t}' /proc/stat)"  # idle, total
    sleep 0.4
    b="$(awk '/^cpu /{for(i=2;i<=NF;i++)t+=$i; print $5+$6, t}' /proc/stat)"
    awk -v a="$a" -v b="$b" 'BEGIN{
      split(a,x," "); split(b,y," ");
      dt=y[2]-x[2]; di=y[1]-x[1];
      if (dt<=0) { print 0 } else { p=100*(dt-di)/dt; if(p<0)p=0; if(p>100)p=100; printf "%.0f", p }
    }'
    return
  fi
  if is_macos && have top; then
    top -l 2 -n 0 2>/dev/null |
      awk -F'[ %]+' '/CPU usage/{idle=$7} END{ if (idle=="") print "0"; else printf "%.0f", 100-idle }'
    return
  fi
  printf '0'
}

# numfmt --to=iec-i --suffix=B replacement.
human_bytes_iec() {
  awk -v b="${1:-0}" 'BEGIN {
    if (b >= 1024^4) printf "%.1fTiB", b/1024^4;
    else if (b >= 1024^3) printf "%.1fGiB", b/1024^3;
    else if (b >= 1024^2) printf "%.1fMiB", b/1024^2;
    else if (b >= 1024) printf "%.1fKiB", b/1024;
    else printf "%dB", b;
  }'
}

# KiB -> IEC string (used by cpu-board memory line).
human_kib_iec() {
  awk -v b="${1:-0}" 'BEGIN {
    if (b >= 1024^3) printf "%.1f TiB", b/1024^3;
    else if (b >= 1024^2) printf "%.1f GiB", b/1024^2;
    else if (b >= 1024) printf "%.1f MiB", b/1024;
    else printf "%d KiB", b;
  }'
}

user_exists() { id -u "$1" >/dev/null 2>&1; }

file_owner() {
  if is_macos; then
    stat -f '%Su' "$1" 2>/dev/null
  else
    stat -c '%U' "$1" 2>/dev/null
  fi
}