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
  install-aliases.sh  install shell aliases for the boards (.bashrc / .zshrc)
tools/lib/
  platform.sh         Linux + macOS portability shim (sourced by the boards)
qgpu/               self-contained GPU job queue (Python 3 stdlib + nvidia-smi)
  qgpu.py             CLI: submit / list / show / logs / cancel / start / stop
  scheduler.py        background scheduler; finds idle GPUs and launches jobs
  common.py           config, state dir, SQLite, nvidia-smi inventory
  install.sh          copy into a private prefix + `qgpu` launcher on PATH
  qgpu, run.sh, stop.sh  launchers for running straight from the repo
  README.md           full manual
```

## Platform support

| Component | Linux (all major distros) | macOS |
|-----------|:---:|:---:|
| `install-fast/*` | yes (apt / dnf / yum / pacman) | yes (Homebrew) |
| `tools/cpu-board.sh` | yes | overall CPU only (no NUMA / per-core heat map) |
| `tools/gpu-board.sh` | yes (needs `nvidia-smi`) | n/a (no NVIDIA `nvidia-smi`) |
| `tools/docker-board.sh` | yes | yes (Docker Desktop) |
| `tools/install-aliases.sh` | yes | yes |
| `qgpu/` | yes (needs `python3` + `nvidia-smi`) | n/a (no NVIDIA `nvidia-smi`) |

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
| `qgpu` | per-user GPU job queue CLI (see below) |

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

### install-aliases.sh

Install `ccc` (CPU) / `ggg` (GPU) / `ddd` (Docker) aliases so the boards can be
run from anywhere. The block always goes into `~/.bashrc`, and into `~/.zshrc`
as well when zsh is your login shell or the file exists.

```bash
tools/install-aliases.sh            # install / refresh the aliases
tools/install-aliases.sh --remove   # take them back out
```

The aliases live in a managed `# >>> infra-tools >>>` block that is replaced on
every run, so re-running after moving the repo refreshes the paths and your
other shell configuration is never touched. Open a new shell (or
`source ~/.bashrc`) to use them.

## qgpu

A self-contained GPU job queue, for the same shared servers the installers
prepare. Queue a command and a background scheduler starts it as soon as a
genuinely idle NVIDIA GPU exists, with `CUDA_VISIBLE_DEVICES` already set.
Requires only `python3` (stdlib) and `nvidia-smi`.

Nothing is tied to a particular host: the pool is re-discovered from
`nvidia-smi` on every scheduling round, so any card count, mixed models,
non-contiguous indices and changing hardware all work. Cards are considered
free only when no compute process from **any** user is present and used memory
is below `free_memory_mib`.

```bash
./install-fast/install-user.sh --only qgpu   # install the `qgpu` launcher
qgpu detect                                  # what does nvidia-smi see?
qgpu start                                   # start the scheduler

qgpu submit --name L12 -- python train.py    # queue a job
qgpu list                                    # see the queue
qgpu logs -f 12                              # follow job 12
qgpu status                                  # scheduler + per-GPU view
```

| Command | Meaning |
|---------|---------|
| `start` / `stop` | start / stop the scheduler (running jobs survive `stop`) |
| `status` / `detect` | queue and GPU view / raw `nvidia-smi` inventory |
| `submit` (`sb`) | queue a job; `--gpus N`, `--gpu-ids 5,6`, `--cwd`, `--env K=V` |
| `list` (`ls`) / `show ID` | recent jobs / one job in detail |
| `logs ID [-f]` | tail the per-job log |
| `cancel ID` / `retry ID` | cancel a job / re-queue a finished one |
| `promote ID` / `demote ID` | move a pending job to the front / back |
| `config` | print or change `max_gpus`, `gpu_pool`, `poll_seconds`, `free_memory_mib` |

Config defaults (`max_gpus: 0` = pool size, `gpu_pool: []` = every visible GPU):

```json
{
  "max_gpus": 0,
  "gpu_pool": [],
  "poll_seconds": 2.0,
  "free_memory_mib": 1024
}
```

State lives outside the code, in `$QGPU_HOME` (default `~/.local/state/qgpu`),
and `qgpu/install.sh` copies the code into a private prefix (`~/.local/share/qgpu`)
with a launcher in `~/.local/bin`, so the tool keeps working if the repository
moves or disappears. `qgpu/install.sh --remove` uninstalls it and leaves the
queue database alone.

Full manual: [qgpu/README.md](./qgpu/README.md).

## Design principles

- Plain Bash, minimal dependencies, no root required to read a dashboard.
- Opt-in extras (`qgpu`) stay self-contained: stdlib only, private state dir,
  removable without touching the host.
- Detect the platform and package manager instead of assuming one distro.
- Degrade — print a clear "not supported here" line rather than failing.
- Idempotent installers; managed config blocks that do not overwrite yours.