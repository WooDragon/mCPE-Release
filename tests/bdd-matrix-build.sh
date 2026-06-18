#!/usr/bin/env bash
# =============================================================================
# tests/bdd-matrix-build.sh — 单分支 matrix 构建的本地 BDD 回归套件
# =============================================================================
# 断言纯文本契约(不烧 CI), 覆盖 8 类行为:
#   1. 拼装等价性 (B01/B02/B03) — Never break userspace 铁律
#   2. 设备钩子机制 (B04/B05/B06)
#   3. matrix 生成逻辑 (B07/B08/B09) — 调 build-lib.sh 真函数
#   4. 固件命名前缀 & 架构探测 & release 隔离 (B10/B11/B12)
#   5. fail-loud 定制原语 (B15/B16/B17)
#   6. dl 残包清理作用域 (B18/B18b) — 调 build-lib.sh 真函数
#   7. build-firmware.sh 抽取契约 (B19-B31) — 反向私有注入支撑 + .config 落位时序
#   8. Rockchip 首启扩盘 preinit 钩子契约 (B32-B41)
#
# 单一真相源: B07-B09/B11/B18 测的是 scripts/build-lib.sh 的真函数 (非复刻),
#   改一处不必同步两处。
#
# 用法: bash tests/bdd-matrix-build.sh   (在仓库根目录运行)
# 退出码: 0 = 全过, 非 0 = 有失败
# =============================================================================
set -u
cd "$(dirname "$0")/.." || exit 2
REPO_ROOT="$(pwd)"

# 纯库: 无 set -e/trap/副作用, source 进测试进程安全 (B20 守护此契约)。
# shellcheck source=scripts/build-lib.sh
. "$REPO_ROOT/scripts/build-lib.sh"

PASS=0; FAIL=0; SKIP=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
skip() { echo "  ⏭️  $1"; SKIP=$((SKIP+1)); }
scenario() { echo ""; echo "Scenario: $1"; }

# 历史设备基线分支可能已被清理 (issue #8 合并设备分支入 main)。B01/B01b 的
# "逐字节还原" 比对依赖这些 ref; ref 不在时跳过而非误判失败 —— 拼装契约本身另由
# B02/B03/B10/B13 (不依赖历史分支) 守护, 还原比对只是分支尚存时的额外保险。
has_ref() { git rev-parse --verify --quiet "$1" >/dev/null 2>&1; }

ALL_DEVICES="r2s r3s r5s r5s-outdoor r68s x86"
# r68s 故意偏离原始 .config: 旧分支符号 friendlyarm_nanopi-r68s 是无效符号
# (defconfig 静默回退编出 ariaboard_photonicat 废固件), 已修正为上游真实符号
# lunzn_fastrhino-r68s。故 B01 还原断言豁免 r68s, 由 B13 上游有效性断言守护。
RESTORE_DEVICES="r2s r5s r5s-outdoor x86"

# 上游 ImmortalWRT v24.10.6 真实有效的 device 符号白名单。
# 来源: target/linux/rockchip/image/armv8.mk @ tag v24.10.6 (2026-06 核实);
# x86 来自 target/linux/x86/64 generic。新增设备时同步更新此白名单。
# 注: v24.10.4->v24.10.6 升级时已逐符号复核, 5 个符号全部有效无改名 (issue #9)。
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
scenario "B01 — common+seed 逐行还原原始 .config (排除有意新增项)"
for dev in $RESTORE_DEVICES; do
  if ! has_ref "$dev:.config"; then
    skip "$dev 基线分支已清理 (ref 不存在), 跳过还原比对"
    continue
  fi
  orig=$(git show "$dev:.config" | effective)
  asm=$(assemble "$dev" | effective | grep -vE '^CONFIG_(CCACHE|DEVEL|KERNEL_SECURITY_LANDLOCK|PACKAGE_f2fsck|PACKAGE_sfdisk|PACKAGE_partx-utils)=y$')
  if diff <(echo "$orig") <(echo "$asm") >/dev/null; then
    ok "$dev 还原一致"
  else
    bad "$dev 配置漂移:"; diff <(echo "$orig") <(echo "$asm")
  fi
done

