/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Csing-box - Config File Editor
 * Based on luci-app-homeproxy (C) 2022-2025 ImmortalWrt.org
 */

'use strict';
'require form';
'require rpc';
'require uci';
'require ui';
'require view';

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

const callServiceReload = rpc.declare({
	object: 'luci.csingbox',
	method: 'service_reload',
	expect: { '': {} }
});

const PANEL_PATH = '/etc/csingbox/sing-box-panel.json';

return view.extend({
	load() {
		return Promise.all([
			uci.load('csingbox'),
			L.resolveDefault(callPanelRead(), {})
		]);
	},

	render(data) {
		const isPanel = uci.get('csingbox', 'config', 'routing_mode') === 'panel';
		const readRes = data[1];

		let m, s, o;

		m = new form.Map('csingbox');

		s = m.section(form.NamedSection, 'config', 'csingbox', _('Config File Editor'));
		s.anonymous = true;

		if (!isPanel) {
			o = s.option(form.DummyValue, '_mode_hint', _('Notice'));
			o.default = E('span', {}, [
				_('Current routing mode is not Clash Panel Manual Routing; this file will not be used until the mode is switched.')
			]);
		}

		if (readRes.error) {
			o = s.option(form.DummyValue, '_file_missing', _('File status'));
			o.default = E('strong', { 'style': 'color:red' }, [
				_('File not found: %s').format(PANEL_PATH) + ' ' +
				_('Enable Clash Panel Manual Routing and start the service once, or regenerate the template from the Settings page.')
			]);
		}

		o = s.option(form.TextValue, '_file_content', _('Panel config file'),
			_('File: %s. Invalid JSON will be rejected; the config is also checked with sing-box before saving. This file is only used when the routing mode is Clash Panel Manual Routing.').format(PANEL_PATH));
		o.rows = 28;
		o.wrap = false;
		o.monospace = true;
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

		o = s.option(form.Button, '_reload_file', _('Reload from disk'));
		o.inputstyle = 'action';
		o.onclick = function() {
			return L.resolveDefault(callPanelRead(), {}).then((res) => {
				const content = (res.content != null) ? res.content : '';
				m.lookupOption('_file_content', 'config')[0].getUIElement('config').setValue(content);
				ui.addNotification(null, E('p', {}, _('Panel config reloaded from disk.')));
			});
		};

		return m.render();
	},

	handleSaveApply(ev) {
		return this.handleSave(ev).then(() => {
			return L.resolveDefault(callServiceReload(), {}).then((res) => {
				if (res && res.status === 0)
					ui.addNotification(null, E('p', {}, _('Service reloaded.')));
				else
					ui.addNotification(null, E('p', {}, _('Failed to reload service.')));
			});
		});
	},

	handleReset: null
});
