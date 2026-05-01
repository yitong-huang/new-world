# SimpleConnect（macOS 简易按钮客户端）

- 一个窗口：**连接 / 断开**、状态文案、可选「全流量」、可选「国内 IP 直连（仅墙外走隧道）」、可填 `nw-client`、`server.crt`、china 路由表路径、可选补丁表路径。
- 与命令行相同：**必须以 root 创建 TUN**，请在本目录执行：

```bash
cd /Users/yitong/Projects/new_world/simple-connect
# 先编译好 ../go/nw-client
sudo swift run
```

可选环境变量：`NW_CLIENT=/绝对路径/nw-client` 覆盖默认推断。

## 全流量是否走 VPN？

- **勾选「全流量」**时，会向 `nw-client` 传入 `-split-default`（在 macOS 上添加两条大网段路由经 TUN），**大部分** IPv4 流量会走隧道；是否真能上网还取决于 **服务端 NAT/转发** 与 DNS。
- **勾选「国内 IP 直连」**时，会同时传入 `-split-default` 与 `-china-routes <文件>`：对路由表中的中国大陆 IPv4 段走**物理网卡默认网关**，其余 IPv4 仍走隧道（**按 IP 段近似**「墙内 / 墙外」，不是按域名）。请使用完整 CIDR 列表（仓库 `configs/china_ipv4.txt` 为示例，可用 `scripts/fetch-china-routes.sh` 拉取更新）。
- 若填写「补丁路由表」（`configs/extra_direct_ipv4.txt`），会额外传入 `-extra-direct-routes <文件>`，与 `china-routes` 进行合并去重，便于单独维护少量覆盖网段而不改主表。
- **不勾选**时，只有 **发往隧道网段 / 经系统路由指向 utun** 的流量走 VPN，**不是**整机所有流量。

这与系统「完整 VPN」应用（Network Extension）行为不同；要 100% 与系统设置里一致的体验需做 Apple 的 Packet Tunnel 应用。
