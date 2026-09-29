import vpnExtension from '@ohos.net.vpnExtension';
import Want from '@ohos.app.ability.Want';
import common from '@ohos.app.ability.common';
import taskpool from '@ohos.taskpool';
import { BusinessError } from '@ohos.base';
import { CoreNative } from './CoreNative';
import { XrayConfigBuilder } from './XrayConfigBuilder';
import { HevTunConfig } from './HevTunConfig';
import { VpnFiles, VpnStartRequest, VpnStatus } from './VpnFiles';
import { settings } from '../model/AppSettings';
import { ProfileItem } from '../model/Profile';
import { profiles } from '../model/ProfileStore';
import { getUiAbilityContext } from '../common/AppContext';
import { measureDelayConcurrent } from './DelayTask';
import { Log } from '../util/Log';

/**
 * UI-process side of the VPN lifecycle — the HarmonyOS counterpart of
 * com.v2ray.ang.core.CoreServiceManager (the start/stop orchestration that
 * Android does over an Intent to CoreVpnService).
 *
 * Everything the extension process needs is written to vpn_request.json
 * first; the extension reads it in onCreate(). State comes back through
 * vpn_status.json, which this class polls.
 *
 * The extension ability name must match entry/src/main/module.json5.
 */
const VPN_ABILITY_NAME = 'V2RayVpnAbility';

export class TrafficStat {
  txBytes: number = 0;
  rxBytes: number = 0;
}

export class ConnectionController {
  private static staleStatus: VpnStatus | null = null;

  static state(): number {
    const st = ConnectionController.readStatus();
    return st === null ? 0 : st.state;
  }

  static isConnected(): boolean {
    return ConnectionController.state() === 2;
  }

  static isBusy(): boolean {
    const s = ConnectionController.state();
    return s === 1;
  }

  static lastError(): string {
    const st = ConnectionController.readStatus();
    if (st === null) {
      return '';
    }
    return st.state === 3 ? st.message : '';
  }

  static statusMessage(): string {
    const st = ConnectionController.readStatus();
    return st === null ? '' : st.message;
  }

  static stats(): TrafficStat {
    const out = new TrafficStat();
    const st = ConnectionController.readStatus();
    if (st !== null) {
      out.txBytes = st.txBytes;
      out.rxBytes = st.rxBytes;
    }
    return out;
  }

  /** Real byte counters straight from the core, resetting them on read. */
  static queryCoreStats(): TrafficStat {
    const out = new TrafficStat();
    const raw = CoreNative.queryAllOutboundTrafficStats();
    if (raw.length === 0) {
      return out;
    }
    // format: tag,direction,value;tag,direction,value;
    for (const entry of raw.split(';')) {
      if (entry.length === 0) {
        continue;
      }
      const parts = entry.split(',');
      if (parts.length !== 3) {
        continue;
      }
      const value = Number.parseInt(parts[2], 10);
      if (parts[1] === 'uplink') {
        out.txBytes += value;
      } else if (parts[1] === 'downlink') {
        out.rxBytes += value;
      }
    }
    return out;
  }

  // -------------------------------------------------------------------------

  static async start(): Promise<boolean> {
    let ctx: common.UIAbilityContext;
    try {
      ctx = getUiAbilityContext();
    } catch (e) {
      Log.e('ConnectionController.start: no UIAbilityContext');
      return false;
    }

    const guid = profiles.selectedGuid();
    const profile: ProfileItem | null = guid.length > 0 ? profiles.get(guid) : null;
    if (profile === null) {
      Log.e('ConnectionController.start: no server selected');
      return false;
    }

    ConnectionController.staleStatus = new VpnStatus();
    ConnectionController.staleStatus.state = 1;
    ConnectionController.staleStatus.message = '正在准备配置…';
    VpnFiles.writeStatus(ctx.filesDir, ConnectionController.staleStatus);

    const req = ConnectionController.buildRequest(ctx, profile);
    VpnFiles.writeRequest(ctx.filesDir, req);

    const want: Want = {
      bundleName: ctx.abilityInfo.bundleName,
      abilityName: VPN_ABILITY_NAME
    };

    try {
      await vpnExtension.startVpnExtensionAbility(want);
      Log.i('ConnectionController: startVpnExtensionAbility dispatched');
    } catch (e) {
      const be = e as BusinessError;
      Log.e('ConnectionController: startVpnExtensionAbility failed ' + be.code + ' ' + be.message);
      ConnectionController.writeError(ctx.filesDir, '无法启动 VPN 扩展: ' + be.code + ' ' + be.message);
      return false;
    }

    const ok = await ConnectionController.waitForState(ctx.filesDir, 2, 20000);
    if (!ok) {
      const st = ConnectionController.readStatus();
      const msg = st !== null ? st.message : '超时';
      Log.e('ConnectionController: connect failed: ' + msg);
    }
    return ok;
  }

