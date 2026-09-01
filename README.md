## About

Lightweight OpenWrt firmware built on HomeProxy, running the **sing-box 1.14.0** core with the official **sing-box-dashboard** panel.
**It is recommended to fill in all nodes before enabling the panel's manual routing mode.**

## Requirements

- OpenWrt with firewall4 / nftables
- **sing-box 1.14.0+** — panel mode uses the native API service introduced in sing-box 1.14.0

## Panel (sing-box-dashboard)

Panel mode (`routing_mode = panel`) enables the sing-box native API service and serves the official [sing-box-dashboard](https://github.com/SagerNet/sing-box-dashboard) on the same listener:

| Item | Value |
| --- | --- |
| API listener | `0.0.0.0:9090` (`api_panel_port`) |
| Dashboard | `http://<router-ip>:9090/dashboard/` |
| Auth | Bearer token = `api_panel_secret` (default `666b888C`) |

The dashboard is downloaded automatically on first start and refreshed daily. The panel config is kept in `/etc/csingbox/sing-box-panel.json` and can be edited on the LuCI *Panel Config* tab; after upgrading from an older version, click **Regenerate panel config file** on the Settings page once.

## Build (OpenWrt SDK / Buildroot)

1. Put this directory into `package/luci-app-csing-box` (or add it to a custom feed and run `./scripts/feeds install luci-app-csing-box`).
2. `make menuconfig` → `LuCI` → `Applications` → select `luci-app-csing-box`.
3. `make package/luci-app-csing-box/compile V=s` to build the ipk.

## License

GPL-2.0-only. UI and logic reference [immortalwrt/homeproxy](https://github.com/immortalwrt/homeproxy); its copyright notices are retained.
