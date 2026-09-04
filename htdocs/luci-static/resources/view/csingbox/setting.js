/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Csing-box - Settings
 * Based on luci-app-homeproxy (C) 2022-2025 ImmortalWrt.org
 */

'use strict';
'require form';
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

const callServiceReload = rpc.declare({
	object: 'luci.csingbox',
	method: 'service_reload',
	expect: { '': {} }
});

const callReadDomainList = rpc.declare({
	object: 'luci.csingbox',
	method: 'acllist_read',
	params: ['type'],
	expect: { '': {} }
});

const callWriteDomainList = rpc.declare({
	object: 'luci.csingbox',
	method: 'acllist_write',
	params: ['type', 'content'],
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

const callPanelWrite = rpc.declare({
	object: 'luci.csingbox',
	method: 'panel_config_write',
	params: ['content'],
	expect: { '': {} }
});

const routing_modes = {
	'bypass_mainland_china': _('Bypass mainland China'),
	'panel': _('Panel Manual Routing'),
	'gfwlist': _('GFWlist'),
	'global': _('Global')
};

const PANEL_PATH = '/etc/csingbox/sing-box-panel.json';

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

function renderStatus(isRunning, version) {
	const node = uci.get('csingbox', 'config', 'main_node');
	const nodeLabel = (!node || node === 'nil') ? _('Not selected') :
		(node === 'urltest') ? _('URLTest') : (uci.get('csingbox', node, 'label') || node);
	const mode = routing_modes[uci.get('csingbox', 'config', 'routing_mode')] || _('Unknown');
	const cls = isRunning ? 'success' : 'danger';
	const state = isRunning ? _('Running') : _('Stopped');
	const isPanel = uci.get('csingbox', 'config', 'routing_mode') === 'panel';
	const panelCls = isPanel ? 'success' : 'danger';
	const panelState = isPanel ? _('Enabled') : _('Disabled');

	const item = (label, value) =>
		'<div class="status-item"><div class="k">' + escapeHtml(label) +
		'</div><div class="v">' + value + '</div></div>';

	return item(_('Running status'),
			'<span class="status-dot ' + cls + '"></span><span class="status-text ' + cls + '">' + escapeHtml(state) + '</span>') +
		item(_('Panel'), '<span class="status-text ' + panelCls + '">' + escapeHtml(panelState) + '</span>') +
		item(_('Current node'), escapeHtml(nodeLabel)) +
		item(_('Routing mode'), escapeHtml(mode)) +
		item(_('sing-box core version'), escapeHtml(version ? 'v' + version : _('Unknown')));
}

return view.extend({
	load() {
		return Promise.all([
			uci.load('csingbox'),
			cs.getBuiltinFeatures(),
			L.resolveDefault(callPanelRead(), {})
		]);
	},

	render(data) {
		let m, s, o;
		const features = data[1];
		const readRes = data[2];

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
		s.tab('panel', _('Panel Config'));
		s.tab('domain', _('Domain Rules'));

		o = s.taboption('basic', form.ListValue, 'main_node', _('Node selection'));
		o.widget = 'select';
		o.value('nil', _('Disable'));
		o.value('urltest', _('URLTest'));
		for (let i in proxy_nodes)
			o.value(i, proxy_nodes[i]);
		o.default = 'nil';
		o.rmempty = false;

		o = s.taboption('basic', form.DummyValue, 'service_actions', ' ');
		o.renderWidget = function(section_id, option_index, cfgvalue) {
			return E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'click': ui.createHandlerFn(this, () => {
					return L.resolveDefault(callServiceReload(), {}).then((res) => {
						if (res && res.status === 0)
							ui.addNotification(null, E('p', {}, _('Service reloaded.')));
						else
							ui.addNotification(null, E('p', {}, _('Failed to reload service.')));
					});
				})
			}, [ _('Reload') ]);
		}

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
		o.default = 'tls://8.8.8.8:853';
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'china_dns_server', _('Local DNS'),
			_('Domestic DNS, supports UDP, TCP, DoH, DoQ, DoT.'));
		o.value('udp://223.5.5.5:53');
		o.value('udp://119.29.29.29:53');
		o.value('udp://210.2.4.8:53');
		o.default = 'udp://223.5.5.5:53';
		o.rmempty = false;

		o = s.taboption('basic', form.ListValue, 'routing_mode', _('Routing mode'),
		_('After selecting Panel Manual Routing, you can edit the config file on the Panel Config page to define custom routing rules.'));
		o.value('bypass_mainland_china', _('Bypass mainland China'));
		o.value('panel', _('Panel Manual Routing'));
		o.value('gfwlist', _('GFWlist'));
		o.value('global', _('Global'));
		o.default = 'bypass_mainland_china';
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'api_panel_port', _('Panel port'));
		o.datatype = 'port';
		o.default = '9090';
		o.rmempty = false;
		o.depends('routing_mode', 'panel');

		o = s.taboption('basic', form.Value, 'api_panel_secret', _('Panel secret'));
		o.password = true;
		o.description = _('Used to authenticate panel API access. It is recommended to set a custom secret instead of the default.');
		o.default = '666b888C';
		o.rmempty = false;
		o.depends('routing_mode', 'panel');
		o.validate = function(section_id, value) {
			if (section_id && !value)
				return _('Expecting: %s').format(_('non-empty value'));

			return true;
		}

		o = s.taboption('basic', form.Button, '_regenerate_panel_template', _('Regenerate panel config file'));
		o.inputstyle = 'apply';
		o.inputtitle = _('Regenerate config');
		o.description = _('Regenerates the config file from the current page settings and overwrites the original, losing any manual rules.');
		o.depends('routing_mode', 'panel');
		o.onclick = function() {
			if (!confirm(_('This will overwrite manual modifications in sing-box-panel.json. Continue?')))
				return;

			return L.resolveDefault(callPanelRegenerate(), {}).then((res) => {
				if (res && res.result)
					ui.addNotification(null, E('p', {}, _('Panel config file regenerated and service restarted.')));
				else
					ui.addNotification(null, E('p', {}, _('Failed to regenerate panel config file.')));
			});
		}

		o = s.taboption('basic', form.Button, '_open_panel', _('Open Panel'));
		o.inputstyle = 'action';
		o.inputtitle = _('Open sing-box dashboard');
		o.depends('routing_mode', 'panel');
		o.onclick = function() {
			const port = uci.get('csingbox', 'config', 'api_panel_port') || '9090';
			window.open('http://' + location.hostname + ':' + port + '/dashboard/');
		}

		o = s.taboption('basic', form.ListValue, 'proxy_mode', _('Proxy mode'));
		o.value('redirect_tproxy', _('Redirect TCP + TProxy UDP'));
		o.value('redirect', _('Redirect TCP'));
		o.default = 'redirect_tproxy';
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'routing_port', _('Routing ports'),
			_('Specify target ports to be proxied. Multiple ports must be separated by commas.'));
		o.value('', _('All ports'));
		o.value('common', _('Common ports only (bypass P2P traffic)'));
		o.validate = function(section_id, value) {
			if (section_id && value && value !== 'common') {
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
		}

		o = s.taboption('basic', form.Flag, 'auto_update', _('Auto update rule files'),
			_('Automatically fetch china_ip4, china_ip6, gfw_list rule files every Sunday at 03:00.'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('basic', form.Flag, 'dns_mainland_fallback',
			_('Mainland IP DNS fallback'),
			_('When the proxy DNS returns a mainland IP, re-resolve the query with the local DNS; ' +
			  'per-rule DNS strategies are disabled once enabled. Regenerate the panel config file ' +
			  'in Panel Manual Routing.'));
		o.default = '1';
		o.rmempty = false;
		o.depends('routing_mode', 'bypass_mainland_china');
		o.depends('routing_mode', 'panel');

		o = s.taboption('basic', form.Flag, 'ipv6_support', _('IPv6 support'));
		o.default = '1';
		o.rmempty = false;

		/* Panel config file editor (panel manual routing only) */
		if (readRes.error) {
			o = s.taboption('panel', form.DummyValue, '_file_missing', _('File status'));
			o.depends('routing_mode', 'panel');
			o.default = E('strong', { 'class': 'status-text danger' }, [
				_('File not found. Enable Panel Manual Routing and start the service once, or regenerate the template from the Settings page.')
			]);
		}

		o = s.taboption('panel', form.TextValue, '_file_content', _('Panel config file'),
			_('File: %s. Invalid JSON will be rejected; the config is also checked with sing-box before saving. This file is only used when the routing mode is Panel Manual Routing.').format(PANEL_PATH));
		o.rows = 28;
		o.wrap = false;
		o.monospace = true;
		o.depends('routing_mode', 'panel');
		o.load = function() {
			return L.resolveDefault(callPanelRead(), {}).then((res) => {
				return (res.content != null) ? res.content : '';
			});
		};
		o.validate = function(section_id, value) {
			if (value) {
				try {
					JSON.parse(value);
				} catch (e) {
					return _('JSON syntax error: %s').format(e.message);
				}
			}

			return true;
		};
		o.write = function(_section_id, value) {
			return callPanelWrite(value).then((res) => {
				if (!res || !res.result)
					throw new Error((res && res.error) ? res.error : _('Unknown error.'));
			});
		};

		o = s.taboption('panel', form.Button, '_reload_file', _('Reload from disk'));
		o.inputstyle = 'action';
		o.depends('routing_mode', 'panel');
		o.onclick = function() {
			return L.resolveDefault(callPanelRead(), {}).then((res) => {
				const content = (res.content != null) ? res.content : '';
				m.lookupOption('_file_content', 'config')[0].getUIElement('config').setValue(content);
				ui.addNotification(null, E('p', {}, _('Panel config reloaded from disk.')));
			});
		};

		/* Domain rules (all routing modes except panel manual routing) */
		o = s.taboption('domain', form.TextValue, '_direct_domain_list', _('Direct domain list (direct_list.txt)'),
			_('One domain per line. Takes priority over routing mode; matching traffic bypasses sing-box.'));
		o.rows = 10;
		o.monospace = true;
		o.datatype = 'hostname';
		o.depends('routing_mode', 'bypass_mainland_china');
		o.depends('routing_mode', 'gfwlist');
		o.depends('routing_mode', 'global');
		o.load = function() {
			return L.resolveDefault(callReadDomainList('direct_list')).then((res) => {
				return res.content;
			});
		}
		o.write = function(_section_id, value) {
			return callWriteDomainList('direct_list', value);
		}
		o.remove = function() {
			return callWriteDomainList('direct_list', '');
		}
		o.validate = function(section_id, value) {
			if (section_id && value)
				for (let i of value.split('\n'))
					if (i && !stubValidator.apply('hostname', i))
						return _('Expecting: %s').format(_('valid hostname'));

			return true;
		}

		o = s.taboption('domain', form.TextValue, '_proxy_domain_list', _('Proxy domain list (proxy_list.txt)'),
			_('One domain per line. Takes priority over routing mode; matching traffic goes through proxy.'));
		o.rows = 10;
		o.monospace = true;
		o.datatype = 'hostname';
		o.depends('routing_mode', 'bypass_mainland_china');
		o.depends('routing_mode', 'gfwlist');
		o.depends('routing_mode', 'global');
		o.load = function() {
			return L.resolveDefault(callReadDomainList('proxy_list')).then((res) => {
				return res.content;
			});
		}
		o.write = function(_section_id, value) {
			return callWriteDomainList('proxy_list', value);
		}
		o.remove = function() {
			return callWriteDomainList('proxy_list', '');
		}
		o.validate = function(section_id, value) {
			if (section_id && value)
				for (let i of value.split('\n'))
					if (i && !stubValidator.apply('hostname', i))
						return _('Expecting: %s').format(_('valid hostname'));

			return true;
		}

		return m.render();
	}
});
