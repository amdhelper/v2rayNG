import VpnExtensionAbility from '@ohos.app.ability.VpnExtensionAbility';
import vpnExtension from '@ohos.net.vpnExtension';
import connection from '@ohos.net.connection';
import Want from '@ohos.app.ability.Want';
import resourceManager from '@ohos.resourceManager';
import fs from '@ohos.file.fs';
import { BusinessError } from '@ohos.base';
import { CoreNative, CoreState } from '../core/CoreNative';
import { VpnFiles, VpnStartRequest, VpnStatus } from '../core/VpnFiles';
import { Log } from '../util/Log';

/**
 * The VPN extension — the HarmonyOS counterpart of
 * com.v2ray.ang.service.CoreVpnService (Android's VpnService).
 *
 * Data path (identical in spirit to the Android build's "HEV TUN" mode):
 *
 *   app traffic
 *     -> HarmonyOS VPN TUN (fd from vpnExtension.createVpnConnection)
 *     -> libhevsocks5tun.so  (hev-socks5-tunnel, runs on a worker thread)
 *     -> 127.0.0.1:<socksPort>   (Xray's local mixed inbound)
 *     -> libv2rayohos.so     (Xray core, outbound = selected profile)
 *     -> the real server
 *
 * `protectProcessNet()` (API >= 22) is what keeps Xray's own connection to the
 * server out of the tunnel. Without it the server connection is routed back
 * into the TUN and the whole thing loops on itself.
 */

const STATE_STOPPED = 0;
const STATE_STARTING = 1;
const STATE_CONNECTED = 2;
const STATE_ERROR = 3;

/** LAN ranges mirrored from AppConfig.ROUTED_IP_LIST in the Android build. */
const LAN_ROUTES: string[] = [
  '10.0.0.0/8',
  '172.16.0.0/12',
  '192.168.0.0/16',
  '169.254.0.0/16',
  '127.0.0.0/8',
  '224.0.0.0/4',
  '255.255.255.255/32'
];

const GEO_FILES: string[] = ['geoip.dat', 'geosite.dat'];

export default class V2RayVpnAbility extends VpnExtensionAbility {
  private conn: vpnExtension.VpnConnection | null = null;
  private tunFd: number = -1;
  private filesDir: string = '';
  private statusTimer: number = -1;
  private baseUrl: string = '';
  private lastStatus: VpnStatus = new VpnStatus();
  private stopping: boolean = false;

  onCreate(want: Want): void {
    Log.i('V2RayVpnAbility: onCreate');
    this.baseUrl = want.bundleName ?? '';
    this.run().catch((e: Error) => {
      Log.e('V2RayVpnAbility: fatal ' + e.message);
      this.fail('VPN 启动失败: ' + e.message);
    });
  }

  onDestroy(): void {
    Log.i('V2RayVpnAbility: onDestroy');
    this.shutdown();
  }

  // -------------------------------------------------------------------------
  // startup
  // -------------------------------------------------------------------------

  private async run(): Promise<void> {
    const ctx = this.context;
    this.filesDir = ctx.filesDir;

    const req = VpnFiles.readRequest(this.filesDir);
    if (req === null) {
      this.fail('没有待处理的连接请求（vpn_request.json 缺失）');
      return;
    }

    this.publish(STATE_STARTING, '正在部署内核资源…');

    const assetDir = await this.deployGeoData(ctx.resourceManager);

    // INVARIANT: setCoreEnv must run before any Go library is loaded.
    const envOk = CoreNative.setCoreEnv(assetDir, req.xuKey);
    if (!envOk) {
      Log.w('V2RayVpnAbility: setCoreEnv refused (Go core already loaded) — Geo 路由规则可能失效');
    }

    this.publish(STATE_STARTING, '正在创建 VPN 接口…');
    const tunFd = await this.createTun(req);
    if (tunFd < 0) {
      return; // createTun already published the error
    }
    this.tunFd = tunFd;

    // Keep the core's own sockets outside the tunnel.
    await this.protectProcess();

    this.publish(STATE_STARTING, '正在启动 Xray 内核…');
    CoreNative.startLoop(req.configJson);
    const coreOk = await this.waitForCore(15000);
    if (!coreOk) {
      this.fail('Xray 内核启动失败: ' + CoreNative.lastError());
      return;
    }

    this.publish(STATE_STARTING, '正在启动 tun2socks 数据面…');
    const hevRc = CoreNative.hevStart(req.hevYaml, tunFd);
    if (hevRc !== 0) {
      this.fail('tun2socks 启动失败 (code=' + hevRc + ')');
      return;
    }

    this.publish(STATE_CONNECTED, req.remarks.length > 0 ? req.remarks : '已连接');
    this.startTicker();
  }

