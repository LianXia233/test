/*
 * webui_html.h - 内嵌 WebUI 后台（全部存放在 flash，不占 RAM）
 * ================================================================
 * INDEX_HTML  控制台单页（约 22KB）。用 server 分块推给浏览器，
 *             不要用 String 包它 —— 一次性拷贝会吃掉 20KB 堆。
 * MANIFEST_JSON / ICON_SVG  PWA 清单与图标，手机可以"添加到主屏幕"。
 *
 * 改页面：直接改下面的 HTML，重新编译即可。
 */
#pragma once

static const char MANIFEST_JSON[] = R"J({
"name":"OpenWrt 监控面板","short_name":"OpenWrt",
"start_url":"/","display":"standalone",
"background_color":"#070A14","theme_color":"#070A14",
"icons":[{"src":"/icon.svg","sizes":"any","type":"image/svg+xml","purpose":"any"}]
})J";

static const char ICON_SVG[] = R"I(<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 192 192'>
<defs><linearGradient id='g' x1='0' y1='0' x2='1' y2='1'>
<stop offset='0' stop-color='#4F8CFF'/><stop offset='1' stop-color='#8B5CF6'/></linearGradient></defs>
<rect width='192' height='192' rx='42' fill='url(#g)'/>
<rect x='42' y='96' width='108' height='40' rx='9' fill='#fff' opacity='.95'/>
<path d='M62 96 L54 62 M130 96 L138 62' stroke='#fff' stroke-width='9' stroke-linecap='round' opacity='.95'/>
<circle cx='66' cy='116' r='6' fill='#4F8CFF'/><circle cx='96' cy='116' r='6' fill='#4F8CFF'/>
<circle cx='126' cy='116' r='6' fill='#4F8CFF'/>
</svg>)I";

static const char INDEX_HTML[] = R"HTML(<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#070A14">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="OpenWrt 监控">
<link rel="manifest" href="/manifest.json">
<link rel="icon" href="/icon.svg">
<link rel="apple-touch-icon" href="/icon.svg">
<title>OpenWrt 监控面板</title>
<style>
:root{
  --bg:#070A14; --bg2:#101733; --card:#151D36; --card2:#1D2748; --line:#2C3860;
  --txt:#EAF0FF; --dim:#96A3C6; --mute:#5D6A8E;
  --acc:#4F8CFF; --acc2:#8B5CF6; --cyan:#22D3EE;
  --ok:#22C55E; --warn:#F59E0B; --danger:#EF4444; --warm:#FF8A3D;
  --r:16px;
}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent;margin:0;padding:0}
html,body{height:100%}
body{
  font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Noto Sans SC","Microsoft YaHei",sans-serif;
  background:
    radial-gradient(1100px 560px at 100% -8%, rgba(79,140,255,.16), transparent 60%),
    radial-gradient(820px 460px at -10% 108%, rgba(139,92,246,.14), transparent 60%),
    linear-gradient(180deg,var(--bg),var(--bg2));
  color:var(--txt);min-height:100%;max-width:720px;margin:0 auto;
  padding:0 14px calc(26px + env(safe-area-inset-bottom));
  -webkit-font-smoothing:antialiased;font-size:15px;
}
/* ---------------- 顶栏 ---------------- */
.topbar{position:sticky;top:0;z-index:30;margin:0 -14px 12px;padding:12px 14px 0;
  background:linear-gradient(180deg,rgba(7,10,20,.97),rgba(7,10,20,.85));
  backdrop-filter:blur(14px);-webkit-backdrop-filter:blur(14px);
  border-bottom:1px solid rgba(44,56,96,.6)}
header{display:flex;align-items:center;justify-content:space-between;gap:10px;padding-bottom:10px}
.brand{display:flex;align-items:center;gap:11px;min-width:0}
.logo{width:38px;height:38px;border-radius:12px;flex:none;background:linear-gradient(135deg,var(--acc),var(--acc2));
  display:grid;place-items:center;box-shadow:0 6px 18px rgba(79,140,255,.35)}
.logo svg{width:22px;height:22px}
h1{font-size:17px;font-weight:800;letter-spacing:.3px}
.sub{font-size:11.5px;color:var(--mute);margin-top:2px;white-space:nowrap;overflow:hidden;
  text-overflow:ellipsis;max-width:52vw;font-variant-numeric:tabular-nums}
.status{display:flex;align-items:center;gap:7px;font-size:12.5px;color:var(--dim);
  font-variant-numeric:tabular-nums;white-space:nowrap}
