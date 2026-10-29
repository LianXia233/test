/* esp32-screen/cast —— 把画面推到屏幕上
 *
 * 三种模板：
 *   overview / traffic  用 canvas 直接画（数据取自面板的 /api/state）
 *   custom              用户自己写 HTML，用 <foreignObject> 光栅化到 canvas
 *                       （浏览器里没有 html2canvas 这类库，SVG foreignObject 是
 *                        唯一不引依赖就能把 HTML 变成位图的办法）
 *
 * 推送就是 canvas -> RGB565 -> POST :81/draw_rgb565（15 万字节，本地网几十毫秒）。
 * 固件那边 6 秒收不到帧会自己退回监控界面，所以连续推送的间隔别超过 5 秒。
 */
'use strict';
'require view';
'require ui';
'require esp32screen';

var TEMPLATES = {
	overview: '概览（处理器 / 内存 / 速率）',
	traffic: '流量（曲线）',
	custom: '自定义 HTML'
};

var SAMPLE_HTML = [
	'<div style="width:320px;height:240px;background:#070A14;color:#EAF0FF;',
	'     font-family:sans-serif;padding:12px;box-sizing:border-box">',
	'  <div style="font-size:12px;color:#96A3C6">{{hostname}}</div>',
	'  <div style="font-size:26px;margin-top:6px">{{uptime}}</div>',
	'  <div style="font-size:12px;color:#22D3EE;margin-top:10px">↓ {{dl}}　↑ {{ul}}</div>',
	'</div>'
].join('');

