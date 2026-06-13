#!/usr/bin/env bash
# =============================================================================
# scripts/gen-matrix.sh — prepare job 薄入口: device choice → 动态 matrix JSON
# =============================================================================
# 纯逻辑 (gen_matrix) 在 scripts/build-lib.sh, 与 BDD B07-B09 共用单一真相源。
# 本壳只负责 source 库 + 调函数 + 输出 (stdout 给本地, $GITHUB_OUTPUT 给 CI)。
#
# 用法:
#   scripts/gen-matrix.sh <device>          # 本地: matrix JSON 打到 stdout
#   INPUT_DEVICE=all scripts/gen-matrix.sh   # 等价 (无参时读 $INPUT_DEVICE)
# =============================================================================
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/build-lib.sh
. "$SELF_DIR/build-lib.sh"

# device 取值: 位置参数优先, 回退 $INPUT_DEVICE (CI 经 env 注入, 防表达式注入)
DEVICE="${1:-${INPUT_DEVICE:-}}"
MATRIX="$(gen_matrix "$DEVICE")"

echo "Build matrix: $MATRIX" >&2
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "matrix=$MATRIX" >> "$GITHUB_OUTPUT"
fi
echo "$MATRIX"