scenario "B01b — r68s 有意偏离原始(修正废固件 bug), 仅非符号行应一致"
# r68s 只有 DEVICE 符号行从 friendlyarm_nanopi-r68s 改为 lunzn_fastrhino-r68s,
# 其余行应与原始完全一致 (剔除两侧的 r68s DEVICE 符号行与 CCACHE/DEVEL 后比对)
if ! has_ref "r68s:.config"; then
  skip "r68s 基线分支已清理 (ref 不存在), 跳过非符号行比对"
else
orig_r68s=$(git show "r68s:.config" | effective | grep -vE '_DEVICE_.*r68s=y')
asm_r68s=$(assemble r68s | effective | grep -vE '^CONFIG_(CCACHE|DEVEL|KERNEL_SECURITY_LANDLOCK|PACKAGE_f2fsck|PACKAGE_sfdisk|PACKAGE_partx-utils)=y$' | grep -vE '_DEVICE_.*r68s=y')
if diff <(echo "$orig_r68s") <(echo "$asm_r68s") >/dev/null; then
  ok "r68s 除 DEVICE 符号修正外其余完全一致"
else
  bad "r68s 非符号行出现意外漂移:"; diff <(echo "$orig_r68s") <(echo "$asm_r68s")
fi
fi  # has_ref r68s

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

scenario "B03b — ccache 防呆: CONFIG_CCACHE=y 必须伴随 CONFIG_DEVEL=y (issue #25)"
# 局限声明: 这是纯文本共现的低级防呆正则, 不跑 make defconfig, 不验 Kconfig 解析
# 顺序或跨文件覆盖。仅拦"有人单独删掉 DEVEL"的低级回归 —— 上游 CCACHE 的 prompt
# 是 `bool "Use ccache" if DEVEL`, 缺 DEVEL 则 defconfig 静默剔除 CCACHE 致 ccache
# 全程空转。ccache 是否真激活由真实 CI 构建兜底, 此处只守"两行同在 common.config"。
has_ccache=$(grep -qxF 'CONFIG_CCACHE=y' config/common.config && echo y || echo n)
has_devel=$(grep -qxF 'CONFIG_DEVEL=y' config/common.config && echo y || echo n)
if [ "$has_ccache" = n ]; then
  ok "common.config 未启用 CONFIG_CCACHE (无 DEVEL 依赖约束)"
elif [ "$has_devel" = y ]; then
  ok "CONFIG_CCACHE=y 已伴随 CONFIG_DEVEL=y (defconfig 后 CCACHE 可存活)"
else
  bad "common.config 有 CONFIG_CCACHE=y 但缺 CONFIG_DEVEL=y — defconfig 会静默剔除 CCACHE, ccache 空转!"
fi

scenario "B13 — 每设备 DEVICE 符号必须是上游真实有效符号 (防 r68s 幽灵符号回归)"
# 这是能逮住 r68s 废固件 bug 的关键断言: 无效符号会被 defconfig 静默丢弃,
# 回退编出错误设备固件 (历史上 friendlyarm_nanopi-r68s -> ariaboard_photonicat)。
for dev in $ALL_DEVICES; do
  sym=$(grep -E '^CONFIG_TARGET_.*_DEVICE_.*=y' "devices/$dev/seed.config")
  if grep -qxF "$sym" <<<"$UPSTREAM_VALID_SYMBOLS"; then
    ok "$dev: $sym (上游有效)"
  else
    bad "$dev: $sym 不在上游 v24.10.6 有效符号白名单 — 会编出废固件!"
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

scenario "B14 — diy-part2.sh 不再含 rust CI-LLVM patch (v24.10.6 上游自带 false)"
# 升级 v24.10.6 后, packages feed (pin 97af139) lang/rust/Makefile 已自带
# download-ci-llvm=false, 临时 patch 已移除。此断言守护其不被误加回 (防回退)。
# 只看活跃命令行 (排除以 # 起始的注释): 注释里会解释"为何移除"而提及该串。
if grep -vE '^\s*#' diy-part2.sh | grep -q 'download-ci-llvm'; then
  bad "diy-part2.sh 仍含 rust download-ci-llvm patch — v24.10.6 已自带, 应移除"
else
  ok "rust patch 已移除 (跟随上游 v24.10.6 官方默认)"
fi

# -----------------------------------------------------------------------------
# 行为 5: fail-loud 定制原语机制 (B15/B16/B17)
# 测的是 scripts/diy-lib.sh 的契约本身, 而非逐条 diy 命令 —— 命令对不对交给
# 真实 CI 构建 (跑真上游文件) 兜底, 这里只锁死"未命中即失败"的机制不被破坏。
# -----------------------------------------------------------------------------
# shellcheck source=scripts/diy-lib.sh
. "$REPO_ROOT/scripts/diy-lib.sh"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

