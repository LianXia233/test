/* esp32-screen/settings —— 面板配置（存 /etc/config/esp32screen）
 *
 * 只有两件事记在路由器上：面板在哪、默认怎么推。
 * 其余（WiFi、路由器账号、背光、采集周期）都是下发给面板自己存的 EEPROM，
 * 这里只提供入口，改的是面板那边的配置。
 */
'use strict';
'require view';
'require ui';
'require uci';
'require form';
'require esp32screen';

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('esp32screen')
		]);
	},

	render: function() {
		var m = new form.Map('esp32screen', _('ESP32 屏幕 — 设置'),
			_('面板地址、推送模板等配置保存在路由器上；屏幕自己的 WiFi 与路由器账号由屏幕保存。'));

		/* view 基类的 handleSave 要靠 this.map 找到这张表单 */
		this.map = m;

		var s = m.section(form.TypedSection, 'panel', _('面板'));
		s.anonymous = false;
		s.addremove = false;

		var o;

		o = s.option(form.Value, 'host', _('地址'),
			_('面板的 IP 或主机名。留空则按下面的 mDNS 名字解析。'));
		o.datatype = 'or(host, ipaddr)';
		o.placeholder = '192.168.1.23';

		o = s.option(form.Value, 'mdns', _('mDNS 名字'),
			_('固件默认广播的是 openwrt-monitor.local。'));
		o.default = 'openwrt-monitor';

		o = s.option(form.Flag, 'enabled', _('启用'),
			_('关掉之后本插件不主动取面板状态。'));
		o.default = '1';

		o = s.option(form.ListValue, 'template', _('默认模板'),
			_('打开「投屏」页时先选这一个。'));
		o.value('overview', _('概览'));
		o.value('traffic', _('流量'));
		o.value('custom', _('自定义 HTML'));
		o.default = 'overview';

		o = s.option(form.TextValue, 'custom_html', _('自定义 HTML'),
			_('可用占位符：{{hostname}} {{uptime}} {{load1}} {{mem}} {{dl}} {{ul}} {{clients}} {{wanip}} {{time}}'));
		o.depends('template', 'custom');
		o.rows = 12;
		o.monospace = true;

		o = s.option(form.ListValue, 'push_interval', _('连续推送间隔'),
			_('固件 6 秒收不到帧会退回监控界面，别选超过 5 秒。'));
		o.value('1', _('1 秒'));
		o.value('2', _('2 秒'));
		o.value('4', _('4 秒'));
		o.value('5', _('5 秒'));
		o.default = '4';

		/* ------------------------------------------------ 下发给面板的那部分 */
		var r = m.section(form.TypedSection, 'router', _('下发给屏幕'));
		r.anonymous = true;
		r.description = _('这些值保存在屏幕自己的 EEPROM 里。填好之后点「下发」，' +
			'本插件会用面板的 /api 接口把账号推过去，屏幕随后自己去 ubus 取数。');

		o = r.option(form.Value, 'ip', _('路由器地址'),
			_('留空 = 用屏幕当前 WiFi 的 DHCP 网关，一般这样就行。'));
		o.datatype = 'or(hostname, ip4addr)';
		o.placeholder = _('（自动）');

		o = r.option(form.Value, 'user', _('ubus 用户名'));
		o.default = 'root';

		o = r.option(form.Value, 'password', _('ubus 密码'));
		o.password = true;

		return m.render();
	},

	/* 存完 UCI，顺手把路由器账号推给面板（面板自己会存住） */
	handleSave: function() {
		var self = this;
		return view.prototype.handleSave.apply(this).then(function() {
			return self.pushRouter();
		});
	},

	pushRouter: function() {
		return Promise.all([
			uci.load('esp32screen')
		]).then(function() {
			var host = uci.get('esp32screen', 'panel', 'host') ||
			           uci.get('esp32screen', 'panel', 'mdns');
			var ip = uci.get('esp32screen', 'router', 'ip') || '';
			var user = uci.get('esp32screen', 'router', 'user') || 'root';
			var pass = uci.get('esp32screen', 'router', 'password');

			if (!host || !pass) return null;

			return esp32screen.cmd(host, { c: 'router', ip: ip, user: user, pass: pass });
		})['catch'](function(e) {
			ui.addNotification(null, E('p', {}, _('下发到屏幕失败：') + e), 'error');
		});
	}
});
