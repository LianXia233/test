/*
 * OpenWrtMonitor v2 — ESP32-2432S028R（CYD 2.8" / ILI9341 320x240）路由器监控面板
 * ================================================================================
 * 在原版（单页 dashboard + 配网页 + 登录页）基础上的重构：
 *
 *   1. 五页界面 + 顶部状态栏 + 底部导航
 *      概览 / 系统 / 流量 / 无线 / 设置，卡片式排版、深色玻璃拟态配色
 *      （配色与版式参考 esp32-lvgl9-home-panel，按 320x240 重新裁比例）
 *   2. 图标全部是内置 24x24 单色位图（ui_icons.h），运行时 recolor 改色
 *      选中蓝 / 未选中灰 / 告警红共用同一份数据，只占 flash 不占 RAM
 *   3. 内置 WebUI 后台（WebServer + SSE 推送 + mDNS）
 *      手机浏览器打开 http://<板子IP> 就能看到同样的数据，并能改 WiFi、
 *      路由器凭据、刷新周期、背光，还能让屏幕跟着网页切页
 *   4. ubus 轮询改成"每次 loop 只发一个请求"的分步状态机
 *      原版一轮连发 4~5 个同步请求，最长会卡住 10 秒以上 —— 期间触摸没反应、
 *      网页也打不开。现在每一步之间都会跑 lv_timer_handler() 和
 *      server.handleClient()，界面和网页始终是活的
 *   5. 背光 PWM 可调（屏幕上、网页上都能调），掉线自动重连，NTP 校时
 *
 * 采集的 ubus 对象（都是 OpenWrt 自带，不需要装任何插件）：
 *   system.board        主机名 / 型号 / 内核 / 固件版本
 *   system.info         负载、内存、运行时长
 *   network.interface   WAN 口 IP、协议、设备名
 *   network.device      各网口收发字节（据此算实时速率）
 *   iwinfo.assoclist    无线客户端（MAC / 信号 / 协商速率）
 *
 * 编译：见 README.md
 */

// ============================== 用户配置 ==============================
// 出厂留空：开机直接进配网页，选 WiFi、填路由器账号，存 EEPROM。
// 想固化某套参数再在这里填（填了就以这里为准，配网页会覆盖 EEPROM）。
String WIFI_SSID = "";
String WIFI_PASS = "";

// 路由器地址留空 = 用当前 WiFi 的 DHCP 网关（推荐）；要固定时再填
String OPENWRT_IP = "";
String OPENWRT_USER = "root";
String OPENWRT_PASS = "";

#define APP_NAME        "OpenWrt Monitor"
#define APP_VERSION     "2.0.0"
#define MDNS_NAME       "openwrt-monitor"      // http://openwrt-monitor.local
#define WEB_PORT        80
#define SSE_PORT        81                     // 事件推送单独一个端口（见 Web 段落注释）

#define POLL_DEFAULT_MS 3000
#define WIFI_TIMEOUT_MS 15000
#define UBUS_TIMEOUT_MS 2500                   // 单个 ubus 请求的上限
#define CHART_POINTS    40
// ======================================================================

#include <Arduino.h>
#include <EEPROM.h>
#include <ESPmDNS.h>
#include <HTTPClient.h>
#include <WebServer.h>
#include <WiFi.h>

/* ------------------------------------------------------------------ 内置符号中文化
 * LVGL 的 lv_keyboard / lv_textarea 键盘在系统里用 LV_SYMBOL_xxx 做特殊键
 * （确定、关闭、退格、换行、光标左移/右移、密码圆点）。这些宏默认是 FontAwesome
 * 私有区的码位 U+F00C 之类 —— 我们只打包了思源黑体，没有这些图形，键帽会变成
 * 一片方框。
 *
 * 好在 LVGL 内部是拿字符串做 lv_strcmp 来判断按了哪个键的（lv_keyboard.c 里
 * 全是 lv_strcmp(txt, LV_SYMBOL_OK) 这种写法），显示和行为用的是同一个宏。
 * 所以只要赶在 <lvgl.h> 之前把这些宏改写成中文，键帽显示中文，判断逻辑还照样成立，
 * 不需要额外再打一份符号字体。所有用到的汉字都已在 ui_font_cn_16 子集里，
 * 可以用 tools/check_font.py 复核。 */
#ifndef LV_SYMBOL_OK
#define LV_SYMBOL_OK        "确定"   /* 回车/提交，LV_EVENT_READY */
#define LV_SYMBOL_CLOSE     "关闭"   /* 收起键盘，LV_EVENT_CANCEL */
#define LV_SYMBOL_KEYBOARD  "键盘"   /* 同上：CANCEL */
#define LV_SYMBOL_LEFT      "左移"   /* 光标左移 */
#define LV_SYMBOL_RIGHT     "右移"   /* 光标右移 */
#define LV_SYMBOL_BACKSPACE "退格"   /* 删一个字符 */
#define LV_SYMBOL_NEW_LINE  "换行"   /* 单行输入框上等价于提交 */
#define LV_SYMBOL_BULLET    "\xE2\x80\xA2"  /* 密码遮罩圆点 U+2022（UTF-8），已在子集里 */
#endif

/* 投屏帧回调：返回 false 中断接收。必须声明在 include 之前 —— Arduino 会把
   下面 castReadBody() 的原型自动提到文件最前面，typedef 晚了就找不到。 */
typedef bool (*CastFeed)(const uint8_t*, size_t, void*);

#include <ArduinoJson.h>
#include <TFT_Touch.h>
#include <TFT_eSPI.h>
#include <lvgl.h>

#include "ui_icons.h"
#include "ui_theme.h"
#include "webui_html.h"

#ifndef ESP_ARDUINO_VERSION_MAJOR
#define ESP_ARDUINO_VERSION_MAJOR 2
#endif

/* 前向声明：多个页面构建函数互相引用 */
void showProvisioning();
void showRouterScreen();
void navGoto(int p);

/* ------------------------------------------------------------------ JSON 兼容层
 * ArduinoJson 6 用 DynamicJsonDocument(cap)，7 起统一成 JsonDocument（自动扩容）。
 * 用下面两个宏写一次代码，两个大版本都能编。 */
#if ARDUINOJSON_VERSION_MAJOR >= 7
using JsonDoc = JsonDocument;
#define JDOC_CAP(n)
#else
using JsonDoc = DynamicJsonDocument;
#define JDOC_CAP(n) (n)
#endif

// ============================== 硬件 ==============================
static const uint16_t SCREEN_W = 320;
static const uint16_t SCREEN_H = 240;

TFT_eSPI tft = TFT_eSPI(SCREEN_W, SCREEN_H);

#define TP_CS   33
#define TP_CLK  25
#define TP_DIN  32
#define TP_DOUT 39
TFT_Touch touch = TFT_Touch(TP_CS, TP_CLK, TP_DIN, TP_DOUT);

#define PIN_BL 21                          // 背光（PWM 调光）

#define LV_BUF_LINES 20                    // 20 行 ≈ 12.8KB
static lv_color_t lvBuf[SCREEN_W * LV_BUF_LINES];
static lv_display_t* disp = nullptr;      /* v9：显示设备句柄 */
static lv_indev_t* indev = nullptr;       /* v9：输入设备句柄 */

static HTTPClient httpCli;                 // 常驻，避免每次请求都构造

// ============================== 配置存储 ==============================
#define EE_SIZE        512
#define EE_MAGIC_ADDR  0
#define EE_SSID_ADDR   4
#define EE_PASS_ADDR   36
#define EE_OWIP_ADDR   100
#define EE_OWUSER_ADDR 132
#define EE_OWPASS_ADDR 164
#define EE_BRIGHT_ADDR 228
#define EE_POLL_ADDR   229
#define EE_MAGIC       0x4F575232UL        // "OWR2"

static uint8_t cfgBright = 100;
static uint16_t cfgPollMs = POLL_DEFAULT_MS;

static String eeReadStr(int addr, int maxLen) {
  String s;
  for (int i = 0; i < maxLen; i++) {
    uint8_t c = EEPROM.read(addr + i);
    if (c == 0 || c == 0xFF) break;      // 没写过的区域读出来是 0xFF
    s += (char)c;
  }
  return s;
}

static void eeWriteStr(int addr, const char* s, int maxLen) {
  int n = strlen(s);
  for (int i = 0; i < maxLen; i++) EEPROM.write(addr + i, i < n ? s[i] : 0);
}

static void saveWifi(const char* ssid, const char* pass) {
  EEPROM.writeUInt(EE_MAGIC_ADDR, EE_MAGIC);
  eeWriteStr(EE_SSID_ADDR, ssid, 32);
  eeWriteStr(EE_PASS_ADDR, pass, 64);
  EEPROM.commit();
}

static void saveRouterCfg(const char* ip, const char* user, const char* pass) {
  EEPROM.writeUInt(EE_MAGIC_ADDR, EE_MAGIC);
  eeWriteStr(EE_OWIP_ADDR, ip, 32);
  eeWriteStr(EE_OWUSER_ADDR, user, 32);
  eeWriteStr(EE_OWPASS_ADDR, pass, 64);
  EEPROM.commit();
}

static void savePrefs() {
  EEPROM.writeUInt(EE_MAGIC_ADDR, EE_MAGIC);
  EEPROM.write(EE_BRIGHT_ADDR, cfgBright);
  EEPROM.write(EE_POLL_ADDR, (uint8_t)constrain((int)((cfgPollMs - 1000) / 1000), 1, 4));
  EEPROM.commit();
}

static void loadConfig() {
  EEPROM.begin(EE_SIZE);
  if (EEPROM.readUInt(EE_MAGIC_ADDR) != EE_MAGIC) {
    Serial.println("[cfg] blank eeprom, using defaults");
    return;
  }
  String ssid = eeReadStr(EE_SSID_ADDR, 32);
  String pass = eeReadStr(EE_PASS_ADDR, 64);
  String ip = eeReadStr(EE_OWIP_ADDR, 32);
  String user = eeReadStr(EE_OWUSER_ADDR, 32);
  String opass = eeReadStr(EE_OWPASS_ADDR, 64);

  if (ssid.length()) { WIFI_SSID = ssid; WIFI_PASS = pass; }
  // 旧固件把写死的路由器地址当成"手动覆盖"存了下来，这里迁回网关模式
  if (ip == "192.168.10.1" || ip == "192.168.88.1") ip = "";
  if (ip.length()) OPENWRT_IP = ip;
  if (user.length()) OPENWRT_USER = user;
  if (opass.length()) OPENWRT_PASS = opass;

  uint8_t b = EEPROM.read(EE_BRIGHT_ADDR);
  if (b >= 10 && b <= 100) cfgBright = b;
  uint8_t p = EEPROM.read(EE_POLL_ADDR);
  if (p >= 1 && p <= 4) cfgPollMs = (uint16_t)(1000 + p * 1000);   // 2/3/4/5s

  Serial.printf("[cfg] ssid='%s' ow='%s' bright=%u poll=%u\n",
                WIFI_SSID.c_str(), OPENWRT_IP.c_str(), cfgBright, cfgPollMs);
}

// ============================== 数据模型 ==============================
struct RouterData {
  bool valid = false;                 // 至少成功拉过一次
  bool online = false;                // 本轮是否成功
  char hostname[32] = "OpenWrt";
  char model[48] = "";
  char kernel[24] = "";
  char release[48] = "";
  uint32_t uptimeSec = 0;
  float load1 = 0, load5 = 0, load15 = 0;
  uint32_t memTotal = 0, memAvail = 0, memFree = 0, memBuffered = 0, memCached = 0;
  uint32_t swapTotal = 0, swapFree = 0;
  uint8_t memPct = 0;
} rtr;

struct NetData {
  bool valid = false;
  char iface[16] = "";
  char wanIp[20] = "";
  char proto[10] = "";
  uint64_t rxBytes = 0, txBytes = 0;
  float dl = 0, ul = 0;               // KB/s
  float peak = 0;                     // 图表上限（快上慢下）
  uint32_t linkMbps = 0;
} net;

#define MAX_CLIENTS 16
struct ClientItem {
  char mac[18];
  int8_t rssi;
  uint16_t rateMbps;
};
static ClientItem gClients[MAX_CLIENTS];
static int gClientCount = 0;          // 当前展示条数（<= MAX_CLIENTS）
static int gClientTotal = 0;          // 路由器报的总数
static bool gClientsValid = false;
static uint32_t clientsSig = 0;       // 无线列表内容指纹：变了才重建控件
static int gRadioCount = 0;
static char gRadios[4][12];

// ubus 会话
static String owIp;
static String ubusToken;
static uint32_t tokenAt = 0;
static const uint32_t TOKEN_TTL = 280000;

static bool timeReady = false;
static bool boardFresh = false;
static uint32_t boardAt = 0;

// ============================== 格式化小工具 ==============================
static void fmtBytes(char* b, size_t n, uint64_t v) {
  if (v < 1024ULL)                    snprintf(b, n, "%llu B", (unsigned long long)v);
  else if (v < 1024ULL * 1024)        snprintf(b, n, "%.0f KB", (double)v / 1024.0);
  else if (v < 1024ULL * 1024 * 1024) snprintf(b, n, "%.1f MB", (double)v / 1048576.0);
  else                                snprintf(b, n, "%.2f GB", (double)v / 1073741824.0);
}

/** KB/s -> "842 KB/s" / "1.24 MB/s" */
static void fmtRate(char* b, size_t n, float kb) {
  /* 不要空格：148 / 146px 的半张卡里，"1.8 MB/s" 会多出 8px 直接挤掉中文字 */
  if (kb < 1024.0f) snprintf(b, n, "%.0fKB/s", kb);
  else              snprintf(b, n, "%.1fMB/s", kb / 1024.0f);
}

/** 秒 -> "3d 04:21" / "04:21:07" */
static void fmtUptime(char* b, size_t n, uint32_t s) {
  uint32_t d = s / 86400;
  if (d > 0) snprintf(b, n, "%lu天%02lu:%02lu", (unsigned long)d,
                      (unsigned long)((s % 86400) / 3600), (unsigned long)((s % 3600) / 60));
  else       snprintf(b, n, "%02lu:%02lu", (unsigned long)(s / 3600), (unsigned long)((s % 3600) / 60));
}

// ============================== LVGL 驱动 ==============================
static void dispFlush(lv_display_t* d, const lv_area_t* area, uint8_t* px) {
  uint32_t w = lv_area_get_width(area);
  uint32_t h = lv_area_get_height(area);
  tft.startWrite();
  tft.setAddrWindow(area->x1, area->y1, w, h);
  tft.pushColors((uint16_t*)px, w * h, true);
  tft.endWrite();
  lv_display_flush_ready(d);
}

static volatile bool gTouchDown = false;
static volatile int gTouchX = 0, gTouchY = 0;

static void touchRead(lv_indev_t* drv, lv_indev_data_t* data) {
  (void)drv;
  if (!touch.Pressed()) {
    data->state = LV_INDEV_STATE_REL;
    gTouchDown = false;
  } else {
    int16_t x = touch.X(), y = touch.Y();
    data->state = LV_INDEV_STATE_PR;
    data->point.x = x;
    data->point.y = y;
    gTouchDown = true;
    gTouchX = x;
    gTouchY = y;
  }
}

// ============================== 背光 ==============================
static void setBacklight(uint8_t pct) {
  if (pct < 10) pct = 10;
  if (pct > 100) pct = 100;
  cfgBright = pct;
  uint32_t duty = (uint32_t)pct * 255 / 100;
#if ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcWrite(PIN_BL, duty);
#else
  ledcWrite(0, duty);
#endif
}

static void backlightInit() {
#if ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcAttach(PIN_BL, 20000, 8);            // 20kHz，避开可听频段
#else
  ledcSetup(0, 20000, 8);
  ledcAttachPin(PIN_BL, 0);
#endif
  setBacklight(cfgBright);
}

// ============================== ubus 客户端 ==============================
static void httpSetup(const String& url) {
  static WiFiClient cli;
  cli.stop();
  httpCli.setConnectTimeout(UBUS_TIMEOUT_MS);
  httpCli.setTimeout(UBUS_TIMEOUT_MS);
  httpCli.begin(cli, url);
  httpCli.addHeader("Content-Type", "application/json");
}

static bool ubusLogin() {
  if (!owIp.length()) {
    if (OPENWRT_IP.length()) {
      owIp = OPENWRT_IP;
    } else {
      String gw = WiFi.gatewayIP().toString();
      if (!gw.length() || gw == "0.0.0.0") return false;
      owIp = gw;
    }
  }
  if (ubusToken.length() && (millis() - tokenAt) < TOKEN_TTL) return true;

  httpSetup("http://" + owIp + "/ubus");

  JsonDoc req JDOC_CAP(384);
  req["jsonrpc"] = "2.0";
  req["id"] = 1;
  req["method"] = "call";
  JsonArray p = req.createNestedArray("params");
  p.add("00000000000000000000000000000000");
  p.add("session");
  p.add("login");
  JsonObject cred = p.createNestedObject();
  cred["username"] = OPENWRT_USER;
  cred["password"] = OPENWRT_PASS;
  String body;
  serializeJson(req, body);

  int code = httpCli.POST((uint8_t*)body.c_str(), body.length());
  if (code != 200) {
    Serial.printf("[ubus] login http %d\n", code);
    httpCli.end();
    return false;
  }
  // 登录响应带着整份 ACL（十几 KB），doc 要给足
  JsonDoc res JDOC_CAP(16384);
  DeserializationError err = deserializeJson(res, httpCli.getStream());
  httpCli.end();
  if (err) {
    Serial.printf("[ubus] login json %s\n", err.c_str());
    ubusToken = "";
    return false;
  }
  JsonArray r = res["result"];
  if (r.size() < 2 || r[0].as<int>() != 0) {
    Serial.printf("[ubus] login rejected rc=%d\n", r.size() ? r[0].as<int>() : -1);
    ubusToken = "";
    return false;
  }
  ubusToken = r[1]["ubus_rpc_session"].as<String>();
  tokenAt = millis();
  Serial.printf("[ubus] login ok %s as %s\n", owIp.c_str(), OPENWRT_USER.c_str());
  return ubusToken.length() > 0;
}

/**
 * 调一个 ubus 方法，rc==0 返回 true，结果在 out["result"][1]。
 * 注意不要把 result[1] 赋回 out 自己 —— 同一个内存池里自赋值会把池子写坏。
 */
