/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Csing-box - Settings
 * Based on luci-app-homeproxy (C) 2022-2025 ImmortalWrt.org
 */

'use strict';
'require dom';
'require form';
'require network';
'require poll';
'require rpc';
'require uci';
'require ui';
'require validation';
'require view';

'require csingbox as cs';

const callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: ['name'],
	expect: { '': {} }
});

const callPanelRegenerate = rpc.declare({
	object: 'luci.csingbox',
	method: 'panel_template_regenerate',
	expect: { '': {} }
});

const callPanelRead = rpc.declare({
	object: 'luci.csingbox',
	method: 'panel_config_read',
	expect: { '': {} }
});

let stubValidator = {
	factory: validation,
	apply(type, value, args) {
		if (value != null)
			this.value = value;

		return validation.types[type].apply(this, args);
	},
	assert(condition) {
		return !!condition;
	}
};

const status_css = '				\
:root {						\
	--text-color: #000000;			\
}						\
html[data-darkmode="true"] {			\
	--text-color: #e0e0e0;			\
}						\
.csingbox-status-bar {				\
	display: flex;				\
	flex-wrap: wrap;			\
	gap: 8px 40px;				\
	padding: 10px 0;			\
}						\
.csingbox-status-bar .status-item .k {		\
	font-size: 12px;			\
	color: var(--text-color-low);		\
}						\
.csingbox-status-bar .status-item .v {		\
	font-size: 14px;			\
	font-weight: bold;			\
	color: var(--text-color);		\
	margin-top: 2px;			\
}						\
.status-dot {					\
	display: inline-block;			\
	width: 10px;				\
	height: 10px;				\
	border-radius: 50%;			\
	margin-right: 6px;			\
	vertical-align: baseline;		\
}						\
.status-dot.success {				\
	background: #16a34a;			\
}						\
.status-dot.danger {				\
	background: #dc2626;			\
}';

function getServiceStatus() {
	return L.resolveDefault(callServiceList('csingbox'), {}).then((res) => {
		let isRunning = false;
		try {
			isRunning = res['csingbox']['instances']['sing-box-c']['running'];
		} catch (e) { }
		return isRunning;
	});
}

function escapeHtml(s) {
	return String(s).replace(/[&<>"']/g, (c) => ({
		'&': '&amp;',
		'<': '&lt;',
		'>': '&gt;',
		'"': '&quot;',
		"'": '&#39;'
	}[c]));
}

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

