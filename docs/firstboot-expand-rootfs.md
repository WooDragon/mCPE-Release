# Rockchip 设备首启自动扩盘（v2：MBR + loop-backed f2fs）

Rockchip 设备（r2s/r3s/r5s/r5s-outdoor/r68s）首次启动时，自动将 overlay（f2fs）扩展到填满整张 SD/eMMC，无需人工干预。x86 不涉及。

---

## 为何要扩盘

固件镜像由编译期分区布局决定体积，烧写到大容量卡后剩余空间默认闲置。ImmortalWRT 使用 squashfs + overlay 双层布局：squashfs 是只读根文件系统，overlay（rootfs_data，f2fs 格式）承载所有可写内容（包安装、配置修改）。

**真正要扩的是 overlay 的 f2fs 区域**，不是 squashfs（只读，扩了无意义），也不是独立分区（见下文真机布局）。

---

## 真机磁盘布局（v1 的根本误判）

Rockchip 设备使用 **MBR（dos）分区表，不是 GPT**。布局如下：

```
MBR 磁盘
├── p1: boot（固件头、uboot）
└── p2: 组合分区（squashfs + f2fs overlay，同一物理分区）
          ├── [offset 0]   squashfs（只读根，字节数 = bytes_used）
          └── [offset F2OFF] f2fs overlay（rootfs_data）
                             F2OFF = bytes_used 向上取 64 KiB 对齐
```

**关键点**：f2fs overlay 没有独立分区，它追加在 p2 内部 squashfs 之后。两者共用同一个 `/dev/mmcblkXp2`，在分区表中看不出 overlay 的存在。

### fstools 运行期如何建 overlay loop

fstools 在 `80_mount_root` 阶段做如下操作（来源：fstools `libfstools/rootdisk.c`，`ROOTDEV_OVERLAY_ALIGN = 64 KiB`）：

```
offset = align_up(squashfs_bytes_used, 65536)  // 与本脚本算法完全一致
losetup -o <offset> /dev/mmcblkXp2             // lo_sizelimit 从不设置
// sizelimit=0 意味着 loop 覆盖从 offset 到分区末尾的全部区域
```

`sizelimit=0` 的后果是：**只要我们把 p2 扩到磁盘末尾、再把 f2fs resize 到填满 p2 内 f2fs 区域，下次 fstools 建 loop 时自动得到满尺寸 overlay**——无需任何额外配置。fstools 自身从不做 f2fs resize，resize 必须由我们在 fstools 运行之前完成。

---

## 安全不变量：f2fs offline-only resize

`resize.f2fs` 是 offline-only 工具，**拒绝对已挂载的 f2fs 执行**。若强行对活挂载的 f2fs resize：内核持有 in-memory 元数据（不重读磁盘 superblock），checkpoint/重启时以旧几何写回，覆盖 resize 后的新布局 → 随机损坏。这是内核级硬约束，不是工具保守策略。

因此，**f2fs resize 必须在 overlay 挂载前、对未挂载的 f2fs 视图做**。

本钩子命名为 `79_expand_rootfs`，排在 `80_mount_root` 之前（79 < 80）：
- 此刻 overlay loop 尚不存在（`/dev/loop0` 不存在）
- f2fs 在内核中无任何内存态
- 通过 `losetup -o <offset>` 自行构造未挂载 f2fs 视图，在其上执行 offline resize

---

## 核心设计决策

### preinit 钩子 vs init.d

| 维度 | preinit 钩子（本方案） | init.d 脚本 |
|---|---|---|
| overlay 挂载状态 | **未挂载**，可 offline resize | 已挂载，resize 有损坏风险 |
| 额外重启次数 | 1（仅 S1→S2，内核重读 MBR 必须） | 1-2 次 |
| 实现复杂度 | 低（线性三态状态机） | 高（需处理 busy 分区） |
| 数据安全 | offline resize，无竞态 | 在线操作有竞态窗口 |
| 失败影响 | fail-soft，正常启动 | umount 失败可能卡启动 |

### 三态状态机设计原则

**无持久标记**，完全由磁盘现实驱动，天然幂等、重入、断电安全。无需在 overlay 上写标记文件（overlay 此刻未挂载），无需维护状态变量跨启动持久化。

### fail-soft 铁律

