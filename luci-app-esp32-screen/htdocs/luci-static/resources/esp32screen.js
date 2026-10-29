/* esp32screen.js —— 三个页面共用的「跟屏幕说话」的工具。
 * 用 'require esp32screen' 引入（模块名不能有短横线，否则注入不了变量名）。
 *
 * LuCI 跑在路由器上，屏幕是局域网里另一台设备，所以这里全部是浏览器直连
 * （固件那边的 /api 与 :81 都开了 Access-Control-Allow-Origin: *）：
 *
 *   GET  http://<屏>/api/state      取状态
 *   POST http://<屏>/api            发命令（切页/亮度/重启/改 WiFi/改路由器账号）
 *   POST http://<屏>:81/draw_rgb565 推一帧画面
 *   GET  http://<屏>:81/cast_exit   退出投屏
 *
 * 只有「配置存哪」走 ubus（UCI），因为那是路由器自己的状态。
 */
'use strict';
'require baseclass';
'require rpc';

return baseclass.extend({
	/* ---------------------------------------------------------- UCI 配置 */
	getConfig: rpc.declare({
		object: 'luci.esp32-screen',
		method: 'get',
		expect: { config: {} }
	}),

	setConfig: rpc.declare({
		object: 'luci.esp32-screen',
		method: 'set',
		params: [ 'values' ]
	}),

	/* 浏览器够不着面板时（跨 VLAN、从外网连 LuCI），让路由器自己去问 */
	probe: rpc.declare({
		object: 'luci.esp32-screen',
		method: 'probe',
		params: [ 'host' ]
	}),

	/* ---------------------------------------------------------- 面板 HTTP */
	baseUrl: function(host) {
		host = String(host || '').trim();
		if (!host) return null;
		if (!/^[a-z]+:\/\//i.test(host)) host = 'http://' + host;
		return host.replace(/\/+$/, '');
	},

	state: function(host) {
		var url = this.baseUrl(host);
		if (!url) return Promise.reject(new Error('未配置屏幕地址'));
		return fetch(url + '/api/state', { cache: 'no-store' })
			.then(function(r) {
				if (!r.ok) throw new Error('HTTP ' + r.status);
				return r.json();
			});
	},

	cmd: function(host, obj) {
		var url = this.baseUrl(host);
		if (!url) return Promise.reject(new Error('未配置屏幕地址'));
		return fetch(url + '/api', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			cache: 'no-store',
			body: JSON.stringify(obj)
		}).then(function(r) { return r.text(); });
	},

	castExit: function(host) {
		var url = this.baseUrl(host);
		if (!url) return Promise.resolve('');
		return fetch(url + ':81/cast_exit', { cache: 'no-store' })
			.then(function(r) { return r.text(); });
	},

	/* 画布 -> RGB565（每像素 2 字节，高字节在前）-> POST 给屏幕。
	   153,600 字节，本地网一帧几十毫秒。不带 Content-Type 就是 simple request，
	   浏览器不会先发 OPTIONS 预检。 */
	pushFrame: function(host, canvas) {
		var url = this.baseUrl(host);
		if (!url) return Promise.reject(new Error('未配置屏幕地址'));
		if (canvas.width !== 320 || canvas.height !== 240)
			return Promise.reject(new Error('画布必须是 320x240'));

		var ctx = canvas.getContext('2d');
		var img = ctx.getImageData(0, 0, 320, 240).data;
		var buf = new ArrayBuffer(320 * 240 * 2);
		var out = new DataView(buf);

		for (var i = 0, o = 0; i < img.length; i += 4, o += 2) {
			var r = img[i], g = img[i + 1], b = img[i + 2];
			out.setUint16(o, ((r & 0xf8) << 8) | ((g & 0xfc) << 3) | (b >> 3), false);
		}

		return fetch(url + ':81/draw_rgb565', {
			method: 'POST',
			cache: 'no-store',
			body: buf
		}).then(function(r) { return r.text(); });
	},

	/* ---------------------------------------------------------- 小工具 */
	fmtRate: function(bps) {
		if (bps == null) return '—';
		if (bps >= 1048576) return (bps / 1048576).toFixed(1) + ' MB/s';
		if (bps >= 1024) return Math.round(bps / 1024) + ' KB/s';
		return Math.round(bps) + ' B/s';
	},

	fmtBytes: function(kb) {
		if (kb == null) return '—';
		if (kb >= 1048576) return (kb / 1048576).toFixed(1) + ' GB';
		if (kb >= 1024) return (kb / 1024).toFixed(1) + ' MB';
		return Math.round(kb) + ' KB';
	},

	fmtUptime: function(s) {
		if (s == null) return '—';
		var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
		return (d > 0 ? d + '天' : '') + h + ':' + String(m).padStart(2, '0');
	}
});
