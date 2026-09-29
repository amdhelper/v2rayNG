/**
 * 主页面 — 服务器列表 / 连接开关 / 流量统计。
 * 对应安卓版 ui/main/MainActivity.kt + MainScreen.kt。
 *
 * 深色主题为硬性要求（黄斑变性无障碍），所有颜色都显式给出，
 * 不依赖任何系统浅色资源。
 *
 * 延迟测试走 @ohos.taskpool：CoreNative.measureOutboundDelay() 是同步阻塞的
 * 原生调用，放在 UI 线程会卡住 ArkUI 渲染循环，所以放进 taskpool worker。
 */
import router from '@ohos.router';
import pasteboard from '@ohos.pasteboard';
import taskpool from '@ohos.taskpool';
import { ProfileItem, configTypeName } from '../model/Profile';
import { profiles, parseBatch } from '../model/ProfileStore';
import { subscriptions, SubItem } from '../model/SubscriptionStore';
import { settings, AppSettingsData } from '../model/AppSettings';
import { XrayConfigBuilder } from '../core/XrayConfigBuilder';
import { CoreNative } from '../core/CoreNative';
import { measureDelayConcurrent } from '../core/DelayTask';
import { ConnectionController, TrafficStat } from '../core/ConnectionController';
import { Log } from '../util/Log';

// ---------------------------------------------------------------------------
// 深色主题
// ---------------------------------------------------------------------------
const C_BG: string = '#FF101418';
const C_CARD: string = '#FF1B2026';
const C_CARD_SEL: string = '#FF22303F';
const C_TEXT: string = '#FFE8EAED';
const C_TEXT2: string = '#FF9AA0A6';
const C_ACCENT: string = '#FF8AB4F8';
const C_OK: string = '#FF7BE495';
const C_WARN: string = '#FFF2B45C';
const C_BAD: string = '#FFE8836B';

/** 流量统计刷新周期。 */
const TRAFFIC_TICK_MS: number = 2000;
/** 连接中时延迟芯片的自动刷新周期。 */
const DELAY_REFRESH_MS: number = 15000;

/** 延迟测试的内部状态：-2 正在测，-1 失败，0 未测，>0 毫秒。 */
const DELAY_TESTING: number = -2;
const DELAY_FAILED: number = -1;
const DELAY_NONE: number = 0;

/**
 * 列表行的视图模型。
 * 不直接渲染 ProfileItem：ArkUI 的 @State 对类实例的深层字段不敏感，
 * 而延迟是会就地改的，所以每行一份扁平数据，改完整体重建数组触发重绘。
 */
class RowVM {
  guid: string = '';
  remarks: string = '';
  typeName: string = '';
  address: string = '';
  delay: number = DELAY_NONE;
  selected: boolean = false;
}

function formatBytes(n: number): string {
  if (n < 1024) {
    return `${Math.round(n)} B`;
  }
  if (n < 1024 * 1024) {
    return `${(n / 1024).toFixed(1)} KB`;
  }
  if (n < 1024 * 1024 * 1024) {
    return `${(n / 1024 / 1024).toFixed(2)} MB`;
  }
  return `${(n / 1024 / 1024 / 1024).toFixed(2)} GB`;
}

/** 延迟芯片文案：>0 显示毫秒，-1 超时，0/-2 未测或正在测。 */
function delayLabel(ms: number): string {
  if (ms === DELAY_FAILED) {
    return 'timeout';
  }
  if (ms === DELAY_TESTING) {
    return '测试中';
  }
  if (ms <= DELAY_NONE) {
    return '--';
  }
  return `${ms} ms`;
}

function delayColor(ms: number): string {
  if (ms === DELAY_FAILED) {
    return C_BAD;
  }
  if (ms > 0 && ms < 300) {
    return C_OK;
  }
  if (ms > 0 && ms < 1000) {
    return C_WARN;
  }
  if (ms > 0) {
    return C_BAD;
  }
  return C_TEXT2;
}