  static async stop(): Promise<void> {
    let ctx: common.UIAbilityContext;
    try {
      ctx = getUiAbilityContext();
    } catch (e) {
      Log.e('ConnectionController.stop: no UIAbilityContext');
      return;
    }

    const want: Want = {
      bundleName: ctx.abilityInfo.bundleName,
      abilityName: VPN_ABILITY_NAME
    };
    try {
      await vpnExtension.stopVpnExtensionAbility(want);
      Log.i('ConnectionController: stopVpnExtensionAbility dispatched');
    } catch (e) {
      const be = e as BusinessError;
      Log.w('ConnectionController: stopVpnExtensionAbility failed ' + be.code + ' ' + be.message);
    }

    await ConnectionController.waitForState(ctx.filesDir, 0, 8000);

    // The extension cannot always write a final status (it may be killed with
    // the process), so make sure the UI never stays stuck on "connected".
    const st = ConnectionController.readStatus();
    if (st === null || st.state !== 0) {
      const zero = new VpnStatus();
      zero.state = 0;
      zero.message = '未连接';
      zero.txBytes = st === null ? 0 : st.txBytes;
      zero.rxBytes = st === null ? 0 : st.rxBytes;
      VpnFiles.writeStatus(ctx.filesDir, zero);
    }
  }

  /**
   * Delay-test one server without touching the VPN.
   *
   * The native call blocks for up to `timeoutMs`, so it runs on a taskpool
   * worker: freezing the UI thread for eight seconds is not acceptable.
   */
  static async testDelay(profile: ProfileItem, timeoutMs?: number): Promise<number> {
    const cfg = XrayConfigBuilder.buildOutboundOnly(profile);
    const s = settings.get();
    const url = s.delayTestUrl;
    const t = timeoutMs ?? s.delayTestTimeoutMs;
    try {
      const task = new taskpool.Task(measureDelayConcurrent, cfg, url, t);
      const result = await taskpool.execute(task) as number;
      return result;
    } catch (e) {
      Log.w('testDelay: taskpool unavailable, running inline ' + JSON.stringify(e));
      return CoreNative.measureOutboundDelay(cfg, url, t);
    }
  }

  static readCoreLog(): string {
    try {
      return VpnFiles.readCoreLog(getUiAbilityContext().filesDir);
    } catch (e) {
      return '';
    }
  }

  static clearCoreLog(): void {
    try {
      VpnFiles.clearCoreLog(getUiAbilityContext().filesDir);
    } catch (e) {
      Log.w('clearCoreLog failed: ' + JSON.stringify(e));
    }
  }

  // -------------------------------------------------------------------------

  private static buildRequest(ctx: common.UIAbilityContext, profile: ProfileItem): VpnStartRequest {
    const s = settings.get();
    const req = new VpnStartRequest();
    req.remarks = profile.remarks;
    req.configJson = XrayConfigBuilder.build(profile, false);
    req.hevYaml = HevTunConfig.build(0);
    req.xuKey = s.xuKey;
    req.socksPort = Number.parseInt(s.socksPort, 10);
    req.mtu = s.vpnMtu;
    req.ipv6Enabled = s.ipv6Enabled;
    req.bypassLan = s.bypassLan;
    req.dnsServers = ConnectionController.splitCsv(s.vpnDnsServers);

    // Never tunnel our own traffic: the UI process must stay reachable and the
    // per-app lists must not swallow the app itself.
    const self = ctx.abilityInfo.bundleName;
    const blocked: string[] = [self];
    const trusted: string[] = [];

    if (s.perAppProxyEnabled) {
      const selected = ConnectionController.splitCsv(s.perAppProxySet);
      if (selected.length > 0) {
        if (s.perAppProxyBypass) {
          for (const b of selected) {
            if (blocked.indexOf(b) < 0) {
              blocked.push(b);
            }
          }
        } else {
          for (const b of selected) {
            if (b !== self) {
              trusted.push(b);
            }
          }
        }
      }
    }
    req.blockedApplications = blocked;
    req.trustedApplications = trusted;

    return req;
  }

  private static splitCsv(s: string): string[] {
    const out: string[] = [];
    if (!s) {
      return out;
    }
    for (const part of s.split(',')) {
      const t = part.trim();
      if (t.length > 0) {
        out.push(t);
      }
    }
    return out;
  }

  private static readStatus(): VpnStatus | null {
    try {
      return VpnFiles.readStatus(getUiAbilityContext().filesDir);
    } catch (e) {
      return null;
    }
  }

  private static writeError(filesDir: string, message: string): void {
    const st = new VpnStatus();
    st.state = 3;
    st.message = message;
    VpnFiles.writeStatus(filesDir, st);
  }

  private static async waitForState(filesDir: string, wanted: number, timeoutMs: number): Promise<boolean> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const st = VpnFiles.readStatus(filesDir);
      if (st !== null) {
        if (st.state === wanted) {
          return true;
        }
        if (st.state === 3 && wanted !== 3) {
          return false;
        }
      }
      await ConnectionController.sleep(200);
    }
    return false;
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }
}