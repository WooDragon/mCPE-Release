#!/usr/bin/env bash
# =============================================================================
# scripts/build-firmware.sh — mCPE 固件构建编排入口 (单一真相源)
# =============================================================================
# 把原先散落在 .github/workflows/openwrt-builder.yml 各 step 的"构建核心"
# (clone → 拼 .config → diy-part1 → feeds → diy-part2 → defconfig+download+清残包
#  → 预置 clash 核心 → make → 重命名固件) 收敛成一个可复用脚本。
#
# 两类调用方:
#   1. 公开 CI (openwrt-builder.yml): clone 与 cache action 必须分离 (cache 夹在
#      clone 与 download 之间), 故 CI 自行 clone 后用 --skip-clone 调本脚本跑其余。
#   2. 反向私有注入 (mCPE-luci-app): 私有 CI 反向 checkout 本 repo, overlay
#      wizard 包 (--extra-config 追加包符号) / provision 文件 (files/ overlay) /
#      机密渲染后, 一次调用跑完整 clone→make, 产物发私有 S3。
#
# 接缝: 脚本零 CI 耦合, 只把版本/固件路径等 emit 到 --vars-out 文件 (KEY=val)。
#       CI 侧 `cat build-vars.env >> $GITHUB_ENV` 跨 step 桥接 (GHA 每 step 独立
#       进程, source 出 step 即销毁, 故必须写文件 + GITHUB_ENV)。
#
# 用法:
#   scripts/build-firmware.sh --device <dev> [--tag v24.10.6] [--repo-root .]
#     [--openwrt-dir ./openwrt] [--extra-config <f>] [--vars-out build-vars.env]
#     [--skip-clone]
# =============================================================================
set -euo pipefail
trap 'echo "ERROR: build-firmware.sh failed (line $LINENO, exit $?)" >&2' ERR

# 脚本自身物理位置 (绝对路径硬寻址的锚点; 严禁 $(pwd) —— 反向调用时 cwd 是私有
# repo 根, 会去私有环境找 seed.config 触发强校验误杀)。
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/build-lib.sh
. "$SELF_DIR/build-lib.sh"

# --- 默认值 (上游源/分支可被 env 覆盖, 与 workflow env 同名) -------------------
REPO_URL="${REPO_URL:-https://github.com/immortalwrt/immortalwrt}"
REPO_BRANCH="${REPO_BRANCH:-openwrt-24.10}"
DEVICE=""
TAG="v24.10.6"
REPO_ROOT_ARG=""
OPENWRT_DIR="./openwrt"
EXTRA_CONFIG=""
VARS_OUT="build-vars.env"
SKIP_CLONE=0

usage() {
  sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# abspath <path>: 解析为绝对路径, 即使路径尚不存在 (取父目录 + basename)。
abspath() {
  local p="$1"
  if [ -d "$p" ]; then
    (cd "$p" && pwd)
  else
    echo "$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"
  fi
}

# --- 参数解析 ----------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --device)       DEVICE="$2"; shift 2 ;;
    --tag)          TAG="$2"; shift 2 ;;
    --repo-root)    REPO_ROOT_ARG="$2"; shift 2 ;;
    --openwrt-dir)  OPENWRT_DIR="$2"; shift 2 ;;
    --extra-config) EXTRA_CONFIG="$2"; shift 2 ;;
    --vars-out)     VARS_OUT="$2"; shift 2 ;;
    --skip-clone)   SKIP_CLONE=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# --- repo 根解析 (优先级: --repo-root > $MCPE_REPO_ROOT > 脚本物理位置) --------
# 严禁 $(pwd): 反向调用场景私有 CI 在自己根目录执行 ./mCPE-Release/scripts/...,
# $(pwd) 是私有 repo 根; 基于脚本物理位置 ($SELF_DIR/..) 才是真绝对路径。
if [ -n "$REPO_ROOT_ARG" ]; then
  MCPE_REPO_ROOT="$(abspath "$REPO_ROOT_ARG")"
elif [ -n "${MCPE_REPO_ROOT:-}" ]; then
  MCPE_REPO_ROOT="$(abspath "$MCPE_REPO_ROOT")"
else
  MCPE_REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"
fi
export MCPE_REPO_ROOT   # 下游 diy-part1/2 的 hook 读它定位 devices/<dev>/*.sh

OPENWRT_DIR="$(abspath "$OPENWRT_DIR")"

# --- 绝对防御 3: build-vars.env 幂等 (启动即清, 防多次调试 >> 堆成垃圾场) -------
# 必须在任何校验/退出之前: 校验失败提前 exit 也应留下干净 (空) 产物, 不残留旧键。
rm -f "$VARS_OUT"
emit() { printf '%s=%s\n' "$1" "$2" >> "$VARS_OUT"; }

# --- 绝对防御 1: 设备有效性强校验 (复刻 B13 意图进脚本, 私有 CI 不跑本仓 BDD) --
if [ -z "$DEVICE" ]; then
  echo "ERROR: --device is required" >&2; usage >&2; exit 2