  /**
   * Copies geoip.dat / geosite.dat out of the HAP's rawfile into the sandbox
   * so XRAY_LOCATION_ASSET can point at a plain directory. Returns the path.
   * Missing data is not fatal — routing then falls back to whatever the config
   * references, and geo-based rules simply match nothing.
   */
  private async deployGeoData(rm: resourceManager.ResourceManager): Promise<string> {
    const dir = this.filesDir + '/geo';
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
    } catch (e) {
      Log.e('deployGeoData: mkdir failed ' + JSON.stringify(e));
      return this.filesDir;
    }

    for (const name of GEO_FILES) {
      const dest = dir + '/' + name;
      try {
        if (fs.accessSync(dest) && fs.statSync(dest).size > 0) {
          continue;
        }
        const bytes: Uint8Array = await rm.getRawFileContent(name);
        const f = fs.openSync(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        fs.writeSync(f.fd, bytes.buffer as ArrayBuffer);
        fs.closeSync(f);
        Log.i('deployGeoData: ' + name + ' -> ' + fs.statSync(dest).size + ' bytes');
      } catch (e) {
        Log.w('deployGeoData: ' + name + ' unavailable (' + JSON.stringify(e) + ')');
      }
    }
    return dir;
  }

  private async createTun(req: VpnStartRequest): Promise<number> {
    const cfg: vpnExtension.VpnConfig = {
      addresses: this.buildAddresses(req),
      routes: this.buildRoutes(req),
      dnsAddresses: req.dnsServers.length > 0 ? req.dnsServers : ['1.1.1.1'],
      mtu: req.mtu > 0 ? req.mtu : 1500,
      isIPv4Accepted: true,
      isIPv6Accepted: req.ipv6Enabled,
      isBlocking: false,
      isInternal: false
    };
    if (req.blockedApplications.length > 0) {
      cfg.blockedApplications = req.blockedApplications;
    }
    if (req.trustedApplications.length > 0) {
      cfg.trustedApplications = req.trustedApplications;
    }

    try {
      this.conn = vpnExtension.createVpnConnection(this.context);
      const fd = await this.conn.create(cfg);
      Log.i('createTun: tun fd = ' + fd);
      return fd;
    } catch (e) {
      const be = e as BusinessError;
      let hint = '';
      if (be.code === 2203001) {
        hint = '（系统未授权 VPN：请在弹窗中允许，或第三方 VPN 需要华为审核后方可上架分发）';
      } else if (be.code === 2203002) {
        hint = '（已有 VPN 连接存在，请先断开）';
      }
      this.fail('创建 VPN 接口失败: ' + be.code + ' ' + be.message + hint);
      return -1;
    }
  }

  private buildAddresses(req: VpnStartRequest): connection.LinkAddress[] {
    const out: connection.LinkAddress[] = [];
    out.push({ address: req.vpnIpv4Address, prefixLength: 30 });
    if (req.ipv6Enabled) {
      out.push({ address: req.vpnIpv6Address, prefixLength: 126 });
    }
    return out;
  }

  private buildRoutes(req: VpnStartRequest): connection.RouteInfo[] {
    const out: connection.RouteInfo[] = [];
    const zero: connection.LinkAddress = { address: '0.0.0.0', prefixLength: 0 };

    if (req.bypassLan) {
      for (const r of LAN_ROUTES) {
        const parts = r.split('/');
        out.push({
          interface: 'vpn-tun',
          destination: { address: parts[0], prefixLength: Number.parseInt(parts[1], 10) },
          gateway: zero,
          hasGateway: false,
          isDefaultRoute: false
        });
      }
    } else {
      out.push({
        interface: 'vpn-tun',
        destination: { address: '0.0.0.0', prefixLength: 0 },
        gateway: zero,
        hasGateway: false,
        isDefaultRoute: true
      });
    }

    if (req.ipv6Enabled) {
      out.push({
        interface: 'vpn-tun',
        destination: { address: '::', prefixLength: 0 },
        gateway: { address: '::', prefixLength: 0 },
        hasGateway: false,
        isDefaultRoute: true
      });
    }
    return out;
  }

