include $(TOPDIR)/rules.mk

PKG_NAME:=podkop-autoswitch
PKG_VERSION:=0.1.3
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-or-later
PKG_MAINTAINER:=Podkop AutoSwitch contributors
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/podkop-autoswitch
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Sticky proxy failover for Podkop with LuCI
  DEPENDS:=+podkop +curl +jq +ucode +ucode-mod-fs +ca-bundle +luci-base +rpcd
endef

define Package/podkop-autoswitch/description
  Subscription pools, HTTPS health checks, sticky selector failover and a LuCI
  Services page. Runtime capabilities are checked before attaching to Podkop.
endef

define Package/podkop-autoswitch/conffiles
/etc/config/podkop-autoswitch
endef

define Build/Compile
endef

define Package/podkop-autoswitch/install
	$(CP) ./files/* $(1)/
	chmod 0755 $(1)/usr/bin/podkop-autoswitch $(1)/etc/init.d/podkop-autoswitch $(1)/usr/libexec/rpcd/podkop-autoswitch
	chmod 0600 $(1)/etc/config/podkop-autoswitch
endef

define Package/podkop-autoswitch/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
chmod 600 /etc/config/podkop-autoswitch
/etc/init.d/podkop-autoswitch enable
/etc/init.d/podkop-autoswitch restart
/etc/init.d/rpcd reload
exit 0
endef

define Package/podkop-autoswitch/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
case "$${1}" in upgrade|failed-upgrade) exit 0;; esac
/etc/init.d/podkop-autoswitch stop
if [ -f /etc/podkop-autoswitch/attachment.json ]; then
  /usr/bin/podkop-autoswitch detach || exit 1
fi
/etc/init.d/podkop-autoswitch disable
exit 0
endef

$(eval $(call BuildPackage,podkop-autoswitch))
