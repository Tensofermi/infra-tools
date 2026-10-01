#!/usr/bin/env bash
# shellcheck disable=SC2016,SC1091,SC2034

# One-click installer for terminal coding-agent harnesses.
# Interactive by default: pick which agents to install, then it installs them.
# Node/npm are bootstrapped into user space (fnm) when missing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${MODE:-user}"

# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# ------------------------------------------------------------ agent registry --

AGENT_KEYS=(claude codex gemini opencode qwen kimi pi dsh)
AGENT_NAME=(
  "Claude Code (Anthropic)"
  "Codex CLI (OpenAI)"
  "Gemini CLI (Google)"
  "OpenCode"
  "Qwen Code"
  "Kimi Code CLI (Moonshot)"
  "Pi Coding Agent"
  "DeepSeek Harness (dsh)"
)
AGENT_PKG=(
  "@anthropic-ai/claude-code"
  "@openai/codex"
  "@google/gemini-cli"
  "opencode-ai"
  "@qwen-code/qwen-code"
  "@moonshot-ai/kimi-code"
  "@earendil-works/pi-coding-agent"
  "@deepseek-ai/dsh"
)
AGENT_BIN=(claude codex gemini opencode qwen kimi pi dsh)
AGENT_NOTE=("" "" "" "" "" "" "" "pre-release")

agent_index() {
  local key="$1" i
  for i in "${!AGENT_KEYS[@]}"; do
    [[ "${AGENT_KEYS[$i]}" == "$key" ]] && { printf '%s' "$i"; return 0; }
  done
  return 1
}

print_menu() {
  printf '\n%sAvailable agent harnesses%s\n' "$C_BOLD" "$C_RESET"
  local i note
  for i in "${!AGENT_KEYS[@]}"; do
    printf '  %2d) %-26s %s%s%s' \
      "$((i + 1))" "${AGENT_NAME[$i]}" "$C_DIM" "${AGENT_PKG[$i]}" "$C_RESET"
    note="${AGENT_NOTE[$i]}"
    [[ -n "$note" ]] && printf '  %s[%s]%s' "$C_YELLOW" "$note" "$C_RESET"
    printf '\n'
  done
  printf '\n'
}

# Turn a comma list of keys or numbers ("claude,5,pi", "all") into a key list.
parse_selection() {
  local input="$1" tok idx out="" i
  local -a toks
  if [[ "$input" == "all" || "$input" == "*" ]]; then
    for i in "${!AGENT_KEYS[@]}"; do out+="${out:+,}${AGENT_KEYS[$i]}"; done
    printf '%s' "$out"
    return 0
  fi
  IFS=',' read -ra toks <<<"$input"
  for tok in "${toks[@]}"; do
    tok="${tok//[[:space:]]/}"
    [[ -z "$tok" ]] && continue
    idx=""
    if agent_index "$tok" >/dev/null; then
      idx="$(agent_index "$tok")"
    elif [[ "$tok" =~ ^[0-9]+$ ]] && ((tok >= 1 && tok <= ${#AGENT_KEYS[@]})); then
      idx=$((tok - 1))
    else
      warn "ignoring unknown selection: $tok"
      continue
    fi
    case ",${out}," in
      *",${AGENT_KEYS[$idx]},"*) ;;
      *) out+="${out:+,}${AGENT_KEYS[$idx]}" ;;
    esac
  done
  printf '%s' "$out"
}

prompt_selection() {
  print_menu >&2
  local answer selected
  while :; do
    printf 'Select agents to install (e.g. %s1,4,6%s, %sall%s, %sq%s to quit): ' \
      "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" >&2
    IFS= read -r answer || answer=""
    case "$answer" in
      q|Q|quit|exit) printf 'Aborted.\n' >&2; exit 0 ;;
    esac
    selected="$(parse_selection "$answer")"
    if [[ -n "$selected" ]]; then
      SELECTED_KEYS="$selected"
      return 0
    fi
    warn "nothing selected, try again"
  done
}

# ------------------------------------------------------------------- node -----

extract_zip_bin() {
  local url="$1" glob="$2" name="$3" tmp bin
  tmp="$(mktemp -d)"
  log "downloading ${name}"
  if ! download "$url" "$tmp/${name}.zip"; then
    warn "download failed for ${name}"
    rm -rf "$tmp"
    return 1
  fi
  ((DRY_RUN)) && { info "would install ${name} into $BIN_DIR"; rm -rf "$tmp"; return 0; }
  if ! have unzip; then
    warn "unzip is required to install ${name}"
    rm -rf "$tmp"
    return 1
  fi
  unzip -oq "$tmp/${name}.zip" -d "$tmp" 2>/dev/null || { warn "unzip failed"; rm -rf "$tmp"; return 1; }
  bin="$(find "$tmp" -type f -name "$glob" | head -n1)"
  [[ -n "$bin" ]] || { warn "${glob} not found in archive"; rm -rf "$tmp"; return 1; }
  mkdir -p "$BIN_DIR"
  install -m 0755 "$bin" "$BIN_DIR/$name"
  rm -rf "$tmp"
}

