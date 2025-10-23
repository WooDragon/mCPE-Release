# mCPE-Release 项目Memory

## 文档维护规范 ⚠️

**本文件的维护规则**：
1. **仅在main分支修改本文件**，禁止在设备分支（r2s/r5s/r68s/x86）直接修改
2. 修改流程：
   ```bash
   # 在main分支修改CLAUDE.md
   git checkout main
   # 编辑CLAUDE.md...
   git add CLAUDE.md
   git commit -m "docs: update CLAUDE.md"
   git push origin main

   # 合并到所有设备分支（CLAUDE.md自动同步）
   for branch in r2s r5s r5s-outdoor r68s x86; do
     git checkout $branch
     git merge main
     git push origin $branch
   done
   ```
3. **冲突处理**：如果设备分支误修改了CLAUDE.md导致merge冲突，使用`git checkout main -- CLAUDE.md`保留main版本

## 项目概述
基于Lean OpenWrt源码（coolsnowwolf/lede）的个性化编译项目，使用GitHub Actions实现自动化编译和发布。
模板来源：P3TERX/Actions-OpenWrt

## 技术栈与版本

### 核心组件
- **OpenWrt源码**: [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede) master分支
- **构建平台**: GitHub Actions (ubuntu-22.04) + Self-hosted runner
- **编译工具链**: GCC/G++ (Ubuntu 22.04默认版本)
- **包管理**: opkg

### 关键依赖
- **第三方软件源**:
  - kenzok8/openwrt-packages
  - kenzok8/small
  - WooDragon/outdoor-backup（仅r5s-outdoor分支）
- **预置组件**:
  - OpenClash核心（Meta版本）
  - GeoIP/GeoSite数据库（Loyalsoldier维护）
  - Netdata流量监控插件

## 分支架构

### 分支模型
```
main (通用配置基线)
├── r2s (NanoPi R2S - ARM64)
├── r5s (NanoPi R5S - ARM64)
├── r5s-outdoor (NanoPi R5S - ARM64 + outdoor-backup插件)
├── r68s (NanoPi R68S - ARM64)
└── x86 (x86_64平台)
```

### ⚠️ .config文件铁律（严格执行）

**main分支**：
- ❌ **绝对禁止**创建或提交`.config`文件
- ✅ 只包含通用内容（diy脚本、文档、workflow）
- 原因：main分支是配置基线，不针对特定设备

**设备分支**（r2s/r5s/r5s-outdoor/r68s/x86）：
- ✅ **必须包含**`.config`文件
- ✅ workflow会强制检查`.config`存在性，不存在则立即失败
- ❌ 禁止依赖`make defconfig`生成配置
- 原因：`.config`是配置的唯一真实来源，确保构建可重复性

**历史教训**：
- 2024年6月1日：所有设备分支的`.config`被删除 → 导致4个月编译失败
- 根本问题：依赖`make defconfig`的默认配置 → 不确定、不可控
- 修复方案：恢复所有`.config` + workflow强制检查
- 详见：`docs/uwsgi-gcc-fix-journey.md`

### 分支管理规则

1. **main分支**: 仅存放通用内容（diy脚本、公共配置、文档）
   - **绝对禁止**包含`.config`文件
2. **设备分支**:
   - **必须包含**设备特定的`.config`文件
   - 可能有设备特定的diy-part2.sh修改
   - 修改前必须先`git merge main`获取最新通用内容
3. **重要**: 修改通用内容时务必merge到所有设备分支

## 项目文件结构

```
.
├── .github/workflows/
│   ├── openwrt-builder.yml           # 主编译流程（GitHub托管）
│   ├── openwrt-builder-self_host.yml # 自托管runner编译
│   └── update-checker.yml            # 源码更新检测（已禁用）
├── drivers/                          # 内核驱动目录（当前为空）
├── scripts/
│   └── netdata/
│       └── global_traffic.plugin     # Netdata流量监控插件
├── diy-part1.sh                      # Feeds更新前定制脚本
├── diy-part2.sh                      # Feeds安装后定制脚本
├── .config                           # 设备分支特有，main分支无此文件
└── README.md                         # 项目说明
```

