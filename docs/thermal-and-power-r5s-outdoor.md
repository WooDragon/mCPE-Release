# r5s-outdoor 的热与 PCIe 功耗边界

本文记录 NanoPi R5S 的 `r5s-outdoor` 固件在 ImmortalWRT 24.10、Linux 6.6 上的实测热基线、已确认的热节流失效根因，以及 PCIe ASPM 的能力边界。本文是架构与诊断说明，不是散热改装操作手册。

## 实测基线

以下数据来自真机实测。环境温度为 26.7 ℃。整机空载功耗为 4.8 W。CPU 温度为 78.75 ℃。GPU 温度为 75.625 ℃。CPU 相对环境温升为 52 ℃。按整机空载功耗估算的热阻为 10.8 ℃/W。

`/sys/class/thermal/` 只有 `thermal_zone0`（`cpu-thermal`）与 `thermal_zone1`（`gpu-thermal`）。系统没有任何 `cooling_device*`。`cpufreq` 的 `policy0` 存在，governor 为 `schedutil`，OPP 表覆盖 408000 到 1992000 kHz。

`time_in_state` 显示 CPU 有 92.48% 时间驻留在 408 MHz。CPU 驻留在 1608 MHz 或更高频率的时间只有 0.19%。这些数据说明空载时的动态 CPU 功耗已经很低。

## CPU_FREQ_THERMAL 根因

**事实：** ImmortalWRT 的 `target/linux/rockchip/armv8/config-6.6` 启用了父符号 `CONFIG_CPU_THERMAL=y`，但显式关闭了子符号 `# CONFIG_CPU_FREQ_THERMAL is not set`。Linux 6.6 的 `drivers/thermal/Kconfig` 在 `CPU_THERMAL` 条件内定义 `CPU_FREQ_THERMAL`。子符号依赖 `CPU_FREQ`，上游默认值为 `y`。

**事实：** `drivers/cpufreq/cpufreq.c:1575` 根据 `CONFIG_CPU_THERMAL` 调用 `of_cpufreq_cooling_register()`。`include/linux/cpu_cooling.h` 则用 `#ifdef CONFIG_CPU_FREQ_THERMAL` 控制该函数实体。子符号关闭时，`#else` 分支直接 `return NULL`。

**推断：** 内核调用路径仍然完整，但注册函数静默返回空指针。因此 dmesg 不会报告错误。RK3568 DTS 中的 70 ℃ 与 75 ℃ passive trip 虽有 cooling-map，却没有可执行的 CPU 降频机构。负载持续升温时，系统可能直接到达 95 ℃ 的 TSADC 硬关机线。

构建脚本将该子符号直注到 Rockchip 的 target 配置。此 target 由 r2s、r3s、r5s、r5s-outdoor 与 r68s 共用，所以修复有意覆盖全部 Rockchip 设备。

## 热预算

**推断：** 以实测热阻 10.8 ℃/W 和空载温升 52 ℃估算，40 ℃ 环境下芯温约为 92 ℃。45 ℃ 环境下芯温约为 97 ℃，超过 95 ℃ TSADC 硬关机线。

**推断：** 若要在 45 ℃ 环境下把芯温守在 85 ℃，温升必须不高于 40 ℃。在 4.8 W 功耗下，热阻必须降到约 8.3 ℃/W。在 10.8 ℃/W 热阻下，功耗必须降到约 3.7 W。单独满足其中一项不足以同时满足这个热预算。

## 热节流的能力边界

修复 `CPU_FREQ_THERMAL` 后，CPU 降频会成为负载升温时的安全网。该修复不降低空载温度。实测中 CPU 已有 92.48% 时间运行在 408 MHz，空载的主要热源不是可继续大幅降低的 CPU 动态功耗。

## ASPM 保留

**事实：** 当前内核使用 `CONFIG_PCIEASPM_DEFAULT=y`。该配置沿用固件设置，而 RK3568 的 U-Boot 通常不配置 ASPM。`r5s-outdoor` 在每次启动时把运行时 policy 写为 `powersave`。

**能力边界：** M.2 链路经过有源 packet switch。`pcie_aspm_check_latency()` 可能因 switch 带来的 +1 µs 延迟惩罚清除 `ASPM_STATE_L1` 能力位。后续 policy 下发前仍会与 `link->aspm_capable` 和 `link->aspm_disable` 相交。因此 `powersave` 不能恢复已经被清除的 L1。应使用 `lspci -vv` 核验实际链路状态。

## M.2 拓扑约束

**事实：** M.2 M-key 槽是 PCIe 2.1 Gen2 x1 单 lane。该接口不能提供 bifurcation。NVMe 与 mt7922 必须经有源 switch 共享同一条链路。

**推断：** 两个端点共享约 500 MB/s 的 Gen2 x1 可用带宽。ASPM 策略只能改变已保留能力的电源状态，不能改变这条拓扑和带宽上限。
