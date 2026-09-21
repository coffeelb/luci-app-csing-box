本项目基于 HomeProxy 修改，以**完整 TUN 模式**运行 **sing-box 1.15.x** 内核，并内置官方**sing-box-dashboard** 面板。
默认只代理常见的 Web 相关端口；其余端口的连接不经过代理（由两条路由规则保证，见下）。被代理流量
的路由由面板配置文件中的手动规则决定。**面板默认关闭，需在设置页打开「启用面板」；启用前请先把节点填写完整，
涉及面板配置生成的选项（节点、DNS、路由端口等）在「保存并应用」后，还需点一次「覆盖配置」才会生效。**

核心几乎完全重写，与上游的主要差异：

- **HomeProxy 的防火墙层整体移除**：`firewall_pre.uc`、`firewall_post.ut`、它们注册的 fw4
  include 以及生成的 `/var/run/csingbox/fw4_post.nft` 规则集全部删除——TUN 路由及其 nftables
  规则由 sing-box 自己负责，升级路径会清掉遗留 include、运行时文件与 1.2.1 之前的**路由端口** nft 片段；
- 仅 TUN：移除旧的 `redirect` / `tproxy` inbound 与客户端/服务端双模式，只生成一个 TUN inbound；
- **路由端口**用两条路由规则表达：限定 `inbound: tun-in` 的 `bypass`（pre-match 内核级放行）+ 普通
  `route → direct-out`（兜住 LAN 代理端口、已建立连接等 pre-match 之外的场景）；默认表较上游精简
  （不含 SSH/邮件/git 端口，`53` 固化）；
- **UDP 会话超时**显式写进配置（`option infra.udp_timeout`，默认 `300` 秒 = sing-box 自身默认值）；
- 设备级访问控制只保留 MAC、且位于 TUN 层（`include_mac_address` / `exclude_mac_address`，由
  sing-box 自身的 auto_redirect 规则匹配——不需要防火墙规则，也不依赖 nfqueue 模块）；上游是在
  fw4 include 里匹配 `ether saddr` 与 IPv4/IPv6 列表，并额外提供游戏模式、全局代理、WAN 策略与
  监听接口等选项，这些在本包中已移除——升级时会清掉 WAN 策略列表，其余遗留列表不再被读取；
- `generate_client.uc`、`init.d`、`uci-defaults` 与升级迁移围绕上述目标重写（与上游 HomeProxy 行级相似度约
  36% / 23% / 14%），并新增或重写了 LuCI 页面与选项（面板配置页、路由端口、QUIC 开关、
  多队列 TUN、私有网段处理：`tun-in` 作用域的 `ip_is_private` pre-match `bypass`（内核级放行）
  + 主规则的 `direct-out` 兜底，例如经 LAN 代理端口（6330）访问内网地址时不会再被送往远端代理；
  不再写静态 `route_exclude_address`，CGNAT 段按上游做法不处理）；
- 基本原样继承的文件：`node.js`、`csingbox.uc`、`update_subscriptions.uc` 与 RPC/ACL 层。

## 环境要求

- OpenWrt（firewall4 / nftables）
- **sing-box 1.15.0+** —— TUN 不写 `stack` 字段：1.15.0 起 sing-tun 使用自研的 TCP/IP 栈，省略该选项即启用它
  （该选项 1.15.0 废弃、1.17.0 移除；1.16.0 起命令行还需 `ENABLE_DEPRECATED_TUN_STACK=true` 才能沿用旧值）
- 构建需带 **`with_wireguard` + `with_gvisor` 两个标签**：WireGuard 节点生成的是用户态 endpoint
  （`system: false`），依赖 gVisor netstack；缺少任一标签时 UI 中都不显示 WireGuard 节点类型
  （TUN 本身不需要 gVisor）
- `kmod-nft-queue` / `kmod-nfnetlink-queue`（已声明为包依赖）：pre-match 的路由动作
  （`bypass` / L3 `route` / `reject` / `sniff`）靠它们把 TCP SYN 入队到用户态；**路由端口**的
  `bypass` 走的就是这条链路，非列表端口每条流因此有一次用户态往返，之后由内核按标记直连。
  本包生成的排除项（`route_exclude_address_set`）和按设备 MAC 过滤都是纯静态 nftables 规则。

## 面板（sing-box-dashboard）

面板由 sing-box 自身的 API 服务提供（不需要额外进程），首次启动时自动下载官方
[sing-box-dashboard](https://github.com/SagerNet/sing-box-dashboard)，之后每周刷新一次
（生成的 API 服务设置 `update_interval: 7d`）。

| 项 | 值 |
| --- | --- |
| 开关 | `option api_panel_enabled`（默认 `0`；关闭时**不在配置文件里生成面板内容**（`services` 里的 api 服务会被移除，`/etc` 的模板与 `/var/run` 的运行配置都不含），并隐藏面板端口/密码/打开面板。开关即时生效，不需要点「覆盖配置」；「覆盖配置」按钮本身不受它影响——它负责把节点、DNS、路由端口等设置写进配置文件） |
| API 监听 | `0.0.0.0:9090`（`option api_panel_port`） |
| 面板地址 | `http://<路由器IP>:9090/dashboard/` |
| 认证 | Bearer token = `api_panel_secret`（默认 `666b888C`，建议改掉） |

面板配置文件位于 `/etc/csingbox/sing-box-panel.json`，可在 LuCI 的 *Panel Config* 页面（顶层菜单项）中
编辑；它只生成一次，之后由手动维护——点「覆盖配置」会按当前设置覆盖手动改动。生成器只会在
**面板开关切换时**改动其中 `services` 那一条（关闭时移除 api 服务、打开时按当前设置重新生成），
其余内容与你手动写的规则都不动。

仪表盘归档由 sing-box 自己下载到 `/tmp`（tmpfs）后解压到 `/etc/csingbox/ui/dashboard.tmp`，再整体改名为
`/etc/csingbox/ui/dashboard`。注意：该目录**非空且不含 `.etag`** 时会被当作「用户提供的文件」而停止自动
更新（日志里是 `dashboard: serving user-provided files at …, auto-update disabled`）——要强制重新下载就
`rm -rf /etc/csingbox/ui/dashboard`，下次启动会重新拉取。

DNS 方面默认只生成一条分流规则：`geosite-cn → china-dns`（大陆域名用本地 DNS 解析，其余用远程 DNS）。
1.2.x 曾默认附带「大陆 DNS 回退」——远端解析结果落在大陆 IP 时改用国内答案；它只在远端解析器**确实返回
大陆地址**时才生效，且每次命中都要多一次国内查询，因此不再默认生成。需要的话在「配置编辑」页把它加回
`dns.rules`（注意顺序：放在 `geosite-cn` 那条之后）：

```json
{ "action": "evaluate", "server": "main-dns" },
{ "match_response": true, "rule_set": "geoip-cn", "action": "route", "server": "china-dns" }
```

## 构建（OpenWrt SDK / Buildroot）

1. 把本目录放入 `package/luci-app-csing-box`（或加入自定义 feed 后执行
   `./scripts/feeds install luci-app-csing-box`）。
2. `make menuconfig` → `LuCI` → `Applications` → 选中 `luci-app-csing-box`。
3. `make package/luci-app-csing-box/compile V=s` 生成 ipk / apk（视发行版而定）。

## 许可证

`GPL-2.0-only` —— 见 [LICENSE](LICENSE)。

本包是 [immortalwrt/homeproxy](https://github.com/immortalwrt/homeproxy)（© 2022-2025 ImmortalWrt.org）
的**修改版**。
