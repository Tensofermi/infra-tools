#!/usr/bin/env python3
# qGPU 的公共模块：状态目录、配置、SQLite 数据库和 NVIDIA GPU 查询。
#
# 只依赖 Python 标准库；不绑定任何特定机器、卡数或卡型号。

from __future__ import annotations

import json
import os
import sqlite3
import subprocess
from datetime import datetime
from pathlib import Path

CODE_DIR = Path(__file__).resolve().parent


class GpuUnavailable(RuntimeError):
    """nvidia-smi 不可用（没有驱动 / 没有 GPU / 命令缺失）。"""


def resolve_state_home() -> Path:
    """运行时状态目录。

    优先级：QGPU_HOME 环境变量 > 代码目录旁边已有的旧状态 > XDG 状态目录。
    状态与代码分离，因此代码可以放在任意位置，也可以被独立安装到别处。
    """
    explicit = os.environ.get("QGPU_HOME", "").strip()
    if explicit:
        return Path(explicit).expanduser().resolve()
    for legacy in ("qgpu.db", "config.json"):
        if (CODE_DIR / legacy).exists():
            return CODE_DIR
    base = os.environ.get("XDG_STATE_HOME", "").strip()
    root = Path(base).expanduser() if base else Path.home() / ".local" / "state"
    return (root / "qgpu").resolve()


ROOT = CODE_DIR  # 代码目录，scheduler.py 在这里
HOME = resolve_state_home()  # 状态目录：数据库、配置、日志、pid
DB_PATH = HOME / "qgpu.db"
CONFIG_PATH = HOME / "config.json"
LOG_DIR = HOME / "logs"
PID_PATH = HOME / "scheduler.pid"
LOCK_PATH = HOME / "scheduler.lock"
DAEMON_LOG = HOME / "scheduler.log"

# gpu_pool 为空表示自动使用 nvidia-smi 能看到的全部 GPU；
# max_gpus 为 0 表示自动取 GPU 池的大小。
DEFAULT_CONFIG = {
    "max_gpus": 0,
    "gpu_pool": [],
    "poll_seconds": 2,
    "free_memory_mib": 1024,
}


def now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


# ------------------------------------------------------------------ config ---


def load_config() -> dict:
    if not CONFIG_PATH.exists():
        save_config(dict(DEFAULT_CONFIG))
    with CONFIG_PATH.open(encoding="utf-8") as file:
        stored = json.load(file)
    merged = dict(DEFAULT_CONFIG)
    merged.update(stored)
    return validate_config(merged)


