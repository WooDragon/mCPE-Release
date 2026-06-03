# rust CI LLVM 404 问题：根因、临时方案与根治记录

> **状态（2026-06）**：已根治。编译 tag 升级至 v24.10.6（上游 packages feed 自带 `download-ci-llvm=false`），本仓库临时 patch 已移除。本文档保留根因与演进记录备查。详见 issue #9。

## 问题现象

GitHub Actions 编译固件时，`rust` 包（host 工具链）构建失败：

```
python3 .../host/rustc-1.89.0-src/x.py ... dist build-manifest ...
curl: (22) The requested URL returned error: 404
ERROR: failed to download llvm from ci
ERROR: package/feeds/packages/rust [host] failed to build.
make: *** [include/toplevel.mk:233: world] Error 2
```

`rust` 是 `luci-app-mosdns` / `luci-app-netdata` 等包的传递依赖，全设备共性。该失败导致整个 `make world` 中断，编不出固件。

归档 Issue：本仓库 issue #6（已关闭）。

## 根因

### LLVM 与 rustc 的关系

`rustc`（Rust 编译器）以 LLVM 为后端，所以**编译 rustc 必须先有一份 LLVM**。LLVM 是巨型 C++ 项目，从源码编译需 30-60 分钟。

Rust 的构建脚本 `x.py` 默认从 `ci-artifacts.rust-lang.org` 下载官方 CI 预编译的 LLVM 二进制（`download-ci-llvm=true`），跳过本地编译以加速。

### 失效链条

1. ImmortalWRT tag `v24.10.4` 的 `feeds.conf.default` 把 packages feed **pin 死**在 commit `83e0be6d`（`^commit` 语法）。
2. 该 commit 锁定 **rust 1.89.0 + `--set=llvm.download-ci-llvm=true`**（Makefile 第 78 行）。
3. Rust 官方 CI artifacts **有保质期，超期被自动删除**。1.89.0 对应的 LLVM 制品已被删 → 下载返回 404。
4. 上游 `immortalwrt/packages` 已于 2026-03 修复（commit `360ffee`：rust 升 1.90.0 + `download-ci-llvm=false`），但 v24.10.4 的 pin 锁死旧 commit，拿不到修复。

时间线佐证：同一套配置在 2026-01-05 能成功编译（CI 制品尚在），2026-06 失败（制品已删）。

## 历史临时方案（已移除）

> ⚠️ 以下 patch 是 v24.10.4 时代的临时绕过，**已随 2026-06 升级到 v24.10.6 移除**。保留此节仅作历史背景，当前 `diy-part2.sh` 不再含此 patch。

曾在 `diy-part2.sh` 开头（feeds install 之后、rust Makefile 已存在）sed patch：

```bash
# 将 download-ci-llvm=true 改为 false，强制本地编译 LLVM
sed -i 's/--set=llvm\.download-ci-llvm=true/--set=llvm.download-ci-llvm=false/g' \
  feeds/packages/lang/rust/Makefile
```

- **效果**：不再依赖外部 CI 制品，本地从源码编译 LLVM，确定性修复。
- **代价**：每个 build job 多耗 30-60 分钟编译 LLVM。
- **守护**（已反转）：曾用 BDD 断言 B14 守护 patch 不被误删；移除 patch 后 B14 反转为「断言 diy-part2.sh 不再含 rust patch」防回退。

## 根治（已落地：升级 v24.10.6）

落地 Issue：本仓库 issue #9。2026-06 已将默认 tag 从 v24.10.4 升级到 **v24.10.6**，移除临时 patch，跟随上游官方 `download-ci-llvm=false` 默认。

### 上游各 tag 的 rust 配置对照

核实于 2026-06（ImmortalWRT openwrt-24.10 系列；v24.10.6 为当时最新稳定 tag，无 v24.10.7）：

| tag | rust 版本 | download-ci-llvm | 评价 |
|-----|----------|:---:|------|
| v24.10.4（旧） | 1.89.0 | true | ❌ 1.89.0 CI 制品已删 → 404 |
| v24.10.5 | 1.90.0 | **true** | ⚠️ 定时炸弹：靠 1.90.0 制品暂时在线，制品被删后同样 404 |
| **v24.10.6（当前）** | 1.90.0 | **false** | ✅ 根治：本地编译是上游官方默认，不依赖会过期的制品 |

### 关键结论

- 升级目标必须是 **v24.10.6**，不能停在 v24.10.5（后者仍 `download-ci-llvm=true`，隐患未除）。已确认 5 个设备符号在 v24.10.6 全部有效、无改名，seed.config 可原样沿用。
- v24.10.6 同样是本地编译 LLVM，**升级本身不消除编译耗时**；其价值在于去掉本仓库的临时 patch（跟上游官方配置）+ 不再依赖会过期的外部制品。
- 要消除 30-60 分钟耗时，需正交的"缓存 rust LLVM 编译产物"方案（约 1-2GB，低于 GitHub 10GB 缓存上限）。详见 issue #9 方案 B（与本次升级正交，未落地）。

## 外部参考

- OpenWrt 社区同问题讨论：https://forum.openwrt.org/t/rust-error-failed-to-download-llvm-from-ci/227143
- 上游 bug report：https://github.com/openwrt/packages/issues/27331
