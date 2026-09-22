#!/bin/bash
# Device hook: r5s-outdoor first-boot UCI + every-boot init (diy-part2 sources this
# AFTER 99-custom-settings). Wireless UCI defaults pin the 5 GHz AP; the init
# writes PCIe ASPM powersave, keeps the radio down until a delayed wifi up, and
# stops netdata after S99 (issue #50).

mkdir -p package/base-files/files/etc/uci-defaults
mkdir -p package/base-files/files/etc/init.d

cat > package/base-files/files/etc/uci-defaults/99-wireless-r5s-outdoor << 'SCRIPT'
#!/bin/sh
# WiFi (mt7922 via M.2 PCIe) — 5 GHz AP, SSID outdoor-backup, WPA2-PSK
# wifi detect generates the UCI wireless config for the detected hardware
# (avoids hardcoding the PCIe sysfs path which varies per board revision).
# detect may set band=6g; CN has no 6 GHz WLAN channels, so pin 5g after import.
#
# channel and htmode are pinned to the combination that came up on the bench
# (issue #46). Do not restore channel='auto' or htmode='HE80':
#   - channel='auto' makes hostapd sweep the band with ACS, and the wider modes
#     reach DFS channels that then need a CAC pass. Both keep the MCU busy, and
#     this board froze rtnl during AP bring-up under that configuration: SSH went
#     down with it and only a power cycle brought the radio back.
#   - ch36 + HE40 is non-DFS, needs no ACS sweep, and did come up.
# country is pinned here rather than left to whatever `wifi detect` imports.
#
# disabled=1 is the committed persistent state (issue #50). Every-boot init
# overlays disabled=1 before netifd (S20), then after 30s sets disabled=0 and
# runs wifi up without committing, so a later boot still starts with the radio
# down. Do not commit disabled=0 from that init.
#
# There is deliberately no txpower line: the radio reports 3 dBm and neither a
# uci setting nor `iw ... set txpower fixed` moves it, so writing one here would
# state a value the hardware does not honour. 3 dBm covers the roughly 15 m of
# line of sight this AP is for.
wifi detect | uci -m import wireless
uci set wireless.radio0.disabled=1
uci set wireless.radio0.band='5g'
uci set wireless.radio0.channel='36'
uci set wireless.radio0.htmode='HE40'
uci set wireless.radio0.country='CN'
uci set wireless.default_radio0.ssid='outdoor-backup'
uci set wireless.default_radio0.encryption='psk2'
uci set wireless.default_radio0.key='Outdoor5gCheck'
uci commit wireless
exit 0
SCRIPT

chmod +x package/base-files/files/etc/uci-defaults/99-wireless-r5s-outdoor
echo "==> Added wireless UCI defaults: 99-wireless-r5s-outdoor (SSID: outdoor-backup, 5g ch36 HE40 psk2, disabled=1)"

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

cat > package/base-files/files/etc/init.d/r5s-outdoor-boot << 'SCRIPT'
#!/bin/sh /etc/rc.common
# r5s-outdoor every-boot: ASPM L1, radio held down until delayed wifi up, netdata
# stopped after S99. Issue #50.
#
# START=15 is after S10 boot (uci-defaults, wifi config) and before S20 netifd.
# prepare_rootfs enables rc.common inits, so the image gets S15r5s-outdoor-boot
# without a hand-made rc.d symlink.
#
# Do not uci commit wireless from this script. Committing disabled=0 would make
# the next boot bring the AP up at S20 and drop the delay.

START=15

start() {
	if [ -f /sys/module/pcie_aspm/parameters/policy ]; then
		printf 'powersave\n' > /sys/module/pcie_aspm/parameters/policy
	else
		logger -t r5s-outdoor-boot 'pcie_aspm policy sysfs missing; skipping ASPM powersave'
	fi

	# Runtime overlay so a preserved wireless (disabled=0) cannot race S20.
	uci -q set wireless.radio0.disabled=1

	(
		sleep 30
		if [ -x /etc/init.d/netdata ]; then
			/etc/init.d/netdata disable
			/etc/init.d/netdata stop
		fi
		uci -q set wireless.radio0.disabled=0
		wifi up
		logger -t r5s-outdoor-boot 'delayed wifi up after 30s; netdata stopped if present'
	) &
}
SCRIPT

chmod +x package/base-files/files/etc/init.d/r5s-outdoor-boot
echo "==> Added every-boot init: r5s-outdoor-boot (ASPM powersave, delayed wifi up, netdata stop)"
