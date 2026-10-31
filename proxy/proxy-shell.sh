# proxy — shell integration for the mihomo control CLI.
#
# Why this file exists: `proxy on` / `proxy off` must change the environment of
# the *current* shell, and a child process cannot do that. The `proxy`
# executable prints `export` / `unset` lines on stdout; the shell function
# below evals them. Everything else (status/nodes/node/test/ip/update/log) is
# passed straight through to the executable.
#
# Installed and wired into ~/.bashrc (and ~/.zshrc) by proxy/install.sh.
# Running straight from the repo:
#   . /path/to/infra-tools/proxy/proxy-shell.sh
#   proxy on

# Directory this library lives in, so an install under any --prefix works.
# BASH_SOURCE is bash-only; other shells fall back to the default directory.
_proxy_lib_dir() {
  if [ -n "${BASH_VERSION:-}" ]; then
    (cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  else
    printf '%s' "${MIHOMO_DIR:-$HOME/Mihomo}"
  fi
}

proxy() {
  local bin="${PROXY_CLI_BIN:-$(_proxy_lib_dir)/proxy}" out rc mode="${1:-status}"

  if [[ ! -x "$bin" ]]; then
    # Older installs only put the CLI on PATH; keep working with those.
    out="$(command -v proxy-cli 2>/dev/null || true)"
    [[ -n "$out" ]] && bin="$out"
  fi
  if [[ ! -x "$bin" ]]; then
    printf 'proxy: 找不到 %s（被删了？重跑 proxy/install.sh）\n' "$bin" >&2
    return 127
  fi

  case "$mode" in
    on|off|toggle)
      out="$("$bin" "$@")"; rc=$?
      # Guard against the silent failure mode that shipped once: the message
      # "✔ 代理已开启" goes to stderr, so an empty stdout looks like success
      # while the shell keeps talking to the internet directly.
      if [[ -z "$out" ]]; then
        printf 'proxy: 警告：没拿到 export 语句，代理环境未生效（%s 出错了）\n' "$bin" >&2
        return 1
      fi
      eval "$out"
      # Judge success by what the block actually did, not by $mode: `toggle`
      # is neither on nor off, and naming it made toggle→off exit 1.
      if [[ "$out" == *"unset HTTP_PROXY"* ]]; then
        if [[ -n "${HTTPS_PROXY:-}" ]]; then
          printf 'proxy: 警告：HTTPS_PROXY 仍是 %s，没清掉\n' "$HTTPS_PROXY" >&2
          return 1
        fi
      elif [[ "$mode" == "off" ]]; then
        printf 'proxy: 警告：off 没有输出 unset，环境可能没清干净\n' >&2
        return 1
      elif [[ -z "${HTTPS_PROXY:-}" ]]; then
        printf 'proxy: 警告：HTTPS_PROXY 仍为空，流量会走直连（见 %s status）\n' "$bin" >&2
        return 1
      fi
      return "$rc"
      ;;
    *)
      "$bin" "$@"
      ;;
  esac
}
