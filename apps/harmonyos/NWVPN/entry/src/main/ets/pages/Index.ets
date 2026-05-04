import { common } from '@kit.AbilityKit';
import { getContext } from '@ohos.ability_common';
import preferences from '@ohos.data.preferences';
import util from '@ohos.util';
import {
  VPNServerEntry,
  parseServersText,
  resolveServerAddress,
  normalizeSelectedHost
} from '../common/VPNServerCatalog';
import { startVpnExtension, stopVpnExtension } from '../service/VpnConnectionService';

@Entry
@Component
struct Index {
  @State serverNodes: VPNServerEntry[] = [];
  @State selectedHost: string = '';
  @State username: string = '';
  @State password: string = '';
  @State chinaDirect: boolean = false;
  @State statusText: string = '加载中…';
  @State lastError: string = '';
  @State tunnelBusy: boolean = false;
  @State nePhase: string = 'invalid';

  private lastTapMs: number = 0;
  private readonly prefStoreName: string = 'nwvpn_prefs';
  private readonly prefKeyHost: string = 'NewWorldVPN.node.selectedHost';

  aboutToAppear(): void {
    void this.bootstrapAsync();
  }

  private async bootstrapAsync(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    try {
      const rm = ctx.resourceManager;
      const buf = await rm.getRawFileContent('servers');
      const decoder = util.TextDecoder.create('utf-8');
      const text = decoder.decodeWithStream(new Uint8Array(buf), { stream: false });
      this.serverNodes = parseServersText(text);
    } catch (_) {
      this.serverNodes = parseServersText('');
    }
    try {
      const pref = await preferences.getPreferences(ctx, this.prefStoreName);
      const saved = await pref.get(this.prefKeyHost, '') as string;
      this.selectedHost = normalizeSelectedHost(saved, this.serverNodes);
    } catch (_) {
      this.selectedHost = this.serverNodes.length > 0 ? this.serverNodes[0].host : '';
    }
    this.statusText = '未连接';
    this.nePhase = 'disconnected';
    this.lastError = '隧道已断开（可先关闭「国内直连」重试）';
  }

  private statusColor(): ResourceColor | string {
    if (this.nePhase === 'connected') {
      return '#0A5FFF';
    }
    if (this.nePhase === 'disconnected' || this.nePhase === 'invalid') {
      return '#E53935';
    }
    return '#99000000';
  }

  private statusTappable(): boolean {
    if (this.tunnelBusy) {
      return false;
    }
    if (this.statusText === '加载中…' || this.statusText === '偏好设置错误') {
      return false;
    }
    if (this.nePhase === 'connected') {
      return true;
    }
    if (this.nePhase === 'disconnected' || this.nePhase === 'invalid') {
      return this.serverNodes.length > 0;
    }
    return false;
  }

  private async persistSelectedHost(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    const pref = await preferences.getPreferences(ctx, this.prefStoreName);
    await pref.put(this.prefKeyHost, this.selectedHost);
    await pref.flush();
  }

  private splitHostPort(addr: string): { host: string; port: string } | undefined {
    const t = addr.trim();
    if (t.length === 0) {
      return undefined;
    }
    const idx = t.indexOf(':');
    if (idx < 0) {
      return { host: t, port: '8443' };
    }
    const h = t.substring(0, idx);
    const p = t.substring(idx + 1);
    if (h.length > 0 && p.length > 0) {
      return { host: h, port: p };
    }
    return undefined;
  }

  private async onStatusClick(): Promise<void> {
    const now = Date.now();
    if (now - this.lastTapMs < 450) {
      return;
    }
    this.lastTapMs = now;
    if (this.nePhase === 'connected') {
      await this.doDisconnect();
    } else if (this.nePhase === 'disconnected' || this.nePhase === 'invalid') {
      await this.doConnect();
    }
  }

