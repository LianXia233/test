# luci-app-esp32-screen

[OpenWrtMonitor](../OpenWrtMonitor)（ESP32-2432S028R / "Cheap Yellow Display"）的 LuCI 界面。
面向 **OpenWrt 主线 24.10 / 25.12**，打包出来是 **APK** 格式。

三个页面：

| 菜单项 | 路径 | 干什么 |
|---|---|---|
| 状态 | `esp32-screen/status` | 显示面板采集到的路由器数据，外加遥控（切页 / 背光 / 采集周期 / 重启 / 退出投屏） |
| 投屏 | `esp32-screen/cast` | 在浏览器里画一帧 320×240，POST 到面板的 `:81/draw_rgb565` |
| 设置 | `esp32-screen/settings` | 面板在哪、默认模板、自定义 HTML、连续推送间隔 |

---

## 1. 数据流

面板是局域网里另一台设备，所以**能不走路由器就不走路由器**：

```
┌──────────────┐  ① fetch /api/state（浏览器直连，面板开了 CORS）
│   浏览器      │──────────────────────────────────→  面板 :80
│  （LuCI 页面）│  ② POST /api（切页/背光/重启…）  ──→  面板 :80
│              │  ③ POST :81/draw_rgb565（一帧 153,600 字节）→ 面板 :81
└──────┬───────┘
       │ ④ ubus luci.esp32-screen get / set     （只有「配置存哪」走路由器）
       │ ⑤ ubus luci.esp32-screen probe        （浏览器连不上屏时的兜底）
┌──────▼───────┐
│   路由器      │  rpcd + ucode 插件 → /etc/config/esp32screen
└──────────────┘
```

① 拿不到（跨 VLAN、从外网连 LuCI、混合内容被拦）就自动降级到 ⑤，
状态页上会显示「在线（经路由器中转）」还是「在线（浏览器直连）」。

---

## 2. 装

### 2.1 跟着固件树一起编

```sh
cp -r luci-app-esp32-screen ~/openwrt/package/luci-app-esp32-screen   # 或者 feeds/luci/applications/
cd ~/openwrt && ./scripts/feeds update -a && ./scripts/feeds install -a
make menuconfig      # LuCI → 3. Applications → luci-app-esp32-screen
make package/luci-app-esp32-screen/compile V=s
```

产物在 `bin/packages/<arch>/luci/luci-app-esp32-screen_1.0-r1.apk`（`CONFIG_USE_APK=y` 时）。

### 2.2 用 SDK 单独编

```sh
tar xf openwrt-sdk-*.tar.xz && cd openwrt-sdk-*
cp -r /path/to/luci-app-esp32-screen package/
./scripts/feeds update -a && ./scripts/feeds install -a
make menuconfig && make package/luci-app-esp32-screen/compile V=s
```

### 2.3 直接装到机器上

```sh
apk add luci-app-esp32-screen_1.0-r1.apk --allow-untrusted
/etc/init.d/rpcd reload     # ACL 是启动时加载的
rm -rf /tmp/luci-modulecache /tmp/luci-indexcache
```

浏览器硬刷新一次（`Ctrl+Shift+R`），菜单在 **服务 → ESP32 屏幕**。

---

## 3. 目录

```
luci-app-esp32-screen/
├── Makefile                                  # APK 打包规则（PKGARCH=all）
├── htdocs/luci-static/resources/
│   ├── esp32screen.js                        # 三个页面共用的「跟屏幕说话」工具
│   └── view/esp32-screen/{status,cast,settings}.js
├── root/
│   ├── etc/config/esp32screen                # UCI 默认值（conffile，升级保留）
│   ├── usr/share/luci/menu.d/luci-app-esp32-screen.json
│   ├── usr/share/rpcd/acl.d/luci-app-esp32-screen.json
│   └── usr/share/rpcd/ucode/luci.esp32-screen   # 后端
└── tools/test_ucode.py                       # 后端逻辑烟测（19 项）
```

---

## 4. UCI 配置（`/etc/config/esp32screen`）

