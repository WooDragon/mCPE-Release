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

# Modify default IP
sed -i 's/192.168.233.1/192.168.233.1/g' package/base-files/files/bin/config_generate

# Modify default theme
sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile

# Modify hostname
sed -i 's/OpenWrt/uCPE/g' package/base-files/files/bin/config_generate

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
