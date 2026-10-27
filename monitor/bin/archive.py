#!/usr/bin/env python3
"""Roll a finished UTC day's minute samples into one summary file.

Run after midnight (cron). Each output is ``<data>/archives/<day>.summary.json``
and is idempotent: re-running the same day rewrites the same numbers.

The summary answers the questions a month of minute samples makes expensive:
how loaded was the day, how much energy did it draw, which account held the
GPUs, and where the recording itself had holes. Coverage and gaps are reported
rather than smoothed over — a day with 60% coverage is not a quiet day.
"""

import gzip
import json
import math
import os
import time
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

# A gap longer than this between consecutive samples is a recording hole, not
# jitter: cron runs every minute, so 150s is two missed runs plus slack.
GAP_SECONDS = 150


def sample_paths(samples_dir):
    return sorted(
        list(Path(samples_dir).glob("*.jsonl")) + list(Path(samples_dir).glob("*.jsonl.gz"))
    )


def load_samples(path):
    """Read a sample file, plain or gzipped, skipping lines that do not parse."""
    opener = gzip.open if path.suffix == ".gz" else open
    try:
        with opener(path, "rt", encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return []
    rows = []
    for line in lines:
        if not line.strip():
            continue
        try:
            rows.append(json.loads(line))
        except ValueError:
            continue
    return rows


def parse_time(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def avg(values):
    values = [value for value in values if isinstance(value, (int, float)) and math.isfinite(value)]
    return round(sum(values) / len(values), 1) if values else None


def pct(numerator, denominator):
    return round(numerator / denominator * 100, 1) if denominator else 0.0


def interval_text(start, end):
    return f"{start.strftime('%H:%M')}-{end.strftime('%H:%M')} UTC"


def summarize_day(day, rows):
    machine = rows[-1].get("payload", {}).get("machine", "GPU") if rows else "GPU"
    per_gpu = defaultdict(lambda: {"util": [], "mem": [], "power": [], "temp": []})
    statuses = Counter()
    process_counts = Counter()
    disk_risks = []
    low_intervals = []
    gap_intervals = []
    current_low = None
    last_ts = None

    total_power_series = []
    avg_util_series = []
    avg_mem_series = []
    cpu_series = []
    system_mem_series = []

    for row in rows:
        payload = row.get("payload", {})
        summary = row.get("summary", {})
        collected_at = payload.get("collected_at")
        if not collected_at:
            continue
        ts = parse_time(collected_at)

        status = summary.get("status", "offline")
        statuses[status] += 1
        if summary.get("disk_risk") and summary["disk_risk"] != "ok":
            disk_risks.append({"time": collected_at, "risk": summary["disk_risk"]})
        if last_ts and (ts - last_ts).total_seconds() > GAP_SECONDS:
            gap_intervals.append(interval_text(last_ts, ts))
        last_ts = ts

        low = status in {"partial", "idle", "offline"}
        if low and current_low is None:
            current_low = ts
        elif not low and current_low is not None:
            low_intervals.append(interval_text(current_low, ts))
            current_low = None

        if summary.get("cpu_util_pct") is not None:
            cpu_series.append(summary["cpu_util_pct"])
        if summary.get("mem_used_pct") is not None:
            system_mem_series.append(summary["mem_used_pct"])

        for gpu in payload.get("gpus", []):
            idx = str(gpu.get("index", "?"))
            total = max(gpu.get("memory_total_mib", 0), 1)
            per_gpu[idx]["util"].append(gpu.get("utilization_gpu_pct", 0))
            per_gpu[idx]["mem"].append(gpu.get("memory_used_mib", 0) / total * 100)
            per_gpu[idx]["power"].append(gpu.get("power_draw_w", 0))
            per_gpu[idx]["temp"].append(gpu.get("temperature_c", 0))

        for proc in payload.get("processes", []):
            key = (
                proc.get("user", ""),
                proc.get("process_name", ""),
                proc.get("command", ""),
            )
            process_counts[key] += 1

        gpus = payload.get("gpus", [])
        total_power_series.append(sum(gpu.get("power_draw_w", 0) for gpu in gpus))
        avg_util_series.append(avg([gpu.get("utilization_gpu_pct", 0) for gpu in gpus]))
        avg_mem_series.append(avg([
            gpu.get("memory_used_mib", 0) / max(gpu.get("memory_total_mib", 1), 1) * 100
            for gpu in gpus
        ]))

    if current_low is not None and rows:
        last_payload = rows[-1].get("payload", {})
        if last_payload.get("collected_at"):
            low_intervals.append(interval_text(current_low, parse_time(last_payload["collected_at"])))

    sample_count = len(rows)
    per_gpu_summary = {}
    for idx, values in per_gpu.items():
        per_gpu_summary[idx] = {
            "avg_util": avg(values["util"]),
            "min_util": min(values["util"]) if values["util"] else None,
            "max_util": max(values["util"]) if values["util"] else None,
            "avg_mem_pct": avg(values["mem"]),
            "avg_power_w": avg(values["power"]),
            "max_temp_c": max(values["temp"]) if values["temp"] else None,
        }

    energy_wh = sum(value for value in total_power_series if isinstance(value, (int, float))) / 60

    return {
        "day": day,
        "machine": machine,
        "sample_count": sample_count,
        "coverage_pct": pct(sample_count, 1440),
        "avg_gpu_util": avg(avg_util_series),
        "avg_gpu_mem_pct": avg(avg_mem_series),
        "avg_power_w": avg(total_power_series),
        "estimated_energy_kwh": round(energy_wh / 1000, 2),
        "avg_cpu_util": avg(cpu_series),
        "max_cpu_util": max(cpu_series) if cpu_series else None,
        "avg_system_mem_pct": avg(system_mem_series),
        "max_system_mem_pct": max(system_mem_series) if system_mem_series else None,
        "status_minutes": dict(statuses),
        "full_minutes": statuses.get("full", 0),
        "low_util_minutes": (
            statuses.get("partial", 0) + statuses.get("idle", 0) + statuses.get("offline", 0)
        ),
        "per_gpu": per_gpu_summary,
        "top_processes": [
            {"user": user, "process": name, "command": command, "minutes_seen": minutes}
            for (user, name, command), minutes in process_counts.most_common(12)
        ],
        "disk_risks": disk_risks[:24],
        "low_util_intervals": low_intervals[:24],
        "gap_intervals": gap_intervals[:24],
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


def main():
    home = Path(os.environ.get("MONITOR_HOME", str(Path.home() / "gpu-monitor")))
    data_dir = Path(os.environ.get("MONITOR_DATA_DIR", str(home / "data")))
    samples_dir = data_dir / "samples"
    archives_dir = data_dir / "archives"
    archives_dir.mkdir(parents=True, exist_ok=True)

    today = time.strftime("%Y-%m-%d", time.gmtime())
    for path in sample_paths(samples_dir):
        day = path.name.split(".")[0]
        if day >= today:
            continue
        out = archives_dir / f"{day}.summary.json"
        rows = load_samples(path)
        if not rows:
            continue
        summary = summarize_day(day, rows)
        tmp = out.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        tmp.replace(out)
        print(f"archived {day}: {out}", flush=True)


if __name__ == "__main__":
    main()
