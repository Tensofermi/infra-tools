# qgpu

A self-contained GPU job queue for any NVIDIA box. One Python file set, no
dependencies beyond `python3` (stdlib only) and `nvidia-smi`; no config files
from the host are assumed, and nothing is hardcoded to a specific machine, card
count or model.

Submit a command, let the scheduler wait for a genuinely idle GPU, and get
`CUDA_VISIBLE_DEVICES` set for you.

It is deliberately not Slurm: no priorities, no preemption, no reservations.
What it does:

1. stores queued jobs in SQLite;
2. inspects the *real* GPU state (any user, not just qGPU jobs);
3. assigns one or more GPUs to a job;
4. exports `CUDA_VISIBLE_DEVICES` and launches the command;
5. records status, exit code and stdout/stderr in a log file.

## Install

Self-contained: the code is copied into a private prefix and a `qgpu` launcher
is linked on `PATH`, so the tool keeps working after the repository is deleted
or moved.

```bash
./install-fast/install-user.sh --only qgpu   # from the repo root
./qgpu/install.sh                            # or call the installer directly

./qgpu/install.sh --prefix /opt/qgpu --bin-dir /usr/local/bin
./qgpu/install.sh --remove                   # uninstall (state is kept)
```

It can also be run straight from the repo without installing:
`qgpu/run.sh`, `qgpu/stop.sh`, `qgpu/qgpu <subcommand>`.

### Layout

Code and state are separate, so a single install can serve one user's queue:

```
<prefix>/            qgpu.py scheduler.py common.py qgpu   (installed code)
$QGPU_HOME/          runtime state, default ~/.local/state/qgpu
  qgpu.db              SQLite job database
  config.json          runtime configuration
  logs/NNNNNN.log      per-job stdout/stderr
  scheduler.pid        pid of the running scheduler
  scheduler.log        scheduler daemon log
  scheduler.lock       single-instance lock
```

`QGPU_HOME` (or `qgpu --home DIR`) relocates the state; `XDG_STATE_HOME` is
honoured. `--home` is a global option, so it must come before the subcommand
(`qgpu --home /tmp/alt status`); everything after `--` belongs to the job
command and is passed through untouched. If an older copy of qGPU left
`qgpu.db` next to the scripts, that directory keeps being used as the state
dir, so existing queues survive the upgrade.

## Quick start

```bash
qgpu detect                      # which GPUs does nvidia-smi see?
qgpu start                       # start the background scheduler (idempotent)
qgpu status                      # scheduler state, queue counters, per-GPU view

cd ~/project && conda activate myenv
qgpu submit --name L12-seed42 -- python train.py --config configs/L12.toml
qgpu list
qgpu logs -f 12
```

Everything after `--` is executed verbatim. A job is only started when a card
is free, so `submit` returns immediately with a job id; `pending` does not mean
running yet.

## Commands

| Command | Meaning |
|---------|---------|
| `qgpu start` | start the scheduler (no-op if already running) |
| `qgpu stop` | stop scheduling new jobs; running jobs keep going |
| `qgpu status` | scheduler state, queue counters, per-GPU memory / pids |
| `qgpu detect` | raw `nvidia-smi` inventory plus the resolved pool / cap |
| `qgpu submit` (`sb`) | queue a job; see flags below |
| `qgpu list` (`ls`) | recent jobs, optionally `--status pending` |
| `qgpu show ID` | full detail for one job, including queue position |
| `qgpu logs ID [-f] [-n N]` | tail the job log |
| `qgpu cancel ID` (`scancel`) | cancel a pending job or stop a running one |
| `qgpu retry ID` | re-queue a finished job under a new id |
| `qgpu promote ID` / `qgpu demote ID` | move a pending job to the queue front / back |
| `qgpu config` | print config; flags below change it |

`submit` flags:

| Flag | Meaning |
|------|---------|
| `--name NAME` | label for the job (defaults to the command's basename) |
| `--gpus N` | request N free GPUs, default 1 |
| `--gpu-ids IDS` | wait for specific physical GPUs (`5`, `5,6`, `3-6`); overrides `--gpus` |
| `--cwd DIR` | working directory, default the current one |
| `--env K=V` | extra environment variable, repeatable |

`config` flags: `--max-gpus N`, `--gpu-pool IDS` (or `auto`),
`--poll-seconds S`, `--free-memory-mib M`. Changes take effect on the next
scheduling round, no restart needed.

## Any card count, any model

Nothing assumes eight H200s. The pool is discovered from `nvidia-smi` at every
scheduling round, so qGPU adapts to:

- **any number of GPUs** — 1, 2, 4, 8, 16 …; `max_gpus` defaults to the whole
  pool and `--gpus N` is validated against what is actually visible;
- **mixed models / VRAM sizes** — free cards are ordered by free memory, so the
  emptiest card is picked first;
- **non-contiguous indices** — `CUDA_VISIBLE_DEVICES` is built from the real
  physical indices reported by the driver;
- **changing hardware** — driver reload, a card dropping out, or moving the
  config to a smaller box; indices that are not visible are ignored and
  `max_gpus` is clamped to the visible count, with a note in `qgpu status`;
- **no GPU at all** — `qgpu detect` / `qgpu status` report the reason instead of
  crashing, and the scheduler keeps polling.

`gpu_pool: []` in `config.json` means "all visible GPUs" (the default), `0` for
`max_gpus` means "the size of the pool".

## Examples

```bash
# two-card DDP job
qgpu submit --name L22-ddp --gpus 2 -- \
  torchrun --standalone --nproc_per_node=2 train.py

# pin to GPU 5 and 6
qgpu submit --gpu-ids 5,6 -- bash runs/L22.sh

# shell features need an explicit shell
qgpu submit --name special -- \
  bash -lc 'source env.sh && python -u train.py 2>&1 | tee train.log'

# a batch of single-card runs, no manual waiting
for cfg in L8 L10 L12 L15; do qgpu submit --name "$cfg" -- bash "runs/$cfg.sh"; done
```

## When is a GPU considered free?

Every `poll_seconds` (default 2 s) the scheduler reads `nvidia-smi` and checks:

1. the card is in the pool;
2. the card is not already assigned to another qGPU job;
3. the card has no NVIDIA compute process from **any** user;
4. the card's used memory is at most `free_memory_mib` (default 1024).

Other users' training is therefore avoided without relying on usernames. There
is still a small race between "looks free" and "launch", which is unavoidable
without taking over the whole machine.

Defaults:

```json
{
  "max_gpus": 0,
  "gpu_pool": [],
  "poll_seconds": 2.0,
  "free_memory_mib": 1024
}
```

`max_gpus` caps the total GPUs held by qGPU jobs at once; it is not a fixed set
of cards. `max_gpus` may not exceed the size of the pool.

## Notes

- Jobs and the scheduler are detached from the SSH session; no `nohup` needed.
  Do not background the submitted command itself, qGPU tracks the foreground
  process to know when the job ended.
- Environments are inherited: `PATH`, `PYTHONPATH`, `LD_LIBRARY_PATH`, the
  active conda/virtualenv, HF/Torch cache paths and `CUDA_*` / `NCCL_*` /
  `TORCH_*` / `OMP_*` / `MKL_*` / `PYTORCH_*` variables. `CUDA_VISIBLE_DEVICES`
  from the submitting shell is ignored. Anything else has to be passed with
  `--env`. Secrets are not captured.
- Inside a job, `QGPU_JOB_ID` and `QGPU_PHYSICAL_GPU_IDS` are exported.
- `qgpu stop` never kills running jobs; use `qgpu cancel ID` for that.
- Linux + NVIDIA only; macOS has no `nvidia-smi` and is not supported.
- State is per user, not shared: two users on the same box get two queues that
  still see each other's GPU usage.
- A card whose driver reports `[N/A]` for a numeric field (seen on some MIG /
  virtualised setups) is skipped instead of being treated as idle. If
  `nvidia-smi --query-compute-apps` fails, other users' processes are not
  visible and the idle check falls back to the memory threshold alone.