scenario "B15 — sed_required: 命中目标串 → 改动并返回 0"
printf "option Interface 'lan'\n" > "$TMPD/dropbear"
if sed_required "test hit" "s/option Interface[[:space:]]*'lan'/#&/g" "$TMPD/dropbear" >/dev/null 2>&1 \
   && grep -q "^#option Interface 'lan'" "$TMPD/dropbear"; then
  ok "命中即改 (单空格变体也被容差正则覆盖)"
else
  bad "sed_required 命中分支异常"
fi

scenario "B16 — sed_required: 零匹配 (上游串漂移) → 返回非 0 中断构建"
printf "totally-different-line\n" > "$TMPD/nomatch"
if sed_required "test miss" "s/THIS_STRING_DOES_NOT_EXIST/Y/g" "$TMPD/nomatch" >/dev/null 2>&1; then
  bad "零匹配竟返回 0 — fail-loud 失效, 定制会静默蒸发!"
else
  ok "零匹配返回非 0 (上游漂移会在构建期响亮中断, 非运行期猝死)"
fi

scenario "B16b — sed_required: 目标文件不存在 (上游删文件) → 返回非 0"
if sed_required "test missing file" "s/a/b/g" "$TMPD/no-such-file" >/dev/null 2>&1; then
  bad "文件缺失竟返回 0 — 上游删/改名文件会被静默放过!"
else
  ok "文件缺失返回非 0 (如 luci-ssl-nginx 被合并那类场景会被逮住)"
fi

scenario "B17 — append_required: 文件存在 → 追加; 文件缺失 → 返回非 0"
printf "head\n" > "$TMPD/conf"
if append_required "test append" "$TMPD/conf" "tail-line" >/dev/null 2>&1 \
   && grep -q '^tail-line$' "$TMPD/conf" \
   && ! append_required "test append miss" "$TMPD/no-such" "x" >/dev/null 2>&1; then
  ok "存在即追加, 缺失即失败 (不会凭空造孤儿文件)"
else
  bad "append_required 契约异常"
fi

# -----------------------------------------------------------------------------
# 行为 3: matrix 生成逻辑 (B07/B08/B09)
# 调 build-lib.sh 的真 gen_matrix 函数 (非复刻; 单一真相源)
# -----------------------------------------------------------------------------
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

scenario "B11 — clash 架构探测: x86->amd64, 其余->arm64 (调 build-lib.sh 真函数)"
# 真函数 clash_arch <config-file> 接文件路径; 把拼装结果落临时文件再喂进去
arch_of() { local f; f="$(mktemp)"; assemble "$1" > "$f"; clash_arch "$f"; rm -f "$f"; }
[ "$(arch_of x86)" = "amd64" ] && ok "x86 -> amd64" || bad "x86 应为 amd64"
fail_arm=0
for dev in r2s r3s r5s r5s-outdoor r68s; do
  [ "$(arch_of "$dev")" = "arm64" ] || { bad "$dev 应为 arm64"; fail_arm=1; }
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

# -----------------------------------------------------------------------------
# 行为 6: dl 残包清理只清顶层, 不误删 go-mod-cache 源文件 (B18/B18b)
# 调 build-lib.sh 的真 prune_residual_dl 函数 (非复刻; 单一真相源)。
# 背景: 裸 `find dl -size -1024c -delete` 会递归删进 dl/go-mod-cache/, 把 frp
# 等 Go 包依赖的合法小 .go 源文件 (如 fatedier/golib/errors/errors.go 800B、
# pion/dtls types 394B) 当残包误删 -> 离线编译报 "no required module provides
# package" (run 26865990666 全 6 设备栽在此)。修复: 用 -maxdepth 1 -type f 锁定
# dl 顶层下载包, 让 go-mod-cache 子树根本不进射程。
# -----------------------------------------------------------------------------