/* MAC list option of the access-control tab; the values live in the UCI section "control" */
function addMACOption(s, tab, name, label, description, hosts) {
	const o = s.taboption(tab, CBIDynamicMultiValueList, name, label, description);

	o.ucisection = 'control';
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

function renderStatus(isRunning, version) {
	const node = uci.get('csingbox', 'config', 'main_node');
	const nodeLabel = (!node || node === 'nil') ? _('Not selected') :
		(node === 'urltest') ? _('URLTest') : (uci.get('csingbox', node, 'label') || node);
	const cls = isRunning ? 'success' : 'danger';
	const state = isRunning ? _('Running') : _('Stopped');
	const panelEnabled = uci.get('csingbox', 'config', 'api_panel_enabled') === '1';

	const item = (label, value) =>
		'<div class="status-item"><div class="k">' + escapeHtml(label) +
		'</div><div class="v">' + value + '</div></div>';

	return item(_('Running status'),
			'<span class="status-dot ' + cls + '"></span><span class="status-text ' + cls + '">' + escapeHtml(state) + '</span>') +
		item(_('Panel'), '<span class="status-text ' + (panelEnabled ? 'success' : 'muted') + '">' +
			escapeHtml(panelEnabled ? _('Enabled') : _('Disabled')) + '</span>') +
		item(_('Current node'), escapeHtml(nodeLabel)) +
		item(_('sing-box core version'), escapeHtml(version ? 'v' + version : _('Unknown')));
}

return view.extend({
	load() {
		return Promise.all([
			uci.load('csingbox'),
			cs.getBuiltinFeatures(),
			L.resolveDefault(callPanelRead(), {}),
			network.getHostHints()
		]);
	},

	render(data) {
		let m, s, o;
		const features = data[1];
		const readRes = data[2];
		const hosts = data[3]?.hosts;

		let proxy_nodes = {};
		uci.sections('csingbox', 'node', (res) => {
			let nodeaddr = ((res.type === 'direct') ? res.override_address : res.address) || '',
			    nodeport = ((res.type === 'direct') ? res.override_port : res.port) || '';

			proxy_nodes[res['.name']] =
				String.format('[%s] %s', res.type, res.label || ((stubValidator.apply('ip6addr', nodeaddr) ?
					String.format('[%s]', nodeaddr) : nodeaddr) + ':' + nodeport));
		});

		m = new form.Map('csingbox', _('Csing-box'), _('Lightweight build based on HomeProxy'));

		/* Running status (one line) */
		s = m.section(form.TypedSection);
		s.render = function() {
			poll.add(function() {
				return L.resolveDefault(getServiceStatus()).then((res) => {
					let view = document.getElementById('service_status');
					view.innerHTML = renderStatus(res, features.version);
				});
			});

			return E([
				E('style', [ cs.status_css, status_css ]),
				E('div', { 'class': 'cbi-section' }, [
					E('div', { 'class': 'cbi-section-node' }, [
						E('div', { 'class': 'csingbox-status-bar', 'id': 'service_status' }, _('Collecting data...'))
					])
				])
			]);
		}

		s = m.section(form.NamedSection, 'config', 'csingbox');
		s.anonymous = true;
		s.tab('basic', _('General'));
		s.tab('access', _('Access Control'));

		o = s.taboption('basic', form.ListValue, 'main_node', _('Node selection'));
		o.widget = 'select';
		o.value('nil', _('Disable'));
		o.value('urltest', _('URLTest'));
		for (let i in proxy_nodes)
			o.value(i, proxy_nodes[i]);
		o.default = 'nil';
		o.rmempty = false;

		o = s.taboption('basic', cs.CBIStaticList, 'main_urltest_nodes', _('URLTest nodes'),
			_('List of nodes to test.'));
		for (let i in proxy_nodes)
			o.value(i, proxy_nodes[i]);
		o.depends('main_node', 'urltest');
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'main_urltest_interval', _('Test interval'),
			_('The test interval in seconds.'));
		o.datatype = 'uinteger';
		o.placeholder = '180';
		o.depends('main_node', 'urltest');

		o = s.taboption('basic', form.Value, 'main_urltest_tolerance', _('Test tolerance'),
			_('The test tolerance in milliseconds.'));
		o.datatype = 'uinteger';
		o.placeholder = '50';
		o.depends('main_node', 'urltest');

		o = s.taboption('basic', form.Value, 'dns_server', _('Remote DNS'),
			_('Proxy DNS, supports UDP, TCP, DoH, DoQ, DoT.'));
		o.value('tls://8.8.8.8:853');
		o.value('tls://1.1.1.1:853');
		o.value('https://dns.google/dns-query');
		o.value('https://1.1.1.1/dns-query');
		o.default = 'https://dns.google/dns-query';
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'china_dns_server', _('Local DNS'),
			_('Domestic DNS, supports UDP, TCP, DoH, DoQ, DoT.'));
		o.value('udp://223.5.5.5:53');
		o.value('udp://119.29.29.29:53');
		o.value('udp://210.2.4.8:53');
		o.default = 'udp://223.5.5.5:53';
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'routing_port', _('Routing ports'),
			_('Separate multiple ports with commas; regenerate the config after changing ports.'));
		o.value('all', _('All ports'));
		o.value('common', _('Common ports only (bypass P2P traffic)'));
		o.validate = function(section_id, value) {
			if (section_id && value && value !== 'common' && value !== 'all') {
				let ports = [];
				for (let i of value.split(',')) {
					if (!stubValidator.apply('port', i) && !stubValidator.apply('portrange', i))
						return _('Expecting: %s').format(_('valid port value'));
					if (ports.includes(i))
						return _('Port %s already exists!').format(i);
					ports = ports.concat(i);
				}
			}

			return true;
		};
		o.default = 'common';
		o.rmempty = false;

		o = s.taboption('basic', form.Flag, 'api_panel_enabled', _('Enable panel'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'api_panel_port', _('Panel port'));
		o.datatype = 'port';
		o.default = '9090';
		o.rmempty = false;
		o.depends('api_panel_enabled', '1');

		o = s.taboption('basic', form.Value, 'api_panel_secret', _('Panel secret'));
		o.password = true;
		o.description = _('Used to authenticate panel API access. It is recommended to set a custom secret instead of the default.');
		o.default = '666b888C';
		o.rmempty = false;
		o.depends('api_panel_enabled', '1');
		o.validate = function(section_id, value) {
			if (section_id && !value)
				return _('Expecting: %s').format(_('non-empty value'));

			return true;
		}

		o = s.taboption('basic', form.Button, '_open_panel', _('Open Panel'));
		o.inputstyle = 'action';
		o.inputtitle = _('Open sing-box dashboard');
		o.depends('api_panel_enabled', '1');
		o.onclick = function() {
			const port = uci.get('csingbox', 'config', 'api_panel_port') || '9090';
			window.open('http://' + location.hostname + ':' + port + '/dashboard/');
		}

		/* Not tied to the panel switch: this is the button that applies every generator
		 * setting (nodes, DNS, routing ports, …) to the config file, so it must stay
		 * available with the panel turned off as well. */
		o = s.taboption('basic', form.Button, '_regenerate_panel_template', _('Overwrite config'));
		o.inputstyle = 'apply';
		o.inputtitle = _('Click to regenerate config');
		o.description = _('Regenerates the config file from the current page settings and overwrites the original, losing any manual rules.');
		o.onclick = function() {
			if (!confirm(_('This will overwrite manual modifications in sing-box-panel.json. Continue?')))
				return;

			return L.resolveDefault(callPanelRegenerate(), {}).then((res) => {
				if (res && res.result)
					ui.addNotification(null, E('p', {}, _('Panel config file regenerated and service restarted.')));
				else
					ui.addNotification(null, E('p', {}, _('Failed to regenerate the config file.')));
			});
		}

		o = s.taboption('basic', form.Flag, 'quic_reject', _('Reject QUIC'),
			_('Rejects proxied QUIC (UDP 80/443) so applications fall back to TCP immediately. Direct traffic is unaffected; turn it off only if you need UDP 443 through the proxy.'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('basic', form.Flag, 'multi_queue', _('Multi-queue TUN'),
			_('Spreads packet processing over multiple cores, and falls back to a single queue with a log warning if the device does not support it.'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('basic', form.Flag, 'ipv6_support', _('IPv6 support'));
		o.default = '1';
		o.rmempty = false;

		/* The panel template is generated once and then maintained manually: flag templates
		 * created by older versions instead of overwriting user changes automatically. */
		if (readRes.legacy) {
			o = s.taboption('basic', form.DummyValue, '_legacy_template', _('Panel config status'));
			o.default = E('strong', { 'class': 'status-text danger' }, [
				_('The panel config file was generated by an older version and still uses the removed redirect/tproxy inbounds. Use the "Click to regenerate config" button to rebuild it with TUN; this overwrites any manual rules.')
			]);
		}

		/* Access control: the options live in the UCI section "control", but are presented in the
		 * same tab set as the general settings, so ucisection is pointed at it explicitly
		 * (documented per-option property, see LuCI form.js). */
		o = s.taboption('access', form.ListValue, 'lan_proxy_mode', _('Proxy filter mode'));
		o.ucisection = 'control';
		o.value('disabled', _('Disable'));
		o.value('listed_only', _('Proxy listed only'));
		o.value('except_listed', _('Proxy all except listed'));
		o.default = 'disabled';
		o.rmempty = false;

		o = addMACOption(s, 'access', 'lan_direct_mac_addrs', _('Direct MAC'),
			_('Traffic from these MACs bypasses sing-box. You can select LAN DHCP clients from the dropdown.'), hosts);
		o.depends('lan_proxy_mode', 'except_listed');

		o = addMACOption(s, 'access', 'lan_proxy_mac_addrs', _('Proxy MAC'),
			_('Traffic from these MACs is forced through sing-box. You can select LAN DHCP clients from the dropdown.'), hosts);
		o.depends('lan_proxy_mode', 'listed_only');

		return m.render();
	}
});