  private async doConnect(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.tunnelBusy = true;
    this.lastError = '';
    this.nePhase = 'connecting';
    this.statusText = '连接中…';
    try {
      const rm = ctx.resourceManager;
      const buf = await rm.getRawFileContent('servers');
      const decoder = util.TextDecoder.create('utf-8');
      const text = decoder.decodeWithStream(new Uint8Array(buf), { stream: false });
      this.serverNodes = parseServersText(text);
      this.selectedHost = normalizeSelectedHost(this.selectedHost, this.serverNodes);
      const addr = resolveServerAddress(this.selectedHost, this.serverNodes);
      const hp = this.splitHostPort(addr);
      if (hp === undefined) {
        this.lastError = '服务器地址无效';
        this.statusText = '未连接';
        this.nePhase = 'disconnected';
        this.tunnelBusy = false;
        return;
      }
      await startVpnExtension(ctx, {
        serverAddress: `${hp.host}:${hp.port}`,
        username: this.username.trim(),
        password: this.password,
        chinaDirect: this.chinaDirect
      });
      this.statusText = '已连接';
      this.nePhase = 'connected';
      this.lastError = '';
    } catch (e) {
      this.lastError = String(e);
      this.statusText = '未连接';
      this.nePhase = 'disconnected';
    } finally {
      this.tunnelBusy = false;
    }
  }

  private async doDisconnect(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.tunnelBusy = true;
    this.nePhase = 'disconnecting';
    this.statusText = '断开中…';
    try {
      await stopVpnExtension(ctx);
    } catch (_) {
    }
    this.statusText = '未连接';
    this.nePhase = 'disconnected';
    this.lastError = '隧道已断开（可先关闭「国内直连」重试）';
    this.tunnelBusy = false;
  }

  @Builder
  sectionTitle(title: string) {
    Text(title)
      .fontSize(13)
      .fontColor('#99000000')
      .width('100%')
      .padding({ left: 20, top: 18, bottom: 6 })
  }

  build() {
    Column() {
      Text('NewWorld VPN')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .width('100%')
        .padding({ left: 20, top: 16, bottom: 8 })

      Scroll() {
        Column() {
          this.sectionTitle('服务器')

          if (this.serverNodes.length === 0) {
            Text('未加载节点列表（请确认 rawfile/servers 存在）')
              .fontSize(14)
              .fontColor('#99000000')
              .width('100%')
              .padding({ left: 20, right: 20 })
          } else {
            Column() {
              Select(this.serverNodes.map((n): SelectOption => {
                return { value: n.host, text: n.displayName };
              }))
                .value(this.selectedHost)
                .onSelect((_: number, v: string) => {
                  this.selectedHost = v;
                  void this.persistSelectedHost();
                })
            }
            .width('100%')
            .backgroundColor('#FFFFFFFF')
            .borderRadius(12)
            .padding(12)
            .margin({ left: 16, right: 16 })
          }

          this.sectionTitle('认证（可选）')
          Column() {
            TextInput({ placeholder: '用户名', text: this.username })
              .onChange((v: string) => {
                this.username = v;
              })
              .margin({ bottom: 10 })
            TextInput({ placeholder: '密码', text: this.password })
              .type(InputType.Password)
              .onChange((v: string) => {
                this.password = v;
              })
          }
          .width('100%')
          .backgroundColor('#FFFFFFFF')
          .borderRadius(12)
          .padding(12)
          .margin({ left: 16, right: 16 })

          this.sectionTitle('分流')
          Column() {
            Row() {
              Text('仅墙外走隧道（国内直连）')
                .fontSize(16)
                .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.chinaDirect })
                .onChange((on: boolean) => {
                  this.chinaDirect = on;
                })
            }
            .width('100%')
            Text('开启后会使用扩展内置的 china_ipv4/extra_direct_ipv4 规则。若连接失败，可先关闭此项做排查。')
              .fontSize(12)
              .fontColor('#99000000')
              .margin({ top: 8 })
          }
          .width('100%')
          .backgroundColor('#FFFFFFFF')
          .borderRadius(12)
          .padding(12)
          .margin({ left: 16, right: 16 })

          this.sectionTitle('状态')
          Column() {
            Button() {
              Text(this.statusText)
                .fontSize(22)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.statusColor())
            }
            .type(ButtonType.Normal)
            .backgroundColor(Color.Transparent)
            .enabled(this.statusTappable())
            .onClick(() => {
              void this.onStatusClick();
            })
            .width('100%')

            if (this.lastError.length > 0) {
              Divider()
                .margin({ top: 12 })
                .color('#33000000')
              Text(this.lastError)
                .fontSize(12)
                .fontColor('#E53935')
                .margin({ top: 10 })
                .width('100%')
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .backgroundColor('#FFFFFFFF')
          .borderRadius(12)
          .padding({ left: 16, right: 16, top: 12, bottom: 14 })
          .margin({ left: 16, right: 16 })
        }
        .width('100%')
        .padding({ bottom: 32 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFF5F8FC')
  }
}
