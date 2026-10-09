# r5s-outdoor 无线（mt7922）的可用边界

本文记录 `r5s-outdoor` 固件上 mt7922 无线网卡的真机行为：AP 拉起时冻结 rtnl 的故障、逐项排除的怀疑对象、固件里钉死的配置及其理由，以及两项已确认的硬件限制。

本文是诊断与决策说明，不是无线调优手册。固件实际写入的配置以 `devices/r5s-outdoor/post-feeds.sh` 生成的 `99-wireless-r5s-outdoor` 为权威。

> **前置阅读**：M.2 槽的 packet switch 拓扑、现网开机 powersave，能力已在同一次启动对照中确认 L1 与 NVMe 功耗旋钮，构成本文多处结论的前提，读本文前应先读取：
> [thermal-and-power-r5s-outdoor.md](thermal-and-power-r5s-outdoor.md)

## 故障现象

**事实（真机）：** hostapd 把 AP 接口置为 UP 时，内核日志出现 mt7921e 的 `driver own failed`。该消息表示驱动向网卡 MCU 申请驱动侧所有权（drv-own）的握手未完成。

**事实（真机）：** 该消息出现后，rtnetlink（rtnl，内核的网络配置接口）随即冻结。`ip link` 与新建 SSH 连接都停在 D 状态不返回，已建立的 ICMP 回应仍正常。系统无法通过软件手段恢复，只能断电重启。

**影响范围：** 该故障发生在 AP 拉起的一瞬间，不是运行一段时间后的退化。

## 已排除的怀疑对象

下列四项在排查中被逐一证伪。记录在此，避免重复走一遍。

| 怀疑对象 | 证伪依据 |
|---|---|
| PCIe ASPM | 挂死发生时 policy 为 `[default]`、链路 ASPM Disabled，故 **那次** 挂死不是 L1 造成的。现网开机写 powersave（issue #50）。根因仍未闭合。 |
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
| `disabled` | `1` | 提交值固定为 `1`。每次开机 init 先 runtime 覆盖为 `1`，30s 后再执行 `wifi up`，且不 commit。 |
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

## PCIe 恢复耗尽后的软件失败隔离

固定 mt76 的 PCIe 恢复最多尝试十次。首次、中途或第十次成功仍走原正常恢复路径；只有全部失败才发布独立、单调的 `MT76_STATE_RECOVERY_FAILED`。该状态不等于临时 `RESET` 或最终 `REMOVED`，也不尝试修复第一次 drv-own 失败的硬件原因。

- **恢复所有权。** common reset 只 park 一次 TX worker，成功才 unpark。单次 HIF reset 保留配对的 NAPI disable/enable；WPDMA、固件与 MCU 错误向上返回，不把失败写成成功。恢复前 ownership 错误仍允许原 WFSYS 恢复机会。
- **终态停止调度。** FAILED 发布和 IRQ helper 的检查、mask、tasklet 排入使用同一 `irq_lock`。设备级 PM、watchdog、scan、ROC、IPv6 与 coredump 的终态路径不恢复接口或建立持续重排。NAPI complete 仅表示清除 SCHED，不表示正在运行的 C poll 函数已经返回；其旧尾部仍必须受终态 IRQ 检查约束。
- **MCU 排空。** 先发布终态并唤醒等待者，再依次经过 mt76 与 MCU mutex 屏障。新 transport 请求消费 skb 一次并返回 `-EIO`；终态响应解析不重复记录 timeout 或排 reset。持锁的旧 PM/MCU 操作退出后，FAILED 清理才继续。
- **rfkill 与最终释放。** reset 排入一次 `system_unbound_wq` 清理工作，reset 和持 wiphy 的 `.stop` 都不 join 它，避免 reset、`.stop` 与 poll 三方互等。最终 remove 先 join init/reset producer，再 flush 清理、停止 polling，最后 unregister/free。REMOVED 不能让已排入的清理跳过职责。FAILED 的 `.stop` 和 DMA 清理不重复 park，仍释放 NAPI、ring、page pool、skb 与 token 等软件资源。

FAILED 没有软件重试入口；重新 `wifi up` 不清除它。恢复该设备状态需要重新初始化设备，本项目未把 reboot 或热插拔当作已验收的恢复手段。现有 UCI、延迟 AP、ASPM、NVMe 与其他设备配置不因该隔离改变。

## 恢复耗尽后的 CSA 生命周期

`r5s-outdoor` 的 [mt76 专用补丁](../devices/r5s-outdoor/patches/mt76/990-mt7921-pcie-recovery-fail-stop.patch) 区分设备失败隔离和接口最终销毁。固定驱动、基内核与实际 mac80211 backports 的版本及源摘要以 [源码 manifest](../tests/fixtures/mt7921-fail-stop/source-manifest.json) 为准。该补丁不改变上述无线参数或 PCIe/NVMe 策略。

