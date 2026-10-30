/* esp32-screen/cast —— 预览 + 自定内容 + 推送
 *
 * 这里画出来的 canvas 就是最终推到屏上的像素（1:1，没有二次缩放），
 * 所以「预览」和「实际显示」永远一致。推送走
 *   canvas -> RGB565（高字节在前）-> POST http://<屏>:81/draw_rgb565
 * 153,600 字节一帧，局域网里几十毫秒。
 *
 * 内容三选一：
 *   overview / traffic   内置模板，数据取面板的 /api/state
 *   custom               自己写 HTML，用 {{占位符}} 插数据
 * 数据也可以改：默认「跟随面板」，切成「手动填」就能随便改值试效果。
 *
 * 固件 6 秒收不到帧会自己退回监控界面，所以连续推送的间隔别超过 5 秒。
 */
'use strict';
'require view';
'require ui';
'require esp32screen';

var W = 320, H = 240;

var TEMPLATES = {
	overview: '概览（负载 / 内存 / 速率）',
	traffic: '流量（曲线）',
	custom: '自定义 HTML'
};

var SAMPLE_HTML = [
	'<div style="width:320px;height:240px;background:#070A14;color:#EAF0FF;',
	'     font-family:sans-serif;padding:14px;box-sizing:border-box">',
	'  <div style="font-size:12px;color:#96A3C6;letter-spacing:1px">{{hostname}}</div>',
	'  <div style="font-size:34px;margin-top:8px;font-weight:600">{{uptime}}</div>',
	'  <div style="font-size:11px;color:#5D6A8E;margin-top:2px">运行时长</div>',
	'  <div style="margin-top:16px;font-size:14px;color:#22D3EE">↓ {{dl}}</div>',
	'  <div style="font-size:14px;color:#FF8A3D;margin-top:4px">↑ {{ul}}</div>',
	'  <div style="font-size:12px;color:#96A3C6;margin-top:18px">',
	'    客户端 {{clients}}　WAN {{wanip}}</div>',
	'</div>'
].join('');

function s(v) { return (v == null) ? '' : String(v); }

