#!/usr/bin/env bash
# 停止 qGPU 后台调度器；已经开始运行的训练不会被终止。
set -euo pipefail

QGPU_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec "$QGPU_DIR/qgpu" stop

