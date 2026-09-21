/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Csing-box - Panel config file
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

	/* "Save & Apply" writes the file and then reloads the service so the edited config
	 * takes effect (the init script re-runs generate_client.uc on every start). The plain
	 * "Save" button only writes the file. */
	handleSaveApply(ev, mode) {
		return this.handleSave(ev)
			.then(() => L.resolveDefault(callServiceReload(), {}))
			.then((res) => {
				if (res && res.status === 0)
					ui.addNotification(null, E('p', {}, _('Service reloaded.')));
				else
					ui.addNotification(null, E('p', {}, _('Failed to reload service.')));
			});
	},

	render(data) {
		let m, s, o;
		const readRes = data[1];

		m = new form.Map('csingbox');

		s = m.section(form.NamedSection, 'config', 'csingbox', _('sing-box config file'));
		s.anonymous = true;

		/* Panel config file editor */
		if (readRes.error) {
			o = s.option(form.DummyValue, '_file_missing', _('File status'));
			o.default = E('strong', { 'class': 'status-text danger' }, [
				_('File not found. Start the service once, or regenerate the template from the Settings page.')
			]);
		}

		o = s.option(form.TextValue, '_file_content', _('Panel config file'),
			_('File: %s. Invalid JSON will be rejected; the config is also checked with sing-box before saving.').format(PANEL_PATH));
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
	}
});