install_fnm() {
  have fnm && return 0
  local asset
  case "$(uname -s):$(uname -m)" in
    Linux:x86_64|Linux:amd64)   asset="fnm-linux.zip" ;;
    Linux:aarch64|Linux:arm64)  asset="fnm-linux-arm64.zip" ;;
    Darwin:x86_64)              asset="fnm-macos.zip" ;;
    Darwin:arm64|Darwin:aarch64) asset="fnm-arm64.zip" ;;
    *) return 1 ;;
  esac
  extract_zip_bin "https://github.com/Schniz/fnm/releases/latest/download/${asset}" "fnm" "fnm"
}

install_node_via_conda() {
  local conda_bin=""
  have conda && conda_bin="conda"
  [[ -z "$conda_bin" && -x "$CONDA_PREFIX/bin/conda" ]] && conda_bin="$CONDA_PREFIX/bin/conda"
  [[ -n "$conda_bin" ]] || return 1
  log "falling back to conda for Node.js"
  run "$conda_bin" install -y -c conda-forge nodejs
}

ensure_node() {
  if have node && have npm; then
    info "node $(node -v 2>/dev/null) / npm $(npm -v 2>/dev/null) already available"
    return 0
  fi
  log "Node.js/npm not found; bootstrapping Node LTS in user space (fnm)"
  export FNM_DIR="${FNM_DIR:-${HOME}/.local/share/fnm}"
  export FNM_NODE_DIST_MIRROR="https://npmmirror.com/mirrors/node"
  export PATH="${BIN_DIR}:${PATH}"

  if install_fnm && have fnm; then
    if ((DRY_RUN)); then
      info "[dry-run] would run: fnm install --lts"
      return 0
    fi
    fnm install --lts || warn "fnm could not install Node"
    fnm default lts-latest 2>/dev/null || true
    local node_dir
    node_dir="$(find "$FNM_DIR/node-versions" -mindepth 1 -maxdepth 1 -type d -name 'v*' 2>/dev/null | sort -V | tail -1)"
    [[ -n "$node_dir" ]] && export PATH="${node_dir}/installation/bin:${PATH}"
  fi

  if have node && have npm; then
    info "node $(node -v) / npm $(npm -v) ready"
    return 0
  fi
  warn "fnm bootstrap failed; trying conda"
  install_node_via_conda || true
  if ! have node && [[ -x "$CONDA_PREFIX/bin/node" ]]; then
    export PATH="${CONDA_PREFIX}/bin:${PATH}"
  fi
  have node && have npm
}

# ---------------------------------------------------------------- installs ----

configure_npm_prefix() {
  local prefix="${BIN_DIR%/bin}"
  [[ "$MODE" == "root" ]] && prefix="/usr/local"
  log "npm global prefix -> $prefix"
  ((DRY_RUN)) && { info "[dry-run] npm config set prefix $prefix"; return 0; }
  npm config set prefix "$prefix" >/dev/null 2>&1 || true
}

install_one() {
  local key="$1" i name pkg bin
  i="$(agent_index "$key")" || return 0
  name="${AGENT_NAME[$i]}"; pkg="${AGENT_PKG[$i]}"; bin="${AGENT_BIN[$i]}"
  if have "$bin"; then
    info "${name} already installed ($(command -v "$bin"))"
    return 0
  fi
  log "installing ${name}  ${C_DIM}(${pkg})${C_RESET}"
  if ! run npm install -g "$pkg"; then
    warn "npm install failed for ${name}"
    return 1
  fi
  ((DRY_RUN)) && return 0
  if have "$bin"; then
    log "installed ${name} -> $(command -v "$bin")"
  else
    warn "${name} installed but '${bin}' is not on PATH yet; open a new shell"
  fi
}

