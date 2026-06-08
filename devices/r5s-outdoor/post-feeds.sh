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
