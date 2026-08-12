# Csing-box (luci-app-csing-box)

Csing-box is an OpenWrt / ImmortalWrt / LuCI proxy plugin that simplifies the logic of [immortalwrt/homeproxy](https://github.com/immortalwrt/homeproxy), powered by the [sing-box](https://github.com/SagerNet/sing-box) proxy core. The UI style, layout and routing logic stay consistent with homeproxy; some features were removed, the code was modified, and Clash panel support was added.

Originally I only wanted to add a Clash panel feature; once added, I figured why not add a mode to edit the config file for custom routing; after adding that, homeproxy's custom routing felt redundant, and it gradually drifted further and further from the original...

## What's New / Changed

The following adjustments were made on top of homeproxy:

- **Routing mode**: added "Clash Panel Manual Routing" mode, which allows manually editing `/etc/csingbox/sing-box-panel.json` for custom routing;
- **Yacd panel**: on first start, the panel UI (Yacd-meta) is downloaded to `/etc/csingbox/yacd` and served locally at `http://<router-ip>:9090/ui/`, so the first start may be a bit slower; once enabled, you can select nodes and outbounds directly from the panel;
- **Reload button**: click reload directly after changing the configuration; no need to switch the node off and on;
- **Regenerate Clash panel config file**: clicking regenerate reads the current UI configuration and overwrites the original file; all manually added rules will be lost. **It is recommended to fill in all nodes before regenerating**, so that routing can be done by only editing the rule sets and outbounds in the config file;
- **Default panel rule set sources**: geoip-cn / geosite-cn / geosite-noncn use the jsDelivr mirror (same as homeproxy); panel mode does not pre-bake routing rules (route.rules only keeps DNS hijacking); routing rules must be edited manually in `/etc/csingbox/sing-box-panel.json`.

### Removed Features (vs. homeproxy)

Based on the simplified positioning, the following homeproxy features are removed and not provided:

- **TUN mode**: TUN is not enabled; no TUN firewall chains or policy routing (never used);
- **Server mode**: no sing-box server configuration or logs (never used);
- **Custom routing (custom)**: no routing node / routing rule / DNS rule editors (the "Clash Panel Manual Routing" mode has been added for custom routing);
- **Dedicated UDP node**: no UDP node selection; UDP traffic always goes through the main node (main-out);
- **Client IP-level control**: only MAC address filtering is kept; no lan_direct/proxy IPv4/IPv6 lists (rarely used);
- **Gaming mode / global proxy client**: no lan_gaming / lan_global controls (never used);
- **WAN direct IP list**: no wan_direct IPv4/IPv6 entries (the built-in reserved ranges are already included, just not exposed in the UI);
- **TUN-related settings**: no tun_name / tun_mark / tcpip_stack options (TUN not enabled);
- **Advanced DNS options**: no disable_cache / independent_cache / client_subnet per-node DNS settings (custom routing removed);
- **china_list rule file**: the china_list rule resource is not bundled (config for the proxy-mainland-only mode, which was removed).

## Features

### Settings Page

- Running status (single-line display): running / stopped, current node, routing mode, sing-box core version;
- Node selection: dropdown of nodes added on the "Node Management" page; selecting a node starts the service; default is "Disabled";
- Remote DNS: default `tls://8.8.8.8:853`, presets and custom values supported (UDP / TCP / DoH / DoQ / DoT);
- Local DNS: default `udp://223.5.5.5:53`, presets and custom values supported;
- Routing mode: Bypass Mainland China / Clash Panel Manual Routing / GFWlist / Global, with the same logic as homeproxy;
- Clash panel: automatically enabled when "Clash Panel Manual Routing" is selected; Clash API (external-controller) + default Yacd panel (no bundled UI); port and secret configurable; uses a separate sing-box-panel.json, with the persistent template at /etc/csingbox/sing-box-panel.json (survives reboots, can be edited directly for custom routing); the template is generated on first start and maintained manually afterwards — auto-generation never overwrites it; nodes can be switched directly from the panel; switching to another mode disables the panel;
- **Panel access**: open `http://<router-ip>:9090/ui/` in a browser (or use the "Open Clash panel" button on the settings page); API address: `http://<router-ip>:9090`, password: the configured Secret (default `666b888C`);
  - **Local rule set example**: add a local file rule set under `route.rule_set` in `/etc/csingbox/sing-box-panel.json` and reference it in `route.rules`:
    ```json
    { "type": "local", "tag": "myrules", "path": "/etc/csingbox/resources/myrules.json", "format": "source" }
    ```
    Reference in rules: `{ "rule_set": "myrules", "action": "route", "outbound": "main-out" }`
    File format: `{ "version": 1, "rules": [ { "domain_suffix": ["example.com"] } ] }`;
- Proxy mode: Redirect TCP + TProxy UDP (default) / Redirect TCP; **TUN is not enabled**;
- Routing ports: common ports (16, bypassing P2P traffic) or all ports / custom; only traffic matching the ports enters sing-box for routing; DNS queries are not restricted;
- Automatic rule file updates: fetch the latest china_ip4, china_ip6 and gfw_list every Sunday at 03:00;
- IPv6 support: disabled by default; behavior follows homeproxy when enabled.

### Access Control (Settings Page → Access Control Tab)

- Client control: proxy filter mode (disabled / proxy listed only / proxy all except listed) + direct MAC list + proxy MAC list, based on homeproxy's LAN IP policy and implemented with nftables `ether saddr` matching;
- Domain control: forced direct list (direct_list.txt) and forced proxy list (proxy_list.txt), domain-only, one per line, taking priority over the routing mode.

### Node Management Page

Identical to homeproxy, no reductions:

- User node grid: apply / applied, label, type, address, port, edit / delete;
- Import share links (supports Hysteria, Shadowsocks, Trojan, v2rayN (VMess), XTLS (VLESS) and other online config standards);
- Subscription node tabs and subscription settings tab: auto update, update time, update via proxy, subscription URL, node filtering (disabled / blacklist / whitelist), filter keywords, user agent, allow insecure, default packet encoding, plus "Save subscription settings / Update nodes from subscriptions / Remove all subscription nodes" buttons.

### Status Page

- Resource management: bundled china_ip4, china_ip6 and gfw_list rule files with version display and a manual "Check update" (china_list not included);
- Software log and sing-box log shown in separate sections: auto-refreshed at the LuCI poll interval (default 5 seconds); log size limited to 50KB (truncated when exceeded); only the sing-box log is cleared on reload, while the daemon log keeps its history.

## Routing Logic

The direct/proxy decision is ultimately made by the firewall (nftables / fw4) based on the destination IP, same as homeproxy; sing-box only handles DNS routing and forwarding of intercepted traffic.

- Bypass Mainland China: the firewall lets mainland IP ranges (china_ip4 / china_ip6) through directly, everything else goes through the proxy; on the DNS side, mainland domains are resolved directly via the local DNS, everything else via the remote DNS through the proxy;
- GFWlist: dnsmasq dynamically writes the resolution results of gfw_list domains into nftables sets; matched traffic goes through the proxy, unmatched goes direct; only listed domains use the remote DNS to avoid pollution;
- Global: everything goes through the proxy except reserved addresses and the forced direct list; all DNS goes through the remote DNS;
- Clash panel mode: routing logic identical to Bypass Mainland China (mainland domains resolved directly, firewall lets mainland IPs through), but the outbound is a selector group that can switch nodes in real time from the Clash panel (Yacd etc.); the routing port restriction still applies;
- The forced direct / forced proxy lists take priority over the routing mode (IP/CIDR written into nftables sets, domains dynamically written back via dnsmasq nftset);
- Client control (MAC) is evaluated before traffic enters the redirect chain: proxy listed only / proxy all except listed; it does not affect the router's own traffic.

## Build (OpenWrt SDK / Buildroot)

1. Put this directory into `package/luci-app-csing-box` (or add it to a custom feed and run `./scripts/feeds install luci-app-csing-box`).
2. `make menuconfig` → `LuCI` → `Applications` → select `luci-app-csing-box`.
3. `make package/luci-app-csing-box/compile V=s` to build the ipk.

## Installation & Usage

```sh
opkg update
opkg install luci-app-csing-box_*.ipk
```

After installation, the menu path is: **Services → Csing-box** (Settings / Node Management / Status); Access Control is a sub-tab of the Settings page.

Basic workflow:

1. Add nodes on the "Node Management" page (or import share links / configure subscriptions);
2. Select a node on the "Settings" page and the service starts automatically (select "Disabled" to stop);
3. Optionally configure the forced direct / proxy lists and client MAC control under the "Access Control" tab on the Settings page;
4. View logs and manually update rule files on the "Status" page.

The service can also be managed from the command line:

```sh
/etc/init.d/csingbox start|stop|restart|reload|enable|disable
```

## Logs & Rule Files

- Daemon log: `/var/run/csingbox/csingbox.log`;
- sing-box log: `/var/run/csingbox/sing-box-c.log`;
- Rule files directory: `/etc/csingbox/resources/` (china_ip4.txt / china_ip6.txt / gfw_list.txt with matching .ver files; direct_list.txt / proxy_list.txt are written from the Access Control tab on the settings page).

## Known Limitations

- TUN is not enabled; no server mode, no custom routing (custom); in Clash Panel Manual Routing mode you must edit `/etc/csingbox/sing-box-panel.json` for routing;
- No dedicated UDP node; the main node automatically serves as the UDP node;
- Client MAC control only applies to LAN clients, not the router's own traffic; MAC addresses can be spoofed, so this is a convenience feature rather than a security boundary;
- DNS hijacking only covers UDP 53; devices with hardcoded DoH/DoT are not covered (same as homeproxy).

## License

GPL-2.0-only. UI and logic reference [immortalwrt/homeproxy](https://github.com/immortalwrt/homeproxy); its copyright notices are retained.
