# r5s-outdoor 无线（mt7922）的可用边界

本文记录 `r5s-outdoor` 固件上 mt7922 无线网卡的真机行为：AP 拉起时冻结 rtnl 的故障、逐项排除的怀疑对象、固件里钉死的配置及其理由，以及两项已确认的硬件限制。

本文是诊断与决策说明，不是无线调优手册。固件实际写入的配置以 `devices/r5s-outdoor/post-feeds.sh` 生成的 `99-wireless-r5s-outdoor` 为权威。

> **前置阅读**：M.2 槽的 packet switch 拓扑、PCIe ASPM 的未定论状态与 NVMe 功耗旋钮，构成本文多处结论的前提，读本文前应先读取：
> [thermal-and-power-r5s-outdoor.md](thermal-and-power-r5s-outdoor.md)

## 故障现象

**事实（真机）：** hostapd 把 AP 接口置为 UP 时，内核日志出现 mt7921e 的 `driver own failed`。该消息表示驱动向网卡 MCU 申请驱动侧所有权（drv-own）的握手未完成。

**事实（真机）：** 该消息出现后，rtnetlink（rtnl，内核的网络配置接口）随即冻结。`ip link` 与新建 SSH 连接都停在 D 状态不返回，已建立的 ICMP 回应仍正常。系统无法通过软件手段恢复，只能断电重启。

**影响范围：** 该故障发生在 AP 拉起的一瞬间，不是运行一段时间后的退化。

## 已排除的怀疑对象

下列四项在排查中被逐一证伪。记录在此，避免重复走一遍。

| 怀疑对象 | 证伪依据 |
|---|---|
| PCIe ASPM | 挂死发生时 `/sys/module/pcie_aspm/parameters/policy` 为出厂 `[default]`，两条下行链路的 `l0s_aspm`、`l1_aspm`、`clkpm` 全为 0。ASPM 从未启用过，不可能是成因。其能力状态另有未定论问题，见前置阅读。 |
| NVMe 在位 | 曾观察到「拔掉 SSD 后 AP 起来了」。复查发现该次操作同时强制了一次冷启动，冷启动才是变量。后续在 SSD 已挂载、正在写入的情况下 AP 照常拉起。 |
| `htmode` 过宽本身 | HE40 可以起来，HE80 挂过，但两次不是同一次启动，中间还夹着信道差异。单独归因给带宽不成立。 |
| 发射功率过高 | 功率爬坡实验六级全程恒定在 3 dBm，`iw ... set txpower fixed` 一次都没生效。该实验没有产生任何功率差异，其结论无效。 |

**当前状态：** 挂死的根因未定。剩下的工作假设是「ASM1182e 88 ℃ 的热应力、mt7922 射频前端上电的电流台阶、不省电的 NVMe，三者叠在一条按单 NVMe 设计的 3.3 V 供电上」。该假设没有直接证据，不应当作结论使用。

## 固件钉死的配置及理由

`99-wireless-r5s-outdoor` 在 `wifi detect` 导入之后覆盖以下字段：

| 字段 | 值 | 理由 |
|---|---|---|
| `band` | `5g` | `wifi detect` 按硬件能力写 `6g`。CN 监管域无 6 GHz WLAN 信道，AP 不发信标。 |
| `channel` | `36` | `auto` 会让 hostapd 跑一遍全带 ACS（Automatic Channel Selection，自动信道选择）扫描，长时间占住 MCU。ch36 是非 DFS 信道，无需扫描。 |
| `htmode` | `HE40` | 更宽的模式会探到 DFS 信道，进而触发 CAC（Channel Availability Check，信道可用性检查）静默等待。HE40 + ch36 是真机上起来过的组合。 |
| `country` | `CN` | 显式钉死，不依赖 `wifi detect` 导入什么。 |
| `ssid` | `outdoor-backup` | 该 AP 是备份机的状态检查入口。 |
| `encryption` / `key` | `psk2` / 公开预设 | PSK 进 public git 是有意的：这个 SSID 不承载机密。 |

**不应改回 `channel='auto'` 或 `htmode='HE80'`。** 这两个值的组合在真机上挂死过，且挂死代价是断电重启。BDD 断言 B04f 对生成脚本做字面检查，含这两个值的否定断言。

**脚本里不写 `txpower`。** 理由见下一节。

## 两项已确认的硬件限制

### 发射功率锁死在 3 dBm

**事实（真机）：** `iwinfo` 与 `iw dev phy0-ap0 info` 都报 `Tx-Power 3.00 dBm`。`uci set wireless.radio0.txpower` 与 `iw dev phy0-ap0 set txpower fixed <mBm>` 都不改变该读数，`wifi down; wifi up` 之后仍是 3 dBm。

**事实（真机）：** 监管域不是限制方。`iw reg get` 报 `country CN: DFS-FCC`，`iw phy phy0 info` 的各信道条目均标注 `(30.0 dBm)` 上限。

**裁决：** 该限制按已知限制记录，不再追查。3 dBm 在 15 m 视距下的接收强度约 -63 dBm，满足「车辆周边状态检查入口」这一用途。固件不写 `txpower`，避免在配置里留一个硬件不认的值。

### SSD 不能挪到 USB3

**事实：** 该约束由使用方确认，属硬性前提。

**推论：** NVMe 与 mt7922 共用一条 Gen2 x1 下行链路这件事没有退路。任何「把盘挪开以隔离供电与带宽」的方案都不可行。拓扑细节见前置阅读。

## 核验命令

以下命令用于在真机上复核本文的事实。执行前提是 SSH 可用且 AP 已拉起。

**核验无线实际参数**（预期：Channel 36、HE40、SSID `outdoor-backup`、Tx-Power 3 dBm）：

```sh
iwinfo
iw dev phy0-ap0 info
```

**核验挂死是否复现**（预期：无 `driver own failed`，`ip link` 立即返回）：

```sh
logread -e mt7921
ip -o link show
```

若 `ip -o link show` 不返回，rtnl 已冻结，此时只能断电。

## 待验证

固件里钉死的是「已知能起来的状态」，不是根因修复。新固件应走一次完整验收：合盖冷启动、向 SSD 写入 20 GB、手机关联 AP、持续 30 分钟。验收记录与进度在 issue #46 跟踪。

以下方向已提出但未实施，各自的取舍记录在 issue #46：rtnl 存活看门狗、ASM1182e 导热垫、把 NVMe 操作功率档位压到 PS2、PCIe 降到 Gen1。
