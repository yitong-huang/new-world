# NWVPN（Android）

与 iOS `apps/ios/NWVPN` 同思路的客户端：**节点列表**（`assets/servers`，请与仓库根目录 `configs/servers` 保持内容一致）、可选用户名密码、「国内直连」开关（当前 `VpnService` 隧道层尚未实现分流表，仅作预留与 UI 对齐）、状态行红/蓝可点连断。

协议实现复用仓库根目录 `android/app/src/main/java/newworld/nw/protocol/`（通过 `app/build.gradle.kts` 的 `sourceSets` 引入）。TLS 默认 **`insecure=true`**（与根目录 `android` 示例一致，便于联调）；生产请改为系统信任或证书固定。

## 构建

在 **Android Studio** 中打开本目录 `apps/android/NWVPN`，或使用本机 Gradle 生成 Wrapper 后：

```bash
cd apps/android/NWVPN
gradle wrapper
./gradlew :app:assembleDebug
```

调试 APK 一般在 `app/build/outputs/apk/debug/`。

## 节点列表

编辑 `app/src/main/assets/servers`（或从 `configs/servers` 复制覆盖），每行：`展示名 主机`（不写端口，客户端固定 **8443**）。

## 与 iOS 对齐的偏好键

选中节点主机名保存在 SharedPreferences，键名：**`NewWorldVPN.node.selectedHost`**（与 iOS `AppStorage` 命名一致，各端沙盒仍独立）。
