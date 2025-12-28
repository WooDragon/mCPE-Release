# 商用固件上游源迁移计划：coolsnowwolf/lede → ImmortalWRT

> 创建日期：2025-12-28
> 状态：已分析完成，待执行

## 迁移目标
- **源仓库**：`https://github.com/immortalwrt/immortalwrt`
- **版本**：24.10（kernel 6.6）
- **策略**：仅修改workflow的REPO_URL，不fork上游源码

---

## 一、问题诊断

### 1.1 当前架构的致命缺陷

```
coolsnowwolf/lede (commit锁定: 36c00a4)
           ↓
    feeds.conf.default
           ↓
┌─────────────────────────────────────┐
│  kenzok8/openwrt-packages (master)  │  ← 每日更新，无版本锁定
│  kenzok8/small (master)             │  ← 每日更新，无版本锁定
└─────────────────────────────────────┘
           ↓
    版本不匹配 → 编译失败
```

**根因**：coolsnowwolf/lede依赖的第三方feeds无版本锁定机制，Python/Rust版本漂移导致编译失败。

### 1.2 ImmortalWRT解决方案

```
immortalwrt/immortalwrt (指定tag: v24.10.4)
           ↓
    内置feeds（packages, luci, routing等）
           ↓
┌─────────────────────────────────────┐
│  自建软件源与固件版本绑定            │  ← 版本一致性保证
│  https://downloads.immortalwrt.org  │
└─────────────────────────────────────┘
           ↓
    稳定编译
```

---

## 二、候选上游源深度对比

### 2.1 核心维度对比表

| 维度 | ImmortalWRT | Lienol | Lean(QWRT+) | iStoreOS | KWRT |
|------|-------------|--------|-------------|----------|------|
| **软件源架构** | 自建+版本匹配 | 官方源 | 官方源 | 自建 | 自建 |
| **Feeds稳定性** | ★★★★★ | ★★☆☆☆ | ★★☆☆☆ | ★★★★☆ | ★★★☆☆ |
| **版本跟进** | 24.10 (最新) | 24.10 | 24.10 | 22.03 (落后) | 23.05 (落后) |
| **内核版本** | 6.6 | 6.6 | 6.6 | 5.15 | 5.15 |
| **OpenClash支持** | 官方收录 | 需自添加 | 需自添加 | 官方收录 | 官方收录 |
| **kmod在线安装** | ✅ | ❌ | ❌ | ✅ | ✅ |
| **在线编译器** | ✅ | ❌ | ❌ | ❌ | ✅(限额) |
| **商用友好度** | 完全开源 | 完全开源 | 闭源收费 | 部分闭源 | 付费限制 |
| **社区活跃度** | 高(TG群) | 中 | 中 | 高 | 中 |

### 2.2 关键差异分析

#### ImmortalWRT的核心优势

1. **自建软件源与固件版本绑定**
   - 固件版本: 24.10
   - 软件源: https://downloads.immortalwrt.org/releases/24.10/packages/
   - 保证：软件源中的包与固件100%兼容

2. **OpenClash官方收录**
   - 位于: `packages/net/openclash`
   - 无需添加第三方feeds
   - 版本与系统同步更新

3. **kmod模块在线安装**
   - 解决内核模块版本匹配问题
   - 无需重新编译整个固件

4. **活跃的开发社区**
   - GitHub Issues响应快
   - Telegram群组实时支持
   - 开发者1715173329持续维护

#### 其他源的致命短板

- **Lienol/Lean**: 使用官方软件源 → **feeds锁定问题无法解决**
- **iStoreOS**: 版本22.03太旧 → **内核5.15不适合长期维护**
- **KWRT**: 版本23.05 → **落后一个大版本，定制收费**

---

## 三、完整包兼容性分析

### 3.1 用户指定需求包（全部可用）

