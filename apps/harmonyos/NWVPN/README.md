# NewWorld VPN（鸿蒙）

与 iOS `apps/ios/NWVPN` 对齐的 **Stage 模型** 应用：节点列表（`rawfile/servers`）、可选认证、国内直连开关、点击状态文案连接/断开；通过 **`VpnTunnelAbility`** + `vpnExtension` 拉起系统 VPN 扩展。

## 推荐：命令行构建安装（不必开 DevEco IDE）

依赖 **HarmonyOS Command Line Tools**（或已安装的 DevEco，仅用其 CLI/SDK）：

1. 从 [华为开发者下载中心](https://developer.huawei.com/consumer/cn/download/) 安装 Command Line Tools  
   （本机若已装好，默认路径为 `~/HarmonyOS/command-line-tools`）
2. 配置环境（新开终端后生效；安装脚本可能已写入 `~/.zshrc`）：

```bash
export COMMANDLINE_TOOL_DIR=~/HarmonyOS/command-line-tools
export PATH="$COMMANDLINE_TOOL_DIR/bin:$COMMANDLINE_TOOL_DIR/sdk/default/openharmony/toolchains:$PATH"
export DEVECO_SDK_HOME="$COMMANDLINE_TOOL_DIR/sdk"
```

3. SDK 路径也可写入工程本地文件（已 gitignore）：

```bash
cp apps/harmonyos/NWVPN/local.properties.example apps/harmonyos/NWVPN/local.properties
# 编辑 sdk.dir=...
```

4. **配置调试签名**（安装必需，需华为开发者账号）：

```bash
./scripts/harmonyos_setup_signing.sh              # 生成本地 p12/csr，打印 AGC 步骤
./scripts/harmonyos_setup_signing.sh device-udid  # 手机先点「允许 USB 调试」
# 在 AGC 上传 CSR → 下载并放到 signing/material/：
#   nwvpn-debug.cer  nwvpn-debug.p7b
./scripts/harmonyos_setup_signing.sh apply
```

5. 仓库根执行：

```bash
./scripts/build_and_install_hap.sh
```

常用变体：

```bash
./scripts/build_and_install_hap.sh --no-install          # 只编 HAP
TARGET_SN=设备序列号 ./scripts/build_and_install_hap.sh  # 多设备时指定
./scripts/build_and_install_hap.sh --no-sync-servers     # 不覆盖 rawfile/servers
```

脚本会：探测工具链 → 检查签名材料 → 同步 `configs/servers` → `ohpm install` → `assembleHap` → `hap-sign-tool` 签名 → `hdc install -r` → 拉起应用。

## 可选：用 DevEco Studio

- [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)（建议 5.0+，SDK 与工程 `compatibleSdkVersion` 一致）
- **File → Open** 打开本目录 `apps/harmonyos/NWVPN`
- 首次打开执行 **ohpm install** / 同步依赖；若 `hvigor` 版本与 `oh-package.json5` 不一致，按 IDE 提示调整

## 节点列表

默认使用 `entry/src/main/resources/rawfile/servers`（与仓库 `configs/servers` 格式相同）。  
`build_and_install_hap.sh` 默认会在构建前从仓库根 `configs/servers` 覆盖拷贝；也可手动替换该文件后再编译。

## VPN 与签名

- 主模块已声明 `extensionAbilities`（`type: vpn`）及 `ohos.permission.INTERNET`、`GET_NETWORK_INFO`
- 真机使用 VPN 扩展需在 **AppGallery Connect / 开发者后台** 为应用申请 **Network Extension / VPN** 相关能力，并完成签名；`VpnTunnelAbility` 内隧道协议需按 `docs/protocol-v1.md` 与 Go `nw-client` 对齐实现（当前为占位类）

## 与 iOS 差异说明

- 持久化键：`NewWorldVPN.node.selectedHost`（与 iOS 一致）
- 隧道内 TLS/TUN 逻辑不在本仓库鸿蒙侧实现，需后续移植或封装原生库