.dot{width:9px;height:9px;border-radius:50%;background:var(--mute);flex:none}
.dot.on{background:var(--ok);box-shadow:0 0 0 4px rgba(34,197,94,.16);animation:pl 2.2s infinite}
.dot.warn{background:var(--warn);box-shadow:0 0 0 4px rgba(245,158,11,.16)}
.dot.off{background:var(--danger)}
@keyframes pl{50%{box-shadow:0 0 0 9px rgba(34,197,94,0)}}
/* ---------------- 页签 ---------------- */
.tabs{display:flex;gap:8px;overflow-x:auto;padding:0 0 11px;scrollbar-width:none}
.tabs::-webkit-scrollbar{display:none}
.tabs button{flex:none;background:rgba(255,255,255,.055);border:1px solid var(--line);color:var(--dim);
  border-radius:999px;padding:8px 15px;font-size:13px;font-weight:650;cursor:pointer;transition:.16s;
  white-space:nowrap;font-family:inherit}
.tabs button.active{background:linear-gradient(135deg,var(--acc),var(--acc2));border-color:transparent;color:#fff;
  box-shadow:0 6px 18px rgba(79,140,255,.32)}
.tabs button:active{transform:scale(.95)}
/* ---------------- 卡片 ---------------- */
.page{display:none}
.page.on{display:block;animation:fade .18s ease}
@keyframes fade{from{opacity:0;transform:translateY(5px)}to{opacity:1;transform:none}}
.card{position:relative;background:linear-gradient(180deg,var(--card),var(--card2));
  border:1px solid var(--line);border-radius:var(--r);padding:14px 15px;margin-bottom:12px;
  box-shadow:0 10px 30px rgba(0,0,0,.30)}
.card::before{content:'';position:absolute;inset:0 0 auto;height:1px;border-radius:var(--r) var(--r) 0 0;
  background:linear-gradient(90deg,transparent,rgba(255,255,255,.16),transparent)}
.card h2{display:flex;align-items:center;gap:8px;font-size:12.5px;font-weight:700;color:var(--dim);
  letter-spacing:.5px;margin-bottom:11px}
.card h2 .right{margin-left:auto;font-weight:600;color:var(--mute);font-size:11.5px;letter-spacing:0}
/* ---------------- 指标网格 ---------------- */
.grid{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-bottom:12px}
.stat{background:linear-gradient(180deg,var(--card),var(--card2));border:1px solid var(--line);
  border-radius:14px;padding:12px 13px}
.stat .k{font-size:11px;color:var(--mute);letter-spacing:.5px;display:flex;align-items:center;gap:6px}
.stat .v{font-size:26px;font-weight:800;margin-top:6px;font-variant-numeric:tabular-nums;line-height:1.1}
.stat .v small{font-size:13px;font-weight:600;color:var(--dim);margin-left:2px}
.bar{height:5px;border-radius:999px;background:rgba(44,56,96,.65);margin-top:9px;overflow:hidden}
.bar i{display:block;height:100%;border-radius:999px;width:0;transition:width .35s ease}
/* ---------------- 键值行 ---------------- */
.kv{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:9px 0;
  border-bottom:1px solid rgba(44,56,96,.45);font-size:14px}
.kv:last-child{border-bottom:none;padding-bottom:1px}
.kv .k{color:var(--dim);display:flex;align-items:center;gap:8px;flex:none}
.kv .v{font-weight:650;font-variant-numeric:tabular-nums;text-align:right;
  overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12.5px}
/* ---------------- 图表 ---------------- */
.chartwrap{position:relative;height:148px;margin-top:4px}
canvas{width:100%;height:100%;display:block}
.legend{display:flex;gap:16px;font-size:12px;color:var(--dim);margin-top:8px}
.legend i{display:inline-block;width:9px;height:9px;border-radius:3px;margin-right:6px}
/* ---------------- 列表 ---------------- */
.row{display:flex;align-items:center;gap:10px;padding:10px 0;border-bottom:1px solid rgba(44,56,96,.45)}
.row:last-child{border-bottom:none}
.row .nm{font-size:14px;font-weight:650}
.row .rm{font-size:11.5px;color:var(--mute);margin-top:2px}
.row .sp{margin-left:auto;display:flex;align-items:center;gap:9px}
.pill{font-size:11px;font-weight:700;padding:3px 9px;border-radius:999px;border:1px solid}
.pill.ok{color:var(--ok);border-color:rgba(34,197,94,.45);background:rgba(34,197,94,.12)}
.pill.warn{color:var(--warn);border-color:rgba(245,158,11,.45);background:rgba(245,158,11,.12)}
.pill.bad{color:var(--danger);border-color:rgba(239,68,68,.45);background:rgba(239,68,68,.12)}
.pill.acc{color:var(--acc);border-color:rgba(79,140,255,.45);background:rgba(79,140,255,.12)}
.bars{display:flex;align-items:flex-end;gap:2px;height:14px}
.bars span{width:3px;border-radius:2px;background:var(--line)}
/* ---------------- 表单 ---------------- */
label.f{display:block;font-size:11.5px;color:var(--mute);letter-spacing:.4px;margin:10px 0 6px}
input[type=text],input[type=password],input[type=number]{
  width:100%;background:rgba(7,10,20,.55);border:1px solid var(--line);border-radius:11px;
  padding:11px 12px;color:var(--txt);font-size:14.5px;font-family:inherit;outline:none}
