#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part1.sh
# Description: OpenWrt DIY script part 1 (Before Update feeds)
#
# Copyright (c) 2019-2024 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

# fail-loud: 任一命令出错 / 未定义变量 / 管道中段失败 → 立即中断构建。
# 与 diy-part2.sh 一致, 让设备钩子或未来新增定制的失败在构建期响亮暴露,
# 而非静默放过。GitHub Actions 步骤默认 bash -e, 子脚本非零退出即令该步失败。
set -euo pipefail

# ImmortalWRT Migration Note:
# - OpenClash is now built-in (packages/net/openclash)
# - No need for external feeds (kenzok8/openwrt-packages, kenzok8/small)
# - All required packages are available in official ImmortalWRT feeds

# Add custom feeds here if needed (currently none required)
# echo 'src-git custom https://github.com/example/custom-packages' >>feeds.conf.default

# --- Device-specific pre-feeds hook ---
# matrix 构建注入 $DEVICE; 若该设备有 pre-feeds.sh 则在 feeds update 前执行
# (例: r5s-outdoor 用它追加 outdoor-backup feed)。
# ${VAR:-} 兼容 set -u 下 DEVICE/GITHUB_WORKSPACE 未注入的本地场景。
DEVICE_HOOK="${GITHUB_WORKSPACE:-.}/devices/${DEVICE:-}/pre-feeds.sh"
if [ -n "${DEVICE:-}" ] && [ -f "$DEVICE_HOOK" ]; then
  echo "==> Running device hook: devices/${DEVICE}/pre-feeds.sh"
  # shellcheck source=/dev/null  # 钩子路径运行期由 $DEVICE 决定, 无法静态解析
  . "$DEVICE_HOOK"
fi
