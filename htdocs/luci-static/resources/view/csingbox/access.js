/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Csing-box - Access Control
 * Based on luci-app-homeproxy (C) 2022-2025 ImmortalWrt.org
 */

'use strict';
'require dom';
'require form';
'require network';
'require uci';
'require ui';
'require view';

/* Kanged from luci-app-firewall tools/firewall.js */
const CBIDynamicMultiValueList = form.DynamicList.extend({
	renderWidget() {
		const dl = form.DynamicList.prototype.renderWidget.apply(this, arguments);
		const inst = dom.findClassInstance(dl);

		inst.addItem = function(dl, value, text, flash) {
			const values = L.toArray(value);
			for (let val of values)
				ui.DynamicList.prototype.addItem.call(this, dl, val, null, true);
		};

		return dl;
	}
});

function addMACOption(s, name, label, description, hosts) {
	const o = s.option(CBIDynamicMultiValueList, name, label, description);

	o.modalonly = true;
	o.datatype = 'list(macaddr)';
	o.placeholder = _('-- add MAC --');

	L.sortedKeys(hosts).forEach(function(mac) {
		o.value(mac, E([], [ mac, ' (', E('strong', {}, [
			hosts[mac].name ||
			L.toArray(hosts[mac].ipaddrs || hosts[mac].ipv4)[0] ||
			L.toArray(hosts[mac].ip6addrs || hosts[mac].ipv6)[0] ||
			'?'
		]), ')' ]));
	});

	return o;
}

return view.extend({
	load() {
		return Promise.all([
			uci.load('csingbox'),
			network.getHostHints()
		]);
	},

	render(data) {
		let m, s, so;
		const hosts = data[1]?.hosts;

		m = new form.Map('csingbox');

		s = m.section(form.NamedSection, 'control', 'csingbox', _('Routing control'));
		s.anonymous = true;

		so = s.option(form.ListValue, 'lan_proxy_mode', _('Proxy filter mode'));
		so.value('disabled', _('Disable'));
		so.value('listed_only', _('Proxy listed only'));
		so.value('except_listed', _('Proxy all except listed'));
		so.default = 'disabled';
		so.rmempty = false;

		so = addMACOption(s, 'lan_direct_mac_addrs', _('Direct MAC'),
			_('Traffic from these MACs bypasses sing-box. You can select LAN DHCP clients from the dropdown.'), hosts);
		so.depends('lan_proxy_mode', 'except_listed');

		so = addMACOption(s, 'lan_proxy_mac_addrs', _('Proxy MAC'),
			_('Traffic from these MACs is forced through sing-box. You can select LAN DHCP clients from the dropdown.'), hosts);
		so.depends('lan_proxy_mode', 'listed_only');

		so = s.option(form.DynamicList, 'wan_proxy_ipv4_ips', _('Proxy IPv4 addresses'),
			_('Traffic to these destination IPs is always forced through the proxy, taking priority over the routing mode.'));
		so.datatype = 'or(ip4addr, cidr4)';

		if (uci.get('csingbox', 'config', 'ipv6_support') === '1') {
			so = s.option(form.DynamicList, 'wan_proxy_ipv6_ips', _('Proxy IPv6 addresses'),
				_('Traffic to these destination IPs is always forced through the proxy, taking priority over the routing mode.'));
			so.datatype = 'or(ip6addr, cidr6)';
		}

		return m.render();
	}
});
