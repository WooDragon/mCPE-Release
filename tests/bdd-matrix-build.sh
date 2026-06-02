#!/usr/bin/env bash
# =============================================================================
# tests/bdd-matrix-build.sh — 单分支 matrix 构建的本地 BDD 回归套件
# =============================================================================
# 断言纯文本契约(不烧 CI), 覆盖 4 类行为:
#   1. 拼装等价性 (B01/B02/B03) — Never break userspace 铁律
#   2. 设备钩子机制 (B04/B05/B06)
#   3. matrix 生成逻辑 (B07/B08/B09)
#   4. 固件命名前缀 & 架构探测 & release 隔离 (B10/B11/B12)
#
# 用法: bash tests/bdd-matrix-build.sh   (在仓库根目录运行)
# 退出码: 0 = 全过, 非 0 = 有失败
# =============================================================================
set -u
cd "$(dirname "$0")/.." || exit 2
REPO_ROOT="$(pwd)"

PASS=0; FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
scenario() { echo ""; echo "Scenario: $1"; }

ALL_DEVICES="r2s r3s r5s r5s-outdoor r68s x86"
# 有历史分支可比对原始 .config 的设备 (r3s 是新设备, 无历史基线)
LEGACY_DEVICES="r2s r5s r5s-outdoor r68s x86"
# r68s 故意偏离原始 .config: 旧分支符号 friendlyarm_nanopi-r68s 是无效符号
# (defconfig 静默回退编出 ariaboard_photonicat 废固件), 已修正为上游真实符号
# lunzn_fastrhino-r68s。故 B01 还原断言豁免 r68s, 由 B13 上游有效性断言守护。
RESTORE_DEVICES="r2s r5s r5s-outdoor x86"

# 上游 ImmortalWRT v24.10.4 真实有效的 device 符号白名单。
# 来源: target/linux/rockchip/image/armv8.mk @ tag v24.10.4 (2026-06 核实);
# x86 来自 target/linux/x86/64 generic。新增设备时同步更新此白名单。
UPSTREAM_VALID_SYMBOLS="
CONFIG_TARGET_rockchip_armv8_DEVICE_friendlyarm_nanopi-r2s=y
CONFIG_TARGET_rockchip_armv8_DEVICE_friendlyarm_nanopi-r3s=y
CONFIG_TARGET_rockchip_armv8_DEVICE_friendlyarm_nanopi-r5s=y
CONFIG_TARGET_rockchip_armv8_DEVICE_lunzn_fastrhino-r68s=y
CONFIG_TARGET_x86_64_DEVICE_generic=y
"

# 提取"有效配置行": CONFIG_x=v 或 "# CONFIG_x is not set", 排除人类注释/空行
effective() { grep -E '^(CONFIG_[A-Za-z0-9_]+=|# CONFIG_[A-Za-z0-9_]+ is not set)' | sort; }

assemble() { cat config/common.config "devices/$1/seed.config"; }

# -----------------------------------------------------------------------------
# 行为 1: 拼装等价性 (B01/B02/B03)
# -----------------------------------------------------------------------------
scenario "B01 — common+seed 逐行还原原始 .config (排除有意新增 CONFIG_CCACHE)"
for dev in $RESTORE_DEVICES; do
  orig=$(git show "$dev:.config" | effective)
  asm=$(assemble "$dev" | effective | grep -v '^CONFIG_CCACHE=y$')
  if diff <(echo "$orig") <(echo "$asm") >/dev/null; then
    ok "$dev 还原一致"
  else
    bad "$dev 配置漂移:"; diff <(echo "$orig") <(echo "$asm")
  fi
done

scenario "B01b — r68s 有意偏离原始(修正废固件 bug), 仅非符号行应一致"
# r68s 只有 DEVICE 符号行从 friendlyarm_nanopi-r68s 改为 lunzn_fastrhino-r68s,
# 其余行应与原始完全一致 (剔除两侧的 r68s DEVICE 符号行与 CCACHE 后比对)
orig_r68s=$(git show "r68s:.config" | effective | grep -vE '_DEVICE_.*r68s=y')
asm_r68s=$(assemble r68s | effective | grep -v '^CONFIG_CCACHE=y$' | grep -vE '_DEVICE_.*r68s=y')
if diff <(echo "$orig_r68s") <(echo "$asm_r68s") >/dev/null; then
  ok "r68s 除 DEVICE 符号修正外其余完全一致"
else
  bad "r68s 非符号行出现意外漂移:"; diff <(echo "$orig_r68s") <(echo "$asm_r68s")
fi

