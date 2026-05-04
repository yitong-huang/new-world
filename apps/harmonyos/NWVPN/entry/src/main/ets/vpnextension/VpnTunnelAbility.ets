import { VpnExtensionAbility } from '@kit.NetworkKit';
import Want from '@ohos.app.ability.Want';

/**
 * VPN 扩展进程入口。当前为占位：建立 TUN、跑 nw 协议栈需按 docs/protocol-v1.md 实现，
 * 可参考 iOS `PacketTunnelProvider.swift`。
 */
export default class VpnTunnelAbility extends VpnExtensionAbility {
  onCreate(want: Want): void {
    // want.parameters: serverAddress, username, password, chinaDirect
  }

  onDestroy(): void {
  }
}
