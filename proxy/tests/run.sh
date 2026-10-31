#!/usr/bin/env bash
# Self-contained tests for the proxy CLI (proxy/). No network, no mihomo, no
# root: the controller JSON comes from tests/stub-curl.sh and the mihomo
# instance is a throwaway directory.
#
#   ./proxy/tests/run.sh
#
# Exit code 0 = all good.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROXY="${HERE}/../proxy"
INSTALL="${HERE}/../install.sh"
STUB_SRC="${HERE}/stub-curl.sh"

ok_n=0
fail_n=0
TMP=""
SLEEP_PID=""

ok()   { ok_n=$((ok_n + 1)); printf '  \033[32mok\033[0m   %s\n' "$*"; }
fail() { fail_n=$((fail_n + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
case_start() { printf '\n%s\n' "==> $*"; }

check_eq() { # desc expected actual
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1"; printf '       期望: %s\n       实际: %s\n' "$2" "$3"; fi
}
check_contains() { # desc needle haystack
  if [[ "$3" == *"$2"* ]]; then ok "$1"; else fail "$1"; printf '       缺少: %s\n' "$2"; fi
}
check_absent() { # desc needle haystack
  if [[ "$3" != *"$2"* ]]; then ok "$1"; else fail "$1"; printf '       出现了: %s\n' "$2"; fi
}
check_rc() { # desc expected actual
  if [[ "$2" == "$3" ]]; then ok "$1 (rc=$3)"; else fail "$1 (rc=$3, 期望 $2)"; fi
}

setup() {
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/Mihomo" "$TMP/bin" "$TMP/home"
  DIR="$TMP/Mihomo"
  printf 'mixed-port: 17890\nexternal-controller: 127.0.0.1:19090\n' >"${DIR}/config.yaml"
  printf '#!/bin/sh\necho "Mihomo v1.19.33 test"\n' >"${DIR}/mihomo"
  printf '#!/bin/sh\nexit 0\n' >"${DIR}/mihomoctl"
  chmod +x "${DIR}/mihomo" "${DIR}/mihomoctl"
  sleep 300 &
  SLEEP_PID=$!
  printf '%s\n' "$SLEEP_PID" >"${DIR}/mihomo.pid"
  ln -s "$STUB_SRC" "$TMP/bin/curl"
  export PATH="$TMP/bin:$PATH"
  export STUB_LOG="${TMP}/curl.log"
  export STUB_STATE="${TMP}/stub.state"
  reset_stub
  export MIHOMO_DIR="$DIR"
  export PROXY_MAIN_GROUP="Main"
}

teardown() {
  [[ -n "$SLEEP_PID" ]] && kill "$SLEEP_PID" 2>/dev/null
  [[ -n "$TMP" ]] && rm -rf "$TMP"
  TMP=""
}
trap teardown EXIT

pr() { "$PROXY" "$@"; }
reset_stub() { : >"$STUB_LOG"; rm -f "$STUB_STATE"; }

# One instance + stub PATH for every case below.
setup

# --------------------------------------------------------------- emit_env -----
case_start "emit_env：干净 shell（无 NO_PROXY）也必须完整输出"
# 回归：heredoc 里引用 \$NO_PROXY 曾在 set -u 下让整个函数静默失败。
out="$(env -u NO_PROXY -u no_proxy -u HTTPS_PROXY -u http_proxy \
  MIHOMO_DIR="$DIR" bash "$PROXY" env 2>"${TMP}/err")"
check_rc "proxy env 退出码" 0 "$?"
check_eq "export 行数" 8 "$(printf '%s\n' "$out" | grep -c '^export ')"
check_absent "stderr 无 unbound variable" "unbound variable" "$(cat "${TMP}/err")"
check_contains "HTTPS_PROXY 指向本实例端口" 'HTTPS_PROXY="http://127.0.0.1:17890"' "$out"
check_eq "no_proxy 与 NO_PROXY 一致" \
  "$(printf '%s\n' "$out" | sed -n 's/^export NO_PROXY="\(.*\)"$/\1/p')" \
  "$(printf '%s\n' "$out" | sed -n 's/^export no_proxy="\(.*\)"$/\1/p')"

case_start "emit_env：NO_PROXY 组成"
base="$(env -u NO_PROXY MIHOMO_DIR="$DIR" bash "$PROXY" env)"
check_contains "默认绕过回环" "127.0.0.1" "$base"
check_contains "默认绕过国内镜像" ".npmmirror.com" "$base"
check_absent "公共仓库不含厂内域名" ".gewu-lab.ai" "$base"
extra="$(PROXY_NO_PROXY=".corp.example,10.1.0.0/16" MIHOMO_DIR="$DIR" bash "$PROXY" env)"
check_contains "PROXY_NO_PROXY 追加" ".corp.example" "$extra"
check_contains "PROXY_NO_PROXY 追加（第二个）" "10.1.0.0/16" "$extra"
ncn="$(PROXY_NO_CN_MIRRORS=0 MIHOMO_DIR="$DIR" bash "$PROXY" env)"
check_absent "PROXY_NO_CN_MIRRORS=0 时不绕过镜像" ".npmmirror.com" "$ncn"
check_contains "PROXY_NO_CN_MIRRORS=0 仍绕过回环" "127.0.0.1" "$ncn"

# ------------------------------------------------------------ controller ------
case_start "nodes / node：信息条目不能当节点"
reset_stub
out="$(pr nodes 2>&1)"; rc=$?
check_rc "proxy nodes 退出码" 0 "$rc"
check_contains "列出真实节点" "hk-01" "$out"
check_absent "不列出“剩余流量”" "剩余流量" "$out"
check_absent "不列出“套餐到期”" "套餐到期" "$out"
check_absent "不列出“过滤掉”" "过滤掉" "$out"
# 编号与 proxy node 的索引必须一致：1=Auto 2=hk-01 3=jp-02（信息条目已移除）
check_contains "编号从 1 开始且第 1 项是 Auto" "1) Auto" "$out"
check_contains "第 3 项是 jp-02" "3) jp-02" "$out"

reset_stub
pr node 2 >/dev/null 2>&1; rc=$?
check_rc "proxy node 2" 0 "$rc"
check_contains "编号 2 切到 hk-01" '"name": "hk-01"' "$(cat "$STUB_LOG")"
check_absent "切换目标不是信息条目" "剩余流量" "$(cat "$STUB_LOG")"

reset_stub
out="$(pr node 剩余流量 2>&1)"; rc=$?
check_rc "选中信息条目应失败" 2 "$rc"
check_absent "没有发出切换请求" "PUT" "$(cat "$STUB_LOG")"

case_start "selected_chain：组名不写死，嵌套自动展开"
reset_stub
out="$(pr status 2>&1)"
check_contains "嵌套组自动展开" "Auto → hk-01" "$out"

case_start "pick：组内延迟全 0 时回退到探测到的 url-test 组"
reset_stub
out="$(STUB_ZERO_DELAYS=1 pr pick 2>&1)"; rc=$?
check_rc "proxy pick 退出码" 0 "$rc"
check_contains "回退目标是 Auto" '"name": "Auto"' "$(cat "$STUB_LOG")"
check_absent "回退不会去下载测速" "github.com" "$(cat "$STUB_LOG")"

case_start "secret：走 stdin 而不是命令行"
printf 'mixed-port: 17890\nexternal-controller: 127.0.0.1:19090\nsecret: "tok en"\n' \
  >"${DIR}/config.yaml"
reset_stub
pr node 2 >/dev/null 2>&1
check_contains "header 通过 -H @- 传入（含空格）" "Authorization: Bearer tok en" "$(cat "$STUB_LOG")"
printf 'mixed-port: 17890\nexternal-controller: 127.0.0.1:19090\n' >"${DIR}/config.yaml"

case_start "help：文档列出新增的变量"
out="$(pr help 2>&1)"
check_contains "PROXY_AUTO_GROUP" "PROXY_AUTO_GROUP" "$out"
check_contains "PROXY_NO_PROXY" "PROXY_NO_PROXY" "$out"
check_contains "PROXY_SUB_INSECURE" "PROXY_SUB_INSECURE" "$out"

# ----------------------------------------------------------------- shell ------
case_start "proxy-shell：toggle 的两个方向都不许误报"
printf '#!/bin/bash\necho "unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy"\n' >"${TMP}/cli_off"
printf '#!/bin/bash\necho "export HTTPS_PROXY=http://127.0.0.1:17890"\n' >"${TMP}/cli_on"
printf '#!/bin/sh\nexit 0\n' >"${TMP}/cli_silent"
chmod +x "${TMP}"/cli_off "${TMP}"/cli_on "${TMP}"/cli_silent

rc="$(PROXY_CLI_BIN="${TMP}/cli_off" bash -c '
  . "'"${HERE}"'/../proxy-shell.sh"
  export HTTPS_PROXY=http://old
  proxy toggle >/dev/null 2>&1; printf "%s|%s" "$?" "${HTTPS_PROXY:-}"')"
check_eq "toggle→off：rc=0 且已清空" "0|" "$rc"

rc="$(PROXY_CLI_BIN="${TMP}/cli_on" bash -c '
  . "'"${HERE}"'/../proxy-shell.sh"
  proxy toggle >/dev/null 2>&1; printf "%s|%s" "$?" "${HTTPS_PROXY:-}"')"
check_eq "toggle→on：rc=0 且已设置" "0|http://127.0.0.1:17890" "$rc"

rc="$(PROXY_CLI_BIN="${TMP}/cli_silent" bash -c '
  . "'"${HERE}"'/../proxy-shell.sh"
  proxy on >/dev/null 2>&1; printf "%s" "$?"')"
check_eq "空输出必须报错（静默失败回归）" "1" "$rc"

rc="$(PROXY_CLI_BIN="${TMP}/cli_on" bash -c '
  . "'"${HERE}"'/../proxy-shell.sh"
  export HTTPS_PROXY=http://old
  proxy off >/dev/null 2>&1; printf "%s" "$?"')"
check_eq "off 没清掉环境时必须报错" "1" "$rc"

# ----------------------------------------------------------------- update -----
case_start "update：默认校验证书、保留 secret/端口、失败回滚"
cat >"${TMP}/sub.txt" <<'SUBFILE'
https://sub.example/api/v1/client/subscribe?token=abc
SUBFILE
cat >"${TMP}/new-config.yaml" <<'NEWCONF'
mixed-port: 9999
external-controller: 0.0.0.0:9999
proxies:
    - { name: "new-01", type: ss, server: 1.2.3.4, port: 443, cipher: aes-128-gcm, password: x }
proxy-groups: []
rules:
  - MATCH,DIRECT
NEWCONF
printf 'mixed-port: 17890\nbind-address: 127.0.0.1\nexternal-controller: 127.0.0.1:19090\nsecret: keepme\n' \
  >"${DIR}/config.yaml"
reset_stub
: >"${TMP}/argv.log"
out="$(STUB_SUB_FILE="${TMP}/new-config.yaml" STUB_ARGV_LOG="${TMP}/argv.log" \
  PROXY_SUB_FILE="${TMP}/sub.txt" pr update 2>&1)"; rc=$?
check_rc "proxy update 退出码" 0 "$rc"
check_contains "订阅内容写进去了" 'name: "new-01"' "$(cat "${DIR}/config.yaml")"
check_absent "订阅里的端口被丢掉" "9999" "$(cat "${DIR}/config.yaml")"
check_contains "mixed-port 保留" "mixed-port: 17890" "$(cat "${DIR}/config.yaml")"
check_contains "controller 保留" "external-controller: 127.0.0.1:19090" "$(cat "${DIR}/config.yaml")"
check_contains "secret 保留" "secret: keepme" "$(cat "${DIR}/config.yaml")"
check_absent "默认不加 -k（-fsSL）" "-k" " $(cat "${TMP}/argv.log") "
check_eq "留了备份" 1 "$(ls "${DIR}"/config.yaml.bak.* 2>/dev/null | wc -l)"

reset_stub
: >"${TMP}/argv.insecure"
STUB_SUB_FILE="${TMP}/new-config.yaml" STUB_ARGV_LOG="${TMP}/argv.insecure" \
  PROXY_SUB_FILE="${TMP}/sub.txt" PROXY_SUB_INSECURE=1 pr update >/dev/null 2>&1
check_contains "PROXY_SUB_INSECURE=1 才加 -k" "-k" " $(cat "${TMP}/argv.insecure") "

case_start "update：新配置校验失败必须回滚"
printf 'mixed-port: 17890\nexternal-controller: 127.0.0.1:19090\nsecret: keepme\n' >"${DIR}/config.yaml"
cp "${DIR}/config.yaml" "${TMP}/before.yaml"
printf '#!/bin/sh\nexit 1\n' >"${DIR}/mihomo"; chmod +x "${DIR}/mihomo"
reset_stub
out="$(STUB_SUB_FILE="${TMP}/new-config.yaml" PROXY_SUB_FILE="${TMP}/sub.txt" pr update 2>&1)"; rc=$?
check_rc "校验失败时非 0 退出" 1 "$rc"
check_eq "config.yaml 已回滚" "$(cat "${TMP}/before.yaml")" "$(cat "${DIR}/config.yaml")"
printf '#!/bin/sh\necho "Mihomo v1.19.33 test"\n' >"${DIR}/mihomo"; chmod +x "${DIR}/mihomo"

# ---------------------------------------------------------------- install -----
case_start "install.sh：托管区块、幂等、legacy 迁移、权限保留"
H="$TMP/home"
printf 'line1\n# >>> proxy cli (mihomo) >>>\nold line\n# <<< proxy cli (mihomo) <<<\nline2\n' >"${H}/.bashrc"
chmod 0640 "${H}/.bashrc"
env -u MIHOMO_DIR HOME="$H" bash "$INSTALL" >/dev/null 2>&1
check_eq "区块恰好一个" 1 "$(grep -c '^# >>> infra-tools proxy >>>' "${H}/.bashrc")"
check_eq "legacy 区块已移除" 0 "$(grep -c 'proxy cli (mihomo)' "${H}/.bashrc")"
check_eq "原有内容保留" "line1
line2" "$(grep -v '^#\|^export\|^\[ -f' "${H}/.bashrc" | sed '/^$/d')"
check_eq "权限保持 0640" 640 "$(stat -c %a "${H}/.bashrc")"
check_eq "启动器指向 prefix" "${H}/Mihomo/proxy" "$(readlink "${H}/.local/bin/proxy")"

env -u MIHOMO_DIR HOME="$H" bash "$INSTALL" >/dev/null 2>&1
check_eq "重装仍只有一个区块" 1 "$(grep -c '^# >>> infra-tools proxy >>>' "${H}/.bashrc")"

env -u MIHOMO_DIR HOME="$H" bash "$INSTALL" --sub-file "${TMP}/sub.txt" --no-proxy ".corp.example" >/dev/null 2>&1
check_contains "--sub-file 写进区块" 'export PROXY_SUB_FILE="'"${TMP}"'/sub.txt"' "$(cat "${H}/.bashrc")"
check_contains "--no-proxy 写进区块" 'export PROXY_NO_PROXY=".corp.example"' "$(cat "${H}/.bashrc")"

case_start "install.sh：--prefix 记目录，CLI 能读回来"
env -u MIHOMO_DIR HOME="$H" bash "$INSTALL" --prefix "${TMP}/alt" --no-rc >/dev/null 2>&1
check_eq "marker 内容" "${TMP}/alt" "$(cat "${H}/.config/infra-tools/mihomo-dir")"
out="$(env -u MIHOMO_DIR HOME="$H" bash "$PROXY" help 2>&1)"
check_contains "CLI 从 marker 取实例目录" "MIHOMO_DIR=${TMP}/alt" "$out"

case_start "install.sh --remove：干净撤掉，不碰 mihomo 目录"
env -u MIHOMO_DIR env -u MIHOMO_DIR HOME="$H" bash "$INSTALL" --remove >/dev/null 2>&1
check_eq "区块已移除" 0 "$(grep -c 'infra-tools proxy' "${H}/.bashrc")"
check_eq "启动器已移除" "" "$(readlink "${H}/.local/bin/proxy" 2>/dev/null)"
check_eq "marker 已移除" "no" "$([[ -f "${H}/.config/infra-tools/mihomo-dir" ]] && echo yes || echo no)"
check_eq "原有 bashrc 内容仍在" "line1
line2" "$(grep -v '^#\|^export\|^\[ -f' "${H}/.bashrc" | sed '/^$/d')"

# ----------------------------------------------------------------- result -----
printf '\n%s\n' "----------------------------------------"
printf '通过 %d 项，失败 %d 项\n' "$ok_n" "$fail_n"
((fail_n == 0)) || exit 1
