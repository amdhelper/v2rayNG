/**
 * 设置页 — 对应安卓版 ui/settings/MainSettingsFragment.kt +
 * AppConfig.kt 里的默认项。
 *
 * 每一次改动都走 settings.set(mut) 然后 await settings.save()，
 * 保证进程被杀后不丢。深色主题为硬性要求。
 */
import router from '@ohos.router';
import { settings, AppSettingsData } from '../model/AppSettings';
import { AppResolver, BundleCheck, BundleState } from '../core/AppResolver';
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
/**
 * 标签必须如实反映实现了什么：只有 bypass-mainland / bypass-lan 会生成内置直连
 * 规则（XrayConfigBuilder.routingRules()），'all' 与 'global' 都是"不加规则、
 * 全部走第一个出站"，'custom' 没有规则编辑界面、行为与 global 相同。
 * 别为了让下拉框好看而写成"自定义规则"，用户会以为规则真的生效了。
 */
const ROUTING_PRESET_LABELS: string[] = [
  '全部流量走代理',
  '大陆地址直连（绕过大陆）',
  '仅局域网直连',
  '全局代理（与第一项相同）',
  '自定义规则（未实现，等同全局）'
];

/** 与 AppSettingsData.logLevel 的取值域一致。 */
const LOG_LEVELS: string[] = ['verbose', 'info', 'warning', 'error', 'none'];
const LOG_LEVEL_LABELS: string[] = ['详细 (verbose)', '信息 (info)', '警告 (warning)', '错误 (error)', '关闭 (none)'];

