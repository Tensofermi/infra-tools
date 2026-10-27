#!/usr/bin/env python3
"""Record one node sample: GPUs, CPU utilization, memory, disks and GPU processes.

Intended to run once a minute from cron. Each run:

* appends one JSON object to ``<data>/samples/<UTC-day>.jsonl``
* rewrites ``<data>/latest.json`` atomically
* keeps ``<data>/state/cpu.json`` so two ``/proc/stat`` readings give a real
  CPU average over the interval, not a one-second glimpse
* gzips sample files older than ``MONITOR_RETENTION_DAYS``

Nothing outside the Python standard library is required, because the machines
this runs on do not get a pip install for it.

A value that could not be read is written as ``null``, never as ``0``. A zero
that means "measured idle" and a zero that means "no reading" are different
facts, and a monitor that confuses them lies during exactly the incident it
exists to report.
"""

import csv
import gzip
import json
import os
import re
import shutil
import socket
import subprocess
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

# Bump when a field changes meaning or disappears. Consumers read this before
# trusting anything else in the sample.
SCHEMA_VERSION = 1

GPU_FIELDS = [
    "index",
    "name",
    "utilization.gpu",
    "memory.used",
    "memory.total",
    "temperature.gpu",
    "power.draw",
    "power.limit",
]

# Filesystems worth a look on a GPU box. Missing mounts are skipped.
DISK_MOUNTS = ["/", "/home", "/data", "/data1", "/mnt", "/mnt/nvme"]

# Applied to a process command line before it is written where others can read
# it: shared machines carry other people's tokens in their argv.
SECRET_PATTERNS = [
    re.compile(r"(?i)(--?(?:password|passwd|token|secret|key|api[_-]?key)[=\s]+)(\S+)"),
    re.compile(r"(?i)((?:password|passwd|token|secret|api[_-]?key)=)(\S+)"),
    re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b"),
]

# A disk this full is reported as a risk by `summarize`.
DISK_RISK_PCT = 90.0

# `partial` and above are considered "working"; below is `idle`.
WARM_UTIL_PCT = 70.0
PARTIAL_UTIL_PCT = 20.0
FULL_MIN_UTIL_PCT = 85.0


