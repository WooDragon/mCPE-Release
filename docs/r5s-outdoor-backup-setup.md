# R5S Outdoor — SSD 与读卡器一次性备份配置

本文适用于已刷入包含 `outdoor-backup` 和 `luci-app-outdoor-backup` 的 `r5s-outdoor` 固件，以及已经具有可挂载文件系统的 SSD。本文是交付给目标设备操作者的操作说明，不在本仓库或执行环境中运行任何目标设备命令。

本文不格式化、分区、刷写或擦除任何介质。SSD 应保留现有文件系统。当前固件选择了 ext4、exFAT、NTFS3 与 btrfs 所需的支持包；操作者应使用 SSD 当前受支持的文件系统，而不应为本手册重新创建文件系统。

> **前置阅读**：同一 SSD 上启用 PhotoPrism 前，操作者必须先完成本文的 UUID 与 `/mnt/ssd` 挂载核验，再读取：
> [r5s-outdoor-photoprism.md](r5s-outdoor-photoprism.md) 与 [r5s-outdoor-photoprism-operations.md](r5s-outdoor-photoprism-operations.md)

## 范围与前提

- 本次集成仅面向 `r5s-outdoor`。其 `devices/r5s-outdoor/seed.config` 显式选择 `outdoor-backup` 与 `luci-app-outdoor-backup`。
- `devices/r5s-outdoor/pre-feeds.sh` 是 outdoor feed revision 的真相源。
- 包依赖会带入 `block-mount` 等运行依赖。本文不要求另装 `findmnt`、`lsblk` 或 `pv`。
- 备份方向仅为 SD 卡到 SSD。增量传输不删除 SSD 上已有的源端文件。
- 固件首启会自动把 `fstab` 的 `config global` 段设为 `anon_mount=0`，这是本次唯一的自动配置动作。除此之外不新增自动设备发现，SSD、目标 UUID 与命名 mount 段仍全部由操作者确认。
- 本机的 SSD 与 mt7922 无线网卡共用同一个 M.2 槽，经一颗 packet switch 分成两条下行链路，合计带宽约 500 MB/s。备份速率因此受限于这条链路，而不是 SSD 的标称速率；无线在同一条链路上，故备份验收宜在 AP 开启的状态下进行。

> **前置阅读**：该 M.2 拓扑的细节、两条链路的 PCIe 地址与实测热状态，在排查备份速率或无线异常前应先读取：
> [thermal-and-power-r5s-outdoor.md](thermal-and-power-r5s-outdoor.md) 与 [wireless-mt7922-r5s-outdoor.md](wireless-mt7922-r5s-outdoor.md)

## 0. 配置前停用并记录现状

在插入待备份 SD 卡前，操作者应停止备份服务。预期结果是服务完成已接纳任务的静止处理，随后拒绝新的自动备份。

```sh
/etc/init.d/outdoor-backup stop
cat /var/run/outdoor-backup/state
```

`state` 文件存在时，其内容应为 `stopped:<generation>`。若停止命令返回非零，操作者应先查看日志，不应继续修改挂载或配置。

插入 SSD 和读卡器，但先不要插入待备份 SD 卡。操作者应记录块设备清单和现有挂载配置，以人工区分 SSD、读卡器与系统 overlay：

```sh
block info
uci show fstab
mount
```

`block info` 中的 UUID 是文件系统 UUID。操作者应从实际 SSD 对应行抄录 UUID。设备路径如 `/dev/sda1` 可能随插拔顺序变化，不能写入永久配置。不得把 overlay、系统盘、读卡器或待备份 SD 卡的 UUID 作为 SSD UUID。

## 1. 为已存在的 SSD 文件系统建立稳定挂载

选择一个尚未被其他挂载使用的 SSD 挂载目录。本文统一使用 `/mnt/ssd`。SD 卡源挂载点使用 `/mnt/sdcard`。两个目录应分离，且任何一方都不应位于另一方之内。`/mnt/ssd/SDMirrors` 是备份根目录，不是 SSD 的挂载目录。

操作者应只创建或更新命名 section `fstab.outdoor_backup_target`。不得运行 `block detect` 并重定向覆盖 `/etc/config/fstab`，也不得全量替换已有 fstab 配置。

将下列 `SSD_UUID` 替换为第 0 步人工确认的实际 SSD 文件系统 UUID：

```sh
SSD_UUID='替换为实际 SSD 文件系统 UUID'

uci set fstab.outdoor_backup_target='mount'
uci set fstab.outdoor_backup_target.uuid="$SSD_UUID"
uci set fstab.outdoor_backup_target.target='/mnt/ssd'
uci set fstab.outdoor_backup_target.enabled='1'
uci commit fstab
block mount
```