return view.extend({
	history: [],

	load: function() {
		return Promise.all([
			esp32screen.getConfig()
		]);
	},

	render: function(load) {
		var cfg = (load[0] && load[0].config) ? load[0].config : {};
		var self = this;

		var canvas = E('canvas', {
			'width': 320, 'height': 240,
			'style': 'width:640px;height:480px;image-rendering:pixelated;' +
			         'border:1px solid #2C3860;border-radius:8px;background:#000'
		});
		this.canvas = canvas;

		this.tpl = cfg.template || 'overview';
		this.html = cfg.custom_html || SAMPLE_HTML;
		/* 固件 6 秒收不到帧就退回监控界面，所以夹在 1~5 秒之间 */
		this.pushMs = Math.min(5000, Math.max(1000, (+cfg.push_interval || 4) * 1000));

		var sel = E('select', {
			'id': 'cast-tpl',
			'change': function(ev) {
				self.tpl = ev.target.value;
				document.getElementById('cast-html-row').style.display =
					(self.tpl === 'custom') ? 'block' : 'none';
			}
		}, Object.keys(TEMPLATES).map(function(k) {
			return E('option', { 'value': k, 'selected': (k === self.tpl) }, TEMPLATES[k]);
		}));

		var ta = E('textarea', {
			'id': 'cast-html',
			'style': 'width:100%;height:180px;font-family:monospace;font-size:12px',
			'spellcheck': 'false'
		});
		ta.value = this.html;

		var log = E('div', { 'id': 'cast-log', 'style': 'font-size:12px;color:#96A3C6' }, '就绪');

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', { 'name': 'content' }, '投屏'),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, '模板'),
						E('div', { 'class': 'cbi-value-field' }, sel)
					]),
					E('div', {
						'class': 'cbi-value', 'id': 'cast-html-row',
						'style': (this.tpl === 'custom') ? 'display:block' : 'display:none'
					}, [
						E('label', { 'class': 'cbi-value-title' }, '自定义 HTML'),
						E('div', { 'class': 'cbi-value-field' }, [
							ta,
							E('div', { 'style': 'font-size:12px;color:#96A3C6;margin-top:4px' },
								'可用占位符：{{hostname}} {{model}} {{kernel}} {{uptime}} ' +
								'{{load1}} {{mem}} {{dl}} {{ul}} {{clients}} {{wanip}} {{time}}')
						])
					])
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '预览（320×240，放大 2 倍显示）'),
				E('div', { 'class': 'cbi-section-node' }, canvas)
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'btn-group' }, [
						E('button', { 'class': 'btn primary', 'click': function() { self.render_(); } }, '重画预览'),
						E('button', { 'class': 'btn', 'click': function() { self.push(); } }, '推一帧'),
						E('button', { 'class': 'btn', 'click': function() { self.toggleAuto(); } }, '连续推送'),
						E('button', { 'class': 'btn', 'click': function() { esp32screen.castExit(cfg.host); } }, '退出投屏')
					]),
					E('div', { 'style': 'margin-top:8px' }, log)
				])
			])
		]);
	},

	/* ---------------------------------------------------------- 预览 */
	/* 取状态：浏览器直连优先，不行就让路由器代问（ubus probe） */
	render_: function() {
		var self = this;

		function draw(s) { self.state = s || {}; }

		esp32screen.getConfig().then(function(c) {
			var cfg = (c && c.config) ? c.config : {};
			return Promise.all([cfg.host, esp32screen.state(cfg.host)]);
		}).then(function(r) {
			self.host = r[0];
			draw(r[1]);
		})['catch'](function(e1) {
			esp32screen.probe(self.host).then(function(res) {
				if (res && res.state) draw(res.state);
				else self.log('取不到面板状态：' + ((res && res.error) || e1) + '（模板仍会按空数据画）');
				self.host = self.host || '';
			})['catch'](function() {
				self.log('取不到面板状态：' + e1 + '（模板仍会按空数据画）');
			});
		}).then(function() {
			if (self.tpl === 'custom') self.drawCustom();
			else self.drawTemplate(self.tpl);
		});
	},

	drawTemplate: function(tpl) {
		var self = this;
		var ctx = this.canvas.getContext('2d');
		var s = this.state || {}, r = s.rtr || {}, n = s.net || {}, c = s.cli || {};

		ctx.fillStyle = '#070A14';
		ctx.fillRect(0, 0, 320, 240);
		var g = ctx.createLinearGradient(0, 0, 0, 240);
		g.addColorStop(0, '#070A14'); g.addColorStop(1, '#101733');
		ctx.fillStyle = g; ctx.fillRect(0, 0, 320, 240);

		ctx.textBaseline = 'top';
		ctx.fillStyle = '#96A3C6'; ctx.font = '12px sans-serif';
		ctx.fillText(String(r.host || '—'), 12, 12);
		ctx.fillStyle = '#5D6A8E';
		ctx.fillText(String((s.wifi || {}).ssid || ''), 12, 28);

		if (tpl === 'traffic') {
			ctx.fillStyle = '#22D3EE'; ctx.font = '11px sans-serif';
			ctx.fillText('↓ ' + esp32screen.fmtRate((n.dl || 0) * 1024), 12, 52);
			ctx.fillStyle = '#FF8A3D';
			ctx.fillText('↑ ' + esp32screen.fmtRate((n.ul || 0) * 1024), 12, 68);

			/* 曲线：history 里存最近 40 个采样点 */
			this.history.push([n.dl || 0, n.ul || 0]);
			if (this.history.length > 40) this.history.shift();

			var max = 1;
			this.history.forEach(function(p) { max = Math.max(max, p[0], p[1]); });

			var X = 12, Y = 90, W = 296, H = 130, N = 40;
			ctx.strokeStyle = '#2C3860'; ctx.lineWidth = 1;
			ctx.strokeRect(X, Y, W, H);

			[['#22D3EE', 0], ['#FF8A3D', 1]].forEach(function(spec) {
				var idx = spec[1];
				ctx.strokeStyle = spec[0]; ctx.lineWidth = 2;
				ctx.beginPath();
				for (var i = 0; i < self.history.length; i++) {
					var px = X + Math.round(i * W / (N - 1));
					var py = Y + H - Math.round(self.history[i][idx] / max * (H - 6)) - 3;
					if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
				}
				ctx.stroke();
			});
			return;
		}

		/* overview */
		ctx.font = '28px sans-serif'; ctx.fillStyle = '#EAF0FF';
		ctx.fillText(((r.load || [])[0] != null ? (r.load[0]).toFixed(2) : '—'), 12, 52);
		ctx.font = '12px sans-serif'; ctx.fillStyle = '#96A3C6';
		ctx.fillText('处理器负载', 12, 84);

		ctx.font = '28px sans-serif'; ctx.fillStyle = '#EAF0FF';
		ctx.fillText((r.mem ? r.mem.pct + '%' : '—'), 170, 52);
		ctx.font = '12px sans-serif'; ctx.fillStyle = '#96A3C6';
		ctx.fillText('内存', 170, 84);

		ctx.font = '20px sans-serif';
		ctx.fillStyle = '#22D3EE'; ctx.fillText('↓ ' + esp32screen.fmtRate((n.dl || 0) * 1024), 12, 110);
		ctx.fillStyle = '#FF8A3D'; ctx.fillText('↑ ' + esp32screen.fmtRate((n.ul || 0) * 1024), 12, 136);

		ctx.font = '12px sans-serif'; ctx.fillStyle = '#EAF0FF';
		ctx.fillText('客户端 ' + String(c.n || 0), 12, 172);
		ctx.fillStyle = '#96A3C6';
		ctx.fillText('WAN ' + String(n.wan || '—'), 12, 190);
		ctx.fillText('运行 ' + esp32screen.fmtUptime(r.up), 12, 208);
	},

	/* 自定义 HTML -> SVG foreignObject -> 位图。
	   注意：外链 CSS/图片不会跟着进来，要用的样式请写成内联 style。 */
	drawCustom: function() {
		var self = this;
		var s = this.state || {}, r = s.rtr || {}, n = s.net || {}, c = s.cli || {};
		var ta = document.getElementById('cast-html');
		var html = ta ? ta.value : this.html;
		this.html = html;

		var map = {
			hostname: r.host || '',
			model: r.model || '',
			kernel: r.kernel || '',
			uptime: esp32screen.fmtUptime(r.up),
			load1: ((r.load || [])[0] != null ? (r.load[0]).toFixed(2) : ''),
			mem: (r.mem ? r.mem.pct + '%' : ''),
			dl: esp32screen.fmtRate((n.dl || 0) * 1024),
			ul: esp32screen.fmtRate((n.ul || 0) * 1024),
			clients: String(c.n || 0),
			wanip: String(n.wan || ''),
			time: new Date().toTimeString().substr(0, 8)
		};
		Object.keys(map).forEach(function(k) {
			html = html.split('{{' + k + '}}').join(map[k]);
		});

		var svg = '<svg xmlns="http://www.w3.org/2000/svg" width="320" height="240">' +
			'<foreignObject width="320" height="240">' +
			'<div xmlns="http://www.w3.org/1999/xhtml">' + html + '</div>' +
			'</foreignObject></svg>';

		var img = new Image();
		img.onload = function() {
			self.canvas.getContext('2d').drawImage(img, 0, 0);
		};
		img.onerror = function() {
			self.log('自定义 HTML 光栅化失败，检查标签是否闭合');
		};
		img.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
	},

	/* ---------------------------------------------------------- 推送 */
	push: function() {
		var self = this;
		var host = this.host || '';
		if (!host) {
			esp32screen.getConfig().then(function(c) {
				host = (c && c.config) ? c.config.host : '';
				self.doPush(host);
			});
		} else {
			this.doPush(host);
		}
	},

	doPush: function(host) {
		var self = this;
		if (!host) { this.log('还没填面板地址'); return; }
		var t0 = Date.now();
		esp32screen.pushFrame(host, this.canvas).then(function(txt) {
			self.log('已推送 ' + (320 * 240 * 2) + ' 字节，用时 ' + (Date.now() - t0) + ' ms　→ ' + txt);
		})['catch'](function(e) {
			self.log('推送失败：' + e);
		});
	},

	toggleAuto: function(ev) {
		var self = this;
		if (this.autoTimer) {
			clearInterval(this.autoTimer);
			this.autoTimer = null;
			this.log('已停止连续推送');
			return;
		}
		this.log('连续推送中（每 ' + (this.pushMs / 1000) + ' 秒一帧，切走本页会自动停）');
		this.autoTimer = setInterval(function() {
			/* 切走本页后节点就没了，顺手把定时器停掉，别一直往屏幕上推 */
			if (!document.getElementById('cast-log')) {
				clearInterval(self.autoTimer);
				self.autoTimer = null;
				return;
			}
			self.render_();
			setTimeout(function() { self.push(); }, 300);
		}, this.pushMs);
	},

	log: function(t) {
		var el = document.getElementById('cast-log');
		if (el) el.textContent = t;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	handleRemove: function(ev) {
		if (this.autoTimer) clearInterval(this.autoTimer);
	}
});
