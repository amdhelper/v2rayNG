/**
 * 服务器编辑页 — 对应安卓版 ui/server/ServerEditActivity.kt。
 *
 * 深色主题为硬性要求，所有颜色显式给出。
 *
 * 两种进入方式：
 *  1. 编辑已有节点：Index 传 guid，读取 ProfileStore。
 *  2. 新建 / 粘贴分享链接：Index 传 isNew(+fromClipboard)，本页先尝试
 *     从剪贴板解析分享链接预填表单，用户确认后保存。
 */
import router from '@ohos.router';
import pasteboard from '@ohos.pasteboard';
import {
  ProfileItem,
  EConfigType,
  configTypeName,
  configTypeFromName,
  NetworkType,
  SecurityType
} from '../model/Profile';
import { profiles, newGuid } from '../model/ProfileStore';
import { Fmt } from '../fmt/Fmt';
import { Log } from '../util/Log';

const C_BG: string = '#FF101418';
const C_CARD: string = '#FF1B2026';
const C_FIELD: string = '#FF161B21';
const C_TEXT: string = '#FFE8EAED';
const C_TEXT2: string = '#FF9AA0A6';
const C_ACCENT: string = '#FF8AB4F8';
const C_BAD: string = '#FFE8836B';

/** 协议下拉项。 */
const TYPE_OPTIONS: string[] = [
  configTypeName(EConfigType.VMESS),
  configTypeName(EConfigType.VLESS),
  configTypeName(EConfigType.SHADOWSOCKS),
  configTypeName(EConfigType.TROJAN),
  configTypeName(EConfigType.HYSTERIA2),
  configTypeName(EConfigType.SOCKS),
  configTypeName(EConfigType.HTTP),
  configTypeName(EConfigType.ANYTLS),
  configTypeName(EConfigType.WIREGUARD),
  configTypeName(EConfigType.CUSTOM)
];

/** 传输方式下拉项（对应 Profile.NetworkType）。 */
const NETWORK_OPTIONS: string[] = [
  NetworkType.TCP,
  NetworkType.KCP,
  NetworkType.WS,
  NetworkType.HTTP,
  NetworkType.GRPC,
  NetworkType.HTTPUPGRADE,
  NetworkType.SPLITHTP,
  NetworkType.XHTTP,
  NetworkType.QUIC
];

/** 安全层下拉项（对应 Profile.SecurityType）。 */
const SECURITY_OPTIONS: string[] = [SecurityType.NONE, SecurityType.TLS, SecurityType.REALITY];

/** 加密方式候选；vmess 用 aes-128-gcm 系列，shadowsocks 用 AEAD 系列。 */
const METHOD_OPTIONS: string[] = [
  'auto',
  'aes-128-gcm',
  'chacha20-poly1305',
  'none',
  '2022-blake3-aes-128-gcm',
  '2022-blake3-aes-256-gcm',
  '2022-blake3-chacha20-poly1305'
];

/** flow 只对 vless 有意义。 */
const FLOW_OPTIONS: string[] = ['', 'xtls-rprx-vision', 'xtls-rprx-vision-udp443'];

/** 把字符串数组转成 Select 需要的选项数组（模块级常量，避免每次 build 重新分配）。 */
function toSelectOptions(values: string[]): SelectOption[] {
  const out: SelectOption[] = [];
  for (const v of values) {
    const o: SelectOption = { value: v };
    out.push(o);
  }
  return out;
}

const TYPE_SELECT: SelectOption[] = toSelectOptions(TYPE_OPTIONS);
const NETWORK_SELECT: SelectOption[] = toSelectOptions(NETWORK_OPTIONS);
const SECURITY_SELECT: SelectOption[] = toSelectOptions(SECURITY_OPTIONS);
const METHOD_SELECT: SelectOption[] = toSelectOptions(METHOD_OPTIONS);
const FLOW_SELECT: SelectOption[] = toSelectOptions(FLOW_OPTIONS);

@Entry
@Component
struct ServerEdit {
  @State guid: string = '';
  @State typeName: string = configTypeName(EConfigType.VMESS);
  @State remarks: string = '';
  @State address: string = '';
  @State port: string = '';
  @State uuid: string = '';
  @State password: string = '';
  @State method: string = '';
  @State flow: string = '';
  @State network: string = NetworkType.TCP;
  @State security: string = SecurityType.NONE;
  @State sni: string = '';
  @State alpn: string = '';
  @State fingerPrint: string = '';
  @State insecure: boolean = false;
  @State path: string = '';
  @State host: string = '';
  @State serviceName: string = '';
  @State publicKey: string = '';
  @State shortId: string = '';
  @State spiderX: string = '';
  @State prefillNote: string = '';
  @State saving: boolean = false;

  /** 原始记录，用于保存时保留未在表单中暴露的字段。 */
  private original: ProfileItem | null = null;

  aboutToAppear(): void {
    this.load();
  }

