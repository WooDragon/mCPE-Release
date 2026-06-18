# Rockchip 设备首启自动扩盘

Rockchip 设备（r2s/r3s/r5s/r5s-outdoor/r68s）首次启动时，自动将 overlay（rootfs_data，f2fs）分区扩展到填满整张 SD/eMMC，无需人工干预。x86 不涉及。

---

## 为何要扩盘

固件镜像由编译期 `CONFIG_TARGET_ROOTFS_PARTSIZE=1024MB` 决定分区布局，烧写到大容量卡后剩余空间默认闲置。ImmortalWRT 使用 squashfs + overlay 双层布局：squashfs 是只读根文件系统，overlay（rootfs_data 分区，f2fs 格式）承载所有可写内容（包安装、配置修改）。

**真正要扩的是 overlay 的 f2fs 分区**，不是 squashfs 本身（只读，扩了也没用），也不是 ext4 root（squashfs 布局无此分区）。

---

## 核心设计决策

### 为何用 preinit 阶段而非 init.d

这是本方案与传统方案的根本分歧：

| | preinit 钩子（本方案） | init.d 脚本（传统方案） |
|---|---|---|
| overlay 挂载状态 | **未挂载**，分区不 busy | 已挂载，分区占用中 |
| offline resize | 直接可做，无风险 | 需 loop 套娃，有损坏风险 |
| 重启次数 | **零额外重启** | 需重启 1-2 次 |
| 实现复杂度 | 低（线性流程） | 高（需处理"已挂载时重排"逻辑） |

preinit 钩子命名为 `/lib/preinit/79_expand_rootfs`，排在 `80_mount_root` 之前执行——此时 overlay 未挂载、分区不 busy，可以直接做 offline resize，**实现真正的零额外重启**。

### 运行期 fail-soft vs 构建期 fail-loud 分层

preinit 脚本的所有失败路径一律 `return 0`，不用 `exit`。

**原因是物理约束**：preinit 钩子被主 init 进程 source（不是 fork）进来，`exit` 会终止主进程、杀死整个启动链，设备变砖。扩容是辅助功能，失败必须让设备以原始大小正常启动——这是"never break userspace"铁律在固件层的体现。

与之相反，构建期 diy 脚本（`diy-part1.sh`、`diy-part2.sh`）保持 `set -euo pipefail` + fail-loud——构建失败早暴露比静默出废固件好。两套语义在职责边界处分层，互不干扰。

### 为何选 per-target base-files 落位

脚本放在 `target/linux/rockchip/armv8/base-files/lib/preinit/79_expand_rootfs`，利用 OpenWrt 原生 per-target 文件覆盖机制：编译 rockchip 目标时，该路径下的文件自动打包进固件；编译 x86 时，此路径不参与，脚本天然不存在于 x86 固件。

这是零条件分支的方案——不需要在 diy 脚本里写 `if [ "$DEVICE" = "r2s" ]`，也不需要在 common.config 里加 x86 排除项，平台隔离由构建系统本身完成。

### 工具链选择

使用 util-linux 套件的 `sfdisk` + `partx`，不用 `parted` 或 `gdisk`。

`parted`/`gdisk` 是桌面级工具，体积大、交互式 API 设计对脚本不友好。`sfdisk` 专为脚本设计，`echo ", +" | sfdisk ...` 单行即可扩末分区到磁盘末尾；调整 GPT 时自动重定位备份 GPT 头（GPT 有两份元数据，主头在开头，备份头在磁盘末尾——扩盘后末尾位置变了，sfdisk 自动处理，gptfdisk 需手工修复）。

### 依赖包名陷阱

OpenWrt 包符号与直觉名称不一致，写错会被 `make defconfig` 静默丢弃、功能空转：

| 需求 | 错误写法 | 正确符号 |
|------|----------|----------|
| resize.f2fs（扩容工具） | `CONFIG_PACKAGE_f2fs-tools` | `CONFIG_PACKAGE_f2fsck` |
| partx（刷新分区表） | `CONFIG_PACKAGE_partx` | `CONFIG_PACKAGE_partx-utils` |
| sfdisk（调整分区） | — | `CONFIG_PACKAGE_sfdisk` |

