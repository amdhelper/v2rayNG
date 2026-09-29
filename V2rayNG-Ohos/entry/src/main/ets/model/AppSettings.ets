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

  /**
   * Mux (multiplexing). Defaults mirror AppConfig.kt exactly
   * (PREF_MUX_ENABLED=false, PREF_MUX_CONCURRENCY="8",
   * PREF_MUX_XUDP_CONCURRENCY="8", PREF_MUX_XUDP_QUIC="reject"), and they stay
   * strings here because that is how upstream stores them — so a settings blob
   * exported from the Android build round-trips without conversion.
   */
  muxEnabled: boolean = false;
  muxConcurrency: string = '8';
  muxXudpConcurrency: string = '8';
  muxXudpProxyUDP443: string = 'reject';

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

  /**
   * Field-by-field merge of a persisted snapshot onto freshly-defaulted data,
   * so a settings file written by an older build still loads. Written out
   * explicitly because ArkTS forbids dynamic property access.
   */
  private static merge(base: AppSettingsData, over: AppSettingsData): AppSettingsData {
    const out = base;
    if (over.vpnMode !== undefined) { out.vpnMode = over.vpnMode; }
    if (over.localProxyEnabled !== undefined) { out.localProxyEnabled = over.localProxyEnabled; }
    if (over.socksPort !== undefined) { out.socksPort = over.socksPort; }
    if (over.httpPort !== undefined) { out.httpPort = over.httpPort; }
    if (over.socksUsername !== undefined) { out.socksUsername = over.socksUsername; }
    if (over.socksPassword !== undefined) { out.socksPassword = over.socksPassword; }
    if (over.vpnMtu !== undefined) { out.vpnMtu = over.vpnMtu; }
    if (over.ipv6Enabled !== undefined) { out.ipv6Enabled = over.ipv6Enabled; }
    if (over.bypassLan !== undefined) { out.bypassLan = over.bypassLan; }
    if (over.appendHttpProxy !== undefined) { out.appendHttpProxy = over.appendHttpProxy; }
    if (over.vpnDnsServers !== undefined) { out.vpnDnsServers = over.vpnDnsServers; }
    if (over.remoteDns !== undefined) { out.remoteDns = over.remoteDns; }
    if (over.localDnsEnabled !== undefined) { out.localDnsEnabled = over.localDnsEnabled; }
    if (over.fakeDnsEnabled !== undefined) { out.fakeDnsEnabled = over.fakeDnsEnabled; }
    if (over.sniffingEnabled !== undefined) { out.sniffingEnabled = over.sniffingEnabled; }
    if (over.routingEnabled !== undefined) { out.routingEnabled = over.routingEnabled; }
    if (over.domainStrategy !== undefined) { out.domainStrategy = over.domainStrategy; }
    if (over.routingPreset !== undefined) { out.routingPreset = over.routingPreset; }
    if (over.perAppProxyEnabled !== undefined) { out.perAppProxyEnabled = over.perAppProxyEnabled; }
    if (over.perAppProxyBypass !== undefined) { out.perAppProxyBypass = over.perAppProxyBypass; }
    if (over.perAppProxySet !== undefined) { out.perAppProxySet = over.perAppProxySet; }
    if (over.muxEnabled !== undefined) { out.muxEnabled = over.muxEnabled; }
    if (over.muxConcurrency !== undefined) { out.muxConcurrency = over.muxConcurrency; }
    if (over.muxXudpConcurrency !== undefined) { out.muxXudpConcurrency = over.muxXudpConcurrency; }
    if (over.muxXudpProxyUDP443 !== undefined) { out.muxXudpProxyUDP443 = over.muxXudpProxyUDP443; }
    if (over.delayTestUrl !== undefined) { out.delayTestUrl = over.delayTestUrl; }
    if (over.delayTestTimeoutMs !== undefined) { out.delayTestTimeoutMs = over.delayTestTimeoutMs; }
    if (over.logLevel !== undefined) { out.logLevel = over.logLevel; }
    if (over.xuKey !== undefined) { out.xuKey = over.xuKey; }
    if (over.currentProfileGuid !== undefined) { out.currentProfileGuid = over.currentProfileGuid; }
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
