/**
 * Server profile store — the HarmonyOS counterpart of
 * V2rayNG/app/src/main/java/com/v2ray/ang/handler/MmkvManager.kt
 * (the server-record half: decodeServerList / addServer / removeServer /
 *  decodeSelectServer / encodeSelectServer / removeDuplicateServer).
 *
 * Backed by @ohos.data.preferences (the platform MMKV equivalent), a single
 * JSON array under key 'json' so the on-disk shape stays interchangeable with
 * the Android export format.
 *
 * Delay results are deliberately NOT persisted: a stale delay is worse than
 * no delay, so they live in memory only and are lost on process restart
 * (same as Android, which never stores them either).
 */
import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import { ProfileItem } from './Profile';
import { Fmt } from '../fmt/Fmt';
import { Log } from '../util/Log';

const STORE_NAME: string = 'v2rayng_servers';
const KEY_JSON: string = 'json';
const KEY_SELECTED: string = 'selected';

/** 32-char lower-case hex id, same shape as Android's UUID-without-dashes. */
export function newGuid(): string {
  const hex: string = '0123456789abcdef';
  let out: string = '';
  for (let i = 0; i < 32; i++) {
    out += hex.charAt(Math.floor(Math.random() * 16));
  }
  return out;
}

/** Rehydrates a ProfileItem from parsed JSON, preserving prototype methods. */
function toProfileItem(raw: ProfileItem): ProfileItem {
  const p: ProfileItem = new ProfileItem();
  p.guid = raw.guid ?? '';
  p.configVersion = raw.configVersion ?? 4;
  p.configType = raw.configType ?? 1;
  p.subscriptionId = raw.subscriptionId ?? '';
  p.addedTime = raw.addedTime ?? 0;
  p.remarks = raw.remarks ?? '';
  p.description = raw.description ?? '';
  p.server = raw.server ?? '';
  p.serverPort = raw.serverPort ?? '';
  p.password = raw.password ?? '';
  p.method = raw.method ?? '';
  p.flow = raw.flow ?? '';
  p.username = raw.username ?? '';
  p.network = raw.network ?? '';
  p.headerType = raw.headerType ?? '';
  p.host = raw.host ?? '';
  p.path = raw.path ?? '';
  p.seed = raw.seed ?? '';
  p.kcpMtu = raw.kcpMtu ?? 0;
  p.kcpTti = raw.kcpTti ?? 0;
  p.quicSecurity = raw.quicSecurity ?? '';
  p.quicKey = raw.quicKey ?? '';
  p.mode = raw.mode ?? '';
  p.serviceName = raw.serviceName ?? '';
  p.authority = raw.authority ?? '';
  p.xhttpMode = raw.xhttpMode ?? '';
  p.xhttpExtra = raw.xhttpExtra ?? '';
  p.finalMask = raw.finalMask ?? '';
  p.security = raw.security ?? '';
  p.sni = raw.sni ?? '';
  p.alpn = raw.alpn ?? '';
  p.fingerPrint = raw.fingerPrint ?? '';
  p.insecure = raw.insecure ?? false;
  p.echConfigList = raw.echConfigList ?? '';
  p.verifyPeerCertByName = raw.verifyPeerCertByName ?? '';
  p.pinnedCA256 = raw.pinnedCA256 ?? '';
  p.publicKey = raw.publicKey ?? '';
  p.shortId = raw.shortId ?? '';
  p.spiderX = raw.spiderX ?? '';
  p.mldsa65Verify = raw.mldsa65Verify ?? '';
  p.secretKey = raw.secretKey ?? '';
  p.preSharedKey = raw.preSharedKey ?? '';
  p.localAddress = raw.localAddress ?? '';
  p.reserved = raw.reserved ?? '';
  p.mtu = raw.mtu ?? 0;
  p.remoteDNS = raw.remoteDNS ?? '';
  p.obfsPassword = raw.obfsPassword ?? '';
  p.portHopping = raw.portHopping ?? '';
  p.portHoppingInterval = raw.portHoppingInterval ?? '';
  p.bandwidthDown = raw.bandwidthDown ?? '';
  p.bandwidthUp = raw.bandwidthUp ?? '';
  p.browserDialerMode = raw.browserDialerMode ?? '';
  return p;
}

/**
 * Parses a batch (subscription body, pasted multi-link text, JSON array).
 * Returns [] when nothing could be parsed, so callers can treat 0 as failure.
 */
