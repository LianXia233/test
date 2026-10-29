# luci-app-esp32-screen —— ESP32-2432S028R（CYD）监控屏的 LuCI 界面
#
# 面向 OpenWrt 主线（24.10 / 25.12，apk 包格式）。没有 C 代码要编，
# 纯粹装文件：JS 视图 + rpcd ucode 后端 + UCI 默认配置 + ACL + 菜单项。
#
# 放到 feeds/luci/applications/luci-app-esp32-screen 或
# package/luci-app-esp32-screen 都可以，make menuconfig 里在
#   LuCI -> 3. Applications -> luci-app-esp32-screen
# 选上。CONFIG_USE_APK=y 时编出来的就是 .apk。

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-esp32-screen
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_ARCH:=all

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=
PKG_MAINTAINER:=OpenWrtMonitor contributors

PKG_FLAGS:=nonshared

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI interface for the ESP32 monitor screen
  DEPENDS:=+luci-base +rpcd-mod-ucode +uclient-fetch
  PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
  Web UI for the ESP32-2432S028R (Cheap Yellow Display) OpenWrt monitor panel.

  Three views:
    status    - what the panel sees, plus remote controls (page / brightness /
                poll interval / reboot / exit cast)
    cast      - push a 320x240 frame to the panel (built-in templates or your
                own HTML, rasterized in the browser)
    settings  - where the panel lives, which template to open by default

  The panel is a separate device on the LAN, so the browser talks to it
  directly (the firmware sets Access-Control-Allow-Origin). ubus is only used
  for the config itself and for the server-side probe fallback.
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/esp32-screen
	$(INSTALL_DATA) $(CURDIR)/htdocs/luci-static/resources/esp32screen.js \
		$(1)/www/luci-static/resources/esp32screen.js
	$(INSTALL_DATA) $(CURDIR)/htdocs/luci-static/resources/view/esp32-screen/*.js \
		$(1)/www/luci-static/resources/view/esp32-screen/

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) $(CURDIR)/root/etc/config/esp32screen \
		$(1)/etc/config/esp32screen

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) $(CURDIR)/root/usr/share/luci/menu.d/*.json \
		$(1)/usr/share/luci/menu.d/

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) $(CURDIR)/root/usr/share/rpcd/acl.d/*.json \
		$(1)/usr/share/rpcd/acl.d/

	$(INSTALL_DIR) $(1)/usr/share/rpcd/ucode
	$(INSTALL_DATA) $(CURDIR)/root/usr/share/rpcd/ucode/luci.esp32-screen \
		$(1)/usr/share/rpcd/ucode/luci.esp32-screen
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/esp32screen
endef

# rpcd 每次调用都会重新去 /usr/share/rpcd/ucode 读脚本，插件不用重启；
# 但 acl.d 是启动时加载的，所以这里补一次 reload。
define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/rpcd reload >/dev/null 2>&1 || true
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
