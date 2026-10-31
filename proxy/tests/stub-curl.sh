#!/usr/bin/env bash
# Stub `curl` for the proxy CLI tests: answers the mihomo controller endpoints
# that proxy/proxy really calls, so the CLI's JSON plumbing can be tested with
# no mihomo, no network and no root.
#
# Fixture (kept in one place, names are what the CLI sees in the JSON):
#   Main  : Selector, all = Auto + 2 real nodes + 3 subscription info entries
#   Auto  : URLTest,  all = the 2 real nodes
#
# Knobs: STUB_LOG=<file> (record method/path/body), STUB_DELAY=<ms>,
#        STUB_ZERO_DELAYS=1 (every node reports 0 ms -> triggers the fallback
#        path in `proxy pick` without downloading anything).
set -uo pipefail

argv=("$@")
url=""; method="GET"; body=""; out=""; want_code=0
while (($#)); do
  case "$1" in
    http://*|https://*) url="$1" ;;
    -X) method="$2"; shift ;;
    -d) body="$2"; shift ;;
    -o|--output) out="$2"; shift ;;
    -w|--write-out) want_code=1; shift ;;
  esac
  shift
done

# Raw argv, so a test can prove whether -k (insecure) was passed.
[[ -n "${STUB_ARGV_LOG:-}" ]] && printf '%s\n' "${argv[*]}" >>"$STUB_ARGV_LOG"

# Anything that is not the controller is the subscription download.
if [[ -n "$url" && "$url" != *127.0.0.1* ]]; then
  if [[ -n "$out" && -f "${STUB_SUB_FILE:-}" ]]; then
    cp "${STUB_SUB_FILE}" "$out"
  fi
  ((want_code)) && printf '200'
  exit 0
fi

# -H @- makes curl read the header block from stdin; record it so a test can
# prove the controller secret never travels on the command line.
hdr=""
[[ -t 0 ]] || hdr="$(cat 2>/dev/null || true)"

path="${url#http://*/}"
path="${path%%\?*}"

# Stateful bit: remember the last group switch so a follow-up GET /proxies/Main
# reports it as `now` (the CLI asserts the switch actually took effect).
state="${STUB_STATE:-/tmp/stub-curl.state}"
current() { [[ -s "$state" ]] && cat "$state" || printf 'Auto'; }

if [[ -n "${STUB_LOG:-}" ]]; then
  printf '%s %s %s [%s]\n' "$method" "$path" "$body" "$hdr" >>"$STUB_LOG"
fi

MAIN_JSON='{"name":"Main","type":"Selector","now":"Auto","all":[
 "Auto","hk-01","jp-02","剩余流量：100.00 GB","套餐到期：长期有效","过滤掉 3 条线路"]}'
AUTO_JSON='{"name":"Auto","type":"URLTest","now":"hk-01","all":["hk-01","jp-02"]}'

case "$path" in
  proxies|proxies/)
    printf '{"proxies":{
      "Main":{"type":"Selector","all":["Auto","hk-01","jp-02"]},
      "Auto":{"type":"URLTest","all":["hk-01","jp-02"]},
      "hk-01":{"type":"Shadowsocks"},
      "jp-02":{"type":"Shadowsocks"}}}'
    ;;
  group/*/delay)
    if [[ "${STUB_ZERO_DELAYS:-0}" == "1" ]]; then
      printf '{"Auto":0,"hk-01":0,"jp-02":0}'
    else
      printf '{"Auto":20,"hk-01":15,"jp-02":40,"剩余流量：100.00 GB":0}'
    fi
    ;;
  proxies/*/delay)
    printf '{"delay":%s}' "${STUB_DELAY:-15}"
    ;;
  proxies/Main)
    printf '%s' "$MAIN_JSON" | sed "s/\"now\":\"Auto\"/\"now\":\"$(current)\"/"
    ;;
  proxies/Auto)
    printf '%s' "$AUTO_JSON"
    ;;
  proxies/*)
    # Anything else (nodes, info entries) is not a group: no "all" key.
    printf '{"type":"Shadowsocks"}'
    ;;
  *)
    ;;
esac

# switch_group() sends a PUT and parses the HTTP code from `-w '\n%{http_code}'`.
if [[ "$method" == "PUT" ]]; then
  case "$path" in
    proxies/*)
      printf '%s' "$body" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' >"$state" ;;
  esac
  ((want_code)) && printf '\n204'
fi
