#!/usr/bin/env bash
# 启动 qGPU 后台调度器；重复执行不会启动多个实例。
set -euo pipefail

QGPU_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec "$QGPU_DIR/qgpu" start

