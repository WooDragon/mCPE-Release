#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#
# Copyright (c) 2019-2024 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

# fail-loud: 任一命令出错 / 未定义变量 / 管道中段失败 → 立即中断构建。
# 配合 scripts/diy-lib.sh 的 sed_required/append_required, 把"上游默认串漂移
# 导致定制静默 no-op"从运行期猝死提前为构建期响亮失败。
set -euo pipefail

# 载入"必中即改, 未中即停"定制原语 (单一真相源; BDD 也 source 同一文件做机制测试)
. "$(dirname "$0")/scripts/diy-lib.sh"

# rust download-ci-llvm patch 已随上游 tag v24.10.6 移除:
# v24.10.6 的 packages feed (pin 97af139) lang/rust/Makefile 自带
# download-ci-llvm=false, 本地编译 LLVM 是上游官方默认, 无需再 patch。详见 issue #9。

# --- Start: Add UCI Defaults script for custom settings ---

# Create the uci-defaults directory within the base-files package structure
mkdir -p package/base-files/files/etc/uci-defaults

# Create the uci-defaults script file (e.g., 99-custom-settings)
cat <<EOF > package/base-files/files/etc/uci-defaults/99-custom-settings
#!/bin/sh
# Set the LAN IP address
uci set network.lan.ipaddr='192.168.233.1'
uci commit network
# Set the system hostname
uci set system.@system[0].hostname='MCPE'
uci commit system
# Exit successfully
exit 0
EOF

# Make the uci-defaults script executable
chmod +x package/base-files/files/etc/uci-defaults/99-custom-settings

echo "Added UCI Defaults script: package/base-files/files/etc/uci-defaults/99-custom-settings"

# --- End: Add UCI Defaults script ---

# --- Kernel Security: Landlock LSM (直注内核配置片段) ---
# SECURITYFS / SECURITY_LANDLOCK / LSM 在 OpenWrt Config-kernel.in 无有效入口,
# CONFIG_KERNEL_* 写 seed 会被 OpenWrt defconfig 静默剥掉;
# 直注 target/linux/generic/config-6.6 是社区标准做法。
# 注: CONFIG_SECURITY=y 已由 common.config 的 CONFIG_KERNEL_SECURITY=y 通过 OpenWrt
# Kconfig 正常注入, 此处不重复 sed (冗余注入会在上游启用该选项时触发假阳性 fail-loud)。
sed_required "kernel: enable CONFIG_SECURITYFS (/sys/kernel/security auto-mount)" \
  's/^# CONFIG_SECURITYFS is not set$/CONFIG_SECURITYFS=y/' \
  target/linux/generic/config-6.6

sed_required "kernel: enable CONFIG_SECURITY_LANDLOCK" \
  's/^# CONFIG_SECURITY_LANDLOCK is not set$/CONFIG_SECURITY_LANDLOCK=y/' \
  target/linux/generic/config-6.6

# LSM 列表: 反向匹配 + 捕获组动态追加。
# /landlock/! 确保: 若上游已自带 landlock, 该行含 "landlock" 则 sed 跳过 → 文件未改 →
# sed_required fail-loud 触发, 逼迫维护者清理废弃 patch。
# 上游增删其他 LSM (如加 bpf) 不影响 — 捕获组 \(.*\) 抓取任意内容再追加。
sed_required "kernel: append landlock to CONFIG_LSM activation list" \
  '/landlock/! s/^CONFIG_LSM="\(.*\)"$/CONFIG_LSM="\1,landlock"/' \
  target/linux/generic/config-6.6

# Modify default theme (bootstrap -> argon)
# 仅 patch luci-nginx collection: 这是本项目实际编译的集合 (.config 选 luci-nginx,
# 不装 luci 元包/不走 uhttpd/不装 luci-ssl-nginx)。v24.10.6 上 luci/Makefile 已无
# theme 行 (theme 下沉 luci-light), luci-ssl-nginx 已并入 luci-nginx, 故那两条旧
# sed 是死代码, 已删除。若上游连 luci-nginx 也改了默认 theme, fail-loud 会中断
# 构建提示我们重新评估, 而非静默漏掉 argon。
sed_required "theme: luci-nginx bootstrap->argon" \
  's/luci-theme-bootstrap/luci-theme-argon/g' \
  feeds/luci/collections/luci-nginx/Makefile

# Change Password
# 单引号刻意保留 hash 字面量 $1$... (MD5 crypt 前缀), 不可改双引号否则 shell 展开破坏。
# shellcheck disable=SC2016
sed_required "shadow: set root password hash" \
  's@root.*@root:$1$4Y0U89hL$FJkkEvZLUkiL4bwuwiPRJ/:19216:0:99999:7:::@g' \
  package/base-files/files/etc/shadow

# Env
sed_required "profile: export TERM=xterm" \
  '/export PATH="%PATH%"/a export TERM=xterm' \
  package/base-files/files/etc/profile

# SSH: 端口 65422 + 禁用密码认证 + 解绑 lan (使 dropbear 监听 WAN 侧 65422)
DROPBEAR_CFG="package/network/services/dropbear/files/dropbear.config"
sed_required "dropbear: port 22->65422" \
  "s/'22'/'65422'/g" "$DROPBEAR_CFG"
sed_required "dropbear: RootPasswordAuth off" \
  "s/RootPasswordAuth 'on'/RootPasswordAuth 'off'/g" "$DROPBEAR_CFG"
sed_required "dropbear: PasswordAuth off" \
  "s/PasswordAuth 'on'/PasswordAuth 'off'/g" "$DROPBEAR_CFG"