scenario "B18 — dl 清理删顶层残包, 保住 go-mod-cache 小源文件 (调真函数)"
DLROOT="$(mktemp -d)"
trap 'rm -rf "$TMPD" "$DLROOT"' EXIT  # 接管前面 fail-loud 块设的 trap, 一并清理
mkdir -p "$DLROOT/go-mod-cache/github.com/fatedier/golib/errors"
# 顶层残包 (下载失败的错误页, <1024B): 应被删
printf 'broken\n' > "$DLROOT/some-pkg-1.0.tar.gz"
# go-mod-cache 里的合法小源文件 (<1024B): 必须保住
printf 'package errors\n' > "$DLROOT/go-mod-cache/github.com/fatedier/golib/errors/errors.go"
prune_residual_dl "$DLROOT" >/dev/null 2>&1
if [ ! -f "$DLROOT/some-pkg-1.0.tar.gz" ] \
   && [ -f "$DLROOT/go-mod-cache/github.com/fatedier/golib/errors/errors.go" ]; then
  ok "顶层残包已删, go-mod-cache 源文件完好 (frp 依赖不再被误删)"
else
  bad "清理作用域错误: 顶层残包=$([ -f "$DLROOT/some-pkg-1.0.tar.gz" ] && echo 残留 || echo 已删) / go-mod源文件=$([ -f "$DLROOT/go-mod-cache/github.com/fatedier/golib/errors/errors.go" ] && echo 完好 || echo 被误删)"
fi

scenario "B18b — 旧版裸 find 反例确认 (证明修复必要性)"
# 裸递归 find 会把 go-mod-cache 的小源文件一并删掉, 重现 run 26865990666 的 bug
DLROOT2="$(mktemp -d)"
mkdir -p "$DLROOT2/go-mod-cache/github.com/fatedier/golib/errors"
printf 'package errors\n' > "$DLROOT2/go-mod-cache/github.com/fatedier/golib/errors/errors.go"
# 旧逻辑: 无 maxdepth/type 限制; -size 也匹配目录, rm 拒删目录的 stderr 噪声丢弃
# (核心是演示小源文件被误删, 目录报错与本断言无关)
find "$DLROOT2" -size -1024c -exec rm -f {} \; 2>/dev/null
if [ ! -f "$DLROOT2/go-mod-cache/github.com/fatedier/golib/errors/errors.go" ]; then
  ok "裸 find 确实递归删了 go-mod-cache 源文件 — 已被 -maxdepth 1 -type f 取代"
else
  bad "反例预期源文件被删, 实际未删 — 反例不成立"
fi
rm -rf "$DLROOT2"

# -----------------------------------------------------------------------------
# 行为 7: build-firmware.sh 抽取契约 (B19-B31) — 反向私有注入支撑 + 落位时序
# 不跑真 make (那是 CI 全量构建的活), 只锁死脚本的接口/防御/路径解析契约。
# -----------------------------------------------------------------------------
BF="$REPO_ROOT/scripts/build-firmware.sh"
GM="$REPO_ROOT/scripts/gen-matrix.sh"
BL="$REPO_ROOT/scripts/build-lib.sh"

scenario "B19 — 三个新脚本 bash -n 可解析 (无语法错误)"
synfail=0
for f in "$BF" "$GM" "$BL"; do
  bash -n "$f" 2>/dev/null || { bad "$(basename "$f") 语法错误"; synfail=1; }
done
[ "$synfail" = "0" ] && ok "build-firmware.sh / gen-matrix.sh / build-lib.sh 均可解析"

scenario "B20 — source build-lib.sh 无副作用 (不开 set -e/不退出/不输出)"
# 纯库铁律: 被 BDD source 不得带 set -e/trap 污染测试进程, 否则纯函数返回非 0
# 即杀死整个套件。干净子 shell 里 source, 验证: (1) 未打开 errexit; (2) 无 stdout。
BL_ERR="$(mktemp)"  # 独占临时文件, 避免并行跑回归时的竞态/串扰
bl_out="$(bash -c '. "'"$BL"'"; case $- in *e*) echo ERREXIT_ON;; esac' 2>"$BL_ERR")"
if [ -z "$bl_out" ] && [ ! -s "$BL_ERR" ]; then
  ok "build-lib.sh source 后无 errexit 污染、无输出 (可安全被 BDD source)"
else
  bad "build-lib.sh source 有副作用: stdout='$bl_out' stderr='$(cat "$BL_ERR")'"
fi
rm -f "$BL_ERR"

