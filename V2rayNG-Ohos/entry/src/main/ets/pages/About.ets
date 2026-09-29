/**
 * 关于页 — 对应安卓版 ui/AboutActivity.kt。
 *
 * 版本号从 AppScope/app.json5 的语义对齐：这里直接读运行时 bundle 信息，
 * 免得两处版本号不同步。深色主题为硬性要求。
 */
import bundleManager from '@ohos.bundle.bundleManager';
import { CoreNative } from '../core/CoreNative';
import { Log } from '../util/Log';

const C_BG: string = '#FF101418';
const C_CARD: string = '#FF1B2026';
const C_TEXT: string = '#FFE8EAED';
const C_TEXT2: string = '#FF9AA0A6';
const C_ACCENT: string = '#FF8AB4F8';

/** 上游项目。GPL-3.0，移植必须保留出处。 */
const UPSTREAM_URL: string = 'https://github.com/2dust/v2rayNG';

@Entry
@Component
struct About {
  @State appVersion: string = '读取中…';
  @State bundleName: string = '';
  @State vendor: string = '';
  @State coreVersion: string = '读取中…';
  @State bridgeAbi: string = '读取中…';

  aboutToAppear(): void {
    this.loadBundleInfo();
    this.loadCoreInfo();
  }

  private async loadBundleInfo(): Promise<void> {
    try {
      const info: bundleManager.BundleInfo =
        await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.appVersion = `${info.versionName} (${info.versionCode})`;
      this.bundleName = info.name;
      this.vendor = info.vendor;
    } catch (e) {
      Log.e('About.loadBundleInfo failed: ' + JSON.stringify(e));
      this.appVersion = '未知';
    }
  }

  /**
   * CoreNative 走的是 dlopen 的原生桥；.so 缺失或未打包时调用会抛，
   * 所以整段包在 try/catch 里，失败时如实显示"不可用"，不假装成功。
   */
  private loadCoreInfo(): void {
    try {
      this.coreVersion = CoreNative.checkVersionX();
    } catch (e) {
      Log.e('About: CoreNative.checkVersionX failed: ' + JSON.stringify(e));
      this.coreVersion = '核心不可用（原生库未加载）';
    }
    try {
      this.bridgeAbi = `ABI v${CoreNative.libVersion()}`;
    } catch (e) {
      Log.e('About: CoreNative.libVersion failed: ' + JSON.stringify(e));
      this.bridgeAbi = '不可用';
    }
  }

  @Builder
  Row2(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontColor(C_TEXT2)
        .width('38%')
      Text(value)
        .fontSize(14)
        .fontColor(C_TEXT)
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
  }

  build() {
    Scroll() {
      Column() {
        Text('v2rayNG for HarmonyOS')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(C_TEXT)
          .width('100%')

        Text('Xray 内核 · 纯血鸿蒙移植版')
          .fontSize(13)
          .fontColor(C_TEXT2)
          .width('100%')
          .margin({ top: 4, bottom: 18 })

        Column() {
          this.Row2('应用版本', this.appVersion)
          this.Row2('包名', this.bundleName)
          this.Row2('发布者', this.vendor)
          this.Row2('Xray 核心', this.coreVersion)
          this.Row2('原生桥', this.bridgeAbi)
        }
        .width('100%')
        .padding(16)
        .backgroundColor(C_CARD)
        .borderRadius(12)

        Text('上游项目')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(C_TEXT)
          .width('100%')
          .margin({ top: 22, bottom: 8 })

        Text(UPSTREAM_URL)
          .fontSize(14)
          .fontColor(C_ACCENT)
          .width('100%')

        Text('本应用是 2dust/v2rayNG 的 HarmonyOS NEXT 移植版，沿用其 GPL-3.0 许可证。' +
          '上游作者与贡献者列表见项目仓库。')
          .fontSize(12)
          .fontColor(C_TEXT2)
          .width('100%')
          .margin({ top: 12 })

        Text('许可证：GNU General Public License v3.0\n' +
          '本软件按 GPL-3.0 发布，无任何担保，且不附带默示担保。')
          .fontSize(12)
          .fontColor(C_TEXT2)
          .width('100%')
          .margin({ top: 12, bottom: 32 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 18, bottom: 18 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
    .scrollBar(BarState.Off)
  }
}