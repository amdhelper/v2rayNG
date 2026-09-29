import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import { Log } from '../util/Log';

/**
 * Settings store — the HarmonyOS counterpart of
 * com.v2ray.ang.handler.SettingsManager / MmkvManager (settings keys only;
 * server entries live in ProfileStore).
 *
 * Backed by @ohos.data.preferences (the platform equivalent of MMKV).
 */
const STORE_NAME = 'v2rayng_settings';

export class AppSettingsData {
  vpnMode: boolean = true;
  localProxyEnabled: boolean = true;

  socksPort: string = '10808';
  httpPort: string = '10809';
  socksUsername: string = '';
  socksPassword: string = '';

  vpnMtu: number = 1500;
  ipv6Enabled: boolean = false;
  bypassLan: boolean = true;
  appendHttpProxy: boolean = false;

  /** Comma separated DNS servers used inside the tunnel. */
  vpnDnsServers: string = '1.1.1.1,8.8.8.8';
  /** Remote DNS for routing/fakedns; empty means "use default". */
  remoteDns: string = '1.1.1.1';
  localDnsEnabled: boolean = true;
  fakeDnsEnabled: boolean = false;
  sniffingEnabled: boolean = true;

  routingEnabled: boolean = true;
  domainStrategy: string = 'IPIfNonMatch';
  /** Routing preset id: 'all' | 'bypass-mainland' | 'bypass-lan' | 'global' | 'custom'. */
  routingPreset: string = 'bypass-mainland';

  perAppProxyEnabled: boolean = false;
  perAppProxyBypass: boolean = false;
  /** bundle names */
  perAppProxySet: string = '';

  delayTestUrl: string = 'https://www.gstatic.com/generate_204';
  delayTestTimeoutMs: number = 8000;
  logLevel: string = 'warning';

  /** Stable per-install key for XUDP; generated on first launch. */
  xuKey: string = '';
  currentProfileGuid: string = '';
}

class Store {
  private data: AppSettingsData = new AppSettingsData();
  private prefs: preferences.Preferences | null = null;

  async load(ctx: common.Context): Promise<AppSettingsData> {
    try {
      this.prefs = await preferences.getPreferences(ctx, STORE_NAME);
      const raw = this.prefs.getSync('json', '') as string;
      if (raw.length > 0) {
        const parsed = JSON.parse(raw) as AppSettingsData;
        this.data = Store.merge(new AppSettingsData(), parsed);
      }
      if (!this.data.xuKey) {
        this.data.xuKey = Store.randomKey();
        await this.save();
      }
    } catch (e) {
      Log.e('AppSettings.load failed: ' + JSON.stringify(e));
    }
    return this.data;
  }

  private static merge(base: AppSettingsData, over: AppSettingsData): AppSettingsData {
    const out = base;
    for (const k of Object.keys(over)) {
      const v = (over as Record<string, ESObject>)[k];
      if (v === undefined || v === null) {
        continue;
      }
      (out as Record<string, ESObject>)[k] = v;
    }
    return out;
  }

  private static randomKey(): string {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    let s = '';
    for (let i = 0; i < 32; i++) {
      s += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return s;
  }

  get(): AppSettingsData {
    return this.data;
  }

  set(mut: (d: AppSettingsData) => void): void {
    mut(this.data);
  }

  async save(): Promise<void> {
    if (this.prefs === null) {
      return;
    }
    try {
      await this.prefs.put('json', JSON.stringify(this.data));
      await this.prefs.flush();
    } catch (e) {
      Log.e('AppSettings.save failed: ' + JSON.stringify(e));
    }
  }
}

export const settings = new Store();