# Interface 行: 用 [[:space:]]* 容差正则, 不依赖上游空格数量
# (v24.10.4 是 4 空格, v24.10.6 改为 1 空格; 硬编码空格数会静默失效 -> WAN SSH 哑火)
sed_required "dropbear: unbind lan interface (enable WAN SSH)" \
  "s/option Interface[[:space:]]*'lan'/#&/g" "$DROPBEAR_CFG"

mkdir -p package/base-files/files/etc/dropbear
echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDBwECtUHN6VDe8QFmlgNm4meZ32VP9JiIEH0+wo3eh+Gs2dibZGJKzPBsQM3XphfailDgYiZbTHfKzNCpAk+SnvcwIPXy8wZ1AwWjN9Jf6qULeI8VI84Ik0cDa9byI5S99894gAh9Um7Jo34ns2REdCLrdABa37E/ZgiJJVtWblxHSlMAfr9vbmFjTETe1rD7L3FbytBLbExo3wylb2+eLwPRtaDdShFDLJJFd5PRTIVYKACXfaywdODAX0WCa09yIm29b0lGuaAukPk0rzSpyN5dG/muevQ3LpNt/r5jPkEwcPerHHSoDRgxvhLe8QO01izhbUugWJ3LFvr15M9Qd" > package/base-files/files/etc/dropbear/authorized_keys

# Firewall: 放行 WAN 侧 65422 SSH
append_required "firewall: allow WAN SSH on 65422" \
  "package/network/config/firewall/files/firewall.config" \
  '# Allow WAN SSH on 65422
config rule
        option name             Allow-WAN-SSH
        option src              wan
        option proto            tcp
        option dest_port        65422
        option target           ACCEPT
        option family           ipv4'

# Sysctl: 转发 / BBR / conntrack 调优 / 缓冲区
append_required "sysctl: forwarding + BBR + conntrack tuning" \
  "package/base-files/files/etc/sysctl.conf" \
  'net.ipv4.ip_forward=1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.conf.default.rp_filter=0
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter = 0
net.netfilter.nf_conntrack_max = 2000000
net.netfilter.nf_conntrack_buckets = 250000
net.netfilter.nf_conntrack_generic_timeout = 60
net.netfilter.nf_conntrack_tcp_timeout_established = 1800
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 120
net.netfilter.nf_conntrack_tcp_timeout_syn_recv=30
net.netfilter.nf_conntrack_tcp_timeout_syn_sent=60
net.netfilter.nf_conntrack_udp_timeout_stream=60
net.ipv4.tcp_fastopen=3
net.ipv4.conf.all.route_localnet=1
net.ipv4.tcp_slow_start_after_idle=0
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 131072 33554432'

# Nginx conf template: 上调上传体积上限
sed_required "nginx: client_max_body_size 128M->1024M" \
  's/client_max_body_size 128M;/client_max_body_size 1024M;/g' \
  feeds/packages/net/nginx-util/files/uci.conf.template

# NOTE: .config patching logic removed - using seed config architecture
# All package selections are now declared in the seed config file (~100 lines)
# 'make defconfig' expands the seed to full config with all dependencies resolved

# --- Rockchip 首启自动扩盘: 落位 preinit 钩子到 rockchip armv8 base-files ---
# 目标路径无 openwrt/ 前缀: diy-part2.sh 由 build-firmware.sh 在 openwrt 树内执行
# (scripts/build-firmware.sh 的 `cd "$OPENWRT_DIR"` 已把 CWD 切入 openwrt 树)。
# per-target 机制保证此目录只进 rockchip 固件, x86 编译天然不打包此目录, 无需平台判断。
# 源路径用绝对变量 ${MCPE_REPO_ROOT:-${GITHUB_WORKSPACE:-}}: CWD 在 openwrt 树内,
# scripts/ 在上一级 repo 根, 不可用相对路径。
# fail-loud: 两变量皆空会退化成绝对路径 /scripts/... (cp 失败或拷错文件), 故显式断言。
MCPE_SRC_ROOT="${MCPE_REPO_ROOT:-${GITHUB_WORKSPACE:-}}"
if [ -z "$MCPE_SRC_ROOT" ]; then
  echo "ERROR [diy]: 扩盘钩子落位 — MCPE_REPO_ROOT/GITHUB_WORKSPACE 均未设置, 无法定位源文件" >&2
  exit 1
fi
mkdir -p target/linux/rockchip/armv8/base-files/lib/preinit/
cp "${MCPE_SRC_ROOT}/scripts/firstboot/79_expand_rootfs" \
   target/linux/rockchip/armv8/base-files/lib/preinit/
chmod +x target/linux/rockchip/armv8/base-files/lib/preinit/79_expand_rootfs
echo "Installed preinit hook: target/linux/rockchip/armv8/base-files/lib/preinit/79_expand_rootfs"

# --- Device-specific post-feeds hook ---
# matrix 构建注入 $DEVICE; 若该设备有 post-feeds.sh 则在系统配置阶段执行
# (例: r5s-outdoor 用它注入 WiFi UCI defaults)。
# repo 根取 ${MCPE_REPO_ROOT:-${GITHUB_WORKSPACE}} (均绝对路径): build-firmware.sh
# 调用读 MCPE_REPO_ROOT, 旧 CI 直调读 GITHUB_WORKSPACE; 去 `.` 兜底防 cd 漂移。
DEVICE_HOOK="${MCPE_REPO_ROOT:-${GITHUB_WORKSPACE:-}}/devices/${DEVICE:-}/post-feeds.sh"
if [ -n "${DEVICE:-}" ] && [ -f "$DEVICE_HOOK" ]; then
  echo "==> Running device hook: devices/${DEVICE}/post-feeds.sh"
  # shellcheck source=/dev/null
  . "$DEVICE_HOOK"
fi
