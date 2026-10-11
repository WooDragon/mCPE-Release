# shellcheck shell=bash
# Shared B04/B22 integration scenarios: source only defines functions.
# Args: none; uses matrix runner counters and REPO_ROOT; records each assertion.
run_media_date_feed_cases() {
scenario "B04b — r5s-outdoor hook 实际写入固定 outdoor feed，且仅一次"
# 在隔离目录 source 交付 hook，验证实际副作用而非誊抄其实现。固定 revision
# 是可复现构建的输入契约；格式检查防止未来把短 hash 或可变引用悄悄带回来。
OUTDOOR_FEED_REVISION="20aeaf59e96a4e9a704922c3a4007885af4d016f"
outdoor_feed_tmp="$(mktemp -d)"
if (
  cd "$outdoor_feed_tmp" || exit 2
  # shellcheck source=devices/r5s-outdoor/pre-feeds.sh
  . "$REPO_ROOT/devices/r5s-outdoor/pre-feeds.sh"
) >/dev/null 2>&1; then
  outdoor_feed_file="$outdoor_feed_tmp/feeds.conf.default"
  outdoor_feed_count="$(grep -c '^src-git outdoor ' "$outdoor_feed_file" 2>/dev/null || true)"
  outdoor_feed_line="$(grep '^src-git outdoor ' "$outdoor_feed_file" 2>/dev/null || true)"
  outdoor_feed_url="${outdoor_feed_line#src-git outdoor }"
  outdoor_feed_repo="${outdoor_feed_url%%^*}"
  outdoor_feed_revision="${outdoor_feed_url##*^}"
  if [ "$outdoor_feed_count" = "1" ] \
     && [ "$outdoor_feed_repo" = "https://github.com/WooDragon/outdoor-backup" ] \
     && [[ "$outdoor_feed_revision" =~ ^[0-9a-f]{40}$ ]] \
     && [ "$outdoor_feed_revision" = "$OUTDOOR_FEED_REVISION" ]; then
    ok "hook 实际写入一次固定 40 位 outdoor revision"
  else
    bad "outdoor feed 不可复现或重复: count=$outdoor_feed_count line=$outdoor_feed_line"
  fi
else
  bad "source r5s-outdoor pre-feeds hook 失败"
fi
rm -rf "$outdoor_feed_tmp"

scenario "B04c — outdoor 包选择只在 r5s-outdoor seed 显式声明"
if grep -qxF 'CONFIG_PACKAGE_outdoor-backup=y' devices/r5s-outdoor/seed.config \
   && grep -qxF 'CONFIG_PACKAGE_luci-app-outdoor-backup=y' devices/r5s-outdoor/seed.config \
   && grep -qxF 'CONFIG_PACKAGE_outdoor-backup-media-date=y' devices/r5s-outdoor/seed.config; then
  ok "r5s-outdoor seed 显式选择 outdoor-backup core、LuCI 与 media-date 包"
else
  bad "r5s-outdoor seed 缺少显式 outdoor-backup core/LuCI/media-date 包选择"
fi

outdoor_leak="$(grep -nE 'CONFIG_PACKAGE_(luci-app-)?outdoor-backup=y|outdoor-backup' config/common.config || true)"
for dev in r2s r3s r5s r68s x86; do
  outdoor_leak="${outdoor_leak}$(grep -nE 'CONFIG_PACKAGE_(luci-app-)?outdoor-backup=y|outdoor-backup' "devices/$dev/seed.config" || true)"
  if [ -f "devices/$dev/pre-feeds.sh" ]; then
    outdoor_leak="${outdoor_leak}$(grep -n 'outdoor-backup' "devices/$dev/pre-feeds.sh" || true)"
  fi
done
if [ -z "$outdoor_leak" ]; then
  ok "common 与其他设备均未引入 outdoor 包或 feed"
else
  bad "outdoor 包/feed 泄漏到公共或其他设备配置: $outdoor_leak"
fi

}

