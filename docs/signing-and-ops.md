# 签名、Network Extension 与排障

## Apple（iOS / macOS）

- 需要 **Apple Developer** 账号；在 Identifiers 中为 App ID 开启 **Network Extensions**，勾选 **Packet Tunnel**。
- App 与 Extension 使用同一 Team；Extension 的 Bundle ID 一般为 `主AppID.packet-tunnel`。
- Xcode Target：主 App + **Network Extension**（Packet Tunnel Provider）。将 `apple/Sources/NWTunnel/PacketTunnelProvider.swift` 加入 Extension Target，并在 Xcode 中依赖 SwiftPM 包 `NWTunnel` / `NwVpnWire`（打开 `apple/Package.swift` 作为 local package 引用）。
- Entitlements：主 App 通常包含 `com.apple.developer.networking.networkextension` = `packet-tunnel-provider`；具体键名以 Apple 当前模板为准。
- 企业内测：使用 **Development** 或 **Enterprise** 描述文件签名；TestFlight 需通过 App Store Connect 合规流程（若对外分发）。

### 常见错误

- **Missing entitlements**：Capabilities 未同步到 profile。
- **NEProvider objects may not be instantiated from the main app**：隧道逻辑只能在 Extension 进程内跑。

## Android

- `VpnService` 需在清单中声明 `BIND_VPN_SERVICE`；Android 14+ 注意 **前台服务类型** `connectedDevice` 或文档推荐类型。
- 侧载：在系统设置中允许安装未知来源；调试时使用 `adb install -r app-debug.apk`。

## Windows 客户端

- 将官方 **wintun.dll**（与架构一致）放在 `nw-client.exe` 同目录，或以文档说明路径加载。
- 首次创建虚拟适配器可能需管理员权限；路由示例：

```powershell
route add 0.0.0.0 mask 128.0.0.0 <Wintun接口网关> IF <接口索引>
```

具体索引以 `route print` 为准；更稳妥方式是用 PowerShell `New-NetRoute` 针对 Wintun 接口名。

## 通用排障

- **TLS 握手失败**：检查系统时间、SAN/CN 与连接地址、`-cacert` 或 `-insecure`（仅开发）。
- **能连上无流量**：检查服务端 NAT、客户端是否添加 split-default 或默认路由、以及 `VpnService.protect()` 是否已作用于 TLS 套接字。
