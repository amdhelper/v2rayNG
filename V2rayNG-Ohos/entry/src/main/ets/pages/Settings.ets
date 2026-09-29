/**
 * 设置页 — 对应安卓版 ui/settings/MainSettingsFragment.kt +
 * AppConfig.kt 里的默认项。
 *
 * 每一次改动都走 settings.set(mut) 然后 await settings.save()，
 * 保证进程被杀后不丢。深色主题为硬性要求。
 */
import router from '@ohos.router';
import { settings, AppSettingsData } from '../model/AppSettings';
import { Log } from '../util/Log';

const C_BG: string = '#FF101418';
const C_CARD: string = '#FF1B2026';
const C_FIELD: string = '#FF161B21';
const C_TEXT: string = '#FFE8EAED';
const C_TEXT2: string = '#FF9AA0A6';
const C_ACCENT: string = '#FF8AB4F8';
const C_WARN: string = '#FFF2B45C';

/** 路由规则预设，与 AppSettingsData.routingPreset 的取值域一致。 */
const ROUTING_PRESETS: string[] = ['all', 'bypass-mainland', 'bypass-lan', 'global', 'custom'];
const ROUTING_PRESET_LABELS: string[] = [
  '全部流量走代理',
  '大陆地址直连（绕过大陆）',
  '仅局域网直连',
  '全局代理',
  '自定义规则'
];

/** 与 AppSettingsData.logLevel 的取值域一致。 */
const LOG_LEVELS: string[] = ['verbose', 'info', 'warning', 'error', 'none'];
const LOG_LEVEL_LABELS: string[] = ['详细 (verbose)', '信息 (info)', '警告 (warning)', '错误 (error)', '关闭 (none)'];

const DOMAIN_STRATEGIES: string[] = ['AsIs', 'IPIfNonMatch', 'IPOnDemand'];
const DOMAIN_STRATEGY_LABELS: string[] = ['原样 (AsIs)', '非匹配时用 IP', '按需用 IP'];

function toSelectOptions(values: string[]): SelectOption[] {
  const out: SelectOption[] = [];
  for (const v of values) {
    const o: SelectOption = { value: v };
    out.push(o);
  }
  return out;
}

const ROUTING_SELECT: SelectOption[] = toSelectOptions(ROUTING_PRESETS);
const LOG_LEVEL_SELECT: SelectOption[] = toSelectOptions(LOG_LEVELS);
const STRATEGY_SELECT: SelectOption[] = toSelectOptions(DOMAIN_STRATEGIES);

/** 把 0..n-1 的下标映射到标签数组，越界时返回原值。 */
function labelOf(labels: string[], index: number, fallback: string): string {
  return index >= 0 && index < labels.length ? labels[index] : fallback;
}

function indexOf(values: string[], needle: string): number {
  for (let i = 0; i < values.length; i++) {
    if (values[i] === needle) {
      return i;
    }
  }
  return 0;
}

function toInt(text: string, fallback: number): number {
  const n: number = Number(text);
  return Number.isFinite(n) ? n : fallback;
}

@Entry
@Component
struct Settings {
  @State vpnMode: boolean = true;
  @State localProxyEnabled: boolean = true;
  @State socksPort: string = '10808';
  @State httpPort: string = '10809';
  @State vpnMtu: number = 1500;
  @State ipv6Enabled: boolean = false;
  @State bypassLan: boolean = true;
  @State appendHttpProxy: boolean = false;
  @State vpnDnsServers: string = '';
  @State remoteDns: string = '';
  @State localDnsEnabled: boolean = true;
  @State fakeDnsEnabled: boolean = false;
  @State sniffingEnabled: boolean = true;
  @State routingEnabled: boolean = true;
  @State routingPreset: string = 'bypass-mainland';
  @State domainStrategy: string = 'IPIfNonMatch';
  @State perAppProxyEnabled: boolean = false;
  @State perAppProxyBypass: boolean = false;
  @State delayTestUrl: string = '';
  @State delayTestTimeoutMs: number = 8000;
  @State logLevel: string = 'warning';