# Args: none; exercises the delivered read-only guard, including all 14 symbols.
run_media_date_guard_cases() {
scenario "B22b — r5s-outdoor 展开配置必须保留完整 PhotoPrism/outdoor contract (调真函数)"
# Issue #37: feeds 索引失败曾使 make defconfig 静默剔除 outdoor 两包，完整 make
# 仍返回成功。此处加载交付 build-lib.sh 的真函数，以等价组覆盖精确 =y、缺失、
# not-set、=m、近似前后缀与缺文件；不是模拟 Kconfig。BusyBox CUSTOM 与三项
# applet 选择同属运行期不可拆分合同。
REQUIRED_PKG_TMP="$(mktemp -d)"

write_required_config() {
  local config_path="$1"
  shift
  printf '%s\n' "$@" > "$config_path"
}
photo_runtime_symbols=(
  CONFIG_PACKAGE_outdoor-backup-media-date
  CONFIG_PACKAGE_luci-app-filemanager
  CONFIG_PACKAGE_jsonfilter
  CONFIG_PACKAGE_exiftool
  CONFIG_BUSYBOX_CUSTOM
  CONFIG_BUSYBOX_CONFIG_TIMEOUT
  CONFIG_BUSYBOX_CONFIG_FLOCK
  CONFIG_BUSYBOX_CONFIG_SETSID
  CONFIG_PACKAGE_dockerd
  CONFIG_PACKAGE_docker-compose
  CONFIG_DOCKER_STO_EXT4
  CONFIG_DOCKER_STO_BTRFS
)
required_pkg_cases=(
  "both-y|CONFIG_PACKAGE_outdoor-backup=y|CONFIG_PACKAGE_luci-app-outdoor-backup=y|pass|"
  "core-missing||CONFIG_PACKAGE_luci-app-outdoor-backup=y|fail|CONFIG_PACKAGE_outdoor-backup"
  "luci-missing|CONFIG_PACKAGE_outdoor-backup=y||fail|CONFIG_PACKAGE_luci-app-outdoor-backup"
  "core-not-set|# CONFIG_PACKAGE_outdoor-backup is not set|CONFIG_PACKAGE_luci-app-outdoor-backup=y|fail|CONFIG_PACKAGE_outdoor-backup"
  "luci-module|CONFIG_PACKAGE_outdoor-backup=y|CONFIG_PACKAGE_luci-app-outdoor-backup=m|fail|CONFIG_PACKAGE_luci-app-outdoor-backup"
  "core-prefix|XCONFIG_PACKAGE_outdoor-backup=y|CONFIG_PACKAGE_luci-app-outdoor-backup=y|fail|CONFIG_PACKAGE_outdoor-backup"
  "luci-suffix|CONFIG_PACKAGE_outdoor-backup=y|CONFIG_PACKAGE_luci-app-outdoor-backup-extra=y|fail|CONFIG_PACKAGE_luci-app-outdoor-backup"
)
required_failures=0
for required_pkg_case in "${required_pkg_cases[@]}"; do
  IFS='|' read -r case_name core_line luci_line expected expected_symbol <<< "$required_pkg_case"
  case_config="$REQUIRED_PKG_TMP/$case_name.config"
  case_before="$REQUIRED_PKG_TMP/$case_name.before"
  case_out="$REQUIRED_PKG_TMP/$case_name.stdout"
  case_err="$REQUIRED_PKG_TMP/$case_name.stderr"
  runtime_lines=()
  for runtime_symbol in "${photo_runtime_symbols[@]}"; do runtime_lines+=("${runtime_symbol}=y"); done
  write_required_config "$case_config" "$core_line" "$luci_line" "${runtime_lines[@]}"
  cp "$case_config" "$case_before"
  if verify_device_packages r5s-outdoor "$case_config" >"$case_out" 2>"$case_err"; then
    case_rc=0
  else
    case_rc=$?
  fi
  if ! cmp -s "$case_config" "$case_before"; then
    bad "$case_name: 校验函数改写了展开配置"
    required_failures=1
  elif [ "$expected" = pass ] && [ "$case_rc" -eq 0 ]; then
    ok "$case_name: 14 个必装符号均精确 =y 时通过，配置字节未变"
  elif [ "$expected" = fail ] && [ "$case_rc" -ne 0 ] \
       && grep -Fq 'ERROR:' "$case_err" \
       && grep -Fq 'r5s-outdoor' "$case_err" \
       && grep -Fq "$expected_symbol" "$case_err" \
       && grep -Fq "$case_config" "$case_err"; then
    ok "$case_name: 无效选择被响亮拒绝，错误含设备/symbol/配置路径"
  else
    bad "$case_name: rc=$case_rc stderr=$(tr '\n' ' ' < "$case_err")"
    required_failures=1
  fi
done
[ "$required_failures" = 0 ] || true

runtime_guard_failures=0
for runtime_mode in missing not-set module prefix suffix; do
  for runtime_symbol in "${photo_runtime_symbols[@]}"; do
    runtime_config="$REQUIRED_PKG_TMP/${runtime_symbol##CONFIG_}-$runtime_mode.config"
    runtime_lines=()
    for candidate_symbol in "${photo_runtime_symbols[@]}"; do
      if [ "$candidate_symbol" = "$runtime_symbol" ]; then
        case "$runtime_mode" in
          missing) ;;
          not-set) runtime_lines+=("# $candidate_symbol is not set") ;;
          module) runtime_lines+=("$candidate_symbol=m") ;;
          prefix) runtime_lines+=("X$candidate_symbol=y") ;;
          suffix) runtime_lines+=("$candidate_symbol-extra=y") ;;
        esac
      else
        runtime_lines+=("$candidate_symbol=y")
      fi
    done
    write_required_config "$runtime_config" 'CONFIG_PACKAGE_outdoor-backup=y' 'CONFIG_PACKAGE_luci-app-outdoor-backup=y' "${runtime_lines[@]}"
    if verify_device_packages r5s-outdoor "$runtime_config" >"$runtime_config.out" 2>"$runtime_config.err"; then
      bad "$runtime_symbol $runtime_mode: 无效 runtime 选择竟通过"
      runtime_guard_failures=1
    elif grep -Fq "$runtime_symbol" "$runtime_config.err"; then
      ok "$runtime_symbol $runtime_mode: r5s-outdoor runtime contract 响亮拒绝"
    else
      bad "$runtime_symbol $runtime_mode: 错误未列出缺失 symbol"
      runtime_guard_failures=1
    fi
  done
