# infra-tools

<p align="center">
  <a href="./README.md">English</a> |
  <b>简体中文</b>
</p>

面向共享 Linux / GPU 服务器的终端看板与一键安装脚本。

全部使用纯 Bash，依赖极少，SSH 登上一台新机器即可使用。安装器会自动识别发行版
与包管理器；看板在不支持的平台上会有清晰的降级提示，而不是直接崩溃。

## 仓库结构

```
install-fast/       一键环境安装与 agent 安装器
  common.sh           安装器共用逻辑
  install-user.sh     用户态安装（无需 root）
  install-root.sh     系统级安装（自动 sudo）
  install-agent.sh    交互式 coding-agent / harness 安装器
  install-mihomo.sh   mihomo（Clash Meta）代理安装器
tools/              只读终端看板
  cpu-board.sh        CPU / NUMA / 进程看板
  gpu-board.sh        NVIDIA GPU 看板
  docker-board.sh     Docker 看板（含 owner 推断）
  install-aliases.sh  为看板安装 shell 别名（.bashrc / .zshrc）
tools/lib/
  platform.sh         Linux + macOS 可移植层（被看板 source）
monitor/             cron 驱动的节点监控：采样、归档、本地看板
  bin/collect.py      一次采样：GPU、进程、CPU、内存、磁盘
  bin/archive.py      每日汇总、采样缺口、超期转 .gz
  bin/dashboard.py    127.0.0.1:8899 上的只读看板
  install.sh          装到 ~/gpu-monitor，可选写入 crontab
  docs/schema.md      稳定的样本字段契约
  README.md           完整使用手册
qgpu/               自完备的 GPU 作业队列（Python 3 标准库 + nvidia-smi）
  qgpu.py             命令行：submit / list / show / logs / cancel / start / stop
  scheduler.py        后台调度器：寻找空闲卡并启动作业
  common.py           配置、状态目录、SQLite、nvidia-smi 查询
  install.sh          复制到私有目录并在 PATH 上放 `qgpu` 启动器
  qgpu, run.sh, stop.sh  直接跑仓库内代码用的启动脚本
  README.md           完整使用手册
```

## 平台支持

| 组件 | Linux（各主流发行版） | macOS |
|------|:---:|:---:|
| `install-fast/*` | 支持（apt / dnf / yum / pacman） | 支持（Homebrew） |
| `tools/cpu-board.sh` | 支持 | 仅整体 CPU（无 NUMA / 逐核热力图） |
| `tools/gpu-board.sh` | 支持（需 `nvidia-smi`） | 不适用（无 NVIDIA `nvidia-smi`） |
| `tools/docker-board.sh` | 支持 | 支持（Docker Desktop） |
| `tools/install-aliases.sh` | 支持 | 支持 |
| `monitor/` | 支持（需 `python3`；GPU 字段需 `nvidia-smi`） | 支持（GPU 字段为 `null`） |
| `qgpu/` | 支持（需 `python3` + `nvidia-smi`） | 不适用（无 NVIDIA `nvidia-smi`） |

架构：`x86_64` / `amd64` 与 `aarch64` / `arm64`。

安装器除了自身安装的内容外不额外依赖 `jq`/`python`；`docker-board.sh` 需要
`docker` + `jq`。

## install-fast

### 1. 环境安装器

幂等地安装常用开发工具链（可反复运行）。

```bash
# 用户态，无需 root
./install-fast/install-user.sh

# 系统级；非 root 时会自动用 sudo 重新执行
sudo ./install-fast/install-root.sh

# 只预览、不做任何改动
./install-fast/install-user.sh --dry-run
```

分组（默认全装）：

| 分组 | 内容 |
|------|------|
| `base` | git、curl、wget、unzip、zip、ca-certificates、jq |
| `cli` | tree、ripgrep（`rg`）、fd、fzf、tmux、htop |
| `dev` | g++ / build-essential、make、gdb、cmake、ninja、pkg-config |
| `python` | uv + conda（Miniforge，自带 `mamba`） |
| `vcs` | gh（GitHub CLI）+ glab（GitLab CLI），装到 `~/.local/bin` |
| `qgpu` | 个人 GPU 作业队列命令行（见下文） |
| `monitor` | cron 驱动的节点监控 + 本地看板（见下文） |

参数：

| 参数 | 说明 |
|------|------|
| `--only GROUPS` | 只安装这些分组（逗号分隔） |
| `--skip GROUPS` | 从默认集合中去掉这些分组 |
| `--dry-run` | 只打印将要执行的操作 |
| `--no-mirror` | 不写入 pip / uv / conda / HuggingFace 中国镜像，同时关闭 GitHub 下载镜像 |
| `--use-sudo` | （用户态）允许用 sudo 安装系统包 |
| `--no-color` | 关闭 ANSI 颜色 |
| `--list` | 列出分组 |
| `-h`、`--help` | 帮助 |

