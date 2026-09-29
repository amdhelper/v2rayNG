/**
 * 日志页 — 对应安卓版 ui/logcat/LogcatActivity.kt。
 *
 * 数据源是 util/Log.ets 的内存环形缓冲 logRing（上限 2000 行），
 * 因此手机上直接看日志，不需要 hdc。深色主题为硬性要求。
 */
import pasteboard from '@ohos.pasteboard';
import { logRing, Log } from '../util/Log';

const C_BG: string = '#FF101418';
const C_CARD: string = '#FF1B2026';
const C_TEXT: string = '#FFE8EAED';
const C_TEXT2: string = '#FF9AA0A6';
const C_ACCENT: string = '#FF8AB4F8';
const C_ERROR: string = '#FFE8836B';
const C_WARN: string = '#FFF2B45C';
const C_CORE: string = '#FF7BE495';

/**
 * 行首级别字母 → 颜色。core 输出（'C'）最常见，单独给绿色。
 * util/Log 的行格式是 `${stamp} ${level} ${msg}`，stamp 恒为 12 字符
 * （HH:MM:SS.mmm），所以第 13 个字符才是级别标记。
 */
function levelColor(line: string): string {
  const marker: string = line.length > 13 ? line.substring(13, 14) : '';
  if (marker === 'E') {
    return C_ERROR;
  }
  if (marker === 'W') {
    return C_WARN;
  }
  if (marker === 'C') {
    return C_CORE;
  }
  return C_TEXT2;
}

@Entry
@Component
struct Logcat {
  @State lines: string[] = [];
  @State follow: boolean = true;

  /** 订阅句柄要保持稳定，才能正确退订。 */
  private readonly onLine = (line: string): void => {
    if (this.follow) {
      this.lines = this.lines.concat([line]);
      if (this.lines.length > 2000) {
        this.lines = this.lines.slice(this.lines.length - 2000);
      }
    }
  };

  aboutToAppear(): void {
    this.lines = logRing.all();
    logRing.subscribe(this.onLine);
  }

  aboutToDisappear(): void {
    logRing.unsubscribe(this.onLine);
  }

  private async copyAll(): Promise<void> {
    if (this.lines.length === 0) {
      this.toast('没有可复制的日志');
      return;
    }
    try {
      const board: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      const data: pasteboard.PasteData = pasteboard.createData(
        pasteboard.MIMETYPE_TEXT_PLAIN, this.lines.join('\n'));
      await board.setData(data);
      this.toast(`已复制 ${this.lines.length} 行`);
    } catch (e) {
      Log.e('Logcat.copyAll failed: ' + JSON.stringify(e));
      this.toast('复制失败');
    }
  }

  private clearAll(): void {
    this.getUIContext().showAlertDialog({
      title: '清空日志',
      message: '确定清空当前内存中的全部日志吗？',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: C_ERROR,
        action: () => {
          logRing.clear();
          this.lines = [];
          this.toast('已清空');
        }
      }
    });
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1500 });
    } catch (e) {
      Log.w('Logcat.toast failed: ' + JSON.stringify(e));
    }
  }

  build() {
    Column() {
      Row() {
        Text(`日志（${this.lines.length} 行）`)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(C_TEXT)
        Blank()
        Button('复制')
          .fontSize(13)
          .fontColor(C_TEXT)
          .backgroundColor(C_CARD)
          .onClick(() => {
            this.copyAll();
          })
        Button('清空')
          .fontSize(13)
          .fontColor(C_ERROR)
          .backgroundColor(C_CARD)
          .margin({ left: 8 })
          .onClick(() => {
            this.clearAll();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      Row() {
        Text(this.follow ? '实时跟随：开' : '实时跟随：关')
          .fontSize(12)
          .fontColor(C_TEXT2)
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.follow })
          .selectedColor(C_ACCENT)
          .onChange((v: boolean) => {
            this.follow = v;
            if (v) {
              this.lines = logRing.all();
            }
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })

      if (this.lines.length === 0) {
        Column() {
          Text('暂无日志').fontSize(15).fontColor(C_TEXT2)
          Text('连接服务器或执行延迟测试后，日志会实时出现在这里')
            .fontSize(12)
            .fontColor(C_TEXT2)
            .margin({ top: 6 })
        }
        .width('100%')
        .padding({ top: 40, bottom: 40 })
      } else {
        Scroll() {
          Column() {
            ForEach(this.lines, (line: string, index: number) => {
              Text(line)
                .fontSize(11)
                .fontColor(levelColor(line))
                .width('100%')
                .padding({ top: 1, bottom: 1 })
            }, (line: string, index: number) => `${index}_${line}`)
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 16 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
  }
}