scenario "B21 — clash_arch 是 build-lib.sh 导出的真函数 (非 BDD 局部复刻)"
# 在干净子 shell 里只 source 库, 验证函数确实来自库而非测试文件
if bash -c '. "'"$BL"'"; declare -F clash_arch >/dev/null && declare -F gen_matrix >/dev/null && declare -F prune_residual_dl >/dev/null && declare -F assemble_config >/dev/null'; then
  ok "clash_arch/gen_matrix/prune_residual_dl/assemble_config 均由 build-lib.sh 提供"
else
  bad "build-lib.sh 未导出预期纯函数"
fi

scenario "B22 — assemble_config 真函数: common+seed 拼装与 cat 等价"
# 私有注入的核心契约: assemble_config 就是按序 cat, extra 殿后可覆盖
a_lib=$(assemble_config config/common.config devices/r5s/seed.config | effective)
a_cat=$(cat config/common.config devices/r5s/seed.config | effective)
[ "$a_lib" = "$a_cat" ] && ok "assemble_config == cat (拼装契约不破)" \
  || bad "assemble_config 与 cat 不等价"

# --- B23-B30: build-firmware.sh 入口防御 (在 make 之前的校验/解析阶段验证) -----
# 策略: 这些断言都让脚本在 clone/校验阶段就退出 (报错或 --skip-clone 缺目录),
# 绝不进真 make。用 timeout 兜底防意外卡死。
runbf() { timeout 30 bash "$BF" "$@"; }

scenario "B23 — 缺 --device 报错退出 (exit!=0)"
if runbf >/dev/null 2>&1; then
  bad "缺 --device 竟成功退出 — 强校验失效"
else
  ok "缺 --device 非零退出 (内建强校验)"
fi

scenario "B28 — --device typo 报错退出 (复刻 B13 意图进脚本, 不靠外围 BDD)"
# 私有 CI 不跑本仓 BDD, 故 typo 防御必须内建在脚本里
if runbf --device r5x --skip-clone --openwrt-dir /nonexistent >/dev/null 2>&1; then
  bad "无效设备 r5x 竟通过 — 会编废固件 (重演 r68s 教训)"
else
  ok "无效设备 r5x 非零退出 (devices/r5x/seed.config 不存在)"
fi

scenario "B24 — --skip-clone 时缺 openwrt-dir 即报错, 绝不 clone"
# --skip-clone 承诺复用已有树; 树不存在应直接失败而非偷偷 clone
out=$(runbf --device r5s --skip-clone --openwrt-dir /nonexistent-openwrt 2>&1 || true)
if echo "$out" | grep -q 'does not exist' && ! echo "$out" | grep -qi 'Cloning'; then
  ok "--skip-clone 缺目录即报错, 未触发 clone"
else
  bad "--skip-clone 行为异常: $out"
fi

scenario "B25 — --extra-config 缺文件即报错 (私有注入支点的存在性校验)"
if runbf --device r5s --extra-config /no-such-extra.config --skip-clone --openwrt-dir /nonexistent >/dev/null 2>&1; then
  bad "--extra-config 指向不存在文件竟通过"
else
  ok "--extra-config 缺文件非零退出 (注入件丢失会响亮失败, 不静默漏掉)"
fi

scenario "B26 — assemble_config extra 殿后: 后写覆盖前写 (私有注入可改写 seed)"
# wizard 包符号注入的核心: extra 拼在 seed 之后, defconfig 取最后一次赋值
EXTRA="$(mktemp)"
printf 'CONFIG_PACKAGE_luci-app-mcpe-wizard=y\n' > "$EXTRA"
merged=$(assemble_config config/common.config devices/r5s/seed.config "$EXTRA")
last=$(echo "$merged" | tail -n1)
if [ "$last" = "CONFIG_PACKAGE_luci-app-mcpe-wizard=y" ]; then
  ok "extra 内容追加在末尾 (defconfig 末值优先 -> 注入可覆盖)"
else
  bad "extra 未在末尾, 注入覆盖语义不成立: 末行=$last"
fi
rm -f "$EXTRA"

scenario "B27 — hook 路径用 MCPE_REPO_ROOT 绝对路径, cd 子目录后不漂移"
# 模拟 build-firmware.sh 在 openwrt 目录内执行 diy-part1 时, hook 仍命中 repo 根。
# 核心: diy-part1.sh 取 \${MCPE_REPO_ROOT:-\$GITHUB_WORKSPACE}, 即使 cwd 变了
# 绝对路径也不漂移 (旧 \`.\` 兜底会在 cd openwrt 后找错目录静默跳过钩子)。
sub="$(mktemp -d)"
hook_path=$(cd "$sub" && MCPE_REPO_ROOT="$REPO_ROOT" DEVICE="r5s-outdoor" bash -c \
  'echo "${MCPE_REPO_ROOT:-${GITHUB_WORKSPACE:-}}/devices/${DEVICE:-}/pre-feeds.sh"')