行为要点：

- **幂等** —— 每个工具安装前都会检测，已装则跳过。
- **用户态优先** —— `uv`、`conda`、`rg`、`fd`、`fzf`、`jq` 装到
  `~/.local/bin`（或 `~/miniforge3`）；必须走系统包管理器的会给出确切命令。
- **托管 `PATH` 块** —— 用 `>>> install-fast >>>` 标记写入，绝不覆盖你已有的 shell 配置。
- **中国镜像** —— 默认写 pip / uv / conda / HuggingFace 镜像（`--no-mirror` 可关闭）；
  apt 源不动。
- **Miniforge 走国内镜像站** —— 官方 `github.com/.../latest/download` 在国内实测只有
  13 KB/s，128 MB 安装包要下一个多小时，看起来就像卡死。`install_conda()` 现在先试
  北外 / 清华 / 南大（它们把 release 原样同步到国内，实测 ~13 MB/s），下载后用官方
  发布的 `.sha256` 校验再执行；GitHub 只作兜底。
- **GitHub 兜底链路** —— 先直连；10 秒内速度低于 1 KB/s 或连不上时，依次改用
  `gh-proxy.com`、`ghfast.top`。可用 `GH_MIRROR=<前缀>` / `GH_MIRRORS="a b"` 覆盖，
  `GH_MIRROR_FIRST=1` 镜像优先，`--no-mirror` 或 `DISABLE_GH_MIRROR=1` 完全关闭。

### 2. 仓库命令行（gh / glab）

`--only vcs`（包含在默认集合里）把两个 forge 命令行工具作为单文件二进制装进
`~/.local/bin`，不需要 root，也不用额外加 apt 源：

```bash
./install-fast/install-user.sh --only vcs
gh --version && glab --version
gh auth login        # 每个账户只需一次
```

- **gh** —— 从 `api.github.com/repos/cli/cli/releases/latest` 解析最新 release，走 GitHub
  镜像链下载且镜像优先（直连 ~13 KB/s，`gh-proxy.com` ~90 KB/s）。
- **glab** —— 它的发布仓库在 **gitlab.com**（GitHub 上的 `gitlab-org/cli` 已 404），
  因此改用 GitLab releases API 解析，直接从 `gitlab.com` 下载，不走 GitHub 镜像。
- 两者在 release API 取不到时都回落到写死的版本；已经在 `PATH` 上时直接跳过。
- macOS：交给 Homebrew（`brew install gh glab`）。

登录**故意不做自动化**：凭据属于个人，不该由共享服务器上的安装器代管。

### 3. Agent / harness 安装器

默认交互式：列出支持的 agent，询问要装哪些，然后安装所选内容。

```bash
./install-fast/install-agent.sh                 # 交互菜单
./install-fast/install-agent.sh --all
./install-fast/install-agent.sh --agents claude,opencode,kimi
./install-fast/install-agent.sh --list
./install-fast/install-agent.sh --agents all --dry-run
```

在提示处输入编号或键名，用逗号分隔（`1,4,6` 或 `claude,pi`），`all` 表示全部，
`q` 退出。

| 键名 | Agent | npm 包 | 命令 |
|------|-------|--------|------|
| `claude` | Claude Code | `@anthropic-ai/claude-code` | `claude` |
| `codex` | Codex CLI | `@openai/codex` | `codex` |
| `gemini` | Gemini CLI | `@google/gemini-cli` | `gemini` |
| `opencode` | OpenCode | `opencode-ai` | `opencode` |
| `qwen` | Qwen Code | `@qwen-code/qwen-code` | `qwen` |
| `kimi` | Kimi Code CLI | `@moonshot-ai/kimi-code` | `kimi` |
| `pi` | Pi Coding Agent | `@earendil-works/pi-coding-agent` | `pi` |
| `dsh` | DeepSeek Harness | `@deepseek-ai/dsh` | `dsh`（预发布） |

缺少 Node/npm 时，会用 `fnm` 在用户态引导安装 Node（失败再回退到 conda）。由于
部分网络下 `fnm.vercel.app` 很慢/被墙，安装器改从 GitHub release 取 fnm 二进制，
Node 本体走 `npmmirror.com`。

### 4. mihomo 代理安装器