write_agent_env() {
  local file="${HOME}/.bashrc"
  [[ "$MODE" == "root" ]] && file="/etc/profile.d/install-fast-agent.sh"
  local start="# >>> install-fast-agent >>>" end="# <<< install-fast-agent >>>" tmp
  log "updating agent environment in $file"
  if ((DRY_RUN)); then
    info "[dry-run] would write managed block to $file"
    return 0
  fi
  tmp="$(mktemp)"
  if [[ -f "$file" ]]; then
    awk -v s="$start" -v e="$end" '
      index($0, s) { skip = 1 }
      skip && index($0, e) { skip = 0; next }
      !skip { print }
    ' "$file" > "$tmp"
  fi
  local dir="${file%/*}"
  [[ -d "$dir" ]] || mkdir -p "$dir"
  {
    cat "$tmp"
    printf '%s\n' "$start"
    printf 'export PATH="%s:$PATH"\n' "$BIN_DIR"
    printf 'export FNM_DIR="%s/.local/share/fnm"\n' "$HOME"
    printf 'export FNM_NODE_DIST_MIRROR="https://npmmirror.com/mirrors/node"\n'
    printf 'command -v fnm >/dev/null 2>&1 && eval "$(fnm env --shell bash)"\n'
    printf '%s\n' "$end"
  } > "$file"
  rm -f "$tmp"
}

# ------------------------------------------------------------------ main ------

usage() {
  local prog="$1"
  cat <<EOF
Usage: ${prog} [options]

Interactively (or non-interactively) install terminal coding-agent harnesses.

Options:
  -a, --agents LIST   Comma list of keys or numbers (default: interactive)
                      keys: ${AGENT_KEYS[*]}
      --all           Install every supported agent
  -l, --list          List supported agents and exit
      --dry-run       Print actions without installing anything
      --no-color      Disable ANSI colors
  -h, --help          Show this help

Examples:
  ${prog}
  ${prog} --all
  ${prog} --agents claude,opencode,kimi
EOF
}

main() {
  local prog="${0##*/}"
  local choice=""
  local -a argv=("$@")
  local i=0
  while ((i < ${#argv[@]})); do
    case "${argv[$i]}" in
      -a|--agents) ((i + 1 < ${#argv[@]})) || die "--agents requires a value"; choice="${argv[$((i + 1))]}"; ((i++)) ;;
      --all)       choice="all" ;;
      -l|--list)   setup_colors; print_menu; exit 0 ;;
      --dry-run)   DRY_RUN=1 ;;
      --no-color)  DISABLE_COLOR=1 ;;
      -h|--help)   setup_colors; usage "$prog"; exit 0 ;;
      *)           die "unknown option: ${argv[$i]} (try --help)" ;;
    esac
    ((i++))
  done
  setup_colors

  local selected
  if [[ -n "$choice" ]]; then
    selected="$(parse_selection "$choice")"
  elif [[ -t 0 ]]; then
    SELECTED_KEYS=""
    prompt_selection
    selected="$SELECTED_KEYS"
  else
    die "no agents selected and stdin is not a terminal; use --agents or --all"
  fi
  [[ -n "$selected" ]] || die "no agents selected"

  printf '\n%s%sagent harness installer%s (%s mode)\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$MODE"
  local -a keys
  IFS=',' read -ra keys <<<"$selected"
  local k names=""
  for k in "${keys[@]}"; do
    i="$(agent_index "$k")" && names+="${names:+, }${AGENT_NAME[$i]}"
  done
  info "selected: ${names}"

  ensure_node || warn "continuing without a working node/npm; npm-based installs may fail"
  export PATH="${BIN_DIR}:${PATH}"
  configure_npm_prefix

  local failed=0
  for k in "${keys[@]}"; do
    install_one "$k" || failed=$((failed + 1))
  done

  write_agent_env

  printf '\n%sSummary%s\n' "$C_BOLD" "$C_RESET"
  for k in "${keys[@]}"; do
    i="$(agent_index "$k")" || continue
    if have "${AGENT_BIN[$i]}"; then
      printf '  %s%-9s%s %s\n' "$C_GREEN" "${AGENT_KEYS[$i]}" "$C_RESET" "$(command -v "${AGENT_BIN[$i]}")"
    else
      printf '  %s%-9s%s not found\n' "$C_DIM" "${AGENT_KEYS[$i]}" "$C_RESET"
    fi
  done

  printf '\n%sDone.%s ' "$C_GREEN" "$C_RESET"
  if ((failed)); then
    printf '%s%s of %s installs failed.%s ' "$C_RED" "$failed" "${#keys[@]}" "$C_RESET"
  fi
  if [[ "$MODE" != "root" ]]; then
    printf 'Open a new shell (or run: %ssource ~/.bashrc%s) to load PATH.\n' "$C_BOLD" "$C_RESET"
  else
    printf 'Open a new shell to load the agent environment.\n'
  fi
}

main "$@"