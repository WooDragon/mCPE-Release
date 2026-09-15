#!/bin/bash
# Device hook: WiFi UCI defaults for r5s-outdoor (mt7922 via M.2 PCIe)
# Sourced by diy-part2.sh AFTER system configuration (diy-part2 runs first,
# creates 99-custom-settings, then sources this hook).
# Creates 99-wireless-r5s-outdoor in the firmware image; runs at first router
# boot to configure SSID (uses wifi detect so no hardcoded PCIe sysfs path).

mkdir -p package/base-files/files/etc/uci-defaults

cat > package/base-files/files/etc/uci-defaults/99-wireless-r5s-outdoor << 'SCRIPT'
#!/bin/sh
# WiFi (mt7922 via M.2 PCIe) — SSID: mW, open network
# wifi detect generates the UCI wireless config for the detected hardware
# (avoids hardcoding the PCIe sysfs path which varies per board revision).
wifi detect | uci -m import wireless
uci set wireless.radio0.disabled=0
uci set wireless.default_radio0.ssid='mW'
uci set wireless.default_radio0.encryption='none'
uci commit wireless
exit 0
SCRIPT

chmod +x package/base-files/files/etc/uci-defaults/99-wireless-r5s-outdoor
echo "==> Added wireless UCI defaults: 99-wireless-r5s-outdoor (SSID: mW, open)"

# CONFIG_PCIEASPM_DEFAULT=y keeps the firmware setting; RK3568 U-Boot normally
# leaves ASPM unconfigured. Install a boot-time init script because the sysfs
# policy resets on reboot. Create the standard rc.d link during image assembly:
# it exists before the first boot and starts this script persistently without
# placing any ASPM policy in the one-shot UCI defaults script.
mkdir -p package/base-files/files/etc/init.d
cat > package/base-files/files/etc/init.d/pcie-aspm-powersave << 'SCRIPT'
#!/bin/sh /etc/rc.common
# Apply powersave before network startup. A packet switch can make
# pcie_aspm_check_latency() remove L1 capability; policy=powersave cannot restore
# it, so lspci -vv remains the authoritative verification of actual L1 state.
START=11

start() {
	local policy_path='/sys/module/pcie_aspm/parameters/policy'
	local before_policy after_policy

	if [ ! -e "$policy_path" ]; then
		logger -t pcie-aspm "policy file unavailable: $policy_path"
		return 0
	fi

	before_policy="$(cat "$policy_path" 2>/dev/null || printf '<unreadable>')"
	if printf '%s\n' powersave > "$policy_path"; then
		after_policy="$(cat "$policy_path" 2>/dev/null || printf '<unreadable>')"
		logger -t pcie-aspm "policy before=$before_policy after=$after_policy requested=powersave"
	else
		after_policy="$(cat "$policy_path" 2>/dev/null || printf '<unreadable>')"
		logger -t pcie-aspm "failed to request powersave: before=$before_policy after=$after_policy"
	fi
}
SCRIPT

chmod +x package/base-files/files/etc/init.d/pcie-aspm-powersave
mkdir -p package/base-files/files/etc/rc.d
ln -sf ../init.d/pcie-aspm-powersave \
  package/base-files/files/etc/rc.d/S11pcie-aspm-powersave
echo "==> Added persistent ASPM init script: pcie-aspm-powersave"