@Entry
@Component
struct Index {
  @State rows: RowVM[] = [];
  @State connected: boolean = false;
  @State connecting: boolean = false;
  @State stateText: string = '未连接';
  @State upBytes: number = 0;
  @State downBytes: number = 0;
  @State showAddSheet: boolean = false;
  @State subSheet: boolean = false;
  @State subName: string = '';
  @State subUrl: string = '';
  @State subBusy: boolean = false;

  private selected: string = '';
  private trafficTimer: number = -1;
  private delayTimer: number = -1;
  private testing: boolean = false;

  aboutToAppear(): void {
    this.selected = profiles.selectedGuid();
    this.rebuild();
    this.connected = ConnectionController.isConnected();
    this.stateText = this.connected ? '已连接' : '未连接';
    this.startTimers();
  }

  aboutToDisappear(): void {
    this.stopTimers();
  }

  // -------------------------------------------------------------------------
  // 列表
  // -------------------------------------------------------------------------

  /** 从 store 重新生成视图模型数组；任何列表/延迟变化后都要调。 */
  private rebuild(): void {
    this.selected = profiles.selectedGuid();
    const out: RowVM[] = [];
    for (const p of profiles.all()) {
      out.push(this.toRow(p));
    }
    this.rows = out;
  }

  private toRow(p: ProfileItem): RowVM {
    const r: RowVM = new RowVM();
    r.guid = p.guid;
    r.remarks = p.remarks;
    r.typeName = configTypeName(p.configType);
    r.address = p.getServerAddressAndPort();
    r.delay = profiles.delayOf(p.guid);
    r.selected = this.selected === p.guid;
    return r;
  }

  /** 只更新一行的延迟，保持数组引用其它部分不变（仍需整体重建以触发观察）。 */
  private patchDelay(guid: string, ms: number): void {
    const next: RowVM[] = [];
    for (const r of this.rows) {
      if (r.guid === guid) {
        const copy: RowVM = new RowVM();
        copy.guid = r.guid;
        copy.remarks = r.remarks;
        copy.typeName = r.typeName;
        copy.address = r.address;
        copy.delay = ms;
        copy.selected = r.selected;
        next.push(copy);
      } else {
        next.push(r);
      }
    }
    this.rows = next;
  }

  // -------------------------------------------------------------------------
  // 定时器
  // -------------------------------------------------------------------------

  private startTimers(): void {
    this.stopTimers();
    this.trafficTimer = setInterval(() => {
      this.refreshState();
      this.pollTraffic();
    }, TRAFFIC_TICK_MS);
    this.delayTimer = setInterval(() => {
      this.refreshDelaysIfConnected();
    }, DELAY_REFRESH_MS);
  }

  private stopTimers(): void {
    if (this.trafficTimer !== -1) {
      clearInterval(this.trafficTimer);
      this.trafficTimer = -1;
    }
    if (this.delayTimer !== -1) {
      clearInterval(this.delayTimer);
      this.delayTimer = -1;
    }
  }

  private pollTraffic(): void {
    if (!ConnectionController.isConnected()) {
      return;
    }
    try {
      // ConnectionController.stats() 读的是 VPN 扩展落盘的累计值，
      // 已经是本次会话的总量，不需要我自己累加。
      const t: TrafficStat = ConnectionController.stats();
      this.upBytes = t.txBytes;
      this.downBytes = t.rxBytes;
    } catch (e) {
      Log.w('Index.pollTraffic failed: ' + JSON.stringify(e));
    }
  }

  /** 状态与流量一起刷：连接可能在我们没点按钮的时候断开（扩展被杀等）。 */
  private async refreshState(): Promise<void> {
    const was: boolean = this.connected;
    this.connected = ConnectionController.isConnected();
    if (was !== this.connected) {
      this.upBytes = 0;
      this.downBytes = 0;
      this.rebuild();
    }
    this.stateText = this.describeState();
  }

