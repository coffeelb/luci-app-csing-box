This package is a modified HomeProxy: it runs the **sing-box 1.15.x** core in **full TUN mode** and
ships the official **sing-box-dashboard** panel.
Only the common web ports are proxied by default; connections on other ports stay out of the proxy
(enforced by two route rules, see below). The routing of proxied traffic is decided by the manual
rules in the panel config file. **The panel is off by default - turn it on with "Enable panel" on the
Settings page, and fill in your node first: the options that feed the generated config (node, DNS,
routing ports, ...) only take effect after one more click on "Overwrite config" following
"Save & Apply".**

The core is almost completely rewritten. Main differences from upstream:

- **The HomeProxy firewall layer is gone entirely**: `firewall_pre.uc`, `firewall_post.ut`, the fw4
  include they registered and the generated `/var/run/csingbox/fw4_post.nft` rule set are all
  removed - the TUN routing and its nftables rules are sing-box's own business. The upgrade path
  clears the legacy include, the runtime files and the pre-1.2.1 **routing ports** nft fragment;
- **TUN only**: the old `redirect` / `tproxy` inbounds and the client/server dual mode are gone; a
  single TUN inbound is generated;
- **Routing ports** are expressed as two route rules: a `bypass` limited to `inbound: tun-in`
  (kernel-level pass in the pre-match stage) plus a plain `route -> direct-out` (covers what
  pre-match cannot see: the LAN proxy port, established connections, ...). The default list is
  slimmer than upstream (no SSH/mail/git ports, `53` is pinned);
- **UDP session timeout** is written into the config explicitly (`option infra.udp_timeout`,
  default `300` seconds = sing-box's own default);
- Device-level access control keeps MAC matching only, and it lives in the TUN layer
  (`include_mac_address` / `exclude_mac_address`, matched by sing-box's own auto_redirect rules - no
  firewall rules and no nfqueue module needed). Upstream matches `ether saddr` plus IPv4/IPv6 lists
  inside its fw4 include and also offers game mode, global proxy, WAN policy and listen-interface
  options; those are removed here - the upgrade clears the WAN policy lists, and the remaining
  legacy lists are no longer read;
- `generate_client.uc`, `init.d`, `uci-defaults` and the upgrade migration are rewritten around the
  points above (line-level similarity to upstream HomeProxy is about 36% / 23% / 14%), and the LuCI
  pages and options were added or rewritten (panel config page, routing ports, the QUIC switch,
  multi-queue TUN, private-range handling: an `ip_is_private` pre-match `bypass` scoped to `tun-in`
  (kernel-level pass) plus a `direct-out` fallback in the main rules, so for example an internal
  address reached through the LAN proxy port (6330) is no longer handed to the remote proxy; the
  static `route_exclude_address` is not written any more, and CGNAT is left alone the way upstream
  does);
- Files inherited roughly unchanged: `node.js`, `csingbox.uc`, `update_subscriptions.uc` and the
  RPC/ACL layer.

## Requirements

- OpenWrt (firewall4 / nftables)
- **sing-box 1.15.0+** - the TUN inbound omits the `stack` field: since 1.15.0 sing-tun uses its own
  TCP/IP stack, and leaving the option out selects it (the option is deprecated in 1.15.0 and removed
  in 1.17.0; from 1.16.0 the CLI additionally needs `ENABLE_DEPRECATED_TUN_STACK=true` to keep using
  the old values)
- The build needs **both the `with_wireguard` and `with_gvisor` tags**: WireGuard nodes are generated
  as userspace endpoints (`system: false`) on top of the gVisor netstack; without either tag the
  WireGuard node type is not offered in the UI at all (the TUN itself does not need gVisor)
- `kmod-nft-queue` / `kmod-nfnetlink-queue` (declared as package dependencies): the pre-match route
  actions (`bypass` / L3 `route` / `reject` / `sniff`) use them to queue the TCP SYN into userspace.
  The **routing ports** `bypass` rides that path, so every flow on a non-listed port costs one
  userspace round trip before the kernel continues it directly. The exclusions this package
  generates (`route_exclude_address_set`) and the per-device MAC filter are plain static nftables
  rules.

## Panel (sing-box-dashboard)

The panel is served by sing-box's own API service (no extra process). On first start it downloads the
official [sing-box-dashboard](https://github.com/SagerNet/sing-box-dashboard) and refreshes it once a
week (the generated API service sets `update_interval: 7d`).

| Item | Value |
| --- | --- |
| Switch | `option api_panel_enabled` (default `0`; while it is off **no panel content is written to the config** - the api service in `services` is removed from both the `/etc` template and the `/var/run` runtime config - and the panel port / secret / open-panel rows are hidden. The switch takes effect immediately, no "Overwrite config" needed; that button is unaffected by it - it is what writes the node, DNS, routing ports and friends into the config file) |
| API listen | `0.0.0.0:9090` (`option api_panel_port`) |
| Panel URL | `http://<router-ip>:9090/dashboard/` |
| Auth | Bearer token = `api_panel_secret` (default `666b888C`, change it) |

The panel config file lives at `/etc/csingbox/sing-box-panel.json` and can be edited on the LuCI
*Panel Config* page (a top-level menu entry). It is generated once and maintained by hand afterwards
- "Overwrite config" replaces your manual edits with whatever the current settings say. The
generator only ever touches its `services` entry, and only **when the panel switch flips** (removing
the api service while off, regenerating it from the current settings while on); everything else,
including rules you wrote yourself, is left untouched.

The dashboard archive is downloaded by sing-box into `/tmp` (tmpfs), unpacked to
`/etc/csingbox/ui/dashboard.tmp` and then renamed to `/etc/csingbox/ui/dashboard`. Note: once that
directory is **non-empty and has no `.etag`**, it counts as "user-provided files" and automatic
updates stop (the log says `dashboard: serving user-provided files at ..., auto-update disabled`) -
to force a re-download, run `rm -rf /etc/csingbox/ui/dashboard` and it will be fetched again on the
next start.

For DNS, only one split rule is generated by default: `geosite-cn -> china-dns` (mainland domains use
the local resolver, everything else the remote one). 1.2.x used to ship a "mainland DNS fallback" -
when the remote resolver returned a mainland IP, the local answer was used instead; it only fired
when the remote resolver **actually returned a mainland address**, and it cost one extra local query
per hit, so it is no longer generated. If you want it back, add it to `dns.rules` on the
*Panel Config* page (mind the order: after the `geosite-cn` entry):

```json
{ "action": "evaluate", "server": "main-dns" },
{ "match_response": true, "rule_set": "geoip-cn", "action": "route", "server": "china-dns" }
```

## Building (OpenWrt SDK / Buildroot)

1. Put this directory at `package/luci-app-csing-box` (or add it to a custom feed and run
   `./scripts/feeds install luci-app-csing-box`).
2. `make menuconfig` -> `LuCI` -> `Applications` -> select `luci-app-csing-box`.
3. `make package/luci-app-csing-box/compile V=s` produces the ipk / apk (depending on the
   distribution).

## License

`GPL-2.0-only` - see [LICENSE](LICENSE).

This package is a **modified version** of
[immortalwrt/homeproxy](https://github.com/immortalwrt/homeproxy) (© 2022-2025 ImmortalWrt.org).
