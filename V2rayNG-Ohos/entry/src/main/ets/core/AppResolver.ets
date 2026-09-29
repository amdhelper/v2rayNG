/**
 * 应用名单的核验。
 *
 * 鸿蒙**不提供**枚举已安装应用的 API，安卓版那种"列出全部应用让用户勾选"的
 * 选择器在纯血鸿蒙上做不到：
 *   - `@ohos.bundle.bundleManager.d.ts` 里只有 `getBundleInfoForSelf()` 和
 *     按包名查的 `getBundleInfo()`，**没有** `getAllBundleInfo()` 这个函数；
 *   - 按名查询需要 `ohos.permission.GET_BUNDLE_INFO`（availableLevel=normal、
 *     system_grant，普通应用声明即有），而枚举全部应用需要
 *     `GET_BUNDLE_INFO_PRIVILEGED` / `ENTERPRISE_GET_ALL_BUNDLE_INFO`
 *     （availableLevel=system_basic，第三方应用拿不到）。
 *
 * 所以名单只能由用户填包名，这里负责逐个核验：查得到=已安装（顺带拿版本号），
 * 查不到就标出来——免得名单里塞一堆拼错的包名，而 VpnConfig 只是静默忽略它们，
 * 用户却以为"分应用代理生效了"。
 */
import bundleManager from '@ohos.bundle.bundleManager';
import { BusinessError } from '@ohos.base';
import { Log } from '../util/Log';

/** 单个包名的核验结果。 */
export enum BundleState {
  FOUND = 0,
  NOT_FOUND = 1,
  NO_PERMISSION = 2,
  UNKNOWN = 3
}

export class BundleCheck {
  bundleName: string = '';
  state: BundleState = BundleState.UNKNOWN;
  /** 已安装时是版本名，其余情况为空。 */
  versionName: string = '';
}

export class AppResolver {
  private static cache: Map<string, BundleCheck> = new Map();

  /** 名单用逗号/分号/空白分隔都认，忽略空项并按首次出现顺序去重。 */
  static splitNames(text: string): string[] {
    const out: string[] = [];
    const parts: string[] = text.split(new RegExp('[\\s,;，；]+'));
    for (const raw of parts) {
      const name: string = raw.trim();
      if (name.length === 0 || out.indexOf(name) >= 0) {
        continue;
      }
      out.push(name);
    }
    return out;
  }

  /**
   * 按包名核验，结果缓存。不向调用方抛异常：查不到就返回 NOT_FOUND /
   * NO_PERMISSION，交给 UI 标注，而不是让设置页崩掉。
   */
  static async check(bundleName: string): Promise<BundleCheck> {
    const cached: BundleCheck | undefined = AppResolver.cache.get(bundleName);
    if (cached !== undefined) {
      return cached;
    }
    const result: BundleCheck = new BundleCheck();
    result.bundleName = bundleName;
    try {
      const info: bundleManager.BundleInfo = await bundleManager.getBundleInfo(
        bundleName, bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      result.state = BundleState.FOUND;
      result.versionName = info.versionName;
    } catch (err) {
      const be = err as BusinessError;
      // 17700001 = bundle not exists；201 = 权限未授予。
      result.state = be.code === 201 ? BundleState.NO_PERMISSION : BundleState.NOT_FOUND;
      Log.w('AppResolver: resolve ' + bundleName + ' failed, code=' + be.code
        + ' message=' + be.message);
    }
    AppResolver.cache.set(bundleName, result);
    return result;
  }

  /** 核验一整串名单，保持输入顺序。 */
  static async checkAll(text: string): Promise<BundleCheck[]> {
    const out: BundleCheck[] = [];
    const names: string[] = AppResolver.splitNames(text);
    for (const name of names) {
      out.push(await AppResolver.check(name));
    }
    return out;
  }

  /** 供 UI 直接使用的一行摘要，例如 "com.example.app（版本 1.2.0）"。 */
  static describe(c: BundleCheck): string {
    if (c.state === BundleState.FOUND) {
      return c.versionName.length > 0 ? '已安装 · 版本 ' + c.versionName : '已安装';
    }
    if (c.state === BundleState.NOT_FOUND) {
      return '未找到这个包名，隧道会忽略它';
    }
    if (c.state === BundleState.NO_PERMISSION) {
      return '无权查询（缺 ohos.permission.GET_BUNDLE_INFO）';
    }
    return '待核验';
  }
}