if [ -f "$hook_path" ]; then
  ok "cd 任意子目录后 hook 路径仍指向 repo 根真实文件 (绝对路径固化)"
else
  bad "hook 路径漂移, 找不到文件: $hook_path"
fi
rm -rf "$sub"

scenario "B29 — build-vars.env 幂等 (脚本顶部 rm -f, 重跑不堆积)"
# 校验脚本确实在顶部清理 VARS_OUT。预置脏内容, 跑到校验失败前应已被清空。
VOUT="$(mktemp)"
printf 'STALE=garbage\nSTALE2=junk\n' > "$VOUT"
# 用无效设备让脚本在 rm -f VARS_OUT 之后、make 之前退出; 此时旧内容应已被清掉
runbf --device r5x --vars-out "$VOUT" --skip-clone --openwrt-dir /nonexistent >/dev/null 2>&1 || true
if ! grep -q '^STALE=garbage$' "$VOUT" 2>/dev/null; then
  ok "build-vars.env 启动即清空 (幂等, 旧键不残留)"
else
  bad "build-vars.env 未幂等, 残留旧内容: $(cat "$VOUT")"
fi
rm -f "$VOUT"

scenario "B30 — 从任意外部 cwd 调用仍正确定位 repo 根 (BASH_SOURCE 硬寻址)"
# 模拟反向调用: 私有 CI 在自己根目录执行 mCPE-Release/scripts/build-firmware.sh,
# 不传 --repo-root。脚本须靠 BASH_SOURCE 物理位置 ($SELF_DIR/..) 找到本 repo 根,
# 而非 $(pwd)(那是私有 repo 根, 会去私有环境找 seed.config 误杀)。
extcwd="$(mktemp -d)"
# r5s 有效: 若 repo 根定位正确, 校验通过进入 clone 检查 (--skip-clone 缺目录才退);
# 报错信息应是 "does not exist"(已过设备校验), 而非 "Invalid device"(repo 根找错)
out=$(cd "$extcwd" && timeout 30 bash "$BF" --device r5s --skip-clone --openwrt-dir /nonexistent-ow 2>&1 || true)
if echo "$out" | grep -q 'does not exist' && ! echo "$out" | grep -q 'Invalid device'; then
  ok "从外部 cwd 调用经 BASH_SOURCE 正确定位 repo 根 (反向调用安全)"
else
  bad "外部 cwd 定位 repo 根失败 (可能误用 \$(pwd)): $out"
fi
rm -rf "$extcwd"

scenario "B31 — .config 落位 openwrt 树必须在 feeds install 之后 (防瘦固件回归)"
# 回归背景: build-firmware.sh 重构曾把 .config 直接写 \$OPENWRT_DIR/.config 于拼装
# 阶段 (feeds install 之前)。OpenWrt 的 \`feeds install -a\` 见 openwrt/.config 已存
# 在即触发 Kconfig 扫描, 而此刻 package/feeds/ symlink 未建全, 来自 luci/packages
# feed 的包符号 (openclash/dockerd/frpc...) 被当未知符号静默重置为 not-set, 整套
# 业务包无声蒸发 -> 固件 100MB 暴跌 28MB, config.buildinfo 仅剩 13 行。
# 修复: 拼到 openwrt 树外 staging, feeds install 完成后才 cp 落位。
# 本断言静态守护此时序: 落位行 (cp ... 到 \$OPENWRT_DIR/.config) 必须在
# feeds install 之后, 且拼装阶段不得把 assemble_config 直接重定向进 openwrt 树。
# grep 取实际命令行: 排除注释行 (行首去空格后为 #), 否则会误命中第 2 步注释里
# 解释时序铁律时提及的 \`./scripts/feeds install -a\` 文字。
cmd_lines() { grep -nE "$1" "$BF" | grep -vE '^[0-9]+:[[:space:]]*#'; }
feeds_ln=$(cmd_lines 'feeds install -a' | head -n1 | cut -d: -f1)
place_ln=$(cmd_lines 'cp "\$STAGED_CONFIG" "\$CONFIG_FILE"' | head -n1 | cut -d: -f1)
asm_ln=$(cmd_lines 'assemble_config .* > "\$STAGED_CONFIG"' | head -n1 | cut -d: -f1)
# 拼装阶段不得直接写 openwrt 树: assemble_config 的重定向目标必须是 staging, 不是
# \$OPENWRT_DIR/.config / \$CONFIG_FILE (后者只应出现在 feeds install 之后的落位行)。
asm_to_tree=$(cmd_lines 'assemble_config .* > "(\$OPENWRT_DIR/\.config|\$CONFIG_FILE)"' || true)
if [ -n "$feeds_ln" ] && [ -n "$place_ln" ] && [ -n "$asm_ln" ] \
   && [ "$place_ln" -gt "$feeds_ln" ] && [ "$asm_ln" -lt "$feeds_ln" ] \
   && [ -z "$asm_to_tree" ]; then
  ok "拼装(行$asm_ln)→feeds install(行$feeds_ln)→落位(行$place_ln): 时序正确, 拼装不直写 openwrt 树"