## 核心工作流详解

### 1. openwrt-builder.yml（主要编译流程）

#### 关键特性
- **磁盘优化**: 使用hugoalh/disk-space-optimizer清理空间，/home/runner移至/mnt
- **源码管理**:
  - 默认commit ID: 36c00a4
  - 支持手动指定commit ID
  - 编译缓存基于commit ID + feeds/config哈希
- **Clash核心预安装**:
  - x86: clash-linux-amd64
  - r5s/其他ARM64: clash-linux-arm64
  - 包含GeoIP/GeoSite数据库
- **编译策略**: `make -j$(nproc) || make -j1 || make -j1 V=s`（失败自动降级单线程详细日志）
- **Release管理**:
  - Tag格式: `{分支名}-YYYY.MM.DD-HHMM`
  - 每分支仅保留最近2个release
  - 自动删除旧release及对应tag

#### 环境变量
```bash
REPO_URL: https://github.com/coolsnowwolf/lede
REPO_BRANCH: master
CURRENT_BRANCH: ${{ github.ref_name }}
OPENWRT_COMMIT_ID: 可通过workflow_dispatch指定
TZ: Asia/Shanghai
```

### 2. openwrt-builder-self_host.yml

#### 与主流程差异
- 运行在self-hosted runner
- 禁用了磁盘优化步骤（已注释）
- 固定单线程编译: `make -j1 V=s`
- Release保留策略: 保留最近3个（使用delete-older-releases action）
- 不支持Clash核心预安装

### 3. update-checker.yml
- **当前状态**: 定时触发已禁用（cron注释）
- **功能**: 检测Lean源码更新并触发repository_dispatch事件
- **缓存机制**: 使用actions/cache缓存commit hash

## 定制配置详解

### diy-part1.sh（Feeds阶段）
```bash
# 添加第三方软件源
echo 'src-git kenzo https://github.com/kenzok8/openwrt-packages' >>feeds.conf.default
echo 'src-git small https://github.com/kenzok8/small' >>feeds.conf.default
```

### diy-part2.sh（系统配置阶段）

#### UCI Defaults配置
- **LAN IP**: 192.168.233.1
- **主机名**: MCPE

#### 安全配置
- **SSH**:
  - 端口: 65422
  - 禁用密码认证（PasswordAuth off, RootPasswordAuth off）
  - 仅允许密钥认证
  - 公钥已预置在`/etc/dropbear/authorized_keys`
- **防火墙**:
  - 允许WAN侧访问65422端口（SSH远程管理）
- **Root密码**:
  - 已通过shadow文件预设（hash: $1$4Y0U89hL$FJkkEvZLUkiL4bwuwiPRJ/）

#### 系统优化
- **主题**: 将默认luci-theme-bootstrap替换为luci-theme-argon
- **Shell环境**: 添加`export TERM=xterm`到/etc/profile
- **Sysctl优化**:
  ```
  net.ipv4.tcp_congestion_control = bbr
  net.ipv4.tcp_fastopen = 3
  net.ipv4.conf.all.route_localnet = 1
  net.core.rmem_max = 4000000
  net.netfilter.nf_conntrack_max = 2000000
  net.netfilter.nf_conntrack_buckets = 250000
  （完整参数见diy-part2.sh:69-86）
  ```
- **Nginx**: client_max_body_size提升至1024M

## 设备架构映射

