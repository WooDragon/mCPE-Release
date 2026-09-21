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

cat > package/base-files/files/etc/uci-defaults/98-outdoor-backup-fstab << 'SCRIPT'
#!/bin/sh
# outdoor-backup runtime prerequisite: anonymous automounts make target
# ownership ambiguous, so force anon_mount=0 on the real fstab global section.
#
# Ordering: runs after block-mount's own 10-fstab (which creates
# /etc/config/fstab via `block detect`) and before /etc/init.d/fstab performs
# the first `block mount`. On a fresh image `block detect` already emits
# anon_mount '0'; this script is the guard for a sysupgrade that preserved a
# config where it had been set to 1.
#
# Idempotent: re-running sets the same value. uci_apply_defaults sources this
# file and only deletes it on a zero exit, so a failure to apply the setting
# exits nonzero and logs the reason: the script is kept and retried on the next
# boot. A silent failure would instead surface much later as a device_unknown
# source rejection with no evidence left behind.

if [ ! -f /etc/config/fstab ]; then
    logger -t outdoor-backup-fstab 'no /etc/config/fstab; skipping the anon_mount prerequisite'
    exit 0
fi

# Takes the first global section. A config carrying more than one is
# pathological and is not reconciled here.
fstab_global=$(uci -q show fstab | sed -n 's/^fstab\.\([^.=]*\)=global$/\1/p' | sed -n '1p')
if [ -z "$fstab_global" ]; then
    if ! fstab_global=$(uci add fstab global); then
        logger -t outdoor-backup-fstab "ERROR: failed to create fstab global section"
        exit 1
    fi
fi

if ! uci set "fstab.$fstab_global.anon_mount=0"; then
    logger -t outdoor-backup-fstab "ERROR: failed to set anon_mount=0 on fstab.$fstab_global"
    exit 1
fi

if ! uci commit fstab; then
    logger -t outdoor-backup-fstab "ERROR: failed to commit fstab changes"
    exit 1
fi

exit 0
SCRIPT

chmod +x package/base-files/files/etc/uci-defaults/98-outdoor-backup-fstab
echo "==> Added fstab prereq: 98-outdoor-backup-fstab (anon_mount=0)"
