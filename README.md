# infra-tools

<p align="center">
  <b>English</b> |
  <a href="./README.zh-CN.md">简体中文</a>
</p>

Terminal dashboards and one-shot installers for shared Linux / GPU servers.

Everything is plain Bash with a tiny dependency footprint, so it works the
moment you SSH into a fresh box. The installer detects the distro and package
manager; the dashboards degrade gracefully instead of crashing on unsupported
platforms.

## Repository layout

```
install-fast/       one-click environment and agent installers
  common.sh           shared logic for the installers
  install-user.sh     user-space install (no root)
  install-root.sh     system-wide install (auto-sudo)
  install-agent.sh    interactive coding-agent / harness installer
  install-mihomo.sh   mihomo (Clash Meta) proxy installer
tools/              read-only terminal dashboards
  cpu-board.sh        CPU / NUMA / process dashboard
  gpu-board.sh        NVIDIA GPU dashboard
  docker-board.sh     Docker dashboard with owner inference
tools/lib/
  platform.sh         Linux + macOS portability shim (sourced by the boards)
```

## Platform support

| Component | Linux (all major distros) | macOS |
|-----------|:---:|:---:|
| `install-fast/*` | yes (apt / dnf / yum / pacman) | yes (Homebrew) |
| `tools/cpu-board.sh` | yes | overall CPU only (no NUMA / per-core heat map) |
| `tools/gpu-board.sh` | yes (needs `nvidia-smi`) | n/a (no NVIDIA `nvidia-smi`) |
| `tools/docker-board.sh` | yes | yes (Docker Desktop) |

Architectures: `x86_64` / `amd64` and `aarch64` / `arm64`.

The installers never require `jq`/`python` beyond what they install
themselves; `docker-board.sh` uses `docker` + `jq`.

## install-fast

### 1. Environment installer

Install the usual dev toolchain, idempotently (safe to re-run).

```bash
# user space, no root needed
./install-fast/install-user.sh

# system wide; re-executes itself with sudo when not root
sudo ./install-fast/install-root.sh

# preview actions without changing anything
./install-fast/install-user.sh --dry-run
```

Groups (default: all):

| Group | Contents |
|-------|----------|
| `base` | git, curl, wget, unzip, zip, ca-certificates, jq |
| `cli` | tree, ripgrep (`rg`), fd, fzf, tmux, htop |
| `dev` | g++ / build-essential, make, gdb, cmake, ninja, pkg-config |
| `python` | uv + conda (Miniforge, includes `mamba`) |

Flags:

| Flag | Meaning |
|------|---------|
| `--only GROUPS` | install only these groups (comma list) |
| `--skip GROUPS` | remove groups from the default set |
| `--dry-run` | print what would happen |
| `--no-mirror` | skip writing pip / uv / conda / HuggingFace China mirrors |
| `--use-sudo` | (user mode) allow sudo for system packages |
| `--no-color` | disable ANSI colors |
| `--list` | list groups |
| `-h`, `--help` | help |

Behavior highlights:

- **Idempotent** — every tool is checked before it is installed.
- **User space first** — `uv`, `conda`, `rg`, `fd`, `fzf`, `jq` go into
  `~/.local/bin` (or `~/miniforge3`); anything that needs the system package
  manager is reported with the exact command to run.
- **Managed `PATH` block** — written with `>>> install-fast >>>` markers, so it
  never clobbers existing shell configuration.
- **China mirrors** — pip / uv / conda / HuggingFace by default (`--no-mirror`
  to disable). apt sources are left untouched.

### 2. Agent / harness installer

Interactive by default: it lists the supported agents, asks which to install,
then installs the selection.

```bash
./install-fast/install-agent.sh                 # interactive menu
./install-fast/install-agent.sh --all
./install-fast/install-agent.sh --agents claude,opencode,kimi
./install-fast/install-agent.sh --list
./install-fast/install-agent.sh --agents all --dry-run
```

