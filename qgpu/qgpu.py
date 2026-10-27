#!/usr/bin/env python3
# qGPU 的命令行入口：用于提交、查看、取消作业，以及启动和配置调度器。

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path


def _prescan_home() -> None:
    """在 import common 之前处理 --home，使状态目录可以在本次调用内改变。

    只解析子命令之前的全局选项。子命令之后的参数，尤其是 `--` 之后的作业命令，
    必须原样交给作业：`qgpu submit -- python train.py --home /data` 里的 --home
    属于训练脚本，不能改动 qGPU 自己的状态目录。
    """
    argv = sys.argv[1:]
    position = 0
    while position < len(argv):
        item = argv[position]
        if item == "--" or not item.startswith("-"):
            return  # 到达子命令或 `--`，后面全部属于子命令/作业
        if item == "--home":
            if position + 1 >= len(argv):
                return
            os.environ["QGPU_HOME"] = argv[position + 1]
            position += 2
            continue
        if item.startswith("--home="):
            os.environ["QGPU_HOME"] = item.split("=", 1)[1]
        position += 1


_prescan_home()

from common import (  # noqa: E402  (必须晚于 _prescan_home)
    DAEMON_LOG,
    HOME,
    LOG_DIR,
    PID_PATH,
    ROOT,
    GpuUnavailable,
    connect,
    effective_config,
    gpu_inventory,
    join_ids,
    load_config,
    now,
    parse_gpu_ids,
    pid_is_alive,
    save_config,
    scheduler_pid,
    split_ids,
)


RUNTIME_ENV_NAMES = {
    "PATH",
    "PYTHONPATH",
    "LD_LIBRARY_PATH",
    "LD_PRELOAD",
    "CONDA_PREFIX",
    "CONDA_DEFAULT_ENV",
    "VIRTUAL_ENV",
    "HF_HOME",
    "HF_DATASETS_CACHE",
    "TRANSFORMERS_CACHE",
    "TORCH_HOME",
}
RUNTIME_ENV_PREFIXES = ("CUDA_", "NCCL_", "TORCH_", "OMP_", "MKL_", "PYTORCH_")


def captured_environment(extra: list[str]) -> dict[str, str]:
    env = {
        key: value
        for key, value in os.environ.items()
        if key in RUNTIME_ENV_NAMES or key.startswith(RUNTIME_ENV_PREFIXES)
    }
    for item in extra:
        if "=" not in item:
            raise ValueError(f"--env 需要 KEY=VALUE，收到：{item}")
        key, value = item.split("=", 1)
        if not key:
            raise ValueError("环境变量名不能为空")
        env[key] = value
    env.pop("CUDA_VISIBLE_DEVICES", None)
    return env


def format_time(value: str | None) -> str:
    return value[5:16].replace("T", " ") if value else "-"


def format_ids(value: str | None) -> str:
    return value if value else "auto"


def gpu_failure_hint(exc: Exception) -> ValueError:
    return ValueError(f"无法读取 GPU 状态：{exc}（可用 qgpu detect 排查）")


