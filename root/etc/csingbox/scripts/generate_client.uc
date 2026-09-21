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
	removeBlankAttrs, validation, CS_DIR, RUN_DIR
} from 'csingbox';

const ubus = connect();

/* UCI config start */
const uci = cursor();

const uciconfig = 'csingbox';
uci.load(uciconfig);

const uciinfra = 'infra',
      ucimain = 'config';

const api_panel_port = uci.get(uciconfig, ucimain, 'api_panel_port') || '9090';
const api_panel_secret = uci.get(uciconfig, ucimain, 'api_panel_secret') || '';
const api_panel_enabled = uci.get(uciconfig, ucimain, 'api_panel_enabled') || '0';

let wan_dns = ubus.call('network.interface', 'status', {'interface': 'wan'})?.['dns-server']?.[0];
if (!wan_dns)
	wan_dns = '223.5.5.5';

const dns_port = uci.get(uciconfig, uciinfra, 'dns_port') || '6333';

const ntp_server = uci.get(uciconfig, uciinfra, 'ntp_server') || 'time.apple.com';

const ipv6_support = uci.get(uciconfig, ucimain, 'ipv6_support') || '0';

const quic_reject = uci.get(uciconfig, ucimain, 'quic_reject') || '0';

const multi_queue = uci.get(uciconfig, ucimain, 'multi_queue') || '0';

/* Routing ports: 'common' proxies only the preset list, 'all' every port, anything else is a
 * comma-separated list with `a:b` ranges. Ports outside the list are kept out of the proxy by
 * the two route rules below. */
const common_routing_ports = [53, 80, 443, 853, 5222, 8443];

let routing_port = uci.get(uciconfig, ucimain, 'routing_port');
if (routing_port === null)
	routing_port = 'common';

let routing_ports, routing_port_ranges;
if (routing_port === 'common') {
	routing_ports = common_routing_ports;
	routing_port_ranges = [];
} else if (routing_port !== '' && routing_port !== 'all') {
	routing_ports = [];
	routing_port_ranges = [];
	const routing_port_items = split(routing_port, ',');
	for (let i = 0; i < length(routing_port_items); i++) {
		const item = trim(routing_port_items[i]);
		if (item === '')
			continue;
		if (match(item, /^[0-9]+$/))
			push(routing_ports, int(item));
		else
			push(routing_port_ranges, item);
	}
}

/* Port 53 is pinned: plaintext DNS (clients using their own resolver) must always reach the
 * sing-box hijack, so it stays in the effective list no matter what the option says. */
if (routing_port !== '' && routing_port !== 'all') {
	let pinned_routing_ports = [53];
	for (let i = 0; i < length(routing_ports); i++)
		if (routing_ports[i] !== 53)
			push(pinned_routing_ports, routing_ports[i]);
	routing_ports = pinned_routing_ports;
}

/* Port match for both routing-port rules; unusable values are dropped, so a malformed list
 * cannot break the config. */
let routing_port_exclude = null;
if (routing_port !== '' && routing_port !== 'all') {
	let ports = [], ranges = [], seen = {};
	for (let i = 0; i < length(routing_ports); i++) {
		const port = routing_ports[i];
		if (port < 0 || port > 65535)
			continue;
		const item = sprintf('%d', port);
		if (seen[item])
			continue;
		seen[item] = true;
		push(ports, port);
	}
	for (let i = 0; i < length(routing_port_ranges); i++) {
		const range = match(routing_port_ranges[i], /^([0-9]+)[:-]([0-9]+)$/);
		if (!range || int(range[1]) > int(range[2]) || int(range[2]) > 65535)
			continue;
		const item = sprintf('%d:%d', int(range[1]), int(range[2]));
		if (seen[item])
			continue;
		seen[item] = true;
		push(ranges, item);
	}
	if (length(ports) || length(ranges)) {
		routing_port_exclude = { invert: true };
		if (length(ports))
			routing_port_exclude.port = ports;
		if (length(ranges))
			routing_port_exclude.port_range = ranges;
	}
}

let main_node, dns_server, china_dns_server;

main_node = uci.get(uciconfig, ucimain, 'main_node') || 'nil';

dns_server = uci.get(uciconfig, ucimain, 'dns_server');
if (isEmpty(dns_server) || dns_server === 'wan')
	dns_server = wan_dns;