def save_config(config: dict) -> None:
    config = validate_config(config)
    HOME.mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_text(
        json.dumps(config, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def validate_config(config: dict) -> dict:
    config["max_gpus"] = int(config.get("max_gpus") or 0)
    config["gpu_pool"] = sorted({int(item) for item in (config.get("gpu_pool") or [])})
    config["poll_seconds"] = float(config.get("poll_seconds", 2))
    config["free_memory_mib"] = int(config.get("free_memory_mib", 1024))
    if config["max_gpus"] < 0:
        raise ValueError("max_gpus 不能为负数（0 表示自动）")
    if any(gpu_id < 0 for gpu_id in config["gpu_pool"]):
        raise ValueError("GPU 编号不能小于 0")
    if config["max_gpus"] and config["gpu_pool"] and config["max_gpus"] > len(config["gpu_pool"]):
        raise ValueError("max_gpus 不能大于 gpu_pool 中的 GPU 数量")
    if config["poll_seconds"] <= 0:
        raise ValueError("poll_seconds 必须大于 0")
    if config["free_memory_mib"] < 0:
        raise ValueError("free_memory_mib 不能小于 0")
    return config


def effective_config(config: dict | None = None, gpus: list[dict] | None = None) -> dict:
    """把 auto 配置解析成具体值，并与当前真实可见的 GPU 对齐。

    在只有 2 张卡的机器上使用默认配置（自动池）也能正常工作；显式 gpu_pool
    里不存在的编号会被过滤掉，max_gpus 会收敛到实际可用卡数，避免作业永远排队。
    每一步调整都会记在 notes 里，方便 qgpu status / detect 解释原因。
    """
    config = dict(load_config() if config is None else config)
    inventory = gpu_inventory() if gpus is None else gpus
    visible = [gpu["index"] for gpu in inventory]
    configured_pool = list(config["gpu_pool"])
    notes: list[str] = []
    if configured_pool:
        pool = [gpu_id for gpu_id in configured_pool if gpu_id in visible]
        missing = [gpu_id for gpu_id in configured_pool if gpu_id not in visible]
        if missing:
            notes.append(f"gpu_pool 中的 {join_ids(missing)} 当前不可见，已忽略")
        if not pool:
            pool = visible
            notes.append("配置的 gpu_pool 全部不可见，已回退到全部可见 GPU")
    else:
        pool = visible
    max_gpus = config["max_gpus"] or len(pool)
    if pool and max_gpus > len(pool):
        notes.append(f"max_gpus 由 {max_gpus} 收敛到 {len(pool)}（当前可用卡数）")
        max_gpus = len(pool)
    resolved = dict(config)
    resolved["gpu_pool"] = pool
    resolved["max_gpus"] = max_gpus
    resolved["configured_pool"] = configured_pool
    resolved["inventory"] = inventory
    resolved["notes"] = notes
    return resolved


# ---------------------------------------------------------------- database ---


def connect() -> sqlite3.Connection:
    HOME.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(DB_PATH, timeout=30)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("PRAGMA busy_timeout=30000")
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS jobs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            status TEXT NOT NULL,
            command_json TEXT NOT NULL,
            cwd TEXT NOT NULL,
            env_json TEXT NOT NULL,
            gpu_count INTEGER NOT NULL,
            requested_gpu_ids TEXT,
            assigned_gpu_ids TEXT,
            pid INTEGER,
            exit_code INTEGER,
            message TEXT,
            submitted_at TEXT NOT NULL,
            started_at TEXT,
            ended_at TEXT,
            log_path TEXT NOT NULL,
            queue_order INTEGER NOT NULL DEFAULT 0
        )
        """
    )
    columns = {
        row["name"] for row in connection.execute("PRAGMA table_info(jobs)").fetchall()
    }
    if "queue_order" not in columns:
        connection.execute(
            "ALTER TABLE jobs ADD COLUMN queue_order INTEGER NOT NULL DEFAULT 0"
        )
        connection.execute("UPDATE jobs SET queue_order = id")
    connection.commit()
    return connection


def pid_is_alive(pid: int | None) -> bool:
    if not pid:
        return False
    try:
        os.kill(pid, 0)
    except (ProcessLookupError, PermissionError):
        return False
    return True


def scheduler_pid() -> int | None:
    try:
        return int(PID_PATH.read_text(encoding="utf-8").strip())
    except (FileNotFoundError, ValueError):
        return None


# -------------------------------------------------------------------- gpu ----


def parse_gpu_ids(value: str) -> list[int]:
    ids: list[int] = []
    for part in value.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            start_text, end_text = part.split("-", 1)
            start, end = int(start_text), int(end_text)
            if end < start:
                raise ValueError(f"非法 GPU 范围：{part}")
            ids.extend(range(start, end + 1))
        else:
            ids.append(int(part))
    ids = sorted(set(ids))
    if not ids:
        raise ValueError("GPU 编号不能为空")
    if ids[0] < 0:
        raise ValueError("GPU 编号不能小于 0")
    return ids


def _nvidia_smi(query: str) -> str:
    command = ["nvidia-smi", f"--query-gpu={query}", "--format=csv,noheader,nounits"]
    try:
        result = subprocess.run(
            command,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except FileNotFoundError as exc:
        raise GpuUnavailable("找不到 nvidia-smi，请确认已安装 NVIDIA 驱动") from exc
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().splitlines()
        reason = detail[0] if detail else f"exit {result.returncode}"
        raise GpuUnavailable(f"nvidia-smi 调用失败：{reason}")
    return result.stdout


def gpu_inventory() -> list[dict]:
    """当前 nvidia-smi 能看到的所有 GPU（不做 pool 过滤）。

    字段：index / uuid / name / memory_total / memory_used / utilization / compute_pids。
    卡数、型号、编号是否连续都不做假设。
    """
    output = _nvidia_smi("index,uuid,name,memory.total,memory.used,utilization.gpu")
    gpus: list[dict] = []
    uuid_to_index: dict[str, int] = {}
    for line in output.splitlines():
        if not line.strip():
            continue
        # 型号名里可能带逗号，所以从两端解析。
        fields = [item.strip() for item in line.split(",")]
        if len(fields) < 6:
            continue
        try:
            index = int(fields[0])
            memory_total = int(float(fields[-3]))
            memory_used = int(float(fields[-2]))
            utilization = int(float(fields[-1]))
        except ValueError:
            continue
        uuid = fields[1]
        gpu = {
            "index": index,
            "uuid": uuid,
            "name": ",".join(fields[2:-3]).strip() or "unknown",
            "memory_total": memory_total,
            "memory_used": memory_used,
            "memory_free": max(memory_total - memory_used, 0),
            "utilization": utilization,
            "compute_pids": [],
        }
        gpus.append(gpu)
        uuid_to_index[uuid] = index
    if not gpus:
        raise GpuUnavailable("nvidia-smi 没有返回任何 GPU")
    gpus.sort(key=lambda gpu: gpu["index"])

    # 计算进程查询失败（旧驱动、权限、MIG 等）不应让整个调度停摆。
    process_output = subprocess.run(
        [
            "nvidia-smi",
            "--query-compute-apps=gpu_uuid,pid",
            "--format=csv,noheader,nounits",
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    ).stdout
    by_index = {gpu["index"]: gpu for gpu in gpus}
    for line in process_output.splitlines():
        fields = [item.strip() for item in line.split(",")]
        if len(fields) != 2 or fields[0] not in uuid_to_index:
            continue
        try:
            by_index[uuid_to_index[fields[0]]]["compute_pids"].append(int(fields[1]))
        except ValueError:
            continue
    return gpus


def gpu_snapshot() -> list[dict]:
    """gpu_inventory() 的别名，保留旧调用点。"""
    return gpu_inventory()


def split_ids(value: str | None) -> list[int]:
    if not value:
        return []
    return [int(item) for item in value.split(",") if item]


def join_ids(ids: list[int]) -> str:
    return ",".join(str(item) for item in ids)