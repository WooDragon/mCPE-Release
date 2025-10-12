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
   for branch in r2s r5s r68s x86; do
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
├── r68s (NanoPi R68S - ARM64)
└── x86 (x86_64平台)
```

### 分支管理规则
1. **main分支**: 仅存放通用内容（diy脚本、公共配置、文档）
2. **设备分支**:
   - 包含设备特定的`.config`文件
   - 可能有设备特定的diy-part2.sh修改
   - 修改前必须先merge main分支最新内容
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
for branch in r2s r5s r68s x86; do
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
1. 检查GitHub Actions日志中的错误信息
2. 查看是否有package下载失败（dl目录小文件会被清理）
3. 尝试指定更早的稳定commit ID
4. 检查缓存是否损坏（可禁用缓存重试）

### SSH无法连接
1. 确认防火墙规则已应用（端口65422）
2. 检查公钥是否正确配置在authorized_keys
3. 确认dropbear配置：`cat /etc/config/dropbear`

### 分支合并冲突
1. 通常冲突在.config或diy-part2.sh
2. .config冲突：保留设备分支版本
3. diy-part2.sh冲突：仔细合并设备特定修改

## 安全注意事项

1. **密钥管理**:
   - diy-part2.sh中的SSH公钥需定期轮换
   - GITHUB_TOKEN使用仓库secrets管理
2. **密码安全**:
   - Root密码hash已固化，建议首次登录后修改
3. **网络暴露**:
   - WAN侧SSH端口已开放，务必使用强密钥
   - 考虑添加fail2ban或IP白名单

## 参考资源

- [Lean OpenWrt](https://github.com/coolsnowwolf/lede)
- [P3TERX Actions-OpenWrt](https://github.com/P3TERX/Actions-OpenWrt)
- [OpenClash](https://github.com/vernesong/OpenClash)
- [kenzok8软件源](https://github.com/kenzok8/openwrt-packages)
