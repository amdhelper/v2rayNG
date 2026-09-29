/**
 * Subscription store — the HarmonyOS counterpart of
 * V2rayNG/app/src/main/java/com/v2ray/ang/handler/SubscriptionUpdater.kt
 * plus the `SubItem` half of MmkvManager.
 *
 * Unlike Android (which schedules a WorkManager PeriodicWorkRequest), the
 * ohos port updates on demand from the UI: the user taps 订阅更新. The payload
 * semantics are kept identical — decode base64-or-plain, parse share links,
 * merge by duplicateIdentity instead of duplicating, prune entries the
 * provider dropped, then dedupe.
 *
 * Android also sends `v2raySubscription` / `Profile-Update-Interval` style
 * headers; only the User-Agent matters for most providers, so that is what we
 * send, plus an `Accept` that asks for text.
 */
import http from '@ohos.net.http';
import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import { profiles, ImportStat, parseBatch } from './ProfileStore';
import { ProfileItem } from './Profile';
import { Log } from '../util/Log';
import buffer from '@ohos.buffer';

const STORE_NAME: string = 'v2rayng_subscriptions';
const KEY_JSON: string = 'json';
const UA: string = 'v2rayNG-ohos/1.0.0';
/** Spec'd download timeout: 15 s. */
const TIMEOUT_MS: number = 15000;

export class SubItem {
  guid: string = '';
  remarks: string = '';
  url: string = '';
  addedTime: number = 0;
  lastUpdated: number = 0;
  autoUpdate: boolean = false;
  enabled: boolean = true;
}

/** Per-subscription outcome of one update() call, surfaced to the UI. */
export class SubUpdateResult {
  guid: string = '';
  remarks: string = '';
  ok: boolean = false;
  added: number = 0;
  updated: number = 0;
  removed: number = 0;
  duplicatesDropped: number = 0;
  error: string = '';
}

function toSubItem(raw: SubItem): SubItem {
  const s: SubItem = new SubItem();
  s.guid = raw.guid ?? '';
  s.remarks = raw.remarks ?? '';
  s.url = raw.url ?? '';
  s.addedTime = raw.addedTime ?? 0;
  s.lastUpdated = raw.lastUpdated ?? 0;
  s.autoUpdate = raw.autoUpdate ?? false;
  s.enabled = raw.enabled ?? true;
  return s;
}

export class SubscriptionStore {
  private subs: SubItem[] = [];
  private prefs: preferences.Preferences | null = null;

  async init(ctx: common.Context): Promise<void> {
    try {
      this.prefs = await preferences.getPreferences(ctx, STORE_NAME);
      const raw: string = this.prefs.getSync(KEY_JSON, '') as string;
      if (raw.length > 0) {
        const parsed: SubItem[] = JSON.parse(raw) as SubItem[];
        this.subs = [];
        for (const item of parsed) {
          if (item !== null && item !== undefined) {
            const s: SubItem = toSubItem(item);
            if (s.guid.length > 0) {
              this.subs.push(s);
            }
          }
        }
      }
      Log.i('SubscriptionStore.init loaded ' + this.subs.length + ' subscriptions');
    } catch (e) {
      Log.e('SubscriptionStore.init failed: ' + JSON.stringify(e));
    }
  }

  list(): SubItem[] {
    return this.subs;
  }

  find(guid: string): SubItem | null {
    for (const s of this.subs) {
      if (s.guid === guid) {
        return s;
      }
    }
    return null;
  }

  async add(name: string, url: string): Promise<string> {
    const s: SubItem = new SubItem();
    s.guid = randomGuid();
    s.remarks = name.trim().length > 0 ? name.trim() : hostOf(url);
    s.url = url.trim();
    s.addedTime = Date.now();
    this.subs.push(s);
    await this.persist();
    Log.i('SubscriptionStore.add ' + s.remarks);
    return s.guid;
  }

  async remove(guid: string): Promise<void> {
    const kept: SubItem[] = [];
    for (const s of this.subs) {
      if (s.guid !== guid) {
        kept.push(s);
      }
    }
    this.subs = kept;
    await this.persist();
  }