china_dns_server = uci.get(uciconfig, ucimain, 'china_dns_server');
if (isEmpty(china_dns_server) || type(china_dns_server) !== 'string' || china_dns_server === 'wan')
	china_dns_server = wan_dns;

/* Per-device access control. The old implementation used nftables `ether saddr` rules; with
 * TUN + auto_redirect the native tun options replace them. include/exclude are mutually
 * exclusive in sing-box, so only one of them is ever emitted. */
let mac_include, mac_exclude;

const lan_proxy_mode = uci.get(uciconfig, 'control', 'lan_proxy_mode') || 'disabled';
if (lan_proxy_mode === 'listed_only')
	mac_include = uci.get(uciconfig, 'control', 'lan_proxy_mac_addrs');
else if (lan_proxy_mode === 'except_listed')
	mac_exclude = uci.get(uciconfig, 'control', 'lan_direct_mac_addrs');

const dns_default_strategy = (ipv6_support !== '1') ? 'ipv4_only' : null;

const mixed_port = uci.get(uciconfig, uciinfra, 'mixed_port') || '6330';

/* UDP session timeout. 300 = sing-box's own 5-minute default (upstream writes 300s too);
 * empty or missing falls back to 300. */
const udp_timeout = uci.get(uciconfig, 'infra', 'udp_timeout') || '300';

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
		/* packet_encoding is only accepted by the vless/vmess outbounds in sing-box 1.14;
		 * a stale value left on another node type would invalidate the whole config. */
		packet_encoding: (node.type === 'vless' || node.type === 'vmess') ? node.packet_encoding : null,

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
			detour: 'direct-out'
		}
	],
	rules: [],
	strategy: dns_default_strategy,
	/* Stale-while-revalidate with a short window (the 3d default is too long here). */
	optimistic: {
		enabled: true,
		timeout: '1h'
	},
	/* Domain names for IP-form connections (logs, dashboard, domain route rules). */
	reverse_mapping: true
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

	/* Mainland DNS split: CN domains are resolved by the domestic server, everything else by
	 * the remote one. The former "mainland fallback" (evaluate + match_response/geoip-cn ->
	 * china-dns) is no longer generated: it only fired when the remote resolver itself
	 * returned a CN address, and every hit cost an extra domestic lookup. The README shows how
	 * to add those two rules back in the panel config. */
	push(config.dns.servers, {
		tag: 'china-dns',
		/* No explicit strategy: fall back to the global dns.strategy, which already
		 * follows ipv6_support (ipv4_only when IPv6 support is disabled). */
		domain_resolver: {
			server: 'default-dns'
		},
		detour: 'direct-out',
		...parse_dnsserver(china_dns_server)
	});
	push(config.dns.rules, {
		rule_set: 'geosite-cn',
		action: 'route',
		server: 'china-dns'
	});
}
/* DNS end */

/* Inbound start */
config.inbounds = [];

/* TUN inbound: TCP and UDP are both handled by the sing-box 1.15 native TUN stack.
 * Values are intentionally fixed; see the package README for the rationale. */
push(config.inbounds, {
	type: 'tun',
	tag: 'tun-in',

	/* Fixed name: nothing else depends on it, but a stable interface name keeps routing
	 * and troubleshooting predictable. */
	interface_name: 'singtun0',
	address: (ipv6_support === '1') ? ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'] : ['172.19.0.1/30'],
	mtu: 9000,
	/* The `stack` option is intentionally absent: it is deprecated as of sing-box 1.15.0, and
	 * omitting it selects the new native TCP/IP stack this package targets. */
	auto_route: true,
	auto_redirect: true,
	strict_route: false,
	exclude_mptcp: true,
	/* Native-stack only (sing-box 1.15+, Linux): open the device with IFF_MULTI_QUEUE and run
	 * one queue per CPU. The stack logs a warning and falls back to a single queue if the
	 * device does not support it. */
	multi_queue: strToBool(multi_queue),
	/* hijack: TUN takes over port 53 for non-local destinations; no dns_address is set,
	 * so the automatic hijack into the DNS module stays enabled. */
	dns_mode: 'hijack',
	udp_timeout: strToTime(udp_timeout),

	/* Mainland IPs bypass sing-box in the nftables pre-match stage instead of entering
	 * userspace routing (geoip-cn is an IP-CIDR rule-set, so domain lists don't apply).
	 * Note: this bypass takes precedence over every route rule, i.e. a CN destination can
	 * no longer be forced through the proxy while this option is set. */
	route_exclude_address_set: ['geoip-cn'],

	/* Device-level filter (only one of the two can be set) */
	include_mac_address: mac_include,
	exclude_mac_address: mac_exclude
});

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
	set_system_proxy: false
});
/* Inbound end */