input:focus{border-color:var(--acc);box-shadow:0 0 0 3px rgba(79,140,255,.16)}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:7px;background:rgba(255,255,255,.055);
  border:1px solid var(--line);color:var(--txt);border-radius:11px;padding:10px 14px;font-size:13.5px;
  font-weight:650;cursor:pointer;font-family:inherit;transition:.15s;-webkit-appearance:none}
.btn:active{transform:scale(.97)}
.btn.primary{background:linear-gradient(135deg,var(--acc),var(--acc2));border-color:transparent;
  box-shadow:0 6px 18px rgba(79,140,255,.28)}
.btn.ghost{background:transparent}
.btn.danger{color:#FCA5A5;border-color:rgba(239,68,68,.45);background:rgba(239,68,68,.10)}
.btnrow{display:flex;gap:8px;flex-wrap:wrap;margin-top:12px}
.seg{display:flex;gap:7px;flex-wrap:wrap}
.seg button{flex:1;min-width:58px;background:rgba(255,255,255,.055);border:1px solid var(--line);
  color:var(--dim);border-radius:11px;padding:9px 4px;font-size:13px;cursor:pointer;font-weight:600;
  font-family:inherit;transition:.15s}
.seg button.active{background:linear-gradient(135deg,rgba(79,140,255,.32),rgba(139,92,246,.24));
  border-color:var(--acc);color:#fff}
input[type=range]{-webkit-appearance:none;appearance:none;width:100%;height:7px;border-radius:999px;
  background:linear-gradient(90deg,var(--acc) var(--p,100%),var(--line) var(--p,100%));outline:none;margin-top:6px}
input[type=range]::-webkit-slider-thumb{-webkit-appearance:none;width:22px;height:22px;border-radius:50%;
  background:#fff;border:3px solid var(--acc);box-shadow:0 2px 10px rgba(0,0,0,.45);cursor:pointer}
input[type=range]::-moz-range-thumb{width:17px;height:17px;border-radius:50%;background:#fff;border:3px solid var(--acc)}
/* ---------------- 提示条 ---------------- */
#toast{position:fixed;left:50%;bottom:26px;transform:translate(-50%,20px);opacity:0;pointer-events:none;
  background:rgba(11,18,32,.96);border:1px solid rgba(79,140,255,.5);color:var(--txt);
  padding:10px 16px;border-radius:999px;font-size:13px;font-weight:600;transition:.25s;z-index:99;
  box-shadow:0 10px 30px rgba(0,0,0,.5);max-width:90vw;text-align:center}
#toast.on{opacity:1;transform:translate(-50%,0)}
.hint{font-size:11.5px;color:var(--mute);line-height:1.7;margin-top:8px}
.empty{font-size:12.5px;color:var(--mute);padding:10px 0}
</style>
</head>
<body>

<div class="topbar">
  <header>
    <div class="brand">
      <div class="logo">
        <svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round">
          <rect x="3" y="12" width="18" height="7" rx="2"/><path d="M7 12 5.5 6M17 12l1.5-6"/>
          <circle cx="7.5" cy="15.5" r="1.1" fill="#fff" stroke="none"/>
          <circle cx="12" cy="15.5" r="1.1" fill="#fff" stroke="none"/>
          <circle cx="16.5" cy="15.5" r="1.1" fill="#fff" stroke="none"/>
        </svg>
      </div>
      <div>
        <h1>OpenWrt 监控</h1>
        <div class="sub" id="sub">正在连接面板…</div>
      </div>
    </div>
    <div class="status"><span class="dot" id="dot"></span><span id="clock">--:--</span></div>
  </header>
  <nav class="tabs" id="tabs">
    <button class="active" data-p="0">概览</button>
    <button data-p="1">系统</button>
    <button data-p="2">流量</button>
    <button data-p="3">无线</button>
    <button data-p="4">设置</button>
  </nav>
</div>

<!-- ================= 概览 ================= -->
<section class="page on" id="p0">
  <div class="grid">
    <div class="stat">
      <div class="k">CPU 负载 (1m)</div>
      <div class="v" id="ovLoad">--</div>
      <div class="bar"><i id="ovLoadBar" style="background:linear-gradient(90deg,#4F8CFF,#8B5CF6)"></i></div>
    </div>
    <div class="stat">
      <div class="k">内存占用</div>
      <div class="v" id="ovMem">--</div>
      <div class="bar"><i id="ovMemBar" style="background:linear-gradient(90deg,#8B5CF6,#22D3EE)"></i></div>
    </div>
    <div class="stat">
      <div class="k">下载</div>
      <div class="v" id="ovDl" style="color:var(--ok)">--</div>
      <div class="bar"><i id="ovDlBar" style="background:#22C55E"></i></div>
    </div>
    <div class="stat">
      <div class="k">上传</div>
      <div class="v" id="ovUl" style="color:var(--warm)">--</div>
      <div class="bar"><i id="ovUlBar" style="background:#FF8A3D"></i></div>
    </div>
  </div>

  <div class="card">
    <h2>路由器<span class="right" id="ovOnline">--</span></h2>
    <div class="kv"><span class="k">主机名</span><span class="v" id="ovHost">--</span></div>
    <div class="kv"><span class="k">型号</span><span class="v" id="ovModel">--</span></div>
    <div class="kv"><span class="k">固件</span><span class="v" id="ovFw">--</span></div>
    <div class="kv"><span class="k">WAN IP</span><span class="v mono" id="ovWan">--</span></div>
    <div class="kv"><span class="k">运行时长</span><span class="v" id="ovUp">--</span></div>
    <div class="kv"><span class="k">无线客户端</span><span class="v" id="ovCli">--</span></div>
  </div>
</section>

<!-- ================= 系统 ================= -->
<section class="page" id="p1">
  <div class="card">
    <h2>系统信息</h2>
    <div class="kv"><span class="k">主机名</span><span class="v" id="syHost">--</span></div>
    <div class="kv"><span class="k">型号</span><span class="v" id="syModel">--</span></div>
    <div class="kv"><span class="k">内核</span><span class="v mono" id="syKernel">--</span></div>
    <div class="kv"><span class="k">固件版本</span><span class="v" id="syRel">--</span></div>
    <div class="kv"><span class="k">运行时长</span><span class="v" id="syUp">--</span></div>
  </div>

  <div class="card">
    <h2>负载<span class="right" id="syLoadTip">--</span></h2>
    <div class="kv"><span class="k">1 分钟</span><span class="v" id="syL1">--</span></div>
    <div class="bar" style="margin:2px 0 8px"><i id="syL1Bar" style="background:#22D3EE"></i></div>
    <div class="kv"><span class="k">5 分钟</span><span class="v" id="syL5">--</span></div>
    <div class="bar" style="margin:2px 0 8px"><i id="syL5Bar" style="background:#4F8CFF"></i></div>
    <div class="kv"><span class="k">15 分钟</span><span class="v" id="syL15">--</span></div>
    <div class="bar" style="margin:2px 0 0"><i id="syL15Bar" style="background:#8B5CF6"></i></div>
  </div>

  <div class="card">
    <h2>内存</h2>
    <div class="kv"><span class="k">已用 / 总量</span><span class="v" id="syMem">--</span></div>
    <div class="bar" style="margin:2px 0 8px"><i id="syMemBar" style="background:linear-gradient(90deg,#8B5CF6,#22D3EE)"></i></div>
    <div class="kv"><span class="k">缓存 / 缓冲</span><span class="v" id="syCache">--</span></div>
    <div class="kv"><span class="k">Swap</span><span class="v" id="sySwap">--</span></div>
  </div>

  <div class="card">
    <h2>本机面板</h2>
    <div class="kv"><span class="k">剩余内存</span><span class="v" id="syHeap">--</span></div>
    <div class="kv"><span class="k">WiFi 信号</span><span class="v" id="syRssi">--</span></div>
    <div class="kv"><span class="k">面板 IP</span><span class="v mono" id="syIp">--</span></div>
    <div class="kv"><span class="k">已运行</span><span class="v" id="syPanelUp">--</span></div>
    <div class="kv"><span class="k">固件版本</span><span class="v" id="syVer">--</span></div>
  </div>
</section>

<!-- ================= 流量 ================= -->
<section class="page" id="p2">
  <div class="card">
    <h2>实时速率<span class="right" id="ntPeak">峰值 --</span></h2>
    <div class="chartwrap"><canvas id="cv"></canvas></div>
    <div class="legend">
      <span><i style="background:#22C55E"></i>下载 <b id="lgDl">--</b></span>
      <span><i style="background:#FF8A3D"></i>上传 <b id="lgUl">--</b></span>
    </div>
  </div>
  <div class="card">
    <h2>接口</h2>
    <div class="kv"><span class="k">上行设备</span><span class="v mono" id="ntIface">--</span></div>
    <div class="kv"><span class="k">WAN IP</span><span class="v mono" id="ntWan">--</span></div>
    <div class="kv"><span class="k">协议</span><span class="v" id="ntProto">--</span></div>
    <div class="kv"><span class="k">链路速率</span><span class="v" id="ntLink">--</span></div>
    <div class="kv"><span class="k">累计接收</span><span class="v" id="ntRx">--</span></div>
    <div class="kv"><span class="k">累计发送</span><span class="v" id="ntTx">--</span></div>
  </div>
</section>

<!-- ================= 无线 ================= -->
<section class="page" id="p3">
  <div class="card">
    <h2>无线客户端<span class="right" id="wfCount">--</span></h2>
    <div id="wfList"><div class="empty">等待路由器数据…</div></div>
  </div>
  <div class="card">
    <h2>说明</h2>
    <div class="hint">数据来自路由器的 <b>iwinfo.assoclist</b>（OpenWrt 自带）。
      信号强度 -50 dBm 以上为优，-70 以下体验开始变差。</div>
  </div>
</section>

<!-- ================= 设置 ================= -->
<section class="page" id="p4">
  <div class="card">
    <h2>WiFi 配网</h2>
    <label class="f">当前网络</label>
    <div class="kv"><span class="k">当前 SSID</span><span class="v" id="cfSsid">--</span></div>
    <label class="f">SSID</label>
    <input type="text" id="inSsid" placeholder="要连接的 WiFi 名称" autocomplete="off">
    <label class="f">密码</label>
    <input type="password" id="inPass" placeholder="留空表示开放网络">
    <div class="btnrow">
      <button class="btn primary" onclick="saveWifi()">连接并保存</button>
      <button class="btn ghost" onclick="scanWifi()">扫描附近</button>
      <button class="btn danger" onclick="forgetWifi()">忘记网络</button>
    </div>
    <div id="scanBox"></div>
  </div>

  <div class="card">
    <h2>OpenWrt 登录</h2>
    <label class="f">路由器地址（留空 = 用当前网关）</label>
    <input type="text" id="inIp" placeholder="例如 192.168.1.1" autocomplete="off">
    <label class="f">用户名</label>
    <input type="text" id="inUser" placeholder="root" autocomplete="off">
    <label class="f">密码</label>
    <input type="password" id="inPw" placeholder="ubus 登录密码">
    <div class="btnrow"><button class="btn primary" onclick="saveRouter()">保存并重连</button></div>
    <div class="hint">面板用 ubus（<b>/ubus</b> JSON-RPC）读取数据，不需要在路由器上装任何插件。</div>
  </div>

  <div class="card">
    <h2>刷新周期</h2>
    <div class="seg" id="pollSeg">
      <button data-ms="2000">2 秒</button>
      <button data-ms="3000">3 秒</button>
      <button data-ms="5000">5 秒</button>
      <button data-ms="10000">10 秒</button>
    </div>
    <div class="hint">周期越短越实时，路由器负载也越高。默认 3 秒。</div>
  </div>

  <div class="card">
    <h2>屏幕背光<span class="right" id="briVal">--</span></h2>
    <input type="range" id="bri" min="10" max="100" step="5" value="100">
    <div class="hint">拖动即时生效，松手保存到 EEPROM。</div>
  </div>

  <div class="card">
    <h2>面板操作</h2>
    <div class="kv"><span class="k">访问地址</span><span class="v mono" id="cfUrl">--</span></div>
    <div class="kv"><span class="k">mDNS</span><span class="v mono" id="cfMdns">openwrt-monitor.local</span></div>
    <div class="kv"><span class="k">剩余内存</span><span class="v" id="cfHeap">--</span></div>
    <div class="btnrow">
      <button class="btn" onclick="cmd({c:'reboot'})">重启面板</button>
      <button class="btn ghost" onclick="switchTab(0)">回到概览</button>
    </div>
  </div>
</section>

<div id="toast"></div>

<script>
/* ============================ 工具 ============================ */
const $ = id => document.getElementById(id);
function toast(t){const el=$('toast');el.textContent=t;el.classList.add('on');
  clearTimeout(el._t);el._t=setTimeout(()=>el.classList.remove('on'),1800);}
function fmtBytes(v){v=+v||0;
  if(v<1024)return v+' B';
  if(v<1048576)return (v/1024).toFixed(0)+' KB';
  if(v<1073741824)return (v/1048576).toFixed(1)+' MB';
  return (v/1073741824).toFixed(2)+' GB';}
function fmtKBps(v){v=+v||0;return v<1024?v.toFixed(0)+' KB/s':(v/1024).toFixed(1)+' MB/s';}
function fmtUp(s){s=+s||0;const d=Math.floor(s/86400);
  const h=String(Math.floor(s%86400/3600)).padStart(2,'0');
  const m=String(Math.floor(s%3600/60)).padStart(2,'0');
  return d>0?`${d} 天 ${h}:${m}`:`${h}:${m}`;}
function setT(id,v){const e=$(id);if(e&&e.textContent!==String(v))e.textContent=v;}
function bar(id,pct){const e=$(id);if(e)e.style.width=Math.max(0,Math.min(100,pct))+'%';}

/* ============================ 状态与渲染 ============================ */
let S=null, hist=[], HIST=60, lastTab=-1, devScreen=-1, lastAck=0;

function apply(st){
  S=st; lastAck=Date.now();
  const up=st.wifi&&st.wifi.up, on=st.rtr&&st.rtr.online;
  $('dot').className='dot '+(up?(on?'on':'warn'):'off');
  setT('sub',(up?st.wifi.ssid||'已连接':'未连接 WiFi')+' · '+(on?'已同步':'等待路由器'));
  setT('clock',new Date().toLocaleTimeString('zh-CN',{hour:'2-digit',minute:'2-digit'}));

  /* --- 概览 --- */
  const r=st.rtr||{}, m=r.mem||{}, n=st.net||{}, c=st.cli||{};
  const l1=(r.load&&r.load[0])||0;
  setT('ovLoad',l1.toFixed(2)); bar('ovLoadBar',l1*100);
  setT('ovMem',(m.pct||0)+'%'); bar('ovMemBar',m.pct||0);
  setT('ovDl',fmtKBps(n.dl)); bar('ovDlBar',n.peak?n.dl/n.peak*100:0);
  setT('ovUl',fmtKBps(n.ul)); bar('ovUlBar',n.peak?n.ul/n.peak*100:0);
  setT('ovHost',r.host||'--'); setT('ovModel',r.model||'--');
  setT('ovFw',r.release||'--'); setT('ovWan',n.wan||'--');
  setT('ovUp',fmtUp(r.up)); setT('ovCli',(c.total||0)+' 台');
  setT('ovOnline',on?'在线':'离线');
  $('ovOnline').style.color=on?'var(--ok)':'var(--danger)';

  /* --- 系统 --- */
  setT('syHost',r.host||'--'); setT('syModel',r.model||'--');
  setT('syKernel',r.kernel||'--'); setT('syRel',r.release||'--');
  setT('syUp',fmtUp(r.up));
  const ld=r.load||[0,0,0];
  setT('syL1',ld[0].toFixed(2)); bar('syL1Bar',ld[0]*100);
  setT('syL5',ld[1].toFixed(2)); bar('syL5Bar',ld[1]*100);
  setT('syL15',ld[2].toFixed(2)); bar('syL15Bar',ld[2]*100);
  setT('syLoadTip','1 / 5 / 15 分钟');
  setT('syMem',fmtBytes((m.used||0)*1024)+' / '+fmtBytes((m.total||0)*1024));
  bar('syMemBar',m.pct||0);
  setT('syCache',fmtBytes((m.cached||0)*1024)+' / '+fmtBytes((m.buffered||0)*1024));
  const sw=r.swap||{};
  setT('sySwap',sw.total?fmtBytes((sw.used||0)*1024)+' / '+fmtBytes(sw.total*1024):'未启用');
  setT('syHeap',fmtBytes((st.sys||{}).heap||0));
  setT('syRssi',(st.wifi&&st.wifi.rssi?st.wifi.rssi:'--')+' dBm');
  setT('syIp',(st.wifi&&st.wifi.ip)||'--');
  setT('syPanelUp',fmtUp((st.sys||{}).up));
  setT('syVer',st.fw||'--');

  /* --- 流量 --- */
  hist.push({dl:+n.dl||0,ul:+n.ul||0});
  if(hist.length>HIST)hist.shift();
  setT('ntPeak','峰值 '+fmtKBps(n.peak));
  setT('lgDl',fmtKBps(n.dl)); setT('lgUl',fmtKBps(n.ul));
  setT('ntIface',n.iface||'--'); setT('ntWan',n.wan||'--');
  setT('ntProto',n.proto||'--');
  setT('ntLink',n.link?n.link+' Mbps':'--');
  setT('ntRx',fmtBytes(n.rx)); setT('ntTx',fmtBytes(n.tx));
  drawChart();

  /* --- 无线 --- */
  setT('wfCount',(c.total||0)+' 台 · '+(c.radios||0)+' 个射频');
  renderClients(c.list||[]);

  /* --- 设置（只在没聚焦时回填，别抢用户输入） --- */
  setT('cfSsid',(st.wifi&&st.wifi.ssid)||'--');
  setT('cfUrl',location.origin);
  setT('cfHeap',fmtBytes((st.sys||{}).heap||0));
  setT('briVal',((st.sys||{}).bright||100)+'%');
  const bri=$('bri');
  if(document.activeElement!==bri){bri.value=(st.sys||{}).bright||100;
    bri.style.setProperty('--p',bri.value+'%');}
  document.querySelectorAll('#pollSeg button').forEach(b=>{
    b.classList.toggle('active',+b.dataset.ms===+(st.sys||{}).poll);
  });
  /* 屏幕跟随：只在设备侧真的换了页时跟一次。
     不能写成 st.screen!==lastTab —— 那样用户点开"设置"后，下一帧就会被拉回概览。 */
  if(typeof st.screen==='number'&&st.screen!==devScreen){
    devScreen=st.screen;
    if(st.screen!==lastTab)switchTab(st.screen,true);
  }
}

function renderClients(list){
  const box=$('wfList');
  if(!list.length){box.innerHTML='<div class="empty">当前没有无线客户端连接</div>';return;}
  let h='';
  for(const c of list){
    const q=c.rssi, cls=q>-65?'ok':(q>-78?'warn':'bad');
    let bars='';
    const lvl=q>-55?5:q>-65?4:q>-72?3:q>-80?2:1;
    for(let i=0;i<5;i++)bars+=`<span style="height:${4+i*2.5}px;background:${i<lvl?'var(--ok)':'var(--line)'}"></span>`;
    h+=`<div class="row">
      <div><div class="nm mono">${c.mac}</div>
      <div class="rm">${q} dBm${c.rate?' · '+c.rate+' Mbps':''}</div></div>
      <div class="sp"><div class="bars">${bars}</div>
      <span class="pill ${cls}">${q>-65?'优':q>-78?'良':'弱'}</span></div></div>`;
  }
  box.innerHTML=h;
}

/* ============================ 图表 ============================ */
const cv=$('cv');
function drawChart(){
  const dpr=window.devicePixelRatio||1;
  const w=cv.clientWidth||300, h=cv.clientHeight||148;
  if(cv.width!==w*dpr||cv.height!==h*dpr){cv.width=w*dpr;cv.height=h*dpr;}
  const g=cv.getContext('2d');
  g.setTransform(dpr,0,0,dpr,0,0);
  g.clearRect(0,0,w,h);
  const peak=(S&&S.net&&S.net.peak)||64;
  const max=Math.max(peak,64)*1.05;
  /* 网格 */
  g.strokeStyle='rgba(44,56,96,.55)';g.lineWidth=1;
  for(let i=1;i<4;i++){const y=h*i/4;g.beginPath();g.moveTo(0,y);g.lineTo(w,y);g.stroke();}
  if(hist.length<2)return;
  const px=i=>i*(w/(HIST-1));
  function line(key,color){
    g.beginPath();
    hist.forEach((p,i)=>{const y=h-(p[key]/max)*h;i?g.lineTo(px(i),y):g.moveTo(px(i),y);});
    g.strokeStyle=color;g.lineWidth=2;g.lineJoin='round';g.stroke();
    /* 底部渐变填充 */
    g.lineTo(px(hist.length-1),h);g.lineTo(px(0),h);g.closePath();
    const grad=g.createLinearGradient(0,0,0,h);
    grad.addColorStop(0,color+'55');grad.addColorStop(1,color+'00');
    g.fillStyle=grad;g.fill();
  }
  line('dl','#22C55E');
  line('ul','#FF8A3D');
  /* 顶部刻度：画在右下角，别跟卡片标题挤在一起 */
  g.fillStyle='rgba(150,163,198,.55)';g.font='10px ui-monospace,monospace';
  g.textAlign='right';g.fillText('max '+fmtKBps(max),w-4,h-4);g.textAlign='left';
}

/* ============================ 交互 ============================ */
function switchTab(p,fromDevice){
  lastTab=p;
  document.querySelectorAll('.page').forEach((el,i)=>el.classList.toggle('on',i===p));
  document.querySelectorAll('#tabs button').forEach(b=>b.classList.toggle('active',+b.dataset.p===p));
  if(!fromDevice)cmd({c:'ui',id:p});
  if(p===2)drawChart();
}
document.querySelectorAll('#tabs button').forEach(b=>{
  b.onclick=()=>switchTab(+b.dataset.p);
});

async function cmd(body){
  try{
    const r=await fetch('/api',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify(body)});
    const j=await r.json();
    if(!j.ok)toast('操作失败');
    return j;
  }catch(e){toast('请求失败：'+e.message);return {ok:0};}
}

function saveWifi(){
  const ssid=$('inSsid').value.trim(), pass=$('inPass').value;
  if(!ssid){toast('请填写 WiFi 名称');return;}
  cmd({c:'wifi',ssid,pass}).then(()=>{toast('已提交，正在连接 '+ssid);$('inPass').value='';});
}
function forgetWifi(){ if(confirm('清除保存的 WiFi 并进入配网页面？')) cmd({c:'forget'}); }
function saveRouter(){
  cmd({c:'router',ip:$('inIp').value.trim(),user:$('inUser').value.trim(),pass:$('inPw').value})
    .then(()=>toast('已保存，正在重新登录路由器'));
}
function scanWifi(){
  cmd({c:'scan'}); toast('正在扫描…');
  setTimeout(()=>{
    if(!S||!S.ap){$('scanBox').innerHTML='<div class="hint">还没有扫描结果，稍后再看。</div>';return;}
    let h='<label class="f">附近的网络</label>';
    for(const a of S.ap){
      const cls=a.rssi>-65?'ok':(a.rssi>-78?'warn':'bad');
      h+=`<div class="row" onclick="pickSsid('${a.ssid.replace(/'/g,"\\'")}')">
        <div><div class="nm">${a.ssid}</div><div class="rm">${a.rssi} dBm ${a.sec?'· 加密':'· 开放'}</div></div>
        <div class="sp"><span class="pill ${cls}">选择</span></div></div>`;
    }
    $('scanBox').innerHTML=h;
  },4200);
}
function pickSsid(s){$('inSsid').value=s;toast('已填入 '+s);}

$('bri').addEventListener('input',e=>{
  const v=e.target.value;
  e.target.style.setProperty('--p',v+'%');
  setT('briVal',v+'%');
});
$('bri').addEventListener('change',e=>cmd({c:'bright',pct:+e.target.value}));
document.querySelectorAll('#pollSeg button').forEach(b=>{
  b.onclick=()=>cmd({c:'poll',ms:+b.dataset.ms}).then(()=>{
    document.querySelectorAll('#pollSeg button').forEach(x=>x.classList.toggle('active',x===b));
  });
});

/* ============================ 数据通道 ============================ */
/* SSE 在 81 端口：ESP32 的 WebServer 不支持长连接，所以推送单独走一个裸 socket。
   万一浏览器拦了跨端口请求，下面的轮询会兜底，最多 5 秒刷新一次。 */
let es=null, sseOk=false;
function connectSSE(){
  if(!window.EventSource)return;
  try{
    es=new EventSource(`http://${location.hostname}:81/events`);
    es.onopen=()=>{sseOk=true;};
    es.onmessage=e=>{
      try{apply(JSON.parse(e.data));}catch(_){}
    };
    es.onerror=()=>{sseOk=false;if(es){es.close();es=null;}setTimeout(connectSSE,4000);};
  }catch(_){}
}

async function pollOnce(){
  try{
    const r=await fetch('/api/state',{cache:'no-store'});
    if(!r.ok)return;
    apply(await r.json());
  }catch(_){
    $('dot').className='dot off';
    setT('sub','连不上面板');
  }
}

/* 首屏：先拉一次，再开推送；之后每 5 秒兜底轮询一次（SSE 正常时几乎无感） */
pollOnce().then(()=>{
  connectSSE();
  setInterval(()=>{ if(!sseOk || Date.now()-lastAck>6000) pollOnce(); },5000);
});
setInterval(()=>{setT('clock',new Date().toLocaleTimeString('zh-CN',{hour:'2-digit',minute:'2-digit'}));},20000);
window.addEventListener('resize',drawChart);
</script>
</body>
</html>)HTML";