| 分支 | 设备型号 | CPU架构 | Clash核心 | 备注 |
|------|---------|---------|-----------|------|
| r2s  | NanoPi R2S | ARM64 | clash-linux-arm64 | 双网口软路由 |
| r5s  | NanoPi R5S | ARM64 | clash-linux-arm64 | 多网口软路由 |
| r5s-outdoor | NanoPi R5S | ARM64 | clash-linux-arm64 | r5s + outdoor-backup自动备份 |
| r68s | NanoPi R68S | ARM64 | clash-linux-arm64 | 企业级软路由 |
| x86  | x86_64通用 | x86_64 | clash-linux-amd64 | 虚拟机/物理机 |

## 编译缓存策略

### 缓存目录
```
$GITHUB_WORKSPACE/openwrt/build_dir
$GITHUB_WORKSPACE/openwrt/staging_dir
$GITHUB_WORKSPACE/openwrt/dl
```

### 缓存Key
```
${{ runner.os }}-openwrt-${{ env.OPENWRT_COMMIT_ID }}-${{ hashFiles('**/feeds.conf', '**/.config') }}
```
- 变更commit ID、feeds配置或.config会导致缓存失效
- 使用restore-keys实现部分匹配回退

## 关键操作规范

### 修改通用配置（main分支内容）
```bash
# 1. 在main分支修改
git checkout main
# 进行修改...
git add .
git commit -m "update: xxx"
git push origin main

# 2. 合并到所有设备分支
for branch in r2s r5s r5s-outdoor r68s x86; do
  git checkout $branch
  git merge main
  git push origin $branch
done
```

### 修改设备特定配置
```bash
# 1. 先合并main最新内容
git checkout r5s  # 或其他设备分支
git merge main

# 2. 进行设备特定修改
# 修改.config或diy-part2.sh...
git add .
git commit -m "r5s: update config for xxx"
git push origin r5s
```

### 触发编译
```bash
# 方式1: GitHub Web界面
# Actions -> OpenWrt Builder -> Run workflow -> 选择分支 -> (可选)填写commit ID

# 方式2: gh CLI
gh workflow run "OpenWrt Builder" --ref r5s -f openwrt_commit_id=36c00a4
```

## 扩展开发指南

### 添加自定义驱动
1. 将驱动源码放入`drivers/`目录
2. Workflow会自动移动到`openwrt/package/kernel/`
3. 在`.config`中启用对应驱动模块

### 添加自定义feeds
```bash
# 在diy-part1.sh添加
echo 'src-git myfeed https://github.com/xxx/xxx' >>feeds.conf.default
```

### 添加预置文件
```bash
# 在diy-part2.sh中创建files目录结构
mkdir -p files/etc/config/
cat > files/etc/config/myconfig <<EOF
# 配置内容
EOF
```

### 添加Netdata插件
1. 将插件脚本放入`scripts/netdata/`
2. 在diy-part2.sh中复制到固件：
```bash
mkdir -p files/usr/libexec/netdata/plugins.d/
cp -f ../scripts/netdata/*.plugin files/usr/libexec/netdata/plugins.d/
chmod +x files/usr/libexec/netdata/plugins.d/*.plugin
```

## 故障排查

### 编译失败

**系统性调试流程**：
1. **查看完整日志**：从前往后找第一个ERROR，不是最后一个
2. **分层分析**：
   ```
   表层现象（exit code 2）
     ↓ 不是根因
   中层错误（最后几行日志）
     ↓ 可能是成功的包
   深层错误（第一个ERROR）
     ↓ 真正的问题
   根本原因（为什么会失败）
   ```

**常见问题检查清单**：
1. ✅ .config文件是否存在？（设备分支必须有）
2. ✅ 检查日志中的`ERROR: package/feeds/packages/XXX failed to build`
3. ✅ 是否有包不应该被包含？（如gcc、uwsgi-python3-plugin）
4. ✅ 版本兼容性问题？（如uwsgi 2.0.20 vs Python 3.11）
5. ✅ 磁盘空间是否足够？（查看`df -h`输出）
6. ✅ 缓存是否损坏？（可禁用缓存重试）

