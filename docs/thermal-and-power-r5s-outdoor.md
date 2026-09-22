# r5s-outdoor 的热与 PCIe 功耗边界

本文记录 NanoPi R5S 的 `r5s-outdoor` 固件在 ImmortalWRT 24.10、Linux 6.6 上的实测热基线、已确认的热节流失效根因，以及 PCIe ASPM 的能力边界。本文是架构与诊断说明，不是散热改装操作手册。

## 实测基线

以下数据来自真机实测。环境温度为 26.7 ℃。整机空载功耗为 4.8 W。CPU 温度为 78.75 ℃。GPU 温度为 75.625 ℃。CPU 相对环境温升为 52 ℃。按整机空载功耗估算的热阻为 10.8 ℃/W。

`/sys/class/thermal/` 只有 `thermal_zone0`（`cpu-thermal`）与 `thermal_zone1`（`gpu-thermal`）。系统没有任何 `cooling_device*`。`cpufreq` 的 `policy0` 存在，governor 为 `schedutil`，OPP 表覆盖 408000 到 1992000 kHz。

`time_in_state` 显示 CPU 有 92.48% 时间驻留在 408 MHz。CPU 驻留在 1608 MHz 或更高频率的时间只有 0.19%。这些数据说明空载时的动态 CPU 功耗已经很低。

## CPU_FREQ_THERMAL 根因

**事实：** ImmortalWRT v24.10.6 的 `target/linux/generic/config-6.6` 第 991 行是 `# CONFIG_CPU_FREQ_THERMAL is not set`；`target/linux/rockchip/armv8/config-6.6` 完全未提及该符号。OpenWrt 的内核配置合并规则是 generic 打底、target 覆盖，因此 rockchip target 未覆盖时，generic 的显式 `not set` 就是最终值。Linux 6.6 的 `drivers/thermal/Kconfig` 虽声明该子符号 `default y`，显式的 `# ... is not set` 仍会覆盖默认值。父符号 `CONFIG_CPU_THERMAL=y` 由 rockchip target config 第 178 行提供，造成“看起来启用了”的假象。

**事实：** `drivers/cpufreq/cpufreq.c:1575` 根据 `CONFIG_CPU_THERMAL` 调用 `of_cpufreq_cooling_register()`。`include/linux/cpu_cooling.h` 则用 `#ifdef CONFIG_CPU_FREQ_THERMAL` 控制该函数实体。子符号关闭时，`#else` 分支直接 `return NULL`。

**推断：** 内核调用路径仍然完整，但注册函数静默返回空指针。因此 dmesg 不会报告错误。RK3568 DTS 中的 70 ℃ 与 75 ℃ passive trip 虽有 cooling-map，却没有可执行的 CPU 降频机构。负载持续升温时，系统可能直接到达 95 ℃ 的 TSADC 硬关机线。

构建脚本现在把该子符号直注到 `target/linux/generic/config-6.6`。generic config 是全部 target 共用的基础配置，所以该改动影响全部设备而非仅 Rockchip：x86 若未启用 `CONFIG_CPU_FREQ`，该符号因 `depends on CPU_FREQ` 不生效、无副作用；Rockchip 侧 `CONFIG_CPU_FREQ=y`，故修复生效。

## CPU 热节流阈值：从 70/75/95 ℃ 调为 85/90/95 ℃

### 触发问题与机制

**事实（真机）：** 启用 `CPU_FREQ_THERMAL` 后，26.7 ℃环境、空载 CPU 66–73 ℃时，`/sys/class/thermal/cooling_device0/cur_state` 已为 `7`（`max_state=7`）；`scaling_cur_freq` 与 `scaling_max_freq` 都是 `408000` kHz。CPU 因而被锁死在最低 OPP，而不是仅在高温负载时降频。

**事实（Linux 6.6.133 DTS）：** `rk356x.dtsi` 的 `cpu_thermal` 有 70 ℃ `cpu_alert0`、75 ℃ `cpu_alert1` 和 95 ℃ `cpu_crit`。唯一 `cooling-maps/map0` 只引用 `&cpu_alert0`，并把四个 CPU 的上限设为 `THERMAL_NO_LIMIT`；`cpu_alert1` 没有 cooling-map，只产生 thermal netlink 通知。

**事实（Linux 6.6 `drivers/thermal/gov_step_wise.c`）：** 温度高于 passive trip 且趋势未下降时，step-wise governor 每个 polling 周期计算 `next_target = clamp(cur_state + 1, instance->lower, instance->upper)`。这里 `upper` 是 `THERMAL_NO_LIMIT` 展开的 `max_state=7`，而 passive polling delay 是 100 ms。因此 73 ℃基线一旦越过唯一受控的 70 ℃ trip，会在约一秒内逐级顶到 state 7；温度没有回落就不会自行恢复。

**事实（写入路径）：** sysfs 的 trip 属性只读，向 `trip_point_0_temp` 写入 85000 会返回 `Permission denied`。阈值只能通过 DTS patch 改，而不能用运行时脚本覆盖。

### 取值与边界