| 包 | 仓库位置 | 版本 | 状态 |
|---|---------|------|------|
| luci-app-openclash | luci/ | 0.47.028 | ✅ |
| frpc | net/frp | 0.65.0 | ✅ |
| luci-app-frpc | luci/ | 最新 | ✅ |
| docker/dockerd | packages/ | 27.3.1 | ✅ |
| docker-compose | packages/ | 2.40.3 | ✅ |
| netdata | admin/netdata | 最新 | ✅ |
| luci-app-netdata | luci/ | 最新 | ✅ |
| ttyd | utils/ttyd | 最新 | ✅ |
| luci-app-ttyd | luci/ | 最新 | ✅ |
| vnstat | net/vnstat | 最新 | ✅ |
| luci-app-vnstat2 | luci/ | 最新 | ✅ |
| nginx | net/nginx | 最新 | ✅ |

### 3.2 最终迁移方案（用户确认）

**用户需求确认**：
- ✅ 不需要turboacc和passwall，使用原生flow offloading
- ✅ 不需要pushbot、wrtbwmon、filetransfer
- ✅ 核心需求：OpenClash + frpc + Docker + Netdata + ttyd + vnstat + nginx

**必须删除的包**（共15+个）：
```bash
# 科学上网（全部删除，只保留OpenClash）
CONFIG_PACKAGE_luci-app-bypass=y           # 删除
CONFIG_PACKAGE_luci-app-passwall=y         # 删除（用户不需要）
CONFIG_PACKAGE_luci-app-passwall2=y        # 删除
CONFIG_PACKAGE_luci-app-ssr-plus=y         # 删除
CONFIG_PACKAGE_luci-app-vssr=y             # 删除

# 网络加速（使用原生替代）
CONFIG_PACKAGE_luci-app-turboacc=y         # 删除
CONFIG_PACKAGE_kmod-shortcut-fe=y          # 删除
CONFIG_PACKAGE_kmod-shortcut-fe-cm=y       # 删除

# 不需要的功能包
CONFIG_PACKAGE_luci-app-pushbot=y          # 删除
CONFIG_PACKAGE_luci-app-wrtbwmon=y         # 删除
CONFIG_PACKAGE_luci-app-filetransfer=y     # 删除
```

**保留的核心包**：
```bash
# 科学上网（仅OpenClash）
CONFIG_PACKAGE_luci-app-openclash=y

# 用户指定需求
CONFIG_PACKAGE_luci-app-frpc=y
CONFIG_PACKAGE_dockerd=y
CONFIG_PACKAGE_docker-compose=y
CONFIG_PACKAGE_luci-app-netdata=y
CONFIG_PACKAGE_luci-app-ttyd=y
CONFIG_PACKAGE_luci-app-vnstat2=y
CONFIG_PACKAGE_nginx=y
CONFIG_PACKAGE_luci-app-mwan3=y

# 网络加速（原生实现）
CONFIG_PACKAGE_kmod-nft-offload=y
CONFIG_PACKAGE_kmod-tcp-bbr=y
```

---

## 四、详细迁移步骤

### 4.1 文件修改清单

| 文件 | 修改类型 | 说明 |
|------|---------|------|
| `.github/workflows/openwrt-builder.yml` | 修改 | 更换REPO_URL和分支 |
| `diy-part1.sh` | 简化 | 移除kenzok8 feeds（已内置） |
| `diy-part2.sh` | 微调 | 检查包名差异 |
| `.config`（各设备分支） | 重新生成 | 使用ImmortalWRT config generator |

### 4.2 openwrt-builder.yml 修改

```yaml
# 当前配置
env:
  REPO_URL: https://github.com/coolsnowwolf/lede
  REPO_BRANCH: master
  OPENWRT_COMMIT_ID: 36c00a4

# 修改为
env:
  REPO_URL: https://github.com/immortalwrt/immortalwrt
  REPO_BRANCH: openwrt-24.10
  OPENWRT_TAG: v24.10.4  # 使用tag代替commit，更稳定
```

