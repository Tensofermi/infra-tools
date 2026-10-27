#!/usr/bin/env python3
# qGPU 的后台调度器：检查真实 GPU 占用，分配空闲卡，并启动或回收作业。

from __future__ import annotations

import fcntl
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

from common import (
    DEFAULT_CONFIG,
    HOME,
    LOCK_PATH,
    PID_PATH,
    ROOT,
    GpuUnavailable,
    connect,
    effective_config,
    gpu_inventory,
    join_ids,
    load_config,
    now,
    pid_is_alive,
    split_ids,
)


def write_daemon_log(message: str) -> None:
    print(f"[{now()}] {message}", flush=True)


def reconcile_jobs(connection) -> None:
    rows = connection.execute(
        "SELECT id, pid FROM jobs WHERE status = 'running'"
    ).fetchall()
    for row in rows:
        if not pid_is_alive(row["pid"]):
            connection.execute(
                """
                UPDATE jobs
                SET status = 'failed', exit_code = COALESCE(exit_code, 255),
                    ended_at = COALESCE(ended_at, ?),
                    message = COALESCE(message, '作业进程异常消失')
                WHERE id = ? AND status = 'running'
                """,
                (now(), row["id"]),
            )
    connection.commit()


def fail_job(connection, job_id: int, message: str) -> None:
    connection.execute(
        "UPDATE jobs SET status='failed', ended_at=?, message=? WHERE id=?",
        (now(), message, job_id),
    )
    connection.commit()
    write_daemon_log(f"作业 {job_id} 无法调度：{message}")


def available_gpus(connection, config: dict, inventory: list[dict]) -> list[int]:
    """按空闲显存从多到少返回可分配的物理 GPU。

    排序而不是按编号取，是为了在混合型号 / 混合占用的情况下优先用最空的卡。
    """
    rows = connection.execute(
        "SELECT assigned_gpu_ids FROM jobs WHERE status = 'running'"
    ).fetchall()
    managed = {
        gpu_id
        for row in rows
        for gpu_id in split_ids(row["assigned_gpu_ids"])
    }
    by_index = {gpu["index"]: gpu for gpu in inventory}
    candidates: list[tuple[int, int]] = []
    for gpu_id in config["gpu_pool"]:
        gpu = by_index.get(gpu_id)
        if not gpu or gpu_id in managed:
            continue
        if gpu["compute_pids"]:
            continue
        if gpu["memory_used"] > config["free_memory_mib"]:
            continue
        candidates.append((-gpu["memory_free"], gpu_id))
    candidates.sort()
    return [gpu_id for _, gpu_id in candidates]


def launch_job(connection, row, assigned: list[int]) -> None:
    job_id = row["id"]
    process = subprocess.Popen(
        [sys.executable, str(Path(__file__).resolve()), "run-job", str(job_id)],
        cwd=ROOT,
        env={**os.environ, "QGPU_HOME": str(HOME)},
        start_new_session=True,
    )
    connection.execute(
        """
        UPDATE jobs
        SET status = 'running', assigned_gpu_ids = ?, pid = ?, started_at = ?,
            message = NULL
        WHERE id = ? AND status = 'pending'
        """,
        (join_ids(assigned), process.pid, now(), job_id),
    )
    connection.commit()
    write_daemon_log(
        f"启动作业 {job_id} ({row['name']}), GPU={join_ids(assigned)}, pid={process.pid}"
    )


def schedule_once(connection) -> None:
    config = effective_config(gpus=gpu_inventory())
    reconcile_jobs(connection)
    free = available_gpus(connection, config, config["inventory"])
    managed_rows = connection.execute(
        "SELECT assigned_gpu_ids FROM jobs WHERE status = 'running'"
    ).fetchall()
    managed = {
        gpu_id
        for row in managed_rows
        for gpu_id in split_ids(row["assigned_gpu_ids"])
    }
    capacity = config["max_gpus"] - len(managed)
    if capacity <= 0:
        return

    pending = connection.execute(
        "SELECT * FROM jobs WHERE status = 'pending' ORDER BY queue_order, id"
    ).fetchall()
    for row in pending:
        count = int(row["gpu_count"])
        if count > len(config["gpu_pool"]):
            fail_job(
                connection,
                row["id"],
                f"请求 {count} 张 GPU，但当前 GPU 池只有 {len(config['gpu_pool'])} 张",
            )
            continue
        if count > capacity:
            continue
        requested = split_ids(row["requested_gpu_ids"])
        if requested:
            out_of_pool = [gpu_id for gpu_id in requested if gpu_id not in config["gpu_pool"]]
            if out_of_pool:
                fail_job(
                    connection,
                    row["id"],
                    "指定 GPU 不在当前 gpu_pool 中："
                    + join_ids(out_of_pool)
                    + f"（当前池：{join_ids(config['gpu_pool'])}）",
                )
                continue
            if not set(requested).issubset(free):
                continue
            assigned = requested
        else:
            if len(free) < count:
                continue
            # 按“最空闲优先”挑选，但编号按升序写回，保持作业侧可预测。
            assigned = sorted(free[:count])
        launch_job(connection, row, assigned)
        free = [gpu_id for gpu_id in free if gpu_id not in assigned]
        capacity -= len(assigned)
        if capacity <= 0:
            break


