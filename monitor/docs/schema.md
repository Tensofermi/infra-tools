# Sample schema (v1)

One sample is one JSON object. It is written twice per run:

* `<data>/latest.json` — the most recent sample, pretty-printed
* `<data>/samples/<UTC-day>.jsonl` — one compact line per sample, appended

`collect.py` writes it; `archive.py`, `dashboard.py` and any future reader only
ever read it. **This file is the contract.** Changing a field's meaning, or
removing one, means bumping `schema`.

```jsonc
{
  "schema": 1,
  "payload": { ... },
  "summary": { ... }
}
```

## Null means "not measured"

Every numeric field may be `null`, and `null` is not `0`.

| Value | Meaning |
|---|---|
| `0.0` | measured, and the measurement was zero |
| `null` | no reading: first CPU sample, unreadable file, counter reset |

A consumer must render `null` as "—" or "unknown". Substituting `0` turns a
recording failure into a report of idle hardware, which is the one lie a
monitor cannot afford.

## `payload`

| Field | Type | Notes |
|---|---|---|
| `machine` | string | `MONITOR_MACHINE`, default short hostname |
| `collected_at` | string | UTC, `YYYY-MM-DDTHH:MM:SSZ`, second resolution |
| `loadavg` | [number] | 1/5/15-minute load average, `[]` where unavailable |
| `cpu` | object | see below |
| `memory` | object | `free -m`, all values MiB |
| `gpus` | [object] | one per GPU; `[]` when none is visible |
| `gpu_error` | string | present only when `nvidia-smi` failed; says why |
| `processes` | [object] | at most 24, GPU compute processes only |
| `disks` | [object] | the mounts from `DISK_MOUNTS` that exist |

### `cpu`

| Field | Type | Notes |
|---|---|---|
| `cores` | int | logical CPUs |
| `utilization_pct` | number \| null | busy share over `window_seconds` |
| `window_seconds` | int \| null | interval the average covers |

`utilization_pct` comes from two readings of `/proc/stat` (this run and the
previous run's saved counters), not from a momentary glance. The average is
therefore over roughly one minute when cron runs every minute, and
`window_seconds` says exactly how long. A reboot or counter wrap makes the two
readings incomparable and the field `null`; the next run has an average again.

### `memory`

| Field | Type |
|---|---|
| `total_mib`, `used_mib`, `free_mib`, `available_mib` | int |
| `swap_total_mib`, `swap_used_mib` | int |

### `gpus[]`

| Field | Type | Notes |
|---|---|---|
| `index` | int | NVML index |
| `name` | string | e.g. `NVIDIA H200` |
| `utilization_gpu_pct` | number | share of the sample window with a kernel running |
| `memory_used_mib`, `memory_total_mib` | int | framebuffer allocation, not activity |
| `temperature_c` | number | on-die sensor |
| `power_draw_w`, `power_limit_w` | number | board power and its cap |

`utilization_gpu_pct` answers "was something running", not "was the machine
full". One kernel on one SM reads 100%.

### `processes[]`

| Field | Type | Notes |
|---|---|---|
| `gpu` | string | PCI bus id as NVML reports it |
| `pid` | int | |
| `process_name` | string | basename, max 80 chars |
| `used_memory_mib` | int | |
| `user`, `elapsed` | string | from `ps`; `elapsed` is `[[dd-]hh:]mm:ss` |
| `command` | string | from `ps`, credentials and IPs redacted, max 220 chars |

Redaction replaces the value after `password`/`passwd`/`token`/`secret`/`key`/
`api_key` with `[redacted]`, every IPv4 address with `[ip]`, and truncates the
result. The `user`/`elapsed`/`command` fields are absent when `ps` could not be
read.

### `disks[]`

| Field | Type | Notes |
|---|---|---|
| `filesystem` | string | |
| `size`, `used`, `avail` | string | `df -h` units |
| `use_pct` | number | |
| `mount` | string | |

## `summary`

Derived by `summarize()` from the payload alone. Recomputable at any time.

| Field | Type | Notes |
|---|---|---|
| `gpu_count` | int | |
| `avg_util`, `min_util`, `max_util` | number \| null | across GPUs; `null` with no GPUs |
| `avg_mem_pct` | number \| null | mean of `memory_used/total` per GPU |
| `total_power_w` | number \| null | sum over GPUs |
| `max_temp_c` | number \| null | |
| `cpu_util_pct` | number \| null | copied from `cpu.utilization_pct` |
| `mem_used_pct` | number \| null | system RAM |
| `swap_used_pct` | number \| null | |
| `status` | string | `full`, `warm`, `partial`, `idle`, `offline` |
| `disk_risk` | string | `"<mount> <pct>%"` of the fullest disk ≥90%, else `"ok"` |

### `status`

| Value | Rule |
|---|---|
| `full` | at least one GPU and `min_util >= 85` |
| `warm` | `avg_util >= 70` |
| `partial` | `avg_util >= 20` |
| `idle` | otherwise, with GPUs present |
| `offline` | no GPU visible at all |

`offline` describes the reading, not the machine: a host without NVIDIA cards
reports `offline` every minute, and any consumer that means "this machine is
down" must use its own heartbeat, not this field.

## Archive (`archives/<day>.summary.json`)

One file per finished UTC day, written by `archive.py`. Adds:

* `sample_count`, `coverage_pct` — against a full 1440-minute day
* `avg_gpu_util`, `avg_gpu_mem_pct`, `avg_power_w`, `estimated_energy_kwh`
* `avg_cpu_util`, `max_cpu_util`, `avg_system_mem_pct`, `max_system_mem_pct`
* `status_minutes`, `full_minutes`, `low_util_minutes`
* `per_gpu` — per-index averages and maxima
* `top_processes` — most-seen processes, by user/name/redacted command
* `low_util_intervals`, `gap_intervals` — UTC `HH:MM-HH:MM` strings

`coverage_pct` below 100 and a non-empty `gap_intervals` say the recording had
holes. They are reported, never interpolated away.