/* Outbound start */
config.endpoints = [];

/* Default outbounds */
config.outbounds = [
	{
		type: 'direct',
		tag: 'direct-out',
		/* The DNS servers use this outbound as detour; sing-box rejects "detour to an empty
		 * direct outbound", and routing_mark cannot be used here because auto_redirect
		 * conflicts with dial marks. Resolving direct destinations with the local DNS keeps
		 * this outbound non-empty. */
		domain_resolver: 'default-dns'
	}
];

/* Main outbounds */
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

if (isEmpty(config.endpoints))
	config.endpoints = null;
/* Outbound end */

/* Routing rules start */
/* Default settings */
config.route = {
	rules: [],
	auto_detect_interface: true,
	/* LAN device hostnames/MACs for logs and dashboard. Explicit lease path: the
	 * auto-detection skips files that are empty at startup (tmpfs after a reboot). */
	find_neighbor: true,
	dhcp_lease_files: ['/tmp/dhcp.leases']
};

/* Private destinations (ip_is_private: RFC 1918 + ULA) are bypassed at kernel level in
 * pre-match; the direct rule below covers the contexts where `bypass` does not apply.
 * CGNAT is deliberately not handled (upstream ignores it too). */
push(config.route.rules, {
	type: 'logical',
	mode: 'and',
	rules: [
		{ inbound: 'tun-in' },
		{ ip_is_private: true }
	],
	action: 'bypass'
});

/* Routing ports, first half: kernel-level `bypass` in pre-match, so ports outside the list
 * never enter userspace. Must precede the sniff rule - pre-match stops at sniff for TCP.
 * ICMP (no port) matches the inverted rule as well. */
if (routing_port_exclude !== null)
	push(config.route.rules, {
		type: 'logical',
		mode: 'and',
		rules: [
			{ inbound: 'tun-in' },
			routing_port_exclude
		],
		action: 'bypass'
	});

push(config.route.rules, {
	action: 'sniff'
});
push(config.route.rules, {
	inbound: 'dns-in',
	action: 'hijack-dns'
});

/* Routing rules */
if (!isEmpty(main_node)) {
	/* Avoid DNS loop */
	config.route.default_domain_resolver = {
		server: 'default-dns',
		strategy: (ipv6_support !== '1') ? 'prefer_ipv4' : null
	};

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

	/* Shared HTTP client for remote rule-set and panel dashboard downloads (sing-box >= 1.14) */
	config.http_clients = [{
		tag: 'main',
		detour: 'main-out'
	}];
	config.route.default_http_client = 'main';

	/* Non-public destinations never go to the proxy: the bypass above covers auto-redirect
	 * traffic, this rule the rest (LAN proxy port, established connections). Drop it on the
	 * Panel Config page to force a private range through an outbound. */
	push(config.route.rules, {
		ip_is_private: true,
		action: 'route',
		outbound: 'direct-out'
	});

	/* Second half: `bypass` only works in pre-match, this copy covers the rest (mixed inbound,
	 * established connections, the router's own traffic). */
	if (routing_port_exclude !== null)
		push(config.route.rules, { ...routing_port_exclude, action: 'route', outbound: 'direct-out' });

	/* Mainland China direct split, shipped with the panel template by default.
	 * The rule-sets are remote .srs files: they are fetched through the main outbound
	 * (config.route.default_http_client) and cached in cache.db. Panel users are free to
	 * edit or remove them on the Panel Config page. */
	push(config.route.rules, {
		rule_set: 'geosite-cn',
		action: 'route',
		outbound: 'direct-out'
	});
	push(config.route.rules, {
		rule_set: 'geoip-cn',
		action: 'route',
		outbound: 'direct-out'
	});
	/* Reject proxied QUIC (UDP 80/443) so clients fall back to TCP. */
	if (quic_reject === '1') {
		push(config.route.rules, {
			network: 'udp',
			port: [80, 443],
			action: 'reject',
			no_drop: true
		});
	}
	config.route.rule_set = [
		{
			type: 'remote',
			tag: 'geosite-cn',
			format: 'binary',
			url: 'https://fastly.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-geolocation-cn.srs',
			http_client: 'main'
		},
		{
			type: 'remote',
			tag: 'geoip-cn',
			format: 'binary',
			url: 'https://fastly.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/geoip-cn.srs',
			http_client: 'main'
		},
		/* Kept for parity with the pre-1.2.0 template: the tag is available to panel rules.
		 * The old DNS rule that consumed it (logical: not geosite-noncn and geoip-cn ->
		 * china-dns) belonged to the removed DNS split and is not generated anymore. */
		{
			type: 'remote',
			tag: 'geosite-noncn',
			format: 'binary',
			url: 'https://fastly.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-geolocation-!cn.srs',
			http_client: 'main'
		}
	];
}
/* Routing rules end */