scenario "B02 — 每设备恰好 1 个 DEVICE 符号, 且平台符号唯一"
for dev in $ALL_DEVICES; do
  asm=$(assemble "$dev")
  ndev=$(echo "$asm" | grep -cE '^CONFIG_TARGET_.*_DEVICE_.*=y')
  nplat=$(echo "$asm" | grep -cE '^CONFIG_TARGET_(rockchip|x86)=y')
  if [ "$ndev" = "1" ] && [ "$nplat" = "1" ]; then
    ok "$dev: DEVICE符号=1 平台符号=1"
  else
    bad "$dev: DEVICE符号=$ndev 平台符号=$nplat (应各为1)"
  fi
done

scenario "B03 — common.config 无任何架构/平台污染行"
# 污染 = 平台选择符号或镜像格式; 不含架构中立的 ROOTFS 格式/分区/CCACHE。
# 匹配: CONFIG_TARGET_<arch>=y (rockchip/x86 等平台根符号) 或 GRUB/VMDK 镜像格式。
# 排除: CONFIG_TARGET_ROOTFS_* 与 CONFIG_TARGET_KERNEL_PARTSIZE (跨架构通用)。
poison=$(grep -nE '^(CONFIG_TARGET_(rockchip|x86)|CONFIG_TARGET_.*_DEVICE_|CONFIG_GRUB|CONFIG_VMDK)' config/common.config || true)
if [ -z "$poison" ]; then
  ok "common.config 架构中立 (无平台根符号/DEVICE/GRUB/VMDK)"
else
  bad "common.config 混入架构项:"; echo "$poison"
fi

scenario "B13 — 每设备 DEVICE 符号必须是上游真实有效符号 (防 r68s 幽灵符号回归)"
# 这是能逮住 r68s 废固件 bug 的关键断言: 无效符号会被 defconfig 静默丢弃,
# 回退编出错误设备固件 (历史上 friendlyarm_nanopi-r68s -> ariaboard_photonicat)。
for dev in $ALL_DEVICES; do
  sym=$(grep -E '^CONFIG_TARGET_.*_DEVICE_.*=y' "devices/$dev/seed.config")
  if grep -qxF "$sym" <<<"$UPSTREAM_VALID_SYMBOLS"; then
    ok "$dev: $sym (上游有效)"
  else
    bad "$dev: $sym 不在上游 v24.10.4 有效符号白名单 — 会编出废固件!"
  fi
done
# PLACEHOLDER_HOOK_TESTS

# -----------------------------------------------------------------------------
# 行为 2: 设备钩子机制 (B04/B05/B06)
# 复刻 diy-part1.sh 末尾的钩子逻辑做隔离验证 (避免跑整个 diy 脚本的副作用)
# -----------------------------------------------------------------------------
run_hook() {
  # $1=DEVICE 值; 模拟 diy-part1.sh 的钩子分支, 命中则 echo 标记
  local DEVICE="$1"
  local GITHUB_WORKSPACE="$REPO_ROOT"
  local DEVICE_HOOK="$GITHUB_WORKSPACE/devices/$DEVICE/pre-feeds.sh"
  if [ -n "$DEVICE" ] && [ -f "$DEVICE_HOOK" ]; then
    echo "HOOK_RAN:$DEVICE"
  else
    echo "HOOK_SKIPPED"
  fi
}

scenario "B04 — DEVICE=r5s-outdoor 有 pre-feeds.sh, 钩子应被触发"
[ "$(run_hook r5s-outdoor)" = "HOOK_RAN:r5s-outdoor" ] \
  && ok "r5s-outdoor 钩子触发" || bad "r5s-outdoor 钩子未触发"

scenario "B05 — DEVICE=r5s 无钩子, 应静默跳过"
[ "$(run_hook r5s)" = "HOOK_SKIPPED" ] \
  && ok "r5s 无钩子静默跳过" || bad "r5s 不该执行钩子"

scenario "B06 — DEVICE 为空 (matrix 注入失败), 钩子整体跳过不报错"
[ "$(run_hook '')" = "HOOK_SKIPPED" ] \
  && ok "空 DEVICE 安全跳过" || bad "空 DEVICE 行为异常"

scenario "B04b — pre-feeds.sh 内容正确追加 outdoor feed"
grep -q 'src-git outdoor https://github.com/WooDragon/outdoor-backup' \
  devices/r5s-outdoor/pre-feeds.sh \
  && ok "outdoor feed 行存在" || bad "outdoor feed 行缺失或被改"

# -----------------------------------------------------------------------------
# 行为 3: matrix 生成逻辑 (B07/B08/B09)
# 复刻 workflow prepare job 的 set-matrix 逻辑
# -----------------------------------------------------------------------------
gen_matrix() {
  local DEVICE="$1"
  local ALL='["r2s","r3s","r5s","r5s-outdoor","r68s","x86"]'
  if [ -z "$DEVICE" ] || [ "$DEVICE" = "all" ]; then
    echo "$ALL"
  else
    echo "[\"$DEVICE\"]"
  fi
}

scenario "B07 — device=all 展开为 6 元素 matrix"
m=$(gen_matrix all)
n=$(echo "$m" | jq 'length')
[ "$n" = "6" ] && ok "all -> 6 设备: $m" || bad "all 应为 6 元素, 实得 $n: $m"

