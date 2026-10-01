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
tools/              只读终端看板
  cpu-board.sh        CPU / NUMA / 进程看板
  gpu-board.sh        NVIDIA GPU 看板
  docker-board.sh     Docker 看板（含 owner 推断）
tools/lib/
  platform.sh         Linux + macOS 可移植层（被看板 source）
```

## 平台支持

| 组件 | Linux（各主流发行版） | macOS |
|------|:---:|:---:|
| `install-fast/*` | 支持（apt / dnf / yum / pacman） | 支持（Homebrew） |
| `tools/cpu-board.sh` | 支持 | 仅整体 CPU（无 NUMA / 逐核热力图） |
| `tools/gpu-board.sh` | 支持（需 `nvidia-smi`） | 不适用（无 NVIDIA `nvidia-smi`） |
| `tools/docker-board.sh` | 支持 | 支持（Docker Desktop） |

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

参数：

| 参数 | 说明 |
|------|------|
| `--only GROUPS` | 只安装这些分组（逗号分隔） |
| `--skip GROUPS` | 从默认集合中去掉这些分组 |
| `--dry-run` | 只打印将要执行的操作 |
| `--no-mirror` | 不写入 pip / uv / conda / HuggingFace 中国镜像 |
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

### 2. Agent / harness 安装器

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

## 设计原则

- 纯 Bash、依赖极少，读看板不需要 root。
- 检测平台与包管理器，而不是假设某个发行版。
- 优雅降级 —— 打印清晰的“此处不支持”，而不是报错。
- 安装器幂等；托管配置块不会覆盖你的原有配置。