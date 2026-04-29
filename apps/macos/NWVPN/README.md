# NWVPN（macOS 主应用 + Packet Tunnel）

在仓库根目录用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 生成 Xcode 工程，即可得到可签名的完整 VPN 壳应用：主界面通过 `NETunnelProviderManager` 启动内嵌扩展，扩展内实现与 `apple/Sources/NWTunnel` 相同的 TLS + 帧协议逻辑。

## 生成工程

```bash
brew install xcodegen
cd apps/macos/NWVPN
xcodegen generate
open NWVPN.xcodeproj
```

在 Xcode 中为 **NWVPN** 与 **NWVPNPacketTunnel** 两个 Target 选择你的 **Team**，并确认 Capability「Network Extension」与 entitlements 中的 `packet-tunnel-provider` 已在 [Apple Developer](https://developer.apple.com) 对应 App ID 上启用。

## 与 Go 服务端联调

1. 按仓库 `scripts/gen-certs.sh` 生成证书，启动 `nw-server`（见 `docs/server-deploy.md`）。
2. 在应用中填写服务器 `主机:端口`；若服务端启用 `-auth-file`，在「认证」中填写用户名与密码。
3. 首次连接时系统会提示授权 VPN；扩展使用开发用 TLS 校验（接受任意证书），生产环境需改为锚定 CA / 证书固定。

## 协议源码同步

扩展目录下的 `Extension/Framing.swift` 与 `Extension/PacketTunnelProvider.swift` 为与 `apple/` 下模块对齐的副本；若你修改了 `apple/Sources/NwVpnWire/Framing.swift` 或 `apple/Sources/NWTunnel/PacketTunnelProvider.swift`，请手动同步对应文件或改为在 Xcode 中直接引用 `apple` 路径下的源文件并去掉跨模块 `import`（需自行调整 target 成员关系）。

## Bundle ID

默认前缀为 `com.newworld`。若需修改，请同时更新 `project.yml` 中两个 target 的 `PRODUCT_BUNDLE_IDENTIFIER`、`App/VPNManager.swift` 中的 `extensionBundleId`，以及 Developer 门户中的 App ID 与描述文件。
