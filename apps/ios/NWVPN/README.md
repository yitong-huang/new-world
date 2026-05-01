# NWVPNiOS（iOS 主应用 + Packet Tunnel）

提供 iOS 端一键连接/断开，扩展内实现与 macOS/Go 客户端一致的 TLS + 帧协议隧道。

## 生成工程

```bash
brew install xcodegen
cd apps/ios/NWVPN
xcodegen generate
open NWVPNiOS.xcodeproj
```

在 Xcode 中为 `NWVPNiOS` 与 `NWVPNiOSPacketTunnel` 选择同一 Team，并确认 App ID 已开通 Network Extension（packet tunnel）。

## 分流行为

- App 内可切换「仅墙外走隧道（国内直连）」。
- 开启后，扩展会读取同目录下打包资源：
  - `Extension/china_ipv4.txt`
  - `Extension/extra_direct_ipv4.txt`
- 这些 CIDR 会作为 `excludedRoutes` 下发给 iOS Packet Tunnel，实现「国内直连，其他走隧道」的近似效果。

## 更新直连库

仓库根目录执行：

```bash
bash scripts/fetch-china-routes.sh
```

然后把更新后的 `configs/china_ipv4.txt`、`configs/extra_direct_ipv4.txt` 复制到本目录 `Extension/` 下再重新编译 App。
