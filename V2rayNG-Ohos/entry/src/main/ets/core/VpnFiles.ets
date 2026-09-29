import fs from '@ohos.file.fs';
import buffer from '@ohos.buffer';
import { Log } from '../util/Log';

/**
 * Cross-process handoff between the UI process and the VPN-extension process.
 *
 * On HarmonyOS the VpnExtensionAbility runs in its own process, so the two
 * halves of the port cannot share ArkTS state. They talk through three small
 * files inside the bundle's filesDir, which both processes see:
 *
 *   vpn_request.json  UI -> extension : what to start
 *   vpn_status.json   extension -> UI : state, message, byte counters
 *   vpn_core.log      extension -> UI : the Xray core log trail
 *
 * Start is a file write + `startVpnExtensionAbility`; stop is
 * `stopVpnExtensionAbility`, which lands in V2RayVpnAbility.onDestroy().
 */

export const FILE_REQUEST = 'vpn_request.json';
export const FILE_STATUS = 'vpn_status.json';
export const FILE_CORE_LOG = 'vpn_core.log';

/** UI-process -> extension-process payload. */
export class VpnStartRequest {
  remarks: string = '';
  configJson: string = '';
  hevYaml: string = '';
  xuKey: string = '';
  socksPort: number = 10808;
  mtu: number = 1500;
  ipv6Enabled: boolean = false;
  bypassLan: boolean = true;
  /** bundle names that must bypass the tunnel (always contains our own). */
  blockedApplications: string[] = [];
  /** when non-empty, only these bundle names are tunnelled. */
  trustedApplications: string[] = [];
  dnsServers: string[] = [];
  vpnIpv4Address: string = '172.19.0.1';
  vpnIpv6Address: string = 'fd00:1::1';
}

/** extension-process -> UI-process payload. */
export class VpnStatus {
  /** 0 stopped, 1 starting, 2 connected, 3 error. */
  state: number = 0;
  message: string = '';
  txBytes: number = 0;
  rxBytes: number = 0;
  updatedAt: number = 0;
}

export class VpnFiles {
  private static path(filesDir: string, name: string): string {
    return filesDir + '/' + name;
  }

  private static writeText(filesDir: string, name: string, text: string): void {
    const p = VpnFiles.path(filesDir, name);
    try {
      const f = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, text);
      fs.closeSync(f);
    } catch (e) {
      Log.e('VpnFiles.writeText(' + name + ') failed: ' + JSON.stringify(e));
    }
  }

  private static readText(filesDir: string, name: string): string {
    const p = VpnFiles.path(filesDir, name);
    try {
      if (!fs.accessSync(p)) {
        return '';
      }
      const stat = fs.statSync(p);
      if (stat.size <= 0) {
        return '';
      }
      const f = fs.openSync(p, fs.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(stat.size);
      const n = fs.readSync(f.fd, buf);
      fs.closeSync(f);
      return buffer.from(buf, 0, n).toString('utf-8');
    } catch (e) {
      return '';
    }
  }

  static writeRequest(filesDir: string, req: VpnStartRequest): void {
    VpnFiles.writeText(filesDir, FILE_REQUEST, JSON.stringify(req));
  }

  static readRequest(filesDir: string): VpnStartRequest | null {
    const raw = VpnFiles.readText(filesDir, FILE_REQUEST);
    if (raw.length === 0) {
      return null;
    }
    try {
      return JSON.parse(raw) as VpnStartRequest;
    } catch (e) {
      Log.e('VpnFiles.readRequest parse failed: ' + JSON.stringify(e));
      return null;
    }
  }

  static writeStatus(filesDir: string, st: VpnStatus): void {
    st.updatedAt = Date.now();
    VpnFiles.writeText(filesDir, FILE_STATUS, JSON.stringify(st));
  }

  static readStatus(filesDir: string): VpnStatus | null {
    const raw = VpnFiles.readText(filesDir, FILE_STATUS);
    if (raw.length === 0) {
      return null;
    }
    try {
      return JSON.parse(raw) as VpnStatus;
    } catch (e) {
      return null;
    }
  }

  /** Appends core output, trimming the file when it grows past ~512 KiB. */
  static appendCoreLog(filesDir: string, text: string): void {
    if (text.length === 0) {
      return;
    }
    const p = VpnFiles.path(filesDir, FILE_CORE_LOG);
    try {
      let size = 0;
      if (fs.accessSync(p)) {
        size = fs.statSync(p).size;
      }
      if (size > 512 * 1024) {
        fs.unlinkSync(p);
        size = 0;
      }
      const f = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
      fs.writeSync(f.fd, text);
      fs.closeSync(f);
    } catch (e) {
      Log.e('VpnFiles.appendCoreLog failed: ' + JSON.stringify(e));
    }
  }

  static readCoreLog(filesDir: string): string {
    return VpnFiles.readText(filesDir, FILE_CORE_LOG);
  }

  static clearCoreLog(filesDir: string): void {
    const p = VpnFiles.path(filesDir, FILE_CORE_LOG);
    try {
      if (fs.accessSync(p)) {
        fs.unlinkSync(p);
      }
    } catch (e) {
      Log.w('VpnFiles.clearCoreLog failed: ' + JSON.stringify(e));
    }
  }
}