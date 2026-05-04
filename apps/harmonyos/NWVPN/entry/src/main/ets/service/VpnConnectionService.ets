import { vpnExtension } from '@kit.NetworkKit';
import type common from '@ohos.app.ability.common';
import Want from '@ohos.app.ability.Want';

export interface VpnConnectParams {
  serverAddress: string;
  username: string;
  password: string;
  chinaDirect: boolean;
}

/**
 * 启动系统 VPN 扩展（与 iOS NETunnelProvider + PacketTunnel 对应）。
 * 隧道内具体协议（TLS/TUN）需在 VpnTunnelAbility 中实现，与 Go nw-client 对齐。
 */
export async function startVpnExtension(context: common.UIAbilityContext, p: VpnConnectParams): Promise<void> {
  const bundleName = context.applicationInfo.name;
  const want: Want = {
    bundleName: bundleName,
    moduleName: 'entry',
    abilityName: 'VpnTunnelAbility',
    parameters: {
      serverAddress: p.serverAddress,
      username: p.username,
      password: p.password,
      chinaDirect: p.chinaDirect
    }
  };
  await vpnExtension.startVpnExtensionAbility(want);
}

export async function stopVpnExtension(context: common.UIAbilityContext): Promise<void> {
  const bundleName = context.applicationInfo.name;
  const want: Want = {
    bundleName: bundleName,
    moduleName: 'entry',
    abilityName: 'VpnTunnelAbility'
  };
  await vpnExtension.stopVpnExtensionAbility(want);
}