scenario "B08 — device=r3s 展开为单元素 matrix"
m=$(gen_matrix r3s)
[ "$(echo "$m" | jq -r '.[0]')" = "r3s" ] && [ "$(echo "$m" | jq 'length')" = "1" ] \
  && ok "r3s -> 单元素: $m" || bad "r3s matrix 错误: $m"

scenario "B09 — device 缺省(空)回退为全量"
m=$(gen_matrix '')
[ "$(echo "$m" | jq 'length')" = "6" ] \
  && ok "空 device 回退全量: $m" || bad "空 device 未回退: $m"

scenario "B08b — matrix 每个设备都有对应 seed.config (无悬空设备)"
miss=0
for dev in $(gen_matrix all | jq -r '.[]'); do
  [ -f "devices/$dev/seed.config" ] || { bad "matrix 含设备 $dev 但无 seed.config"; miss=1; }
done
[ "$miss" = "0" ] && ok "matrix 全部设备 seed.config 齐备"

# -----------------------------------------------------------------------------
# 行为 4: 命名前缀 / 架构探测 / release 隔离 (B10/B11/B12)
# -----------------------------------------------------------------------------
scenario "B10 — 每设备 VERSION 三元组齐全, 前缀符合 MCPE-251228-NN"
for dev in $ALL_DEVICES; do
  asm=$(assemble "$dev")
  vd=$(echo "$asm" | grep 'CONFIG_VERSION_DIST=' | cut -d'"' -f2)
  vn=$(echo "$asm" | grep 'CONFIG_VERSION_NUMBER=' | cut -d'"' -f2)
  vc=$(echo "$asm" | grep 'CONFIG_VERSION_CODE=' | cut -d'"' -f2)
  prefix="${vd}-${vn}-${vc}"
  if [ "$vd" = "MCPE" ] && [ "$vn" = "251228" ] && [ -n "$vc" ]; then
    ok "$dev 前缀=$prefix"
  else
    bad "$dev VERSION 三元组异常: DIST=$vd NUMBER=$vn CODE=$vc"
  fi
done

scenario "B11 — clash 架构探测: x86->amd64, 其余->arm64"
clash_arch() { grep -q '^CONFIG_TARGET_x86=y' <<<"$(assemble "$1")" && echo amd64 || echo arm64; }
[ "$(clash_arch x86)" = "amd64" ] && ok "x86 -> amd64" || bad "x86 应为 amd64"
fail_arm=0
for dev in r2s r3s r5s r5s-outdoor r68s; do
  [ "$(clash_arch "$dev")" = "arm64" ] || { bad "$dev 应为 arm64"; fail_arm=1; }
done
[ "$fail_arm" = "0" ] && ok "r2s/r3s/r5s/r5s-outdoor/r68s -> arm64"

scenario "B12 — release 清理: r5s 不误删 r5s-outdoor (date-anchored 正则隔离)"
# tag 格式 {device}-YYYY.MM.DD-HHMM; 用与 workflow 同款正则 ^DEV-[0-9]{4}\. 隔离
tags='[{"tag_name":"r5s-2026.01.01-1200"},{"tag_name":"r5s-outdoor-2026.01.01-1200"},{"tag_name":"r5s-2026.02.02-0800"}]'
match_dev() { echo "$tags" | jq -r --arg DEV "$1" '[.[] | select(.tag_name | test("^" + $DEV + "-[0-9]{4}\\.")) | .tag_name]'; }

r5s_hits=$(match_dev r5s)
out_hits=$(match_dev r5s-outdoor)
r5s_n=$(echo "$r5s_hits" | jq 'length')
out_n=$(echo "$out_hits" | jq 'length')
# r5s 应只匹配 2 个 r5s-日期 tag, 不含 outdoor; outdoor 应只匹配自己那 1 个
if [ "$r5s_n" = "2" ] && ! echo "$r5s_hits" | grep -q outdoor && [ "$out_n" = "1" ]; then
  ok "r5s 命中 $r5s_n 个(不含 outdoor), r5s-outdoor 命中 $out_n 个 — 隔离正确"
else
  bad "隔离失败: r5s=$r5s_hits ($r5s_n) / outdoor=$out_hits ($out_n)"
fi

scenario "B12b — 旧版裸 startswith 反例确认 (证明修复必要性)"
old_n=$(echo "$tags" | jq -r '[.[] | select(.tag_name | startswith("r5s-"))] | length')
[ "$old_n" = "3" ] \
  && ok "旧 startswith('r5s-') 会吞 3 个(含 outdoor) — 已被 date-anchored 正则取代" \
  || bad "反例预期 3, 实得 $old_n"

echo ""
echo "============================================================"
echo "BDD 回归结果: PASS=$PASS  FAIL=$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ]