fi
SEED="$MCPE_REPO_ROOT/devices/$DEVICE/seed.config"
if [ ! -f "$SEED" ]; then
  echo "ERROR: Invalid device: $DEVICE (no $SEED)" >&2; exit 1
fi
COMMON="$MCPE_REPO_ROOT/config/common.config"
if [ ! -f "$COMMON" ]; then
  echo "ERROR: $COMMON not found" >&2; exit 1
fi
if [ -n "$EXTRA_CONFIG" ] && [ ! -f "$EXTRA_CONFIG" ]; then
  echo "ERROR: --extra-config file not found: $EXTRA_CONFIG" >&2; exit 1
fi

echo "==> build-firmware: device=$DEVICE tag=$TAG repo-root=$MCPE_REPO_ROOT openwrt-dir=$OPENWRT_DIR"

# --- 1. clone + checkout tag (CI 走 --skip-clone 自行 clone 以夹 cache action) -
if [ "$SKIP_CLONE" -eq 1 ]; then
  if [ ! -d "$OPENWRT_DIR" ]; then
    echo "ERROR: --skip-clone but $OPENWRT_DIR does not exist" >&2; exit 1
  fi
  # 绝对防御 2: 复用已 clone 的树时先清残局 (保 dl/.ccache 缓存),
  # 杜绝上次 .config 碎片/临时包污染本次构建。
  echo "==> --skip-clone: cleaning $OPENWRT_DIR (preserving dl/.ccache)"
  git -C "$OPENWRT_DIR" clean -fdx -e dl -e .ccache
else
  clone_openwrt "$REPO_URL" "$REPO_BRANCH" "$TAG" "$OPENWRT_DIR"
fi

# --- 2. 拼装 .config 到 staging (openwrt 树外) + 抽版本三元组 ------------------
# 时序铁律: .config 绝不可在 feeds install 之前进 openwrt/。OpenWrt 的
# `./scripts/feeds install -a` 若发现 openwrt/.config 已存在, 会触发 Kconfig 扫描,
# 而此刻 package/feeds/ symlink 尚未建全 —— 来自 luci/packages feed 的包符号
# (CONFIG_PACKAGE_luci-app-openclash / dockerd / frpc ...) 被当未知符号静默重置为
# not-set, 整套业务包无声蒸发, 编出近乎默认的瘦固件 (回归实例: 100MB->28MB,
# config.buildinfo 仅剩 13 行)。故先拼到 openwrt 树外的 staging, 待 feeds install
# 完成后 (第 4.5 步) 才落位。BDD B31 守护此时序契约。
STAGED_CONFIG="$(mktemp)"
trap 'rm -f "${STAGED_CONFIG:-}"' EXIT
# extra 殿后: 私有注入支点 (wizard 包符号), 后写覆盖前写。
# 用数组显式构造参数: EXTRA_CONFIG 为空时数组不含该元素, 非空时作为独立参数传入,
# 既无 word-splitting 风险, 也无需 shellcheck disable。
config_parts=("$COMMON" "$SEED")
[ -n "$EXTRA_CONFIG" ] && config_parts+=("$EXTRA_CONFIG")
assemble_config "${config_parts[@]}" > "$STAGED_CONFIG"
echo "Assembled seed .config for '$DEVICE' ($(wc -l < "$STAGED_CONFIG") lines, staged outside openwrt tree)"

# 抽版本信息 (在 defconfig 改格式前; 从 staging 早抽, 不受落位时序影响)
VERSION_DIST=$(grep 'CONFIG_VERSION_DIST=' "$STAGED_CONFIG" | cut -d'"' -f2)
VERSION_NUMBER=$(grep 'CONFIG_VERSION_NUMBER=' "$STAGED_CONFIG" | cut -d'"' -f2)
VERSION_CODE=$(grep 'CONFIG_VERSION_CODE=' "$STAGED_CONFIG" | cut -d'"' -f2)
emit VERSION_DIST "$VERSION_DIST"
emit VERSION_NUMBER "$VERSION_NUMBER"
emit VERSION_CODE "$VERSION_CODE"
echo "Extracted version: ${VERSION_DIST}-${VERSION_NUMBER}-${VERSION_CODE}"

# --- 3. diy-part1 (feeds 阶段 + 设备 pre-feeds 钩子) ---------------------------
# 先 overlay 自定义 feeds.conf.default / drivers (P3TERX 扩展点; 公开 repo 当前
# 二者皆空 -> no-op, 行为与旧 CI 一致; 私有注入可借此铺 feeds/驱动)。用 cp 不用
# mv: 不破坏 repo-root, --skip-clone 重跑幂等。
if [ -f "$MCPE_REPO_ROOT/feeds.conf.default" ]; then
  cp "$MCPE_REPO_ROOT/feeds.conf.default" "$OPENWRT_DIR/feeds.conf.default"