  private async refreshDelaysIfConnected(): Promise<void> {
    if (!ConnectionController.isConnected() || this.testing) {
      return;
    }
    // 只刷新选中项：全量重测太贵，也没意义。
    if (this.selected.length === 0) {
      return;
    }
    await this.testDelay(this.selected, false);
  }

  // -------------------------------------------------------------------------
  // 延迟测试
  // -------------------------------------------------------------------------

  /**
   * 真实延迟测试：构造仅含 outbound 的配置，在 taskpool 里跑原生探测，
   * 结果写回 ProfileStore.markDelay。
   */
  private async testDelay(guid: string, toast: boolean): Promise<void> {
    if (this.testing) {
      return;
    }
    const p: ProfileItem | null = profiles.get(guid);
    if (p === null) {
      return;
    }
    this.testing = true;
    this.patchDelay(guid, DELAY_TESTING);

    const s: AppSettingsData = settings.get();
    let ms: number = DELAY_FAILED;
    try {
      const cfg: string = XrayConfigBuilder.buildOutboundOnly(p);
      ms = await this.measure(cfg, s.delayTestUrl, s.delayTestTimeoutMs);
    } catch (e) {
      Log.e('Index.testDelay failed for ' + guid + ': ' + JSON.stringify(e));
      ms = DELAY_FAILED;
    }

    profiles.markDelay(guid, ms);
    this.patchDelay(guid, ms);
    this.testing = false;
    if (toast) {
      this.toast(`延迟测试：${delayLabel(ms)}`);
    }
  }

  /** 优先走 taskpool；worker 起不来时退回同步调用，保证功能不残废。 */
  private async measure(configJson: string, url: string, timeoutMs: number): Promise<number> {
    try {
      const result: Object = await taskpool.execute(measureDelayConcurrent, configJson, url, timeoutMs);
      if (typeof result === 'number') {
        return result as number;
      }
      return DELAY_FAILED;
    } catch (e) {
      Log.w('Index.measure: taskpool unavailable, inline fallback: ' + JSON.stringify(e));
      return CoreNative.measureOutboundDelay(configJson, url, timeoutMs);
    }
  }

  // -------------------------------------------------------------------------
  // 连接
  // -------------------------------------------------------------------------

  private async toggleConnection(): Promise<void> {
    if (this.connecting) {
      return;
    }
    if (!ConnectionController.isConnected() && this.selected.length === 0) {
      this.toast('请先选择一个服务器');
      return;
    }
    this.connecting = true;
    this.stateText = '正在连接…';
    try {
      if (ConnectionController.isConnected()) {
        await ConnectionController.stop();
      } else {
        // start() 内部最多等 20s，成功与否用返回值，不要只看异常。
        const ok: boolean = await ConnectionController.start();
        if (!ok) {
          const reason: string = ConnectionController.lastError();
          this.toast(reason.length > 0 ? `连接失败：${reason}` : '连接失败，详见日志');
        }
      }
    } catch (e) {
      Log.e('Index.toggleConnection failed: ' + JSON.stringify(e));
      this.toast('连接操作失败，详见日志');
    }
    this.connected = ConnectionController.isConnected();
    this.connecting = false;
    this.stateText = this.describeState();
    if (!this.connected) {
      this.upBytes = 0;
      this.downBytes = 0;
    }
  }

  /** 状态文案以 ConnectionController 为准（它是 VPN 扩展的写入方）。 */
  private describeState(): string {
    if (ConnectionController.isConnected()) {
      return '已连接';
    }
    if (ConnectionController.isBusy()) {
      return '正在连接…';
    }
    const err: string = ConnectionController.lastError();
    return err.length > 0 ? '连接失败：' + err : '未连接';
  }

  // -------------------------------------------------------------------------
  // 列表操作
  // -------------------------------------------------------------------------