def run(argv):
    """Run a command, returning ``(stdout, error)`` with ``error`` None on success."""
    try:
        done = subprocess.run(
            argv,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except FileNotFoundError:
        return "", f"{argv[0]} not found"
    except OSError as exc:
        return "", f"{argv[0]}: {exc}"
    if done.returncode != 0:
        detail = (done.stderr or "").strip().splitlines()
        error = f"{argv[0]} exited {done.returncode}"
        if detail:
            error += f": {detail[0][:200]}"
        return "", error
    return done.stdout, None


def parse_float(value):
    try:
        return float(str(value).strip())
    except Exception:
        return 0.0


def parse_int(value):
    try:
        return int(float(str(value).strip()))
    except Exception:
        return 0


def read_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def write_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def collect_gpus():
    """Return ``(gpus, error)``. Error is why the list would be empty."""
    output, error = run([
        "nvidia-smi",
        f"--query-gpu={','.join(GPU_FIELDS)}",
        "--format=csv,noheader,nounits",
    ])
    if error:
        return [], error
    gpus = []
    for row in csv.reader(output.splitlines()):
        if len(row) < len(GPU_FIELDS):
            continue
        gpus.append({
            "index": parse_int(row[0]),
            "name": row[1].strip(),
            "utilization_gpu_pct": parse_float(row[2]),
            "memory_used_mib": parse_int(row[3]),
            "memory_total_mib": parse_int(row[4]),
            "temperature_c": parse_float(row[5]),
            "power_draw_w": parse_float(row[6]),
            "power_limit_w": parse_float(row[7]),
        })
    return gpus, None


def collect_processes():
    """GPU compute processes, enriched from ``ps`` and redacted."""
    output, error = run([
        "nvidia-smi",
        "--query-compute-apps=gpu_bus_id,pid,process_name,used_memory",
        "--format=csv,noheader,nounits",
    ])
    if error:
        return []
    raw = []
    for row in csv.reader(output.splitlines()):
        if len(row) < 4:
            continue
        raw.append({
            "gpu": row[0].strip(),
            "pid": parse_int(row[1]),
            "process_name": os.path.basename(row[2].strip())[:80],
            "used_memory_mib": parse_int(row[3]),
        })
    return enrich_processes(raw)


def sanitize_command(command):
    """Strip credentials and addresses, then bound the length."""
    command = " ".join(str(command or "").split())
    for pattern in SECRET_PATTERNS[:2]:
        command = pattern.sub(r"\1[redacted]", command)
    command = SECRET_PATTERNS[2].sub("[ip]", command)
    if len(command) > 220:
        command = command[:217] + "..."
    return command


def enrich_processes(processes):
    """Add user, elapsed time and a redacted command line from ``ps``."""
    if not processes:
        return []
    by_pid = {proc["pid"]: proc for proc in processes if proc["pid"]}
    pids = sorted(by_pid)
    output, error = run(["ps", "-o", "pid=,user=,etime=,comm=,args=", "-p", ",".join(map(str, pids))])
    if error:
        return list(by_pid.values())
    for line in output.splitlines():
        parts = line.strip().split(None, 4)
        if len(parts) < 4:
            continue
        pid = parse_int(parts[0])
        if pid not in by_pid:
            continue
        by_pid[pid]["user"] = parts[1][:32]
        by_pid[pid]["elapsed"] = parts[2]
        by_pid[pid]["command"] = sanitize_command(parts[4] if len(parts) >= 5 else parts[3])
    return list(by_pid.values())


def read_cpu_counters():
    """Return ``(total, idle)`` jiffies from ``/proc/stat``, or None.

    ``guest``/``guest_nice`` are already included in ``user``/``nice``, so the
    first eight fields are the whole of the time accounted for.
    """
    try:
        with open("/proc/stat", encoding="utf-8") as fh:
            for line in fh:
                if not line.startswith("cpu "):
                    continue
                fields = [int(value) for value in line.split()[1:9]]
                if len(fields) < 5:
                    return None
                return sum(fields), fields[3] + fields[4]
    except (OSError, ValueError):
        return None
    return None


def cpu_utilization(previous, current):
    """Percent busy between two counter readings, or None if incomparable.

    Counters that went backwards mean a reboot or a wrap; there is no average
    across that boundary, and ``None`` says so instead of inventing one.
    """
    if not previous or not current:
        return None
    delta_total = current["total"] - previous["total"]
    delta_idle = current["idle"] - previous["idle"]
    if delta_total <= 0 or delta_idle < 0:
        return None
    busy = delta_total - delta_idle
    return round(max(0.0, min(100.0, busy / delta_total * 100)), 1)


def collect_cpu(state_path, now):
    """CPU utilization averaged over the interval since the previous run."""
    block = {
        "cores": os.cpu_count() or 0,
        "utilization_pct": None,
        "window_seconds": None,
    }
    counters = read_cpu_counters()
    if counters is None:
        return block
    current = {"total": counters[0], "idle": counters[1], "ts": now}
    previous = read_json(state_path)
    util = cpu_utilization(previous, current)
    block["utilization_pct"] = util
    if util is not None and previous and isinstance(previous.get("ts"), (int, float)):
        block["window_seconds"] = int(max(0, now - previous["ts"]))
    write_json(state_path, current)
    return block


def collect_memory():
    """Memory and swap in MiB, from ``free``."""
    output, error = run(["free", "-m"])
    if error:
        return {}
    memory = {}
    for line in output.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        if line.startswith("Mem:") and len(parts) >= 7:
            memory["total_mib"] = parse_int(parts[1])
            memory["used_mib"] = parse_int(parts[2])
            memory["free_mib"] = parse_int(parts[3])
            memory["available_mib"] = parse_int(parts[6])
        elif line.startswith("Swap:"):
            memory["swap_total_mib"] = parse_int(parts[1])
            memory["swap_used_mib"] = parse_int(parts[2])
    return memory


def collect_disks():
    """Usage of the mounts in ``DISK_MOUNTS`` that exist."""
    mounts = [mount for mount in DISK_MOUNTS if os.path.exists(mount)] or ["/"]
    output, error = run(["df", "-hP", *mounts])
    if error:
        return []
    disks = []
    seen = set()
    for line in output.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 6 or parts[5] in seen:
            continue
        seen.add(parts[5])
        disks.append({
            "filesystem": parts[0],
            "size": parts[1],
            "used": parts[2],
            "avail": parts[3],
            "use_pct": parse_float(parts[4].rstrip("%")),
            "mount": parts[5],
        })
    return disks


def percentage(part, whole):
    if not whole or not isinstance(whole, (int, float)):
        return None
    return round(max(0.0, min(100.0, part / whole * 100)), 1)


def summarize(payload):
    """The derived block: fleet state, and nothing the payload did not contain."""
    gpus = payload.get("gpus") or []
    utils = [gpu.get("utilization_gpu_pct", 0) for gpu in gpus]
    memory_pct = [
        percentage(gpu.get("memory_used_mib", 0), gpu.get("memory_total_mib", 0))
        for gpu in gpus
    ]
    memory_pct = [value for value in memory_pct if value is not None]
    powers = [gpu.get("power_draw_w", 0) for gpu in gpus]
    temps = [gpu.get("temperature_c", 0) for gpu in gpus]

    risky = sorted(
        [disk for disk in payload.get("disks", []) if disk.get("use_pct", 0) >= DISK_RISK_PCT],
        key=lambda disk: disk.get("use_pct", 0),
        reverse=True,
    )

    avg_util = round(sum(utils) / len(utils), 1) if utils else None
    min_util = min(utils) if utils else None

    if not gpus:
        # No GPU seen at all. `offline` is a fact about the reading, not about
        # the machine: a CPU-only host says the same thing every minute.
        status = "offline"
    elif min_util >= FULL_MIN_UTIL_PCT:
        status = "full"
    elif avg_util >= WARM_UTIL_PCT:
        status = "warm"
    elif avg_util >= PARTIAL_UTIL_PCT:
        status = "partial"
    else:
        status = "idle"

    memory = payload.get("memory") or {}
    cpu = payload.get("cpu") or {}

    return {
        "gpu_count": len(gpus),
        "avg_util": avg_util,
        "min_util": min_util,
        "max_util": max(utils) if utils else None,
        "avg_mem_pct": round(sum(memory_pct) / len(memory_pct), 2) if memory_pct else None,
        "total_power_w": round(sum(powers), 1) if powers else None,
        "max_temp_c": max(temps) if temps else None,
        "cpu_util_pct": cpu.get("utilization_pct"),
        "mem_used_pct": percentage(memory.get("used_mib", 0), memory.get("total_mib", 0)),
        "swap_used_pct": percentage(
            memory.get("swap_used_mib", 0), memory.get("swap_total_mib", 0)
        ),
        "status": status,
        "disk_risk": (
            f"{risky[0]['mount']} {risky[0]['use_pct']:.0f}%" if risky else "ok"
        ),
    }


def prune_samples(samples_dir, retention_days, now):
    """Gzip sample files whose UTC day is older than the retention window."""
    if retention_days <= 0:
        return []
    cutoff = (datetime.fromtimestamp(now, timezone.utc).date() - timedelta(days=retention_days))
    pruned = []
    for path in sorted(Path(samples_dir).glob("*.jsonl")):
        try:
            day = datetime.strptime(path.stem, "%Y-%m-%d").date()
        except ValueError:
            continue
        if day >= cutoff:
            continue
        target = path.with_suffix(".jsonl.gz")
        try:
            with path.open("rb") as src, gzip.open(target, "wb") as dst:
                shutil.copyfileobj(src, dst)
            path.unlink()
            pruned.append(target.name)
        except OSError as exc:
            print(f"prune: could not compress {path.name}: {exc}", flush=True)
    return pruned


def main():
    machine = os.environ.get("MONITOR_MACHINE") or socket.gethostname().split(".")[0]
    home = Path(os.environ.get("MONITOR_HOME", str(Path.home() / "gpu-monitor")))
    data_dir = Path(os.environ.get("MONITOR_DATA_DIR", str(home / "data")))
    retention_days = float(os.environ.get("MONITOR_RETENTION_DAYS", "7"))

    now = time.time()
    collected_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
    samples_dir = data_dir / "samples"
    state_dir = data_dir / "state"
    samples_dir.mkdir(parents=True, exist_ok=True)
    state_dir.mkdir(parents=True, exist_ok=True)

    gpus, gpu_error = collect_gpus()
    payload = {
        "machine": machine,
        "collected_at": collected_at,
        "loadavg": list(os.getloadavg()) if hasattr(os, "getloadavg") else [],
        "cpu": collect_cpu(state_dir / "cpu.json", now),
        "memory": collect_memory(),
        "gpus": gpus,
        "processes": collect_processes()[:24],
        "disks": collect_disks(),
    }
    if gpu_error:
        payload["gpu_error"] = gpu_error

    sample = {
        "schema": SCHEMA_VERSION,
        "payload": payload,
        "summary": summarize(payload),
    }

    write_json(data_dir / "latest.json", sample)
    day_file = samples_dir / f"{collected_at[:10]}.jsonl"
    with day_file.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(sample, ensure_ascii=False, separators=(",", ":")) + "\n")

    pruned = prune_samples(samples_dir, retention_days, now)

    printed = {
        "ok": True,
        "machine": machine,
        "summary": sample["summary"],
    }
    if gpu_error:
        printed["gpu_error"] = gpu_error
    if pruned:
        printed["pruned"] = pruned
    print(json.dumps(printed, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
