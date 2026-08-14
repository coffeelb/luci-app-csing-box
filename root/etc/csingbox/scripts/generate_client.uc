#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2023-2025 ImmortalWrt.org
 */

'use strict';

import { readfile, writefile } from 'fs';
import { connect } from 'ubus';
import { cursor } from 'uci';

import {
	isEmpty, parseURL, strToBool, strToInt, strToTime,
	removeBlankAttrs, validation, HP_DIR, RUN_DIR
} from 'csingbox';

const ubus = connect();

/* const features = ubus.call('luci.csingbox', 'singbox_get_features') || {}; */

/* UCI config start */
const uci = cursor();

const uciconfig = 'csingbox';
uci.load(uciconfig);

const uciinfra = 'infra',
      ucimain = 'config';

const routing_mode = uci.get(uciconfig, ucimain, 'routing_mode') || 'bypass_mainland_china';
const api_panel_port = uci.get(uciconfig, ucimain, 'api_panel_port') || '9090';
const api_panel_secret = uci.get(uciconfig, ucimain, 'api_panel_secret') || '';

let wan_dns = ubus.call('network.interface', 'status', {'interface': 'wan'})?.['dns-server']?.[0];
if (!wan_dns)
	wan_dns = (routing_mode === 'global') ? '8.8.8.8' : '223.5.5.5';

const dns_port = uci.get(uciconfig, uciinfra, 'dns_port') || '6333';

const ntp_server = uci.get(uciconfig, uciinfra, 'ntp_server') || 'time.apple.com';

const ipv6_support = uci.get(uciconfig, ucimain, 'ipv6_support') || '0';

let main_node, sniff_override, dns_server, china_dns_server, dns_default_strategy,
    direct_domain_list, proxy_domain_list;

main_node = uci.get(uciconfig, ucimain, 'main_node') || 'nil';

dns_server = uci.get(uciconfig, ucimain, 'dns_server');
if (isEmpty(dns_server) || dns_server === 'wan')
	dns_server = wan_dns;

if (routing_mode === 'bypass_mainland_china' || routing_mode === 'panel') {
	china_dns_server = uci.get(uciconfig, ucimain, 'china_dns_server');
	if (isEmpty(china_dns_server) || type(china_dns_server) !== 'string' || china_dns_server === 'wan')
		china_dns_server = wan_dns;
}
dns_default_strategy = (ipv6_support !== '1') ? 'ipv4_only' : null;

direct_domain_list = trim(readfile(HP_DIR + '/resources/direct_list.txt'));
if (direct_domain_list)
	direct_domain_list = split(direct_domain_list, /[\r\n]/);

proxy_domain_list = trim(readfile(HP_DIR + '/resources/proxy_list.txt'));
if (proxy_domain_list)
	proxy_domain_list = split(proxy_domain_list, /[\r\n]/);

sniff_override = uci.get(uciconfig, uciinfra, 'sniff_override') || '1';

const proxy_mode = uci.get(uciconfig, ucimain, 'proxy_mode') || 'redirect_tproxy';

const mixed_port = uci.get(uciconfig, uciinfra, 'mixed_port') || '6330';

let self_mark, redirect_port, tproxy_port, udp_timeout;

udp_timeout = uci.get(uciconfig, 'infra', 'udp_timeout');

if (match(proxy_mode, /redirect/)) {
	self_mark = uci.get(uciconfig, 'infra', 'self_mark') || '200';
	redirect_port = uci.get(uciconfig, 'infra', 'redirect_port') || '6331';
}
/* No dedicated UDP node: the main node is also the UDP node, so UDP traffic goes through main-out */
if (match(proxy_mode, /tproxy/))
	tproxy_port = uci.get(uciconfig, 'infra', 'tproxy_port') || '6332';

const log_level = uci.get(uciconfig, ucimain, 'log_level') || 'warn';
/* UCI config end */

