# SPDX-License-Identifier: GPL-2.0-only
#
# Csing-box - a simplified homeproxy client
# Based on luci-app-homeproxy (C) 2022-2025 ImmortalWrt.org

include $(TOPDIR)/rules.mk

LUCI_TITLE:=Csing-box - Simplified homeproxy client
LUCI_PKGARCH:=all
# sing-box core compatibility: config generation supports 1.12.x - 1.13.x (verified with 1.13.16)
# If the bundled sing-box is outdated, manually replace /usr/bin/sing-box with the 1.13.16 binary
LUCI_DEPENDS:= \
	+sing-box \
	+firewall4 \
	+kmod-nft-tproxy \
	+ucode-mod-digest

PKG_NAME:=luci-app-csing-box
PKG_VERSION:=1.1.6
PKG_RELEASE:=1

define Package/luci-app-csing-box/conffiles
/etc/config/csingbox
/etc/csingbox/certs/
/etc/csingbox/resources/direct_list.txt
/etc/csingbox/resources/proxy_list.txt
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