static bool ubusInvoke(const char* obj, const char* method, const char* device, JsonDoc& out) {
  if (!ubusToken.length() || (millis() - tokenAt) > TOKEN_TTL) {
    if (!ubusLogin()) return false;
  }
  httpSetup("http://" + owIp + "/ubus");

  JsonDoc req JDOC_CAP(384);
  req["jsonrpc"] = "2.0";
  req["id"] = 2;
  req["method"] = "call";
  JsonArray p = req.createNestedArray("params");
  p.add(ubusToken);
  p.add(obj);
  p.add(method);
  JsonObject args = p.createNestedObject();
  if (device) args["device"] = device;
  String body;
  serializeJson(req, body);

  int code = httpCli.POST((uint8_t*)body.c_str(), body.length());
  if (code != 200) {
    Serial.printf("[ubus] %s.%s http %d\n", obj, method, code);
    httpCli.end();
    ubusToken = "";                       // 多半是会话过期，下轮重登
    return false;
  }
  DeserializationError err = deserializeJson(out, httpCli.getStream());
  httpCli.end();
  if (err) {
    Serial.printf("[ubus] %s.%s json %s\n", obj, method, err.c_str());
    return false;
  }
  JsonArray r = out["result"];
  if (r.size() < 2 || r[0].as<int>() != 0) {
    Serial.printf("[ubus] %s.%s rc=%d\n", obj, method, r.size() ? r[0].as<int>() : -1);
    return false;
  }
  return true;
}

// ============================== 采集 ==============================
static bool fetchBoard() {
  JsonDoc d JDOC_CAP(1536);
  if (!ubusInvoke("system", "board", nullptr, d)) return false;
  JsonObject b = d["result"][1];
  snprintf(rtr.hostname, sizeof rtr.hostname, "%s", (const char*)(b["hostname"] | "OpenWrt"));
  snprintf(rtr.model, sizeof rtr.model, "%s", (const char*)(b["model"] | ""));
  snprintf(rtr.kernel, sizeof rtr.kernel, "%s", (const char*)(b["kernel"] | ""));
  JsonObject rel = b["release"];
  const char* desc = rel["description"] | "";
  if (!strlen(desc)) desc = rel["version"] | "";
  snprintf(rtr.release, sizeof rtr.release, "%s", desc);
  boardFresh = true;
  boardAt = millis();
  return true;
}

static bool fetchSystem() {
  JsonDoc d JDOC_CAP(2048);
  if (!ubusInvoke("system", "info", nullptr, d)) return false;
  JsonObject si = d["result"][1];
  rtr.uptimeSec = si["uptime"] | 0U;
  JsonArray ld = si["load"];
  rtr.load1 = ld[0] | 0.0f;
  rtr.load5 = ld[1] | 0.0f;
  rtr.load15 = ld[2] | 0.0f;
  JsonObject m = si["memory"];
  rtr.memTotal = m["total"] | 0U;
  rtr.memAvail = m["available"] | (m["free"] | 0U);
  rtr.memFree = m["free"] | 0U;
  rtr.memBuffered = m["buffered"] | 0U;
  rtr.memCached = m["cached"] | 0U;
  rtr.swapTotal = m["swap_total"] | 0U;
  rtr.swapFree = m["swap_free"] | 0U;
  if (rtr.memTotal && rtr.memAvail <= rtr.memTotal) {
    rtr.memPct = (uint8_t)((uint64_t)(rtr.memTotal - rtr.memAvail) * 100 / rtr.memTotal);
  }
  return true;
}

/** WAN 口：找带默认路由的那个 interface，取 IP 与设备名 */
static bool fetchInterface() {
  JsonDoc d JDOC_CAP(12288);
  if (!ubusInvoke("network.interface", "dump", nullptr, d)) return false;
  JsonArray list = d["result"][1]["interface"];
  for (JsonObject it : list) {
    if (!(it["up"] | false)) continue;
    bool def = false;
    for (JsonObject rt : it["route"].as<JsonArray>()) {
      if ((strcmp(rt["target"] | "", "0.0.0.0") == 0) && ((rt["mask"] | 0U) == 0U)) { def = true; break; }
    }
    if (!def) continue;
    JsonArray addrs = it["ipv4-address"];
    if (addrs.size()) snprintf(net.wanIp, sizeof net.wanIp, "%s", (const char*)(addrs[0]["address"] | ""));
    snprintf(net.proto, sizeof net.proto, "%s", (const char*)(it["proto"] | ""));
    const char* dev = it["l3_device"] | "";
    if (!strlen(dev)) dev = it["device"] | "";
    snprintf(net.iface, sizeof net.iface, "%s", dev);
    break;
  }
  return true;
}

/** 各网口累计字节；顺便记下 wlan 设备名，并挑一个上行口算速率 */
static bool fetchDevices() {
  JsonDoc d JDOC_CAP(14336);
  if (!ubusInvoke("network.device", "status", nullptr, d)) return false;
  JsonObject devs = d["result"][1];

  String wanName, bestEth, bestOther;
  uint64_t bestEthBytes = 0, bestOtherBytes = 0;
  gRadioCount = 0;

  for (JsonPair kv : devs) {
    String name = kv.key().c_str();
    if (name == "lo") continue;
    JsonObject o = kv.value();
    String dtype = o["devtype"] | "";
    if (dtype == "wlan" && gRadioCount < 4) {
      snprintf(gRadios[gRadioCount], sizeof gRadios[0], "%s", name.c_str());
      gRadioCount++;
    }
    if (!(o["up"] | false)) continue;
    if (name.indexOf("wan") >= 0 || name.indexOf("pppoe") >= 0) wanName = name;
    if (dtype == "bridge") continue;
    uint64_t bytes = (o["statistics"]["rx_bytes"] | 0ULL) + (o["statistics"]["tx_bytes"] | 0ULL);
    if (dtype == "ethernet") {
      if (bytes > bestEthBytes) { bestEthBytes = bytes; bestEth = name; }
    } else if (bytes > bestOtherBytes) {
      bestOtherBytes = bytes; bestOther = name;
    }
  }

  // 上行口优先级：
  //   1) network.interface 报的 l3_device（最准，就是承载 WAN 的那块网口）
  //   2) 名字里带 wan / pppoe 的设备
  //   3) 最忙的有线口 > 最忙的其他口
  // 都不用 br-lan 之类的网桥：那是 LAN 侧，算出来会反向且接近 0。
  String pick;
  if (net.iface[0] && devs.containsKey(net.iface) && (devs[net.iface]["up"] | false)
      && String((const char*)(devs[net.iface]["devtype"] | "")) != "bridge") {
    pick = net.iface;
  } else if (wanName.length()) {
    pick = wanName;
  } else if (bestEth.length()) {
    pick = bestEth;
  } else {
    pick = bestOther;
  }
  if (!pick.length()) return false;
  snprintf(net.iface, sizeof net.iface, "%s", pick.c_str());

  JsonObject dev = devs[pick];
  uint64_t rx = dev["statistics"]["rx_bytes"] | 0ULL;
  uint64_t tx = dev["statistics"]["tx_bytes"] | 0ULL;

  static uint64_t prevRx = 0, prevTx = 0;
  static uint32_t prevMs = 0;
  static bool havePrev = false;

  uint32_t now = millis();
  if (havePrev && now > prevMs && rx >= prevRx && tx >= prevTx) {
    uint32_t dt = now - prevMs;
    net.dl = (float)(rx - prevRx) * 1000.0f / (float)dt / 1024.0f;
    net.ul = (float)(tx - prevTx) * 1000.0f / (float)dt / 1024.0f;
  }
  prevRx = rx; prevTx = tx; prevMs = now; havePrev = true;

  net.rxBytes = rx;
  net.txBytes = tx;

  // 图表上限做"快上慢下"，否则会一直卡在历史峰值
  float m = net.dl > net.ul ? net.dl : net.ul;
  if (m * 1.3f > net.peak) net.peak = m * 1.3f;
  else net.peak *= 0.99f;
  if (net.peak < 64) net.peak = 64;

  const char* spd = dev["speed"] | "";
  net.linkMbps = (uint32_t)atoi(spd);
  return true;
}

static bool fetchClients(int radioIdx) {
  if (radioIdx < 0 || radioIdx >= gRadioCount) return false;
  JsonDoc d JDOC_CAP(3072);
  if (!ubusInvoke("iwinfo", "assoclist", gRadios[radioIdx], d)) return false;
  JsonArray res = d["result"][1]["results"];
  if (res.isNull()) return false;

  gClientTotal = res.size();
  for (JsonObject c : res) {
    if (gClientCount >= MAX_CLIENTS) break;
    ClientItem& it = gClients[gClientCount];
    snprintf(it.mac, sizeof it.mac, "%s", (const char*)(c["mac"] | ""));
    it.rssi = (int8_t)(c["signal"] | -100);
    // iwinfo 的速率单位不统一：有的固件给 bps(866700)，有的给 100kbps(8667)
    uint32_t r = c["rx"]["rate"] | 0U;
    if (r > 100000U)      it.rateMbps = (uint16_t)(r / 1000000U);
    else if (r > 1000U)   it.rateMbps = (uint16_t)(r / 10U);
    else                  it.rateMbps = (uint16_t)r;
    gClientCount++;
  }
  gClientsValid = true;
  return true;
}

// ============================== 轮询状态机 ==============================
enum PollStep { PS_LOGIN, PS_BOARD, PS_SYSTEM, PS_IFACE, PS_DEV, PS_ASSOC, PS_DONE };

static PollStep pollStep = PS_DONE;
static int assocIdx = 0;

/* 界面要不要重画。所有会改界面的地方都置 true，由 loop() 收敛。
   放在这么靠前是因为投屏那一段退出时也要用到。 */
static bool uiDirty = true;

static void pollReset() { pollStep = PS_DONE; }

/** 开一轮新的采集：清掉上一轮的客户端列表，从第一个射频重新数 */
static void pollBeginCycle() {
  gClientCount = 0;
  gClientTotal = 0;
  gClientsValid = false;
  assocIdx = 0;
  pollStep = PS_LOGIN;
}

/** 每次 loop 推进一步；返回 true 表示这一轮刚结束 */
static bool pollStepOnce() {
  bool stepOk = true;
  switch (pollStep) {
    case PS_LOGIN:
      stepOk = ubusLogin();
      break;
    case PS_BOARD:
      if (!boardFresh || (millis() - boardAt) > 60000UL) stepOk = fetchBoard();
      break;
    case PS_SYSTEM:
      stepOk = fetchSystem();
      break;
    case PS_IFACE:
      stepOk = fetchInterface();
      break;
    case PS_DEV:
      stepOk = fetchDevices();
      break;
    case PS_ASSOC:
      // 每个射频一次请求；没拉完就停在这一步，下一个 loop 继续
      if (assocIdx < gRadioCount) {
        fetchClients(assocIdx);
        assocIdx++;
        return false;
      }
      break;
    default:
      break;
  }

  if (!stepOk && pollStep == PS_LOGIN) {
    pollStep = PS_DONE;                  // 登录失败就收工，别连着打 5 个请求
    rtr.online = false;
    return true;
  }

  pollStep = (PollStep)(pollStep + 1);
  if (pollStep >= PS_DONE) {
    pollStep = PS_DONE;
    rtr.online = true;
    rtr.valid = true;
    net.valid = true;
    return true;
  }
  return false;
}

// ============================== WiFi ==============================
static void wifiBegin(const String& ssid, const String& pass) {
  owIp = "";                            // 重连后重新解析网关
  ubusToken = "";
  boardFresh = false;
  pollReset();
  WiFi.begin(ssid.c_str(), pass.c_str());
  Serial.printf("[wifi] begin '%s'\n", ssid.c_str());
}

static bool mdnsDone = false;

static void onWifiUp() {
  Serial.printf("[wifi] up ip=%s gw=%s\n", WiFi.localIP().toString().c_str(),
                WiFi.gatewayIP().toString().c_str());
  if (!timeReady) {
    configTime(8 * 3600, 0, "ntp1.aliyun.com", "ntp2.aliyun.com", "pool.ntp.org");
    timeReady = true;
  }
  if (!mdnsDone) {                       // mDNS 必须等有 IP 才能起
    if (MDNS.begin(MDNS_NAME)) {
      MDNS.addService("http", "tcp", WEB_PORT);
      mdnsDone = true;
      Serial.printf("[web] mdns %s.local\n", MDNS_NAME);
    }
  }
}

// ============================== 界面骨架 ==============================
static lv_obj_t* scrMain = nullptr;
static lv_obj_t* panels[5] = {nullptr};
static int curPage = 0;

/* 投屏页实现在文件后半段的「投屏接收」里，这里先声明：
   设置页的入口按钮和 /api 的 {"c":"ui","id":5} 都要用 */
static lv_obj_t* scrCast = nullptr;      // 推屏专用页（整屏，无状态栏/导航栏）
static void castPageOpen();
static void castPageClose();

static lv_obj_t* navItem[5] = {nullptr};
static lv_obj_t* navIcon[5] = {nullptr};
static lv_obj_t* navText[5] = {nullptr};
static lv_obj_t* navLine[5] = {nullptr};

static lv_obj_t* lblSbSsid = nullptr;
static lv_obj_t* lblSbClock = nullptr;
static lv_obj_t* sbDot = nullptr;
static lv_obj_t* sbStatus = nullptr;

// 概览
static lv_obj_t* hLoad = nullptr, *hLoadBar = nullptr, *hMem = nullptr, *hMemBar = nullptr;
static lv_obj_t* hDl = nullptr, *hUl = nullptr, *hDev = nullptr;
static lv_obj_t* hClients = nullptr, *hWan = nullptr, *hUp = nullptr;

// 系统
static lv_obj_t* sHost = nullptr, *sModel = nullptr, *sKernel = nullptr, *sRelease = nullptr;
static lv_obj_t* sL1 = nullptr, *sL5 = nullptr, *sL15 = nullptr;
static lv_obj_t* sMemBar = nullptr, *sMemTxt = nullptr, *sSwapTxt = nullptr;
static lv_obj_t* sEspHeap = nullptr, *sEspRssi = nullptr, *sEspIp = nullptr, *sEspUp = nullptr;

// 流量
static lv_obj_t* chartNet = nullptr;
static lv_chart_series_t* serDl = nullptr;
static lv_chart_series_t* serUl = nullptr;
static lv_obj_t* nDl = nullptr, *nUl = nullptr, *nPeak = nullptr;
static lv_obj_t* nLine1 = nullptr, *nLine2 = nullptr;
static int chartRange = 0;

// 无线
static lv_obj_t* wCount = nullptr, *wRadio = nullptr, *wList = nullptr;

// 设置
static lv_obj_t* cWeb = nullptr, *cBrightVal = nullptr, *cSlider = nullptr, *cSsidVal = nullptr, *cRtrVal = nullptr;

static const lv_image_dsc_t* NAV_ICONS[5] = {&ic_home, &ic_chip, &ic_flow, &ic_users, &ic_settings};
static const char* NAV_TEXT[5] = {"概览", "系统", "流量", "无线", "设置"};

void navGoto(int p);

static void navEvent(lv_event_t* e) {
  navGoto((int)(intptr_t)lv_event_get_user_data(e));
}