`block mount` 成功后，操作者应同时核对实际挂载、实际 UUID 和两处配置值：

```sh
mount | grep ' on /mnt/ssd '
block info
uci get fstab.outdoor_backup_target.uuid
uci -q get outdoor-backup.config.target_uuid
```

`mount` 的 `/mnt/ssd` 行应来自选定 SSD。`block info` 中该 SSD 的 UUID 应等于 `fstab.outdoor_backup_target.uuid`。在第 2 步提交前，`outdoor-backup.config.target_uuid` 可以为空；提交后它也应等于同一个 UUID。仅看到普通目录 `/mnt/ssd` 不证明 SSD 已挂载。掉盘后该目录仍可存在，但写入会落到根文件系统或被目标保护拒绝。

## 2. 配置备份目标与 SD 卡源挂载点

`outdoor-backup` 使用命名 UCI section `outdoor-backup.config`。其中 `target_uuid` 绑定目标 SSD 的文件系统 UUID；`target_mount` 是 SSD 挂载目录；`backup_root` 必须是 `target_mount` 的严格子目录；`mount_point` 是程序临时挂载 SD 卡的源目录。

### 在 LuCI 中选择目标存储

先按第 1 步完成 fstab 持久挂载。再打开 Outdoor Backup 配置页，在 Target Storage 中选择目标。列表显示 `device`、`UUID`、`mount` 和 `fstype`。保存时页面会复验目标已挂载、可写且不是系统盘，并联动写入 `target_mount`、`target_uuid` 和 `backup_root`。若目标下已有合法的旧备份子目录后缀，页面沿用该后缀；否则使用 `SDMirrors`。

选择 `Manual` 可保留手工配置。空列表时，先检查挂载状态、目标可写性和系统盘排除结果，再刷新页面。

选择器不自动格式化介质、不执行挂载、不修改 `fstab`，也不迁移数据。传输过程中仍可保存新的目标配置；正在运行的备份继续使用启动时已锚定的旧目标，新配置只对后续备份任务生效。

操作者应只设置以下字段，不应修改 LAN、SSH 或其他基础系统配置：

```sh
SSD_UUID='替换为实际 SSD 文件系统 UUID'

uci set outdoor-backup.config.enabled='0'
uci set outdoor-backup.config.target_mount='/mnt/ssd'
uci set outdoor-backup.config.target_uuid="$SSD_UUID"
uci set outdoor-backup.config.backup_root='/mnt/ssd/SDMirrors'
uci set outdoor-backup.config.mount_point='/mnt/sdcard'
uci commit outdoor-backup
```

配置后的目录关系应如下。若现有验证器拒绝某个值，操作者应保留服务停用状态并回报验证错误，不应改写程序或绕过检查。

```text
SSD 实际挂载目录:       /mnt/ssd
备份根目录:             /mnt/ssd/SDMirrors
SD 卡临时源挂载点:      /mnt/sdcard
```

启用前，操作者应重新执行以下检查。预期结果是 3 个 UUID 字符串一致，SSD 挂载仍存在，且 `/mnt/sdcard` 不在 `/mnt/ssd` 内：

```sh
block info
mount | grep ' on /mnt/ssd '
uci get fstab.outdoor_backup_target.uuid
uci get outdoor-backup.config.target_uuid
uci get outdoor-backup.config.target_mount
uci get outdoor-backup.config.backup_root
uci get outdoor-backup.config.mount_point
```

`test -d /mnt/ssd` 只能证明目录存在，不能证明 SSD 仍在该目录上。因此它不能替代上述挂载来源和 UUID 的比对。

### 匿名自动挂载与 fstab global 段

固件首启的 uci-defaults 脚本 `98-outdoor-backup-fstab` 会自动把 `/etc/config/fstab` 真实 `config global` 段设为 `anon_mount=0`，操作者无需手工设置。匿名自动挂载会让目标归属变得不确定，所以必须为 0。

验证配置已正确落位，执行：

```sh
uci show fstab | grep -E '=global$|anon_mount'
```

预期输出中 global 段的 `anon_mount` 为 `'0'`。若不是 0，操作者应执行以下命令手工修复：

```sh
uci set fstab.@global[0].anon_mount='0'
uci commit fstab
```

该钩子在每次保留配置的 sysupgrade 之后会重新断言 `anon_mount=0`，操作者对该字段的手工修改会被下次首启覆盖。

## 3. 启用、首次卡初始化与重启验证

操作者应在 SSD 挂载与 UUID 比对均通过后，将 UCI 功能开关恢复为 1，再启用和启动服务。init 服务的 `enable` 不会修改 UCI `enabled`。预期服务状态为 `running:<generation>`。