  /**
   * Downloads the subscription and merges it into the profile store.
   * Never throws — failures come back as ok=false with `error` set, because
   * this runs from a UI callback.
   */
  async update(guid: string): Promise<SubUpdateResult> {
    const result: SubUpdateResult = new SubUpdateResult();
    const sub: SubItem | null = this.find(guid);
    if (sub === null) {
      result.error = '订阅不存在';
      return result;
    }
    result.guid = sub.guid;
    result.remarks = sub.remarks;

    if (sub.url.length === 0) {
      result.error = '订阅地址为空';
      return result;
    }

    let body: string = '';
    try {
      body = await fetchText(sub.url);
    } catch (e) {
      result.error = '下载失败: ' + describe(e);
      Log.e('SubscriptionStore.update download failed: ' + result.error);
      return result;
    }

    const parsed: ProfileItem[] = parseBatch(body);
    if (parsed.length === 0) {
      result.error = '订阅内容为空或无法解析';
      Log.w('SubscriptionStore.update: empty payload for ' + sub.remarks);
      return result;
    }

    // Remember which identities the provider still serves, so entries that
    // disappeared upstream can be pruned.
    const identities: Set<string> = new Set<string>();
    for (const p of parsed) {
      identities.add(p.duplicateIdentity());
    }

    const stat: ImportStat = await profiles.mergeFromText(body, sub.guid);
    result.added = stat.added;
    result.updated = stat.updated;

    if (sub.autoUpdate) {
      result.removed = await profiles.pruneSubscription(sub.guid, identities);
    }

    result.duplicatesDropped = await profiles.dedupe();

    sub.lastUpdated = Date.now();
    await this.persist();
    result.ok = true;
    Log.i('SubscriptionStore.update ' + sub.remarks + ' added=' + result.added +
      ' updated=' + result.updated + ' removed=' + result.removed);
    return result;
  }

  /** Updates every enabled subscription in order. */
  async updateAll(): Promise<SubUpdateResult[]> {
    const out: SubUpdateResult[] = [];
    for (const s of this.subs) {
      if (s.enabled && s.url.length > 0) {
        out.push(await this.update(s.guid));
      }
    }
    return out;
  }

  private async persist(): Promise<void> {
    if (this.prefs === null) {
      Log.w('SubscriptionStore.persist: init() has not run, changes are memory-only');
      return;
    }
    try {
      await this.prefs.put(KEY_JSON, JSON.stringify(this.subs));
      await this.prefs.flush();
    } catch (e) {
      Log.e('SubscriptionStore.persist failed: ' + JSON.stringify(e));
    }
  }
}

function randomGuid(): string {
  const hex: string = '0123456789abcdef';
  let out: string = '';
  for (let i = 0; i < 32; i++) {
    out += hex.charAt(Math.floor(Math.random() * 16));
  }
  return out;
}

function hostOf(url: string): string {
  const t: string = url.trim();
  const i: number = t.indexOf('://');
  if (i >= 0) {
    const rest: string = t.substring(i + 3);
    const slash: number = rest.indexOf('/');
    const host: string = slash >= 0 ? rest.substring(0, slash) : rest;
    const at: number = host.indexOf('@');
    return at >= 0 ? host.substring(at + 1) : host;
  }
  return t.length > 0 ? t : '订阅';
}

function describe(e: Object): string {
  const text: string = JSON.stringify(e);
  return text.length > 0 && text !== '{}' ? text : String(e);
}

/**
 * One-shot HTTP GET returning the body as text.
 * 15 s read + connect timeout, matching the spec'd behaviour.
 */
async function fetchText(url: string): Promise<string> {
  const request = http.createHttp();
  try {
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: {
        'User-Agent': UA,
        'Accept': 'text/plain, */*'
      },
      readTimeout: TIMEOUT_MS,
      connectTimeout: TIMEOUT_MS,
      expectDataType: http.HttpDataType.STRING,
      usingCache: false
    };
    const response: http.HttpResponse = await request.request(url, options);
    if (response.responseCode !== 200) {
      throw new Error('HTTP ' + response.responseCode);
    }
    const raw: string | Object | ArrayBuffer = response.result;
    if (typeof raw === 'string') {
      return raw;
    }
    if (raw instanceof ArrayBuffer) {
      return buffer.from(raw).toString('utf-8');
    }
    return JSON.stringify(raw);
  } finally {
    request.destroy();
  }
}

export const subscriptions = new SubscriptionStore();