preinit 钩子被主 init 进程 source 进来（非 fork）。任何非零退出会终止主进程、杀死整个启动链，设备变砖。**所有失败/工具缺失/校验不过路径一律 `return 0`**，只写日志，不阻断启动。扩盘是辅助功能，失败必须让设备以原始大小正常启动——这是 never-break-boot 原则在固件层的体现。

例外：若已通过 `losetup` 拿到 loop 设备句柄，任何退出路径必须先执行 `losetup -d`，否则僵尸 loop 占住 p2 会导致 `80_mount_root` 遭遇 EBUSY，fail-soft 退化为 fail-hard（砖）。

### per-target base-files 落位

脚本放在 `target/linux/rockchip/armv8/base-files/lib/preinit/79_expand_rootfs`，利用 OpenWrt 原生 per-target 文件覆盖机制：编译 rockchip 目标时自动打包；编译 x86 时此路径不参与，脚本天然不进 x86 固件。零条件分支，平台隔离由构建系统完成。

---

## 三态状态机详解

### 探测阶段（所有状态共用前置步骤）

```
1. 工具齐全性检查: losetup / sfdisk / fsck.f2fs / resize.f2fs / hexdump
   └─ 任何缺失 → return 0（工具未打包，正常跳过）

2. 定位组合分区 p2
   └─ block info | grep TYPE="squashfs"
   └─ 理由: preinit 阶段 /rom 未挂载，p2 头部是 squashfs → 被识别为 squashfs 类型
            overlay loop 此刻不存在，不可能找到 f2fs 或 /dev/loop0（v1 死穴）
   └─ 不写死 mmcblkN：从 sysfs /sys/class/block/<name>/partition 反推磁盘节点 + 分区号

3. 读取分区几何
   └─ p2 start/size（扇区）← sfdisk -d
   └─ 磁盘总扇区 ← /sys/class/block/<diskname>/size

4. 计算 f2fs 偏移 F2OFF
   └─ squashfs bytes_used: dd 从 p2 设备偏移 40 读 8 字节小端整数（squashfs superblock 规范）
   └─ F2OFF = ceil(bytes_used / 65536) × 65536
   └─ 与 fstools libfstools/rootdisk.c 的算法完全一致

5. f2fs magic 校验（偏移防护）
   └─ 读 p2[F2OFF + 1024] 处 4 字节 → 验证等于 0xF2F52010（F2FS_MAGIC）
   └─ 不符 → return 0（布局非预期，放行启动，不动磁盘）
   └─ 理由: 偏移算错一扇区就会让 resize 摧毁数据，magic 校验是最后一道保险
```

### S1：磁盘末尾有未分配空间

**判据**：`disk_total_sectors − (p2_start + p2_size) ≥ FREE_THRESHOLD（2048 扇区 ≈ 1 MiB）`

**动作**：

```
echo ', +' | sfdisk --no-reread --force -N <partnum> <disk>
└─ 把 p2 扩展到磁盘末尾，保持起始扇区不变
   --no-reread: 内核不立即刷新（刷新路径在此刻是 EBUSY）
   --force: 跳过对已挂载磁盘的交互式确认

重新读 p2 size（sfdisk -d）:
  若实际增大 → sync + reboot -f  ← 必须：内核重读 MBR 后才能看到新 p2 尺寸
  若未增大   → return 0，不 reboot（防 bootloop：没有持久标记，不能区分"已做过"）
```

**为何必须 reboot**：MBR 分区表改变后，内核持有的分区表缓存是旧值。唯有重启让内核重新解析磁盘 MBR，p2 的新尺寸才对 sysfs 和 block layer 可见。这依赖"内核启动时重读分区表"这一坚实语义，不依赖任何在线刷新技巧。

### S2：p2 已填满磁盘，但 f2fs 小于可用区域

**判据**：`(p2_size × 512 − F2OFF) − f2fs_current_bytes ≥ FREE_THRESHOLD × 512`

f2fs 当前字节数 = `block_count`（f2fs superblock 偏移 1060，8 字节小端）× 4096。

**动作**（`resize_overlay` 函数，统一清理出口）：