**实战案例**：
- **案例1**：`uwsgi-python3-plugin`编译失败
  - 症状：`invalid use of incomplete typedef 'PyFrameObject'`
  - 根因：uwsgi 2.0.20不支持Python 3.11
  - 解决：升级到uwsgi 2.0.30

- **案例2**：gcc包编译失败
  - 症状：`ERROR: package/feeds/packages/gcc failed to build`
  - 根因：路由器不需要编译器，错误包含
  - 解决：禁用`CONFIG_PACKAGE_gcc`

- **案例3**：磁盘空间不足
  - 症状：`No space left on device`
  - 根因：/workdir使用了小分区
  - 解决：使用/mnt分区（软链接到/workdir）

**调试技巧**：
- 使用`grep -i "error:" build.log | head -20`找前20个错误
- 使用`make -j1 V=s`启用详细日志
- 对比成功分支和失败分支的.config差异
- 检查是否有近期的上游commit破坏了构建

### SSH无法连接
1. 确认防火墙规则已应用（端口65422）
2. 检查公钥是否正确配置在authorized_keys
3. 确认dropbear配置：`cat /etc/config/dropbear`
4. 查看系统日志：`logread | grep dropbear`

### 分支合并冲突
1. 通常冲突在.config或diy-part2.sh
2. **.config冲突**：保留设备分支版本（设备特定配置）
3. **diy-part2.sh冲突**：仔细合并设备特定修改
4. **CLAUDE.md冲突**：保留main分支版本（`git checkout main -- CLAUDE.md`）

## ⚠️ 安全注意事项与最佳实践

### 1. Git Commit Message规范（严格遵守）

**禁止cross-reference外部项目issue**：
```bash
# ❌ 错误示范（会永久污染外部项目）
git commit -m "fix: uwsgi issue coolsnowwolf/lede#7127"
git commit -m "fix: close openwrt/packages#10134"
git commit -m "fix: related to kenzok8/openwrt-packages#123"

# ✅ 正确示范（使用文字描述）
git commit -m "fix: upgrade uwsgi to 2.0.30 for Python 3.11 compatibility"
git commit -m "fix: uwsgi 2.0.20 in coolsnowwolf packages doesn't support Python 3.11"

# ✅ 正确示范（引用本项目issue）
git commit -m "fix: upgrade uwsgi to 2.0.30, see #1 for details"
git commit -m "docs: add debugging guide, close #1"
```

**规则总结**：
- ❌ 禁止：`外部组织/外部仓库#数字`（如coolsnowwolf/lede#7127）
- ❌ 禁止：完整URL指向外部issue（如https://github.com/openwrt/packages/issues/123）
- ✅ 允许：`#数字`（仅引用本项目issue，如#1）
- ✅ 允许：纯文本描述外部项目问题（如"coolsnowwolf lede的uwsgi版本过旧"）

**原因**：GitHub的cross-reference一旦创建**永久不可删除**，即使force push删除commits，引用记录仍会保留在外部项目的issue页面，造成污染。

### 2. .config包选择审查原则

**每个包都必须有明确理由**：
```bash
# ❌ 错误：路由器不需要编译器
CONFIG_PACKAGE_gcc=m

# ✅ 正确：明确禁用不需要的包
# CONFIG_PACKAGE_gcc is not set           # 编译器，路由器不需要
CONFIG_PACKAGE_libgcc=y                   # 运行时库，必需

# ✅ 正确：明确禁用可能导致编译失败的包
# CONFIG_PACKAGE_uwsgi-python3-plugin is not set  # Python插件，不需要
```

**包选择检查清单**：
1. ✅ 这个包的功能是什么？
2. ✅ 路由器运行时是否真的需要？
3. ✅ 是编译时工具还是运行时库？（gcc vs libgcc）
4. ✅ 包的体积对固件大小的影响？
5. ❌ 不要"以防万一"添加包

