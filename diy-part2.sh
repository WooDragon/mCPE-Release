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

# Modify Basic setup
sed -i 's/192.168.1.1/192.168.233.1/g' package/base-files/files/bin/config_generate
sed -i 's/OpenWrt/MCPE/g' package/base-files/files/bin/config_generate

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