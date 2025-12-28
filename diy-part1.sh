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