def run_daemon() -> int:
    HOME.mkdir(parents=True, exist_ok=True)
    lock_file = LOCK_PATH.open("w")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("qGPU 调度器已经在运行", file=sys.stderr)
        return 1

    PID_PATH.write_text(f"{os.getpid()}\n", encoding="utf-8")
    stopping = False

    def stop_handler(_signum, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop_handler)
    signal.signal(signal.SIGINT, stop_handler)
    connection = connect()
    write_daemon_log(f"qGPU 调度器启动，pid={os.getpid()}，状态目录={HOME}")
    poll_seconds = float(DEFAULT_CONFIG["poll_seconds"])
    try:
        while not stopping:
            try:
                schedule_once(connection)
            except GpuUnavailable as exc:
                write_daemon_log(f"GPU 暂不可用，等待下一轮：{exc}")
            except Exception as exc:  # 调度器不能因一次 nvidia-smi 或作业错误退出。
                write_daemon_log(f"调度循环错误：{exc}")
            try:
                poll_seconds = float(load_config()["poll_seconds"])
            except Exception as exc:  # config.json 被写坏时沿用上一轮的值，别退出。
                write_daemon_log(f"读取 poll_seconds 失败，沿用 {poll_seconds}s：{exc}")
            time.sleep(poll_seconds)
    finally:
        PID_PATH.unlink(missing_ok=True)
        connection.close()
        write_daemon_log("qGPU 调度器停止；已运行作业不会被终止")
    return 0


def run_job(job_id: int) -> int:
    connection = connect()
    row = None
    # 父进程拿到 runner pid 后才写入 running；短暂等待可消除启动时的毫秒级竞争。
    for _ in range(100):
        row = connection.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
        if row and row["status"] == "running":
            break
        time.sleep(0.02)
    if not row or row["status"] != "running":
        connection.close()
        return 2

    command = json.loads(row["command_json"])
    submitted_env = json.loads(row["env_json"])
    env = os.environ.copy()
    env.update(submitted_env)
    env["CUDA_VISIBLE_DEVICES"] = row["assigned_gpu_ids"]
    env["QGPU_JOB_ID"] = str(job_id)
    env["QGPU_PHYSICAL_GPU_IDS"] = row["assigned_gpu_ids"]

    log_path = Path(row["log_path"])
    log_path.parent.mkdir(parents=True, exist_ok=True)
    exit_code = 255
    try:
        with log_path.open("a", encoding="utf-8", buffering=1) as log_file:
            log_file.write(
                f"[{now()}] qGPU start: physical GPUs={row['assigned_gpu_ids']} "
                f"cwd={row['cwd']}\n"
            )
            log_file.write(f"command: {command!r}\n")
            try:
                child = subprocess.Popen(
                    command,
                    cwd=row["cwd"],
                    env=env,
                    stdout=log_file,
                    stderr=subprocess.STDOUT,
                )
                exit_code = child.wait()
            except Exception as exc:
                log_file.write(f"qGPU launch error: {exc}\n")
                exit_code = 127
            log_file.write(f"[{now()}] qGPU exit: code={exit_code}\n")
    finally:
        status = "completed" if exit_code == 0 else "failed"
        connection.execute(
            """
            UPDATE jobs
            SET status = ?, exit_code = ?, ended_at = ?
            WHERE id = ? AND status = 'running'
            """,
            (status, exit_code, now(), job_id),
        )
        connection.commit()
        connection.close()
    return exit_code


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "run-job":
        return run_job(int(sys.argv[2]))
    return run_daemon()


if __name__ == "__main__":
    raise SystemExit(main())
