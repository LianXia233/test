/* esp32-screen/status —— 屏幕状态与遥控
 *
 * 数据两条路：
 *   面板自身的状态  -> 浏览器直接 fetch http://<屏>/api/state
 *   LuCI 里的配置   -> ubus luci.esp32-screen get
 */
'use strict';
'require view';
'require ui';
'require rpc';
'require esp32screen';

return view.extend({
	load: function() {
		return Promise.all([
			esp32screen.getConfig(),
			rpc.list()
		]);
	},

	render: function(data) {
		var cfg = (data[0] && data[0].config) ? data[0].config : {};
		var host = cfg.host || '';

		var view_ = E('div', { 'class': 'cbi-map' }, [
			E('h2', { 'name': 'content' }, 'ESP32 屏幕'),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, '面板地址'),
						E('div', { 'class': 'cbi-value-field', 'id': 'esp-host' }, host || '(未配置)')
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, '连接状态'),
						E('div', { 'class': 'cbi-value-field', 'id': 'esp-online' }, '探测中…')
					])
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '路由器信息（屏幕采集到的）'),
				E('div', { 'class': 'cbi-section-node', 'id': 'esp-router' },
					E('em', {}, '等待面板数据…'))
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '面板自身'),
				E('div', { 'class': 'cbi-section-node', 'id': 'esp-sys' },
					E('em', {}, '等待面板数据…'))
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '遥控'),
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, '切到哪一页'),
						E('div', { 'class': 'cbi-value-field' },
							E('div', { 'class': 'btn-group' },
								['概览', '系统', '流量', '无线', '设置'].map(function(t, i) {
									return E('button', {
										'class': 'btn',
										'click': function() { esp32screen.cmd(host, { c: 'ui', id: i }); }
									}, t);
								})))
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, '背光'),
						E('div', { 'class': 'cbi-value-field' }, [
							E('input', {
								'type': 'range', 'min': '10', 'max': '100', 'step': '5',
								'value': '100', 'id': 'esp-bright'
							}),
							' ',
							E('button', {
								'class': 'btn',
								'click': function() {
									var v = document.getElementById('esp-bright').value;
									esp32screen.cmd(host, { c: 'bright', pct: +v });
								}
							}, '应用')
						])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, '采集周期'),
						E('div', { 'class': 'cbi-value-field' },
							E('div', { 'class': 'btn-group' },
								[2000, 3000, 5000, 10000].map(function(ms) {
									return E('button', {
										'class': 'btn',
										'click': function() { esp32screen.cmd(host, { c: 'poll', ms: ms }); }
									}, (ms / 1000) + ' 秒');
								})))
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, '危险操作'),
						E('div', { 'class': 'cbi-value-field' }, [
							E('button', {
								'class': 'btn danger',
								'click': function(ev) {
									if (!confirm('重启面板？')) return;
									esp32screen.cmd(host, { c: 'reboot' });
								}
							}, '重启面板'),
							' ',
							E('button', {
								'class': 'btn',
								'click': function() { esp32screen.castExit(host); }
							}, '退出投屏')
						])
					])
				])
			])
		]);

		this.poll();
		return view_;
	},

	poll: function() {
		var self = this;
		var cfg = null;

		esp32screen.getConfig().then(function(c) {
			cfg = (c && c.config) ? c.config : {};
			self.refresh(cfg.host);
		});

		/* 3 秒刷一次，跟面板自己的采集周期一致。
		   LuCI 是 SPA，切走本页没有回调，只能靠节点还在不在判断。 */
		this.timer = setInterval(function() {
			if (!document.getElementById('esp-online')) {
				clearInterval(self.timer);
				self.timer = null;
				return;
			}
			var host = cfg ? cfg.host : '';
			if (host) self.refresh(host);
		}, 3000);
	},

	/* 先让浏览器直连面板；连不上就让路由器（ubus probe）代问一次 */
	refresh: function(host) {
		if (!host) return;
		var self = this;

		esp32screen.state(host).then(function(s) {
			self.markOnline('在线（浏览器直连）');
			self.show(s);
		})['catch'](function(e1) {
			esp32screen.probe(host).then(function(res) {
				if (res && res.state) {
					self.markOnline('在线（经路由器中转）');
					self.show(res.state);
				} else {
					throw new Error((res && res.error) || e1);
				}
			})['catch'](function(e2) {
				self.markOnline('取不到：' + e2);
			});
		});
	},

	markOnline: function(t) {
		var online = document.getElementById('esp-online');
		if (online) online.textContent = t;
	},

	show: function(s) {
		var rtr = document.getElementById('esp-router');
		var sys = document.getElementById('esp-sys');
		if (!rtr || !sys) return;   /* 页面已经切走了 */

		var r = s.rtr || {}, n = s.net || {}, m = s.sys || {}, w = s.wifi || {};

		function fill(el, rows) {
			el.innerHTML = '';
			el.appendChild(E('table', { 'class': 'table' },
				rows.map(function(row) {
					return E('tr', {}, [
						E('td', { 'class': 'td left', 'width': '33%' }, row[0]),
						E('td', {}, row[1] || '—')
					]);
				})));
		}

		fill(rtr, [
			['主机名', r.host],
			['型号', r.model],
			['内核', r.kernel],
			['固件', r.release],
			['负载', (r.load || []).join(' / ')],
			['内存', r.mem ? (r.mem.pct + '%　' +
				esp32screen.fmtBytes(r.mem.used) + ' / ' +
				esp32screen.fmtBytes(r.mem.total)) : null],
			['运行时长', esp32screen.fmtUptime(r.up)],
			['下行 / 上行', esp32screen.fmtRate((n.dl || 0) * 1024) + '　' +
				esp32screen.fmtRate((n.ul || 0) * 1024)],
			['无线客户端', String((s.cli || {}).n || 0)]
		]);

		fill(sys, [
			['连的 WiFi', (w.ssid || null) + (w.rssi ? '（' + w.rssi + ' dBm）' : '')],
			['IP', w.ip],
			['空闲内存', esp32screen.fmtBytes((m.heap || 0) / 1024)],
			['已运行', esp32screen.fmtUptime(m.up)],
			['采集周期', (m.poll || 0) + ' ms'],
			['当前页', String(s.screen)]
		]);
	},

	handleReset: null,

	handleSave: null,

	handleSaveApply: null,

	handleRemove: function() {
		if (this.timer) clearInterval(this.timer);
	}
});