```
losetup -f --show -o <F2OFF> <p2dev>
└─ sizelimit=0（默认）→ loop 覆盖 F2OFF 到 p2 末尾
└─ 此为未挂载视图，overlay 的正式 loop 由 80_mount_root 在后续建立

任何退出前都先: losetup -d $LOOP（防僵尸 loop → EBUSY → 砖）

block info $LOOP | grep TYPE="f2fs"  → 不符则 losetup -d + return 0
fsck.f2fs -f $LOOP                    → 失败则 losetup -d + return 0
resize.f2fs $LOOP                     → 填满设备尺寸
                                         失败则 losetup -d + return 0
成功: losetup -d $LOOP → return 0
```

完成后，`80_mount_root` 以相同偏移建 loop，fstools 自动得到满尺寸 overlay。

### S3：f2fs 已填满可用区域

**判据**：差额 < FREE_THRESHOLD，即 `(AVAIL_BYTES − F2FS_BYTES) / SECTOR < FREE_THRESHOLD`

**动作**：直接 `return 0`，稳态，无操作。

### 完整启动时序

```
Boot1: preinit → 探测 → S1（盘尾有空间）→ sfdisk 扩 p2 → 实变 → reboot -f
Boot2: 内核重读 MBR → p2 已填满磁盘
       preinit → 探测 → S2（f2fs 小）→ offline resize f2fs → return 0
       80_mount_root 建满尺寸 loop → overlay 全量可用
Boot3+: preinit → 探测 → S3（稳态）→ return 0
```

精确 **1 次强制重启**，仅发生在 S1→S2 边界（内核重读 MBR 必须）。之后每次启动直通 S3。

---

## 工具链与依赖包

### 为何需要 util-linux losetup（不用 busybox losetup）

busybox losetup 默认不编译，且不支持 `-o offset` 参数。`-o offset` 是构造偏移 loop 视图的必要参数——没有它无法单独对 f2fs 区域操作。故必须声明 `CONFIG_PACKAGE_losetup`（util-linux 套件）。

### 为何 sfdisk 不用 parted / gdisk

`parted`/`gdisk` 是桌面级工具，体积大，交互式 API 对脚本不友好。`sfdisk` 专为脚本设计，`echo ', +' | sfdisk ...` 单行即可扩末分区到磁盘末尾。v2 使用 MBR，sfdisk 对 MBR 的操作更直接可靠。

### 为何移除 partx-utils

v1 用 `partx -u` 在线刷新内核分区表视图。v2 使用重启（`reboot -f`）重读 MBR，partx 在线刷新路径已删除，`partx-utils` 是死重量，依照项目"无 just-in-case 包"原则移除。

### 整数读取用 hexdump 而非 od

busybox `od` 默认不编译；busybox `hexdump` 可用。`read_le` 函数：`dd` 逐字节提取 → `hexdump -v -e '1/1 "%u\n"'` 输出十进制字节序列 → `awk` 按位权累加（busybox awk 无 `strtonum`，用乘法代替）。

### 依赖包汇总

声明在 5 个 rockchip 设备的 `devices/{r2s,r3s,r5s,r5s-outdoor,r68s}/seed.config`：

| 依赖 | 包符号 | 提供工具 |
|------|--------|----------|
| f2fs 工具 | `CONFIG_PACKAGE_f2fsck` | `fsck.f2fs` + `resize.f2fs`（f2fs-tools 1.16.0） |
| 分区扩展 | `CONFIG_PACKAGE_sfdisk` | `sfdisk`（util-linux） |
| 偏移 loop | `CONFIG_PACKAGE_losetup` | `losetup`（util-linux，busybox 无 `-o offset`） |

x86 `seed.config` 不含上述符号（无扩盘需求）。

> **旧包 `partx-utils` 已移除**：v2 走 reboot 重读 MBR，不再需要 partx 在线刷新，v2 seed.config 中不应出现此符号。

---

## 落位逻辑（diy-part2.sh）

```bash
# diy-part2.sh ~L160
MCPE_SRC_ROOT="${MCPE_REPO_ROOT:-${GITHUB_WORKSPACE:-}}"
if [ -z "$MCPE_SRC_ROOT" ]; then
  echo "ERROR [diy]: 扩盘钩子落位 — MCPE_REPO_ROOT/GITHUB_WORKSPACE 均未设置" >&2
  exit 1
fi
mkdir -p target/linux/rockchip/armv8/base-files/lib/preinit/
cp "${MCPE_SRC_ROOT}/scripts/firstboot/79_expand_rootfs" \
   target/linux/rockchip/armv8/base-files/lib/preinit/
chmod +x target/linux/rockchip/armv8/base-files/lib/preinit/79_expand_rootfs
```