**`config panel 'panel'`**

| 键 | 默认 | 说明 |
|---|---|---|
| `host` | 空 | 面板 IP 或主机名。空着就用下面的 mDNS 名字 |
| `mdns` | `openwrt-monitor` | 固件广播的名字；后端会拼成 `<mdns>.local` |
| `enabled` | `1` | 关掉之后插件不主动取状态 |
| `template` | `overview` | 投屏页默认选哪个模板：`overview` / `traffic` / `custom` |
| `custom_html` | 空 | 自定义模板的 HTML |
| `push_interval` | `4` | 连续推送间隔（秒）。固件 6 秒收不到帧会退回监控界面，所以会被夹在 1–5 |

**`config router 'router'`**（保存后下发给屏幕存在它自己的 EEPROM）

| 键 | 默认 | 说明 |
|---|---|---|
| `ip` | 空 | 路由器地址；空 = 屏幕用 WiFi 的 DHCP 网关 |
| `user` | `root` | 屏幕登录 ubus 用的用户名 |
| `password` | 空 | 同上密码 |

---

## 5. ubus 接口

```sh
# 读配置（host 会带上解析结果，host_source 告诉你这个地址是填的还是拼的）
ubus call luci.esp32-screen get
# → { "config": { "host": "openwrt-monitor.local", "host_source": "mdns", ... } }

# 写配置（键名白名单，别的键静默忽略；返回实际写了几个）
ubus call luci.esp32-screen set '{"values":{"host":"192.168.1.23","template":"traffic"}}'
# → { "ok": true, "changed": 2, "config": {...} }

# 让路由器自己去问面板（浏览器直连失败时的兜底）
ubus call luci.esp32-screen probe '{"host":"192.168.1.23"}'
# → { "state": { "rtr": {...}, "net": {...}, ... } }
# 或 { "error": "面板无响应（http://192.168.1.23/api/state）" }
```

`probe` 依次找 `uclient-fetch` → `curl` → `wget`，都没有就返回 `error` 而不抛异常。

---

## 6. 前端能用的占位符（自定义 HTML）

```
{{hostname}} {{model}} {{kernel}} {{uptime}} {{load1}} {{mem}}
{{dl}} {{ul}} {{clients}} {{wanip}} {{time}}
```

自定义 HTML 是用 SVG `foreignObject` 光栅化成位图的（浏览器里没有 html2canvas，
这是唯一不引依赖的办法）。**外链 CSS 和图片不会跟着进来**，样式请写成内联 `style`。

---

## 7. 排障

| 现象 | 查什么 |
|---|---|
| 菜单不出现 | `ls /usr/share/luci/menu.d/`；`rm /tmp/luci-indexcache*`；确认 ACL 文件在 `/usr/share/rpcd/acl.d/` |
| `Access denied` | `/etc/init.d/rpcd reload`；`ubus list \| grep esp32` |
| 状态一直「取不到」 | 先 `curl http://<屏>/api/state` 看面板活着没；再 `ubus call luci.esp32-screen probe` 看路由器够不够得着 |
| 投屏推不出去 | 浏览器控制台看 `:81/draw_rgb565` 的返回；面板侧串口会打印 `cast: ...` |
| 推一帧就退回监控页 | 连续推送间隔超过 5 秒了，固件 6 秒超时 |
| 设置页保存后屏幕没改 | 「下发给屏幕」要填密码才会推；`ubus call luci.esp32-screen get` 确认密码存住了 |

---

## 8. 验证情况

| 检查项 | 结果 |
|---|---|
| 4 个 JS 文件 `node --check` | 0 错误 |
| 2 个 JSON（menu.d / acl.d） | 解析通过 |
| ucode 后端 `tools/test_ucode.py` | **19/19 通过**（默认值回落、mDNS 拼接、类型转换、白名单、自动建段、probe 容错） |

真机上的 ubus 调用、菜单渲染和投屏推送尚未在本环境实测（沙箱里没有 OpenWrt 与面板）。
