#!/usr/bin/env python3
"""Tests for the sample collector. Stdlib only: ``python3 -m unittest discover -s tests``."""

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

BIN = Path(__file__).resolve().parent.parent / "bin"
spec = importlib.util.spec_from_file_location("collect", BIN / "collect.py")
collect = importlib.util.module_from_spec(spec)
sys.modules["collect"] = collect
spec.loader.exec_module(collect)


def make_payload(gpus=None, cpu_util=0.0, mem=(100, 50), disks=None):
    total, used = mem
    return {
        "machine": "test",
        "collected_at": "2026-01-01T00:00:00Z",
        "loadavg": [1.0, 1.0, 1.0],
        "cpu": {"cores": 8, "utilization_pct": cpu_util, "window_seconds": 60},
        "memory": {"total_mib": total, "used_mib": used, "free_mib": 1, "available_mib": 1,
                   "swap_total_mib": 0, "swap_used_mib": 0},
        "gpus": gpus or [],
        "processes": [],
        "disks": disks or [],
    }


def gpu(index=0, util=0.0, used=1, total=1000, temp=30.0, power=100.0):
    return {
        "index": index,
        "name": "NVIDIA TEST",
        "utilization_gpu_pct": util,
        "memory_used_mib": used,
        "memory_total_mib": total,
        "temperature_c": temp,
        "power_draw_w": power,
        "power_limit_w": 700.0,
    }


class CpuUtilizationTests(unittest.TestCase):
    def test_busy_interval(self):
        previous = {"total": 1000, "idle": 800, "ts": 0}
        current = {"total": 2000, "idle": 1200, "ts": 60}
        self.assertEqual(collect.cpu_utilization(previous, current), 60.0)

    def test_idle_interval(self):
        previous = {"total": 1000, "idle": 900, "ts": 0}
        current = {"total": 2000, "idle": 1900, "ts": 60}
        self.assertEqual(collect.cpu_utilization(previous, current), 0.0)

    def test_first_run_has_no_average(self):
        self.assertIsNone(collect.cpu_utilization(None, {"total": 2000, "idle": 1200, "ts": 60}))

    def test_counter_reset_is_unknown_not_zero(self):
        previous = {"total": 2000, "idle": 1200, "ts": 60}
        current = {"total": 10, "idle": 8, "ts": 120}
        self.assertIsNone(collect.cpu_utilization(previous, current))

    def test_idle_counter_going_backwards_is_unknown(self):
        previous = {"total": 1000, "idle": 900, "ts": 0}
        current = {"total": 2000, "idle": 10, "ts": 60}
        self.assertIsNone(collect.cpu_utilization(previous, current))


class CollectCpuTests(unittest.TestCase):
    def test_state_round_trip_gives_window(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "cpu.json"
            first = collect.collect_cpu(state, 1000.0)
            self.assertIsNone(first["utilization_pct"])
            self.assertTrue(state.exists())
            collect.write_json(state, {"total": 100, "idle": 80, "ts": 1000.0})
            counters = collect.read_cpu_counters()
            if counters is None:  # /proc/stat unavailable on this host
                self.skipTest("/proc/stat is not readable here")
            second = collect.collect_cpu(state, 1060.0)
            self.assertIsNotNone(second["window_seconds"])


class SummarizeTests(unittest.TestCase):
    def test_full_when_every_gpu_is_busy(self):
        payload = make_payload([gpu(0, 90), gpu(1, 95), gpu(2, 88)])
        self.assertEqual(collect.summarize(payload)["status"], "full")

    def test_warm_at_seventy_percent_average(self):
        payload = make_payload([gpu(0, 80), gpu(1, 70), gpu(2, 60)])
        self.assertEqual(collect.summarize(payload)["status"], "warm")

    def test_partial_at_twenty_percent_average(self):
        payload = make_payload([gpu(0, 30), gpu(1, 10)])
        self.assertEqual(collect.summarize(payload)["status"], "partial")

    def test_idle_below_twenty_percent_average(self):
        payload = make_payload([gpu(0, 5), gpu(1, 0)])
        self.assertEqual(collect.summarize(payload)["status"], "idle")

    def test_offline_when_no_gpu_is_visible(self):
        summary = collect.summarize(make_payload([]))
        self.assertEqual(summary["status"], "offline")
        self.assertEqual(summary["gpu_count"], 0)
        self.assertIsNone(summary["avg_util"])

    def test_memory_and_cpu_are_reported(self):
        summary = collect.summarize(make_payload([gpu()], cpu_util=42.5, mem=(1000, 250)))
        self.assertEqual(summary["cpu_util_pct"], 42.5)
        self.assertEqual(summary["mem_used_pct"], 25.0)

    def test_disk_risk_picks_the_fullest_mount(self):
        payload = make_payload([gpu()], disks=[
            {"mount": "/", "use_pct": 40.0},
            {"mount": "/data", "use_pct": 99.0},
        ])
        self.assertEqual(collect.summarize(payload)["disk_risk"], "/data 99%")

    def test_disk_below_threshold_is_ok(self):
        payload = make_payload([gpu()], disks=[{"mount": "/", "use_pct": 89.9}])
        self.assertEqual(collect.summarize(payload)["disk_risk"], "ok")


class SanitizeTests(unittest.TestCase):
    def test_password_is_redacted(self):
        self.assertEqual(
            collect.sanitize_command("python serve.py --password hunter2 --port 80"),
            "python serve.py --password [redacted] --port 80",
        )

    def test_token_with_equals_is_redacted(self):
        self.assertEqual(
            collect.sanitize_command("api.py token=abc123"),
            "api.py token=[redacted]",
        )

    def test_ip_address_is_removed(self):
        self.assertEqual(
            collect.sanitize_command("worker --master 10.0.0.7:8080"),
            "worker --master [ip]:8080",
        )

    def test_long_command_is_bounded(self):
        self.assertEqual(len(collect.sanitize_command("x" * 400)), 220)


class SampleFileTests(unittest.TestCase):
    def test_prune_compresses_only_days_past_retention(self):
        with tempfile.TemporaryDirectory() as tmp:
            samples = Path(tmp)
            (samples / "2026-01-01.jsonl").write_text("{}\n", encoding="utf-8")
            (samples / "2026-01-10.jsonl").write_text("{}\n", encoding="utf-8")
            now = 1767225600.0  # 2026-01-01T00:00:00Z
            pruned = collect.prune_samples(samples, 7, now)
            self.assertEqual(pruned, [])
            self.assertTrue((samples / "2026-01-01.jsonl").exists())

    def test_prune_is_off_when_retention_is_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            samples = Path(tmp)
            (samples / "2020-01-01.jsonl").write_text("{}\n", encoding="utf-8")
            self.assertEqual(collect.prune_samples(samples, 0, 1767225600.0), [])

    def test_sample_has_schema_version(self):
        sample = {"schema": collect.SCHEMA_VERSION, "payload": make_payload([gpu()])}
        self.assertEqual(sample["schema"], 1)
        json.dumps(sample)  # must stay serialisable


if __name__ == "__main__":
    unittest.main()