  private async onSelect(guid: string): Promise<void> {
    await profiles.select(guid);
    this.rebuild();
  }

  private onDelete(guid: string): void {
    const p: ProfileItem | null = profiles.get(guid);
    const name: string = p === null ? guid : p.remarks;
    this.getUIContext().showAlertDialog({
      title: '删除服务器',
      message: `确定删除「${name}」吗？此操作不可撤销。`,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: C_BAD,
        action: () => {
          this.doDelete(guid);
        }
      }
    });
  }

  private async doDelete(guid: string): Promise<void> {
    await profiles.remove(guid);
    this.rebuild();
  }

  private onEdit(guid: string): void {
    router.pushUrl({
      url: 'pages/ServerEdit',
      params: { guid: guid }
    }).catch((e: Object) => {
      Log.e('Index.onEdit pushUrl failed: ' + JSON.stringify(e));
    });
  }

  private onOpenSettings(): void {
    router.pushUrl({ url: 'pages/Settings' }).catch((e: Object) => {
      Log.e('Index.onOpenSettings pushUrl failed: ' + JSON.stringify(e));
    });
  }

  // -------------------------------------------------------------------------
  // 添加服务器
  // -------------------------------------------------------------------------

  private addManually(): void {
    // 空白表单，新建一条 vmess 草稿，保存时才真正落库。
    router.pushUrl({
      url: 'pages/ServerEdit',
      params: { guid: '', isNew: true }
    }).catch((e: Object) => {
      Log.e('Index.addManually pushUrl failed: ' + JSON.stringify(e));
    });
  }

  private async addFromClipboard(): Promise<void> {
    let text: string = '';
    try {
      const board: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      const data: pasteboard.PasteData = await board.getData();
      text = data.getPrimaryText();
    } catch (e) {
      Log.e('Index.addFromClipboard: pasteboard read failed: ' + JSON.stringify(e));
      this.toast('读取剪贴板失败');
      return;
    }
    if (text.trim().length === 0) {
      this.toast('剪贴板为空');
      return;
    }
    await this.importText(text, '剪贴板导入');
  }

  private addFromLink(): void {
    // 粘贴分享链接交给 ServerEdit 预填，走完整的解析 + 表单确认流程。
    router.pushUrl({
      url: 'pages/ServerEdit',
      params: { guid: '', isNew: true, fromClipboard: true }
    }).catch((e: Object) => {
      Log.e('Index.addFromLink pushUrl failed: ' + JSON.stringify(e));
    });
  }

  private async importText(text: string, label: string): Promise<void> {
    const parsed: ProfileItem[] = parseBatch(text);
    if (parsed.length === 0) {
      this.toast(`${label}：无法解析任何节点`);
      return;
    }
    const added: number = await profiles.importFromText(text, '');
    const dropped: number = await profiles.dedupe();
    this.rebuild();
    const tail: string = dropped > 0 ? `，去重 ${dropped}` : '';
    this.toast(`${label}：导入 ${added} 个节点${tail}`);
  }

  // -------------------------------------------------------------------------
  // 订阅
  // -------------------------------------------------------------------------

  private async updateAllSubscriptions(): Promise<void> {
    this.subBusy = true;
    try {
      const results = await subscriptions.updateAll();
      if (results.length === 0) {
        this.toast('还没有订阅，先在下方添加一个');
        return;
      }
      let added: number = 0;
      let updated: number = 0;
      let failed: number = 0;
      for (const r of results) {
        if (r.ok) {
          added += r.added;
          updated += r.updated;
        } else {
          failed++;
          Log.w('Index.updateAllSubscriptions: ' + r.remarks + ' -> ' + r.error);
        }
      }
      this.rebuild();
      const bad: string = failed > 0 ? `，失败 ${failed}` : '';
      this.toast(`订阅更新：新增 ${added}，更新 ${updated}${bad}`);
    } finally {
      this.subBusy = false;
    }
  }

  private async addSubscription(): Promise<void> {
    if (this.subUrl.trim().length === 0) {
      this.toast('请填写订阅地址');
      return;
    }
    this.subBusy = true;
    try {
      await subscriptions.add(this.subName, this.subUrl);
      const name: string = this.subName;
      this.subName = '';
      this.subUrl = '';
      const r = await subscriptions.updateAll();
      let added: number = 0;
      for (const one of r) {
        if (one.ok) {
          added += one.added;
        } else {
          this.toast(`${one.remarks} 更新失败：${one.error}`);
        }
      }
      this.rebuild();
      this.toast(`订阅「${name}」已添加，新增 ${added} 个节点`);
    } finally {
      this.subBusy = false;
    }
  }

  private async removeSubscription(id: string): Promise<void> {
    await subscriptions.remove(id);
    this.toast('订阅已删除');
  }

  private async updateOneSubscription(id: string): Promise<void> {
    this.subBusy = true;
    try {
      const r = await subscriptions.update(id);
      this.rebuild();
      if (r.ok) {
        this.toast(`${r.remarks}：新增 ${r.added}，更新 ${r.updated}`);
      } else {
        this.toast(`${r.remarks} 更新失败：${r.error}`);
      }
    } finally {
      this.subBusy = false;
    }
  }

  private subLabel(s: SubItem): string {
    return s.remarks.length > 0 ? s.remarks : s.url;
  }

  private subToggle(s: SubItem): string {
    return s.enabled ? '已启用' : '已停用';
  }

  // -------------------------------------------------------------------------
  // 提示
  // -------------------------------------------------------------------------

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
    } catch (e) {
      Log.w('Index.toast failed: ' + JSON.stringify(e));
    }
  }

  // -------------------------------------------------------------------------
  // UI 片段
  // -------------------------------------------------------------------------

  @Builder
  ServerActions(item: RowVM) {
    Row() {
      Button('测试延迟')
        .fontSize(13)
        .fontColor(C_TEXT)
        .backgroundColor(C_BG)
        .layoutWeight(1)
        .onClick(() => {
          this.testDelay(item.guid, true);
        })
      Button('编辑')
        .fontSize(13)
        .fontColor(C_TEXT)
        .backgroundColor(C_BG)
        .layoutWeight(1)
        .margin({ left: 8 })
        .onClick(() => {
          this.onEdit(item.guid);
        })
      Button('删除')
        .fontSize(13)
        .fontColor(C_BAD)
        .backgroundColor(C_BG)
        .layoutWeight(1)
        .margin({ left: 8 })
        .onClick(() => {
          this.onDelete(item.guid);
        })
    }
    .width('100%')
    .padding({ left: 14, right: 14, bottom: 10 })
  }

  @Builder
  EmptyHint() {
    Column() {
      Text('还没有服务器').fontSize(16).fontColor(C_TEXT)
      Text('点下方「添加」导入节点，或粘贴分享链接')
        .fontSize(13)
        .fontColor(C_TEXT2)
        .margin({ top: 6 })
    }
    .width('100%')
    .padding({ top: 40, bottom: 40 })
  }

  @Builder
  AddSheet() {
    Column() {
      Text('添加服务器')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(C_TEXT)
        .width('100%')
        .margin({ bottom: 10 })
      Button('手动输入')
        .width('100%')
        .fontColor(C_TEXT)
        .backgroundColor(C_BG)
        .onClick(() => {
          this.showAddSheet = false;
          this.addManually();
        })
      Button('从剪贴板导入')
        .width('100%')
        .fontColor(C_TEXT)
        .backgroundColor(C_BG)
        .margin({ top: 8 })
        .onClick(() => {
          this.showAddSheet = false;
          this.addFromClipboard();
        })
      Button('粘贴分享链接')
        .width('100%')
        .fontColor(C_TEXT)
        .backgroundColor(C_BG)
        .margin({ top: 8 })
        .onClick(() => {
          this.showAddSheet = false;
          this.addFromLink();
        })
      Button('订阅更新')
        .width('100%')
        .fontColor(C_TEXT)
        .backgroundColor(C_BG)
        .margin({ top: 8 })
        .onClick(() => {
          this.showAddSheet = false;
          this.subSheet = true;
        })
      Button('取消')
        .width('100%')
        .fontColor(C_TEXT2)
        .backgroundColor(C_BG)
        .margin({ top: 12 })
        .onClick(() => {
          this.showAddSheet = false;
        })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(C_CARD)
    .borderRadius(16)
    // Block：点击面板本体不冒泡到遮罩，否则一点击就关闭。
    .hitTestBehavior(HitTestMode.Block)
  }

  @Builder
  SubSheet() {
    Column() {
      Text('订阅管理')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(C_TEXT)
        .width('100%')

      Scroll() {
        Column() {
          ForEach(subscriptions.list(), (s: SubItem) => {
            Column() {
              Text(this.subLabel(s))
                .fontSize(15)
                .fontColor(C_TEXT)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(`${this.subToggle(s)} · 上次更新 ${s.lastUpdated > 0 ? new Date(s.lastUpdated).toLocaleString() : '从未'}`)
                .fontSize(12)
                .fontColor(C_TEXT2)
                .width('100%')
                .margin({ top: 2 })
              Row() {
                Button('立即更新')
                  .fontSize(13)
                  .fontColor(C_TEXT)
                  .backgroundColor(C_BG)
                  .layoutWeight(1)
                  .onClick(() => {
                    this.updateOneSubscription(s.guid);
                  })
                Button('删除订阅')
                  .fontSize(13)
                  .fontColor(C_BAD)
                  .backgroundColor(C_BG)
                  .layoutWeight(1)
                  .margin({ left: 8 })
                  .onClick(() => {
                    this.removeSubscription(s.guid);
                  })
              }
              .width('100%')
              .margin({ top: 8 })
            }
            .width('100%')
            .padding(12)
            .backgroundColor(C_BG)
            .borderRadius(10)
            .margin({ top: 10 })
          }, (s: SubItem) => s.guid)

          if (subscriptions.list().length === 0) {
            Text('暂无订阅')
              .fontSize(13)
              .fontColor(C_TEXT2)
              .width('100%')
              .margin({ top: 16 })
          }
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: 260 })
      .margin({ top: 10, bottom: 10 })

      TextInput({ text: this.subName, placeholder: '订阅名称（可留空）' })
        .backgroundColor(C_BG)
        .fontColor(C_TEXT)
        .placeholderColor(C_TEXT2)
        .width('100%')
        .onChange((value: string) => {
          this.subName = value;
        })

      TextInput({ text: this.subUrl, placeholder: 'https://example.com/sub' })
        .backgroundColor(C_BG)
        .fontColor(C_TEXT)
        .placeholderColor(C_TEXT2)
        .width('100%')
        .margin({ top: 8 })
        .onChange((value: string) => {
          this.subUrl = value;
        })

      Button(this.subBusy ? '处理中…' : '添加并更新')
        .width('100%')
        .fontColor(C_TEXT)
        .backgroundColor(C_ACCENT)
        .margin({ top: 12 })
        .enabled(!this.subBusy)
        .onClick(() => {
          this.addSubscription();
        })

      Button(this.subBusy ? '处理中…' : '全部更新')
        .width('100%')
        .fontColor(C_TEXT)
        .backgroundColor(C_BG)
        .margin({ top: 8 })
        .enabled(!this.subBusy)
        .onClick(() => {
          this.updateAllSubscriptions();
        })

      Button('关闭')
        .width('100%')
        .fontColor(C_TEXT2)
        .backgroundColor(C_BG)
        .margin({ top: 8 })
        .onClick(() => {
          this.subSheet = false;
        })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(C_CARD)
    .borderRadius(16)
    .hitTestBehavior(HitTestMode.Block)
  }

  // -------------------------------------------------------------------------
  // 页面
  // -------------------------------------------------------------------------

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        // --- 顶部状态 ---
        Row() {
          Text('v2rayNG')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(C_TEXT)
          Blank()
          Text(this.stateText)
            .fontSize(13)
            .fontColor(this.connected ? C_OK : C_TEXT2)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 8 })

        if (this.connected) {
          Row() {
            Text(`↑ ${formatBytes(this.upBytes)}`)
              .fontSize(13)
              .fontColor(C_ACCENT)
            Text('　')
              .fontSize(13)
              .fontColor(C_TEXT2)
            Text(`↓ ${formatBytes(this.downBytes)}`)
              .fontSize(13)
              .fontColor(C_OK)
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 8 })
        }

        // --- 列表 ---
        Scroll() {
          Column() {
            if (this.rows.length === 0) {
              this.EmptyHint()
            }
            ForEach(this.rows, (item: RowVM) => {
              Column() {
                Row() {
                  Column() {
                    Text(item.remarks.length > 0 ? item.remarks : '(未命名)')
                      .fontSize(17)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(C_TEXT)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(`${item.typeName} · ${item.address}`)
                      .fontSize(12)
                      .fontColor(C_TEXT2)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .margin({ top: 3 })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  Text(delayLabel(item.delay))
                    .fontSize(13)
                    .fontColor(delayColor(item.delay))
                    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                    .backgroundColor(C_BG)
                    .borderRadius(10)
                    .margin({ left: 8, right: 8 })

                  if (item.selected) {
                    Text('已选')
                      .fontSize(12)
                      .fontColor(C_ACCENT)
                  }
                }
                .width('100%')
                .padding({ left: 14, right: 14, top: 12, bottom: 6 })
                .onClick(() => {
                  this.onSelect(item.guid);
                })

                this.ServerActions(item)
              }
              .width('100%')
              .backgroundColor(item.selected ? C_CARD_SEL : C_CARD)
              .borderRadius(12)
              .margin({ bottom: 10 })
            }, (item: RowVM) => item.guid)
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
        }
        .width('100%')
        .layoutWeight(1)

        // --- 底部操作条 ---
        Row() {
          Button(this.connecting ? '处理中…' : (this.connected ? '断开连接' : '连接'))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(C_BG)
            .backgroundColor(this.connected ? C_BAD : C_ACCENT)
            .layoutWeight(1)
            .height(48)
            .enabled(!this.connecting)
            .onClick(() => {
              this.toggleConnection();
            })
          Button('添加')
            .fontSize(16)
            .fontColor(C_TEXT)
            .backgroundColor(C_CARD)
            .width(96)
            .height(48)
            .margin({ left: 10 })
            .onClick(() => {
              this.showAddSheet = true;
            })
          Button('设置')
            .fontSize(16)
            .fontColor(C_TEXT)
            .backgroundColor(C_CARD)
            .width(96)
            .height(48)
            .margin({ left: 10 })
            .onClick(() => {
              this.onOpenSettings();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 16 })
        .backgroundColor(C_BG)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(C_BG)

      // --- 遮罩层：添加 / 订阅 ---
      if (this.showAddSheet) {
        Column() {
          Blank()
          this.AddSheet()
          Blank()
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#99000000')
        .onClick(() => {
          this.showAddSheet = false;
        })
      }

      if (this.subSheet) {
        Column() {
          Blank()
          Scroll() {
            this.SubSheet()
          }
          .constraintSize({ maxHeight: 620 })
          .hitTestBehavior(HitTestMode.Block)
          Blank()
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#99000000')
        .onClick(() => {
          this.subSheet = false;
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
  }
}