  aboutToAppear(): void {
    const d: AppSettingsData = settings.get();
    this.vpnMode = d.vpnMode;
    this.localProxyEnabled = d.localProxyEnabled;
    this.socksPort = d.socksPort;
    this.httpPort = d.httpPort;
    this.vpnMtu = d.vpnMtu;
    this.ipv6Enabled = d.ipv6Enabled;
    this.bypassLan = d.bypassLan;
    this.appendHttpProxy = d.appendHttpProxy;
    this.vpnDnsServers = d.vpnDnsServers;
    this.remoteDns = d.remoteDns;
    this.localDnsEnabled = d.localDnsEnabled;
    this.fakeDnsEnabled = d.fakeDnsEnabled;
    this.sniffingEnabled = d.sniffingEnabled;
    this.routingEnabled = d.routingEnabled;
    this.routingPreset = d.routingPreset;
    this.domainStrategy = d.domainStrategy;
    this.perAppProxyEnabled = d.perAppProxyEnabled;
    this.perAppProxyBypass = d.perAppProxyBypass;
    this.delayTestUrl = d.delayTestUrl;
    this.delayTestTimeoutMs = d.delayTestTimeoutMs;
    this.logLevel = d.logLevel;
  }

  /** 统一的落盘入口：先改内存，再 flush。 */
  private async commit(mut: (d: AppSettingsData) => void): Promise<void> {
    settings.set(mut);
    await settings.save();
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1500 });
    } catch (e) {
      Log.w('Settings.toast failed: ' + JSON.stringify(e));
    }
  }

  /** 数字输入统一走这里：解析失败时保留原值并提示，不写坏数据。 */
  private async commitInt(text: string, fallback: number, apply: (n: number) => void): Promise<void> {
    const n: number = toInt(text, fallback);
    if (!Number.isFinite(n)) {
      this.toast('请输入数字');
      return;
    }
    await this.commit(() => {
      apply(n);
    });
  }

  private onOpenAbout(): void {
    router.pushUrl({ url: 'pages/About' }).catch((e: Object) => {
      Log.e('Settings.onOpenAbout pushUrl failed: ' + JSON.stringify(e));
    });
  }

  private onOpenLogcat(): void {
    router.pushUrl({ url: 'pages/Logcat' }).catch((e: Object) => {
      Log.e('Settings.onOpenLogcat pushUrl failed: ' + JSON.stringify(e));
    });
  }

  // -------------------------------------------------------------------------
  // UI 片段
  // -------------------------------------------------------------------------

  @Builder
  Card(title: string, note: string) {
    Column() {
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(C_TEXT)
        .width('100%')
      if (note.length > 0) {
        Text(note)
          .fontSize(12)
          .fontColor(C_TEXT2)
          .width('100%')
          .margin({ top: 3 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 14, bottom: 6 })
  }

  @Builder
  SwitchRow(label: string, hint: string, value: boolean, onChanged: (v: boolean) => void) {
    Row() {
      Column() {
        Text(label).fontSize(15).fontColor(C_TEXT)
        if (hint.length > 0) {
          Text(hint)
            .fontSize(12)
            .fontColor(C_TEXT2)
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: value })
        .selectedColor(C_ACCENT)
        .onChange((v: boolean) => {
          onChanged(v);
        })
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
  }

  @Builder
  TextRow(label: string, value: string, placeholder: string, onChanged: (v: string) => void) {
    Column() {
      Text(label)
        .fontSize(12)
        .fontColor(C_TEXT2)
        .width('100%')
        .margin({ bottom: 4 })
      TextInput({ text: value, placeholder: placeholder })
        .fontSize(15)
        .fontColor(C_TEXT)
        .placeholderColor(C_TEXT2)
        .backgroundColor(C_FIELD)
        .width('100%')
        .onChange((v: string) => {
          onChanged(v);
        })
    }
    .width('100%')
    .margin({ bottom: 12 })
  }

  @Builder
  IntRow(label: string, value: number, hint: string, fallback: number,
         apply: (n: number) => void, onApplied: (n: number) => void) {
    Column() {
      Text(label)
        .fontSize(12)
        .fontColor(C_TEXT2)
        .width('100%')
        .margin({ bottom: 4 })
      TextInput({ text: `${value}`, placeholder: hint })
        .type(InputType.Number)
        .fontSize(15)
        .fontColor(C_TEXT)
        .placeholderColor(C_TEXT2)
        .backgroundColor(C_FIELD)
        .width('100%')
        .onChange((v: string) => {
          this.commitInt(v, fallback, apply);
          onApplied(toInt(v, fallback));
        })
    }
    .width('100%')
    .margin({ bottom: 12 })
  }

  @Builder
  PickerRow(label: string, options: SelectOption[], value: string,
            values: string[], labels: string[], onChanged: (v: string) => void) {
    Column() {
      Text(label)
        .fontSize(12)
        .fontColor(C_TEXT2)
        .width('100%')
        .margin({ bottom: 4 })
      Text(labelOf(labels, indexOf(values, value), value))
        .fontSize(13)
        .fontColor(C_ACCENT)
        .width('100%')
        .margin({ bottom: 4 })
      Select(options)
        .value(value)
        .font({ size: 15 })
        .fontColor(C_TEXT)
        .selectedOptionBgColor(C_CARD)
        .menuBackgroundColor(C_CARD)
        .optionFont({ size: 15 })
        .backgroundColor(C_FIELD)
        .width('100%')
        .onSelect((index: number, v: string) => {
          onChanged(v);
        })
    }
    .width('100%')
    .margin({ bottom: 12 })
  }

  // -------------------------------------------------------------------------
  // 页面
  // -------------------------------------------------------------------------

  build() {
    Scroll() {
      Column() {
        Text('设置')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(C_TEXT)
          .width('100%')
          .margin({ bottom: 4 })

        // --- 基础 ---
        this.Card('基础', 'VPN 模式由系统 VPN 扩展承载；本地代理提供 SOCKS/HTTP 端口')
        this.SwitchRow('VPN 模式', '关闭后仅保留本地代理监听', this.vpnMode, (v: boolean) => {
          this.vpnMode = v;
          this.commit((d: AppSettingsData) => {
            d.vpnMode = v;
          });
        })
        this.SwitchRow('本地代理', '在回环地址上开 SOCKS/HTTP 端口', this.localProxyEnabled, (v: boolean) => {
          this.localProxyEnabled = v;
          this.commit((d: AppSettingsData) => {
            d.localProxyEnabled = v;
          });
        })
        this.TextRow('SOCKS 端口', this.socksPort, '10808', (v: string) => {
          this.socksPort = v;
          this.commit((d: AppSettingsData) => {
            d.socksPort = v;
          });
        })
        this.TextRow('HTTP 端口', this.httpPort, '10809', (v: string) => {
          this.httpPort = v;
          this.commit((d: AppSettingsData) => {
            d.httpPort = v;
          });
        })
        this.IntRow('MTU', this.vpnMtu, '1500', 1500, (n: number) => {
          settings.set((d: AppSettingsData) => {
            d.vpnMtu = n;
          });
        }, (n: number) => {
          this.vpnMtu = n;
        })
        this.SwitchRow('允许 IPv6', '', this.ipv6Enabled, (v: boolean) => {
          this.ipv6Enabled = v;
          this.commit((d: AppSettingsData) => {
            d.ipv6Enabled = v;
          });
        })
        this.SwitchRow('绕过局域网', '内网地址不经过隧道', this.bypassLan, (v: boolean) => {
          this.bypassLan = v;
          this.commit((d: AppSettingsData) => {
            d.bypassLan = v;
          });
        })
        this.SwitchRow('追加 HTTP 代理', '让受支持的应用额外走 HTTP 代理', this.appendHttpProxy, (v: boolean) => {
          this.appendHttpProxy = v;
          this.commit((d: AppSettingsData) => {
            d.appendHttpProxy = v;
          });
        })

        // --- DNS ---
        this.Card('DNS', '隧道内 DNS 与远端 DNS 分开配置')
        this.TextRow('DNS 服务器', this.vpnDnsServers, '逗号分隔，例如 1.1.1.1,8.8.8.8', (v: string) => {
          this.vpnDnsServers = v;
          this.commit((d: AppSettingsData) => {
            d.vpnDnsServers = v;
          });
        })
        this.TextRow('远端 DNS', this.remoteDns, '用于路由解析与 fakedns', (v: string) => {
          this.remoteDns = v;
          this.commit((d: AppSettingsData) => {
            d.remoteDns = v;
          });
        })
        this.SwitchRow('本地 DNS', '由本地服务应答 DNS 查询', this.localDnsEnabled, (v: boolean) => {
          this.localDnsEnabled = v;
          this.commit((d: AppSettingsData) => {
            d.localDnsEnabled = v;
          });
        })
        this.SwitchRow('Fake DNS', '用假 IP 加速域名分流', this.fakeDnsEnabled, (v: boolean) => {
          this.fakeDnsEnabled = v;
          this.commit((d: AppSettingsData) => {
            d.fakeDnsEnabled = v;
          });
        })

        // --- 路由 ---
        this.Card('路由与嗅探', '')
        this.SwitchRow('启用路由规则', '', this.routingEnabled, (v: boolean) => {
          this.routingEnabled = v;
          this.commit((d: AppSettingsData) => {
            d.routingEnabled = v;
          });
        })
        this.PickerRow('路由预设', ROUTING_SELECT, this.routingPreset, ROUTING_PRESETS,
          ROUTING_PRESET_LABELS, (v: string) => {
          this.routingPreset = v;
          this.commit((d: AppSettingsData) => {
            d.routingPreset = v;
          });
        })
        this.PickerRow('域名策略', STRATEGY_SELECT, this.domainStrategy, DOMAIN_STRATEGIES,
          DOMAIN_STRATEGY_LABELS, (v: string) => {
          this.domainStrategy = v;
          this.commit((d: AppSettingsData) => {
            d.domainStrategy = v;
          });
        })
        this.SwitchRow('流量嗅探', '从 SNI/HTTP 头还原域名以套用规则', this.sniffingEnabled, (v: boolean) => {
          this.sniffingEnabled = v;
          this.commit((d: AppSettingsData) => {
            d.sniffingEnabled = v;
          });
        })

        // --- 分应用代理 ---
        this.Card('分应用代理', '')
        this.SwitchRow('启用分应用代理', '按应用名单决定是否走隧道', this.perAppProxyEnabled, (v: boolean) => {
          this.perAppProxyEnabled = v;
          this.commit((d: AppSettingsData) => {
            d.perAppProxyEnabled = v;
          });
        })
        this.SwitchRow('名单内应用排除', '名单内的应用直连', this.perAppProxyBypass, (v: boolean) => {
          this.perAppProxyBypass = v;
          this.commit((d: AppSettingsData) => {
            d.perAppProxyBypass = v;
          });
        })
        Text('提示：应用选择器尚未实现，开关会保存但暂不生效。')
          .fontSize(12)
          .fontColor(C_WARN)
          .width('100%')
          .margin({ top: 4, bottom: 8 })

        // --- 延迟测试与日志 ---
        this.Card('延迟测试与日志', '')
        this.TextRow('延迟测试地址', this.delayTestUrl, 'https://www.gstatic.com/generate_204', (v: string) => {
          this.delayTestUrl = v;
          this.commit((d: AppSettingsData) => {
            d.delayTestUrl = v;
          });
        })
        this.IntRow('延迟测试超时 (毫秒)', this.delayTestTimeoutMs, '8000', 8000, (n: number) => {
          settings.set((d: AppSettingsData) => {
            d.delayTestTimeoutMs = n;
          });
        }, (n: number) => {
          this.delayTestTimeoutMs = n;
        })
        this.PickerRow('日志级别', LOG_LEVEL_SELECT, this.logLevel, LOG_LEVELS,
          LOG_LEVEL_LABELS, (v: string) => {
          this.logLevel = v;
          this.commit((d: AppSettingsData) => {
            d.logLevel = v;
          });
        })

        // --- 入口 ---
        this.Card('关于与日志', '')
        Button('查看日志 (Logcat)')
          .width('100%')
          .fontColor(C_TEXT)
          .backgroundColor(C_CARD)
          .margin({ bottom: 8 })
          .onClick(() => {
            this.onOpenLogcat();
          })
        Button('关于本应用')
          .width('100%')
          .fontColor(C_TEXT)
          .backgroundColor(C_CARD)
          .margin({ bottom: 32 })
          .onClick(() => {
            this.onOpenAbout();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
    .scrollBar(BarState.Off)
  }
}