export function parseBatch(text: string): ProfileItem[] {
  const trimmed: string = (text ?? '').trim();
  if (trimmed.length === 0) {
    return [];
  }
  // A raw JSON array of ProfileItem objects is what our own export produces.
  if (trimmed.startsWith('[')) {
    try {
      const parsed: ProfileItem[] = JSON.parse(trimmed) as ProfileItem[];
      const out: ProfileItem[] = [];
      for (const raw of parsed) {
        if (raw !== null && raw !== undefined && typeof raw.server === 'string') {
          out.push(toProfileItem(raw));
        }
      }
      if (out.length > 0) {
        return out;
      }
    } catch (e) {
      Log.w('ProfileStore.parseBatch: not a JSON array, falling through to share links');
    }
  }
  return Fmt.parseSubscription(trimmed);
}

export class ProfileStore {
  private items: ProfileItem[] = [];
  private selected: string = '';
  /** guid -> delay in ms. -1 = failed. Never persisted. */
  private delays: Map<string, number> = new Map<string, number>();
  private prefs: preferences.Preferences | null = null;

  async init(ctx: common.Context): Promise<void> {
    try {
      this.prefs = await preferences.getPreferences(ctx, STORE_NAME);
      const raw: string = this.prefs.getSync(KEY_JSON, '') as string;
      if (raw.length > 0) {
        const parsed: ProfileItem[] = JSON.parse(raw) as ProfileItem[];
        this.items = [];
        for (const item of parsed) {
          if (item !== null && item !== undefined) {
            const p: ProfileItem = toProfileItem(item);
            if (p.guid.length === 0) {
              p.guid = newGuid();
            }
            this.items.push(p);
          }
        }
      }
      const sel: string = this.prefs.getSync(KEY_SELECTED, '') as string;
      this.selected = this.findGuid(sel);
      Log.i('ProfileStore.init loaded ' + this.items.length + ' servers, selected=' + this.selected);
    } catch (e) {
      Log.e('ProfileStore.init failed: ' + JSON.stringify(e));
    }
  }

  private findGuid(guid: string): string {
    if (guid.length === 0) {
      return '';
    }
    for (const it of this.items) {
      if (it.guid === guid) {
        return guid;
      }
    }
    return '';
  }

  all(): ProfileItem[] {
    return this.items;
  }

  get(guid: string): ProfileItem | null {
    for (const it of this.items) {
      if (it.guid === guid) {
        return it;
      }
    }
    return null;
  }

  selectedGuid(): string {
    return this.selected;
  }

  /** Last measured delay in ms, -1 when the last test failed, 0 when unknown. */
  delayOf(guid: string): number {
    return this.delays.get(guid) ?? 0;
  }

  markDelay(guid: string, ms: number): void {
    this.delays.set(guid, ms);
  }

  async select(guid: string): Promise<void> {
    if (guid.length === 0 || this.findGuid(guid).length === 0) {
      return;
    }
    this.selected = guid;
    await this.persist();
    Log.i('ProfileStore.select ' + guid);
  }

