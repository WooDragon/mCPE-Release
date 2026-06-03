# mCPE-Release 项目Memory

## 文档维护规范

**本文件的维护规则**：
1. 单分支架构下，本文件随代码变更在同一分支（main 或特性分支）一并修改，经 PR 合并回 main 生效
2. 修改流程：
   ```bash
   # 在 main 或特性分支编辑 CLAUDE.md，与相关代码变更同一提交
   git add CLAUDE.md && git commit -m "docs: update CLAUDE.md"
   git push
   ```
3. 不再需要"同步到所有设备分支"——单分支已消除分支漂移

## 项目概述

基于ImmortalWRT 24.10的个性化编译项目，使用GitHub Actions matrix实现多设备并行自动化编译和发布。

**架构演进**：
- 2024年12月从coolsnowwolf/lede迁移至ImmortalWRT，详见issue #2
- 2026年6月从"每设备一分支"合并为"main单分支 + 动态matrix构建"，并新增R3S、修复r68s废固件bug，详见issue #5

## 技术栈与版本

### 核心组件
- **OpenWrt源码**: [ImmortalWRT](https://github.com/immortalwrt/immortalwrt) openwrt-24.10分支
- **默认Tag**: v24.10.6（2026-06 从 v24.10.4 升级，根治 rust CI LLVM 404，详见 issue #9）
- **构建平台**: GitHub Actions (ubuntu-22.04)
- **编译工具链**: GCC/G++ (Ubuntu 22.04默认版本)

### 关键特性
- **OpenClash**: ImmortalWRT内置，无需额外feeds
- **第三方feeds**: 仅r5s-outdoor通过设备钩子`devices/r5s-outdoor/pre-feeds.sh`注入outdoor-backup
- **种子配置架构**: `config/common.config`(全设备交集) + `devices/<dev>/seed.config`(设备delta)，`make defconfig`自动展开
- **单分支matrix**: main单分支承载全部设备，workflow按device choice动态生成构建矩阵

## 架构

### 单分支 matrix 模型
```
main (单分支，承载全部设备)
├── config/common.config          # 全设备种子配置严格交集 (~72行)
├── devices/
│   ├── r2s/seed.config           # NanoPi R2S delta
│   ├── r3s/seed.config           # NanoPi R3S delta (RK3566)
│   ├── r5s/seed.config           # NanoPi R5S delta
│   ├── r5s-outdoor/
│   │   ├── seed.config           # R5S + 存储包 delta
│   │   └── pre-feeds.sh          # 设备钩子: 注入 outdoor feed
│   ├── r68s/seed.config          # NanoPi R68S delta (lunzn_fastrhino)
│   └── x86/seed.config           # x86_64 + GRUB/EFI/VMDK delta
└── tests/bdd-matrix-build.sh     # 36条 BDD 断言回归套件
```

### 种子配置架构

**设计理念**：
- `config/common.config` 声明全设备共有的**用户意图**（应用层包、版本号、ccache）
- `devices/<dev>/seed.config` 只声明该设备的 delta（TARGET 符号、VERSION_CODE/HWREV、设备专属包）
- 拼装契约：`cat config/common.config devices/$DEVICE/seed.config > .config`，再由 `make defconfig` 展开为完整配置

**铁律**：
- `common.config` 不得含任何架构/平台相关项（无 TARGET 平台符号、无 GRUB/VMDK、无平台专属 kmod），架构项一律下沉到 `devices/<dev>/seed.config`
- 设备 DEVICE 符号必须是上游真实有效符号（见 BDD 断言 B13），无效符号会被 defconfig 静默丢弃并回退编出错误设备固件（r68s 历史教训）

**设备钩子机制**：
- `diy-part1.sh` 末尾按 `$DEVICE` 挂载 `devices/$DEVICE/pre-feeds.sh`（feeds update 前）
- `diy-part2.sh` 末尾挂载 `devices/$DEVICE/post-feeds.sh`（系统配置阶段，当前无设备使用，预留）
- `$DEVICE` 为空时静默跳过，不报错

### 配置管理规则

1. **通用包**：增删跨设备共有的包 → 改 `config/common.config`
2. **设备专属**：某设备独有的 TARGET/包 → 改 `devices/<dev>/seed.config`
3. **新增设备**：建 `devices/<新设备>/seed.config` + workflow 的 device choice options 加项 + BDD B13 白名单加上游符号
4. **新增 feed/特殊定制**：建 `devices/<dev>/pre-feeds.sh` 或 `post-feeds.sh` 钩子

## 项目文件结构

```
.
├── .github/workflows/
│   └── openwrt-builder.yml           # 主编译流程 (prepare + build matrix)
├── config/
│   └── common.config                 # 全设备种子配置交集
├── devices/<dev>/
│   ├── seed.config                   # 设备 delta
│   └── pre-feeds.sh / post-feeds.sh  # 设备钩子 (按需)
├── scripts/netdata/
│   └── global_traffic.plugin         # Netdata插件
├── tests/
│   └── bdd-matrix-build.sh           # BDD 回归套件
├── diy-part1.sh                      # Feeds阶段定制 (+ 设备钩子挂载)
├── diy-part2.sh                      # 系统配置定制 (+ 设备钩子挂载)
└── CLAUDE.md
```

## 核心工作流

### openwrt-builder.yml

**关键特性**：
- **触发**: 仅 `workflow_dispatch`，device choice（all/r2s/r3s/r5s/r5s-outdoor/r68s/x86）+ openwrt_tag
- **双 job 架构**: `prepare`（device choice → 动态 matrix JSON）→ `build`（matrix.device 并行，fail-fast: false）
- **源码管理**: 基于tag checkout（默认v24.10.6），支持手动指定
- **架构探测**: Clash 核心按 `grep CONFIG_TARGET_x86` 选 amd64/arm64（不依赖分支名）
- **缓存策略**: 只缓存 `dl`（源码包跨设备复用）+ `ccache`，不缓存 build_dir/staging_dir（单设备即超 10GB 全局上限，会触发 LRU 雪崩）
- **Release**: Tag格式`{设备名}-YYYY.MM.DD-HHMM`，每设备保留2个；清理用 date-anchored 正则隔离 + 退避重试防限流

**环境变量**：
```bash
REPO_URL: https://github.com/immortalwrt/immortalwrt
REPO_BRANCH: openwrt-24.10
OPENWRT_TAG: v24.10.6  # 可通过workflow_dispatch指定
DEVICE: ${{ matrix.device }}  # build job 级注入，全 step 可见
```

**构建流程**（build job）：
```
1. Clone ImmortalWRT (git checkout tag)
2. 拼装种子: cat config/common.config devices/$DEVICE/seed.config > .config
3. 执行diy-part1.sh (feeds阶段 + 设备 pre-feeds 钩子)
4. ./scripts/feeds update && install
5. 执行diy-part2.sh (系统配置 + 设备 post-feeds 钩子)
6. make defconfig (展开) → make download && make
7. 重命名固件 (MCPE-251228-NN-*) → 上传Release → 清理旧Release
```

## 定制配置

### diy-part1.sh（Feeds阶段）

ImmortalWRT内置OpenClash，公共部分无需额外feeds。设备专属 feed 通过钩子注入：
```bash
# 公共 (config/common.config 对应): 无需添加 feeds，OpenClash 已内置
# r5s-outdoor 专属: devices/r5s-outdoor/pre-feeds.sh
echo 'src-git outdoor https://github.com/WooDragon/outdoor-backup' >>feeds.conf.default
```
diy-part1.sh 末尾按 `$DEVICE` 自动 source 对应钩子，无钩子则静默跳过（钩子本身报错则因 `set -euo pipefail` 中断构建）。

### fail-loud 定制原语（scripts/diy-lib.sh）

**设计动机**：裸 `sed -i 's/X/Y/'` 在 X 零匹配时返回 0（静默 no-op）。上游一旦改了我们依赖的默认串，定制就无声蒸发、固件照常产出，直到运行期才暴露（历史教训：rust patch 失效编译 404；dropbear `Interface` 串从 4 空格变 1 空格险些导致 WAN SSH 哑火）。

**契约**：`scripts/diy-lib.sh` 提供两个 fail-loud helper，是 diy 脚本与 BDD 共享的单一真相源：
- `sed_required <desc> <expr> <file>`：sed 未改动任何内容（零匹配）或文件不存在 → 返回非 0，配合 `set -e` 中断构建。实现用 `sed`（不带 `-i`）+ `cmp -s` 比对，BSD/GNU sed 行为一致。
- `append_required <desc> <file> <content>`：目标文件不存在 → 返回非 0（避免凭空造没人读的孤儿文件）。

**铁律**：diy 脚本里所有针对上游文件的定制必须走 `sed_required`/`append_required`，不得用裸 `sed -i`。新增定制时同理。BDD 的 B15/B16/B16b/B17 守护此机制本身；具体命令是否命中真实上游文件，由 CI 全量构建兜底（现在会响亮失败而非静默放过）。

### diy-part2.sh（系统配置）

**UCI Defaults配置**：
- LAN IP: 192.168.233.1
- 主机名: MCPE

**安全配置**：
- SSH端口: 65422
- 禁用密码认证，仅允许密钥
- WAN侧防火墙已开放65422
- dropbear `Interface 'lan'` 用 `[[:space:]]*` 容差正则解绑（不依赖上游空格数量）

**系统优化**：
- 主题: luci-theme-argon（仅 patch 实际编译的 `luci-nginx` collection；`luci`/`luci-ssl-nginx` 两条旧 sed 是死代码已删，后者在 v24.10.6 已并入 luci-nginx）
- TCP拥塞控制: BBR
- Nginx: client_max_body_size=1024M

> rust download-ci-llvm patch 已随 v24.10.6 升级移除：上游 packages feed 自带 `download-ci-llvm=false`，无需再 patch。详见 issue #9 / [docs/rust-ci-llvm-404-fix.md](docs/rust-ci-llvm-404-fix.md)。

## 设备架构映射

| 设备 | 上游 DEVICE 符号 | 架构 | VERSION_CODE | 备注 |
|------|-----------------|------|:---:|------|
| r2s | friendlyarm_nanopi-r2s | rockchip armv8 (arm64) | 03 | 双网口 |
| r3s | friendlyarm_nanopi-r3s | rockchip armv8 (arm64) | 06 | RK3566，2026新增 |
| r5s | friendlyarm_nanopi-r5s | rockchip armv8 (arm64) | 04 | 多网口 |
| r5s-outdoor | friendlyarm_nanopi-r5s | rockchip armv8 (arm64) | 05 | + outdoor feed + 存储包 |
| r68s | lunzn_fastrhino-r68s | rockchip armv8 (arm64) | 04 | 企业级；符号厂商前缀是 lunzn_fastrhino 非 friendlyarm |
| x86 | x86_64_DEVICE_generic | x86_64 (amd64) | 05 | + GRUB/EFI/VMDK + 存储包 |

> 具体 CONFIG 行以 `config/common.config` + `devices/<dev>/seed.config` 为权威，本表仅作导航。
> ⚠️ r68s 历史教训：旧分支误用 `friendlyarm_nanopi-r68s`（无效符号），defconfig 回退编出 `ariaboard_photonicat` 废固件，详见 issue #5。

## 操作规范

### 触发编译
```bash
# GitHub Web界面
Actions -> OpenWrt Builder -> Run workflow -> 选 device (all 或单设备)

# gh CLI: 全量
gh workflow run "OpenWrt Builder" -f device=all
# gh CLI: 单设备
gh workflow run "OpenWrt Builder" -f device=r3s
gh workflow run "OpenWrt Builder" -f device=r5s -f openwrt_tag=v24.10.6
```

### 修改配置
```bash
# 通用包: 改 config/common.config
# 设备专属: 改 devices/<dev>/seed.config
# 改完跑本地回归确认契约不破
bash tests/bdd-matrix-build.sh

git add config devices && git commit -m "config: xxx (#issue)"
git push   # 单分支直接推，无需同步多分支
```

### 新增设备
```bash
# 1. 建 devices/<新设备>/seed.config (TARGET 符号 + VERSION_CODE/HWREV)
# 2. workflow device choice options 加该设备
# 3. tests/bdd-matrix-build.sh 的 UPSTREAM_VALID_SYMBOLS 白名单加上游符号
# 4. 先单设备冒烟验证全链路，通过后再放 all
```

## 故障排查

### 编译失败

**调试流程**：
1. 查看日志，找**第一个**ERROR（不是最后一个）
2. 分层分析：表层现象 → 中层错误 → 深层根因
3. 使用`make -j1 V=s`启用详细日志

**常见问题**：
1. 拼装的 `.config` 缺设备符号 → 检查 `devices/<dev>/seed.config` 是否存在且 device 符号有效
2. 固件文件名设备不对 → device 符号是无效符号被 defconfig 回退（跑 BDD B13 核验）
3. 磁盘空间不足 → 检查/mnt分区
4. 包编译失败 → 检查 common.config / seed.config 中的包选择
5. r5s-outdoor 缺 outdoor 包 → 检查 `$DEVICE` 注入是否生效（pre-feeds 钩子依赖它）

### 配置验证
改动 config/devices 后跑本地回归，确认拼装契约与上游符号有效性不破：
```bash
bash tests/bdd-matrix-build.sh   # 36 条断言，含拼装等价性 + 上游符号白名单
```

## 安全规范

### Git Commit Message
```bash
# ❌ 禁止cross-reference外部issue
git commit -m "fix: issue coolsnowwolf/lede#7127"

# ✅ 允许文字描述
git commit -m "fix: upgrade package for compatibility"

# ✅ 允许引用本项目issue
git commit -m "fix: resolve build error, close #1"
```

### 包选择原则
- 每个包必须有明确理由
- 最小化原则：只包含运行时必需组件
- 禁止"以防万一"添加包

## 参考资源

### 技术文档（docs/）
- [docs/rust-ci-llvm-404-fix.md](docs/rust-ci-llvm-404-fix.md) — rust [host] 编译 CI LLVM 404 的根因/临时 patch/升级根治方向（v24.10.4 feed pin 锁死 rust 1.89.0）
- [docs/uwsgi-gcc-fix-journey.md](docs/uwsgi-gcc-fix-journey.md) — uwsgi 包 GCC 编译错误排查记录

### 项目文档（Issue）
- [迁移计划 issue #2](https://github.com/WooDragon/mCPE-Release/issues/2)
- [历史问题归档 issue #4](https://github.com/WooDragon/mCPE-Release/issues/4)
- [单分支matrix合并 + R3S + r68s修复 issue #5](https://github.com/WooDragon/mCPE-Release/issues/5)
- [rust CI LLVM 404 修复 issue #6（已关闭）](https://github.com/WooDragon/mCPE-Release/issues/6)
- [清理旧设备分支跟踪 issue #8](https://github.com/WooDragon/mCPE-Release/issues/8)
- [升级 tag v24.10.6 根治 rust LLVM issue #9](https://github.com/WooDragon/mCPE-Release/issues/9)

### 外部资源
- [ImmortalWRT](https://github.com/immortalwrt/immortalwrt)
- [P3TERX Actions-OpenWrt](https://github.com/P3TERX/Actions-OpenWrt)
- [OpenClash](https://github.com/vernesong/OpenClash)
- [OpenWrt构建系统](https://openwrt.org/docs/guide-developer/build-system/use-buildsystem)
