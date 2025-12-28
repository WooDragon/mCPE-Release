#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#
# Copyright (c) 2019-2024 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

# --- Start: Add UCI Defaults script for custom settings ---

# Create the uci-defaults directory within the base-files package structure
mkdir -p package/base-files/files/etc/uci-defaults

# Create the uci-defaults script file (e.g., 99-custom-settings)
cat <<EOF > package/base-files/files/etc/uci-defaults/99-custom-settings
#!/bin/sh
# Set the LAN IP address
uci set network.lan.ipaddr='192.168.233.1'
uci commit network
# Set the system hostname
uci set system.@system[0].hostname='MCPE'
uci commit system
# Exit successfully
exit 0
EOF

# Make the uci-defaults script executable
chmod +x package/base-files/files/etc/uci-defaults/99-custom-settings

echo "Added UCI Defaults script: package/base-files/files/etc/uci-defaults/99-custom-settings"

# --- End: Add UCI Defaults script ---

# Modify default theme
sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile
sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci-ssl-nginx/Makefile
sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci-nginx/Makefile

# Change Password
sed -i 's@root.*@root:$1$4Y0U89hL$FJkkEvZLUkiL4bwuwiPRJ/:19216:0:99999:7:::@g' package/base-files/files/etc/shadow

# Env
sed -i '/export PATH="%PATH%"/a export TERM=xterm' package/base-files/files/etc/profile

# SSH
sed -i "s/'22'/'65422'/g" package/network/services/dropbear/files/dropbear.config
sed -i "s/RootPasswordAuth 'on'/RootPasswordAuth 'off'/g" package/network/services/dropbear/files/dropbear.config
sed -i "s/PasswordAuth 'on'/PasswordAuth 'off'/g" package/network/services/dropbear/files/dropbear.config
sed -i "s/option Interface    'lan'/#option Interface    'lan'/g" package/network/services/dropbear/files/dropbear.config
mkdir -p package/base-files/files/etc/dropbear
echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDBwECtUHN6VDe8QFmlgNm4meZ32VP9JiIEH0+wo3eh+Gs2dibZGJKzPBsQM3XphfailDgYiZbTHfKzNCpAk+SnvcwIPXy8wZ1AwWjN9Jf6qULeI8VI84Ik0cDa9byI5S99894gAh9Um7Jo34ns2REdCLrdABa37E/ZgiJJVtWblxHSlMAfr9vbmFjTETe1rD7L3FbytBLbExo3wylb2+eLwPRtaDdShFDLJJFd5PRTIVYKACXfaywdODAX0WCa09yIm29b0lGuaAukPk0rzSpyN5dG/muevQ3LpNt/r5jPkEwcPerHHSoDRgxvhLe8QO01izhbUugWJ3LFvr15M9Qd" > package/base-files/files/etc/dropbear/authorized_keys

# Firewall
append_content='# Allow WAN SSH on 65422
config rule
        option name             Allow-WAN-SSH
        option src              wan
        option proto            tcp
        option dest_port        65422
        option target           ACCEPT
        option family           ipv4'
echo "$append_content" >> "package/network/config/firewall/files/firewall.config"

#Sysctl
append_content='net.ipv4.ip_forward=1
net.ipv4.tcp_congestion_control = bbr
net.ipv4.conf.default.rp_filter=0
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter = 0
net.core.rmem_max = 4000000
net.netfilter.nf_conntrack_max = 2000000
net.netfilter.nf_conntrack_buckets = 250000
net.netfilter.nf_conntrack_generic_timeout = 60
net.netfilter.nf_conntrack_tcp_timeout_established = 1800
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 120
net.netfilter.nf_conntrack_tcp_timeout_syn_recv=30
net.netfilter.nf_conntrack_tcp_timeout_syn_sent=60
net.netfilter.nf_conntrack_udp_timeout_stream=60
net.ipv4.tcp_fastopen=3
net.ipv4.conf.all.route_localnet=1'
echo "$append_content" >> "package/base-files/files/etc/sysctl.conf"

#Nginx conf template
sed -i 's/client_max_body_size 128M;/client_max_body_size 1024M;/g' feeds/packages/net/nginx-util/files/uci.conf.template

# NOTE: uwsgi upgrade logic removed after ImmortalWRT migration
# ImmortalWRT uses official openwrt/packages which already has uwsgi 2.0.30+
# with full Python 3.11+ compatibility. No manual patching required.

# --- ImmortalWRT Migration: Clean up incompatible packages ---
# These packages were from kenzok8 feeds and are not available in ImmortalWRT
# or should be replaced with native alternatives