```sh
uci set outdoor-backup.config.enabled='1'
uci commit outdoor-backup
/etc/init.d/outdoor-backup enable
/etc/init.d/outdoor-backup start
cat /var/run/outdoor-backup/state
```

首次插入一张未初始化 SD 卡时，卡必须可写且具有稳定的文件系统 UUID。程序会在有界写入窗口写入卡身份文件，之后以只读方式进行增量备份。稳态备份只将 SD 卡中的新增和变化文件写入 SSD，跳过不变文件；删除 SD 卡上的文件不会删除 SSD 中已有的备份。

备份运行期间，操作者可打开 LuCI 状态页观察进度：

- 条目进度表示最近观测到的文件列表检查位置，包含目录，不是已复制字节的比例，也不证明内容完整性。任务仍在运行时，百分比最高显示 99%。
- 已传文件数、字节数与速度来自传输观测；尚未观测到的值显示等待状态，已观测到的 0 是有效值。增量备份没有可靠的剩余时间估计，页面会明确显示不可用。
- 页面约每 10 秒刷新，短任务可能直接进入终态。验收运行中进度时，应选择持续超过多个刷新周期的样本，记录至少两次运行中状态和最终结果；不能只凭进度条判定备份成功。

若卡只读、卡身份初始化失败、卡身份与已记录值冲突，操作者应预期备份失败而非静默写入 overlay。操作者应停止排障性重复插拔，先读取日志并核对 SSD 挂载与 UUID。不得以“目录存在”为由跳过目标挂载检查。

重启后，操作者应重复第 1 步的 `mount`、`block info` 和 UUID 比对，再检查服务状态：

```sh
cat /var/run/outdoor-backup/state
mount | grep ' on /mnt/ssd '
block info
uci get fstab.outdoor_backup_target.uuid
uci get outdoor-backup.config.target_uuid
```

## 4. 有界故障定位

| 现象 | 操作 | 预期结果或下一步 |
|---|---|---|
| 需要安全停止自动备份 | `/etc/init.d/outdoor-backup stop` | 成功时已接纳任务静止，状态应为 `stopped:<generation>`。非零退出时先查日志。 |
| 查看服务状态 | `cat /var/run/outdoor-backup/state` | 仅接受 `running:<generation>` 或 `stopped:<generation>`。文件缺失时应结合 init 启用状态判断。 |
| 查看系统事件 | `logread -e outdoor-backup` | 日志应说明目标 UUID、挂载、来源身份或卡身份拒绝原因。 |
| 插卡后无备份，日志记录来源已被挂载 | `mount; uci show fstab \| grep -E '=global$\|anon_mount'` | 管理器在挂载来源前检查该来源的 `major:minor` 是否已被挂载，已挂载则拒绝，且不会卸载他人的挂载。操作者应自行从 `mount` 输出中认出该卡的分区，确认 global 段 `anon_mount` 为 `'0'`，安全卸载该来源后重新插卡。 |
| 查看详细日志 | `tail -n 100 /opt/outdoor-backup/log/backup.log` | 结合系统日志定位失败阶段。 |
| 怀疑 SSD 掉盘或错挂载 | `mount | grep ' on /mnt/ssd '; block info` | 实际 SSD UUID 必须与 fstab 和 `target_uuid` 相同。目录存在不构成通过。 |
| 备份速率明显低于 SSD 标称值 | `nvme list; lspci -vv \| grep -A2 LnkSta` | SSD 与无线共用一条 Gen2 x1 链路，合计约 500 MB/s，低于标称属预期。链路已降速或降位宽时才需进一步排查。 |
| 修改配置后恢复服务 | `/etc/init.d/outdoor-backup start` | 仅在全部挂载与 UUID 检查通过后执行。 |

排障不得运行 `cleanup-all.sh --force`。该命令不是诊断工具，且会改变备份数据。

## 5. 验收记录

验收记录应对应最终固件及其实际 feed revision；包仓 CI 通过不能替代完整固件与真机验收。

以下记录应在最终固件和真机验收时填入，不应以推测值替代：

| 记录字段 | 当前值 |
|---|---|
| mCPE main SHA | 待填 |
| mCPE workflow run | 待填 |
| outdoor feed SHA | 待填 |
| 固件 `manifest` | 待填 |
| 固件 `config.buildinfo` | 待填 |
| 固件 `feeds.buildinfo` | 待填 |
| 固件文件名 | 待填 |
| 固件 SHA256 | 待填 |

多分区卡、双槽读卡器、克隆卡和插拔期间的 E01–E10 行为仍需真机证据。本文不把这些未验证场景扩展为实现承诺。
