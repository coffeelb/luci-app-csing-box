## About

Lightweight OpenWrt firmware built on HomeProxy, featuring a Clash dashboard.
**It is recommended to fill in all nodes before enabling the Clash panel's manual routing mode.**

## Build (OpenWrt SDK / Buildroot)

1. Put this directory into `package/luci-app-csing-box` (or add it to a custom feed and run `./scripts/feeds install luci-app-csing-box`).
2. `make menuconfig` → `LuCI` → `Applications` → select `luci-app-csing-box`.
3. `make package/luci-app-csing-box/compile V=s` to build the ipk.

## License

GPL-2.0-only. UI and logic reference [immortalwrt/homeproxy](https://github.com/immortalwrt/homeproxy); its copyright notices are retained.
