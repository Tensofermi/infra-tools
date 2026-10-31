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
monitor/            cron-driven node monitor: samples, archives, local dashboard
  bin/collect.py      one sample: GPUs, processes, CPU, memory, disks
  bin/archive.py      daily summaries, coverage gaps, rotation to .gz
  bin/dashboard.py    read-only web view on 127.0.0.1:8899
  install.sh          install into ~/gpu-monitor, optional crontab lines
  docs/schema.md      stable sample field contract
  README.md           full manual
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
| `monitor/` | yes (needs `python3`; GPU fields need `nvidia-smi`) | yes (GPU fields stay `null`) |
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
| `vcs` | gh (GitHub CLI) + glab (GitLab CLI), into `~/.local/bin` |
| `qgpu` | per-user GPU job queue CLI (see below) |
| `monitor` | cron-driven node monitor + local dashboard (see below) |

Flags:

| Flag | Meaning |
|------|---------|
| `--only GROUPS` | install only these groups (comma list) |
| `--skip GROUPS` | remove groups from the default set |
| `--dry-run` | print what would happen |
| `--no-mirror` | skip writing pip / uv / conda / HuggingFace China mirrors, and skip the GitHub download mirrors |
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
- **Miniforge from a domestic mirror** — the official `github.com/.../latest/download`
  URL runs at ~13 KB/s from China, so the 128 MB installer used to look hung.
  `install_conda()` tries `bfsu` / `tuna` / `nju` first (they mirror the release
  byte-for-byte; measured ~13 MB/s) and verifies the published `.sha256`
  before running the script. GitHub is the fallback.
- **GitHub fallback** — direct GitHub is tried first; if a transfer stalls
  (under 1 KB/s for 10 s) or cannot connect, `download()` retries through
  `gh-proxy.com` and then `ghfast.top`. Override with `GH_MIRROR=<prefix>` /
  `GH_MIRRORS="a b"`, prefer mirrors with `GH_MIRROR_FIRST=1`, disable with
  `--no-mirror` or `DISABLE_GH_MIRROR=1`.

### 2. Repository CLIs (gh / glab)

`--only vcs` (part of the default set) installs the two forge CLIs as static
binaries into `~/.local/bin` — no root, no extra apt repository:

```bash
./install-fast/install-user.sh --only vcs
gh --version && glab --version
gh auth login        # once per account
```

- **gh** — resolved from `api.github.com/repos/cli/cli/releases/latest` through
the GitHub mirror chain, downloaded mirror-first (direct GitHub is ~13 KB/s,
`gh-proxy.com` is ~90 KB/s).
- **glab** — its release lives on **gitlab.com** (`gitlab-org/cli` does not exist
on GitHub), so it is read from the GitLab releases API and fetched directly
from `gitlab.com` — no GitHub mirror involved.
- Both fall back to a pinned version if the release API is unreachable, and both
are skipped when the binary is already on `PATH`.
- macOS: delegated to Homebrew (`brew install gh glab`).

Authentication is deliberately **not** automated: credentials belong to the
user, not to a shared installer.

### 3. Agent / harness installer

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
is fetched from GitHub releases (direct first, then the GitHub mirrors above)
and Node itself from `npmmirror.com`.

### 4. mihomo proxy installer

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

`mihomoctl start` only reports success once the proxy is really listening. If the
mixed port is already taken — common on a shared server where another account
already runs a proxy on 17890 — it stops the half-dead process, prints the
reason and the log path, and exits non-zero instead of claiming success:

```
mihomo start FAILED: port 17890 is already in use by another process
  hint: stop the process using 127.0.0.1:17890, or re-run install-mihomo.sh with a different --port
```

`mihomoctl status` follows the same rule: a live pid whose port is not listening
is reported as `mihomo NOT working` (exit 1). Pick a free port with `--port`
when several people share one machine.

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

Collection is batched: one `docker ps`, one `docker ps -a`, one `docker stats`
and a single bulk `docker inspect`, no matter how many containers exist. A busy
shared host therefore renders in seconds instead of minutes — measured on 716
running containers: 93s → 9.6s, and with `--all` over 3019 containers: 340s →
14s. What is left is `docker stats --no-stream` sampling itself, so a `-w 2`
refresh cycle on a 700-container host is bounded by that (~10s), not by the
interval.

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

## monitor

`tools/gpu-board.sh` answers "what is happening right now". `monitor/` answers
"what happened in the last 24 hours", and keeps the answer on disk: one sample a
minute from cron, daily archives, and a read-only web view. Stdlib only, no
database, no daemon.

This directory is the archived home of the former
[`gpu-monitor`](https://github.com/Tensofermi/gpu-monitor) repository.

```bash
./monitor/install.sh gpu-01           # install into ~/gpu-monitor
./monitor/install.sh gpu-01 --cron    # also add the cron lines (idempotent)

~/gpu-monitor/collect.sh              # one sample now
~/gpu-monitor/status.sh               # one-line summary
~/gpu-monitor/dashboard-start.sh      # http://127.0.0.1:8899/
```

Remote host: `ssh -L 8899:127.0.0.1:8899 <host>`, then open
`http://127.0.0.1:8899/` locally. The dashboard binds to loopback on purpose.

```
cron(1/min) ─→ collect.py ─→ data/samples/<UTC day>.jsonl
                             data/latest.json
cron(daily) ─→ archive.py ─→ data/archives/<day>.summary.json
manual      ─→ dashboard.py ─→ 127.0.0.1:8899
```

Options: `--cron`, `--prefix DIR`, `--retention DAYS`, `--dry-run`,
`--help`. Configuration is environment variables in `~/gpu-monitor/env`
(`MONITOR_MACHINE`, `MONITOR_HOME`, `MONITOR_DATA_DIR`,
`MONITOR_RETENTION_DAYS`, `MONITOR_HOST`, `MONITOR_PORT`).

A value that could not be read is stored as `null`, never `0`; sampling gaps are
reported instead of interpolated; process command lines are redacted before they
touch disk. Full manual, the sample schema and the migration notes for the old
`gpu-monitor` layout are in [`monitor/README.md`](./monitor/README.md) and
[`monitor/docs/schema.md`](./monitor/docs/schema.md).

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
- Opt-in extras (`qgpu`, `monitor`) stay self-contained: stdlib only, private
  state dir outside the repo, removable without touching the host.
- Detect the platform and package manager instead of assuming one distro.
- Degrade — print a clear "not supported here" line rather than failing.
- Idempotent installers; managed config blocks that do not overwrite yours.