**克隆步骤调整**：
```yaml
# 当前
- name: Clone source code
  run: |
    git clone $REPO_URL -b $REPO_BRANCH openwrt
    cd openwrt && git checkout ${{ env.OPENWRT_COMMIT_ID }}

# 修改为（使用tag）
- name: Clone source code
  run: |
    git clone $REPO_URL -b $REPO_BRANCH openwrt --depth=1
    cd openwrt && git checkout tags/${{ env.OPENWRT_TAG }}
```

### 4.3 diy-part1.sh 简化

```bash
# 删除这两行（ImmortalWRT已内置OpenClash）
- echo 'src-git kenzo https://github.com/kenzok8/openwrt-packages' >>feeds.conf.default
- echo 'src-git small https://github.com/kenzok8/small' >>feeds.conf.default

# 保留驱动迁移逻辑（如有）
```

### 4.4 diy-part2.sh 检查项

| 配置项 | coolsnowwolf/lede | ImmortalWRT | 需要调整 |
|--------|-------------------|-------------|---------|
| UCI defaults路径 | `package/base-files/files/etc/uci-defaults/` | 相同 | ❌ |
| dropbear配置路径 | `package/network/services/dropbear/` | 相同 | ❌ |
| sysctl.conf路径 | `package/base-files/files/etc/sysctl.conf` | 相同 | ❌ |
| nginx配置路径 | 需验证 | 需验证 | ⚠️ |
| Netdata插件路径 | `/usr/libexec/netdata/plugins.d/` | 相同 | ❌ |

**uwsgi升级逻辑**：可以删除（ImmortalWRT使用官方packages，已是最新版本）

### 4.5 .config 迁移策略

**方式一**：使用ImmortalWRT Firmware Selector
1. 访问 https://firmware-selector.immortalwrt.org/
2. 选择设备型号（如NanoPi R2S）
3. 选择需要的包
4. 下载生成的.config

**方式二**：手动转换现有.config
```bash
# 1. 克隆ImmortalWRT
git clone https://github.com/immortalwrt/immortalwrt -b openwrt-24.10 --depth=1

# 2. 复制旧.config
cp old/.config immortalwrt/.config

# 3. 运行make defconfig修复不兼容项
cd immortalwrt && make defconfig

# 4. 验证并手动调整
make menuconfig
```

### 4.6 OpenClash核心预安装（保持现有逻辑）

当前workflow中的OpenClash核心预安装逻辑无需修改，因为：
- Clash核心来自vernesong/OpenClash仓库（与上游无关）
- GeoIP/GeoSite来自Loyalsoldier仓库（与上游无关）
- 预安装路径`/etc/openclash/core/`是OpenClash标准路径

---

## 五、迁移执行计划

### Phase 1: POC验证（建议先做）
1. 选择一个设备分支（如r2s）
2. 在本地/临时workflow中测试ImmortalWRT编译
3. 验证所有必需包能正常编译
4. 对比固件大小和功能

### Phase 2: 正式迁移
1. 修改`openwrt-builder.yml`中的REPO_URL
2. 简化`diy-part1.sh`（移除kenzok8 feeds）
3. 检查并微调`diy-part2.sh`
4. 为每个设备分支生成新的`.config`

### Phase 3: 验证与回归
1. 触发所有设备分支编译
2. 功能测试：网络、OpenClash、SSH、Docker、Netdata
3. 性能测试：带宽、延迟
4. 稳定性测试：72小时运行

---

## 六、关键文件路径

需要修改的文件：
- `.github/workflows/openwrt-builder.yml`
- `diy-part1.sh`
- `diy-part2.sh`（可能需要微调）
- 各设备分支的`.config`文件

参考文档：
- ImmortalWRT官方文档：https://immortalwrt.org/docs/
- 软件包目录：https://downloads.immortalwrt.org/releases/24.10.4/packages/
- Firmware Selector：https://firmware-selector.immortalwrt.org/