把 [mihomo](https://github.com/MetaCubeX/mihomo)（Clash Meta）装进一个配置目录，
并生成控制脚本和 shell 代理环境。

```bash
./install-fast/install-mihomo.sh                     # 装到 ~/Mihomo
./install-fast/install-mihomo.sh --start             # 装完即启动
./install-fast/install-mihomo.sh --config-url 'https://.../sub' --force-config
./install-fast/install-mihomo.sh --proxy http://127.0.0.1:17890 --port 17890
```

默认目录：用户态 `~/Mihomo`，root 态 `/etc/mihomo`：

```
mihomo         发布二进制
config.yaml    最小模板，或你的订阅配置
proxy-env.sh   source 后导出 HTTP(S)_PROXY / ALL_PROXY
mihomoctl      start | stop | restart | status
```

参数：`--dir`、`--port`、`--controller-port`、`--config-url`、`--force-config`、
`--version`、`--proxy`、`--with-service`、`--start`、`--dry-run`、`--no-color`。

```bash
source ~/Mihomo/proxy-env.sh
~/Mihomo/mihomoctl start
# 让 github.com 的 git 走该代理：
git config --global http.https://github.com/.proxy http://127.0.0.1:17890
```

`mihomoctl start` 只在代理真正开始监听后才报成功。如果端口已被占用——共享服务器上
别人已经在 17890 跑了一个代理，这是常见情况——它会停掉这个半死的进程、打印原因和
日志路径，并以非零退出码结束，而不是假装启动成功：

```
mihomo start FAILED: port 17890 is already in use by another process
  hint: stop the process using 127.0.0.1:17890, or re-run install-mihomo.sh with a different --port
```

`mihomoctl status` 遵循同一规则：进程活着但端口没在监听时，报告
`mihomo NOT working`（退出码 1）。多人共用一台机器时，请用 `--port` 选一个空闲端口。

## tools

只读看板。通用参数：

```
-w, --watch [SECONDS]   持续刷新（默认 2 秒）
    --once              只打印一次并退出（默认）
    --no-color          关闭 ANSI 颜色
-h, --help              帮助
```

### cpu-board.sh

```bash
tools/cpu-board.sh
tools/cpu-board.sh --watch 1 --top 15
NO_COLOR=1 tools/cpu-board.sh --ascii
```

展示 NUMA 节点、逐逻辑核热力图、内存 / swap、Top 用户与 Top 进程。macOS 上没有
NUMA / 逐核热力图，改为显示整体 CPU。

### gpu-board.sh

```bash
tools/gpu-board.sh
tools/gpu-board.sh --watch
tools/gpu-board.sh --ascii
```

展示每张 GPU 的利用率、显存、温度、功耗、P-State 与风扇，以及各 GPU 上的计算进程
（当前用户会高亮）。

### docker-board.sh

```bash
tools/docker-board.sh
tools/docker-board.sh --all
tools/docker-board.sh --sidecars
tools/docker-board.sh -w 2
tools/docker-board.sh CONTAINER     # 单个容器的详细信息
```

展示容器状态、CPU / 内存，以及推断出的宿主 `OWNER`（Docker 不记录谁启动的容器，
owner 由 Compose 工作目录和 bind mount 路径推断）。默认隐藏 Harbor 网络 sidecar。

采集是批量做的：无论有多少容器，只调用一次 `docker ps`、一次 `docker ps -a`、
一次 `docker stats` 和一次批量 `docker inspect`。因此在繁忙的共享宿主上从“分钟级”
变成“秒级”——实测 716 个运行中容器：93s → 9.6s；`--all` 覆盖 3019 个容器时：
340s → 14s。剩下的耗时来自 `docker stats --no-stream` 本身，所以在 700 容器的
宿主上 `-w 2` 的实际刷新周期由它决定（约 10s），而不是由间隔参数决定。

### install-aliases.sh

安装 `ccc`（CPU）/ `ggg`（GPU）/ `ddd`（Docker）别名，让看板可以在任意目录直接运行。
别名总是写入 `~/.bashrc`；当登录 shell 是 zsh 或 `~/.zshrc` 已存在时，也会同时写入
`~/.zshrc`。

```bash
tools/install-aliases.sh            # 安装 / 刷新别名
tools/install-aliases.sh --remove   # 移除别名
```

别名放在 `# >>> infra-tools >>>` 托管块中，每次运行都会整体替换该块：移动仓库目录后
重新运行即可刷新路径，其余 shell 配置不会被改动。安装后开一个新终端（或
`source ~/.bashrc`）即可使用。

## monitor

`tools/gpu-board.sh` 回答“此刻在发生什么”；`monitor/` 回答“过去 24 小时发生了什么”，
而且把答案留在了磁盘上：cron 每分钟采样一次、每日归档、一个只读网页看板。
纯标准库，无数据库，无守护进程。

本目录是原独立仓库 [`gpu-monitor`](https://github.com/Tensofermi/gpu-monitor)
的归档位置（该仓库已并入 infra-tools）。

```bash
./monitor/install.sh gpu-01           # 装到 ~/gpu-monitor
./monitor/install.sh gpu-01 --cron    # 顺便写入 crontab（幂等）

~/gpu-monitor/collect.sh              # 立刻采一个样
~/gpu-monitor/status.sh               # 一行摘要
~/gpu-monitor/dashboard-start.sh      # http://127.0.0.1:8899/
```

远端机器：先 `ssh -L 8899:127.0.0.1:8899 <host>`，再在本机浏览器打开
`http://127.0.0.1:8899/`。看板默认只监听回环地址。

```
cron(每分钟) ─→ collect.py ─→ data/samples/<UTC 日>.jsonl
                             data/latest.json
cron(每天)   ─→ archive.py ─→ data/archives/<日>.summary.json
手动          ─→ dashboard.py ─→ 127.0.0.1:8899
```

选项：`--cron`、`--prefix DIR`、`--retention DAYS`、`--dry-run`、`--help`。
配置是 `~/gpu-monitor/env` 里的环境变量（`MONITOR_MACHINE`、`MONITOR_HOME`、
`MONITOR_DATA_DIR`、`MONITOR_RETENTION_DAYS`、`MONITOR_HOST`、`MONITOR_PORT`）。

读不到的值一律写 `null` 而不是 `0`；采样缺口如实记录而不插值；进程命令行落盘前先脱敏。
完整手册、样本 schema 以及从旧 `gpu-monitor` 布局迁移的步骤见
[`monitor/README.md`](./monitor/README.md) 与
[`monitor/docs/schema.md`](./monitor/docs/schema.md)。

## qgpu

一个自完备的 GPU 作业队列，服务对象正是这些安装器准备的共享服务器。提交命令后，
后台调度器在真正空闲的 NVIDIA 卡上启动它，`CUDA_VISIBLE_DEVICES` 已自动设好。
只依赖 `python3`（标准库）与 `nvidia-smi`。

不绑定任何特定机器：每一轮调度都会重新从 `nvidia-smi` 发现 GPU 池，因此任意卡数、
混合型号、不连续编号、甚至换机后卡变少都能正常工作。只有当某张卡上没有任何用户的
计算进程、且显存占用低于 `free_memory_mib` 时，才视为空闲。

```bash
./install-fast/install-user.sh --only qgpu   # 安装 `qgpu` 启动器
qgpu detect                                  # 看 nvidia-smi 能看到什么
qgpu start                                   # 启动调度器

qgpu submit --name L12 -- python train.py    # 提交作业
qgpu list                                    # 查看队列
qgpu logs -f 12                              # 跟踪 job 12 日志
qgpu status                                  # 调度器状态 + 每卡概览
```

| 命令 | 作用 |
|------|------|
| `start` / `stop` | 启动 / 停止调度器（`stop` 不会杀掉运行中的作业） |
| `status` / `detect` | 队列与 GPU 概览 / `nvidia-smi` 原始清单 |
| `submit`（`sb`） | 提交作业；`--gpus N`、`--gpu-ids 5,6`、`--cwd`、`--env K=V` |
| `list`（`ls`）/ `show ID` | 最近作业 / 单个作业详情 |
| `logs ID [-f]` | 跟踪作业日志 |
| `cancel ID` / `retry ID` | 取消作业 / 重新提交已结束作业 |
| `promote ID` / `demote ID` | 把 pending 作业移到队首 / 队尾 |
| `config` | 查看或修改 `max_gpus`、`gpu_pool`、`poll_seconds`、`free_memory_mib` |

默认配置（`max_gpus: 0` 表示按池大小自动，`gpu_pool: []` 表示全部可见 GPU）：

```json
{
  "max_gpus": 0,
  "gpu_pool": [],
  "poll_seconds": 2.0,
  "free_memory_mib": 1024
}
```

状态与代码分离，放在 `$QGPU_HOME`（默认 `~/.local/state/qgpu`）；
`qgpu/install.sh` 把代码复制到私有目录（`~/.local/share/qgpu`），并在
`~/.local/bin` 放启动器，因此仓库被移动或删除也不影响使用。
`qgpu/install.sh --remove` 可卸载，且不会删除作业数据库。

完整手册：[qgpu/README.md](./qgpu/README.md)。

## 设计原则

- 纯 Bash、依赖极少，读看板不需要 root。
- 可选组件（`qgpu`、`monitor`）保持自完备：只用标准库、私有状态目录（不在仓库内），
  可整体卸载而不污染宿主。
- 检测平台与包管理器，而不是假设某个发行版。
- 优雅降级 —— 打印清晰的“此处不支持”，而不是报错。
- 安装器幂等；托管配置块不会覆盖你的原有配置。