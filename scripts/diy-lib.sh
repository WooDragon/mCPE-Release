# shellcheck shell=bash
# =============================================================================
# scripts/diy-lib.sh — diy 脚本共享的"必中即改, 未中即停"定制原语
# =============================================================================
# 设计动机 (Never break userspace 的反向教训):
#   裸 `sed -i 's/X/Y/'` 在 X 零匹配时返回 0 (静默 no-op)。上游一旦改了我们
#   依赖的默认串, 定制就无声蒸发, 固件照常产出, 直到运行期才暴露 (典型: rust
#   patch 失效编译 404; dropbear Interface 串变化导致 WAN SSH 哑火)。
#   本库把"无变化"重定义为"失败", 让上游漂移在 *构建期* 响亮中断, 而非
#   运行期静默猝死。配合 diy 脚本的 `set -e`, 任一 helper 失败即中断构建。
#
# 用法 (被 diy-part2.sh source, 也被 tests/bdd-matrix-build.sh source 做机制测试):
#   . "$(dirname "$0")/scripts/diy-lib.sh"
# =============================================================================

# -----------------------------------------------------------------------------
# sed_required <desc> <sed-expr> <file>
#   对 <file> 执行 in-place sed; 若文件不存在或表达式未改动任何内容则失败。
#   参数:
#     desc      — 人类可读的定制说明 (日志用)
#     sed-expr  — 传给 `sed -i` 的脚本 (与裸 sed 完全一致, 不重复书写 pattern)
#     file      — 目标文件路径
#   返回: 命中并改动 → 0; 文件缺失 / 零匹配 (no-op) → 1
#   实现: sed 输出到临时文件 + cmp 字节级比对 + 写回。刻意不用 `sed -i`:
#         GNU 的 `-i` 与 BSD/macOS 的 `-i` 语义不同 (后者把下一个参数当备份后缀),
#         不带 -i 的管道式 sed 在两边行为完全一致 — diy-lib 同时被 CI(GNU) 与
#         本地 BDD(可能 BSD) source, 必须可移植。cmp 比 $(cat) 变量比对更精确,
#         不会吞掉尾部换行。对 s/// 替换与 /anchor/a 追加一律通用。
# -----------------------------------------------------------------------------
sed_required() {
  local desc="$1" expr="$2" file="$3"
  if [ ! -f "$file" ]; then
    echo "ERROR [diy]: ${desc} — 目标文件不存在: ${file} (上游已移除/改名?)" >&2
    return 1
  fi
  local tmp
  tmp="$(mktemp)" || { echo "ERROR [diy]: ${desc} — mktemp 失败" >&2; return 1; }
  if ! sed "$expr" "$file" > "$tmp"; then
    rm -f "$tmp"
    echo "ERROR [diy]: ${desc} — sed 执行失败 (表达式非法?): '${expr}' @ ${file}" >&2
    return 1
  fi
  if cmp -s "$file" "$tmp"; then
    rm -f "$tmp"
    echo "ERROR [diy]: ${desc} — sed 零匹配, 定制未生效 (上游默认串已变?): '${expr}' @ ${file}" >&2
    return 1
  fi
  cat "$tmp" > "$file"   # 写回原文件 (保留 inode/权限, 优于 mv)
  rm -f "$tmp"
  echo "==> [diy] ${desc}"
}

# -----------------------------------------------------------------------------
# append_required <desc> <file> <content>
#   向 *已存在* 的 <file> 追加 <content>。文件缺失即失败 —— 我们是在上游配置
#   尾部追加, 而非创建新文件; 文件不在意味着上游挪了位置, 此时静默用 >> 凭空
#   造一个没人读的孤儿文件才是真 bug, 故响亮失败。
#   参数: desc 说明 / file 目标文件 / content 追加内容 (可多行)
#   返回: 文件存在并追加 → 0; 文件缺失 → 1
# -----------------------------------------------------------------------------
append_required() {
  local desc="$1" file="$2" content="$3"
  if [ ! -f "$file" ]; then
    echo "ERROR [diy]: ${desc} — 目标文件不存在: ${file} (上游已移除/改名?)" >&2
    return 1
  fi
  printf '%s\n' "$content" >> "$file"
  echo "==> [diy] ${desc}"
}