**历史教训**：
- gcc包（200MB+）被错误包含 → 编译失败4个月
- uwsgi-python3-plugin不需要却被默认启用 → Python 3.11 API不兼容
- 最小化原则：只包含运行时必需组件

### 3. 版本依赖管理原则

**优先使用官方维护的最新版本**：
```bash
# ❌ 错误：coolsnowwolf packages中的uwsgi 2.0.20不支持Python 3.11
# 解决方案1：试图禁用Python插件 → 失败
# 解决方案2：试图patch旧版本 → 维护成本高

# ✅ 正确：升级到openwrt/packages的uwsgi 2.0.30
# 在diy-part2.sh中自动从官方拉取最新版本
# 优势：官方持续维护，无需自己维护patch
```

**版本选择原则**：
1. ✅ 升级依赖 > 维护patch
2. ✅ 官方方案 > 自己hack
3. ✅ 关注上游API破坏性变更（如Python 3.11）
4. ❌ 不固定过时的commit ID

### 4. PyPI包的特殊性（重要）

**uwsgi是PyPI包，构建流程与传统OpenWrt包不同**：
```
传统包：
  - 源码在feeds/packages/xxx/src/
  - 修改src/目录的文件会生效

PyPI包（如uwsgi）：
  - 源码从PyPI下载tarball
  - feeds/packages/xxx/src/目录**不被使用**
  - 要修改源码必须：
    a) 创建patch文件（feeds/packages/xxx/patches/）
    b) 修改Makefile添加Build/Prepare hook
    c) 升级包版本（推荐）
```

**数据流验证**：
```
feeds/packages/net/uwsgi/src/buildconf/openwrt.ini
  ↓ (不被使用！)
nowhere

PyPI tarball: uwsgi-2.0.20.tar.gz
  ↓ (解压)
build_dir/pypi/uwsgi-2.0.20/buildconf/openwrt.ini
  ↓ (实际使用)
编译时
```

### 5. 调试方法论

**分层分析**（找第一个ERROR，不是最后一个）：
```
表层现象：exit code 2
  ↓ 顶层make报错，不是根因
中层错误：iptables编译日志
  ↓ 这是成功的包，掩盖真正错误
深层错误：ERROR: package/feeds/packages/gcc failed to build
  ↓ 找到了！
根本原因：CONFIG_PACKAGE_gcc=m（不应该选择）
```

**多层问题需要多次迭代**：
```
第一次修复 → 验证 → 发现新问题
第二次修复 → 验证 → 发现新问题
第三次修复 → 验证 → 完全成功
```

**不要假设只有一个问题**：
- ✅ 修复一个问题后立即重新验证
- ✅ 查看完整日志，从前往后找第一个ERROR
- ✅ 系统性检查所有分支
- ❌ 不要一次修复多个问题后再验证

### 6. 密钥与密码管理

1. **SSH密钥管理**:
   - diy-part2.sh中的SSH公钥需定期轮换
   - GITHUB_TOKEN使用仓库secrets管理
2. **密码安全**:
   - Root密码hash已固化，建议首次登录后修改
3. **网络暴露**:
   - WAN侧SSH端口65422已开放，务必使用强密钥
   - 考虑添加fail2ban或IP白名单

## 参考资源

### 项目文档
- [uwsgi + gcc编译问题完整修复记录](docs/uwsgi-gcc-fix-journey.md) - 详细记录三层嵌套问题的调试过程

### 外部资源
- [Lean OpenWrt](https://github.com/coolsnowwolf/lede)
- [P3TERX Actions-OpenWrt](https://github.com/P3TERX/Actions-OpenWrt)
- [OpenClash](https://github.com/vernesong/OpenClash)
- [kenzok8软件源](https://github.com/kenzok8/openwrt-packages)
- [OpenWrt构建系统文档](https://openwrt.org/docs/guide-developer/build-system/use-buildsystem)
- [uwsgi构建系统文档](https://uwsgi-docs.readthedocs.io/en/latest/BuildSystem.html)
