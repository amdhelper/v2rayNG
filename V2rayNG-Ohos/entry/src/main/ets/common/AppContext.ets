/**
 * Holds the host UIAbility context in AppStorage so that non-UI modules
 * (stores, subscription downloader) can reach `preferences.getPreferences()`
 * without threading a context parameter through every call.
 *
 * EntryAbility calls `setUiAbilityContext(this.context)` in onCreate, BEFORE
 * `profiles.init()` / `settings.load()`, because preferences needs a context.
 */
import common from '@ohos.app.ability.common';
import { Log } from '../util/Log';

const KEY: string = 'v2rayng_UIAbilityContext';

/** Registered by EntryAbility.onCreate(). */
export function setUiAbilityContext(ctx: common.UIAbilityContext): void {
  AppStorage.setOrCreate<common.UIAbilityContext>(KEY, ctx);
}

/**
 * The registered UIAbilityContext.
 * Throws when EntryAbility has not registered yet — callers that run on a
 * timer (subscription refresh) must guard with try/catch.
 */
export function getUiAbilityContext(): common.UIAbilityContext {
  const ctx: common.UIAbilityContext | undefined = AppStorage.get<common.UIAbilityContext>(KEY);
  if (ctx === undefined) {
    Log.e('getUiAbilityContext: context not registered yet (EntryAbility.onCreate)');
    throw new Error('UIAbilityContext is not registered');
  }
  return ctx;
}

/** Non-throwing variant for background work that may run very early. */
export function tryGetUiAbilityContext(): common.UIAbilityContext | null {
  const ctx: common.UIAbilityContext | undefined = AppStorage.get<common.UIAbilityContext>(KEY);
  return ctx === undefined ? null : ctx;
}