特别说明 f2fs-tools：上游拆成多个包，`f2fs-tools` 主包只含 mkfs.f2fs，**`resize.f2fs` 和 `fsck.f2fs` 在 `f2fsck` 包中**。三包均需声明在对应的 `devices/<dev>/seed.config`（仅 rockchip 设备）。

---

## 扩容执行序列

preinit 钩子单次线性执行，无重启：

```
1. 探测块设备节点与分区号（不写死 mmcblk0/1，兼容 mmcblk/nvme/sd* 命名）
2. echo ", +" | sfdisk --no-reread --force -N $PART_NUM $DEV
   └─ 扩末分区吃满尾部空间
      --no-reread：避免触发内核 BLKRRPART，绕过"设备已挂载"的 busy 拦截
      --force：跳过对已挂载磁盘的交互式确认
3. partx -u -n $PART_NUM $DEV
   └─ 只刷 overlay 单分区的内核视图
      -n $PART_NUM：精确指定分区号，避开已挂载 squashfs 分区的 Device-or-resource-busy
4. fsck.f2fs -f $OVERLAY_DEV
   └─ resize 前强制 fsck（resize.f2fs 要求文件系统一致）
5. resize.f2fs $OVERLAY_DEV
   └─ offline 扩容到新分区大小
6. return 0，交还控制权给 mount_root（80_mount_root）
```

### 设备节点探测

块设备命名规则在 OpenWrt 中不统一：

- `mmcblk*` / `nvme*n*`：分区号带 `p` 前缀（如 `mmcblk0p2`）
- `sd*`：分区号直接拼接（如 `sda2`）

脚本通过 `/sys/class/block` 遍历推导当前根设备，不硬编码 `mmcblk0`，保证 eMMC 和 SD 卡均正确工作。

### 版本门禁

resize.f2fs 1.14.0 有 overprovisioning 计算 bug，可能在 resize 后产生损坏的文件系统。脚本检查 `resize.f2fs -V` 版本，低于 1.15.0 则跳过扩容（`return 0`，fail-soft）。ImmortalWRT v24.10.6 的 f2fsck 包为 1.16.0，正常路径不会触发此门禁；门禁是防御性保护，应对未来包版本回退。

### 幂等保护

若分区已占满可用空间（`sfdisk` 输出表明无可扩展空间），脚本直接 `return 0` 跳过，不报错。保证重复启动不产生副作用。

---

## 与 init.d 方案的取舍对比

| 维度 | preinit（本方案） | init.d |
|------|-----------------|--------|
| overlay 挂载时机 | 未挂载 | 已挂载 |
| offline resize | 直接支持 | 需 umount 或 loop 设备套娃 |
| 额外重启次数 | **0** | 1-2 次 |
| 实现复杂度 | 低 | 高（需处理 busy 分区） |
| 数据损坏风险 | 低（offline 操作） | 中（在线操作有风险） |
| 失败影响 | fail-soft，正常启动 | 若 umount 失败可能卡启动 |

init.d 方案的核心问题：overlay 已挂载时，`resize.f2fs` 要求 offline——要么强制 umount（有进程在用 overlay 时会失败），要么走 loop 设备间接 resize（复杂且存在竞态）。preinit 天然在挂载前，规避了这个不可能三角。

---

## 验证

**本地 BDD**：`tests/bdd-matrix-build.sh` 新增 B32 起断言，守护：

- 脚本存在于 `target/linux/rockchip/armv8/base-files/lib/preinit/79_expand_rootfs`
- 三个依赖包符号（`f2fsck`/`sfdisk`/`partx-utils`）声明在全部 rockchip 设备 seed.config
- x86 `seed.config` 不含上述包符号

**CI 冒烟**：rockchip 产物固件包含脚本与三包二进制；x86 固件不含。

**真机验证**：首启单次扩容到位（`df -h` 看 overlay 可用空间）；模拟 resize.f2fs 失败（版本门禁）时设备正常启动、overlay 为原始大小。
