# NewWorldVPN（macOS 菜单栏 + `nw-client`）

菜单栏常驻图标，点击后在图标附近弹出主界面（SwiftUI `MenuBarExtra` + `menuBarExtraStyle(.automatic)`）。隧道由捆绑的 Go **`nw-client`** 创建 utun；**不走 Network Extension / System Extension**，行为与 [`simple-connect`](../../../simple-connect/README.md) 一致。

特权进程：**嵌入式 CLI 助手** `com.newworld.NewWorldVPN.helper`，通过 XPC 接收启动参数并以 root 启动 `nw-client`。首次连接前会通过 **`SMAppService`** 注册内嵌的 LaunchDaemon 描述（用户可能需在「系统设置 → 通用 → 登录项与扩展 → 后台」等处允许）。

---

## 生成工程

```bash
brew install xcodegen   # 若未安装
cd apps/macos/NewWorldVPN
xcodegen generate
open NewWorldVPN.xcodeproj
```

无签名仅验证编译：

```bash
cd apps/macos/NewWorldVPN
xcodegen generate
xcodebuild -scheme NewWorldVPN -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

构建脚本会把仓库内的 `go/nw-client`（若已编译）与 `certs/server.crt`（若存在）拷贝进 App 的 `Resources/`，并把 [`LaunchDaemons/com.newworld.NewWorldVPN.helper.plist`](LaunchDaemons/com.newworld.NewWorldVPN.helper.plist) 安装到 **`Contents/Library/LaunchDaemons/`**（`SMAppService.daemon(plistName:)` 要求 plist 必须在此目录，放在 `Resources/` 会导致 `Unable to read plist … LaunchDaemons … error: 22`）。请先在本机编译客户端：

```bash
cd go && go build -o nw-client ./cmd/nw-client
```

并在仓库根执行过一次证书脚本（见根目录 [`README.md`](../../../README.md)）以便存在 `certs/server.crt`。

---

## 与 `NWVPN`（Packet Tunnel）的差异

| 项目 | NewWorldVPN | [`NWVPN`](../NWVPN/README.md) |
|------|-------------|-------------------------------|
| 隧道实现 | `nw-client` 子进程 | Swift Packet Tunnel 扩展 |
| 系统设置 → VPN | 不会出现系统 VPN 项 | 可出现标准 VPN 配置 |
| 分流 | `-split-default` / `-china-routes` 等（与 SimpleConnect 一致） | 扩展内路由逻辑 |

---

## 签名与分发

- 主应用 Bundle ID：`com.newworld.NewWorldVPN`
- 助手 Bundle ID：`com.newworld.NewWorldVPN.helper`
- `project.yml` 中 `DEVELOPMENT_TEAM` 可按你的 Apple Developer 账号修改。
- 特权助手注册与 XPC 通信需在真机用有效 Developer ID / Development 签名调试；仅 `CODE_SIGNING_ALLOWED=NO` 时无法验证 SMAppService 注册与 Mach 服务连通性。

---

## 行为说明（与命令行 `nw-client` 一致）

- **全流量**（`-split-default`）默认在 UI 中**开启**：会把 `0.0.0.0/1` 与 `128.0.0.0/1` 指到 TUN，常见「上网走代理」才成立。若关闭，则只有已指向 utun 的路由才进隧道，多数外网仍走物理网卡，看起来像「已连接却不上墙」。
- **IPv6**：本隧道仅转发 **IPv4**。若系统仍有 IPv6 默认路由（通常走 `en0`），浏览器可能优先访问网站的 **AAAA**，从而看起来「IPv4 路由已到 utun，但仍打不开 Google」。当前 `nw-client` 在 macOS 上于 `-split-default` 时会对**当前 IPv4 默认出口**对应的网络服务执行 `networksetup -setv6off`，断开时恢复；不需要时请使用 **`NW_IPV6_MITIGATION=0`** 环境变量或 **`nw-client -no-ipv6-mitigation`**（需在 TunnelController / Helper 传入等价参数时可后续再接）。
- 服务器地址请填**主机名**（与证书 CN/SAN 一致）；不要改成纯 IP，否则 Go TLS 可能因 `ServerName` 与证书不匹配而握手失败。

## 故障排查

1. **连接时报注册助手失败**：在系统设置中允许 NewWorldVPN 的后台守护进程；确认已对 App 与 Helper 正确签名。
2. **找不到 nw-client**：确认已 `go build` 且重新 Xcode 构建以使拷贝脚本生效。
3. **国内直连**：需填写存在的 `china_ipv4.txt` 路径（可用仓库 [`configs/china_ipv4.txt`](../../../configs/china_ipv4.txt) 或 `scripts/fetch-china-routes.sh` 更新）。
4. **`LaunchDaemon(com.newworld.NewWorldVPN.helper.plist) error: 22` / 找不到 plist**：确认重新完整构建后，在 `NewWorldVPN.app/Contents/Library/LaunchDaemons/` 下存在同名 plist；若曾把 plist 只放进 `Resources/`，需更新到当前工程并重新 Run。
5. **`Unable to obtain a task name port right for pid … (0x5)`**：常见于 Xcode 附加调试特权助手/root 进程时的限制，一般可忽略；或对助手单独运行、不设断点在 Mach 服务上等场景再试。