  private load(): void {
    const params: ServerEditParams = router.getParams() as ServerEditParams;
    this.guid = params.guid ?? '';
    const isNew: boolean = params.isNew ?? false;

    if (this.guid.length > 0) {
      const existing: ProfileItem | null = profiles.get(this.guid);
      if (existing !== null) {
        this.original = existing;
        this.fill(existing);
        return;
      }
    }

    // 新建：默认给一条可用的 tcp/none 草稿。
    const fresh: ProfileItem = new ProfileItem();
    fresh.guid = this.guid.length > 0 ? this.guid : newGuid();
    fresh.network = NetworkType.TCP;
    fresh.security = SecurityType.NONE;
    this.fill(fresh);

    if (params.fromClipboard === true) {
      this.prefillFromClipboard();
    } else if (isNew) {
      this.prefillNote = '新建节点：填写后点保存';
    }
  }

  /** 把一条 ProfileItem 摊平到表单字段。 */
  private fill(p: ProfileItem): void {
    this.guid = p.guid;
    this.typeName = configTypeName(p.configType);
    this.remarks = p.remarks;
    this.address = p.server;
    this.port = p.serverPort;
    // uuid 与 password 共用一个输入框：vmess/vless 存 uuid，
    // trojan/ss/socks/http 存 password。
    this.uuid = p.configType === EConfigType.VMESS || p.configType === EConfigType.VLESS ? p.password : '';
    this.password = this.uuid.length === 0 ? p.password : '';
    this.method = p.method;
    this.flow = p.flow;
    this.network = p.network.length > 0 ? p.network : NetworkType.TCP;
    this.security = p.security.length > 0 ? p.security : SecurityType.NONE;
    this.sni = p.sni;
    this.alpn = p.alpn;
    this.fingerPrint = p.fingerPrint;
    this.insecure = p.insecure;
    this.path = p.path;
    this.host = p.host;
    this.serviceName = p.serviceName;
    this.publicKey = p.publicKey;
    this.shortId = p.shortId;
    this.spiderX = p.spiderX;
  }

  /** 从剪贴板读分享链接并预填。 */
  private async prefillFromClipboard(): Promise<void> {
    try {
      const board: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      const data: pasteboard.PasteData = await board.getData();
      const text: string = data.getPrimaryText().trim();
      if (text.length === 0) {
        this.prefillNote = '剪贴板为空，请手动填写';
        return;
      }
      const parsed: ProfileItem | null = Fmt.parse(text);
      if (parsed === null) {
        this.prefillNote = '剪贴板内容不是有效的分享链接，请手动填写';
        return;
      }
      // 保留本表单的 guid，让保存走 upsert 而不是新建。
      parsed.guid = this.guid;
      parsed.addedTime = Date.now();
      this.fill(parsed);
      this.prefillNote = `已从剪贴板预填：${parsed.remarks}`;
    } catch (e) {
      Log.e('ServerEdit.prefillFromClipboard failed: ' + JSON.stringify(e));
      this.prefillNote = '读取剪贴板失败，请手动填写';
    }
  }

  // -------------------------------------------------------------------------
  // 保存 / 删除
  // -------------------------------------------------------------------------

  private buildProfile(): ProfileItem {
    const p: ProfileItem = this.original !== null ? this.original : new ProfileItem();
    p.guid = this.guid.length > 0 ? this.guid : newGuid();
    p.configType = configTypeFromName(this.typeName);
    p.remarks = this.remarks;
    p.server = this.address;
    p.serverPort = this.port;
    // 按协议决定写 uuid 还是 password 槽位，避免两边串味。
    const cred: string = this.uuid.length > 0 ? this.uuid : this.password;
    p.password = cred;
    p.username = '';
    p.method = this.method;
    p.flow = this.flow;
    p.network = this.network;
    p.security = this.security;
    p.sni = this.sni;
    p.alpn = this.alpn;
    p.fingerPrint = this.fingerPrint;
    p.insecure = this.insecure;
    p.path = this.path;
    p.host = this.host;
    p.serviceName = this.serviceName;
    p.publicKey = this.publicKey;
    p.shortId = this.shortId;
    p.spiderX = this.spiderX;
    return p;
  }

  private async save(): Promise<void> {
    if (this.saving) {
      return;
    }
    if (this.address.trim().length === 0) {
      this.toast('请填写服务器地址');
      return;
    }
    if (this.port.trim().length === 0) {
      this.toast('请填写服务器端口');
      return;
    }
    this.saving = true;
    try {
      const p: ProfileItem = this.buildProfile();
      await profiles.upsert(p);
      this.guid = p.guid;
      this.original = p;
      Log.i('ServerEdit.save ' + p.guid + ' (' + configTypeName(p.configType) + ')');
      this.toast('已保存');
      router.back();
    } catch (e) {
      Log.e('ServerEdit.save failed: ' + JSON.stringify(e));
      this.toast('保存失败，详见日志');
    } finally {
      this.saving = false;
    }
  }