CSA（Channel Switch Announcement，信道切换通知）是一次性事务。station 接口的核心 CSA 状态已经 active 时，驱动不能把终态早退当作事务完成。这里的终态指 `FAILED` 或 `REMOVED`；`FAILED` 是 PCIe 恢复十次耗尽后的单调软件失败状态，不是短暂的 reset，也不等于接口已经删除。

- **设备隔离。** FAILED reset 不再遍历或同步取消各接口的 CSA timer/work，也不为此取得 wiphy 锁。reset 返回不表示所有旧 CSA callback 或核心断开工作已经完成。
- **驱动通知。** 终态 pre callback 返回 `-EIO`，核心沿自己的错误路线排入断开工作。终态 void producer、mt7921 timer 和 work 经短 RCU 临界区检查 station、关联与 active 状态，再调用 `ieee80211_chswitch_done(false)`。该 API 只排入核心工作，不同步清除关联或 CSA 状态。RCU 不保活驱动的接口私有对象。
- **核心消费。** 核心断开工作随后执行 disassoc/unassign，清除关联和 CSA 标志，并解除 CSA 的队列阻塞。station down 先清关联，再经过 RCU grace period，最后取消核心工作；较晚的驱动通知不能重新排入已取消的断开工作。
- **最终销毁。** 框架持有 wiphy 时，mt7921 专属 remove wrapper 依次同步停止 timer、等待 work、调用原 remove。框架只在 wrapper 返回后清零 `drv_priv`。同步等待期间不持有 callback 所需的 mt76 mutex。原 abort 与 unassign 的取消顺序保留。

健康检查之后才发布 FAILED 时，旧 producer 可留下原 deadline 对应的一次 timer。旧 timer 检查之后才发布 FAILED 时，也可排入一次原 work。终态消费者只完成软件失败通知，不建立周期重排。这个有界尾部不承诺固定秒数，也不表示 reset 已提前结束旧 timer 的原 deadline。健康路径保留原 PM wake、信道更新及正常 release；共享 timer 的 mt7925 行为不采用 mt7921 的终态分支。正常 mt7921 USB/SDIO 的共用 CSA 路径仍保留，PCIe FAILED 的生产入口没有扩到这些总线。

[无线 BDD 入口](../tests/bdd-mt7921-fail-stop.sh) 的默认 full 实际执行 driver 与 CSA 两个分区。runner 逐例核对实际执行数与注册的预期数，任一分区失败都会使 full 失败。driver 分区从当前交付补丁提取完整 reset、MCU、PM、IRQ/NAPI、rfkill 和最终 remove/shutdown 函数。CSA 分区复用同一 prepare 与原文提取器，再执行实际 backports 的核心 completion、断开和 CSA 消费函数；接口停止的相关阶段按固定原文建模。

NAPI 替身遵守固定 Linux 的 SMP 同步合同：只要 SCHED 仍置位，`napi_synchronize` 与 `napi_disable` 就应等待排队项。替身按需调用实际提取的 TX/RX poll，只有 poll 的 complete 才释放 SCHED；disable 不代替 poll 清位。可控交错分别覆盖 TX/RX 的排队但未运行状态，以及原有 complete 后 C 函数尾部仍运行的状态。这个按需执行器不模拟整个内核调度器，也不把清除 SCHED 当作 C 函数已经返回。

CSA 场景进程逐例区分行为失败、明确的等待环或对象生命周期合同失败，以及不确定终止。合同失败使用专用退出码，并绑定该子进程自己的诊断。所有 signal（包括 alarm 安全阀）、未知退出、编译失败和执行数缺失都属于不确定结果。最外层变异 runner 再核验完整计数与逐例分类；只有已确认的行为或合同失败才获得 `MUTANT_REJECTED`。独立的 [runner 合同测试](../tests/fixtures/mt7921-fail-stop/runner-contract.py) 实跑这些拒绝路径，并恢复弱 NAPI 规则或移除子 runner 校验以验证拒绝边界。matrix 的无线分区同时执行该合同测试。

pthread 等待图、timer、RCU、分配器及硬件服务的替身只验证这些源码在给定交错下的行为。完整函数的 body 与 HIF 宏保持原文，实际 ops/HIF 注册也由提取器核对；这些检查仍不等于真实内核调度、USB/SDIO HIF、DMA 硬件或固件故障注入。原源码红基线与临时源码变异都应先编译成功，再按具体场景的断言拒绝；编译失败和安全超时不算行为证据。full 通过也不代表完整固件或运行设备稳定性已经验收。

首次 `driver own failed` 的硬件根因仍未闭合。软件隔离不能证明 rtnl/softirq 在真机故障中已经恢复，也不能替代下文的冷启动、SSD 写入和关联稳定性验收。

## 核验命令

以下命令用于在真机上复核本文的事实。执行前提是 SSH 可用且 AP 已拉起。开机约 30s 内 SSID 可以不出现。

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