else
  bad "时序契约破坏: 拼装行=$asm_ln feeds行=$feeds_ln 落位行=$place_ln 直写树=${asm_to_tree:-无} (落位须>feeds, 拼装须<feeds且写 staging)"
fi

# -----------------------------------------------------------------------------
# 行为 8: Rockchip 首启扩盘 preinit 钩子契约 (B32-B41)
# 静态断言脚本存在性、语法、fail-soft 安全性、关键机制出现。
# 不跑真 preinit (需目标硬件 + block 工具), 只锁死脚本结构契约。
# -----------------------------------------------------------------------------
EXPAND_HOOK="$REPO_ROOT/scripts/firstboot/79_expand_rootfs"

scenario "B32 — preinit 钩子脚本存在"
[ -f "$EXPAND_HOOK" ] \
  && ok "scripts/firstboot/79_expand_rootfs 存在" \
  || bad "scripts/firstboot/79_expand_rootfs 不存在 — 首启扩盘失效"

scenario "B33 — preinit 钩子 bash -n 可解析 (无语法错误)"
bash -n "$EXPAND_HOOK" 2>/dev/null \
  && ok "79_expand_rootfs 语法合法" \
  || bad "79_expand_rootfs 语法错误"

scenario "B34 — shellcheck 扫描 (有 shellcheck 时执行, 无则跳过)"
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$EXPAND_HOOK" 2>/dev/null; then
    ok "shellcheck 79_expand_rootfs 无警告"
  else
    bad "shellcheck 79_expand_rootfs 有问题"
  fi
else
  skip "shellcheck 不可用, 跳过静态分析"
fi

scenario "B35 — preinit 钩子注册: 含 boot_hook_add preinit_main"
grep -q 'boot_hook_add preinit_main' "$EXPAND_HOOK" \
  && ok "boot_hook_add preinit_main expand_rootfs 注册存在" \
  || bad "缺少 boot_hook_add preinit_main — 钩子不会被 preinit 调用"

scenario "B36 — fail-soft: 失败路径用 return 不用 exit 非0 (防启动链中断 -> 设备变砖)"
# 允许: return 0, return (隐式 0)。禁止: exit 1, exit 2 等裸 exit 非0。
# 注意: 'exit 0' 无害但也不应出现在 preinit 钩子中; 这里只检查 exit 非0 的杀链情形。
if grep -vE '^\s*#' "$EXPAND_HOOK" | grep -qE '\bexit\s+[1-9][0-9]*\b'; then
  bad "79_expand_rootfs 含裸 exit 非0 — preinit source 调用时会杀整个启动链!"
else
  ok "无裸 exit 非0 (失败路径全部 return 0, fail-soft 安全)"
fi

scenario "B37 — 不写死设备名: 脚本不硬编码 mmcblk0/mmcblk1 作为操作目标"
# 允许文档注释里提及 mmcblk0 作为示例说明, 但不允许作为命令参数直接写死
if grep -vE '^\s*#' "$EXPAND_HOOK" | grep -qE '/dev/mmcblk[01][^p]'; then
  bad "79_expand_rootfs 硬编码了 /dev/mmcblk0 或 /dev/mmcblk1 — 换盘即失效"
else
  ok "无硬编码设备名 (通过 block info + sysfs 动态探测真实节点)"