  private onDelete(): void {
    const target: string = this.guid;
    this.getUIContext().showAlertDialog({
      title: '删除服务器',
      message: '确定删除这条服务器配置吗？',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: C_BAD,
        action: () => {
          this.doDelete(target);
        }
      }
    });
  }

  private async doDelete(guid: string): Promise<void> {
    await profiles.remove(guid);
    this.toast('已删除');
    router.back();
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (e) {
      Log.w('ServerEdit.toast failed: ' + JSON.stringify(e));
    }
  }

  // -------------------------------------------------------------------------
  // UI 片段
  // -------------------------------------------------------------------------

  @Builder
  Field(label: string, value: string, placeholder: string, onChanged: (v: string) => void) {
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
  SwitchField(label: string, value: boolean, hint: string, onChanged: (v: boolean) => void) {
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
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  Picker(label: string, options: SelectOption[], value: string, onChanged: (v: string) => void) {
    Column() {
      Text(label)
        .fontSize(12)
        .fontColor(C_TEXT2)
        .width('100%')
        .margin({ bottom: 4 })
      Select(options)
        // value() 设置当前显示的选中项；onSelect 回填用户选择。
        // Select 没有 fontSize()，字号走 font()。
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
        Text('服务器配置')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(C_TEXT)
          .width('100%')
          .margin({ bottom: 4 })

        if (this.prefillNote.length > 0) {
          Text(this.prefillNote)
            .fontSize(12)
            .fontColor(C_ACCENT)
            .width('100%')
            .margin({ bottom: 12 })
        }

        this.Picker('协议', TYPE_SELECT, this.typeName, (v: string) => {
          this.typeName = v;
        })

        this.Field('备注', this.remarks, '例如 香港 01', (v: string) => {
          this.remarks = v;
        })

        this.Field('服务器地址', this.address, 'example.com 或 IP', (v: string) => {
          this.address = v;
        })

        this.Field('服务器端口', this.port, '443', (v: string) => {
          this.port = v;
        })

        this.Field(
          'UUID / 密码',
          this.uuid.length > 0 ? this.uuid : this.password,
          'vmess/vless 填 UUID，trojan/ss 填密码',
          (v: string) => {
            const t: EConfigType = configTypeFromName(this.typeName);
            if (t === EConfigType.VMESS || t === EConfigType.VLESS) {
              this.uuid = v;
              this.password = '';
            } else {
              this.password = v;
              this.uuid = '';
            }
          })

        this.Picker('加密方式', METHOD_SELECT, this.method, (v: string) => {
          this.method = v;
        })

        this.Picker('流控 (flow)', FLOW_SELECT, this.flow, (v: string) => {
          this.flow = v;
        })

        this.Picker('传输方式', NETWORK_SELECT, this.network, (v: string) => {
          this.network = v;
        })

        this.Picker('安全层', SECURITY_SELECT, this.security, (v: string) => {
          this.security = v;
        })

        this.Field('SNI', this.sni, '留空则用服务器地址', (v: string) => {
          this.sni = v;
        })

        this.Field('ALPN', this.alpn, '例如 h2,http/1.1', (v: string) => {
          this.alpn = v;
        })

        this.Field('指纹 (fingerprint)', this.fingerPrint, '例如 chrome', (v: string) => {
          this.fingerPrint = v;
        })

        this.SwitchField('允许不安全证书', this.insecure, '跳过 TLS 证书校验（仅自签场景）', (v: boolean) => {
          this.insecure = v;
        })

        this.Field('路径 (path)', this.path, '/path', (v: string) => {
          this.path = v;
        })

        this.Field('主机头 (host)', this.host, '多个用逗号分隔', (v: string) => {
          this.host = v;
        })

        this.Field('gRPC serviceName', this.serviceName, 'grpc 服务名', (v: string) => {
          this.serviceName = v;
        })

        this.Field('Reality 公钥', this.publicKey, '仅 reality 需要', (v: string) => {
          this.publicKey = v;
        })

        this.Field('Reality shortId', this.shortId, '十六进制，偶数长度', (v: string) => {
          this.shortId = v;
        })

        this.Field('Reality spiderX', this.spiderX, '默认 /', (v: string) => {
          this.spiderX = v;
        })

        Row() {
          Button('保存')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(C_BG)
            .backgroundColor(C_ACCENT)
            .layoutWeight(1)
            .height(48)
            .enabled(!this.saving)
            .onClick(() => {
              this.save();
            })
          Button('删除')
            .fontSize(16)
            .fontColor(C_BAD)
            .backgroundColor(C_CARD)
            .width(96)
            .height(48)
            .margin({ left: 10 })
            .onClick(() => {
              this.onDelete();
            })
        }
        .width('100%')
        .margin({ top: 8, bottom: 32 })
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

/** Index 传进来的路由参数。 */
interface ServerEditParams {
  guid?: string;
  isNew?: boolean;
  fromClipboard?: boolean;
}