- **目标路径无 `openwrt/` 前缀**：`diy-part2.sh` 在 `openwrt/` 树内执行（`build-firmware.sh` 已 `cd "$OPENWRT_DIR"`）
- **源路径用绝对变量**：CWD 在 openwrt 树内，`scripts/` 在上级 repo 根，不可用相对路径；两变量皆空会退化成 `/scripts/...`（cp 失败或拷错文件），故显式断言 fail-loud
- **per-target 天然隔离**：此目录只进 rockchip 固件，x86 编译不打包此路径

---

## BDD 守护断言

`tests/bdd-matrix-build.sh` 守护本功能的契约（B32-B44）：

- **B32** 源文件 `scripts/firstboot/79_expand_rootfs` 存在
- **B33** `bash -n` 语法干净
- **B34** `shellcheck` 无错误
- **B35** 注册 `boot_hook_add preinit_main expand_rootfs`
- **B36** 失败路径用 `return`，不用 `exit` 非 0（砖机防护）
- **B37** 不写死设备名（无 `mmcblk0`/`mmcblk1` 等硬编码）
- **B38** v2 探测契约：认 `TYPE="squashfs"` 组合分区 + sysfs 反推，不残留 `loop0`（v1 死穴已除）
- **B39** offset 运行期动态算（64K 对齐）+ 字节读 + f2fs magic 预校验（防错位毁数据）
- **B40** 含 `resize.f2fs` + `fsck.f2fs` + `losetup -o` 未挂载视图（offline resize invariant）
- **B41** S2 统一清理出口：`losetup -d` 出现 ≥4 次（每个出口都清理，防僵尸 loop）
- **B42** S1 防 bootloop：reboot 前对比分区表实变（`newsize -gt` 旧值才 reboot）
- **B43a/b/c** 5 个 rockchip seed 声明 `f2fsck`/`sfdisk`/`losetup`；均不含 `partx-utils`（死包已移除）；x86 不含任何扩盘包
- **B44** `diy-part2.sh` 落位路径无 `openwrt/` 前缀，源用 `MCPE_REPO_ROOT` 绝对变量 + 空值 fail-loud

---

## 附录：v1 失败根因归档与社区方案辨析

### v1 为何在真机上完全无效

v1 基于两个对真机布局的误判：

**误判一：分区表类型**

v1 用 `sfdisk -d | grep 'label: gpt'` 验证 GPT 存在，不符则退出。真机是 MBR（`label: dos`），v1 在第一行验证就返回 0，整个扩盘逻辑从未执行过。

**误判二：overlay 探测时机**

v1 在 preinit 阶段尝试找 `/dev/loop0` 或独立的 f2fs 块设备。但 preinit 阶段 `80_mount_root` 尚未执行，overlay loop 根本不存在，独立 f2fs 分区也不存在（真机布局是 p2 组合分区）。v1 的探测在真机上必然落空。

两处误判互相掩盖——即便修掉 GPT 检查，v1 的 f2fs/loop0 探测在 preinit 仍然失败。v1 是根本性设计错误，不是局部 bug，v2 整体重写。

### 社区"R5S phildubach"方案辨析

社区流传一种方案：在系统完全启动后，通过第二个 `losetup -o` 句柄对活挂载的 f2fs 做 resize。该方案在部分用例中"能用"的原因是：如果 resize 完成后立即断电/重启，且此间没有 f2fs checkpoint 触发，旧几何还来不及写回。这是时序侥幸，不是安全设计。

f2fs 持有 in-memory 超级块，checkpoint 由内核周期性触发（dirty 数据落盘、umount、内存压力均可触发）。resize 后若 checkpoint 发生，旧几何写回，覆盖 resize 后的新布局，文件系统损坏。该窗口无法在用户空间可靠规避。

**v2 拒绝该路径**，原因是：安全不变量要求的是"对从未挂载过的 f2fs 视图做 resize"，而不是"在 resize 和 checkpoint 之间赛跑"。preinit 阶段满足这一不变量，live 路径不满足。
