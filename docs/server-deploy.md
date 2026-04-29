# Linux 服务端部署

## 前置条件

- Linux 内核 TUN/TAP（一般已启用）
- `ip` 来自 iproute2
- 以 **root** 或 `CAP_NET_ADMIN` 运行 `nw-server`（需创建 TUN 并配置地址）

## 证书

开发环境：

```bash
bash scripts/gen-certs.sh
```

生产环境请使用企业 CA 或 ACME 签发的服务端证书；若启用客户端证书认证：

```bash
nw-server -client-ca=/path/to/ca.pem
```

## 用户名与密码（应用层）

可选：使用 JSON 用户表校验客户端（与 TLS 证书无关）。示例见仓库 [`configs/auth.server.example.json`](../configs/auth.server.example.json)。

```bash
sudo ./nw-server -listen 0.0.0.0:8443 -cert ../certs/server.crt -key ../certs/server.key \
  -auth-file /etc/nw/auth.json
```

客户端使用 [`configs/auth.client.example.json`](../configs/auth.client.example.json) 形态的文件：

```bash
sudo ./nw-client -server VPN_IP:8443 -cacert ../certs/server.crt \
  -auth-file ../configs/auth.client.json
```

未指定 `-auth-file` 时，客户端不发送凭据，**仅当服务端也未启用 `-auth-file` 时**才能连通。

## 启动

```bash
cd go
go build -o nw-server ./cmd/nw-server
sudo ./nw-server -listen 0.0.0.0:8443 -cert ../certs/server.crt -key ../certs/server.key
```

## NAT 与转发

客户端使用 **`-split-default`** 时，IPv4 流量会进隧道；服务端必须把虚拟网段 **SNAT/MASQUERADE** 到公网口，否则无法上网。若同时使用 **`-china-routes <文件>`**（与 `-split-default` 配合），客户端会为文件中的 IPv4 CIDR 添加经物理网关的**更具体路由**，使这部分流量**不进隧道**（常见：国内直连、境外走 VPN）；列表需自行维护或从社区 china_ip / chnroutes 源更新。

**一键命令（在服务器上以 root 执行；自动取默认路由出网网卡）**：

```bash
# 1) 持久打开 IPv4 转发
sysctl -w net.ipv4.ip_forward=1
mkdir -p /etc/sysctl.d
printf '%s\n' 'net.ipv4.ip_forward=1' >/etc/sysctl.d/99-nwvpn-forward.conf
sysctl -p /etc/sysctl.d/99-nwvpn-forward.conf 2>/dev/null || true

# 2) 出网网卡（阿里云常见 ens5、eth0 等）
PUB_IF=$(ip -4 route show default | head -1 | sed -n 's/.* dev \([^ ]*\) .*/\1/p')
echo "out_if=$PUB_IF"

# 3a) 优先 nftables（与 deploy 脚本一致）
nft delete table ip nwvpn 2>/dev/null || true
nft add table ip nwvpn
nft add chain ip nwvpn postrouting '{ type nat hook postrouting priority 100 ; policy accept; }'
nft add rule ip nwvpn postrouting oifname "$PUB_IF" ip saddr 10.77.0.0/24 masquerade

# 3b) 若无 nft，可用 iptables（二选一即可）
# iptables -t nat -C POSTROUTING -s 10.77.0.0/24 -o "$PUB_IF" -j MASQUERADE 2>/dev/null || \
#   iptables -t nat -A POSTROUTING -s 10.77.0.0/24 -o "$PUB_IF" -j MASQUERADE
```

虚拟网段 **`10.77.0.0/24`** 须与 `nw-server` 的 **`-tun-cidr`** 一致（默认即此）。**`scripts/deploy-nw-server.sh`** 默认会在远程执行上述逻辑（可用 **`NW_DEPLOY_NAT=0`** 关闭）。

手动指定公网口时，将上文 `nft ... oifname "$PUB_IF"` 中的 **`$PUB_IF`** 换成你的接口名（如 `eth0`）即可。

## systemd 示例

```ini
[Unit]
Description=NewWorld NW VPN Server
After=network-online.target

[Service]
ExecStart=/usr/local/bin/nw-server -listen 0.0.0.0:8443 -cert /etc/nw/server.crt -key /etc/nw/server.key
Restart=on-failure
AmbientCapabilities=CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_ADMIN
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
```

按实际路径调整 `ExecStart`。

## 排障：出口 IP 已是服务器，但部分网页打不开

常见原因与处理顺序：

1. **MTU / 分片（HTTPS 随机站点失败）**  
   隧道上再套 TLS，路径 MTU 变小；若客户端 TUN 仍用 1500，易出现 **部分站点 TLS 握手慢、大页面白屏**。  
   本仓库 `nw-client` 会在 Linux/macOS 上把 TUN **MTU 设为 1360**，并在 `ClientHello` 中携带相同值；请 **重新编译客户端** 后再试。若仍有个别站不通，可暂时把 `internal/tuntap/mtu.go` 里的 **`ClientIPv4MTU` 改为 `1280`** 再编一版对比。

2. **DNS 与「仅隧道内可访问」的站点**  
   若站点按 **解析结果所在地区** 或 **解析器出口** 分流，而本机仍用 **路由器 DNS（192.168.x.1）**，可能出现 **IP 已走隧道、但解析到的 CDN 节点不对**。可尝试：系统网络里把 DNS 改为 **`8.8.8.8` / `1.1.1.1`**（在 `-split-default` 下一般会随 IPv4 大网段走隧道），或关闭浏览器 **「基于 HTTPS 的 DNS」** 做对比。

3. **服务端 MSS（进阶）**  
   若怀疑仍有大包问题，可在 Linux 上对 **来自 `10.77.0.0/24` 的转发 SYN** 做 **TCPMSS 钳制**（需自行维护 iptables/nft 规则，避免重复 `-I` 多条）。云厂商安全组一般不影响 MSS。

4. **吞吐上限：TCP-in-TCP**  
   浏览器每个 TCP 连接都被封装在 **一条** 客户端到服务器的 **TLS TCP** 里，属于 **TCP over TCP**，拥塞控制会相互干扰，**很难跑满标称带宽**（体感「特别慢」常见）。仓库已对隧道套接字开启 **`TCP_NODELAY` + 较大 SO_RCVBUF/SO_SNDBUF** 以缓解；要进一步只能换 **UDP 承载**（如 WireGuard 思路）或内核级 VPN。  
   服务器可开启 **BBR**（需内核支持）：`sysctl -w net.ipv4.tcp_congestion_control=bbr`（持久化写入 `/etc/sysctl.d/`）。

## 多客户端模型

服务端使用 **单个 TUN**，按目的 IPv4 将下行包路由到对应 TLS 会话。请保证为客户端分配的地址在同一网段且不冲突（默认 `10.77.0.2` 起递增）。
