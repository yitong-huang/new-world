# NewWorld VPN（鸿蒙）

与 iOS `apps/ios/NWVPN` 对齐的 **Stage 模型** 应用：节点列表（`rawfile/servers`）、可选认证、国内直连开关、点击状态文案连接/断开；通过 **`VpnTunnelAbility`** + `vpnExtension` 拉起系统 VPN 扩展。

## 开发环境

- [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)（建议 5.0+，SDK 与工程 `compatibleSdkVersion` 一致）
- 在 **File → Open** 打开本目录 `apps/harmonyos/NWVPN`
- 首次打开执行 **ohpm install** / 同步依赖；若 `hvigor` 版本与 `oh-package.json5` 不一致，按 IDE 提示调整或改 `devDependencies` 版本号

## 节点列表

默认使用 `entry/src/main/resources/rawfile/servers`（与仓库 `configs/servers` 格式相同）。更新节点后替换该文件或从 CI 拷贝再编译。

## VPN 与签名

- 主模块已声明 `extensionAbilities`（`type: vpn`）及 `ohos.permission.INTERNET`、`GET_NETWORK_INFO`
- 真机使用 VPN 扩展需在 **AppGallery Connect / 开发者后台** 为应用申请 **Network Extension / VPN** 相关能力，并完成签名；`VpnTunnelAbility` 内隧道协议需按 `docs/protocol-v1.md` 与 Go `nw-client` 对齐实现（当前为占位类）

## 与 iOS 差异说明

- 持久化键：`NewWorldVPN.node.selectedHost`（与 iOS 一致）
- 隧道内 TLS/TUN 逻辑不在本仓库鸿蒙侧实现，需后续移植或封装原生库