  async upsert(p: ProfileItem): Promise<void> {
    if (p.guid.length === 0) {
      p.guid = newGuid();
    }
    if (p.addedTime <= 0) {
      p.addedTime = Date.now();
    }
    let idx: number = -1;
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].guid === p.guid) {
        idx = i;
        break;
      }
    }
    if (idx >= 0) {
      // Keep the original addedTime so "newest wins" dedupe stays stable.
      if (this.items[idx].addedTime > 0) {
        p.addedTime = this.items[idx].addedTime;
      }
      this.items[idx] = p;
    } else {
      this.items.push(p);
    }
    if (this.selected.length === 0) {
      this.selected = p.guid;
    }
    await this.persist();
  }

  async remove(guid: string): Promise<void> {
    const kept: ProfileItem[] = [];
    for (const it of this.items) {
      if (it.guid !== guid) {
        kept.push(it);
      }
    }
    this.items = kept;
    this.delays.delete(guid);
    if (this.selected === guid) {
      this.selected = this.items.length > 0 ? this.items[0].guid : '';
    }
    await this.persist();
    Log.i('ProfileStore.remove ' + guid);
  }

  /**
   * Removes entries sharing a duplicateIdentity(), keeping the newest one.
   * Mirrors MainViewModel.removeDuplicateServerAsync().
   * Returns how many were dropped.
   */
  async dedupe(): Promise<number> {
    const seen: Map<string, string> = new Map<string, string>(); // identity -> guid kept
    const drop: Set<string> = new Set<string>();
    // Walk newest-first so the survivor is the newest duplicate.
    const ordered: ProfileItem[] = this.items.slice().sort(
      (a: ProfileItem, b: ProfileItem): number => b.addedTime - a.addedTime);
    for (const it of ordered) {
      const identity: string = it.duplicateIdentity();
      const kept: string | undefined = seen.get(identity);
      if (kept === undefined) {
        seen.set(identity, it.guid);
      } else if (kept !== it.guid) {
        drop.add(it.guid);
      }
    }
    if (drop.size === 0) {
      return 0;
    }
    const keptItems: ProfileItem[] = [];
    for (const it of this.items) {
      if (!drop.has(it.guid)) {
        keptItems.push(it);
      }
    }
    this.items = keptItems;
    for (const g of drop) {
      this.delays.delete(g);
    }
    if (drop.has(this.selected)) {
      this.selected = this.items.length > 0 ? this.items[0].guid : '';
    }
    await this.persist();
    Log.i('ProfileStore.dedupe dropped ' + drop.size + ' duplicates');
    return drop.size;
  }

  /**
   * Imports every profile found in `text` under `subscriptionId`
   * ('' for a manual/pasted import).
   * Returns how many entries were parsed & stored.
   */
  async importFromText(text: string, subscriptionId: string): Promise<number> {
    const parsed: ProfileItem[] = parseBatch(text);
    let added: number = 0;
    for (const p of parsed) {
      p.subscriptionId = subscriptionId;
      if (p.addedTime <= 0) {
        p.addedTime = Date.now() + added;
      }
      if (p.guid.length === 0) {
        p.guid = newGuid();
      }
      this.items.push(p);
      added++;
    }
    if (added > 0) {
      await this.persist();
      Log.i('ProfileStore.importFromText stored ' + added + ' profiles for sub=' + subscriptionId);
    }
    return added;
  }

  /**
   * Merges a subscription payload: entries already present (same
   * duplicateIdentity + same subscription) are updated in place instead of
   * being duplicated, which is what MmkvManager's addServer does.
   * Returns {added, updated}.
   */
  async mergeFromText(text: string, subscriptionId: string): Promise<ImportStat> {
    const stat: ImportStat = new ImportStat();
    const parsed: ProfileItem[] = parseBatch(text);
    for (const incoming of parsed) {
      incoming.subscriptionId = subscriptionId;
      const identity: string = incoming.duplicateIdentity();
      let hit: ProfileItem | null = null;
      for (const it of this.items) {
        if (it.subscriptionId === subscriptionId && it.duplicateIdentity() === identity) {
          hit = it;
          break;
        }
      }
      if (hit !== null) {
        const keptGuid: string = hit.guid;
        const keptAdded: number = hit.addedTime;
        // Refresh the mutable connection fields, keep identity + timestamps.
        const merged: ProfileItem = incoming;
        merged.guid = keptGuid;
        merged.addedTime = keptAdded;
        const idx: number = this.items.indexOf(hit);
        this.items[idx] = merged;
        stat.updated++;
      } else {
        incoming.guid = newGuid();
        incoming.addedTime = Date.now() + stat.added;
        this.items.push(incoming);
        stat.added++;
      }
    }
    if (stat.added > 0 || stat.updated > 0) {
      await this.persist();
    }
    Log.i('ProfileStore.mergeFromText sub=' + subscriptionId + ' added=' + stat.added +
      ' updated=' + stat.updated);
    return stat;
  }

  /** Drops every profile that no longer appears in the sub payload. */
  async pruneSubscription(subscriptionId: string, keepIdentities: Set<string>): Promise<number> {
    if (subscriptionId.length === 0) {
      return 0;
    }
    const kept: ProfileItem[] = [];
    let removed: number = 0;
    for (const it of this.items) {
      if (it.subscriptionId === subscriptionId && !keepIdentities.has(it.duplicateIdentity())) {
        removed++;
        this.delays.delete(it.guid);
        continue;
      }
      kept.push(it);
    }
    if (removed > 0) {
      this.items = kept;
      if (this.findGuid(this.selected).length === 0) {
        this.selected = this.items.length > 0 ? this.items[0].guid : '';
      }
      await this.persist();
      Log.i('ProfileStore.pruneSubscription sub=' + subscriptionId + ' removed=' + removed);
    }
    return removed;
  }

  private async persist(): Promise<void> {
    if (this.prefs === null) {
      Log.w('ProfileStore.persist: init() has not run, changes are memory-only');
      return;
    }
    try {
      await this.prefs.put(KEY_JSON, JSON.stringify(this.items));
      await this.prefs.put(KEY_SELECTED, this.selected);
      await this.prefs.flush();
    } catch (e) {
      Log.e('ProfileStore.persist failed: ' + JSON.stringify(e));
    }
  }
}

/** Result of a subscription merge: how many entries were new vs refreshed. */
export class ImportStat {
  added: number = 0;
  updated: number = 0;
}

export const profiles = new ProfileStore();