/* Experimental start */
config.experimental = {
	cache_file: {
		enabled: true,
		path: RUN_DIR + '/cache.db',
		/* Keep the DNS cache across service restarts (tmpfs, no flash writes). */
		store_dns: true
	}
};

/* sing-box 1.14 native API service, serving sing-box-dashboard over the same listener.
 * Generated only while the panel is enabled (see the panel switch below). */
if (api_panel_enabled === '1') {
	config.services = [{
		type: 'api',
		tag: 'api',
		listen: '0.0.0.0',
		listen_port: int(api_panel_port),
		secret: api_panel_secret,
		access_control_allow_private_network: true,
		dashboard: {
			enabled: true,
			path: CS_DIR + '/ui/dashboard',
			download_url: 'https://github.com/SagerNet/sing-box-dashboard/archive/refs/heads/gh-pages.zip',
			http_client: 'main',
			update_interval: '7d'
		}
	}];
}
/* Experimental end */

system('mkdir -p ' + RUN_DIR);

const config_json = sprintf('%.J\n', removeBlankAttrs(config));

/* The panel template lives in /etc/csingbox (survives reboots), the runtime copy in /var/run.
 * The template is generated on first start and then maintained manually; the generator only
 * ever touches its `services` entry, to follow the panel switch. */
if (!readfile(CS_DIR + '/sing-box-panel.json')) {
	/* Upgrade migration: the manually-maintained copy used to live in /var/run; preserve manual modifications */
	const legacy_panel = readfile(RUN_DIR + '/sing-box-panel.json');
	writefile(CS_DIR + '/sing-box-panel.json', legacy_panel || config_json);
}

/* Panel switch: the API/dashboard service exists in the config only while the panel is on.
 * Turning the panel off removes it, turning it on generates it again from the page settings,
 * so neither the running config nor the stored config keeps panel content while it is off.
 * Only the `services` entry is touched, everything else stays as the user left it, and the
 * stored file is rewritten only when that entry actually changed. */
const panel_enabled = api_panel_enabled === '1';
let panel_json = readfile(CS_DIR + '/sing-box-panel.json');
let panel_synced = false;

try {
	const panel_obj = json(panel_json);

	if (type(panel_obj) === 'object') {
		const services = (type(panel_obj.services) === 'array') ? panel_obj.services : [];
		/* manually added services are kept either way */
		const other_services = filter(services, (svc) => svc?.type !== 'api');

		if (!panel_enabled && length(other_services) !== length(services)) {
			/* panel off: drop the panel service */
			if (length(other_services))
				panel_obj.services = other_services;
			else
				delete panel_obj.services;
			panel_synced = true;
		} else if (panel_enabled && length(other_services) === length(services)) {
			/* panel on, but this config was generated while the panel was off */
			push(other_services, config.services[0]);
			panel_obj.services = other_services;
			panel_synced = true;
		}

		if (panel_synced)
			panel_json = sprintf('%.J\n', panel_obj);
	}
} catch (e) {
	/* Leave a malformed config untouched: the service reports the config error. */
}

/* Keep the stored template in sync (the init script re-applies chmod 600 right after this). */
if (panel_synced) {
	writefile(CS_DIR + '/sing-box-panel.json', panel_json);
}

writefile(RUN_DIR + '/sing-box-panel.json', panel_json);
