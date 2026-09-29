/**
 * hev-socks5-tunnel YAML builder — HarmonyOS port of the tun2socks config
 * generation in com.v2ray.ang.service.TProxyService.buildConfig() and
 * com.v2ray.ang.root.RootProxyManager.buildHevConfig().
 *
 * The YAML is consumed by libhevsocks5tun.so -> hev_config_init_from_str()
 * (hev-socks5-tunnel/src/hev-config.c). That reader only understands four
 * top level sections and a fixed set of scalar keys inside each, so nothing
 * here may be invented:
 *
 *   tunnel: name, mtu, multi-queue, ipv4, ipv6, icmp, post-up-script, pre-down-script
 *   socks5: port, address, udp, udp-address, pipeline, username, password, mark, tcp-fastopen
 *   mapdns: address, port, network, netmask, cache-size
 *   misc:   task-stack-size, tcp-buffer-size, udp-recv-buffer-size,
 *           udp-copy-buffer-nums, max-session-count, connect-timeout,
 *           read-write-timeout, tcp-read-write-timeout, udp-read-write-timeout,
 *           pid-file, log-file, log-level, limit-nofile
 *
 * Note that hev_config_parse_* `break`s out of its key loop as soon as it meets
 * a non-scalar node, and silently ignores keys it does not know — so extra keys
 * are harmless but useless, and a missing socks5.port/address is fatal.
 *
 * tun addresses are NOT emitted here: on HarmonyOS NEXT the VpnService
 * extension already owns the tun fd and passes it to hev_socks5_tunnel_main_from_str(),
 * so hev consumes the inherited descriptor instead of creating a device. Only the
 * MTU and the SOCKS5 hop are ours to configure.
 */

import { settings } from '../model/AppSettings';
import { Log } from '../util/Log';

/** hev reads these as base-10 integers via strtoul; keep them unquoted. */
const MTU_MIN: number = 576;
const MTU_MAX: number = 9000;
const MTU_FALLBACK: number = 1500;

export class HevTunConfig {
  /**
   * Returns the hev-socks5-tunnel configuration YAML.
   *
   * `tunFdUnused` is accepted so the call site reads symmetrically with
   * CoreNative.hevStart(configYaml, tunFd); hev receives the real descriptor
   * separately and this builder never needs it.
   */
  static build(tunFdUnused: number): string {
    const s = settings.get();
    const mtu: number = HevTunConfig.clampMtu(s.vpnMtu);
    const port: number = HevTunConfig.socksPort(s.socksPort);
    if (port <= 0) {
      Log.e('HevTunConfig: invalid socks port "' + s.socksPort + '", falling back to 10808');
    }
    const socksPort: number = port > 0 ? port : 10808;

    // Only the loopback SOCKS5 inbound that XrayConfigBuilder.build() opens is
    // reachable from inside the tun, so this address is not user data.
    const lines: string[] = [];
    lines.push('tunnel:');
    lines.push('  mtu: ' + mtu.toString());
    lines.push('socks5:');
    lines.push('  port: ' + socksPort.toString());
    lines.push("  address: '127.0.0.1'");
    lines.push("  udp: 'udp'");
    if (s.socksUsername.length > 0 && s.socksPassword.length > 0) {
      // hev requires BOTH username and password or it aborts at parse time
      // ("Must be set both socks5 username and password!").
      lines.push('  username: ' + HevTunConfig.yamlScalar(s.socksUsername));
      lines.push('  password: ' + HevTunConfig.yamlScalar(s.socksPassword));
    }
    lines.push('misc:');
    // hev_config_parse_doc raises task-stack-size to a computed minimum
    // (TASK_STACK_SIZE + max(tcp_buffer, udp_buffer)) after parsing, so this
    // value is a floor, not a cap.
    lines.push('  task-stack-size: 20480');
    lines.push('  connect-timeout: 5000');
    lines.push('  read-write-timeout: 60000');
    lines.push("  log-file: 'stderr'");
    lines.push("  log-level: 'warn'");
    return lines.join('\n') + '\n';
  }

  private static clampMtu(mtu: number): number {
    if (!Number.isFinite(mtu) || mtu <= 0) {
      return MTU_FALLBACK;
    }
    const n: number = Math.floor(mtu);
    if (n < MTU_MIN || n > MTU_MAX) {
      Log.w('HevTunConfig: mtu ' + n.toString() + ' out of range, using ' + MTU_FALLBACK.toString());
      return MTU_FALLBACK;
    }
    return n;
  }

  private static socksPort(raw: string): number {
    const t: string = (raw ?? '').trim();
    if (t.length === 0) {
      return 0;
    }
    const n: number = parseInt(t, 10);
    if (!Number.isFinite(n) || n <= 0 || n > 65535) {
      return 0;
    }
    return n;
  }

  /**
   * Single-quoted YAML scalar. A single quote is escaped by doubling it, which is
   * the only escape a YAML single-quoted scalar has, so credentials containing
   * quotes, colons or newlines cannot break the document.
   */
  private static yamlScalar(value: string): string {
    return "'" + value.replace(/'/g, "''") + "'";
  }
}