fi

scenario "B38 — 含 resize.f2fs 版本门禁 + fsck.f2fs 调用"
has_ver_gate=$(grep -v '^\s*#' "$EXPAND_HOOK" | grep -c 'resize\.f2fs.*version\|version.*resize\.f2fs\|RF_VER\|RF_MAJOR' || true)
has_fsck=$(grep -v '^\s*#' "$EXPAND_HOOK" | grep -c 'fsck\.f2fs' || true)
if [ "$has_ver_gate" -gt 0 ] && [ "$has_fsck" -gt 0 ]; then
  ok "含 resize.f2fs 版本门禁 + fsck.f2fs 调用"
else
  bad "缺少版本门禁(${has_ver_gate})或 fsck.f2fs(${has_fsck})"
fi

scenario "B39 — partx -u 必须带 -n (防裸刷全盘撞已挂载 squashfs busy)"
# 裸 partx -u $DEV (无 -n 参数) 会刷全盘所有分区, 碰已挂载的 squashfs 报 busy。
# 所有 partx 命令调用都必须带 -n。
# 只检查实际命令调用行 (行首可选空白后直接是 partx 或 ! partx 或 if ... partx),
# 排除注释行和 echo/string 里的 partx 文字引用。
bare=$(grep -vE '^\s*#' "$EXPAND_HOOK" \
  | grep -E '^\s*(!?\s*)partx\b' \
  | grep -vE 'partx\s+-u\s+-n')
if [ -n "$bare" ]; then
  bad "发现裸 partx 命令未带 -n: $bare"
else
  ok "所有 partx 命令均带 -n (仅刷 overlay 分区, 不撞 squashfs)"
fi

scenario "B40a — 五个 rockchip seed 均声明 f2fsck/sfdisk/partx-utils"
expand_miss=0
for dev in r2s r3s r5s r5s-outdoor r68s; do
  seed="devices/$dev/seed.config"
  for pkg in f2fsck sfdisk partx-utils; do
    if ! grep -qxF "CONFIG_PACKAGE_${pkg}=y" "$seed"; then
      bad "$dev/seed.config 缺少 CONFIG_PACKAGE_${pkg}=y"
      expand_miss=1
    fi
  done
done
[ "$expand_miss" = "0" ] && ok "r2s/r3s/r5s/r5s-outdoor/r68s 均声明扩盘三包"

scenario "B40b — x86 seed 不声明扩盘包 (x86 无 eMMC/NVMe GPT 扩盘需求)"
x86_miss=0
for pkg in f2fsck sfdisk partx-utils; do
  if grep -qxF "CONFIG_PACKAGE_${pkg}=y" devices/x86/seed.config; then
    bad "x86/seed.config 不应含 CONFIG_PACKAGE_${pkg}=y"
    x86_miss=1
  fi
done
[ "$x86_miss" = "0" ] && ok "x86 seed 未声明扩盘包 (正确排除)"

scenario "B41 — diy-part2 落位路径无 openwrt/ 前缀, 源用 MCPE_REPO_ROOT 绝对变量"
# 落位路径: target/linux/rockchip/armv8/base-files/lib/preinit/ (无 openwrt/ 前缀)
# 源路径: 必须用 ${MCPE_REPO_ROOT:-...} 绝对变量 (CWD 在 openwrt 树内时相对路径会漂移)
if grep -q 'target/linux/rockchip/armv8/base-files/lib/preinit' diy-part2.sh \
   && ! grep 'target/linux/rockchip/armv8/base-files/lib/preinit' diy-part2.sh \
        | grep -q 'openwrt/target'; then
  ok "落位路径无 openwrt/ 前缀 (相对 openwrt 树根)"
else
  bad "落位路径含 openwrt/ 前缀或缺失"
fi
if grep 'firstboot/79_expand_rootfs' diy-part2.sh \
   | grep -q 'MCPE_REPO_ROOT\|GITHUB_WORKSPACE'; then
  ok "源路径用 MCPE_REPO_ROOT/GITHUB_WORKSPACE 绝对变量 (cd openwrt 树后不漂移)"
else
  bad "源路径未用绝对变量 — CWD 在 openwrt 树内时 cp 会找不到源文件"
fi

echo ""
echo "============================================================"
echo "BDD 回归结果: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
echo "============================================================"
[ "$FAIL" -eq 0 ]