/** 与 AppConfig.PREF_MUX_XUDP_QUIC 的取值域一致。 */
const MUX_XUDP_QUIC: string[] = ['reject', 'allow', 'skip'];
const MUX_XUDP_QUIC_LABELS: string[] = ['拒绝 (reject)', '允许 (allow)', '跳过 (skip)'];

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
const MUX_QUIC_SELECT: SelectOption[] = toSelectOptions(MUX_XUDP_QUIC);

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
  @State socksUsername: string = '';
  @State socksPassword: string = '';
  @State socksEnableUdp: boolean = true;
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
  @State perAppProxySet: string = '';
  /** 名单里每个包名的核验结果，供下面逐行标注。 */
  @State bundleChecks: BundleCheck[] = [];
  @State muxEnabled: boolean = false;
  @State muxConcurrency: string = '8';
  @State muxXudpConcurrency: string = '8';
  @State muxXudpProxyUDP443: string = 'reject';
  @State delayTestUrl: string = '';
  @State delayTestTimeoutMs: number = 8000;
  @State logLevel: string = 'warning';

  aboutToAppear(): void {
    const d: AppSettingsData = settings.get();
    this.vpnMode = d.vpnMode;
    this.localProxyEnabled = d.localProxyEnabled;
    this.socksPort = d.socksPort;
    this.socksUsername = d.socksUsername;
    this.socksPassword = d.socksPassword;
    this.socksEnableUdp = d.socksEnableUdp;
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
    this.perAppProxySet = d.perAppProxySet;
    this.muxEnabled = d.muxEnabled;
    this.muxConcurrency = d.muxConcurrency;
    this.muxXudpConcurrency = d.muxXudpConcurrency;
    this.muxXudpProxyUDP443 = d.muxXudpProxyUDP443;
    this.refreshBundleChecks();
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

  /**
   * 核验名单里的包名。鸿蒙不能枚举应用，只能按名查（见 core/AppResolver.ets），
   * 所以这里的结果是用户唯一的反馈：名单写了但核验失败，隧道会静默忽略。
   */
  private refreshBundleChecks(): void {
    AppResolver.checkAll(this.perAppProxySet).then((checks: BundleCheck[]) => {
      this.bundleChecks = checks;
    }).catch((e: Object) => {
      Log.w('Settings.refreshBundleChecks failed: ' + JSON.stringify(e));
    });
  }

  private bundleSymbol(state: BundleState): string {
    if (state === BundleState.FOUND) {
      return '\u2713';
    }
    if (state === BundleState.NOT_FOUND) {
      return '\u2717';
    }
    if (state === BundleState.NO_PERMISSION) {
      return '!';
    }
    return '\u00b7';
  }

  private bundleColor(state: BundleState): string {
    if (state === BundleState.FOUND) {
      return C_ACCENT;
    }
    if (state === BundleState.NOT_FOUND) {
      return C_WARN;
    }
    if (state === BundleState.NO_PERMISSION) {
      return C_WARN;
    }
    return C_TEXT2;
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
  BundleRow(check: BundleCheck) {
    Row() {
      Text(this.bundleSymbol(check.state))
        .fontSize(14)
        .fontColor(this.bundleColor(check.state))
        .width(18)
      Column() {
        Text(check.bundleName)
          .fontSize(13)
          .fontColor(C_TEXT)
          .width('100%')
        Text(AppResolver.describe(check))
          .fontSize(11)
          .fontColor(C_TEXT2)
          .width('100%')
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 5, bottom: 5 })
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
        this.Card('基础', 'VPN 模式由系统 VPN 扩展承载；本地代理提供 SOCKS 端口')
        this.SwitchRow('VPN 模式（未实现：仅本地代理模式）', '见下方说明；开关会保存，但当前只会以 VPN 模式连接', this.vpnMode, (v: boolean) => {
          this.vpnMode = v;
          this.commit((d: AppSettingsData) => {
            d.vpnMode = v;
          });
        })
        this.SwitchRow('本地代理（未实现）', 'SOCKS 入站目前无条件创建（VPN 的 tun2socks 必须连它），开关暂不改变行为', this.localProxyEnabled, (v: boolean) => {
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
        this.SwitchRow('SOCKS 允许 UDP', '关掉后经本地代理的 UDP 一律拒绝（不会直连泄漏）', this.socksEnableUdp,
          (v: boolean) => {
            this.socksEnableUdp = v;
            this.commit((d: AppSettingsData) => {
              d.socksEnableUdp = v;
            });
          })
        this.TextRow('SOCKS 用户名（可选）', this.socksUsername, '留空表示不认证', (v: string) => {
          this.socksUsername = v;
          this.commit((d: AppSettingsData) => {
            d.socksUsername = v;
          });
        })
        this.TextRow('SOCKS 密码（可选）', this.socksPassword, '与用户名同时填写才生效', (v: string) => {
          this.socksPassword = v;
          this.commit((d: AppSettingsData) => {
            d.socksPassword = v;
          });
        })
        this.TextRow('HTTP 端口（未实现，无 HTTP 入站）', this.httpPort, '10809', (v: string) => {
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
        this.SwitchRow('追加 HTTP 代理（鸿蒙不可实现）', '安卓用 VpnService.Builder.setHttpProxy；鸿蒙 VpnConfig 没有任何代理字段，做不了', this.appendHttpProxy, (v: boolean) => {
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

        Text('说明：本机尚未实现“仅本地代理”模式（关掉 VPN、只在回环上开端口让浏览器等应用用），'
          + '也没实现 HTTP 入站与“追加 HTTP 代理”。安卓版的“追加 HTTP 代理”靠的是 '
          + 'VpnService.Builder.setHttpProxy()，鸿蒙的 VpnConfig 里根本没有代理字段，'
          + '属于平台缺失而非没做。这些开关会照常保存（便于与安卓版互相导入设置），'
          + '但当前只有 VPN 模式会真正生效。')
          .fontSize(12)
          .fontColor(C_WARN)
          .width('100%')
          .margin({ top: 4, bottom: 8 })

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
        this.TextRow('应用名单（包名，逗号分隔）', this.perAppProxySet,
          'com.example.app, com.example.two', (v: string) => {
            this.perAppProxySet = v;
            this.commit((d: AppSettingsData) => {
              d.perAppProxySet = v;
            });
          })

        Row() {
          Button('核验名单')
            .fontSize(13)
            .backgroundColor(C_FIELD)
            .fontColor(C_ACCENT)
            .onClick(() => {
              this.refreshBundleChecks();
            })
          Text(`${this.bundleChecks.length} 项`)
            .fontSize(12)
            .fontColor(C_TEXT2)
            .margin({ left: 10 })
        }
        .width('100%')
        .margin({ bottom: 6 })

        ForEach(this.bundleChecks, (check: BundleCheck) => {
          this.BundleRow(check)
        }, (check: BundleCheck) => check.bundleName + '-' + check.state)

        Text('鸿蒙不允许普通应用枚举已安装应用（bundleManager 只有按包名查询，'
          + '没有 getAllBundleInfo），所以安卓版那种“勾选应用”的选择器在这里做不到：'
          + '只能填包名。包名可在“设置 → 应用 → 应用详情”或用 '
          + 'hdc shell bm dump -a 查到。名单在下次连接时生效，未核验通过的包名会被隧道忽略。')
          .fontSize(12)
          .fontColor(C_TEXT2)
          .width('100%')
          .margin({ top: 4, bottom: 8 })

        // --- Mux ---
        this.Card('Mux（分流复用）', '默认关闭，与安卓版出厂设置一致')
        this.SwitchRow('启用 Mux', '把多条连接复用进一条；部分服务端/协议会因此异常，'
          + 'socks/trojan/ss/http/wireguard/hysteria 与 XHTTP 传输仍会自动禁用', this.muxEnabled,
          (v: boolean) => {
            this.muxEnabled = v;
            this.commit((d: AppSettingsData) => {
              d.muxEnabled = v;
            });
          })
        this.TextRow('并发数 (concurrency)', this.muxConcurrency, '8', (v: string) => {
          this.muxConcurrency = v;
          this.commit((d: AppSettingsData) => {
            d.muxConcurrency = v;
          });
        })
        this.TextRow('XUDP 并发数', this.muxXudpConcurrency, '8', (v: string) => {
          this.muxXudpConcurrency = v;
          this.commit((d: AppSettingsData) => {
            d.muxXudpConcurrency = v;
          });
        })
        this.PickerRow('XUDP 走 UDP/443 时', MUX_QUIC_SELECT, this.muxXudpProxyUDP443,
          MUX_XUDP_QUIC, MUX_XUDP_QUIC_LABELS, (v: string) => {
            this.muxXudpProxyUDP443 = v;
            this.commit((d: AppSettingsData) => {
              d.muxXudpProxyUDP443 = v;
            });
          })
        Text('注：带 flow（如 xtls-rprx-vision）的 VLESS 节点，Mux 并发会被强制设为 -1，'
          + '即该节点上 Mux 等于关闭——这是上游 CoreOutboundBuilder 的行为。')
          .fontSize(12)
          .fontColor(C_TEXT2)
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