return view.extend({
	history: [],
	scale: 1,

	/* ---------------------------------------------------------- 生命周期 */
	load: function() {
		return Promise.all([ esp32screen.getConfig() ]);
	},

	render: function(load) {
		var cfg = (load[0] && load[0].config) ? load[0].config : {};
		var self = this;

		this.cfg = cfg;
		this.host = cfg.host || '';
		this.tpl = cfg.template || 'overview';
		this.html = cfg.custom_html || SAMPLE_HTML;
		this.dataMode = 'live';
		this.data = {};
		this.live = {};
		this.pushMs = Math.min(5000, Math.max(1000, (+cfg.push_interval || 4) * 1000));

		/* 画布：320x240 实际像素，显示大小由 scale 决定 */
		var canvas = E('canvas', {
			'width': W, 'height': H,
			'style': 'display:block;width:320px;height:240px;image-rendering:pixelated;' +
			         'background:#000;border-radius:4px'
		});
		this.canvas = canvas;
		this.ctx = canvas.getContext('2d');
		this.ctx.fillStyle = '#070A14';
		this.ctx.fillRect(0, 0, W, H);

		/* ------------- 预览框（带设备边框） ------------- */
		var badge = E('span', { 'style': 'font:11px/1 monospace;color:#5D6A8E;margin-left:8px' },
			'320×240 · 1:1 实际尺寸');

		var frame = E('div', {
			'style': 'display:inline-block;padding:10px;border-radius:10px;' +
			         'background:linear-gradient(180deg,#151D36,#101733);' +
			         'border:1px solid #2C3860;box-shadow:0 6px 18px rgba(0,0,0,.35)'
		}, canvas);

		this.badge = badge;

		/* ------------- 模板 ------------- */
		var sel = E('select', {
			'id': 'cast-tpl',
			'change': function(ev) {
				self.tpl = ev.target.value;
				document.getElementById('cast-html-row').style.display =
					(self.tpl === 'custom') ? '' : 'none';
				self.preview();
			}
		}, Object.keys(TEMPLATES).map(function(k) {
			var a = { 'value': k };
			if (k === self.tpl) a.selected = 'selected';
			return E('option', a, TEMPLATES[k]);
		}));

		var taHtml = E('textarea', {
			'id': 'cast-html', 'spellcheck': 'false',
			'style': 'width:100%;height:170px;font:12px/1.5 monospace;resize:vertical'
		});
		taHtml.value = this.html;
		taHtml.addEventListener('input', function() {
			self.html = taHtml.value;
			self.schedulePreview();
		});

		/* ------------- 数据 ------------- */
		var taData = E('textarea', {
			'id': 'cast-data', 'spellcheck': 'false', 'readonly': 'readonly',
			'style': 'width:100%;height:170px;font:12px/1.5 monospace;resize:vertical;opacity:.65'
		});
		this.taData = taData;

		taData.addEventListener('input', function() {
			if (self.dataMode !== 'manual') return;
			self.applyManualData();
			self.schedulePreview();
		});

		function radio(mode, label, hint) {
			var a = {
				'type': 'radio', 'name': 'cast-datamode', 'value': mode,
				'change': function() {
					self.dataMode = mode;
					var live = (mode === 'live');
					self.taData.readOnly = live;
					self.taData.style.opacity = live ? .65 : 1;
					if (live) {
						self.refreshLive();
					} else {
						self.applyManualData();
						self.preview();
					}
				}
			};
			if (self.dataMode === mode) a.checked = 'checked';

			return E('label', { 'style': 'display:block;margin:2px 0' }, [
				E('input', a), ' ',
				E('b', {}, label), ' ',
				E('span', { 'style': 'color:#5D6A8E;font-size:12px' }, hint)
			]);
		}

		/* ------------- 按钮 / 日志 ------------- */
		var log = E('div', {
			'id': 'cast-log',
			'style': 'font:12px/1.6 monospace;color:#96A3C6;margin-top:8px'
		}, '就绪');

		var btnScale = E('button', {
			'class': 'btn',
			'click': function() {
				self.scale = (self.scale === 1) ? 2 : 1;
				self.canvas.style.width = (W * self.scale) + 'px';
				self.canvas.style.height = (H * self.scale) + 'px';
				btnScale.textContent = (self.scale === 1) ? '放大 2×' : '还原 1×';
				badge.textContent = '320×240 · ' +
					(self.scale === 1 ? '1:1 实际尺寸' : '放大 2× 查看');
			}
		}, '放大 2×');

		var out = E('div', { 'class': 'cbi-map' }, [
			E('h2', { 'name': 'content' }, '投屏'),

			/* 预览 */
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, ['预览', badge]),
				E('div', { 'class': 'cbi-section-node' }, [
					frame,
					E('div', { 'style': 'margin-top:12px' }, [
						btnScale, ' ',
						E('button', { 'class': 'btn', 'click': function() { self.preview(); } }, '重画'),
						' ',
						E('button', { 'class': 'btn cbi-button-save', 'click': function() { self.push(); } }, '推一帧'),
						' ',
						E('button', { 'class': 'btn', 'click': function() { self.toggleAuto(); } }, '连续推送'),
						' ',
						E('button', {
							'class': 'btn', 'click': function() {
								esp32screen.castExit(self.host);
								self.log('已发送退出投屏（面板会在下次超时前回到监控页）');
							}
						}, '退出投屏')
					]),
					log
				])
			]),

			/* 内容 */
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '内容'),
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, '模板'),
						E('div', { 'class': 'cbi-value-field' }, sel)
					]),
					E('div', {
						'class': 'cbi-value', 'id': 'cast-html-row',
						'style': (this.tpl === 'custom') ? '' : 'display:none'
					}, [
						E('label', { 'class': 'cbi-value-title' }, '自定义 HTML'),
						E('div', { 'class': 'cbi-value-field' }, [
							taHtml,
							E('div', { 'style': 'color:#5D6A8E;font-size:12px;margin-top:4px' },
								'只有内联样式会生效（外链 CSS / 图片不会跟进来）。' +
								'画布 320×240，超出的部分直接裁掉。')
						])
					])
				])
			]),

			/* 数据 */
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '数据'),
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, '来源'),
						E('div', { 'class': 'cbi-value-field' }, [
							radio('live', '跟随面板', '每次重画前先取一次 /api/state'),
							radio('manual', '手动填', '固定用下面这份 JSON，改完立即重画'),
							E('button', {
								'class': 'btn', 'style': 'margin-top:6px',
								'click': function() { self.refreshLive(); }
							}, '从面板取一次')
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, '数据（JSON）'),
						E('div', { 'class': 'cbi-value-field' }, [
							taData,
							E('div', { 'style': 'color:#5D6A8E;font-size:12px;margin-top:4px' },
								'键名就是 {{占位符}} 的名字。可以自己加，' +
								'比如 "note": "机柜 A1"，模板里写 {{note}}。')
						])
					])
				])
			])
		]);

		/* 首屏：取一次数据再画 */
		this.refreshLive();
		this.castStatus();

		return out;
	},

	/* ---------------------------------------------------------- 数据 */
	flatten: function(st) {
		var r = (st || {}).rtr || {}, n = (st || {}).net || {},
		    c = (st || {}).cli || {}, w = (st || {}).wifi || {};
		var mem = r.mem || {}, load = r.load || [];
		var num = function(v, d) { return (v == null) ? '' : Number(v).toFixed(d); };
		var pct = function(v) {
			if (v == null) return '—';
			return Math.round(v * 100 / (r.cores || 1)) + '%';
		};

		return {
			hostname: s(r.host), model: s(r.model),
			kernel: s(r.kernel), release: s(r.release),
			uptime: esp32screen.fmtUptime(r.up),
			/* 负载统一用单核百分比，和屏幕本体、状态页口径一致 */
			load1: pct(load[0]), load5: pct(load[1]), load15: pct(load[2]),
			mem: (mem.pct == null) ? '' : mem.pct + '%',
			mem_used: (mem.used == null) ? '' : esp32screen.fmtBytes(mem.used),
			mem_total: (mem.total == null) ? '' : esp32screen.fmtBytes(mem.total),
			dl: esp32screen.fmtRate((n.dl || 0) * 1024),
			ul: esp32screen.fmtRate((n.ul || 0) * 1024),
			dl_raw: String(n.dl || 0), ul_raw: String(n.ul || 0),
			clients: String(c.n || 0),
			wanip: s(n.wan),
			ssid: s(w.ssid), ip: s(w.ip),
			rssi: (w.rssi == null) ? '' : String(w.rssi),
			time: new Date().toTimeString().substr(0, 8)
		};
	},

	refreshLive: function() {
		var self = this;
		return esp32screen.state(this.host).then(function(st) {
			self.state = st;
			self.live = self.flatten(st);
			if (self.dataMode === 'live') {
				self.data = self.live;
				self.taData.value = JSON.stringify(self.data, null, 2);
			}
			self.preview();
		})['catch'](function(e) {
			if (self.dataMode === 'live') {
				self.data = self.live || {};
				self.taData.value = JSON.stringify(self.data, null, 2);
			}
			self.log('取不到面板数据：' + e + '（按当前值画）');
			self.preview();
		});
	},

	applyManualData: function() {
		try {
			var o = JSON.parse(this.taData.value || '{}');
			if (o === null || typeof o !== 'object' || Array.isArray(o))
				throw new Error('要一个 JSON 对象');
			this.data = o;
			this.log('数据已更新（' + Object.keys(o).length + ' 个字段）');
		} catch (e) {
			this.log('数据 JSON 解析失败：' + (e.message || e));
		}
	},

	/* ---------------------------------------------------------- 绘制 */
	schedulePreview: function() {
		var self = this;
		if (this.timer) clearTimeout(this.timer);
		this.timer = setTimeout(function() { self.preview(); }, 350);
	},

	preview: function() {
		if (this.tpl === 'custom') this.drawCustom();
		else this.drawTemplate(this.tpl);
	},

	bg: function(ctx) {
		var g = ctx.createLinearGradient(0, 0, 0, H);
		g.addColorStop(0, '#070A14');
		g.addColorStop(1, '#101733');
		ctx.fillStyle = g;
		ctx.fillRect(0, 0, W, H);
	},

	ellipsis: function(ctx, text, x, y, maxW) {
		text = String(text || '');
		if (ctx.measureText(text).width <= maxW) { ctx.fillText(text, x, y); return; }
		while (text.length > 1 && ctx.measureText(text + '…').width > maxW)
			text = text.substr(0, text.length - 1);
		ctx.fillText(text + '…', x, y);
	},

	drawTemplate: function(tpl) {
		var ctx = this.ctx, d = this.data || {};

		this.bg(ctx);
		ctx.textBaseline = 'top';

		ctx.font = '13px sans-serif';
		ctx.fillStyle = '#EAF0FF';
		this.ellipsis(ctx, d.hostname || '—', 12, 12, 210);
		ctx.font = '11px sans-serif';
		ctx.fillStyle = '#5D6A8E';
		this.ellipsis(ctx, d.ssid || '', 12, 30, 210);

		if (tpl === 'traffic') {
			ctx.font = '12px sans-serif';
			ctx.fillStyle = '#22D3EE';
			ctx.fillText('↓ ' + (d.dl || '—'), 12, 54);
			ctx.fillStyle = '#FF8A3D';
			ctx.fillText('↑ ' + (d.ul || '—'), 12, 72);

			this.history.push([ +(d.dl_raw || 0), +(d.ul_raw || 0) ]);
			if (this.history.length > 40) this.history.shift();

			var max = 1;
			this.history.forEach(function(p) { max = Math.max(max, p[0], p[1]); });

			var X = 12, Y = 96, WW = 296, HH = 124, N = 40;
			ctx.strokeStyle = '#2C3860';
			ctx.lineWidth = 1;
			ctx.strokeRect(X + .5, Y + .5, WW - 1, HH - 1);

			var self = this;
			[['#22D3EE', 0], ['#FF8A3D', 1]].forEach(function(spec) {
				ctx.strokeStyle = spec[0];
				ctx.lineWidth = 2;
				ctx.beginPath();
				self.history.forEach(function(p, i) {
					var px = X + i * (WW - 2) / (N - 1) + 1;
					var py = Y + HH - 2 - (p[spec[1]] / max) * (HH - 8);
					if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
				});
				ctx.stroke();
			});
			return;
		}

		/* overview：两个大数字 + 两行速率 + 底部三行 */
		ctx.font = '30px sans-serif';
		ctx.fillStyle = '#EAF0FF';
		ctx.fillText(d.load1 || '—', 12, 54);
		ctx.font = '11px sans-serif';
		ctx.fillStyle = '#96A3C6';
		ctx.fillText('处理器负载', 12, 92);

		ctx.font = '30px sans-serif';
		ctx.fillStyle = '#EAF0FF';
		ctx.fillText(d.mem || '—', 168, 54);
		ctx.font = '11px sans-serif';
		ctx.fillStyle = '#96A3C6';
		ctx.fillText('内存', 168, 92);

		ctx.font = '18px sans-serif';
		ctx.fillStyle = '#22D3EE';
		ctx.fillText('↓ ' + (d.dl || '—'), 12, 112);
		ctx.fillStyle = '#FF8A3D';
		ctx.fillText('↑ ' + (d.ul || '—'), 12, 136);

		ctx.font = '12px sans-serif';
		ctx.fillStyle = '#EAF0FF';
		ctx.fillText('客户端 ' + (d.clients || '0'), 12, 172);
		ctx.fillStyle = '#96A3C6';
		this.ellipsis(ctx, 'WAN ' + (d.wanip || '—'), 12, 190, 150);
		ctx.fillText('运行 ' + (d.uptime || '—'), 12, 208);
	},

	/* 自定义 HTML -> SVG foreignObject -> 位图。
	   浏览器里没有 html2canvas 这类库，foreignObject 是唯一不引依赖的办法。
	   注意：外链 CSS / 图片不会跟进来，样式必须内联。 */
	drawCustom: function() {
		var self = this;
		var html = String(this.html || '');

		Object.keys(this.data || {}).forEach(function(k) {
			html = html.split('{{' + k + '}}').join(s(self.data[k]));
		});

		var svg = '<svg xmlns="http://www.w3.org/2000/svg" width="' + W + '" height="' + H + '">' +
			'<foreignObject width="100%" height="100%">' +
			'<div xmlns="http://www.w3.org/1999/xhtml" style="width:' + W + 'px;height:' + H +
			'px;margin:0;overflow:hidden">' + html + '</div>' +
			'</foreignObject></svg>';

		var img = new Image();
		img.onload = function() {
			self.bg(self.ctx);
			self.ctx.drawImage(img, 0, 0, W, H);
		};
		img.onerror = function() {
			self.ctx.fillStyle = '#070A14';
			self.ctx.fillRect(0, 0, W, H);
			self.ctx.fillStyle = '#EF4444';
			self.ctx.font = '13px sans-serif';
			self.ctx.fillText('HTML 光栅化失败', 12, 12);
			self.log('自定义 HTML 光栅化失败，检查标签是否闭合');
		};
		img.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
	},

	/* ---------------------------------------------------------- 推送 */
	castStatus: function() {
		var self = this;
		esp32screen.state(this.host).then(function(st) {
			var c = st.cast || {};
			if (c.on) self.log('面板正在投屏：已收 ' + (c.frames || 0) + ' 帧，' +
				(c.w || 0) + '×' + (c.h || 0));
		})['catch'](function() {});
	},

	push: function() {
		var self = this;
		if (!this.host) { this.log('还没填面板地址，去「设置」页填一下'); return; }
		var t0 = Date.now();
		esp32screen.pushFrame(this.host, this.canvas).then(function(txt) {
			self.log('已推送 ' + (W * H * 2) + ' 字节，' + (Date.now() - t0) + ' ms　→ ' + txt);
		})['catch'](function(e) {
			self.log('推送失败：' + e);
		});
	},

	toggleAuto: function() {
		var self = this;
		if (this.autoTimer) {
			clearInterval(this.autoTimer);
			this.autoTimer = null;
			this.log('已停止连续推送');
			return;
		}
		if (!this.host) { this.log('还没填面板地址，去「设置」页填一下'); return; }

		this.log('连续推送中（每 ' + (this.pushMs / 1000) + ' 秒一帧，切走本页自动停）');
		this.autoTimer = setInterval(function() {
			if (!document.getElementById('cast-log')) {     /* 页面已经切走 */
				clearInterval(self.autoTimer);
				self.autoTimer = null;
				return;
			}
			if (self.dataMode === 'live') {
				esp32screen.state(self.host).then(function(st) {
					self.state = st;
					self.live = self.flatten(st);
					self.data = self.live;
					self.taData.value = JSON.stringify(self.data, null, 2);
					self.preview();
					setTimeout(function() { self.push(); }, 250);
				})['catch'](function() {
					self.preview();
					setTimeout(function() { self.push(); }, 250);
				});
			} else {
				self.preview();
				setTimeout(function() { self.push(); }, 250);
			}
		}, this.pushMs);
	},

	log: function(t) {
		var el = document.getElementById('cast-log');
		if (el) el.textContent = t;
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null,

	handleRemove: function() {
		if (this.autoTimer) clearInterval(this.autoTimer);
		if (this.timer) clearTimeout(this.timer);
	}
});