At the prompt, enter numbers or keys separated by commas (`1,4,6` or
`claude,pi`), `all`, or `q` to quit.

| Key | Agent | npm package | Command |
|-----|-------|-------------|---------|
| `claude` | Claude Code | `@anthropic-ai/claude-code` | `claude` |
| `codex` | Codex CLI | `@openai/codex` | `codex` |
| `gemini` | Gemini CLI | `@google/gemini-cli` | `gemini` |
| `opencode` | OpenCode | `opencode-ai` | `opencode` |
| `qwen` | Qwen Code | `@qwen-code/qwen-code` | `qwen` |
| `kimi` | Kimi Code CLI | `@moonshot-ai/kimi-code` | `kimi` |
| `pi` | Pi Coding Agent | `@earendil-works/pi-coding-agent` | `pi` |
| `dsh` | DeepSeek Harness | `@deepseek-ai/dsh` | `dsh` (pre-release) |

Node/npm are bootstrapped into user space with `fnm` when missing (falling back
to conda). Because `fnm.vercel.app` is slow/blocked in some networks, the binary
is fetched from GitHub releases and Node itself from `npmmirror.com`.

### 3. mihomo proxy installer

Install [mihomo](https://github.com/MetaCubeX/mihomo) (Clash Meta) into a config
directory, together with a control script and a shell proxy environment.

```bash
./install-fast/install-mihomo.sh                     # into ~/Mihomo
./install-fast/install-mihomo.sh --start             # install and start
./install-fast/install-mihomo.sh --config-url 'https://.../sub' --force-config
./install-fast/install-mihomo.sh --proxy http://127.0.0.1:17890 --port 17890
```

Installs into `~/Mihomo` (user) or `/etc/mihomo` (root) by default:

```
mihomo         the release binary
config.yaml    a minimal template, or your subscription config
proxy-env.sh   source it to export HTTP(S)_PROXY / ALL_PROXY
mihomoctl      start | stop | restart | status
```

Flags: `--dir`, `--port`, `--controller-port`, `--config-url`, `--force-config`,
`--version`, `--proxy`, `--with-service`, `--start`, `--dry-run`, `--no-color`.

```bash
source ~/Mihomo/proxy-env.sh
~/Mihomo/mihomoctl start
# route git for github.com through the proxy:
git config --global http.https://github.com/.proxy http://127.0.0.1:17890
```

## tools

Read-only dashboards. Common flags:

```
-w, --watch [SECONDS]   refresh continuously (default 2s)
    --once              print once and exit (default)
    --no-color          disable ANSI colors
-h, --help              help
```

### cpu-board.sh

```bash
tools/cpu-board.sh
tools/cpu-board.sh --watch 1 --top 15
NO_COLOR=1 tools/cpu-board.sh --ascii
```

Shows NUMA nodes, a per-logical-CPU heat map, memory / swap, top users and top
processes. On macOS the NUMA / per-core heat map is unavailable and the board
shows overall CPU instead.

### gpu-board.sh

```bash
tools/gpu-board.sh
tools/gpu-board.sh --watch
tools/gpu-board.sh --ascii
```

Shows per-GPU utilization, VRAM, temperature, power, P-state and fan, plus the
compute processes on each GPU (the current user is highlighted).

### docker-board.sh

```bash
tools/docker-board.sh
tools/docker-board.sh --all
tools/docker-board.sh --sidecars
tools/docker-board.sh -w 2
tools/docker-board.sh CONTAINER     # detailed view for one container
```

Shows container state, CPU / memory and an inferred host `OWNER` (Docker does
not record who ran a container; the owner is inferred from Compose working
directories and bind-mount paths). Harbor network sidecars are hidden by
default.

## Design principles

- Plain Bash, minimal dependencies, no root required to read a dashboard.
- Detect the platform and package manager instead of assuming one distro.
- Degrade — print a clear "not supported here" line rather than failing.
- Idempotent installers; managed config blocks that do not overwrite yours.