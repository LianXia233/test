# OpenWrt 监控小屏 · ESP32-2432S028R

把一块 20 块钱的 **ESP32-2432S028R**（俗称 CYD / Cheap Yellow Display，2.8" 320×240 电阻触摸）
做成 OpenWrt 路由器的状态屏：**LVGL 9.6 + 全中文界面 + 五页监控 + 网页后台 + 配网 + 投屏接收**，
再配一个 **APK 格式的 LuCI 插件**，在路由器后台里看状态、遥控、把任意画面推到屏上。

![中文界面](OpenWrtMonitor/preview_cn.png)

---

## 仓库里有什么

| 目录 | 是什么 |
|---|---|
| [`OpenWrtMonitor/`](OpenWrtMonitor/) | **固件**。Arduino 工程，跑在 ESP32 上：采集路由器数据、画界面、开 HTTP/WS 服务、收投屏帧 |
| [`luci-app-esp32-screen/`](luci-app-esp32-screen/) | **OpenWrt 插件**（APK）。菜单挂在 `luci → admin/services/esp32-screen`，三个页面：状态 / 投屏 / 设置 |
| [`dist/`](dist/) | 打好的 zip，直接下载用 |

---

## 快速上手

### 1. 烧固件

```sh
cd OpenWrtMonitor
# 依赖：PlatformIO（pio），库在 platformio.ini 里声明（LVGL 9.6 / TFT_eSPI / ArduinoJson 7 / TJpg_Decoder）
# TFT_Touch 不在注册表里，按 platformio.ini 顶部注释 clone 到 lib/ 下
pio run -t upload
```

第一次开机屏幕会进**配网页**：手机连上它开的 AP，选你家 WiFi、输密码，
再填路由器 IP / ubus 账号，保存后它自己连过去开始采集。

默认 mDNS 名字 `openwrt-monitor.local`，HTTP 在 `:80`，投屏在 `:81`。

### 2. 装插件

```sh
cp -r luci-app-esp32-screen ~/openwrt/package/          # 或 feeds/luci/applications/
cd ~/openwrt && ./scripts/feeds update -a && ./scripts/feeds install -a
make menuconfig      # LuCI → 3. Applications → luci-app-esp32-screen
make package/luci-app-esp32-screen/compile V=s
```

产物 `bin/packages/<arch>/luci/luci-app-esp32-screen_1.0-r1.apk`。装完
`/etc/init.d/rpcd reload` + 清 `/tmp/luci-indexcache*`，菜单在 **服务 → ESP32 屏幕**。

### 3. 投屏

插件「投屏」页在浏览器里画一帧 320×240（内置概览/流量模板，或自己写 HTML），
转成 RGB565 直接 POST 到面板 `:81/draw_rgb565`。固件 6 秒收不到帧会自动退回监控界面。

协议细节（HTTP 端点、WebSocket 帧格式、LZ4 布局）见
[`OpenWrtMonitor/README.md` §7](OpenWrtMonitor/README.md)。

---

## 文档

| 文档 | 内容 |
|---|---|
| [CHANGELOG.md](CHANGELOG.md) | 更新日志：每个版本改了什么、为什么这么改 |
| [OpenWrtMonitor/README.md](OpenWrtMonitor/README.md) | 固件：硬件接线、编译、五个页面、WebUI、投屏协议、中文字体子集流水线、实现要点、排障、验证情况（13+1 节） |
| [luci-app-esp32-screen/README.md](luci-app-esp32-screen/README.md) | 插件：数据流、两种编译方式、UCI 键表、ubus 接口、占位符、排障、验证情况 |

---

## 几个不好踩的坑（已处理）

- **LVGL 8 → 9.6**：`lv_disp_drv_t` 全线换成 `lv_display_*`，flush 回调签名变了，
  `lv_tick_set_cb()` 要手动调（v9 没有 `LV_TICK_CUSTOM`）。
- **中文**：`pyftsubset` + `lv_font_conv` 做子集，3995 字形 ≈331KB flash；
  24px 字号必须只收 `0x20-0x7E`，否则 `line_height` 从 29 变 32，整套布局算式全错。
- **投屏不占帧缓冲**：ESP32 没 PSRAM，153,600 字节的整帧放不下，改成 64KB 环形窗口的
  **流式 LZ4 解码** + 行缓冲直出。
- **CORS**：LuCI 页面在路由器 `:80`，面板是另一台设备，不开放
  `Access-Control-Allow-Origin` 浏览器会直接拦掉请求。

---

## 许可

MIT，见 [LICENSE](LICENSE)。
