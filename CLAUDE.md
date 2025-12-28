# mCPE-Release 项目Memory

## 文档维护规范

**本文件的维护规则**：
1. **仅在main分支修改本文件**，禁止在设备分支直接修改
2. 修改流程：
   ```bash
   git checkout main
   # 编辑CLAUDE.md...
   git add CLAUDE.md && git commit -m "docs: update CLAUDE.md"
   git push origin main

   # 合并到所有设备分支
   for branch in r2s r5s r5s-outdoor r68s x86; do
     git checkout $branch && git merge main && git push origin $branch
   done
   ```
3. **冲突处理**：使用`git checkout main -- CLAUDE.md`保留main版本

## 项目概述

基于ImmortalWRT 24.10的个性化编译项目，使用GitHub Actions实现自动化编译和发布。

**迁移历史**：2024年12月从coolsnowwolf/lede迁移至ImmortalWRT，详见issue #2

## 技术栈与版本

### 核心组件
- **OpenWrt源码**: [ImmortalWRT](https://github.com/immortalwrt/immortalwrt) openwrt-24.10分支
- **默认Tag**: v24.10.4
- **构建平台**: GitHub Actions (ubuntu-22.04)
- **编译工具链**: GCC/G++ (Ubuntu 22.04默认版本)

### 关键特性
- **OpenClash**: ImmortalWRT内置，无需额外feeds
- **第三方feeds**: 仅r5s-outdoor分支使用outdoor-backup
- **种子配置架构**: ~150行种子配置，`make defconfig`自动展开

## 分支架构

### 分支模型
```
main (通用配置基线，无.config)
├── r2s (NanoPi R2S - rockchip/armv8)
├── r5s (NanoPi R5S - rockchip/armv8)
├── r5s-outdoor (NanoPi R5S + outdoor-backup)
├── r68s (NanoPi R68S - rockchip/armv8)
└── x86 (x86_64通用)
```

### 种子配置架构

**设计理念**：
- 种子配置（~150行）只声明**用户意图**
- `make defconfig`自动解决依赖，展开为完整配置
- 配置文件从8927行压缩至150行，易于维护和审查

**配置文件规则**：

| 分支 | .config | 说明 |
|------|---------|------|
| main | ❌ 禁止 | 通用配置基线 |
| 设备分支 | ✅ 必须 | 种子配置（~150行） |

**种子配置结构**：
```bash
# Target Platform
CONFIG_TARGET_rockchip=y
CONFIG_TARGET_rockchip_armv8=y
CONFIG_TARGET_rockchip_armv8_DEVICE_friendlyarm_nanopi-r5s=y

# Partition Size
CONFIG_TARGET_KERNEL_PARTSIZE=32
CONFIG_TARGET_ROOTFS_PARTSIZE=1024

# LuCI Applications
CONFIG_PACKAGE_luci-app-openclash=y
CONFIG_PACKAGE_luci-app-frpc=y
# ...

# Explicitly Disabled
# CONFIG_PACKAGE_strongswan is not set
```

### 分支管理规则

1. **main分支**: 通用内容（diy脚本、workflow、文档），禁止.config
2. **设备分支**: 必须包含种子配置，可能有设备特定diy修改
3. **同步流程**: 修改main后必须merge到所有设备分支

## 项目文件结构

```
.
├── .github/workflows/
│   ├── openwrt-builder.yml           # 主编译流程
│   └── openwrt-builder-self_host.yml # 自托管runner
├── scripts/netdata/
│   └── global_traffic.plugin         # Netdata插件
├── diy-part1.sh                      # Feeds阶段定制
├── diy-part2.sh                      # 系统配置定制
├── .config                           # 种子配置（仅设备分支）
└── CLAUDE.md
```

## 核心工作流

### openwrt-builder.yml

**关键特性**：
- **源码管理**: 基于tag checkout（默认v24.10.4），支持手动指定
- **磁盘优化**: /home/runner移至/mnt
- **编译策略**: `make -j$(nproc) || make -j1 || make -j1 V=s`
- **Release**: Tag格式`{分支名}-YYYY.MM.DD-HHMM`，每分支保留2个

**环境变量**：
```bash
REPO_URL: https://github.com/immortalwrt/immortalwrt
REPO_BRANCH: openwrt-24.10
OPENWRT_TAG: v24.10.4  # 可通过workflow_dispatch指定
```

**构建流程**：
```
1. Clone ImmortalWRT (git checkout tag)
2. 执行diy-part1.sh (feeds阶段)
3. ./scripts/feeds update && install
4. 复制种子配置 → make defconfig (展开)
5. 执行diy-part2.sh (系统配置)
6. make download && make
7. 上传Release
```

## 定制配置

### diy-part1.sh（Feeds阶段）

ImmortalWRT内置OpenClash，无需额外feeds：
```bash
# main分支（通用）
# 无需添加feeds，OpenClash已内置

# r5s-outdoor分支（特有）
echo 'src-git outdoor https://github.com/WooDragon/outdoor-backup' >>feeds.conf.default
```

### diy-part2.sh（系统配置）

**UCI Defaults配置**：
- LAN IP: 192.168.233.1
- 主机名: MCPE

**安全配置**：
- SSH端口: 65422
- 禁用密码认证，仅允许密钥
- WAN侧防火墙已开放65422

**系统优化**：
- 主题: luci-theme-argon
- TCP拥塞控制: BBR
- Nginx: client_max_body_size=1024M

## 设备架构映射

| 分支 | TARGET | 种子行数 | 备注 |
|------|--------|---------|------|
| r2s | nanopi-r2s | 153 | 双网口 |
| r5s | nanopi-r5s | 153 | 多网口 |
| r5s-outdoor | nanopi-r5s | 153 | + outdoor feeds |
| r68s | nanopi-r68s | 153 | 企业级 |
| x86 | x86_64 | 158 | + GRUB/EFI/VMDK |

## 操作规范

### 触发编译
```bash
# GitHub Web界面
Actions -> OpenWrt Builder -> Run workflow -> 选择分支

# gh CLI
gh workflow run "OpenWrt Builder" --ref r5s
gh workflow run "OpenWrt Builder" --ref r5s -f openwrt_tag=v24.10.4
```

### 修改通用配置
```bash
git checkout main
# 修改...
git add . && git commit -m "update: xxx"
git push origin main

# 同步到设备分支
for branch in r2s r5s r5s-outdoor r68s x86; do
  git checkout $branch && git merge main && git push origin $branch
done
```

### 修改设备种子配置
```bash
git checkout r5s
git merge main  # 先同步main
# 修改.config...
git add .config && git commit -m "r5s: update seed config"
git push origin r5s
```

## 故障排查

### 编译失败

**调试流程**：
1. 查看日志，找**第一个**ERROR（不是最后一个）
2. 分层分析：表层现象 → 中层错误 → 深层根因
3. 使用`make -j1 V=s`启用详细日志

**常见问题**：
1. `.config`不存在 → 设备分支必须有种子配置
2. 磁盘空间不足 → 检查/mnt分区
3. 包编译失败 → 检查种子配置中的包选择

### 分支合并冲突
- `.config冲突`：保留设备分支版本
- `CLAUDE.md冲突`：保留main版本

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

### 项目文档
- [迁移计划 issue #2](https://github.com/WooDragon/mCPE-Release/issues/2)
- [历史问题归档 issue #4](https://github.com/WooDragon/mCPE-Release/issues/4)

### 外部资源
- [ImmortalWRT](https://github.com/immortalwrt/immortalwrt)
- [P3TERX Actions-OpenWrt](https://github.com/P3TERX/Actions-OpenWrt)
- [OpenClash](https://github.com/vernesong/OpenClash)
- [OpenWrt构建系统](https://openwrt.org/docs/guide-developer/build-system/use-buildsystem)
