# SPDX-License-Identifier: GPL-2.0-only
#
# Csing-box - a simplified homeproxy client
# Based on luci-app-homeproxy (C) 2022-2025 ImmortalWrt.org

include $(TOPDIR)/rules.mk

LUCI_TITLE:=Csing-box - Simplified homeproxy client
LUCI_PKGARCH:=all
# sing-box core compatibility: config generation targets 1.15.x (native TUN stack, no `stack`
# option; verified against 1.15.0-alpha.3). Replace /usr/bin/sing-box if the bundled core is older.
LUCI_DEPENDS:= \
	+sing-box \
	+firewall4 \
	+kmod-tun \
	+kmod-nft-queue \
	+kmod-nfnetlink-queue \
	+ucode-mod-digest

PKG_NAME:=luci-app-csing-box
PKG_VERSION:=1.2.1
PKG_RELEASE:=3

# luci.mk derives the translation package version from the feed's git history; this
# package is not part of that history, so pin it explicitly instead of getting "0".
PKG_PO_VERSION:=$(PKG_VERSION)-r$(PKG_RELEASE)

define Package/luci-app-csing-box/conffiles
/etc/config/csingbox
/etc/csingbox/certs/
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
