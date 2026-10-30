# 更新日志

本项目的全部显著变更都记录在这里。
格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号跟随固件 `OpenWrtMonitor.ino` 里的 `APP_VERSION`。

## [2.0.1] - 2026-10-31

实机（ESP32-2432S028R）联调后的一轮集中修复，编译产物 1.67MB（huge_app 分区，
Flash 52%，RAM 23.5%）。以下修复全部在真机上逐项验证。

### 修复

- **编译**：`CastFeed` typedef 提前到 include 之前——Arduino 的自动原型生成器会把
  `castReadBody()` 的原型提到生成文件最前面，typedef 声明晚了就报
  `'CastFeed' has not been declared`
- **屏幕**：`TFT_eSPI` 构造函数改传原生竖屏尺寸 `(240, 320)`。原来传横屏尺寸，
  `setRotation(1)` 交换后 `_width` 反而变成 240，`fillScreen`/LVGL flush 只能覆盖
  左侧 240 列，右侧 80 列永远停在 GRAM 上电垃圾（表现：右侧一条蓝白条纹）
- **字体**：`lv_conf.h` 打开 `LV_USE_FONT_COMPRESSED`。`lv_font_conv` 生成的字库
  位图是 RLE 压缩的（`font_dsc.bitmap_format = 1`），关掉后 LVGL 取不到任何字形，
  整个界面一个字都不画（图标是位图所以正常）
- **内存单位**：ubus `system info` 的 memory 字段本来就是字节，去掉多余的 `×1024`
  （1GB 内存的机器才会显示成 987GB）
- **负载单位**：ubus 的 load 是 16.16 定点数，除以 65536；并换算成**单核占用百分比**
  显示（核心数启动时从 `/proc/cpuinfo` 读取，约每分钟刷新，读不到按 1 核算），
  概览页进度条与系统页 1/5/15 分钟三档全部改为百分比
- **`/api/state` 内存单位**：mem/swap 字段改按契约输出 **KB**——内置网页后台和
  LuCI 插件都按 KB 解读（网页端还做 `×1024` 还原字节），固件却发的字节，
  两边的内存都显示成了 943GB。同时 `rtr` 增加 `cores` 字段，
  LuCI 状态页的负载同步改为单核百分比显示

### 配网 / 网络

- WiFi 扫描改用 Arduino **同步** `scanNetworks()`：异步版在这块板子上
  `SCAN_DONE` 事件收不到，`scanComplete()` 直接返回 -2，列表永远为空；
  保留原生 `esp_wifi_*` 兜底路径（缓冲区预分配、扫描返回后立即取记录，
  避免被 WiFi 事件任务抢先消费）
- ubus 登录与数据调用的响应统一改为 `getString()` 后解析：HTTPClient 的
  `getStream()` 在这条链路上是空的，一律报 `InvalidInput`
- 路由器账号页软键盘修复：补 `bg_opa`（本工程 `ui_clean` 默认背景全透明，
  只设 `bg_color` 的键盘整个不可见）、加高到 128px 便于点按、修"点哪个框
  键盘就输入哪个框"的回调取值 bug
- 新增**维护口**：串口收到 `D` 进入下载模式（`rtc_gpio_hold_en` 跨复位把 GPIO0
  钉在低电平再重启）。这块板 CH340 的 DTR 没接 GPIO0，esptool 的自动复位
  序列进不了 bootloader，有它之后刷机不用再按 BOOT 键

### 界面（宽度均按字体字形实测）

- 概览/流量页速率值降为 16px：24px 下 `"1.8MB/s"` 要 89px，半张卡只有 83px，
  实测必溢出；16px 下 `"999.9MB/s"` 也只占 77px
- 无线页客户端列表：MAC/主机名显式 180px 宽（`max_width + DOTS` 在 LVGL 9.6
  会退化成 WRAP，折成两行后行与行叠在一起），完整 17 字符 MAC 或 11 个汉字
  的设备名可整个显示；信号列精简为纯数值；速率胶囊放宽到 62px 容纳
  Wi-Fi 6 的 `"2402M"`
- 无线客户端列表加**缓存**：采集写暂存区、整轮全部成功才提交，失败沿用上一轮，
  不再闪"正在等待路由器数据…"；缓存命中时列表每 3 轮（约 9 秒）才真正刷一次，
  系统/流量数据仍是轮询间隔
- 客户端显示 **DHCP 主机名**（`luci-rpc getDHCPLeases`，MAC 大小写不敏感匹配），
  没有租约的设备回退显示 MAC；WebUI 的 `/api/state` 同步输出 `name` 字段
- 首页概览底部三格重排（"客户端"三个字 48px 装不进 58px 的格子）；
  修多射频时"已连接"总数被最后一个射频覆盖的 bug
- `ui_kv` 值超长从硬裁（CLIP）改为省略号（DOTS）

## [2.0.0] - 2026-10-29

### 首发功能

- **固件**：LVGL 9.6 全中文界面（3981 字子集字体）、五页监控
  （概览/系统/流量/无线/设置）、ubus 轮询采集、屏上配网（软键盘）、
  HTTP/WebSocket 服务、LuCI 投屏接收（RGB565 / LZ4 / JPEG）
- **LuCI 插件**：`luci-app-esp32-screen`（APK 格式），状态 / 投屏 / 设置三页
- **投屏**：LuCI 加 320×240 预览框 + 自定义数据，固件加推屏专用页

[2.0.1]: https://github.com/LianXia233/esp32-openwrt-screen/compare/011df5f...875654a
[2.0.0]: https://github.com/LianXia233/esp32-openwrt-screen/tree/011df5f