fi
mkdir -p "$OPENWRT_DIR/package/kernel/drivers/"
# drivers/* 不匹配 .ignore (无 dotglob) -> 当前为空时整体跳过; nullglob 防字面量残留。
# 用显式 if-then (非 A && B || C): cp 失败应随 set -e 中断, 不被 || true 吞掉。
(
  shopt -s nullglob
  driver_files=("$MCPE_REPO_ROOT"/drivers/*)
  if [ ${#driver_files[@]} -gt 0 ]; then
    cp -a "${driver_files[@]}" "$OPENWRT_DIR/package/kernel/"
  fi
)
# DEVICE/MCPE_REPO_ROOT 经 export 传给子脚本; 在 openwrt 目录内执行 (与 CI 一致)。
export DEVICE
chmod +x "$MCPE_REPO_ROOT/diy-part1.sh"
( cd "$OPENWRT_DIR" && "$MCPE_REPO_ROOT/diy-part1.sh" )

# --- 4. feeds update + install ------------------------------------------------
( cd "$OPENWRT_DIR" && ./scripts/feeds update -a && ./scripts/feeds install -a )

# --- 4.5 staged .config 落位 (feeds install 之后, 与旧 workflow 时序一致) -------
# 至此 package/feeds/ symlink 已建全, 落位后 defconfig 能正确解析所有 feed 包符号。
# 这一步绝不可提前到 feeds install 之前 (见第 2 步时序铁律说明)。
CONFIG_FILE="$OPENWRT_DIR/.config"
cp "$STAGED_CONFIG" "$CONFIG_FILE"
echo "Placed .config into openwrt tree after feeds install ($(wc -l < "$CONFIG_FILE") lines)"

# --- 5. diy-part2 (系统配置 + 设备 post-feeds 钩子) ----------------------------
# files/ overlay: 私有注入把 provision.sh+templates 放 $MCPE_REPO_ROOT/files/,
# 与 CI 同款 "有则搬进 openwrt/files" 语义。
if [ -d "$MCPE_REPO_ROOT/files" ]; then
  rm -rf "$OPENWRT_DIR/files"
  cp -a "$MCPE_REPO_ROOT/files" "$OPENWRT_DIR/files"
fi
chmod +x "$MCPE_REPO_ROOT/diy-part2.sh"
( cd "$OPENWRT_DIR" && "$MCPE_REPO_ROOT/diy-part2.sh" )

# --- 6. defconfig 展开 + download + 清残包 ------------------------------------
(
  cd "$OPENWRT_DIR"
  echo "Expanding seed config with make defconfig..."
  make defconfig
  echo "Full config lines: $(wc -l < .config)"
  make download -j8
)
prune_residual_dl "$OPENWRT_DIR/dl"

# --- 7. 预置 clash 核心 + GeoIP/GeoSite ---------------------------------------
(
  cd "$OPENWRT_DIR"
  ls -l feeds/packages/net/openclash || ls -l feeds/luci/applications/luci-app-openclash || true
  mkdir -p files/etc/openclash/core/
  CLASH_ARCH="$(clash_arch .config)"
  CLASH_CORE_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-${CLASH_ARCH}.tar.gz"
  echo "Device=$DEVICE -> Clash core arch=$CLASH_ARCH"
  curl -sL -m 30 --retry 2 "$CLASH_CORE_URL" -o /tmp/clash.tar.gz
  tar zxvf /tmp/clash.tar.gz -C /tmp
  chmod +x /tmp/clash
  mv /tmp/clash files/etc/openclash/core/clash_meta
  rm -rf /tmp/clash.tar.gz
  curl -sL -m 30 --retry 2 https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -o /tmp/GeoIP.dat
  mv /tmp/GeoIP.dat files/etc/openclash/GeoIP.dat
  curl -sL -m 30 --retry 2 https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -o /tmp/GeoSite.dat
  mv /tmp/GeoSite.dat files/etc/openclash/GeoSite.dat
  ls -l files/etc/openclash
  ls -l files/etc/openclash/core
)

# --- 8. 编译固件 --------------------------------------------------------------
(
  cd "$OPENWRT_DIR"
  make defconfig
  export MAKE="gmake"
  echo -e "$(nproc) thread compile with MAKE: $MAKE"
  make -j"$(nproc)" || make -j1 || make -j1 V=s
)

# --- 9. 抽设备名 (固件重命名/artifact 命名用; emit 到 vars 文件) --------------
(
  cd "$OPENWRT_DIR"
  grep '^CONFIG_TARGET.*DEVICE.*=y' .config | sed -r 's/.*DEVICE_(.*)=y/\1/' > DEVICE_NAME
)
if [ -s "$OPENWRT_DIR/DEVICE_NAME" ]; then
  emit DEVICE_NAME "_$(cat "$OPENWRT_DIR/DEVICE_NAME")"
fi
emit FILE_DATE "_$(date +"%Y%m%d%H%M")"
emit BUILD_STATUS success

echo "==> build-firmware: done. vars written to $VARS_OUT"
