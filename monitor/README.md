# monitor

单机节点监控：**GPU + CPU + 内存 + 磁盘 + GPU 进程**，每分钟一个样本，纯 Python 标准库，无依赖、无数据库、无守护进程。

这个目录是独立仓库 [`gpu-monitor`](https://github.com/Tensofermi/gpu-monitor) 的归档版本（该仓库已并入 infra-tools）。它的定位和 `tools/gpu-board.sh` 不同：

| | `tools/gpu-board.sh` | `monitor/` |
|---|---|---|
| 形态 | 终端里看一眼就走 | cron 每分钟落盘，留存历史 |
| 时间维度 | 此刻 | 最近 24h + 每日归档 |
| 数据 | 不落盘 | `data/samples/<UTC 日>.jsonl` + `latest.json` |
| 入口 | `ggg` | `http://127.0.0.1:8899/` 只读看板 |

为 GPU 服务器（H200 / B300 等）设计：装在机器上、由 cron 驱动、数据落在本地 JSONL，用一个只读的本地看板看最近 24 小时，用每日归档看历史。

```
cron(每分钟) ─→ collect.py ─→ data/samples/<UTC 日>.jsonl
                              data/latest.json
                              data/state/cpu.json
cron(每天)   ─→ archive.py ─→ data/archives/<日>.summary.json
手动          ─→ dashboard.py ─→ http://127.0.0.1:8899/
```

## 采集内容

| 类别 | 字段 | 来源 |
|---|---|---|
| GPU | 每卡利用率、显存用量、温度、功耗/功耗墙、型号、索引 | `nvidia-smi` |
| GPU 进程 | 每进程 PID、显存、用户、已运行时长、脱敏后的命令行 | `nvidia-smi` + `ps` |
| CPU | 逻辑核数、**使用率（跨运行差分，约 1 分钟平均）**、1/5/15 分钟负载 | `/proc/stat`、`os.getloadavg` |
| 内存 | 总量/已用/空闲/可用、**Swap 使用** | `free -m` |
| 磁盘 | `/ /home /data /data1 /mnt /mnt/nvme` 的用量，≥90% 记为风险 | `df -hP` |
| 派生 | 状态分级、平均/峰值利用率、总功耗、能耗估算、采样缺口 | `collect.py` / `archive.py` |

样本字段的完整契约见 [`docs/schema.md`](docs/schema.md)。

## 快速开始

```bash
# 在 infra-tools 仓库根目录
./monitor/install.sh my-host-name                 # 装到 ~/gpu-monitor
./monitor/install.sh my-host-name --cron          # 顺便写入 crontab（幂等）

# 或走统一的安装器
./install-fast/install-user.sh --only monitor
```

只跑一次看效果：

```bash
~/gpu-monitor/collect.sh
~/gpu-monitor/status.sh          # 一行摘要：状态、利用率、功耗、磁盘风险
cat ~/gpu-monitor/data/latest.json
```

启动本地看板：

```bash
~/gpu-monitor/dashboard-start.sh
# 远端机器上：ssh -L 8899:127.0.0.1:8899 <host>
# 然后本机浏览器打开 http://127.0.0.1:8899/
~/gpu-monitor/dashboard-stop.sh
```

安装器选项：

```
./monitor/install.sh [MACHINE_NAME] [options]
      --cron              also add the collect/archive crontab lines (idempotent)
      --prefix DIR        install root (default: $MONITOR_HOME or ~/gpu-monitor)
      --retention DAYS    gzip samples older than DAYS (default: 7, 0 = off)
      --dry-run           print actions without changing anything
```

## 配置

全部通过环境变量，写进 `~/gpu-monitor/env`（`install.sh` 会生成）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `MONITOR_MACHINE` | 短主机名 | 样本里的机器标识 |
| `MONITOR_HOME` | `~/gpu-monitor` | 安装根目录 |
| `MONITOR_DATA_DIR` | `$MONITOR_HOME/data` | 数据目录 |
| `MONITOR_RETENTION_DAYS` | `7` | 超过多少天的 jsonl 自动 gzip（`0` 关闭） |
| `MONITOR_HOST` / `MONITOR_PORT` | `127.0.0.1` / `8899` | 看板监听地址 |

## 数据布局

```
data/
├── latest.json                 # 最近一次样本
├── samples/2026-10-25.jsonl    # 每分钟一行，按 UTC 日切分
├── samples/2026-10-18.jsonl.gz # 超过保留期后自动压缩
├── state/cpu.json              # 上一次 /proc/stat 读数，用于算 CPU 平均
└── archives/2026-10-24.summary.json
```

安装目录里还有 `collector.lock`（防止慢采样堆叠）、`dashboard.pid`、`log/`。

## 三个设计决定

**1. 读不到就写 `null`，不写 `0`。**
`null` 是"没测到"，`0.0` 是"测到了，就是 0"。把采集失败渲染成 0% 利用率，等于在故障发生时谎报空闲。CPU 使用率在第一次运行、或遇到重启导致计数器回退时就是 `null`。

**2. 采样缺口如实记录，不插值。**
归档里的 `coverage_pct` 和 `gap_intervals` 会告诉你哪天少了多少个样本。一个只有 60% 覆盖率的"空闲日"不是空闲日。

**3. 进程命令行先脱敏再落盘。**
共享机器上，别人的 `argv` 里常有 token、密码、内网 IP。落盘前一律替换为 `[redacted]` / `[ip]`，并截断到 220 字符。

## 安全边界

- 看板默认只监听 `127.0.0.1`。要给别人看是**你的决定**，不是脚本的默认。
- 数据目录含进程信息，权限按安装用户的 umask 落盘；共享机器上建议 `chmod 700 ~/gpu-monitor`。
- 不采集、不存储任何凭据；脱敏是兜底，不是许可。

## 与上层 API 集成

`latest.json` 和 `samples/*.jsonl` 的 schema 是稳定的（`schema` 字段做版本控制），任何只读接口都可以直接消费它们：

- 同机部署：只读挂载数据目录，读文件即可
- 多机/容器部署：把 probe 改成暴露一个只读 HTTP 端点，schema 不变

`summary` 里的派生字段随时可以从 `payload` 重算，所以历史数据不会被某一次口径调整污染。

## 从旧的 gpu-monitor 仓库迁移

旧的独立仓库（`bin/gpu_local_probe.py` + `bin/dashboard_server.py` + `collect_once.sh` / `start.sh`）和这里的版本**文件名和环境变量都不同**，不能直接混用：

| 旧 | 新 |
|---|---|
| `bin/gpu_local_probe.py` | `bin/collect.py` |
| `bin/dashboard_server.py` | `bin/dashboard.py` |
| `bin/archive_daily.py` | `bin/archive.py` |
| `collect_once.sh` / `start.sh` / `stop.sh` | `collect.sh` / `dashboard-start.sh` / `dashboard-stop.sh` |
| `GPU_MONITOR_HOME` / `GPU_MONITOR_PORT` | `MONITOR_HOME` / `MONITOR_PORT` |

已经跑着旧版的机器（`crontab -l` 里是 `collect_once.sh`）按这个顺序切换：

```bash
# 1. 停掉旧看板
~/gpu-monitor/stop.sh
# 2. 删掉旧 cron 行（保留 @reboot 也行，它指向的 start.sh 会被安装器覆盖）
crontab -e
# 3. 用新安装器覆盖安装并重写 cron（幂等；会提示还残留哪些旧行）
./monitor/install.sh <host> --cron
# 4. 验证
~/gpu-monitor/collect.sh && ~/gpu-monitor/status.sh
```

旧版留下的 `data/samples/*.jsonl` 和新版 schema 兼容（`schema: 1`），历史数据不用删。
安装器不会自动删除旧文件，`bin/gpu_local_probe.py` 之类可以手动 `rm`。

## 测试

```bash
python3 -m unittest discover -s monitor/tests -v
```

## 许可证

MIT，见 [LICENSE](LICENSE)（随本目录一起从 gpu-monitor 仓库迁移）。
