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

若构建报 **Entitlements … modified during the build**：先 `xcodegen generate` 再编；`project.yml` 已排除将 `*.entitlements` 当资源拷进包、且仅用 `CODE_SIGN_ENTITLEMENTS` 引用静态 plist。若仍失败，在 Xcode → Build Phases 检查 **`PacketTunnel.entitlements` 是否误在 “Copy Bundle Resources” 中**，有则移除。

## 分流行为

- App 内可切换「仅墙外走隧道（国内直连）」。
- 开启后，扩展会读取同目录下打包资源（`excludedRoutes` 有上限；若 `setTunnelNetworkSettings` 失败会自动降级为仅排除 VPN 服务器，避免系统报 **internal error**）：
  - `Extension/china_ipv4.txt`
  - `Extension/extra_direct_ipv4.txt`
- 这些 CIDR 会作为 `excludedRoutes` 下发给 iOS Packet Tunnel，实现「国内直连，其他走隧道」的近似效果。

## 更新直连库

仓库根目录执行：

```bash
bash scripts/fetch-china-routes.sh
```

然后把更新后的 `configs/china_ipv4.txt`、`configs/extra_direct_ipv4.txt` 复制到本目录 `Extension/` 下再重新编译 App。

## 真机：把日志落到仓库 `.cursor/`

Packet Tunnel 跑在手机上，**不能直接写** Mac 里的 `.cursor/debug-2902a2.log`。推荐：

1. Mac 安装：`brew install libimobiledevice`
2. iPhone USB 连接并信任电脑，在**仓库根目录**执行：  
   `./scripts/ios_device_logs_to_cursor.sh`  
   会先清空再写可加参数：`./scripts/ios_device_logs_to_cursor.sh fresh`  
3. 保持脚本运行，在手机上复现连接；相关行会追加到 `.cursor/debug-2902a2.log`。

无 `idevicesyslog` 时：打开 Mac「**控制台**」→ 左侧选 iPhone → 搜索 `com.newworld.nwvpn.ios.debug` 或 `2902a2` → 复制内容粘贴保存到上述路径。