def start_scheduler(_args) -> int:
    pid = scheduler_pid()
    if pid_is_alive(pid):
        print(f"qGPU 已在运行，pid={pid}（状态目录 {HOME}）")
        return 0
    HOME.mkdir(parents=True, exist_ok=True)
    log_file = DAEMON_LOG.open("a", encoding="utf-8")
    process = subprocess.Popen(
        [sys.executable, str(ROOT / "scheduler.py")],
        cwd=ROOT,
        env={**os.environ, "QGPU_HOME": str(HOME)},
        stdout=log_file,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    log_file.close()
    for _ in range(30):
        time.sleep(0.1)
        pid = scheduler_pid()
        if pid_is_alive(pid):
            print(f"qGPU 已启动，pid={pid}（状态目录 {HOME}）")
            return 0
        if process.poll() is not None:
            break
    print(f"qGPU 启动失败，请查看 {DAEMON_LOG}", file=sys.stderr)
    return 1


def stop_scheduler(_args) -> int:
    pid = scheduler_pid()
    if not pid_is_alive(pid):
        PID_PATH.unlink(missing_ok=True)
        print("qGPU 当前未运行")
        return 0
    os.kill(pid, signal.SIGTERM)
    for _ in range(50):
        time.sleep(0.1)
        if not pid_is_alive(pid):
            print("qGPU 已停止；已启动的作业继续运行")
            return 0
    print(f"调度器 pid={pid} 尚未退出", file=sys.stderr)
    return 1


def submit_job(args) -> int:
    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        raise ValueError("缺少作业命令；示例：qgpu submit -- python train.py")
    cwd = str(Path(args.cwd or os.getcwd()).resolve())
    if not Path(cwd).is_dir():
        raise ValueError(f"工作目录不存在：{cwd}")
    try:
        config = effective_config()
    except GpuUnavailable as exc:
        raise gpu_failure_hint(exc) from exc
    requested = parse_gpu_ids(args.gpu_ids) if args.gpu_ids else []
    gpu_count = len(requested) if requested else args.gpus
    if gpu_count < 1:
        raise ValueError("--gpus 必须大于 0")
    pool = config["gpu_pool"]
    if gpu_count > len(pool):
        raise ValueError(
            f"请求 {gpu_count} 张 GPU，但当前 GPU 池只有 {len(pool)} 张：{join_ids(pool)}"
        )
    if requested and not set(requested).issubset(pool):
        outside = [gpu_id for gpu_id in requested if gpu_id not in pool]
        raise ValueError(
            f"指定 GPU 不在当前 GPU 池中：{join_ids(outside)}（当前池：{join_ids(pool)}）"
        )

    connection = connect()
    submitted_at = now()
    queue_order = connection.execute(
        "SELECT COALESCE(MAX(queue_order), 0) + 1 FROM jobs"
    ).fetchone()[0]
    cursor = connection.execute(
        """
        INSERT INTO jobs (
            name, status, command_json, cwd, env_json, gpu_count,
            requested_gpu_ids, submitted_at, log_path, queue_order
        ) VALUES (?, 'pending', ?, ?, ?, ?, ?, ?, '', ?)
        """,
        (
            args.name or Path(command[0]).name,
            json.dumps(command, ensure_ascii=False),
            cwd,
            json.dumps(captured_environment(args.env), ensure_ascii=False),
            gpu_count,
            join_ids(requested) if requested else None,
            submitted_at,
            queue_order,
        ),
    )
    job_id = cursor.lastrowid
    log_path = LOG_DIR / f"{job_id:06d}.log"
    connection.execute(
        "UPDATE jobs SET log_path = ? WHERE id = ?", (str(log_path), job_id)
    )
    connection.commit()
    connection.close()
    print(
        f"已提交 job {job_id}: {args.name or Path(command[0]).name} "
        f"| GPU={format_ids(join_ids(requested) if requested else None)} x{gpu_count}"
    )
    if not pid_is_alive(scheduler_pid()):
        print(f"提示：调度器尚未启动，请运行 {ROOT / 'run.sh'}（或 qgpu start）")
    return 0


def list_jobs(args) -> int:
    connection = connect()
    where = ""
    values: tuple = ()
    if args.status:
        where = "WHERE status = ?"
        values = (args.status,)
    if args.status == "pending":
        rows = connection.execute(
            f"SELECT * FROM jobs {where} ORDER BY queue_order, id LIMIT ?",
            values + (args.limit,),
        ).fetchall()
    else:
        rows = connection.execute(
            f"SELECT * FROM jobs {where} ORDER BY id DESC LIMIT ?",
            values + (args.limit,),
        ).fetchall()
        rows = list(reversed(rows))
    connection.close()
    if not rows:
        print("没有作业")
        return 0
    print(f"{'ID':>5}  {'STATUS':<10} {'GPU':<9} {'SUBMITTED':<11} {'NAME'}")
    for row in rows:
        gpu = row["assigned_gpu_ids"] or row["requested_gpu_ids"] or f"auto:{row['gpu_count']}"
        print(
            f"{row['id']:>5}  {row['status']:<10} {gpu:<9} "
            f"{format_time(row['submitted_at']):<11} {row['name']}"
        )
    return 0


def show_job(args) -> int:
    connection = connect()
    row = connection.execute("SELECT * FROM jobs WHERE id = ?", (args.job_id,)).fetchone()
    if not row:
        connection.close()
        raise ValueError(f"找不到 job {args.job_id}")
    queue_position = "-"
    if row["status"] == "pending":
        queue_position = connection.execute(
            """
            SELECT COUNT(*) + 1 FROM jobs
            WHERE status = 'pending'
              AND (queue_order < ? OR (queue_order = ? AND id < ?))
            """,
            (row["queue_order"], row["queue_order"], row["id"]),
        ).fetchone()[0]
    connection.close()
    command = json.loads(row["command_json"])
    fields = [
        ("id", row["id"]),
        ("name", row["name"]),
        ("status", row["status"]),
        ("queue position", queue_position),
        ("GPU request", row["requested_gpu_ids"] or f"auto x{row['gpu_count']}"),
        ("GPU assigned", row["assigned_gpu_ids"] or "-"),
        ("pid", row["pid"] or "-"),
        ("cwd", row["cwd"]),
        ("command", " ".join(command)),
        ("submitted", row["submitted_at"]),
        ("started", row["started_at"] or "-"),
        ("ended", row["ended_at"] or "-"),
        ("exit code", row["exit_code"] if row["exit_code"] is not None else "-"),
        ("log", row["log_path"]),
        ("message", row["message"] or "-"),
    ]
    for key, value in fields:
        print(f"{key:>12}: {value}")
    return 0


def cancel_job(args) -> int:
    connection = connect()
    row = connection.execute("SELECT * FROM jobs WHERE id = ?", (args.job_id,)).fetchone()
    if not row:
        connection.close()
        raise ValueError(f"找不到 job {args.job_id}")
    if row["status"] == "pending":
        connection.execute(
            "UPDATE jobs SET status='cancelled', ended_at=?, message='用户取消' WHERE id=?",
            (now(), args.job_id),
        )
    elif row["status"] == "running":
        try:
            os.killpg(row["pid"], signal.SIGTERM)
        except ProcessLookupError:
            pass
        connection.execute(
            "UPDATE jobs SET status='cancelled', ended_at=?, message='用户取消' WHERE id=?",
            (now(), args.job_id),
        )
    else:
        connection.close()
        raise ValueError(f"job {args.job_id} 当前状态为 {row['status']}，不能取消")
    connection.commit()
    connection.close()
    print(f"已取消 job {args.job_id}")
    return 0


def retry_job(args) -> int:
    connection = connect()
    row = connection.execute("SELECT * FROM jobs WHERE id = ?", (args.job_id,)).fetchone()
    if not row:
        connection.close()
        raise ValueError(f"找不到 job {args.job_id}")
    if row["status"] in {"pending", "running"}:
        connection.close()
        raise ValueError("pending/running 作业不能 retry")
    queue_order = connection.execute(
        "SELECT COALESCE(MAX(queue_order), 0) + 1 FROM jobs"
    ).fetchone()[0]
    cursor = connection.execute(
        """
        INSERT INTO jobs (
            name, status, command_json, cwd, env_json, gpu_count,
            requested_gpu_ids, submitted_at, log_path, queue_order
        ) VALUES (?, 'pending', ?, ?, ?, ?, ?, ?, '', ?)
        """,
        (
            row["name"], row["command_json"], row["cwd"], row["env_json"],
            row["gpu_count"], row["requested_gpu_ids"], now(), queue_order,
        ),
    )
    new_id = cursor.lastrowid
    log_path = LOG_DIR / f"{new_id:06d}.log"
    connection.execute("UPDATE jobs SET log_path=? WHERE id=?", (str(log_path), new_id))
    connection.commit()
    connection.close()
    print(f"job {args.job_id} 已重新提交为 job {new_id}")
    return 0


def move_job(args, to_front: bool) -> int:
    connection = connect()
    row = connection.execute(
        "SELECT id, status, name FROM jobs WHERE id = ?", (args.job_id,)
    ).fetchone()
    if not row:
        connection.close()
        raise ValueError(f"找不到 job {args.job_id}")
    if row["status"] != "pending":
        connection.close()
        raise ValueError(
            f"job {args.job_id} 当前状态为 {row['status']}，只有 pending 作业可以调整顺序"
        )
    aggregate = "MIN" if to_front else "MAX"
    edge = connection.execute(
        f"SELECT COALESCE({aggregate}(queue_order), 0) FROM jobs WHERE status='pending'"
    ).fetchone()[0]
    new_order = edge - 1 if to_front else edge + 1
    connection.execute(
        "UPDATE jobs SET queue_order = ? WHERE id = ?", (new_order, args.job_id)
    )
    connection.commit()
    connection.close()
    destination = "队首" if to_front else "队尾"
    print(f"job {args.job_id} ({row['name']}) 已移动到 pending {destination}")
    return 0


def promote_job(args) -> int:
    return move_job(args, to_front=True)


def demote_job(args) -> int:
    return move_job(args, to_front=False)


def show_logs(args) -> int:
    connection = connect()
    row = connection.execute("SELECT log_path FROM jobs WHERE id = ?", (args.job_id,)).fetchone()
    connection.close()
    if not row:
        raise ValueError(f"找不到 job {args.job_id}")
    path = Path(row["log_path"])
    if not path.exists():
        print("日志尚未生成")
        return 0
    command = ["tail"]
    if args.follow:
        command.append("-f")
    command.extend(["-n", str(args.lines), str(path)])
    return subprocess.call(command)


def show_status(_args) -> int:
    pid = scheduler_pid()
    state = f"running (pid={pid})" if pid_is_alive(pid) else "stopped"
    print(f"scheduler: {state}")
    print(f"state dir: {HOME}")
    try:
        config = effective_config()
    except (GpuUnavailable, ValueError) as exc:
        print(f"config   : (unavailable) {exc}")
        config = None
    if config:
        pool_text = join_ids(config["gpu_pool"])
        if not config["configured_pool"]:
            pool_text = f"{pool_text} (auto: all visible GPUs)"
        print(
            f"config   : max_gpus={config['max_gpus']} pool={pool_text} "
            f"poll={config['poll_seconds']}s free_mem<={config['free_memory_mib']}MiB"
        )
        for note in config["notes"]:
            print(f"note     : {note}")
    connection = connect()
    counts = dict(
        connection.execute("SELECT status, COUNT(*) FROM jobs GROUP BY status").fetchall()
    )
    managed = {
        gpu_id
        for row in connection.execute(
            "SELECT assigned_gpu_ids FROM jobs WHERE status='running'"
        ).fetchall()
        for gpu_id in split_ids(row["assigned_gpu_ids"])
    }
    connection.close()
    print(
        "jobs: " + " ".join(
            f"{key}={counts.get(key, 0)}"
            for key in ("pending", "running", "completed", "failed", "cancelled")
        )
    )
    if not config:
        return 0
    print(f"{'GPU':>3} {'NAME':<18} {'MEM(MiB)':>17} {'UTIL':>6} {'PIDS':>12} {'QGPU':>6}")
    for gpu in config["inventory"]:
        name = gpu["name"][:18]
        print(
            f"{gpu['index']:>3} {name:<18} "
            f"{gpu['memory_used']:>7}/{gpu['memory_total']:<7} "
            f"{gpu['utilization']:>5}% "
            f"{','.join(map(str, gpu['compute_pids'])) or '-':>12} "
            f"{'yes' if gpu['index'] in managed else '-':>6}"
        )
    return 0


def detect_gpus(_args) -> int:
    """打印 nvidia-smi 的原始可见情况，以及池/上限的解析结果。"""
    print(f"state dir: {HOME}")
    try:
        inventory = gpu_inventory()
    except GpuUnavailable as exc:
        raise ValueError(f"无法读取 GPU 状态：{exc}") from exc
    print(f"{'IDX':>3} {'NAME':<22} {'TOTAL':>8} {'USED':>8} {'FREE':>8} {'UTIL':>5} {'PIDS'}")
    for gpu in inventory:
        print(
            f"{gpu['index']:>3} {gpu['name'][:22]:<22} {gpu['memory_total']:>8} "
            f"{gpu['memory_used']:>8} {gpu['memory_free']:>8} {gpu['utilization']:>4}% "
            f"{','.join(map(str, gpu['compute_pids'])) or '-'}"
        )
    config = effective_config(gpus=inventory)
    configured = config["configured_pool"]
    print(f"visible   : {len(inventory)} GPU ({join_ids([g['index'] for g in inventory])})")
    print(
        "gpu_pool  : "
        + join_ids(config["gpu_pool"])
        + ("  (auto: all visible GPUs)" if not configured else f"  (configured: {join_ids(configured)})")
    )
    print(f"max_gpus  : {config['max_gpus']}")
    for note in config["notes"]:
        print(f"note      : {note}")
    print(
        "idle rule : no compute process and used memory <= "
        f"{config['free_memory_mib']} MiB"
    )
    return 0


def configure(args) -> int:
    config = load_config()
    changed = False
    if args.max_gpus is not None:
        config["max_gpus"] = args.max_gpus
        changed = True
    if args.gpu_pool is not None:
        value = args.gpu_pool.strip().lower()
        if value in {"auto", "all", ""}:
            config["gpu_pool"] = []
        else:
            config["gpu_pool"] = parse_gpu_ids(value)
        changed = True
    if args.poll_seconds is not None:
        config["poll_seconds"] = args.poll_seconds
        changed = True
    if args.free_memory_mib is not None:
        config["free_memory_mib"] = args.free_memory_mib
        changed = True
    if changed:
        save_config(config)
        print("配置已更新，调度器会自动读取新值")
    print(json.dumps(load_config(), ensure_ascii=False, indent=2))
    try:
        resolved = effective_config()
    except (GpuUnavailable, ValueError) as exc:
        print(f"当前无法解析自动配置：{exc}")
        return 0
    print(
        f"resolved  : pool={join_ids(resolved['gpu_pool'])} "
        f"max_gpus={resolved['max_gpus']} (visible {len(resolved['inventory'])})"
    )
    for note in resolved["notes"]:
        print(f"note      : {note}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="qgpu",
        description="qGPU：任意数量 NVIDIA GPU 上的个人作业队列",
        epilog=(
            f"状态目录默认 {HOME}（可用 --home DIR 或 QGPU_HOME 覆盖；"
            "--home 是全局选项，需放在子命令之前）"
        ),
    )
    parser.add_argument(
        "--home",
        metavar="DIR",
        help="状态目录（数据库/配置/日志）；需放在子命令之前",
    )
    sub = parser.add_subparsers(dest="subcommand", required=True)

    sub.add_parser("start", help="启动调度器").set_defaults(func=start_scheduler)
    sub.add_parser("stop", help="停止调度器，不终止已运行作业").set_defaults(func=stop_scheduler)
    sub.add_parser("status", help="查看调度器、队列和 GPU 状态").set_defaults(func=show_status)
    sub.add_parser("detect", help="列出 nvidia-smi 可见的 GPU 与解析后的池").set_defaults(
        func=detect_gpus
    )

    submit = sub.add_parser("submit", aliases=["sb"], help="提交作业")
    submit.add_argument("--name", help="作业名称")
    submit.add_argument("--gpus", type=int, default=1, help="自动分配的 GPU 数，默认 1")
    submit.add_argument("--gpu-ids", help="指定物理 GPU，例如 3 或 3,4 或 0-3")
    submit.add_argument("--cwd", help="工作目录，默认当前目录")
    submit.add_argument("--env", action="append", default=[], help="额外环境变量 KEY=VALUE")
    submit.add_argument("command", nargs=argparse.REMAINDER, help="-- 后面的作业命令")
    submit.set_defaults(func=submit_job)

    listing = sub.add_parser("list", aliases=["ls"], help="查看作业列表")
    listing.add_argument("--status", choices=["pending", "running", "completed", "failed", "cancelled"])
    listing.add_argument("--limit", type=int, default=30)
    listing.set_defaults(func=list_jobs)

    show = sub.add_parser("show", help="查看单个作业详情")
    show.add_argument("job_id", type=int)
    show.set_defaults(func=show_job)

    logs = sub.add_parser("logs", help="查看作业日志")
    logs.add_argument("job_id", type=int)
    logs.add_argument("-f", "--follow", action="store_true")
    logs.add_argument("-n", "--lines", type=int, default=100)
    logs.set_defaults(func=show_logs)

    cancel = sub.add_parser("cancel", aliases=["scancel"], help="取消作业")
    cancel.add_argument("job_id", type=int)
    cancel.set_defaults(func=cancel_job)

    retry = sub.add_parser("retry", help="重新提交已结束作业")
    retry.add_argument("job_id", type=int)
    retry.set_defaults(func=retry_job)

    promote = sub.add_parser("promote", help="把 pending 作业移动到队首")
    promote.add_argument("job_id", type=int)
    promote.set_defaults(func=promote_job)

    demote = sub.add_parser("demote", help="把 pending 作业移动到队尾")
    demote.add_argument("job_id", type=int)
    demote.set_defaults(func=demote_job)

    config = sub.add_parser("config", help="查看或修改配置")
    config.add_argument("--max-gpus", type=int, help="同时占用的 GPU 上限，0 表示自动")
    config.add_argument("--gpu-pool", help="例如 0-7、0,2,4,6，或 auto")
    config.add_argument("--poll-seconds", type=float)
    config.add_argument("--free-memory-mib", type=int)
    config.set_defaults(func=configure)
    return parser


def main() -> int:
    try:
        args = build_parser().parse_args()
        return args.func(args)
    except (ValueError, OSError, RuntimeError, subprocess.SubprocessError) as exc:
        print(f"qgpu: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