| 来源/策略 | passive 1 | passive 2 | critical | 说明 |
|---|---:|---:|---:|---|
| Linux mainline RK356x 原值 | 70 ℃ | 75 ℃ | 95 ℃ | 唯一 cooling-map 绑在 70 ℃的 `cpu_alert0` |
| Rockchip vendor BSP `develop-5.10` | 75 ℃ | 85 ℃ | 115 ℃ | cooling-map 绑在名为 `target` 的 85 ℃ trip |
| 本项目 DTS patch | 85 ℃ | 90 ℃ | 95 ℃ | 把唯一实际降频点对齐 vendor 的 85 ℃，并保留无风扇设备的保守关机线 |

**推断：** vendor 的 115 ℃ critical 适合其主动散热或工业设计假设，不适合本项目的无风扇户外盒子。将 `cpu_alert0` 提到 85 ℃消除空载基线即满档节流的问题；将无 map 的 `cpu_alert1` 提到 90 ℃保持单调 trip 顺序；95 ℃ critical 继续作为最后的硬关机防线。`hysteresis=2000`、`polling-delay-passive=100` 和 cooling-map 结构不变，避免无关重构扩大上游 patch 冲突面。

**影响范围（事实）：** 该 patch 修改 RK3566/RK3568 共用的 `rk356x.dtsi`，影响 r3s（RK3566）、r5s、r5s-outdoor 和 r68s（RK3568）；r2s（RK3328）走不同 DTS，不受影响。这是有意的：原装金属壳 r5s/r68s 的空载约 41 ℃，只会在重载时获得更多温度余量。

## 热预算

**推断：** 以实测热阻 10.8 ℃/W 和空载温升 52 ℃估算，40 ℃ 环境下芯温约为 92 ℃。45 ℃ 环境下芯温约为 97 ℃，超过 95 ℃ TSADC 硬关机线。

**推断：** 若要在 45 ℃ 环境下把芯温守在 85 ℃，温升必须不高于 40 ℃。在 4.8 W 功耗下，热阻必须降到约 8.3 ℃/W。在 10.8 ℃/W 热阻下，功耗必须降到约 3.7 W。单独满足其中一项不足以同时满足这个热预算。

## 热节流的能力边界

修复 `CPU_FREQ_THERMAL` 后，CPU 降频会成为负载升温时的安全网。该修复不降低空载温度。实测中 CPU 已有 92.48% 时间运行在 408 MHz，空载的主要热源不是可继续大幅降低的 CPU 动态功耗。

## ASPM：同一次启动对照后下发 powersave

**事实（issue #50，同一次启动）：** policy 为 `[default]` 时，M.2 链路的 `LnkCtl: ASPM Disabled`。向 `/sys/module/pcie_aspm/parameters/policy` 写入 `printf powersave` 后，根桥 `0002:20:00.0` 显示 `ASPM L1 Enabled`，NVMe `0002:23:00.0` 的 `l1_aspm=1`，mt7922 `0002:24:00.0` 的 `l1_aspm=1`。

**事实（同一次启动）：** 随后用 ch36/HE40 拉起 AP，hostapd 走到 `AP-ENABLED`，没有出现 `driver own failed`。上次挂死发生在 ASPM 全关时，因此 L1 不是那次挂死的成因。

**事实：** ASM1182e 不提供 L1SS，`powersupersave` 不会多出可见的协商状态。两个 RTL8125 的 `ASPM Disabled` 是 r8169 主动关闭的结果，不碰这两个端口。

**裁决：** r5s-outdoor 每次开机由 `r5s-outdoor-boot`（`START=15`）写入 `powersave`。BDD B47 守护只有该设备下发 policy，禁止 `powersupersave` 写入，也禁止泄漏到 common、diy 或其他设备。

**边界：** 挂死根因仍未闭合。风扇对照尚未进行，户外合盖且无风扇的条件不能从一次成功外推。因此，这次成功不代表 MCU 已修好。

## 盘侧功耗：与 ASPM 正交的那个旋钮

**事实：** NVMe APST（Autonomous Power State Transition）由 `nvme_core.default_ps_max_latency_us` 控制（真机为 100000），与 PCIe ASPM 是两套独立机制。真机 `nvme id-ctrl` 报告 PS0 6.50 W 到 PS4 0.0025 W 的档位表。

**推断：** ASPM 动的是链路，APST 与 Feature 0x02（Power Management）动的是盘本身。后者不经过 switch 的延迟惩罚，也不改变 mt7922 那条链路的状态，因此是当前唯一没有已知副作用的降功耗旋钮。`r5s-outdoor` 为此预装 `nvme-cli`（seed `CONFIG_PACKAGE_nvme-cli=y`），可用 `nvme set-feature -f 2` 把操作功率档位压到 PS2。这块盘在 Gen2 x1 上的可用带宽本就约 500 MB/s，压档位的实际速率代价有限。

## M.2 拓扑约束

**事实：** M.2 M-key 槽是 PCIe 2.1 Gen2 x1 单 lane。该接口不能提供 bifurcation。NVMe 与 mt7922 必须经有源 switch 共享同一条链路。

**推断：** 两个端点共享约 500 MB/s 的 Gen2 x1 可用带宽。ASPM 策略只能改变已保留能力的电源状态，不能改变这条拓扑和带宽上限。

**该拓扑的无线侧后果**：mt7922 在 AP 拉起时会冻结 rtnl，只能断电恢复。故障现象、已排除的怀疑对象与固件钉死的应对配置，见 [wireless-mt7922-r5s-outdoor.md](wireless-mt7922-r5s-outdoor.md)。
