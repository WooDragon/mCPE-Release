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

# ImmortalWRT Migration Note:
# - OpenClash is now built-in (packages/net/openclash)
# - No need for external feeds (kenzok8/openwrt-packages, kenzok8/small)
# - All required packages are available in official ImmortalWRT feeds

# Add custom feeds here if needed (currently none required)
# echo 'src-git custom https://github.com/example/custom-packages' >>feeds.conf.default

# --- Device-specific pre-feeds hook ---
# matrix 构建注入 $DEVICE; 若该设备有 pre-feeds.sh 则在 feeds update 前执行
# (例: r5s-outdoor 用它追加 outdoor-backup feed)
DEVICE_HOOK="$GITHUB_WORKSPACE/devices/$DEVICE/pre-feeds.sh"
if [ -n "$DEVICE" ] && [ -f "$DEVICE_HOOK" ]; then
  echo "==> Running device hook: devices/$DEVICE/pre-feeds.sh"
  . "$DEVICE_HOOK"
fi