  /**
   * protectProcessNet() only exists from API 22. It is reached through an
   * untyped handle on purpose: the project's compatibleSdkVersion is 12, and
   * calling an API-22 member directly would be rejected at build time even
   * though the runtime check below makes it safe.
   */
  private async protectProcess(): Promise<void> {
    if (this.conn === null) {
      return;
    }
    try {
      const handle = this.conn as ESObject;
      const fn = handle.protectProcessNet;
      if (typeof fn !== 'function') {
        Log.w('protectProcess: protectProcessNet unavailable (API < 22). '
          + '服务端连接可能被回灌进隧道，请升级系统或改用全局路由排除。');
        return;
      }
      await (fn.call(handle) as Promise<void>);
      Log.i('protectProcess: all subsequently created sockets bypass the tunnel');
    } catch (e) {
      Log.w('protectProcess failed: ' + JSON.stringify(e));
    }
  }

  private async waitForCore(timeoutMs: number): Promise<boolean> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const st = CoreNative.state();
      if (st === CoreState.RUNNING) {
        return true;
      }
      if (st === CoreState.ERROR) {
        return false;
      }
      await this.sleep(120);
    }
    return CoreNative.state() === CoreState.RUNNING;
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  // -------------------------------------------------------------------------
  // steady state
  // -------------------------------------------------------------------------

  private startTicker(): void {
    this.stopTicker();
    this.statusTimer = setInterval(() => {
      this.tick();
    }, 1000);
  }

  private stopTicker(): void {
    if (this.statusTimer !== -1) {
      clearInterval(this.statusTimer);
      this.statusTimer = -1;
    }
  }

  private tick(): void {
    if (this.stopping) {
      return;
    }
    try {
      const logs = CoreNative.drainLogs();
      if (logs.length > 0) {
        VpnFiles.appendCoreLog(this.filesDir, logs);
        Log.core(logs);
      }

      const st = CoreNative.state();
      if (st === CoreState.ERROR) {
        this.fail('Xray 内核异常退出: ' + CoreNative.lastError());
        return;
      }
      if (st === CoreState.STOPPED) {
        this.fail('Xray 内核已停止');
        return;
      }
      if (!CoreNative.hevRunning()) {
        this.fail('tun2socks 数据面已退出');
        return;
      }

      const stat = this.parseStats(CoreNative.hevStats());
      this.lastStatus.txBytes = stat[0];
      this.lastStatus.rxBytes = stat[1];
      this.lastStatus.state = STATE_CONNECTED;
      VpnFiles.writeStatus(this.filesDir, this.lastStatus);
    } catch (e) {
      Log.e('V2RayVpnAbility.tick failed: ' + JSON.stringify(e));
    }
  }

  private parseStats(json: string): number[] {
    try {
      const o = JSON.parse(json) as Record<string, number>;
      return [o.txBytes ?? 0, o.rxBytes ?? 0];
    } catch (e) {
      return [0, 0];
    }
  }

  private publish(state: number, message: string): void {
    this.lastStatus.state = state;
    this.lastStatus.message = message;
    VpnFiles.writeStatus(this.filesDir, this.lastStatus);
    Log.i('V2RayVpnAbility: state=' + state + ' ' + message);
  }

  private fail(message: string): void {
    Log.e('V2RayVpnAbility: ' + message);
    VpnFiles.appendCoreLog(this.filesDir, '\n[bridge] ' + message + '\n');
    this.shutdown();
    this.publish(STATE_ERROR, message);
  }

  // -------------------------------------------------------------------------
  // teardown
  // -------------------------------------------------------------------------

  private shutdown(_unused?: void): void {
    if (this.stopping) {
      return;
    }
    this.stopping = true;
    this.stopTicker();

    try {
      CoreNative.hevStop();
    } catch (e) {
      Log.w('shutdown: hevStop failed ' + JSON.stringify(e));
    }
    try {
      CoreNative.stopLoop();
    } catch (e) {
      Log.w('shutdown: stopLoop failed ' + JSON.stringify(e));
    }
    if (this.conn !== null) {
      const c = this.conn;
      this.conn = null;
      try {
        c.destroy().then(() => {
          Log.i('shutdown: VPN destroyed');
        }).catch((e: BusinessError) => {
          Log.w('shutdown: destroy failed ' + JSON.stringify(e));
        });
      } catch (e) {
        Log.w('shutdown: destroy threw ' + JSON.stringify(e));
      }
    }
    this.tunFd = -1;
    this.stopping = false;
  }
}