if [ -f ".config" ]; then
  echo "Cleaning up incompatible packages for ImmortalWRT migration..."

  # Disable turboacc and shortcut-fe (replaced by native nft-offload)
  sed -i 's/CONFIG_PACKAGE_luci-app-turboacc=y/# CONFIG_PACKAGE_luci-app-turboacc is not set/g' .config
  sed -i 's/CONFIG_PACKAGE_luci-app-turboacc_INCLUDE_OFFLOADING=y/# CONFIG_PACKAGE_luci-app-turboacc_INCLUDE_OFFLOADING is not set/g' .config
  sed -i 's/CONFIG_PACKAGE_luci-app-turboacc_INCLUDE_BBR_CCA=y/# CONFIG_PACKAGE_luci-app-turboacc_INCLUDE_BBR_CCA is not set/g' .config
  sed -i 's/CONFIG_PACKAGE_kmod-shortcut-fe=y/# CONFIG_PACKAGE_kmod-shortcut-fe is not set/g' .config
  sed -i 's/CONFIG_PACKAGE_kmod-shortcut-fe-cm=y/# CONFIG_PACKAGE_kmod-shortcut-fe-cm is not set/g' .config
  sed -i 's/CONFIG_PACKAGE_luci-i18n-turboacc-zh-cn=y/# CONFIG_PACKAGE_luci-i18n-turboacc-zh-cn is not set/g' .config

  # Disable other kenzok8-specific packages that might cause issues
  sed -i 's/CONFIG_PACKAGE_luci-app-bypass=y/# CONFIG_PACKAGE_luci-app-bypass is not set/g' .config
  sed -i 's/CONFIG_PACKAGE_luci-app-vssr=y/# CONFIG_PACKAGE_luci-app-vssr is not set/g' .config
  sed -i 's/CONFIG_PACKAGE_luci-app-ssr-plus=y/# CONFIG_PACKAGE_luci-app-ssr-plus is not set/g' .config
  sed -i 's/CONFIG_PACKAGE_luci-app-passwall=y/# CONFIG_PACKAGE_luci-app-passwall is not set/g' .config
  sed -i 's/CONFIG_PACKAGE_luci-app-passwall2=y/# CONFIG_PACKAGE_luci-app-passwall2 is not set/g' .config

  # Enable native flow offloading (nftables-based)
  if ! grep -q "CONFIG_PACKAGE_kmod-nft-offload" .config; then
    echo "CONFIG_PACKAGE_kmod-nft-offload=y" >> .config
  fi

  echo "✓ Incompatible packages cleaned up"
fi

# --- Package Optimization: Remove unnecessary packages ---
# Goal: Reduce build time and firmware size by disabling unneeded packages

if [ -f ".config" ]; then
  echo "Optimizing package selection..."

  # Disable strongswan (IPSec VPN - not needed, keep WireGuard/OpenVPN)
  sed -i 's/CONFIG_PACKAGE_strongswan=y/# CONFIG_PACKAGE_strongswan is not set/g' .config
  sed -i 's/CONFIG_PACKAGE_strongswan-[a-z-]*=y/# &/g' .config

  # Disable Ruby runtime (no dependencies require it)
  sed -i 's/CONFIG_PACKAGE_ruby=y/# CONFIG_PACKAGE_ruby is not set/g' .config
  sed -i 's/CONFIG_PACKAGE_ruby-[a-z-]*=y/# &/g' .config
  sed -i 's/CONFIG_PACKAGE_libruby=y/# CONFIG_PACKAGE_libruby is not set/g' .config

  # Disable collectd (already have netdata for monitoring)
  sed -i 's/CONFIG_PACKAGE_collectd=y/# CONFIG_PACKAGE_collectd is not set/g' .config
  sed -i 's/CONFIG_PACKAGE_collectd-mod-[a-z-]*=y/# &/g' .config

  # Disable zabbix
  sed -i 's/CONFIG_PACKAGE_zabbix-[a-z-]*=y/# &/g' .config
  sed -i 's/CONFIG_PACKAGE_zabbix-[a-z-]*=m/# &/g' .config

  # Disable file sharing (Samba, FTP)
  sed -i 's/CONFIG_PACKAGE_samba[0-9]*-[a-z-]*=y/# &/g' .config
  sed -i 's/CONFIG_PACKAGE_samba[0-9]*-[a-z-]*=m/# &/g' .config
  sed -i 's/CONFIG_PACKAGE_vsftpd[a-z-]*=y/# &/g' .config
  sed -i 's/CONFIG_PACKAGE_vsftpd[a-z-]*=m/# &/g' .config
  sed -i 's/CONFIG_PACKAGE_luci-app-vsftpd=m/# CONFIG_PACKAGE_luci-app-vsftpd is not set/g' .config

  # Disable vlmcsd (KMS)
  sed -i 's/CONFIG_PACKAGE_vlmcsd=y/# CONFIG_PACKAGE_vlmcsd is not set/g' .config
  sed -i 's/CONFIG_PACKAGE_luci-app-vlmcsd=m/# CONFIG_PACKAGE_luci-app-vlmcsd is not set/g' .config
  sed -i 's/CONFIG_PACKAGE_luci-i18n-vlmcsd-zh-cn=m/# CONFIG_PACKAGE_luci-i18n-vlmcsd-zh-cn is not set/g' .config

  # Disable ZeroTier
  sed -i 's/CONFIG_PACKAGE_zerotier=y/# CONFIG_PACKAGE_zerotier is not set/g' .config
  sed -i 's/CONFIG_PACKAGE_luci-app-zerotier=y/# CONFIG_PACKAGE_luci-app-zerotier is not set/g' .config

  # Disable qBittorrent
  sed -i 's/CONFIG_PACKAGE_luci-app-qbittorrent[_a-z]*=y/# &/g' .config
  sed -i 's/CONFIG_PACKAGE_qBittorrent[a-z-]*=y/# &/g' .config
  sed -i 's/CONFIG_PACKAGE_qbittorrent=y/# CONFIG_PACKAGE_qbittorrent is not set/g' .config

  echo "✓ Package optimization complete"
fi
# --- End: Package Optimization ---
