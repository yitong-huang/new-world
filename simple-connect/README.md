# SimpleConnect（macOS 简易按钮客户端）

- 一个窗口：**连接 / 断开**、状态文案、可选「全流量」、可填 `nw-client` 与 `server.crt` 路径。
- 与命令行相同：**必须以 root 创建 TUN**，请在本目录执行：

```bash
cd /Users/yitong/Projects/new_world/simple-connect
# 先编译好 ../go/nw-client
sudo swift run
```

可选环境变量：`NW_CLIENT=/绝对路径/nw-client` 覆盖默认推断。

## 全流量是否走 VPN？

- **勾选「全流量」**时，会向 `nw-client` 传入 `-split-default`（在 macOS 上添加两条大网段路由经 TUN），**大部分** IPv4 流量会走隧道；是否真能上网还取决于 **服务端 NAT/转发** 与 DNS。
- **不勾选**时，只有 **发往隧道网段 / 经系统路由指向 utun** 的流量走 VPN，**不是**整机所有流量。

这与系统「完整 VPN」应用（Network Extension）行为不同；要 100% 与系统设置里一致的体验需做 Apple 的 Packet Tunnel 应用。