done
[ "$runtime_guard_failures" = 0 ] || true

scenario "B22c — 其他五设备不受 outdoor 必装门限制"
other_device_failures=0
for other_device in r2s r3s r5s r68s x86; do
  if verify_device_packages "$other_device" "$REQUIRED_PKG_TMP/no-such-$other_device.config" >/dev/null 2>&1; then
    ok "$other_device: 不读取 outdoor 配置门，直接通过"
  else
    bad "$other_device: 被错误施加 outdoor 包限制"
    other_device_failures=1
  fi
done
[ "$other_device_failures" = 0 ] || true

scenario "B22d — r5s-outdoor 缺展开配置响亮失败且列出全部必装 symbol 与路径"
missing_config="$REQUIRED_PKG_TMP/no-such-outdoor.config"
missing_symbols=(CONFIG_PACKAGE_outdoor-backup CONFIG_PACKAGE_luci-app-outdoor-backup "${photo_runtime_symbols[@]}")
missing_error_complete=1
if verify_device_packages r5s-outdoor "$missing_config" >"$REQUIRED_PKG_TMP/missing.stdout" 2>"$REQUIRED_PKG_TMP/missing.stderr"; then
  bad "缺展开配置竟通过"
else
  for missing_symbol in "${missing_symbols[@]}"; do
    grep -Fq "$missing_symbol" "$REQUIRED_PKG_TMP/missing.stderr" || missing_error_complete=0
  done
  if grep -Fq 'ERROR:' "$REQUIRED_PKG_TMP/missing.stderr" \
     && grep -Fq 'r5s-outdoor' "$REQUIRED_PKG_TMP/missing.stderr" \
     && [ "$missing_error_complete" = 1 ] \
     && grep -Fq "$missing_config" "$REQUIRED_PKG_TMP/missing.stderr"; then
    ok "缺展开配置被响亮拒绝，错误含全部必装 symbol 与路径"
  else
    bad "缺展开配置错误信息不完整: $(tr '\n' ' ' < "$REQUIRED_PKG_TMP/missing.stderr")"
  fi
fi

rm -rf "$REQUIRED_PKG_TMP"
}
