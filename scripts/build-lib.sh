# shellcheck shell=bash
# =============================================================================
# scripts/build-lib.sh — 构建编排的纯函数库 (单一真相源)
# =============================================================================
# 设计契约 (遵循既有 scripts/diy-lib.sh 模式):
#   本文件是**纯库**: 无 set -e / 无 trap / 无顶层副作用, 只定义函数。
#   被三方共同 source —— scripts/build-firmware.sh (构建入口)、
#   scripts/gen-matrix.sh (prepare job 薄壳)、tests/bdd-matrix-build.sh (回归)。
#   入口脚本带 `set -euo pipefail` + trap; 若本库也带 set -e, source 进 BDD
#   会把错误陷阱灌进测试进程, 纯函数返回非 0 即杀死整个套件 —— 故严禁。
#
# 用法:
#   . "$(dirname "${BASH_SOURCE[0]}")/build-lib.sh"   # 入口/测试统一这样 source
# =============================================================================

# -----------------------------------------------------------------------------
# gen_matrix <device>
#   把 workflow_dispatch 的 device choice 翻译成动态 matrix JSON。
#   空或 "all" → 全设备数组; 其余 → 单元素数组。
#   (单一真相源: prepare job 与 BDD B07-B09 共用本函数, 不再各自复刻)
# -----------------------------------------------------------------------------
gen_matrix() {
  local device="$1"
  local all='["r2s","r3s","r5s","r5s-outdoor","r68s","x86"]'
  if [ -z "$device" ] || [ "$device" = "all" ]; then
    echo "$all"
  else
    echo "[\"$device\"]"
  fi
}

# -----------------------------------------------------------------------------
# assemble_config <common> <seed> [extra...]
#   拼装契约: common.config + devices/<dev>/seed.config [+ 可选 extra] → stdout。
#   顺序铁律: common 在前 (全设备交集), seed 居中 (设备 delta), extra 殿后
#   (私有注入支点, 如 wizard 包符号; 后写覆盖前写, 故 extra 能追加/改写)。
#   纯函数: 只 cat 到 stdout, 由调用方决定落盘位置。
# -----------------------------------------------------------------------------
assemble_config() {
  cat "$@"
}

# -----------------------------------------------------------------------------
# clash_arch <config-file>
#   按 .config 的 TARGET 符号选 Clash 核心架构, 不依赖分支名。
#   x86 → amd64; 其余 (rockchip_armv8: r2s/r3s/r5s/r5s-outdoor/r68s) → arm64。
# -----------------------------------------------------------------------------
clash_arch() {
  local config="$1"
  if grep -q '^CONFIG_TARGET_x86=y' "$config"; then
    echo amd64
  else
    echo arm64
  fi
}

# -----------------------------------------------------------------------------
# prune_residual_dl <dl-dir>
#   清理 make download 产生的残缺包 (<1KB 的错误页/截断下载)。
#   关键作用域: -maxdepth 1 -type f 只清 dl/ 顶层下载包, 不可递归进
#   dl/go-mod-cache/ —— 后者含大量合法的小 .go 源文件 (如 frp 依赖的
#   fatedier/golib/errors/errors.go 800B), 误删会导致 go 离线编译报
#   "no required module provides package", frp [host] 编译失败 (issue #9)。
#   (单一真相源: workflow 与 BDD B18 共用本函数)
# -----------------------------------------------------------------------------
prune_residual_dl() {
  local dl="$1"
  find "$dl" -maxdepth 1 -type f -size -1024c -exec ls -l {} \;
  find "$dl" -maxdepth 1 -type f -size -1024c -exec rm -f {} \;
}

# -----------------------------------------------------------------------------
# clone_openwrt <repo-url> <repo-branch> <tag> <dest>
#   浅克隆 ImmortalWRT 到 <dest>, 若给了 <tag> 则 checkout 该 tag。
#   (单一真相源: build-firmware.sh 默认路径与 CI 的 clone step 共用本函数,
#    因 cache action 必须夹在 clone 与 download 之间, CI 走 --skip-clone,
#    自行在 YAML 里调本函数 clone, 故 clone 逻辑只此一份)
# -----------------------------------------------------------------------------
clone_openwrt() {
  local url="$1" branch="$2" tag="$3" dest="$4"
  git clone "$url" -b "$branch" "$dest" --depth=1
  if [ -n "$tag" ]; then
    echo "Checking out tag: $tag"
    git -C "$dest" fetch --depth=1 origin tag "$tag"
    git -C "$dest" checkout "tags/$tag"
  else
    echo "No tag specified, using latest from branch: $branch"
  fi
}