/* Config helper start */
function parse_port(strport) {
	if (type(strport) !== 'array' || isEmpty(strport))
		return null;

	let ports = [];
	for (let i in strport)
		push(ports, int(i));

	return ports;

}

function parse_dnsserver(server_addr, default_protocol) {
	if (isEmpty(server_addr))
		return null;

	if (!match(server_addr, /:\/\//))
		server_addr = (default_protocol || 'udp') + '://' + (validation('ip6addr', server_addr) ? `[${server_addr}]` : server_addr);
	server_addr = parseURL(server_addr);

	return {
		type: server_addr.protocol,
		server: server_addr.hostname,
		server_port: strToInt(server_addr.port),
		path: (server_addr.pathname !== '/') ? server_addr.pathname : null,
	}
}

function generate_endpoint(node) {
	if (type(node) !== 'object' || isEmpty(node))
		return null;

	const endpoint = {
		type: node.type,
		tag: 'cfg-' + node['.name'] + '-out',
		address: node.wireguard_local_address,
		mtu: strToInt(node.wireguard_mtu),
		private_key: node.wireguard_private_key,
		peers: (node.type === 'wireguard') ? [
			{
				address: node.address,
				port: strToInt(node.port),
				allowed_ips: [
					'0.0.0.0/0',
					'::/0'
				],
				persistent_keepalive_interval: strToInt(node.wireguard_persistent_keepalive_interval),
				public_key: node.wireguard_peer_public_key,
				pre_shared_key: node.wireguard_pre_shared_key,
				reserved: parse_port(node.wireguard_reserved),
			}
		] : null,
		system: (node.type === 'wireguard') ? false : null,
		tcp_fast_open: strToBool(node.tcp_fast_open),
		tcp_multi_path: strToBool(node.tcp_multi_path),
		udp_fragment: strToBool(node.udp_fragment)
	};

	return endpoint;
}

function generate_outbound(node) {
	if (type(node) !== 'object' || isEmpty(node))
		return null;

	const outbound = {
		type: node.type,
		tag: 'cfg-' + node['.name'] + '-out',
		routing_mark: strToInt(self_mark),

		server: node.address,
		server_port: strToInt(node.port),
		/* Hysteria(2) */
		server_ports: node.hysteria_hopping_port,

		username: (node.type !== 'ssh') ? node.username : null,
		user: (node.type === 'ssh') ? node.username : null,
		password: node.password,

		/* Direct */
		proxy_protocol: strToInt(node.proxy_protocol),
		/* AnyTLS */
		idle_session_check_interval: strToTime(node.anytls_idle_session_check_interval),
		idle_session_timeout: strToTime(node.anytls_idle_session_timeout),
		min_idle_session: strToInt(node.anytls_min_idle_session),
		/* Hysteria (2) */
		hop_interval: strToTime(node.hysteria_hop_interval),
		up_mbps: strToInt(node.hysteria_up_mbps),
		down_mbps: strToInt(node.hysteria_down_mbps),
		obfs: node.hysteria_obfs_type ? {
			type: node.hysteria_obfs_type,
			password: node.hysteria_obfs_password
		} : node.hysteria_obfs_password,
		auth: (node.hysteria_auth_type === 'base64') ? node.hysteria_auth_payload : null,
		auth_str: (node.hysteria_auth_type === 'string') ? node.hysteria_auth_payload : null,
		recv_window_conn: strToInt(node.hysteria_recv_window_conn),
		recv_window: strToInt(node.hysteria_revc_window),
		disable_mtu_discovery: strToBool(node.hysteria_disable_mtu_discovery),
		/* Shadowsocks */
		method: node.shadowsocks_encrypt_method,
		plugin: node.shadowsocks_plugin,
		plugin_opts: node.shadowsocks_plugin_opts,
		/* ShadowTLS / Socks */
		version: (node.type === 'shadowtls') ? strToInt(node.shadowtls_version) : ((node.type === 'socks') ? node.socks_version : null),
		/* SSH */
		client_version: node.ssh_client_version,
		host_key: node.ssh_host_key,
		host_key_algorithms: node.ssh_host_key_algo,
		private_key: node.ssh_priv_key,
		private_key_passphrase: node.ssh_priv_key_pp,
		/* Tuic */
		uuid: node.uuid,
		congestion_control: node.tuic_congestion_control,
		udp_relay_mode: node.tuic_udp_relay_mode,
		udp_over_stream: strToBool(node.tuic_udp_over_stream),
		zero_rtt_handshake: strToBool(node.tuic_enable_zero_rtt),
		heartbeat: strToTime(node.tuic_heartbeat),
		/* VLESS / VMess */
		flow: node.vless_flow,
		alter_id: strToInt(node.vmess_alterid),
		security: node.vmess_encrypt,
		global_padding: strToBool(node.vmess_global_padding),
		authenticated_length: strToBool(node.vmess_authenticated_length),
		packet_encoding: node.packet_encoding,

		multiplex: (node.multiplex === '1') ? {
			enabled: true,
			protocol: node.multiplex_protocol,
			max_connections: strToInt(node.multiplex_max_connections),
			min_streams: strToInt(node.multiplex_min_streams),
			max_streams: strToInt(node.multiplex_max_streams),
			padding: strToBool(node.multiplex_padding),
			brutal: (node.multiplex_brutal === '1') ? {
				enabled: true,
				up_mbps: strToInt(node.multiplex_brutal_up),
				down_mbps: strToInt(node.multiplex_brutal_down)
			} : null
		} : null,
		tls: (node.tls === '1') ? {
			enabled: true,
			server_name: node.tls_sni,
			insecure: strToBool(node.tls_insecure),
			alpn: node.tls_alpn,
			min_version: node.tls_min_version,
			max_version: node.tls_max_version,
			cipher_suites: node.tls_cipher_suites,
			certificate_path: node.tls_cert_path,
			ech: (node.tls_ech === '1') ? {
				enabled: true,
				config_path: node.tls_ech_config_path
			} : null,
			utls: !isEmpty(node.tls_utls) ? {
				enabled: true,
				fingerprint: node.tls_utls
			} : null,
			reality: (node.tls_reality === '1') ? {
				enabled: true,
				public_key: node.tls_reality_public_key,
				short_id: node.tls_reality_short_id
			} : null
		} : null,
		transport: !isEmpty(node.transport) ? {
			type: node.transport,
			host: node.http_host || node.httpupgrade_host,
			path: node.http_path || node.ws_path,
			headers: node.ws_host ? {
				Host: node.ws_host
			} : null,
			method: node.http_method,
			max_early_data: strToInt(node.websocket_early_data),
			early_data_header_name: node.websocket_early_data_header,
			service_name: node.grpc_servicename,
			idle_timeout: strToTime(node.http_idle_timeout),
			ping_timeout: strToTime(node.http_ping_timeout),
			permit_without_stream: strToBool(node.grpc_permit_without_stream)
		} : null,
		udp_over_tcp: (node.udp_over_tcp === '1') ? {
			enabled: true,
			version: strToInt(node.udp_over_tcp_version)
		} : null,
		tcp_fast_open: strToBool(node.tcp_fast_open),
		tcp_multi_path: strToBool(node.tcp_multi_path),
		udp_fragment: strToBool(node.udp_fragment)
	};

	return outbound;
}

/* Config helper end */

const config = {};

/* Log */
config.log = {
	disabled: false,
	level: log_level,
	output: RUN_DIR + '/sing-box-c.log',
	timestamp: true
};

/* NTP */
if (!isEmpty(ntp_server))
	config.ntp = {
		enabled: true,
		server: ntp_server,
		detour: 'direct-out',
		domain_resolver: 'default-dns',
	};

/* DNS start */
/* Default settings */
config.dns = {
	servers: [
		{
			tag: 'default-dns',
			type: 'udp',
			server: wan_dns,
			detour: self_mark ? 'direct-out' : null
		},
		{
			tag: 'system-dns',
			type: 'local',
			detour: self_mark ? 'direct-out' : null
		}
	],
	rules: [],
	strategy: dns_default_strategy
};

if (!isEmpty(main_node)) {
	/* Main DNS */
	push(config.dns.servers, {
		tag: 'main-dns',
		domain_resolver: {
			server: 'default-dns',
			strategy: (ipv6_support !== '1') ? 'ipv4_only' : null
		},
		detour: 'main-out',
		...parse_dnsserver(dns_server, 'tcp')
	});
	config.dns.final = 'main-dns';

	if (length(direct_domain_list))
		push(config.dns.rules, {
			rule_set: 'direct-domain',
			action: 'route',
			server: (routing_mode === 'bypass_mainland_china' || routing_mode === 'panel') ? 'china-dns' : 'default-dns'
		});

	/* Filter out SVCB/HTTPS queries for "exquisite" Apple devices */
	if (routing_mode === 'gfwlist' || length(proxy_domain_list))
		push(config.dns.rules, {
			rule_set: (routing_mode !== 'gfwlist') ? 'proxy-domain' : null,
			query_type: [64, 65],
			action: 'reject'
		});

	if (routing_mode === 'bypass_mainland_china' || routing_mode === 'panel') {
		push(config.dns.servers, {
			tag: 'china-dns',
			domain_resolver: {
				server: 'default-dns',
				strategy: 'prefer_ipv6'
			},
			detour: self_mark ? 'direct-out' : null,
			...parse_dnsserver(china_dns_server)
		});

		if (length(proxy_domain_list))
			push(config.dns.rules, {
				rule_set: 'proxy-domain',
				action: 'route',
				server: 'main-dns'
			});

		push(config.dns.rules, {
			rule_set: 'geosite-cn',
			action: 'route',
			server: 'china-dns',
			strategy: 'prefer_ipv6'
		});
		push(config.dns.rules, {
			type: 'logical',
			mode: 'and',
			rules: [
				{
					rule_set: 'geosite-noncn',
					invert: true
				},
				{
					rule_set: 'geoip-cn'
				}
			],
			action: 'route',
			server: 'china-dns',
			strategy: 'prefer_ipv6'
		});
	}
}
/* DNS end */

/* Inbound start */
config.inbounds = [];

push(config.inbounds, {
	type: 'direct',
	tag: 'dns-in',
	listen: '::',
	listen_port: int(dns_port)
});

push(config.inbounds, {
	type: 'mixed',
	tag: 'mixed-in',
	listen: '::',
	listen_port: int(mixed_port),
	udp_timeout: strToTime(udp_timeout),
	sniff: true,
	sniff_override_destination: strToBool(sniff_override),
	set_system_proxy: false
});

if (match(proxy_mode, /redirect/))
	push(config.inbounds, {
		type: 'redirect',
		tag: 'redirect-in',

		listen: '::',
		listen_port: int(redirect_port),
		sniff: true,
		sniff_override_destination: strToBool(sniff_override)
	});
if (match(proxy_mode, /tproxy/))
	push(config.inbounds, {
		type: 'tproxy',
		tag: 'tproxy-in',

		listen: '::',
		listen_port: int(tproxy_port),
		network: 'udp',
		udp_timeout: strToTime(udp_timeout),
		sniff: true,
		sniff_override_destination: strToBool(sniff_override)
	});
/* Inbound end */

/* Outbound start */
config.endpoints = [];

/* Default outbounds */
config.outbounds = [
	{
		type: 'direct',
		tag: 'direct-out',
		routing_mark: strToInt(self_mark)
	}
];

/* Main outbounds */
if (routing_mode === 'panel') {
	const selector_outbounds = [];
	const main_urltest_nodes = uci.get(uciconfig, ucimain, 'main_urltest_nodes') || [];

	uci.foreach(uciconfig, 'node', (cfg) => {
		if (cfg.type === 'wireguard')
			push(config.endpoints, generate_endpoint(cfg));
		else
			push(config.outbounds, generate_outbound(cfg));
		push(selector_outbounds, 'cfg-' + cfg['.name'] + '-out');
	});

	if (length(main_urltest_nodes)) {
		push(config.outbounds, {
			type: 'urltest',
			tag: 'urltest-main',
			outbounds: map(main_urltest_nodes, (k) => `cfg-${k}-out`),
			interval: strToTime(uci.get(uciconfig, ucimain, 'main_urltest_interval')),
			tolerance: strToInt(uci.get(uciconfig, ucimain, 'main_urltest_tolerance'))
		});
		push(selector_outbounds, 'urltest-main');
	}

	push(config.outbounds, {
		type: 'selector',
		tag: 'main-out',
		outbounds: selector_outbounds,
		default: (!isEmpty(main_node) && main_node !== 'nil' && main_node !== 'urltest' &&
		          uci.get_all(uciconfig, main_node)) ? 'cfg-' + main_node + '-out' : null,
		interrupt_exist_connections: true
	});
} else if (!isEmpty(main_node)) {
	let urltest_nodes = [];

	if (main_node === 'urltest') {
		const main_urltest_nodes = uci.get(uciconfig, ucimain, 'main_urltest_nodes') || [];
		const main_urltest_interval = uci.get(uciconfig, ucimain, 'main_urltest_interval');
		const main_urltest_tolerance = uci.get(uciconfig, ucimain, 'main_urltest_tolerance');

		push(config.outbounds, {
			type: 'urltest',
			tag: 'main-out',
			outbounds: map(main_urltest_nodes, (k) => `cfg-${k}-out`),
			interval: strToTime(main_urltest_interval),
			tolerance: strToInt(main_urltest_tolerance),
			idle_timeout: (strToInt(main_urltest_interval) > 1800) ? `${main_urltest_interval * 2}s` : null,
		});
		urltest_nodes = main_urltest_nodes;
	} else {
		const main_node_cfg = uci.get_all(uciconfig, main_node) || {};
		if (main_node_cfg.type === 'wireguard') {
			push(config.endpoints, generate_endpoint(main_node_cfg));
			config.endpoints[length(config.endpoints)-1].tag = 'main-out';
		} else {
			push(config.outbounds, generate_outbound(main_node_cfg));
			config.outbounds[length(config.outbounds)-1].tag = 'main-out';
		}
	}

	for (let i in urltest_nodes) {
		const urltest_node = uci.get_all(uciconfig, i) || {};
		if (urltest_node.type === 'wireguard') {
			push(config.endpoints, generate_endpoint(urltest_node));
			config.endpoints[length(config.endpoints)-1].tag = 'cfg-' + i + '-out';
		} else {
			push(config.outbounds, generate_outbound(urltest_node));
			config.outbounds[length(config.outbounds)-1].tag = 'cfg-' + i + '-out';
		}
	}
}

if (isEmpty(config.endpoints))
	config.endpoints = null;
/* Outbound end */

/* Routing rules start */
/* Default settings */
config.route = {
	rules: [
		{
			inbound: 'dns-in',
			action: 'hijack-dns'
		}
		/*
		 * leave for sing-box 1.13.0
		 * {
		 * 	action: 'sniff'
		 * }
		 */
	],
	rule_set: [],
	auto_detect_interface: true
};

/* Routing rules */
if (!isEmpty(main_node)) {
	/* Avoid DNS loop */
	config.route.default_domain_resolver = {
		action: 'route',
		server: (routing_mode === 'bypass_mainland_china' || routing_mode === 'panel') ? 'china-dns' : 'default-dns',
		strategy: (ipv6_support !== '1') ? 'prefer_ipv4' : null
	};

	/* Direct list */
	if (length(direct_domain_list))
		push(config.route.rules, {
			rule_set: 'direct-domain',
			action: 'route',
			outbound: 'direct-out'
		});

	/* Direct outbound destination override: sing-box >= 1.11 uses the route option (the outbound field is deprecated and removed in 1.13) */
	if (main_node !== 'urltest') {
		const main_node_cfg = uci.get_all(uciconfig, main_node) || {};
		if (main_node_cfg.type === 'direct' &&
		    (!isEmpty(main_node_cfg.override_address) || !isEmpty(main_node_cfg.override_port)))
			push(config.route.rules, {
				action: 'route',
				outbound: 'main-out',
				override_address: main_node_cfg.override_address,
				override_port: strToInt(main_node_cfg.override_port)
			});
	}

	config.route.final = 'main-out';

	/* Rule set */
	/* Direct list */
	if (length(direct_domain_list))
		push(config.route.rule_set, {
			type: 'inline',
			tag: 'direct-domain',
			rules: [
				{
					domain_keyword: direct_domain_list,
				}
			]
		});

	/* Proxy list */
	if (length(proxy_domain_list))
		push(config.route.rule_set, {
			type: 'inline',
			tag: 'proxy-domain',
			rules: [
				{
					domain_keyword: proxy_domain_list,
				}
			]
		});

	if (routing_mode === 'bypass_mainland_china' || routing_mode === 'panel') {
		push(config.route.rule_set, {
			type: 'remote',
			tag: 'geoip-cn',
			format: 'binary',
			url: 'https://fastly.jsdelivr.net/gh/1715173329/IPCIDR-CHINA@rule-set/cn.srs',
			download_detour: 'main-out'
		});
		push(config.route.rule_set, {
			type: 'remote',
			tag: 'geosite-cn',
			format: 'binary',
			url: 'https://fastly.jsdelivr.net/gh/1715173329/sing-geosite@rule-set-unstable/geosite-geolocation-cn.srs',
			download_detour: 'main-out'
		});
		push(config.route.rule_set, {
			type: 'remote',
			tag: 'geosite-noncn',
			format: 'binary',
			url: 'https://fastly.jsdelivr.net/gh/1715173329/sing-geosite@rule-set-unstable/geosite-geolocation-!cn.srs',
			download_detour: 'main-out'
		});
	}

	if (isEmpty(config.route.rule_set))
		config.route.rule_set = null;
}
/* Routing rules end */

/* Experimental start */
if (routing_mode === 'bypass_mainland_china' || routing_mode === 'panel') {
	config.experimental = {
		cache_file: {
			enabled: true,
			path: RUN_DIR + '/cache.db'
		}
	};

	if (routing_mode === 'panel') {
		config.experimental.clash_api = {
			external_controller: '0.0.0.0:' + api_panel_port,
			secret: api_panel_secret,
			default_mode: 'rule',
			external_ui: HP_DIR + '/yacd',
			external_ui_download_url: 'https://github.com/MetaCubeX/Yacd-meta/archive/gh-pages.zip',
			external_ui_download_detour: 'main-out'
		};
	}
}
/* Experimental end */

system('mkdir -p ' + RUN_DIR);
const config_json = sprintf('%.J\n', removeBlankAttrs(config));

/* Always generate the regular config */
writefile(RUN_DIR + '/sing-box-c.json', config_json);

/* Clash panel mode: the persistent template lives in /etc/csingbox (survives reboots),
 * the runtime copy in /var/run. The template is generated automatically on first start,
 * then maintained manually (auto-generation never overwrites it); each start refreshes
 * the runtime copy from the persistent template. */
if (routing_mode === 'panel') {
	if (!readfile(HP_DIR + '/sing-box-panel.json')) {
		/* Upgrade migration: the manually-maintained copy used to live in /var/run; preserve manual modifications */
		const legacy_panel = readfile(RUN_DIR + '/sing-box-panel.json');
		writefile(HP_DIR + '/sing-box-panel.json', legacy_panel || config_json);
	}
	writefile(RUN_DIR + '/sing-box-panel.json', readfile(HP_DIR + '/sing-box-panel.json'));
}
