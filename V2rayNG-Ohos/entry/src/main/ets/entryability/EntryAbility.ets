import UIAbility from '@ohos.app.ability.UIAbility';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import Want from '@ohos.app.ability.Want';
import window from '@ohos.window';
import { BusinessError } from '@ohos.base';
import { setUiAbilityContext } from '../common/AppContext';
import { settings } from '../model/AppSettings';
import { profiles } from '../model/ProfileStore';
import { subscriptions } from '../model/SubscriptionStore';
import { CoreNative } from '../core/CoreNative';
import { Log } from '../util/Log';

/**
 * Application entry — the counterpart of com.v2ray.ang.AngApplication plus
 * ui/MainActivity's launch glue.
 *
 * Besides wiring the two stores it hands the NAPI bridge a hint about where
 * the packaged native libraries live, so libv2rayohos.so / libhevsocks5tun.so
 * can be dlopen'ed by absolute path (the bridge still falls back to a bare
 * soname lookup when the hint is wrong).
 */
export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Log.i('EntryAbility: onCreate');
    setUiAbilityContext(this.context);
    this.bootstrap().catch((e: Error) => {
      Log.e('EntryAbility: bootstrap failed ' + e.message);
    });
  }

  onDestroy(): void {
    Log.i('EntryAbility: onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    CoreNative.setNativeLibDir(this.context.bundleCodeDir + '/libs/arm64');
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        Log.e('EntryAbility: loadContent failed ' + JSON.stringify(err));
        return;
      }
      Log.i('EntryAbility: content loaded');
    });
    try {
      const win = windowStage.getMainWindowSync();
      win.setWindowBackgroundColor('#FF101418');
    } catch (e) {
      Log.w('EntryAbility: setWindowBackgroundColor failed ' + JSON.stringify(e));
    }
  }

  onWindowStageDestroy(): void {
    Log.i('EntryAbility: onWindowStageDestroy');
  }

  onForeground(): void {
    Log.i('EntryAbility: onForeground');
  }

  onBackground(): void {
    Log.i('EntryAbility: onBackground');
  }

  private async bootstrap(): Promise<void> {
    await settings.load(this.context);
    await profiles.init(this.context);
    await subscriptions.init(this.context);
    Log.i('EntryAbility: settings + ' + profiles.all().length + ' profiles loaded');
  }
}