static void buildStatusBar(lv_obj_t* scr) {
  lv_obj_t* bar = lv_obj_create(scr);
  ui_clean(bar);
  lv_obj_set_pos(bar, 0, 0);
  lv_obj_set_size(bar, UI_W, UI_STATUS_H);
  ui_grad(bar, UI_C_BG, UI_C_BG_2);
  lv_obj_set_style_pad_hor(bar, 8, 0);
  lv_obj_set_flex_flow(bar, LV_FLEX_FLOW_ROW);
  lv_obj_set_flex_align(bar, LV_FLEX_ALIGN_SPACE_BETWEEN, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);

  lv_obj_t* left = lv_obj_create(bar);
  ui_clean(left);
  lv_obj_set_size(left, 180, LV_SIZE_CONTENT);
  lv_obj_set_flex_flow(left, LV_FLEX_FLOW_ROW);
  lv_obj_set_flex_align(left, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
  lv_obj_set_style_pad_column(left, 5, 0);

  lv_obj_t* i = ui_icon(left, &ic_router, UI_C_ACCENT);
  lv_image_set_pivot(i, 12, 12);
  lv_image_set_scale(i, 140);

  lblSbSsid = ui_label(left, "连接中", UI_F_XS, UI_C_TEXT_DIM);
  lv_label_set_long_mode(lblSbSsid, LV_LABEL_LONG_MODE_DOTS);
  lv_obj_set_style_max_width(lblSbSsid, 100, 0);

  sbDot = lv_obj_create(left);
  ui_clean(sbDot);
  lv_obj_set_size(sbDot, 6, 6);
  lv_obj_set_style_radius(sbDot, LV_RADIUS_CIRCLE, 0);
  lv_obj_set_style_bg_color(sbDot, ui_col(UI_C_WARN), 0);
  lv_obj_set_style_bg_opa(sbDot, LV_OPA_COVER, 0);

  lv_obj_t* right = lv_obj_create(bar);
  ui_clean(right);
  lv_obj_set_size(right, 106, LV_SIZE_CONTENT);
  lv_obj_set_flex_flow(right, LV_FLEX_FLOW_ROW);
  lv_obj_set_flex_align(right, LV_FLEX_ALIGN_END, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
  lv_obj_set_style_pad_column(right, 5, 0);

  sbStatus = ui_label(right, "等待", UI_F_XS, UI_C_TEXT_MUTE);
  lblSbClock = ui_label(right, "--:--", UI_F_S, UI_C_TEXT);
}

static void buildNavBar(lv_obj_t* scr) {
  lv_obj_t* bar = lv_obj_create(scr);
  ui_clean(bar);
  lv_obj_set_pos(bar, 0, UI_H - UI_NAV_H);
  lv_obj_set_size(bar, UI_W, UI_NAV_H);
  ui_grad(bar, UI_C_BG, UI_C_CARD);
  lv_obj_set_style_border_side(bar, LV_BORDER_SIDE_TOP, 0);
  lv_obj_set_style_border_width(bar, 1, 0);
  lv_obj_set_style_border_color(bar, ui_col(UI_C_BORDER), 0);
  lv_obj_set_style_border_opa(bar, LV_OPA_60, 0);
  lv_obj_set_flex_flow(bar, LV_FLEX_FLOW_ROW);
  lv_obj_set_flex_align(bar, LV_FLEX_ALIGN_SPACE_EVENLY, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);

  for (int i = 0; i < 5; i++) {
    lv_obj_t* it = lv_obj_create(bar);
    ui_clean(it);
    lv_obj_set_size(it, 62, UI_NAV_H - 4);
    lv_obj_set_flex_flow(it, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(it, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_row(it, 0, 0);
    lv_obj_set_style_radius(it, UI_RADIUS_S, 0);
    lv_obj_set_style_bg_color(it, ui_col(UI_C_ACCENT), LV_STATE_PRESSED);
    lv_obj_set_style_bg_opa(it, LV_OPA_20, LV_STATE_PRESSED);
    lv_obj_add_flag(it, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_event_cb(it, navEvent, LV_EVENT_CLICKED, (void*)(intptr_t)i);

    navLine[i] = lv_obj_create(it);
    ui_clean(navLine[i]);
    lv_obj_set_size(navLine[i], 18, 3);
    lv_obj_set_style_radius(navLine[i], LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(navLine[i], ui_col(UI_C_ACCENT), 0);
    lv_obj_set_style_bg_opa(navLine[i], LV_OPA_TRANSP, 0);

    navIcon[i] = ui_icon(it, NAV_ICONS[i], UI_C_TEXT_MUTE);
    lv_image_set_pivot(navIcon[i], 12, 12);
    lv_image_set_scale(navIcon[i], 171);        // 24 -> 16px，下面还要放一行两个汉字
    navText[i] = ui_label(it, NAV_TEXT[i], UI_F_XS, UI_C_TEXT_MUTE);

    navItem[i] = it;
  }
}

void navGoto(int p) {
  if (p < 0 || p > 4 || !scrMain) return;
  for (int i = 0; i < 5; i++) {
    if (!panels[i]) continue;
    if (i == p) lv_obj_clear_flag(panels[i], LV_OBJ_FLAG_HIDDEN);
    else        lv_obj_add_flag(panels[i], LV_OBJ_FLAG_HIDDEN);
  }
  curPage = p;
  for (int i = 0; i < 5; i++) {
    bool on = (i == p);
    lv_obj_set_style_bg_opa(navItem[i], on ? LV_OPA_20 : LV_OPA_TRANSP, 0);
    lv_obj_set_style_bg_color(navItem[i], ui_col(UI_C_ACCENT), 0);
    lv_obj_set_style_image_recolor(navIcon[i], ui_col(on ? UI_C_ACCENT : UI_C_TEXT_MUTE), 0);
    lv_obj_set_style_text_color(navText[i], ui_col(on ? UI_C_ACCENT : UI_C_TEXT_MUTE), 0);
    lv_obj_set_style_bg_opa(navLine[i], on ? LV_OPA_COVER : LV_OPA_TRANSP, 0);
  }
  if (p == 3) clientsSig = 0;      // 进无线页时强制重建列表
}

/** 新建页面容器（内容区），默认隐藏 */
static lv_obj_t* newPanel(bool scrollable) {
  lv_obj_t* p;
  if (scrollable) {
    p = ui_scroll_col(scrMain, UI_W - 2 * UI_PAD, UI_CONTENT_H - 2 * UI_PAD);
    lv_obj_set_pos(p, UI_PAD, UI_CONTENT_Y + UI_PAD);
    lv_obj_set_style_pad_all(p, 0, 0);
    lv_obj_set_style_pad_row(p, UI_GAP, 0);
  } else {
    p = lv_obj_create(scrMain);
    ui_clean(p);
    lv_obj_set_pos(p, UI_PAD, UI_CONTENT_Y + 4);
    lv_obj_set_size(p, UI_W - 2 * UI_PAD, UI_CONTENT_H - 4);
    lv_obj_set_flex_flow(p, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(p, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START);
    lv_obj_set_style_pad_row(p, 5, 0);
  }
  lv_obj_add_flag(p, LV_OBJ_FLAG_HIDDEN);
  return p;
}

// ============================== 页面：概览 ==============================
static void buildHome(lv_obj_t* p) {
  /* 行1 —— 处理器 / 内存：标题和大数值挤在同一行，下面一条进度条。
     中文行高 21、大字行高 29，一行放不下就横着排，别竖着堆。 */
  lv_obj_t* row1 = lv_obj_create(p);
  ui_clean(row1);
  lv_obj_set_size(row1, LV_PCT(100), 54);
  lv_obj_set_flex_flow(row1, LV_FLEX_FLOW_ROW);
  lv_obj_set_style_pad_column(row1, UI_GAP, 0);

  auto mkGauge = [](lv_obj_t* parent, const lv_image_dsc_t* ic, const char* cap, uint32_t col,
                    lv_obj_t** outVal, lv_obj_t** outBar) {
    lv_obj_t* c = ui_card(parent);
    lv_obj_set_size(c, 148, 54);
    lv_obj_set_style_pad_all(c, 6, 0);
    lv_obj_set_style_pad_row(c, 2, 0);
    lv_obj_t* t = lv_obj_create(c);
    ui_clean(t);
    lv_obj_set_size(t, LV_PCT(100), UI_LH_24);
    lv_obj_set_flex_flow(t, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(t, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_column(t, 4, 0);
    lv_obj_t* i = ui_icon(t, ic, col);
    lv_image_set_pivot(i, 12, 12);
    ui_icon_size(i, 15);
    ui_label(t, cap, UI_F_XS, UI_C_TEXT_DIM);
    lv_obj_t* sp = lv_obj_create(t);
    ui_clean(sp);
    lv_obj_set_flex_grow(sp, 1);
    lv_obj_set_height(sp, 1);
    *outVal = ui_label(t, "--", UI_F_NUM, UI_C_TEXT);
    *outBar = ui_bar(c, col);
  };
  mkGauge(row1, &ic_chip, "处理器", UI_C_ACCENT, &hLoad, &hLoadBar);
  mkGauge(row1, &ic_mem, "内存", UI_C_ACCENT_2, &hMem, &hMemBar);

  /* 行2 —— 下载 / 上传合成一张卡，左右各一半。
     分成两张 148 宽的卡时会各少 6px，24px 的大字就被挤成 "1.8M…"，合并才放得下。 */
  lv_obj_t* row2 = ui_card(p);
  lv_obj_set_size(row2, LV_PCT(100), 50);
  lv_obj_set_style_pad_all(row2, 6, 0);
  lv_obj_set_flex_flow(row2, LV_FLEX_FLOW_ROW);
  lv_obj_set_flex_align(row2, LV_FLEX_ALIGN_SPACE_BETWEEN, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
  auto mkRate = [](lv_obj_t* parent, const lv_image_dsc_t* ic, const char* cap, uint32_t col,
                   lv_obj_t** out) {
    lv_obj_t* t = lv_obj_create(parent);
    ui_clean(t);
    lv_obj_set_size(t, 146, UI_LH_24);
    lv_obj_set_flex_flow(t, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(t, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_column(t, 4, 0);
    lv_obj_t* i = ui_icon(t, ic, col);
    lv_image_set_pivot(i, 12, 12);
    ui_icon_size(i, 15);
    ui_label(t, cap, UI_F_XS, UI_C_TEXT_DIM);
    lv_obj_t* sp = lv_obj_create(t);
    ui_clean(sp);
    lv_obj_set_flex_grow(sp, 1);
    lv_obj_set_height(sp, 1);
    *out = ui_label(t, "--", UI_F_L, col);
  };
  mkRate(row2, &ic_down, "下载", UI_C_OK, &hDl);
  mkRate(row2, &ic_up, "上传", UI_C_WARM, &hUl);

  /* 行3 —— 客户端 / 外网 / 运行时长，横排三格 */
  lv_obj_t* row3 = ui_card(p);
  lv_obj_set_size(row3, LV_PCT(100), 40);
  lv_obj_set_style_pad_all(row3, 5, 0);
  lv_obj_set_flex_flow(row3, LV_FLEX_FLOW_ROW);
  lv_obj_set_flex_align(row3, LV_FLEX_ALIGN_SPACE_BETWEEN, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
  auto mkMini = [](lv_obj_t* parent, const char* cap, int w, int vw, uint32_t col, lv_obj_t** out) {
    lv_obj_t* c = lv_obj_create(parent);
    ui_clean(c);
    lv_obj_set_size(c, w, LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(c, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(c, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_column(c, 4, 0);
    ui_label(c, cap, UI_F_XS, UI_C_TEXT_MUTE);
    lv_obj_t* v = ui_label(c, "--", UI_F_S, col);
    lv_obj_set_style_max_width(v, vw, 0);
    lv_label_set_long_mode(v, LV_LABEL_LONG_MODE_DOTS);
    *out = v;
  };
  /* 宽度是量出来的：标签 2 个汉字 32px，值按内容给够 */
  mkMini(row3, "客户端", 58, 26, UI_C_CYAN, &hClients);
  mkMini(row3, "外网", 128, 92, UI_C_TEXT, &hWan);
  mkMini(row3, "运行", 100, 68, UI_C_TEXT_DIM, &hUp);
}

// ============================== 页面：系统 ==============================
static void buildSystem(lv_obj_t* p) {
  lv_obj_t* c1 = ui_card(p);
  lv_obj_set_width(c1, LV_PCT(100));
  ui_title_row(c1, &ic_info, "路由器", UI_C_ACCENT);
  ui_kv(c1, "主机名", "—", UI_C_TEXT, &sHost);
  ui_kv(c1, "型号", "—", UI_C_TEXT_DIM, &sModel);
  ui_kv(c1, "内核", "—", UI_C_TEXT_DIM, &sKernel);
  ui_kv(c1, "固件", "—", UI_C_TEXT_DIM, &sRelease);

  lv_obj_t* c2 = ui_card(p);
  lv_obj_set_width(c2, LV_PCT(100));
  ui_title_row(c2, &ic_chip, "资源占用", UI_C_ACCENT);
  lv_obj_t* loads = lv_obj_create(c2);
  ui_clean(loads);
  lv_obj_set_size(loads, LV_PCT(100), 32);
  lv_obj_set_flex_flow(loads, LV_FLEX_FLOW_ROW);
  lv_obj_set_style_pad_column(loads, 6, 0);
  auto mkLoad = [](lv_obj_t* parent, const char* cap, lv_obj_t** out) {
    lv_obj_t* b = lv_obj_create(parent);
    ui_clean(b);
    lv_obj_set_size(b, 92, 32);
    lv_obj_set_flex_flow(b, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(b, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START);
    lv_obj_set_style_pad_row(b, 0, 0);
    ui_label(b, cap, UI_F_XS, UI_C_TEXT_MUTE);
    *out = ui_label(b, "0.00", UI_F_L, UI_C_CYAN);
  };
  mkLoad(loads, "1 分钟", &sL1);
  mkLoad(loads, "5 分钟", &sL5);
  mkLoad(loads, "15 分钟", &sL15);

  ui_kv(c2, "内存", "—", UI_C_TEXT, &sMemTxt);
  sMemBar = ui_bar(c2, UI_C_ACCENT_2);
  ui_kv(c2, "交换分区", "—", UI_C_TEXT_DIM, &sSwapTxt);

  lv_obj_t* c3 = ui_card(p);
  lv_obj_set_width(c3, LV_PCT(100));
  ui_title_row(c3, &ic_wifi, "本面板", UI_C_CYAN);
  ui_kv(c3, "空闲内存", "—", UI_C_TEXT, &sEspHeap);
  ui_kv(c3, "信号强度", "—", UI_C_TEXT_DIM, &sEspRssi);
  ui_kv(c3, "面板地址", "—", UI_C_TEXT_DIM, &sEspIp);
  ui_kv(c3, "已运行", "—", UI_C_TEXT_DIM, &sEspUp);

  lv_obj_t* c4 = ui_card(p);
  lv_obj_set_width(c4, LV_PCT(100));
  ui_title_row(c4, &ic_clock, "数据来源", UI_C_TEXT_MUTE);
  lv_obj_t* tip = ui_label(c4, "数据经 ubus 采集，路由器无需安装插件",
                           UI_F_XS, UI_C_TEXT_MUTE);
  lv_label_set_long_mode(tip, LV_LABEL_LONG_MODE_WRAP);
  lv_obj_set_width(tip, LV_PCT(100));
}

// ============================== 页面：流量 ==============================
static void buildNet(lv_obj_t* p) {
  /* 速率曲线 */
  lv_obj_t* c = ui_card(p);
  lv_obj_set_size(c, LV_PCT(100), 72);
  lv_obj_set_style_pad_all(c, 6, 0);
  lv_obj_set_style_pad_row(c, 1, 0);

  lv_obj_t* head = lv_obj_create(c);
  ui_clean(head);
  lv_obj_set_size(head, LV_PCT(100), UI_LH_16);
  lv_obj_set_flex_flow(head, LV_FLEX_FLOW_ROW);
  lv_obj_set_flex_align(head, LV_FLEX_ALIGN_SPACE_BETWEEN, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
  ui_label(head, "速率曲线", UI_F_XS, UI_C_TEXT_DIM);
  nPeak = ui_label(head, "峰值 --", UI_F_XS, UI_C_TEXT_MUTE);

  chartNet = lv_chart_create(c);
  lv_obj_set_size(chartNet, LV_PCT(100), 38);
  lv_chart_set_type(chartNet, LV_CHART_TYPE_LINE);
  lv_chart_set_point_count(chartNet, CHART_POINTS);
  lv_chart_set_axis_range(chartNet, LV_CHART_AXIS_PRIMARY_Y, 0, 256);
  lv_chart_set_div_line_count(chartNet, 2, 4);
  lv_chart_set_update_mode(chartNet, LV_CHART_UPDATE_MODE_SHIFT);
  lv_obj_set_style_bg_opa(chartNet, LV_OPA_TRANSP, LV_PART_MAIN);
  lv_obj_set_style_border_width(chartNet, 0, LV_PART_MAIN);
  lv_obj_set_style_pad_all(chartNet, 0, LV_PART_MAIN);
  lv_obj_set_style_line_color(chartNet, ui_col(UI_C_BORDER), LV_PART_MAIN);
  lv_obj_set_style_line_opa(chartNet, LV_OPA_50, LV_PART_MAIN);
  lv_obj_set_style_width(chartNet, 0, LV_PART_INDICATOR);       /* 不画数据点 */
  lv_obj_set_style_height(chartNet, 0, LV_PART_INDICATOR);
  lv_obj_set_style_line_width(chartNet, 2, LV_PART_ITEMS);
  serDl = lv_chart_add_series(chartNet, ui_col(UI_C_OK), LV_CHART_AXIS_PRIMARY_Y);
  serUl = lv_chart_add_series(chartNet, ui_col(UI_C_WARM), LV_CHART_AXIS_PRIMARY_Y);
  lv_chart_set_all_values(chartNet, serDl, 0);
  lv_chart_set_all_values(chartNet, serUl, 0);

  /* 下载 / 上传：同样合成一张卡，理由跟概览页一样 */
  lv_obj_t* row = ui_card(p);
  lv_obj_set_size(row, LV_PCT(100), 50);
  lv_obj_set_style_pad_all(row, 6, 0);
  lv_obj_set_flex_flow(row, LV_FLEX_FLOW_ROW);
  lv_obj_set_flex_align(row, LV_FLEX_ALIGN_SPACE_BETWEEN, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
  auto mkBig = [](lv_obj_t* parent, const lv_image_dsc_t* ic, const char* cap, uint32_t col,
                  lv_obj_t** out) {
    lv_obj_t* t = lv_obj_create(parent);
    ui_clean(t);
    lv_obj_set_size(t, 146, UI_LH_24);
    lv_obj_set_flex_flow(t, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(t, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_column(t, 4, 0);
    lv_obj_t* i = ui_icon(t, ic, col);
    lv_image_set_pivot(i, 12, 12);
    ui_icon_size(i, 15);
    ui_label(t, cap, UI_F_XS, UI_C_TEXT_DIM);
    lv_obj_t* sp = lv_obj_create(t);
    ui_clean(sp);
    lv_obj_set_flex_grow(sp, 1);
    lv_obj_set_height(sp, 1);
    *out = ui_label(t, "--", UI_F_L, col);
  };
  mkBig(row, &ic_down, "下载", UI_C_OK, &nDl);
  mkBig(row, &ic_up, "上传", UI_C_WARM, &nUl);

  /* 接口 / 累计流量 */
  lv_obj_t* c2 = ui_card(p);
  lv_obj_set_size(c2, LV_PCT(100), 30);
  lv_obj_set_style_pad_all(c2, 5, 0);
  lv_obj_set_style_pad_row(c2, 0, 0);
  nLine1 = ui_label(c2, "接口 -- · 外网 --", UI_F_XS, UI_C_TEXT_DIM);
  lv_obj_set_width(nLine1, LV_PCT(100));
  nLine2 = ui_label(c2, "接收 -- · 发送 --", UI_F_XS, UI_C_TEXT_MUTE);
  lv_obj_set_width(nLine2, LV_PCT(100));
}

// ============================== 页面：无线 ==============================
static uint32_t clientsHash() {
  uint32_t h = 2166136261u;
  h = (h ^ (uint32_t)gClientCount) * 16777619u;
  h = (h ^ (uint32_t)gClientTotal) * 16777619u;
  for (int i = 0; i < gClientCount; i++) {
    for (const char* p2 = gClients[i].mac; *p2; p2++) h = (h ^ (uint8_t)*p2) * 16777619u;
    h = (h ^ (uint32_t)gClients[i].rssi) * 16777619u;
  }
  return h;
}

static void rebuildClientList() {
  if (!wList) return;
  clientsSig = clientsHash();
  lv_obj_clean(wList);
  if (!gClientsValid && gClientCount == 0) {
    ui_label(wList, "正在等待路由器数据…", UI_F_XS, UI_C_TEXT_MUTE);
    return;
  }
  if (gClientCount == 0) {
    ui_label(wList, "暂无无线客户端", UI_F_XS, UI_C_TEXT_MUTE);
    return;
  }
  for (int i = 0; i < gClientCount; i++) {
    lv_obj_t* r = lv_obj_create(wList);
    ui_clean(r);
    lv_obj_set_size(r, LV_PCT(100), 26);
    lv_obj_set_flex_flow(r, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(r, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_column(r, 5, 0);

    int8_t q = gClients[i].rssi;
    lv_obj_t* ic = ui_icon(r, &ic_wifi, q > -65 ? UI_C_OK : (q > -78 ? UI_C_WARN : UI_C_DANGER));
    lv_image_set_pivot(ic, 12, 12);
    lv_image_set_scale(ic, 125);

    lv_obj_t* ml = ui_label(r, gClients[i].mac, UI_F_XS, UI_C_TEXT);
    lv_obj_set_style_max_width(ml, 108, 0);        /* 17 字符 MAC 放不下整行，超出省略 */
    lv_label_set_long_mode(ml, LV_LABEL_LONG_MODE_DOTS);

    lv_obj_t* sp = lv_obj_create(r);
    ui_clean(sp);
    lv_obj_set_flex_grow(sp, 1);
    lv_obj_set_height(sp, 1);

    char sig[16];
    snprintf(sig, sizeof sig, "%d dBm", q);
    ui_label(r, sig, UI_F_XS, q > -70 ? UI_C_OK : UI_C_WARN);

    if (gClients[i].rateMbps) {
      char rt[12];
      snprintf(rt, sizeof rt, "%uM", gClients[i].rateMbps);
      ui_chip(r, rt, UI_C_ACCENT);
    }
  }
}

static void buildWifi(lv_obj_t* p) {
  lv_obj_t* head = lv_obj_create(p);
  ui_clean(head);
  lv_obj_set_size(head, LV_PCT(100), 42);
  lv_obj_set_flex_flow(head, LV_FLEX_FLOW_ROW);
  lv_obj_set_style_pad_column(head, UI_GAP, 0);

  lv_obj_t* a = ui_card(head);
  lv_obj_set_size(a, 148, 42);
  lv_obj_set_style_pad_all(a, 5, 0);
  ui_mk_stat(a, &ic_users, "已连接", UI_C_OK, &wCount);
  lv_obj_t* b = ui_card(head);
  lv_obj_set_size(b, 148, 42);
  lv_obj_set_style_pad_all(b, 5, 0);
  ui_mk_stat(b, &ic_wifi, "射频", UI_C_CYAN, &wRadio);

  wList = ui_scroll_col(p, LV_PCT(100), UI_CONTENT_H - 4 - 42 - 5);
  lv_obj_set_style_pad_all(wList, 4, 0);
  lv_obj_set_style_pad_row(wList, 2, 0);
  rebuildClientList();
}

// ============================== 页面：设置 ==============================
static void provOpenEvent(lv_event_t*) { showProvisioning(); }
static void routerOpenEvent(lv_event_t*) { showRouterScreen(); }

static void brightEvent(lv_event_t* e) {
  int v = lv_slider_get_value((const lv_obj_t*)lv_event_get_target(e));
  setBacklight((uint8_t)v);
  char b[8];
  snprintf(b, sizeof b, "%d%%", v);
  ui_set_text(cBrightVal, b);
  if (lv_event_get_code(e) == LV_EVENT_RELEASED) savePrefs();
}

static void pollEvent(lv_event_t* e) {
  cfgPollMs = (uint16_t)(intptr_t)lv_event_get_user_data(e);
  savePrefs();
  ui_toast("刷新间隔已更新");
}

static void rebootEvent(lv_event_t*) {
  ui_toast("正在重启…");
  delay(400);
  ESP.restart();
}

static void buildSettings(lv_obj_t* p) {
  lv_obj_t* c1 = ui_card(p);
  lv_obj_set_width(c1, LV_PCT(100));
  ui_title_row(c1, &ic_settings, "连接设置", UI_C_ACCENT);
  lv_obj_t* r1 = ui_list_row(c1, &ic_wifi, "无线网络", "", provOpenEvent, nullptr);
  cSsidVal = lv_obj_get_child(r1, lv_obj_get_child_cnt(r1) - 1);
  ui_divider(c1);
  lv_obj_t* r2 = ui_list_row(c1, &ic_router, "路由器账号", "", routerOpenEvent, nullptr);
  cRtrVal = lv_obj_get_child(r2, lv_obj_get_child_cnt(r2) - 1);

  lv_obj_t* c2 = ui_card(p);
  lv_obj_set_width(c2, LV_PCT(100));
  ui_title_row(c2, &ic_flow, "刷新间隔", UI_C_ACCENT_2);
  lv_obj_t* seg = lv_obj_create(c2);
  ui_clean(seg);
  lv_obj_set_size(seg, LV_PCT(100), 26);
  lv_obj_set_flex_flow(seg, LV_FLEX_FLOW_ROW);
  lv_obj_set_style_pad_column(seg, 4, 0);
  const uint16_t opts[4] = {2000, 3000, 5000, 10000};
  const char* names[4] = {"2s", "3s", "5s", "10s"};
  for (int i = 0; i < 4; i++) {
    lv_obj_t* b = lv_btn_create(seg);
    lv_obj_set_size(b, 66, 24);
    lv_obj_set_style_radius(b, UI_RADIUS_S, 0);
    lv_obj_set_style_shadow_width(b, 0, 0);
    lv_obj_set_style_border_width(b, 1, 0);
    bool on = (cfgPollMs == opts[i]);
    lv_obj_set_style_bg_color(b, ui_col(on ? UI_C_ACCENT : UI_C_CARD), 0);
    lv_obj_set_style_bg_opa(b, on ? LV_OPA_30 : LV_OPA_COVER, 0);
    lv_obj_set_style_border_color(b, ui_col(on ? UI_C_ACCENT : UI_C_BORDER), 0);
    lv_obj_t* l = ui_label(b, names[i], UI_F_XS, on ? UI_C_ACCENT : UI_C_TEXT_DIM);
    lv_obj_center(l);
    lv_obj_add_event_cb(b, pollEvent, LV_EVENT_CLICKED, (void*)(intptr_t)opts[i]);
  }

  lv_obj_t* c3 = ui_card(p);
  lv_obj_set_width(c3, LV_PCT(100));
  ui_title_row(c3, &ic_thermo, "背光亮度", UI_C_CYAN);
  lv_obj_t* r = lv_obj_create(c3);
  ui_clean(r);
  lv_obj_set_size(r, LV_PCT(100), 22);
  lv_obj_set_flex_flow(r, LV_FLEX_FLOW_ROW);
  lv_obj_set_flex_align(r, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
  lv_obj_set_style_pad_column(r, 6, 0);
  cSlider = lv_slider_create(r);
  lv_obj_set_size(cSlider, 238, 6);
  lv_slider_set_range(cSlider, 10, 100);
  lv_slider_set_value(cSlider, cfgBright, LV_ANIM_OFF);
  lv_obj_set_style_bg_color(cSlider, ui_col(UI_C_BORDER), LV_PART_MAIN);
  lv_obj_set_style_bg_color(cSlider, ui_col(UI_C_CYAN), LV_PART_INDICATOR);
  lv_obj_set_style_bg_color(cSlider, ui_col(UI_C_TEXT), LV_PART_KNOB);
  lv_obj_set_style_pad_all(cSlider, 0, LV_PART_KNOB);
  lv_obj_add_event_cb(cSlider, brightEvent, LV_EVENT_ALL, nullptr);
  char bb[8];
  snprintf(bb, sizeof bb, "%u%%", cfgBright);
  cBrightVal = ui_label(r, bb, UI_F_XS, UI_C_TEXT);

  lv_obj_t* c4 = ui_card(p);
  lv_obj_set_width(c4, LV_PCT(100));
  ui_title_row(c4, &ic_globe, "网页后台", UI_C_ACCENT);
  ui_kv(c4, "地址", "—", UI_C_ACCENT, &cWeb);
  ui_kv(c4, "域名", MDNS_NAME ".local", UI_C_TEXT_DIM, nullptr);

  /* 推屏专用页的入口：整屏铺满，投屏时连状态栏都不留 */
  lv_obj_t* c5a = ui_card(p);
  lv_obj_set_width(c5a, LV_PCT(100));
  ui_title_row(c5a, &ic_flow, "投屏", UI_C_CYAN);
  lv_obj_t* cb = ui_button(c5a, &ic_flow, "进入投屏页", UI_C_CARD_HI,
                           [](lv_event_t*) { castPageOpen(); }, nullptr);
  lv_obj_set_width(cb, LV_PCT(100));
  lv_obj_set_height(cb, 28);

  lv_obj_t* c5 = ui_card(p);
  lv_obj_set_width(c5, LV_PCT(100));
  ui_title_row(c5, &ic_info, "关于", UI_C_TEXT_MUTE);
  ui_kv(c5, "版本", APP_VERSION, UI_C_TEXT_DIM, nullptr);
  ui_kv(c5, "硬件", "ESP32-2432S028R", UI_C_TEXT_DIM, nullptr);
  lv_obj_t* btn = ui_button(c5, &ic_power, "重启面板", UI_C_CARD_HI, rebootEvent, nullptr);
  lv_obj_set_width(btn, LV_PCT(100));
  lv_obj_set_height(btn, 28);
}

// ============================== 刷新 ==============================
static void updateStatusBar() {
  char b[32];
  struct tm ti;
  if (getLocalTime(&ti, 20)) {
    snprintf(b, sizeof b, "%02d:%02d", ti.tm_hour, ti.tm_min);
    ui_set_text(lblSbClock, b);
  }
  if (WiFi.status() == WL_CONNECTED) {
    snprintf(b, sizeof b, "%s", WiFi.SSID().c_str());
    ui_set_text(lblSbSsid, b);
    lv_obj_set_style_bg_color(sbDot, ui_col(rtr.online ? UI_C_OK : UI_C_WARN), 0);
    ui_set_text(sbStatus, rtr.online ? "已同步" : "等待数据");
    lv_obj_set_style_text_color(sbStatus, ui_col(rtr.online ? UI_C_OK : UI_C_WARN), 0);
  } else {
    ui_set_text(lblSbSsid, "未连接");
    lv_obj_set_style_bg_color(sbDot, ui_col(UI_C_DANGER), 0);
    ui_set_text(sbStatus, "无网络");
    lv_obj_set_style_text_color(sbStatus, ui_col(UI_C_DANGER), 0);
  }
}

static void updateHome() {
  char b[40];
  snprintf(b, sizeof b, "%.2f", rtr.load1);
  ui_set_text(hLoad, b);
  lv_bar_set_value(hLoadBar, constrain((int)(rtr.load1 * 100), 0, 100), LV_ANIM_OFF);
  snprintf(b, sizeof b, "%u%%", rtr.memPct);
  ui_set_text(hMem, b);
  lv_bar_set_value(hMemBar, rtr.memPct, LV_ANIM_OFF);

  char dl[20], ul[20];
  fmtRate(dl, sizeof dl, net.dl);
  fmtRate(ul, sizeof ul, net.ul);
  ui_set_text(hDl, dl);
  ui_set_text(hUl, ul);

  snprintf(b, sizeof b, "%d", gClientCount);
  ui_set_text(hClients, b);
  ui_set_text(hWan, net.wanIp[0] ? net.wanIp : "—");
  fmtUptime(b, sizeof b, rtr.uptimeSec);
  ui_set_text(hUp, b);
  ui_set_text(hDev, net.iface[0] ? net.iface : "");
}

static void updateSystem() {
  char b[48];
  ui_set_text(sHost, rtr.hostname);
  ui_set_text(sModel, rtr.model[0] ? rtr.model : "—");
  ui_set_text(sKernel, rtr.kernel[0] ? rtr.kernel : "—");
  ui_set_text(sRelease, rtr.release[0] ? rtr.release : "—");

  snprintf(b, sizeof b, "%.2f", rtr.load1);  ui_set_text(sL1, b);
  snprintf(b, sizeof b, "%.2f", rtr.load5);  ui_set_text(sL5, b);
  snprintf(b, sizeof b, "%.2f", rtr.load15); ui_set_text(sL15, b);

  char used[20], total[20];
  fmtBytes(used, sizeof used, (uint64_t)(rtr.memTotal - rtr.memAvail) * 1024ULL);
  fmtBytes(total, sizeof total, (uint64_t)rtr.memTotal * 1024ULL);
  snprintf(b, sizeof b, "%s / %s", used, total);
  ui_set_text(sMemTxt, b);
  lv_bar_set_value(sMemBar, rtr.memPct, LV_ANIM_OFF);

  if (rtr.swapTotal) {
    char su[16], st[16];
    fmtBytes(su, sizeof su, (uint64_t)(rtr.swapTotal - rtr.swapFree) * 1024ULL);
    fmtBytes(st, sizeof st, (uint64_t)rtr.swapTotal * 1024ULL);
    snprintf(b, sizeof b, "%s / %s", su, st);
  } else {
    snprintf(b, sizeof b, "未启用");
  }
  ui_set_text(sSwapTxt, b);

  char hb[20];
  fmtBytes(hb, sizeof hb, ESP.getFreeHeap());
  ui_set_text(sEspHeap, hb);
  snprintf(b, sizeof b, "%d dBm", WiFi.RSSI());
  ui_set_text(sEspRssi, b);
  ui_set_text(sEspIp, WiFi.status() == WL_CONNECTED ? WiFi.localIP().toString().c_str() : "—");
  fmtUptime(b, sizeof b, millis() / 1000);
  ui_set_text(sEspUp, b);
}

static void updateNet() {
  char dl[20], ul[20], pk[24], b[64];
  fmtRate(dl, sizeof dl, net.dl);
  fmtRate(ul, sizeof ul, net.ul);
  fmtRate(pk, sizeof pk, net.peak);
  ui_set_text(nDl, dl);
  ui_set_text(nUl, ul);
  snprintf(b, sizeof b, "peak %s", pk);
  ui_set_text(nPeak, b);

  snprintf(b, sizeof b, "iface %s · wan %s", net.iface[0] ? net.iface : "—",
           net.wanIp[0] ? net.wanIp : "—");
  ui_set_text(nLine1, b);

  char rx[20], tx[20];
  fmtBytes(rx, sizeof rx, net.rxBytes);
  fmtBytes(tx, sizeof tx, net.txBytes);
  snprintf(b, sizeof b, "rx %s · tx %s", rx, tx);
  ui_set_text(nLine2, b);

  // y 轴自适应：变化超过 1/8 才重设，避免每帧重排
  int range = (int)net.peak;
  if (range < 64) range = 64;
  if (chartRange == 0 || abs(range - chartRange) > chartRange / 8) {
    lv_chart_set_axis_range(chartNet, LV_CHART_AXIS_PRIMARY_Y, 0, range);
    chartRange = range;
  }
  lv_chart_set_next_value(chartNet, serDl, (lv_coord_t)constrain((int)net.dl, 0, range));
  lv_chart_set_next_value(chartNet, serUl, (lv_coord_t)constrain((int)net.ul, 0, range));
  lv_chart_refresh(chartNet);
}

static void updateWifi() {
  char b[16];
  // 数据没变就不重建 DOM（LVGL 对象），否则每轮刷新都会闪一下
  if (clientsHash() == clientsSig && clientsSig != 0) {
    snprintf(b, sizeof b, "%d", gClientTotal);
    ui_set_text(wCount, b);
    return;
  }
  snprintf(b, sizeof b, "%d", gClientTotal);
  ui_set_text(wCount, b);
  snprintf(b, sizeof b, "%d", gRadioCount);
  ui_set_text(wRadio, b);
  rebuildClientList();
}

static void updateSettings() {
  char b[40];
  snprintf(b, sizeof b, "http://%s", WiFi.status() == WL_CONNECTED
           ? WiFi.localIP().toString().c_str() : "—");
  ui_set_text(cWeb, b);
  ui_set_text(cSsidVal, WIFI_SSID.length() ? WIFI_SSID.c_str() : "未设置");
  ui_set_text(cRtrVal, owIp.length() ? owIp.c_str() : "自动");
}

static void refreshUI() {
  if (!scrMain || lv_screen_active() != scrMain) return;
  updateStatusBar();
  switch (curPage) {
    case 0: updateHome(); break;
    case 1: updateSystem(); break;
    case 2: updateNet(); break;
    case 3: updateWifi(); break;
    case 4: updateSettings(); break;
  }
}

static void buildUI() {
  scrMain = lv_obj_create(NULL);
  ui_screen_root(scrMain);
  lv_obj_clear_flag(scrMain, LV_OBJ_FLAG_SCROLLABLE);

  buildStatusBar(scrMain);
  panels[0] = newPanel(false);
  panels[1] = newPanel(true);
  panels[2] = newPanel(false);
  panels[3] = newPanel(false);
  panels[4] = newPanel(true);
  buildHome(panels[0]);
  buildSystem(panels[1]);
  buildNet(panels[2]);
  buildWifi(panels[3]);
  buildSettings(panels[4]);
  buildNavBar(scrMain);

  navGoto(0);
  lv_screen_load(scrMain);
}

// ============================== 配网页 ==============================
static lv_obj_t* scrProv = nullptr;
static lv_obj_t* provList = nullptr;
static lv_obj_t* provHint = nullptr;
static lv_obj_t* provTa = nullptr;
static lv_obj_t* provKb = nullptr;
static lv_obj_t* provBtnOk = nullptr;
static lv_obj_t* provBtnBack = nullptr;

#define AP_MAX 20
struct ApItem { String ssid; int32_t rssi; bool sec; };
static ApItem apList[AP_MAX];
static int apCount = 0;
static bool scanning = false;
static String selSsid;

static void scanStart() {
  apCount = 0;
  scanning = true;
  WiFi.scanNetworks(true);
}

/** 返回 true 表示扫描已结束（成功或失败） */
static bool scanPoll() {
  int n = WiFi.scanComplete();
  if (n == -1) return false;
  if (n < 0) { WiFi.scanDelete(); apCount = 0; scanning = false; return true; }
  if (n > AP_MAX) n = AP_MAX;
  for (int i = 0; i < n; i++) {
    apList[i].ssid = WiFi.SSID(i);
    apList[i].rssi = WiFi.RSSI(i);
    apList[i].sec = WiFi.encryptionType(i) != WIFI_AUTH_OPEN;
  }
  apCount = n;
  // 信号强的排前面
  for (int i = 0; i < apCount - 1; i++)
    for (int j = i + 1; j < apCount; j++)
      if (apList[j].rssi > apList[i].rssi) { ApItem t = apList[i]; apList[i] = apList[j]; apList[j] = t; }
  WiFi.scanDelete();
  scanning = false;
  return true;
}

static void provShowPass(bool show) {
  if (!provTa) return;
  if (show) {
    lv_obj_clear_flag(provTa, LV_OBJ_FLAG_HIDDEN);
    lv_obj_clear_flag(provKb, LV_OBJ_FLAG_HIDDEN);
    lv_obj_clear_flag(provBtnOk, LV_OBJ_FLAG_HIDDEN);
    lv_obj_clear_flag(provBtnBack, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(provList, LV_OBJ_FLAG_HIDDEN);
  } else {
    lv_obj_add_flag(provTa, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(provKb, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(provBtnOk, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(provBtnBack, LV_OBJ_FLAG_HIDDEN);
    lv_obj_clear_flag(provList, LV_OBJ_FLAG_HIDDEN);
    lv_textarea_set_text(provTa, "");
  }
}

static void provFillList() {
  if (!provList) return;
  lv_obj_clean(provList);
  if (!apCount) {
    ui_label(provList, "No network found — tap refresh", UI_F_XS, UI_C_TEXT_MUTE);
    return;
  }
  for (int i = 0; i < apCount; i++) {
    lv_obj_t* r = lv_obj_create(provList);
    ui_clean(r);
    lv_obj_set_size(r, LV_PCT(100), 28);
    lv_obj_set_flex_flow(r, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(r, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_column(r, 6, 0);
    lv_obj_set_style_bg_color(r, ui_col(UI_C_ACCENT), LV_STATE_PRESSED);
    lv_obj_set_style_bg_opa(r, LV_OPA_20, LV_STATE_PRESSED);
    lv_obj_add_flag(r, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_set_user_data(r, (void*)(intptr_t)i);

    int rssi = apList[i].rssi;
    uint32_t col = rssi > -65 ? UI_C_OK : (rssi > -78 ? UI_C_WARN : UI_C_DANGER);
    lv_obj_t* ic = ui_icon(r, &ic_wifi, col);
    lv_image_set_pivot(ic, 12, 12);
    lv_image_set_scale(ic, 125);

    lv_obj_t* nm = ui_label(r, apList[i].ssid.c_str(), UI_F_S, UI_C_TEXT);
    lv_label_set_long_mode(nm, LV_LABEL_LONG_MODE_DOTS);
    lv_obj_set_style_max_width(nm, 190, 0);

    lv_obj_t* sp = lv_obj_create(r);
    ui_clean(sp);
    lv_obj_set_flex_grow(sp, 1);
    lv_obj_set_height(sp, 1);

    char b[16];
    snprintf(b, sizeof b, "%d", rssi);
    ui_label(r, b, UI_F_XS, UI_C_TEXT_MUTE);
    if (apList[i].sec) {
      lv_obj_t* lk = ui_icon(r, &ic_settings, UI_C_TEXT_MUTE);
      lv_image_set_pivot(lk, 12, 12);
      lv_image_set_scale(lk, 100);
    }

    lv_obj_add_event_cb(r, [](lv_event_t* e) {
      int idx = (int)(intptr_t)lv_obj_get_user_data((lv_obj_t*)lv_event_get_target(e));
      if (idx < 0 || idx >= apCount) return;
      selSsid = apList[idx].ssid;
      ui_set_text(provHint, selSsid.c_str());
      provShowPass(true);
    }, LV_EVENT_CLICKED, nullptr);
  }
}

static void provConnect() {
  if (!selSsid.length()) return;
  String pass = lv_textarea_get_text(provTa);
  saveWifi(selSsid.c_str(), pass.c_str());
  WIFI_SSID = selSsid;
  WIFI_PASS = pass;
  wifiBegin(WIFI_SSID, WIFI_PASS);
  ui_toast("正在连接…");
}

static void closeProvisioning() {
  if (!scrProv) return;
  lv_screen_load(scrMain);
  lv_obj_del(scrProv);
  scrProv = nullptr; provList = nullptr; provHint = nullptr; provTa = nullptr;
  provKb = nullptr; provBtnOk = nullptr; provBtnBack = nullptr;
  scanning = false;
}

void showProvisioning() {
  if (scrProv || !scrMain) return;

  scrProv = lv_obj_create(NULL);
  ui_screen_root(scrProv);

  lv_obj_t* head = lv_obj_create(scrProv);
  ui_clean(head);
  lv_obj_set_pos(head, 6, 4);
  lv_obj_set_size(head, UI_W - 12, 28);
  lv_obj_set_flex_flow(head, LV_FLEX_FLOW_ROW);
  lv_obj_set_flex_align(head, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
  lv_obj_set_style_pad_column(head, 6, 0);

  lv_obj_t* back = ui_button(head, &ic_back, nullptr, UI_C_CARD, nullptr, nullptr);
  lv_obj_set_size(back, 30, 26);
  lv_obj_add_event_cb(back, [](lv_event_t*) { closeProvisioning(); }, LV_EVENT_CLICKED, nullptr);

  provHint = ui_label(head, "选择无线网络", UI_F_S, UI_C_TEXT);

  lv_obj_t* rescan = ui_button(head, &ic_refresh, nullptr, UI_C_CARD, nullptr, nullptr);
  lv_obj_set_size(rescan, 30, 26);
  lv_obj_add_event_cb(rescan, [](lv_event_t*) {
    if (scanning) return;
    ui_set_text(provHint, "扫描中…");
    lv_obj_clean(provList);
    scanStart();
  }, LV_EVENT_CLICKED, nullptr);

  provList = ui_scroll_col(scrProv, UI_W - 16, 132);
  lv_obj_set_pos(provList, 8, 36);
  lv_obj_set_style_pad_all(provList, 4, 0);
  lv_obj_set_style_pad_row(provList, 2, 0);

  provTa = lv_textarea_create(scrProv);
  lv_obj_set_pos(provTa, 8, 36);
  lv_obj_set_size(provTa, UI_W - 16, 30);
  lv_textarea_set_one_line(provTa, true);
  lv_textarea_set_password_mode(provTa, true);
  lv_textarea_set_placeholder_text(provTa, "请输入密码");
  lv_obj_set_style_bg_color(provTa, ui_col(UI_C_CARD), 0);
  lv_obj_set_style_text_color(provTa, ui_col(UI_C_TEXT), 0);
  lv_obj_set_style_border_color(provTa, ui_col(UI_C_BORDER), 0);
  lv_obj_set_style_radius(provTa, UI_RADIUS_S, 0);
  lv_obj_add_flag(provTa, LV_OBJ_FLAG_HIDDEN);

  provBtnOk = ui_button(scrProv, &ic_wifi, "连接", 0x1F6F4A,
                        [](lv_event_t*) { provConnect(); }, nullptr);
  lv_obj_set_pos(provBtnOk, 8, 70);
  lv_obj_set_size(provBtnOk, 148, 28);
  lv_obj_add_flag(provBtnOk, LV_OBJ_FLAG_HIDDEN);

  provBtnBack = ui_button(scrProv, &ic_back, "返回", UI_C_CARD,
                          [](lv_event_t*) { provShowPass(false); }, nullptr);
  lv_obj_set_pos(provBtnBack, 164, 70);
  lv_obj_set_size(provBtnBack, 148, 28);
  lv_obj_add_flag(provBtnBack, LV_OBJ_FLAG_HIDDEN);

  provKb = lv_keyboard_create(scrProv);
  lv_obj_set_pos(provKb, 0, 102);
  lv_obj_set_size(provKb, UI_W, 138);
  lv_keyboard_set_textarea(provKb, provTa);
  lv_obj_set_style_bg_color(provKb, ui_col(UI_C_CARD), 0);
  lv_obj_set_style_bg_opa(provKb, LV_OPA_COVER, 0);
  lv_obj_add_flag(provKb, LV_OBJ_FLAG_HIDDEN);
  lv_obj_add_event_cb(provKb, [](lv_event_t* e) {
    lv_event_code_t c = lv_event_get_code(e);
    if (c == LV_EVENT_READY) provConnect();
    else if (c == LV_EVENT_CANCEL) provShowPass(false);
  }, LV_EVENT_ALL, nullptr);

  lv_screen_load(scrProv);
  scanStart();
}

// ============================== 路由器登录页 ==============================
static lv_obj_t* scrOw = nullptr;
static lv_obj_t* owTaIp = nullptr;
static lv_obj_t* owTaUser = nullptr;
static lv_obj_t* owTaPass = nullptr;

static void closeRouter() {
  if (!scrOw) return;
  lv_screen_load(scrMain);
  lv_obj_del(scrOw);
  scrOw = nullptr; owTaIp = nullptr; owTaUser = nullptr; owTaPass = nullptr;
}

static void owSave(lv_event_t*) {
  String ip = lv_textarea_get_text(owTaIp);
  String user = lv_textarea_get_text(owTaUser);
  String pass = lv_textarea_get_text(owTaPass);
  if (!user.length()) user = "root";
  saveRouterCfg(ip.c_str(), user.c_str(), pass.c_str());
  OPENWRT_IP = ip; OPENWRT_USER = user; OPENWRT_PASS = pass;
  owIp = ip;
  ubusToken = "";
  boardFresh = false;
  pollReset();
  ui_toast("已保存，正在重连…");
  closeRouter();
}

void showRouterScreen() {
  if (scrOw || !scrMain) return;

  scrOw = lv_obj_create(NULL);
  ui_screen_root(scrOw);

  lv_obj_t* head = lv_obj_create(scrOw);
  ui_clean(head);
  lv_obj_set_pos(head, 6, 4);
  lv_obj_set_size(head, UI_W - 12, 28);
  lv_obj_set_flex_flow(head, LV_FLEX_FLOW_ROW);
  lv_obj_set_flex_align(head, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
  lv_obj_set_style_pad_column(head, 6, 0);

  lv_obj_t* back = ui_button(head, &ic_back, nullptr, UI_C_CARD, nullptr, nullptr);
  lv_obj_set_size(back, 30, 26);
  lv_obj_add_event_cb(back, [](lv_event_t*) { closeRouter(); }, LV_EVENT_CLICKED, nullptr);
  ui_label(head, "路由器账号", UI_F_S, UI_C_TEXT);

  lv_obj_t* save = ui_button(head, &ic_settings, "保存", 0x1F6F4A, owSave, nullptr);
  lv_obj_set_height(save, 26);

  auto mkTa = [](int y, const char* ph, const char* val, bool pw) {
    lv_obj_t* ta = lv_textarea_create(scrOw);
    lv_obj_set_pos(ta, 8, y);
    lv_obj_set_size(ta, UI_W - 16, 30);
    lv_textarea_set_one_line(ta, true);
    lv_textarea_set_placeholder_text(ta, ph);
    lv_textarea_set_password_mode(ta, pw);
    if (val && strlen(val)) lv_textarea_set_text(ta, val);
    lv_obj_set_style_bg_color(ta, ui_col(UI_C_CARD), 0);
    lv_obj_set_style_text_color(ta, ui_col(UI_C_TEXT), 0);
    lv_obj_set_style_border_color(ta, ui_col(UI_C_BORDER), 0);
    lv_obj_set_style_radius(ta, UI_RADIUS_S, 0);
    return ta;
  };
  owTaIp = mkTa(36, "IP (blank = DHCP gateway)", OPENWRT_IP.c_str(), false);
  owTaUser = mkTa(70, "User", OPENWRT_USER.c_str(), false);
  owTaPass = mkTa(104, "请输入密码", OPENWRT_PASS.c_str(), true);

  lv_obj_t* kb = lv_keyboard_create(scrOw);
  lv_obj_set_pos(kb, 0, 138);
  lv_obj_set_size(kb, UI_W, 102);
  lv_keyboard_set_textarea(kb, owTaPass);
  lv_obj_set_style_bg_color(kb, ui_col(UI_C_CARD), 0);
  lv_obj_add_event_cb(kb, [](lv_event_t* e) {
    if (lv_event_get_code(e) == LV_EVENT_READY) owSave(e);
  }, LV_EVENT_ALL, nullptr);

  // 点哪个框，键盘就输入哪个框
  auto focus = [](lv_event_t* e) {
    lv_obj_t* kb2 = (lv_obj_t*)lv_obj_get_user_data((lv_obj_t*)lv_event_get_current_target(e));
    if (kb2) lv_keyboard_set_textarea(kb2, (lv_obj_t*)lv_event_get_target(e));
  };
  lv_obj_set_user_data(scrOw, kb);
  lv_obj_add_event_cb(owTaIp, focus, LV_EVENT_CLICKED, nullptr);
  lv_obj_add_event_cb(owTaUser, focus, LV_EVENT_CLICKED, nullptr);
  lv_obj_add_event_cb(owTaPass, focus, LV_EVENT_CLICKED, nullptr);

  lv_screen_load(scrOw);
}

// ============================== WebUI 后台 ==============================
/*
 * 路由：
 *   GET  /               内嵌控制台（webui_html.h -> INDEX_HTML，存 flash）
 *   GET  /manifest.json  PWA 清单（可"添加到主屏幕"）
 *   GET  /icon.svg       图标
 *   GET  /api/state      状态快照 JSON
 *   POST /api            控制命令 JSON
 *   GET  :81/events      SSE 状态推送
 *
 * 为什么 SSE 走 81 端口：ESP32 的 WebServer 不支持长连接 —— 它回完响应就
 * Connection: close，还会声明 Transfer-Encoding: chunked，直接往上写会被
 * 浏览器当成格式错误丢掉。所以推送自己开一个裸 socket 服务，手写 HTTP 头并
 * 保持连接。
 */
static WebServer server(WEB_PORT);
static WiFiServer sseSrv(SSE_PORT);

/* 前向声明：这三个函数定义在文件后面的"投屏接收"一段
   （那一段要用到 TFT 的写像素接口和投屏自己的状态机，只能排在后面） */
static void netAccept();
static void wsPoll();
static void castWatchdog();
static void castExit(const char* why);
static void castPageRefresh();
static void castSnapshot(int* on, int* page, unsigned long* frames,
                         unsigned long* errs, unsigned* w, unsigned* h);
#define SSE_MAX 3
static WiFiClient sseCli[SSE_MAX];
static uint32_t sseLastPush = 0;
static uint32_t sseLastPing = 0;
static uint32_t sseLastHash = 0;

static uint32_t hashStr(const String& s) {
  uint32_t h = 2166136261u;
  for (size_t i = 0; i < s.length(); i++) h = (h ^ (uint8_t)s[i]) * 16777619u;
  return h;
}

static String buildState() {
  JsonDoc d JDOC_CAP(6144);
  d["fw"] = APP_VERSION;
  d["screen"] = curPage;

  JsonObject w = d.createNestedObject("wifi");
  bool up = (WiFi.status() == WL_CONNECTED);
  w["up"] = up ? 1 : 0;
  w["ssid"] = WiFi.SSID();
  w["ip"] = up ? WiFi.localIP().toString() : "";
  w["gw"] = up ? WiFi.gatewayIP().toString() : "";
  w["rssi"] = up ? WiFi.RSSI() : 0;

  JsonObject r = d.createNestedObject("rtr");
  r["online"] = rtr.online ? 1 : 0;
  r["host"] = rtr.hostname;
  r["model"] = rtr.model;
  r["kernel"] = rtr.kernel;
  r["release"] = rtr.release;
  r["up"] = rtr.uptimeSec;
  r["ip"] = owIp;
  JsonArray ld = r.createNestedArray("load");
  ld.add(rtr.load1); ld.add(rtr.load5); ld.add(rtr.load15);
  JsonObject mem = r.createNestedObject("mem");
  mem["total"] = rtr.memTotal;
  mem["used"] = rtr.memTotal > rtr.memAvail ? (rtr.memTotal - rtr.memAvail) : 0;
  mem["pct"] = rtr.memPct;
  mem["cached"] = rtr.memCached;
  mem["buffered"] = rtr.memBuffered;
  JsonObject sw = r.createNestedObject("swap");
  sw["total"] = rtr.swapTotal;
  sw["used"] = rtr.swapTotal > rtr.swapFree ? (rtr.swapTotal - rtr.swapFree) : 0;

  JsonObject n = d.createNestedObject("net");
  n["iface"] = net.iface;
  n["wan"] = net.wanIp;
  n["proto"] = net.proto;
  n["rx"] = net.rxBytes;
  n["tx"] = net.txBytes;
  n["dl"] = net.dl;
  n["ul"] = net.ul;
  n["peak"] = net.peak;
  n["link"] = net.linkMbps;

  JsonObject c = d.createNestedObject("cli");
  c["n"] = gClientCount;
  c["total"] = gClientTotal;
  c["radios"] = gRadioCount;
  JsonArray arr = c.createNestedArray("list");
  for (int i = 0; i < gClientCount; i++) {
    JsonObject o = arr.createNestedObject();
    o["mac"] = gClients[i].mac;
    o["rssi"] = gClients[i].rssi;
    o["rate"] = gClients[i].rateMbps;
  }

  JsonObject sys = d.createNestedObject("sys");
  sys["heap"] = (uint32_t)ESP.getFreeHeap();
  sys["up"] = (uint32_t)(millis() / 1000);
  sys["poll"] = cfgPollMs;
  sys["bright"] = cfgBright;

  if (apCount > 0) {
    JsonArray ap = d.createNestedArray("ap");
    for (int i = 0; i < apCount; i++) {
      JsonObject o = ap.createNestedObject();
      o["ssid"] = apList[i].ssid;
      o["rssi"] = apList[i].rssi;
      o["sec"] = apList[i].sec ? 1 : 0;
    }
  }

  /* 投屏状态：LuCI 的「状态」页拿这个显示投屏页开没开、收了多少帧 */
  {
    int on = 0, page = 0;
    unsigned long cf = 0, ce = 0;
    unsigned cw = 0, ch = 0;
    castSnapshot(&on, &page, &cf, &ce, &cw, &ch);
    JsonObject cj = d.createNestedObject("cast");
    cj["on"]     = on;
    cj["page"]   = page;
    cj["frames"] = cf;
    cj["errs"]   = ce;
    cj["w"]      = cw;
    cj["h"]      = ch;
  }

  String out;
  serializeJson(d, out);
  return out;
}

/** 页面/接口一律禁缓存：否则手机会一直用旧网页，改了前端也"没反应" */
static void noCache() {
  server.sendHeader("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0");
  server.sendHeader("Pragma", "no-cache");
  server.sendHeader("Expires", "0");
  /* 放开跨域：这样 OpenWrt 上的 LuCI 插件（跑在 路由器:80）能直接 fetch
     面板自己的 :80/api/state，不用绕路由器转发一遍 */
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.sendHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  server.sendHeader("Access-Control-Allow-Headers", "Content-Type");
}

/** 浏览器在跨域 POST 前会先发 OPTIONS 探一下，不回 204 就会被拦掉 */
static void handleCorsPreflight() {
  noCache();
  server.send(204, "text/plain", "");
}

/** 从 flash 分块推页面：不把整页拷进 RAM（省 20KB 堆） */
static void sendFlash(const char* data, size_t len, const char* ctype) {
  noCache();
  server.setContentLength(CONTENT_LENGTH_UNKNOWN);
  server.send(200, ctype, "");
  static char buf[768];
  size_t off = 0;
  while (off < len) {
    size_t n = len - off;
    if (n > sizeof(buf) - 1) n = sizeof(buf) - 1;
    memcpy_P(buf, data + off, n);
    buf[n] = 0;
    server.sendContent(buf);            // chunked，逐块交给 WebServer
    off += n;
  }
  server.sendContent("");
}

static void handleRoot() { sendFlash(INDEX_HTML, strlen_P(INDEX_HTML), "text/html; charset=utf-8"); }
static void handleManifest() { server.send_P(200, "application/manifest+json", MANIFEST_JSON); }
static void handleIcon() { server.send_P(200, "image/svg+xml", ICON_SVG); }

static void ssePush(bool force);

static void handleState() {
  noCache();
  server.send(200, "application/json", buildState());
}

static void handleApi() {
  JsonDoc d JDOC_CAP(1024);
  if (deserializeJson(d, server.arg("plain"))) {
    server.send(400, "application/json", "{\"ok\":0,\"err\":\"bad json\"}");
    return;
  }
  const char* c = d["c"] | "";
  bool ok = true;

  if (!strcmp(c, "wifi")) {
    const char* ssid = d["ssid"] | "";
    const char* pass = d["pass"] | "";
    if (strlen(ssid)) {
      saveWifi(ssid, pass);
      WIFI_SSID = ssid;
      WIFI_PASS = pass;
      wifiBegin(WIFI_SSID, WIFI_PASS);
    } else ok = false;

  } else if (!strcmp(c, "router")) {
    String ip = (const char*)(d["ip"] | "");
    String user = (const char*)(d["user"] | "root");
    String pass = (const char*)(d["pass"] | "");
    if (!user.length()) user = "root";
    saveRouterCfg(ip.c_str(), user.c_str(), pass.c_str());
    OPENWRT_IP = ip; OPENWRT_USER = user; OPENWRT_PASS = pass;
    owIp = ip;
    ubusToken = "";
    boardFresh = false;
    pollReset();

  } else if (!strcmp(c, "poll")) {
    uint16_t ms = d["ms"] | POLL_DEFAULT_MS;
    if (ms >= 2000 && ms <= 10000) { cfgPollMs = ms; savePrefs(); }

  } else if (!strcmp(c, "bright")) {
    int p = d["pct"] | 100;
    setBacklight((uint8_t)constrain(p, 10, 100));
    savePrefs();
    if (cSlider) lv_slider_set_value(cSlider, cfgBright, LV_ANIM_OFF);

  } else if (!strcmp(c, "ui")) {
    int id = d["id"] | -1;
    if (id == 5) {
      castPageOpen();                       // 专用推屏页
    } else if (id >= 0 && id <= 4) {
      if (scrCast) castPageClose();         // 先收起推屏页
      if (!scrProv && !scrOw) navGoto(id);
    }

  } else if (!strcmp(c, "scan")) {
    if (!scanning) scanStart();

  } else if (!strcmp(c, "forget")) {
    WIFI_SSID = "";
    WIFI_PASS = "";
    saveWifi("", "");
    WiFi.disconnect(true);
    showProvisioning();

  } else if (!strcmp(c, "reboot")) {
    server.send(200, "application/json", "{\"ok\":1}");
    delay(200);
    ESP.restart();

  } else {
    ok = false;
  }

  refreshUI();
  ssePush(true);
  server.send(200, "application/json", ok ? "{\"ok\":1}" : "{\"ok\":0}");
}

/* ---- SSE：81 端口裸 socket 长连接 ---- */
static void ssePush(bool force) {
  // 没有客户端时直接返回：buildState() 要 1.5KB 堆，别白花
  int alive = 0;
  for (int i = 0; i < SSE_MAX; i++) if (sseCli[i] && sseCli[i].connected()) alive++;
  if (!alive) return;

  uint32_t now = millis();
  if (!force && (now - sseLastPush) < 800) return;   // 先看节流再序列化，别白花 1.5KB 堆
  String json = buildState();
  uint32_t h = hashStr(json);
  if (!force && h == sseLastHash) { sseLastPush = now; return; }
  sseLastHash = h;
  sseLastPush = now;

  String msg = "data: " + json + "\n\n";
  for (int i = 0; i < SSE_MAX; i++) {
    if (sseCli[i] && sseCli[i].connected()) {
      sseCli[i].print(msg);
    }
  }
}

static void webBegin() {
  server.on("/", handleRoot);
  server.on("/manifest.json", handleManifest);
  server.on("/icon.svg", handleIcon);
  server.on("/api/state", handleState);
  server.on("/api/state", HTTP_OPTIONS, handleCorsPreflight);
  server.on("/api", HTTP_POST, handleApi);
  server.on("/api", HTTP_OPTIONS, handleCorsPreflight);
  server.onNotFound([]() { server.send(404, "text/plain", "not found"); });
  server.begin();
  sseSrv.begin();
  sseSrv.setNoDelay(true);

  Serial.printf("[web] panel on :%d, sse/投屏 on :%d\n", WEB_PORT, SSE_PORT);
}

static void webLoop() {
  server.handleClient();
  netAccept();
  wsPoll();                                // 投屏的 WebSocket 帧
  castWatchdog();                          // 超时 / 触屏退出
  uint32_t now = millis();
  for (int i = 0; i < SSE_MAX; i++)
    if (sseCli[i] && !sseCli[i].connected()) sseCli[i].stop();

  if (now - sseLastPing > 20000) {          // 心跳，防中间设备掐空闲连接
    sseLastPing = now;
    for (int i = 0; i < SSE_MAX; i++) if (sseCli[i] && sseCli[i].connected()) sseCli[i].print(": ping\n\n");
  }
  ssePush(false);
}

// ============================== 投屏接收 ==============================
/*
 * 画面从上位机推过来，本机只负责"收 + 画"，协议逐字节兼容
 * planet0104/esp32-wifi-screen（MIT）：
 *
 *   GET  :81/display_config    {"width":320,"height":240,"rotated_width":320,"rotated_height":240}
 *   POST :81/draw_image        body = JPEG 文件
 *   POST :81/draw_rgb565       body = 整帧 RGB565（每像素 2 字节、高字节在前）
 *   POST :81/draw_rgb565_lz4   body = [u32 LE 解压后长度] + LZ4 块
 *   GET  :81/ws                WebSocket，二进制帧：
 *                                JPEG 文件
 *                                "RGB565" + 整帧像素
 *                                "wflz4ke_" + u16BE w + u16BE h + LZ4 关键帧
 *                                "wflz4dl_" + 同上 = 差分帧（与上一帧 XOR，本机不支持）
 *                                "wflz4no_" = 无变化帧
 *                              服务端回文本帧 ACK / NACK，上位机据此决定下一帧
 *   GET  :81/cast_exit         退出投屏回到监控界面（屏上点一下也一样）
 *
 * 为什么 endpoint 放在 81 而不是 80：80 上是 Arduino 的 WebServer，它把整个 POST
 * body 收进一个 String —— 153KB 的整帧能把堆直接吃穿。81 是裸 socket，body 可以
 * 一边收一边往屏幕推，全程不落整帧缓冲。
 *
 * 内存取舍（这块 CYD 没有 PSRAM，可用 DRAM 约 300KB）：
 *   整帧像素   320x240x2 = 153,600B  不申请，攒够一行就推给 ILI9341
 *   LZ4 回看   64KB 环形窗口          需要时才申请，会话结束释放
 *   差分参考帧 153,600B               放弃：差分还要再多吃一份同样大的解压缓冲，
 *                                     与其把内存顶到 300KB 以上不如不支持，
 *                                     DLT 帧回 NACK，上位机会自动改发关键帧
 */

#if !defined(CAST_TIMEOUT_MS)
#define CAST_TIMEOUT_MS  6000        // 多久没收到帧就自动退回监控界面
#endif
#define CAST_MAX_W       640         // 拒收远大于屏幕的帧，别被畸形尺寸撑爆
#define CAST_MAX_H       480
#define CAST_MAX_SRC     262144u     // 单帧原始数据上限 256KB
#define CAST_FRAME       262144u     // 单帧 WebSocket payload 上限 256KB

#if __has_include(<TJpg_Decoder.h>)
#include <TJpg_Decoder.h>
#define CAST_HAS_JPEG 1
#else
#define CAST_HAS_JPEG 0
#endif

static bool     castActive = false;    // 正在投屏（LVGL 让位给上位机的像素流）
static bool     castLive   = false;    // 正在写某一帧
static uint32_t castLastFrameMs = 0;
static uint32_t castFrames = 0, castErrs = 0;

/* ---------------------------------------------------------- 大块内存
 * 一个就够了：LZ4 解码要回看历史；必要时 Redis 一帧数据。*/
static uint8_t* castBuf = nullptr;
static size_t   castBufCap = 0;

static bool castAllocBuf(size_t cap) {
  if (castBuf && castBufCap >= cap) return true;
  if (castBuf) { free(castBuf); castBuf = nullptr; castBufCap = 0; }
  if (ESP.getFreeHeap() < cap + 60000) return false;
  castBuf = (uint8_t*)malloc(cap);
  if (!castBuf) return false;
  castBufCap = cap;
  return true;
}

static void castFreeBuf() {
  if (!castBuf) return;
  free(castBuf);
  castBuf = nullptr; castBufCap = 0;
}

/* ---------------------------------------------------------- 像素落屏
 * 拿到的一律是"源图字节流"：按行攒，够一行就 setAddrWindow + pushColors。
 * 尺寸比屏幕大就居中裁剪，比屏幕小就居中留黑边。 */
static uint16_t castRowBuf[CAST_MAX_W];
static uint16_t castRowFill = 0;        // 当前行已经攒的像素数
static uint16_t castCurRow  = 0;        // 当前是源图第几行
static uint16_t castSrcW = 0, castSrcH = 0;
static uint16_t castSrcOx = 0, castSrcOy = 0;
static int      castDstX = 0, castDstY = 0;
static uint16_t castDstW = 0, castDstH = 0;
static int      castPrevX = -1, castPrevY = -1;   // 上一帧落在屏幕上的矩形
static uint16_t castPrevW = 0, castPrevH = 0;     // 变了就先抹一圈，别留残影
static bool     castOddHas = false;
static uint8_t  castOdd = 0;
static bool     castFull = false;       // 源图就是整屏，可以省掉逐行设窗口

/* 把"源图第 srcY 行、从 hostX 列起的 n 个像素"推到目标矩形对应的位置 */
static void castPushSpan(uint16_t srcY, uint16_t hostX, const uint16_t* px, uint16_t n) {
  if (!castLive || srcY < castSrcOy || srcY >= castSrcOy + castDstH) return;
  int32_t c0 = (int32_t)hostX, c1 = (int32_t)hostX + n;
  int32_t a0 = c0 > (int32_t)castSrcOx ? c0 : (int32_t)castSrcOx;
  int32_t a1 = c1 < (int32_t)(castSrcOx + castDstW) ? c1 : (int32_t)(castSrcOx + castDstW);
  if (a1 <= a0) return;
  int32_t dx = castDstX + (a0 - (int32_t)castSrcOx);
  int32_t dy = castDstY + (srcY - castSrcOy);
  tft.setAddrWindow(dx, dy, (uint16_t)(a1 - a0), 1);
  tft.pushColors((uint16_t*)(px + (a0 - c0)), (uint16_t)(a1 - a0), true);
}

static inline void castRowFlush() {
  if (castFull) tft.pushColors(castRowBuf, SCREEN_W, true);
  else          castPushSpan(castCurRow, 0, castRowBuf, castSrcW);
}

static inline void castPixel(uint16_t v) {
  castRowBuf[castRowFill++] = v;
  if (castRowFill >= castSrcW) { castRowFlush(); castRowFill = 0; castCurRow++; }
}

/* 线上 RGB565 是高字节在前，这里拼成 native u16，
   后面走的链路就和 LVGL 那条完全一致了 */
static void castBytes(const uint8_t* p, size_t n) {
  if (!castLive) return;
  size_t i = 0;
  if (castOddHas && n > 0) {
    castOddHas = false;
    castPixel((uint16_t)(((uint16_t)castOdd << 8) | p[0]));
    i = 1;
  }
  for (; i + 2 <= n; i += 2) castPixel((uint16_t)(((uint16_t)p[i] << 8) | p[i + 1]));
  if (i < n) { castOdd = p[i]; castOddHas = true; }
}

static void castFrameBegin(uint16_t w, uint16_t h) {
  if (!w || !h) return;
  castSrcW = w; castSrcH = h;
  if (w >= SCREEN_W) { castDstW = SCREEN_W; castSrcOx = (w - SCREEN_W) / 2; castDstX = 0; }
  else               { castDstW = w;        castSrcOx = 0;                  castDstX = (SCREEN_W - w) / 2; }
  if (h >= SCREEN_H) { castDstH = SCREEN_H; castSrcOy = (h - SCREEN_H) / 2; castDstY = 0; }
  else               { castDstH = h;        castSrcOy = 0;                  castDstY = (SCREEN_H - h) / 2; }
  castFull = (castSrcW == SCREEN_W && castSrcH == SCREEN_H);
  castRowFill = 0; castCurRow = 0; castOddHas = false;

  /* 新帧盖不满整屏时，边上一圈还留着上一帧的像素 —— 尺寸一变就先抹黑。
     只在矩形变化时做，正常逐帧推同一个尺寸不会多花时间。 */
  if (castDstX != castPrevX || castDstY != castPrevY ||
      castDstW != castPrevW || castDstH != castPrevH) {
    if (castDstX > 0)
      tft.fillRect(0, 0, castDstX, SCREEN_H, TFT_BLACK);
    if (castDstX + (int)castDstW < SCREEN_W)
      tft.fillRect(castDstX + castDstW, 0, SCREEN_W - castDstX - castDstW, SCREEN_H, TFT_BLACK);
    if (castDstY > 0)
      tft.fillRect(0, 0, SCREEN_W, castDstY, TFT_BLACK);
    if (castDstY + (int)castDstH < SCREEN_H)
      tft.fillRect(0, castDstY + castDstH, SCREEN_W, SCREEN_H - castDstY - castDstH, TFT_BLACK);
    castPrevX = castDstX; castPrevY = castDstY;
    castPrevW = castDstW; castPrevH = castDstH;
  }

  castLive = true;
  tft.startWrite();
  if (castFull) tft.setAddrWindow(0, 0, SCREEN_W, SCREEN_H);
}

static void castFrameEnd() {
  castLive = false;
  castRowFill = 0;
  castOddHas = false;
  tft.endWrite();
  castFrames++;
  castLastFrameMs = millis();
}

/* ---------------------------------------------------------- LZ4 块解码（流式）
 * 输入两种：纯 LZ4 块；或前面挂了 u32 LE 解压长度的块（上位机用的就是后者）。
 * 输出不落地，直接喂 castBytes()；回看要用的历史数据放 64KB 环形窗口
 * （LZ4 的匹配偏移最大 65535，窗口比它稍大就够）。 */
#define CAST_WIN_BITS 16
#define CAST_WIN_SIZE (1u << CAST_WIN_BITS)
#define CAST_WIN_MASK (CAST_WIN_SIZE - 1u)
static uint8_t* castWin = nullptr;
static uint8_t  castOutBuf[512];
static size_t   castOutFill = 0;

static inline void castOutByte(uint32_t a, uint8_t v) {
  castWin[a & CAST_WIN_MASK] = v;
  castOutBuf[castOutFill++] = v;
  if (castOutFill >= sizeof(castOutBuf)) { castBytes(castOutBuf, castOutFill); castOutFill = 0; }
}

static bool castWinAlloc() {
  if (castWin) return true;
  castWin = (uint8_t*)malloc(CAST_WIN_SIZE);
  if (castWin) Serial.printf("[cast] LZ4 回看窗口 %uB OK，free %u\n",
                             (unsigned)CAST_WIN_SIZE, (unsigned)ESP.getFreeHeap());
  else         Serial.printf("[cast] LZ4 回看窗口申请失败，LZ4 帧暂不可用\n");
  return castWin != nullptr;
}

static void castWinFree() {
  if (!castWin) return;
  free(castWin);
  castWin = nullptr;
}

static bool castLz4(const uint8_t* src, size_t srcLen, uint32_t dstLen) {
  if (!castWinAlloc()) return false;
  const uint8_t* p = src;
  const uint8_t* end = src + srcLen;
  uint32_t out = 0;
  const uint32_t outEnd = dstLen;
  castOutFill = 0;

  while (p < end) {
    uint8_t tok = *p++;
    uint32_t lit = (uint32_t)(tok >> 4);
    if (lit == 15) { uint8_t b; do { if (p >= end) return false; b = *p++; lit += b; } while (b == 255); }
    if ((size_t)(end - p) < lit || out + lit > outEnd) return false;
    while (lit--) castOutByte(out++, *p++);

    if (p >= end) break;                       // 最后一个序列只有字面量
    if (end - p < 2) return false;
    uint32_t off = (uint32_t)p[0] | ((uint32_t)p[1] << 8);
    p += 2;
    uint32_t mlen = (uint32_t)(tok & 0x0F);
    if (mlen == 15) { uint8_t b; do { if (p >= end) return false; b = *p++; mlen += b; } while (b == 255); }
    mlen += 4;                                 // LZ4 最小匹配长度
    if (off == 0 || off > out || out + mlen > outEnd) return false;
    uint32_t from = out - off;
    while (mlen--) castOutByte(out++, castWin[from++ & CAST_WIN_MASK]);
  }

  if (castOutFill) { castBytes(castOutBuf, castOutFill); castOutFill = 0; }
  return out == outEnd;
}

static bool castLz4Prepended(const uint8_t* src, size_t len) {
  if (len < 4) return false;
  uint32_t dstLen = (uint32_t)src[0] | ((uint32_t)src[1] << 8) |
                    ((uint32_t)src[2] << 16) | ((uint32_t)src[3] << 24);
  if (dstLen > CAST_MAX_SRC) return false;
  return castLz4(src + 4, len - 4, dstLen);
}

/* ---------------------------------------------------------- JPEG（可选）
 * 没 PSRAM 也吃得下：TJpg_Decoder 一次只吐一小块，我们照样按行推出去。
 * 没装这个库就自动跳过这一整段。 */
#if CAST_HAS_JPEG
static bool castJpgOut(int16_t x, int16_t y, uint16_t w, uint16_t h, uint16_t* bmp) {
  if (!castLive) return 0;
  for (uint16_t r = 0; r < h; r++) {
    if (y + r < 0 || y + r >= (int16_t)castSrcH) continue;
    castPushSpan((uint16_t)(y + r), (uint16_t)x, bmp + (uint32_t)r * w, w);
  }
  return 1;
}

static bool castDrawJpeg(const uint8_t* src, size_t len, const char** why) {
  uint16_t w = 0, h = 0;
  if (TJpgDec.getJpgSize(&w, &h, src, len) != JDR_OK) { *why = "JPEG 尺寸解析失败"; return false; }
  if (!w || !h || w > CAST_MAX_W || h > CAST_MAX_H) { *why = "JPEG 尺寸越界"; return false; }
  TJpgDec.setCallback(castJpgOut);
  TJpgDec.setJpgScale(1);
  castFrameBegin(w, h);
  JRESULT r = TJpgDec.drawJpg(0, 0, src, len);
  castFrameEnd();
  if (r != JDR_OK) { *why = "JPEG 解码失败"; return false; }
  return true;
}
#endif

/* ---------------------------------------------------------- 一帧的分发
 * 结果通过 *why 返回："ok" = 画完了，"nop" = 本来就不用画，其它 = 出错原因 */
static bool castDispatch(const uint8_t* src, size_t len, const char** why) {
  if (!len) { *why = "空帧"; return false; }

  /* 1) JPEG：上位机最省事的一种 —— 把 HTML 截图编码成 jpg 丢过来 */
  if (len > 2 && src[0] == 0xFF && src[1] == 0xD8) {
#if CAST_HAS_JPEG
    return castDrawJpeg(src, len, why);
#else
    *why = "未编译 JPEG 解码（platformio.ini 加 bodmer/TJpg_Decoder）";
    return false;
#endif
  }
  /* 2) PNG：本机没有解码器，提示上位机换格式 */
  if (len > 4 && src[0] == 0x89 && src[1] == 'P' && src[2] == 'N' && src[3] == 'G') {
    *why = "不支持 PNG，请推 JPEG 或 RGB565";
    return false;
  }
  /* 3) esp32-wifi-screen 的关键帧 / 差分帧 / 无变化帧 */
  if (len >= 12 && memcmp(src, "wflz4", 5) == 0) {
    if (memcmp(src, "wflz4no_", 8) == 0) { *why = "nop"; return true; }
    bool key = memcmp(src, "wflz4ke_", 8) == 0;
    bool dlt = memcmp(src, "wflz4dl_", 8) == 0;
    if (!key && !dlt) { *why = "未知 magic"; return false; }
    if (dlt) { *why = "本机不支持差分帧，请改发关键帧"; return false; }

    uint16_t w = (uint16_t)(((uint16_t)src[8] << 8) | src[9]);
    uint16_t h = (uint16_t)(((uint16_t)src[10] << 8) | src[11]);
    if (!w || !h || w > CAST_MAX_W || h > CAST_MAX_H) { *why = "尺寸越界"; return false; }

    castFrameBegin(w, h);
    bool ok = castLz4(src + 12, len - 12, (uint32_t)w * h * 2);
    castFrameEnd();
    if (!ok) *why = "LZ4 解码失败";
    return ok;
  }
  /* 4) "RGB565" 前缀的裸像素 */
  if (len >= 8 && memcmp(src, "RGB565", 6) == 0) {
    size_t n = len - 6;
    uint32_t lines = (uint32_t)(n / (SCREEN_W * 2));
    if (!lines || lines > CAST_MAX_H) { *why = "像素数对不上整帧"; return false; }
    castFrameBegin(SCREEN_W, (uint16_t)lines);
    castBytes(src + 6, lines * SCREEN_W * 2);
    castFrameEnd();
    return true;
  }
  /* 5) 兜底：当成 [u32 LE 长度] + LZ4 块的整屏帧 */
  castFrameBegin(SCREEN_W, SCREEN_H);
  bool ok = castLz4Prepended(src, len);
  castFrameEnd();
  if (!ok) *why = "既不是 JPEG 也不是 LZ4 帧";
  return ok;
}

/* ---------------------------------------------------------- 推屏专用页
 * 一整屏 320x240，没有状态栏也没有导航栏：投屏时像素是直写 TFT 的，
 * LVGL 整个让位，所以这一页只在「还没开始」和「已经结束」时看得见 ——
 * 它的作用是给地址、给状态、留一条退路。
 *
 * 进入方式：设置页的「进入投屏页」按钮 / POST /api {"c":"ui","id":5} /
 * 收到第一帧时自动切过来（自动切过来的，投屏结束后会自动退回监控页）。 */
#define CAST_PAGE_IDLE_MS  60000      // 手动进来干等 60 秒没人推，退回监控
#define CAST_FAIL_LIMIT    8          // 连续这么多帧失败就认栽，别把屏占着

static lv_obj_t* castLblBig = nullptr;
static lv_obj_t* castLblUrl = nullptr;
static lv_obj_t* castLblTip = nullptr;
static lv_obj_t* castLblStat = nullptr;

static uint32_t castPageAtMs = 0;
static bool     castPageAuto = false;     // 是"因为来了帧"自动打开的
static char     castLastMsg[64] = "";     // 上一次投屏怎么结束的
static uint8_t  castFailStreak = 0;

static void castPageRefresh() {
  if (!scrCast) return;

  char b[72];
  if (castActive) {
    ui_set_text(castLblBig, "正在投屏");
    ui_set_text(castLblTip, "上位机直写画面，触屏退出");
  } else if (castLastMsg[0]) {
    ui_set_text(castLblBig, "已停止");
    ui_set_text(castLblTip, castLastMsg);
  } else {
    ui_set_text(castLblBig, "等待推送画面");
    ui_set_text(castLblTip, "从 LuCI「投屏」页推一帧即可");
  }

  snprintf(b, sizeof b, "http://%s:%d",
           WiFi.status() == WL_CONNECTED ? WiFi.localIP().toString().c_str() : "—",
           SSE_PORT);
  ui_set_text(castLblUrl, b);

  snprintf(b, sizeof b, "已收 %lu 帧 · 失败 %lu 次",
           (unsigned long)castFrames, (unsigned long)castErrs);
  ui_set_text(castLblStat, b);
}

static void castPageBuild() {
  scrCast = lv_obj_create(NULL);
  ui_screen_root(scrCast);

  lv_obj_t* ti = ui_icon(scrCast, &ic_flow, UI_C_CYAN);
  lv_obj_set_pos(ti, 10, 10);
  ui_icon_size(ti, 18);

  lv_obj_t* tt = ui_label(scrCast, "投屏", UI_F_S, UI_C_TEXT);
  lv_obj_set_pos(tt, 34, 9);

  lv_obj_t* xb = ui_button(scrCast, &ic_back, nullptr, UI_C_CARD, nullptr, nullptr);
  lv_obj_set_pos(xb, UI_W - 40, 6);
  lv_obj_set_size(xb, 30, 26);
  lv_obj_add_event_cb(xb, [](lv_event_t*) { castPageClose(); }, LV_EVENT_CLICKED, nullptr);

  /* 中间：状态大卡。整块居中，字少了也不空 */
  lv_obj_t* card = ui_card(scrCast);
  lv_obj_set_pos(card, 8, 40);
  lv_obj_set_size(card, UI_W - 16, 118);
  lv_obj_set_flex_align(card, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
  lv_obj_set_style_pad_row(card, 6, 0);

  castLblBig = ui_label(card, "等待推送画面", UI_F_L, UI_C_TEXT);
  castLblUrl = ui_label(card, "http://—", UI_F_XS, UI_C_CYAN);
  castLblTip = ui_label(card, "", UI_F_XS, UI_C_TEXT_DIM);
  lv_obj_set_width(castLblTip, UI_W - 48);
  lv_label_set_long_mode(castLblTip, LV_LABEL_LONG_MODE_WRAP);
  lv_obj_set_style_text_align(castLblTip, LV_TEXT_ALIGN_CENTER, 0);

  castLblStat = ui_label(scrCast, "", UI_F_XS, UI_C_TEXT_MUTE);
  lv_obj_set_pos(castLblStat, 10, 164);

  lv_obj_t* b1 = ui_button(scrCast, &ic_back, "回到监控", UI_C_CARD, nullptr, nullptr);
  lv_obj_set_pos(b1, 8, 188);
  lv_obj_set_size(b1, 148, 36);
  lv_obj_add_event_cb(b1, [](lv_event_t*) { castPageClose(); }, LV_EVENT_CLICKED, nullptr);

  lv_obj_t* b2 = ui_button(scrCast, &ic_power, "停止投屏", UI_C_CARD_HI, nullptr, nullptr);
  lv_obj_set_pos(b2, 164, 188);
  lv_obj_set_size(b2, 148, 36);
  lv_obj_add_event_cb(b2, [](lv_event_t*) { castExit("手动停止"); }, LV_EVENT_CLICKED, nullptr);
}

static void castPageOpen() {
  if (!scrMain) return;
  if (scrProv) closeProvisioning();
  if (scrOw) closeRouter();
  if (!scrCast) castPageBuild();
  castPageAtMs = millis();
  lv_screen_load(scrCast);
  castPageRefresh();
}

static void castPageClose() {
  if (!scrCast) return;
  if (castActive) castExit("退出页面");      // 先停投屏，别把帧写到监控页上
  lv_screen_load(scrMain);
  lv_obj_del(scrCast);
  scrCast = nullptr;
  castLblBig = castLblUrl = castLblTip = castLblStat = nullptr;
  castPageAuto = false;
  uiDirty = true;
  lv_obj_invalidate(scrMain);
  lv_refr_now(disp);
}

/* ---------------------------------------------------------- 会话进出 */
static void castEnter() {
  if (castActive) return;
  castActive = true;
  castLastFrameMs = millis();
  castFrames = 0; castErrs = 0;
  castFailStreak = 0;
  castLastMsg[0] = 0;
  castWinAlloc();

  /* 有专用页就切过去：这样小于整屏的帧四周是投屏页的底色，
     而不是监控界面被压在下面 */
  if (!scrCast) { castPageOpen(); castPageAuto = true; }
  else          { castPageAtMs = millis(); castPageRefresh(); }

  pollReset();                       // 投屏期间别再去占着带宽问 ubus
  tft.fillScreen(TFT_BLACK);
  castPrevX = -1; castPrevW = 0; castPrevH = 0;
  Serial.printf("[cast] 进入投屏，free %u\n", (unsigned)ESP.getFreeHeap());
}

static void castExit(const char* why) {
  if (!castActive) return;
  castActive = false;
  if (castLive) castFrameEnd();      // 断在半帧上也要把 endWrite 补齐
  castLive = false;
  castWinFree();
  castFreeBuf();
  castPrevX = -1; castPrevW = 0; castPrevH = 0;
  snprintf(castLastMsg, sizeof castLastMsg, "%s退出 · %lu 帧 / %lu 失败",
           why ? why : "", (unsigned long)castFrames, (unsigned long)castErrs);
  Serial.printf("[cast] 退出投屏（%s），%u 帧 / %u 次失败\n",
                why ? why : "", (unsigned)castFrames, (unsigned)castErrs);

  /* LVGL 不知道我们偷偷写过屏幕，得逼它整屏重绘一次 */
  tft.fillScreen(TFT_BLACK);
  uiDirty = true;
  pollReset();

  /* 自动打开的推屏页用完就收，别让屏幕停在「已停止」上 */
  if (castPageAuto) { castPageClose(); return; }

  castPageRefresh();
  lv_obj_invalidate(lv_screen_active());
  lv_refr_now(disp);
}

/* 一帧的结果：成功就把连败清零，失败就累加（看门狗据此放弃） */
static inline void castResult(bool ok) {
  if (ok) { castFailStreak = 0; return; }
  castErrs++;
  if (castFailStreak < 255) castFailStreak++;
}

/* 给 /api/state 用的只读快照（buildState 排在文件前面，只能这样取） */
static void castSnapshot(int* on, int* page, unsigned long* frames,
                         unsigned long* errs, unsigned* w, unsigned* h) {
  if (on)     *on     = castActive ? 1 : 0;
  if (page)   *page   = scrCast ? 1 : 0;
  if (frames) *frames = castFrames;
  if (errs)   *errs   = castErrs;
  if (w)      *w      = castSrcW;
  if (h)      *h      = castSrcH;
}

/* ---------------------------------------------------------- HTTP 裸 socket 服务
 * :81 上一个 server 三种用法，按请求行分发：
 *     /events            -> SSE（见上一段）
 *     /display_config    -> 屏幕参数
 *     /draw_* /cast_exit -> 投屏 HTTP 接口
 *     /ws                -> WebSocket 升级
 */
/* 注意这里不能用 c.printf()：只有 HardwareSerial 有 printf，
   WiFiClient 走的是 Print，得自己拼好再写一次 */
static void castHttpSend(WiFiClient& c, const char* head,
                         const char* type, const char* ctype) {
  char h[160];
  snprintf(h, sizeof h, "%sContent-Type: %s\r\nConnection: close\r\n"
                        "Access-Control-Allow-Origin: *\r\nContent-Length: %u\r\n\r\n",
           head, ctype, (unsigned)strlen(type));
  c.print(h);
  c.print(type);
}

/* 跨域预检。LuCI 插件在浏览器里直接往 :81 推帧时，
   带 Content-Type 的 POST 会先来一个 OPTIONS，不回就被浏览器拦掉 */
static void castHttpOptions(WiFiClient& c) {
  c.print("HTTP/1.1 204 No Content\r\n");
  c.print("Access-Control-Allow-Origin: *\r\n");
  c.print("Access-Control-Allow-Methods: POST, GET, OPTIONS\r\n");
  c.print("Access-Control-Allow-Headers: Content-Type\r\n");
  c.print("Access-Control-Max-Age: 86400\r\n");
  c.print("Content-Length: 0\r\nConnection: close\r\n\r\n");
}

static void castHttpRsp(WiFiClient& c, int code, const char* body) {
  char h[48];
  snprintf(h, sizeof h, "HTTP/1.1 %d %s\r\n", code, code == 200 ? "OK" : "Error");
  castHttpSend(c, h, body, "text/plain; charset=utf-8");
}

static bool castReadBody(WiFiClient& c, size_t total, CastFeed feed, void* ctx) {
  uint8_t buf[1024];
  size_t got = 0;
  uint32_t t0 = millis();
  while (got < total) {
    if (!c.connected()) break;
    int avail = c.available();
    if (avail <= 0) {
      if (millis() - t0 > 15000) break;
      delay(1);
      continue;
    }
    size_t want = (size_t)avail;
    if (want > sizeof(buf)) want = sizeof(buf);
    if (want > total - got) want = total - got;
    int n = c.read(buf, want);
    if (n <= 0) break;
    got += (size_t)n;
    if (feed && !feed(buf, (size_t)n, ctx)) break;
    t0 = millis();
  }
  return got == total;
}

/* 直接从 socket 流到屏幕，不落中间缓冲 */
static bool castFeedPixels(const uint8_t* p, size_t n, void*) {
  castBytes(p, n);
  return true;
}

/* 落到 heap 缓冲：LZ4 / JPEG 都要随机访问，只能整块收 */
struct CastBufCtx { size_t len; };
static bool castFeedBuf(const uint8_t* p, size_t n, void* ctx) {
  CastBufCtx* cb = (CastBufCtx*)ctx;
  if (cb->len + n > castBufCap) return false;
  memcpy(castBuf + cb->len, p, n);
  cb->len += n;
  return true;
}

static void castQuerySize(const String& head, uint16_t* w, uint16_t* h) {
  *w = SCREEN_W; *h = SCREEN_H;
  int i = head.indexOf('?');
  if (i < 0) return;
  String q = head.substring(i + 1);
  int sp = q.indexOf(' ');
  if (sp > 0) q = q.substring(0, sp);
  for (int p = 0; p < (int)q.length();) {
    int eq = q.indexOf('=', p);
    int amp = q.indexOf('&', p);
    if (amp < 0) amp = q.length();
    if (eq < 0 || eq > amp) { p = amp + 1; continue; }
    String k = q.substring(p, eq), v = q.substring(eq + 1, amp);
    if (k == "width")  *w = (uint16_t)constrain(v.toInt(), 1, CAST_MAX_W);
    if (k == "height") *h = (uint16_t)constrain(v.toInt(), 1, CAST_MAX_H);
    p = amp + 1;
  }
}

static uint32_t castContentLength(const String& head) {
  int ci = head.indexOf("Content-Length:");
  if (ci < 0) ci = head.indexOf("content-length:");
  if (ci < 0) return 0;
  int eol = head.indexOf('\n', ci);
  return (uint32_t)head.substring(ci + 15, eol > 0 ? eol : head.length()).toInt();
}

static void castHandleHttp(WiFiClient& c, const String& head) {
  String path = head.substring(head.indexOf(' ') + 1);
  int sp = path.indexOf(' ');
  if (sp > 0) path = path.substring(0, sp);
  int qm = path.indexOf('?');
  if (qm > 0) path = path.substring(0, qm);
  if (head.startsWith("OPTIONS")) { castHttpOptions(c); return; }
  bool get = head.startsWith("GET");

  if (get && path == "/display_config") {
    char js[200];
    snprintf(js, sizeof js,
             "{\"width\":%u,\"height\":%u,\"rotated_width\":%u,\"rotated_height\":%u,"
             "\"rotation\":90,\"protocol\":\"esp32-wifi-screen\"}",
             SCREEN_W, SCREEN_H, SCREEN_W, SCREEN_H);
    castHttpSend(c, "HTTP/1.1 200 OK\r\n", js, "application/json");
    return;
  }
  if (path == "/cast_exit") {
    castExit("HTTP");
    castHttpRsp(c, 200, "OK");
    return;
  }
  if (get) { castHttpRsp(c, 404, "not found"); return; }

  uint32_t cl = castContentLength(head);
  if (!cl)                     { castHttpRsp(c, 411, "需要 Content-Length"); return; }
  if (cl > CAST_MAX_SRC)       { castHttpRsp(c, 413, "帧太大"); return; }

  castEnter();

  if (path == "/draw_rgb565") {
    /* 裸像素可以一路流到屏幕，不用 heap 缓冲 */
    uint16_t w, h;
    castQuerySize(head, &w, &h);
    uint32_t t0 = millis();
    castFrameBegin(w, h);
    bool full = castReadBody(c, cl, castFeedPixels, nullptr);
    castFrameEnd();
    char b[96];
    castResult(full);
    if (full) { snprintf(b, sizeof b, "%ux%u OK %lums", w, h, (unsigned long)(millis() - t0));
                castHttpRsp(c, 200, b); }
    else      { snprintf(b, sizeof b, "接收不完整，期望 %lu 字节", (unsigned long)cl);
                castHttpRsp(c, 400, b); }
    return;
  }

  if (path == "/draw_rgb565_lz4" || path == "/draw_image") {
    if (!castAllocBuf(cl)) { castResult(false); castHttpRsp(c, 507, "内存不足，装不下这一帧"); return; }
    CastBufCtx ctx; ctx.len = 0;
    if (!castReadBody(c, cl, castFeedBuf, &ctx)) {
      castResult(false); castHttpRsp(c, 400, "接收不完整"); return;
    }
    uint32_t t0 = millis();
    const char* why = "ok";
    bool ok;
    if (path == "/draw_rgb565_lz4") {
      castFrameBegin(SCREEN_W, SCREEN_H);
      ok = castLz4Prepended(castBuf, ctx.len);
      castFrameEnd();
      if (!ok) why = "LZ4 解码失败";
    } else {
      ok = castDispatch(castBuf, ctx.len, &why);
    }
    char b[180];
    snprintf(b, sizeof b, "%s %lums (free %u)", why,
             (unsigned long)(millis() - t0), (unsigned)ESP.getFreeHeap());
    castResult(ok);
    castHttpRsp(c, ok ? 200 : 400, b);
    return;
  }

  castHttpRsp(c, 404, "not found");
}

/* ---------------------------------------------------------- WebSocket
 * 手写帧解析，没用现成的 WS 库：那些库给每条连接静态开一个几十 KB 的缓冲，
 * 而本协议二进制帧能到 150KB，配起来比自己解析还绕。
 * 服务端发的帧不带 mask（RFC 6455 要求），客户端发来的必须解 mask。 */
struct CastWs {
  WiFiClient cli;
  bool     up     = false;
  uint8_t  st     = 0;          // 0 帧头 1 len16 2 len64 3 mask 4 payload
  bool     fin    = false;
  bool     masked = false;
  uint8_t  op     = 0;
  uint8_t  mask[4] = {0, 0, 0, 0};
  uint8_t  mi     = 0;          // mask 游标
  size_t   need   = 0;
  size_t   got    = 0;
  uint8_t  pre[16] = {0};       // 帧头 12 字节，用来判类型
  size_t   preGot = 0;
  uint8_t  mode   = 0;          // 0 待定 1 攒到 heap 2 直接流像素 3 丢弃
  size_t   acc    = 0;          // mode 1 已攒字节
  size_t   skip   = 0;          // mode 2 还要丢掉几个前缀字节
  bool     isText = false;
  uint32_t lastMs = 0;
};
static CastWs ws;

static void wsSend(const char* txt) {
  if (!ws.cli || !ws.cli.connected()) return;
  size_t n = strlen(txt);
  uint8_t h[2] = { 0x81, (uint8_t)n };
  ws.cli.write(h, 2);
  ws.cli.write((const uint8_t*)txt, n);
}

static void wsClose() {
  if (ws.cli) ws.cli.stop();
  ws.up = false;
  ws.st = 0;
  ws.mode = 0;
  castFreeBuf();
}

static inline void wsResetFrame() {
  ws.st = 0; ws.got = 0; ws.need = 0; ws.mi = 0;
  ws.mode = 0; ws.preGot = 0; ws.acc = 0; ws.skip = 0;
  ws.isText = false;
  ws.lastMs = millis();
}

static void wsFrameDone() {
  if (ws.isText) {
    if (!castBuf || ws.acc == 0) { wsSend("ACK"); return; }
    castBuf[ws.acc < castBufCap ? ws.acc : castBufCap - 1] = 0;
    String t((const char*)castBuf);
    if (t.indexOf("\"exit\"") >= 0 || t.indexOf("\"stop\"") >= 0) {
      castExit("WS");
      wsSend("ACK");
      return;
    }
    int bi = t.indexOf("\"brightness\"");
    if (bi >= 0) {
      int eq = t.indexOf(':', bi);
      if (eq > 0) setBacklight((uint8_t)constrain(t.substring(eq + 1).toInt(), 10, 100));
    }
    wsSend("ACK");
    return;
  }

  if (ws.mode == 2) {                       // 已经在收的过程中直接画过了
    castFrameEnd();
    wsSend("ACK");
    return;
  }
  if (ws.mode != 1 || !castBuf || !ws.acc) { wsSend("NACK"); return; }

  castEnter();
  const char* why = "ok";
  bool ok = castDispatch(castBuf, ws.acc, &why);
  if (strcmp(why, "nop") == 0) castResult(true); else castResult(ok);
  if (castFrames % 30 == 0)
    Serial.printf("[cast] %s %uB -> %s (free %u)\n", ok ? "OK " : "ERR",
                  (unsigned)ws.acc, why, (unsigned)ESP.getFreeHeap());
  wsSend(ok ? "ACK" : "NACK");
}

static void wsPayload(const uint8_t* p, size_t n) {
  if (ws.mode == 0) {
    /* 攒够 12 字节再判类型；帧本身不足 12 字节就按帧尾判 */
    while (ws.preGot < 12 && n) { ws.pre[ws.preGot++] = *p++; n--; }
    if (ws.preGot < 12 && ws.got < ws.need) return;
    if (!ws.isText && ws.preGot >= 6 && memcmp(ws.pre, "RGB565", 6) == 0) {
      ws.mode = 2;
      ws.skip = 6;
      uint32_t lines = (uint32_t)((ws.need - 6) / (SCREEN_W * 2));
      if (!lines || lines > CAST_MAX_H) { ws.mode = 3; return; }
      castFrameBegin(SCREEN_W, (uint16_t)lines);
      /* pre 里前 6 字节是前缀，剩下的直接喂进去 */
      if (ws.preGot > 6) castBytes(ws.pre + 6, ws.preGot - 6);
      ws.skip = 0;
    } else {
      ws.mode = 1;
      if (!castAllocBuf(ws.need + 16)) {
        ws.mode = 3;
        Serial.printf("[cast] 帧装不下 %uB\n", (unsigned)ws.need);
        return;
      }
      if (ws.preGot) { memcpy(castBuf, ws.pre, ws.preGot); ws.acc = ws.preGot; }
    }
  }
  if (ws.mode == 1) {
    while (n) {
      size_t k = n;
      if (ws.acc + k > ws.need) k = (ws.need > ws.acc) ? (ws.need - ws.acc) : 0;
      if (ws.acc + k > castBufCap) k = (castBufCap > ws.acc) ? (castBufCap - ws.acc) : 0;
      if (!k) break;
      memcpy(castBuf + ws.acc, p, k);
      ws.acc += k; p += k; n -= k;
    }
  } else if (ws.mode == 2) {
    if (ws.skip) { size_t k = n < ws.skip ? n : ws.skip; p += k; n -= k; ws.skip -= k; }
    if (n) castBytes(p, n);
  }
}

static void wsPoll() {
  if (!ws.up) return;
  if (!ws.cli || !ws.cli.connected()) { wsClose(); return; }
  if (ws.got && millis() - ws.lastMs > 15000) {
    Serial.printf("[cast] WS 帧超时，断开\n");
    wsClose();
    return;
  }

  int avail = ws.cli.available();
  if (avail <= 0) return;

  switch (ws.st) {
    case 0: {                                // 2 字节基本帧头
      if (avail < 2) return;
      uint8_t b0 = (uint8_t)ws.cli.read();
      uint8_t b1 = (uint8_t)ws.cli.read();
      ws.fin = (b0 & 0x80) != 0;
      ws.op = b0 & 0x0F;
      ws.masked = (b1 & 0x80) != 0;
      ws.need = (size_t)(b1 & 0x7F);
      ws.isText = (ws.op == 0x1);
      ws.lastMs = millis();
      if (ws.op == 0x8) { ws.cli.stop(); wsClose(); return; }        // close
      if (ws.op == 0x9 || ws.op == 0xA) { ws.st = ws.masked ? 3 : 4; return; }
      if (ws.op != 0x0 && ws.op != 0x1 && ws.op != 0x2) { ws.st = ws.masked ? 3 : 4; ws.mode = 3; return; }
      if (ws.need == 126) ws.st = 1;
      else if (ws.need == 127) ws.st = 2;
      else ws.st = ws.masked ? 3 : 4;
      return;
    }
    case 1: {                                // 16 位扩展长度
      if (avail < 2) return;
      ws.need = ((size_t)ws.cli.read() << 8) | (size_t)ws.cli.read();
      ws.st = ws.masked ? 3 : 4;
      return;
    }
    case 2: {                                // 64 位扩展长度
      if (avail < 8) return;
      ws.need = 0;
      for (int i = 0; i < 8; i++) ws.need = (ws.need << 8) | (uint64_t)ws.cli.read();
      if (ws.need > CAST_FRAME) { Serial.printf("[cast] WS 帧太大 %uB\n", (unsigned)ws.need); wsClose(); return; }
      ws.st = ws.masked ? 3 : 4;
      return;
    }
    case 3: {                                // mask 密钥
      if (avail < 4) return;
      for (int i = 0; i < 4; i++) ws.mask[i] = (uint8_t)ws.cli.read();
      ws.mi = 0;
      ws.st = 4;
      return;
    }
    case 4: {                                // payload
      uint8_t buf[512];
      size_t want = (size_t)avail;
      if (want > sizeof(buf)) want = sizeof(buf);
      if (want > ws.need - ws.got) want = (ws.need > ws.got) ? (ws.need - ws.got) : 0;
      int n = ws.cli.read(buf, want);
      if (n <= 0) return;
      if (ws.masked) for (int i = 0; i < n; i++) buf[i] ^= ws.mask[(ws.mi++) & 3];
      ws.got += (size_t)n;
      ws.lastMs = millis();
      wsPayload(buf, (size_t)n);
      if (ws.got >= ws.need) {
        if (ws.op == 0x9) { uint8_t ph[2] = { 0x8A, 0 }; ws.cli.write(ph, 2); }
        else if (ws.op != 0x0) wsFrameDone();
        wsResetFrame();
      }
      return;
    }
    default: wsResetFrame(); return;
  }
}

/* ---------------------------------------------------------- WS 握手：SHA-1 + Base64 */
static inline uint32_t castRotl(uint32_t x, int n) { return (x << n) | (x >> (32 - n)); }

static void castSha1Block(uint32_t h[5], const uint8_t* p) {
  uint32_t w[80];
  for (int i = 0; i < 16; i++)
    w[i] = ((uint32_t)p[4 * i] << 24) | ((uint32_t)p[4 * i + 1] << 16) |
           ((uint32_t)p[4 * i + 2] << 8) | (uint32_t)p[4 * i + 3];
  for (int i = 16; i < 80; i++) w[i] = castRotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
  uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
  for (int i = 0; i < 80; i++) {
    uint32_t f, k;
    if      (i < 20) { f = (b & c) | ((~b) & d);        k = 0x5A827999u; }
    else if (i < 40) { f = b ^ c ^ d;                   k = 0x6ED9EBA1u; }
    else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDCu; }
    else             { f = b ^ c ^ d;                   k = 0xCA62C1D6u; }
    uint32_t t = castRotl(a, 5) + f + e + k + w[i];
    e = d; d = c; c = castRotl(b, 30); b = a; a = t;
  }
  h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e;
}

static void castSha1(const uint8_t* data, size_t len, uint8_t out[20]) {
  uint32_t h[5] = { 0x67452301u, 0xEFCDAB89u, 0x98BADCFEu, 0x10325476u, 0xC3D2E1F0u };
  size_t off = 0;
  for (; off + 64 <= len; off += 64) castSha1Block(h, data + off);
  uint8_t tail[128]; size_t n = 0;
  while (off < len) tail[n++] = data[off++];
  tail[n++] = 0x80;
  while ((n % 64) != 56) tail[n++] = 0;
  uint64_t bits = (uint64_t)len * 8;
  for (int i = 7; i >= 0; i--) tail[n++] = (uint8_t)(bits >> (8 * i));
  for (size_t i = 0; i < n; i += 64) castSha1Block(h, tail + i);
  for (int i = 0; i < 5; i++) {
    out[4 * i] = (uint8_t)(h[i] >> 24); out[4 * i + 1] = (uint8_t)(h[i] >> 16);
    out[4 * i + 2] = (uint8_t)(h[i] >> 8); out[4 * i + 3] = (uint8_t)h[i];
  }
}

static const char CAST_B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static String castB64(const uint8_t* d, size_t n) {
  String s;
  s.reserve((n + 2) / 3 * 4);
  size_t i = 0;
  for (; i + 3 <= n; i += 3) {
    uint32_t v = ((uint32_t)d[i] << 16) | ((uint32_t)d[i + 1] << 8) | d[i + 2];
    s += CAST_B64[(v >> 18) & 63]; s += CAST_B64[(v >> 12) & 63];
    s += CAST_B64[(v >> 6) & 63];  s += CAST_B64[v & 63];
  }
  size_t r = n - i;
  if (r == 1) {
    uint32_t v = (uint32_t)d[i] << 16;
    s += CAST_B64[(v >> 18) & 63]; s += CAST_B64[(v >> 12) & 63]; s += '='; s += '=';
  } else if (r == 2) {
    uint32_t v = ((uint32_t)d[i] << 16) | ((uint32_t)d[i + 1] << 8);
    s += CAST_B64[(v >> 18) & 63]; s += CAST_B64[(v >> 12) & 63];
    s += CAST_B64[(v >> 6) & 63];  s += '=';
  }
  return s;
}

static bool castWsAccept(WiFiClient& c, const String& head) {
  int ki = head.indexOf("Sec-WebSocket-Key:");
  if (ki < 0) ki = head.indexOf("sec-websocket-key:");
  if (ki < 0) return false;
  int eol = head.indexOf('\n', ki);
  String key = head.substring(ki + 18, eol > 0 ? eol : head.length());
  key.trim();
  if (!key.length()) return false;

  static const char GUID[] = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
  String cat = key + GUID;
  uint8_t dig[20];
  castSha1((const uint8_t*)cat.c_str(), cat.length(), dig);
  String accept = castB64(dig, 20);

  c.print("HTTP/1.1 101 Switching Protocols\r\n");
  c.print("Upgrade: websocket\r\n");
  c.print("Connection: Upgrade\r\n");
  c.print("Sec-WebSocket-Accept: ");
  c.print(accept);
  c.print("\r\n\r\n");

  if (ws.up) wsClose();                     // 一次只服务一路推屏
  ws.cli = c;
  ws.up  = true;
  wsResetFrame();
  castEnter();
  Serial.printf("[cast] WebSocket 已连接\n");
  return true;
}

/* :81 这一个端口要伺候三拨人：SSE 推送、投屏 HTTP、WebSocket。
   这里只读到头部结束就收手（不能像以前那样"把 available 全读进来"，
   那样会把 POST 的 body 一起吞掉），然后按路径分发。 */
static void netAccept() {
  if (!sseSrv.hasClient()) return;
  WiFiClient c = sseSrv.accept();
  if (!c) return;
  c.setNoDelay(true);

  String req;
  uint32_t t0 = millis();
  bool hdrDone = false;
  while (c.connected() && (millis() - t0) < 400) {
    while (c.available()) {
      req += (char)c.read();
      /* 逐字节比对头部结束符：不用 String::endsWith，也不用每次从头 indexOf */
      unsigned L = req.length();
      if (L >= 4 && req[L - 1] == '\n' && req[L - 3] == '\n' &&
          req[L - 2] == '\r' && req[L - 4] == '\r') { hdrDone = true; break; }
    }
    if (hdrDone || req.length() > 4096) break;
    delay(1);
  }
  if (req.length() < 8) { c.stop(); return; }

  /* WebSocket 升级：头里有 Upgrade: websocket 且路径是 /ws */
  if (req.indexOf("Upgrade: websocket") >= 0 || req.indexOf("upgrade: websocket") >= 0) {
    if (castWsAccept(c, req)) return;
    castHttpRsp(c, 400, "WebSocket 握手失败");
    return;
  }
  /* 投屏 HTTP 接口 */
  if (req.indexOf("/display_config") >= 0 || req.indexOf("/draw_") >= 0 ||
      req.indexOf("/cast_exit") >= 0) {
    castHandleHttp(c, req);
    c.stop();
    return;
  }
  /* SSE 是唯一留下长连接的 */
  if (req.indexOf("/events") < 0) { c.stop(); return; }

  // 找一个空位，满了就踢掉最早的
  int slot = -1;
  for (int i = 0; i < SSE_MAX; i++) if (!sseCli[i] || !sseCli[i].connected()) { slot = i; break; }
  if (slot < 0) { sseCli[0].stop(); slot = 0; }

  c.print("HTTP/1.1 200 OK\r\n");
  c.print("Content-Type: text/event-stream; charset=utf-8\r\n");
  c.print("Cache-Control: no-cache, no-store\r\n");
  c.print("Connection: keep-alive\r\n");
  c.print("Access-Control-Allow-Origin: *\r\n\r\n");
  c.print(": connected\n\n");
  sseCli[slot] = c;
  Serial.printf("[web] sse client on slot %d\n", slot);
  ssePush(true);
}

/* ---------------------------------------------------------- 投屏看门狗 */
static void castWatchdog() {
  if (!castActive) {
    /* 手动点进来的推屏页干等着没人推，到点退回监控页 */
    if (scrCast && !castPageAuto && millis() - castPageAtMs > CAST_PAGE_IDLE_MS)
      castPageClose();
    return;
  }
  if (castLive) return;                     // 半帧写一半的时候别打扰
  if (castFailStreak >= CAST_FAIL_LIMIT) { castExit("连续失败"); return; }
  if (touch.Pressed()) { castExit("触屏"); delay(300); return; }
  if (millis() - castLastFrameMs > CAST_TIMEOUT_MS) castExit("超时");
}

// ============================== setup / loop ==============================
static uint32_t lastCycleAt = 0;
static uint32_t lastUiTick = 0;

void setup() {
  Serial.begin(115200);
  delay(200);
  Serial.printf("\n=== %s v%s ===\n", APP_NAME, APP_VERSION);

  loadConfig();

  lv_init();

  tft.init();
  tft.setRotation(1);
  tft.fillScreen(TFT_BLACK);
  touch.setCal(526, 3443, 750, 3377, SCREEN_W, SCREEN_H, 1);
  backlightInit();

  /* v9 里没有 LV_TICK_CUSTOM 了，得自己把时间源挂上去，否则动画和定时器都不走 */
  lv_tick_set_cb([]() -> uint32_t { return millis(); });

  disp = lv_display_create(SCREEN_W, SCREEN_H);
  lv_display_set_flush_cb(disp, dispFlush);
  lv_display_set_buffers(disp, lvBuf, NULL, sizeof(lvBuf), LV_DISPLAY_RENDER_MODE_PARTIAL);

  indev = lv_indev_create();
  lv_indev_set_type(indev, LV_INDEV_TYPE_POINTER);
  lv_indev_set_read_cb(indev, touchRead);
  lv_indev_set_display(indev, disp);

  buildUI();
  refreshUI();

  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);                    // 关省电，否则轮询延迟会飘
  WiFi.setAutoReconnect(false);            // 重连自己管，避免和状态机打架

  if (WIFI_SSID.length()) {
    wifiBegin(WIFI_SSID, WIFI_PASS);
  } else {
    showProvisioning();
  }

  webBegin();
  Serial.printf("[sys] free heap %u\n", (unsigned)ESP.getFreeHeap());
}

void loop() {
  /* 投屏期间 LVGL 要彻底松手：画面是上位机的像素直接写进去的，
     LVGL 再补什么都会盖在上面（触摸也不用它，退出靠 castWatchdog 自己看） */
  if (!castActive) lv_timer_handler();

  // ---- WiFi 守候：连上了就开跑，超时就进配网（边沿检测，别每轮都触发）----
  static bool wifiWasUp = false;
  static bool wifiWaitArmed = false;
  static uint32_t wifiWaitAt = 0;
  bool wifiUp = (WiFi.status() == WL_CONNECTED);

  if (wifiUp && !wifiWasUp) {
    wifiWasUp = true;
    wifiWaitArmed = false;
    onWifiUp();
    if (scrProv) closeProvisioning();
    pollReset();
    lastCycleAt = millis();
    uiDirty = true;
  } else if (!wifiUp) {
    if (wifiWasUp) { wifiWasUp = false; uiDirty = true; }
    if (WIFI_SSID.length()) {
      if (!wifiWaitArmed) { wifiWaitArmed = true; wifiWaitAt = millis(); }
      else if (millis() - wifiWaitAt > WIFI_TIMEOUT_MS) {
        wifiWaitArmed = false;
        showProvisioning();
      }
    }
  }

  // ---- ubus 轮询：每次 loop 只走一步。投屏时让路，别抢 cast 的带宽 ----
  if (wifiUp && !castActive) {
    if (pollStep == PS_DONE) {
      if (millis() - lastCycleAt >= cfgPollMs) {
        lastCycleAt = millis();
        pollBeginCycle();
      }
    } else {
      if (pollStepOnce()) { uiDirty = true; lastCycleAt = millis(); }
    }
  }

  // ---- 配网页扫描 ----
  if (scanning) {
    static uint32_t scanAt = 0;
    if (millis() - scanAt > 300) {
      scanAt = millis();
      if (scanPoll() && scrProv) provFillList();
      if (!scanning && scrProv) ui_set_text(provHint, apCount ? "选择无线网络" : "未搜索到网络");
    }
  }

  webLoop();

  // ---- 界面刷新：状态变了立刻刷，否则 1 秒刷一次时钟 ----
  if (!castActive && (uiDirty || millis() - lastUiTick > 1000)) {
    lastUiTick = millis();
    uiDirty = false;
    refreshUI();
  }

  delay(1);              // 让出 CPU 给 WiFi/lwIP 任务，否则空闲时会被自己占满
}
