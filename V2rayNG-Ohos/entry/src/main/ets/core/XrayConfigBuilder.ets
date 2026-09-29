/**
 * Xray config builder — HarmonyOS port of
 *   V2rayNG/app/src/main/java/com/v2ray/ang/core/CoreOutboundBuilder.kt   (full)
 *   V2rayNG/app/src/main/java/com/v2ray/ang/core/CoreConfigManager.kt    (core parts)
 *   V2rayNG/app/src/main/java/com/v2ray/ang/dto/V2rayConfig.kt           (JSON shape)
 *
 * Every field name below is the *xray-core* JSON schema name, verified against
 * the pinned core in native/libv2ray_ohos/go.mod
 * (github.com/xtls/xray-core v1.260327.1-0.20260728075948-5ca6f4b7d4dc):
 *   infra/conf/xray.go            Config / OutboundDetourConfig / InboundDetourConfig
 *                                 SniffingConfig / MuxConfig / PolicyConfig
 *   infra/conf/transport_internet.go  StreamConfig
 *   infra/conf/transport_method.go    TCPConfig / SplitHTTPConfig / KCPConfig /
 *                                     GRPCConfig / WebSocketConfig /
 *                                     HttpUpgradeConfig / HysteriaConfig / Bandwidth
 *   infra/conf/transport_security.go  TLSConfig / REALITYConfig
 *   infra/conf/transport_finalmask.go FinalMask / QuicParamsConfig / UdpHop / masks
 *   infra/conf/dns.go              DNSConfig / NameServerConfig / HostsWrapper
 *   infra/conf/router.go           RouterConfig / RawFieldRule
 *   infra/conf/vmess.go|vless.go|trojan.go|shadowsocks.go|socks.go|wireguard.go|
 *   hysteria.go                     outbound settings shapes
 *
 * Design rules (ArkTS / HarmonyOS NEXT Stage model):
 *   - no `any`, no dynamic property access, no untyped object literals;
 *   - every JSON node is a declared class with declared fields, so the shape is
 *     checked at compile time;
 *   - `undefined` fields are dropped by JSON.stringify, which is how gson's
 *     default null-omission is reproduced (xray treats a missing key and a null
 *     key identically for every field used here);
 *   - user data is never concatenated into a string; only JSON.stringify touches it.
 */

import { ProfileItem, EConfigType, NetworkType, SecurityType } from '../model/Profile';
import { AppSettingsData, settings } from '../model/AppSettings';
import { Log } from '../util/Log';

// ── AppConfig constants (com.v2ray.ang.AppConfig) ────────────────────────────
const TAG_PROXY: string = 'proxy';
const TAG_DIRECT: string = 'direct';
const TAG_BLOCKED: string = 'block';
const TAG_DNS: string = 'dns-module';
const LOOPBACK: string = '127.0.0.1';
const GEOSITE_PRIVATE: string = 'geosite:private';
const GEOSITE_CN: string = 'geosite:cn';
const GEOIP_PRIVATE: string = 'geoip:private';
const GEOIP_CN: string = 'geoip:cn';
const DEFAULT_LEVEL: number = 8;
const DEFAULT_NETWORK: string = 'tcp';
const HEADER_TYPE_HTTP: string = 'http';
const WIREGUARD_LOCAL_ADDRESS_V4: string = '172.16.0.2/32';
const WIREGUARD_LOCAL_REMOTE_DNS: string = '1.1.1.1,1.0.0.1,2606:4700:4700::1111,2606:4700:4700::1001';
const DNS_PROXY: string = '1.1.1.1';
const DNS_DIRECT: string = '223.5.5.5';
const FAKE_DNS_IP_POOL: string = '198.18.0.0/15';
const FAKE_DNS_POOL_SIZE: number = 10000;
/** the fixed TCP-HTTP camouflage request from CoreOutboundBuilder.createTcpHttpRequest */
const TCP_HTTP_UA: string =
  'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.6478.122 Mobile Safari/537.36';

const IPV4_RE: RegExp = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;
const DOMAIN_RE: RegExp = /^[a-zA-Z0-9]([a-zA-Z0-9\-_]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-_]*[a-zA-Z0-9])?)+$/;

// ═════════════════════════════════════════════════════════════════════════════
//  JSON model — one class per xray schema node
// ═════════════════════════════════════════════════════════════════════════════

/** infra/conf/transport_security.go — TLSConfig and REALITYConfig (shared subset). */
export class TlsSettings {
  allowInsecure?: boolean;
  serverName?: string;
  alpn?: string[];
  fingerprint?: string;
  echConfigList?: string;
  verifyPeerCertByName?: string;
  pinnedPeerCertSha256?: string;
  /** REALITY only. */
  publicKey?: string;
  /** REALITY only. */
  shortId?: string;
  /** REALITY only. */
  spiderX?: string;
  /** REALITY only. */
  mldsa65Verify?: string;
}

/** infra/conf/transport_method.go — AuthenticatorRequest.headers (xray: map[string]*StringList). */
class TcpRequestHeaders {
  'Host'?: string[];
  'User-Agent'?: string[];
  'Accept-Encoding'?: string[];
  'Connection'?: string[];
  'Pragma'?: string;
}

/** infra/conf/transport_method.go — AuthenticatorRequest. */
class TcpRequest {
  version?: string;
  method?: string;
  path?: string[];
  headers?: TcpRequestHeaders;
}

/** infra/conf/transport_method.go — Authenticator.request. */
class TcpHeader {
  type?: string;
  request?: TcpRequest;
}

/** infra/conf/transport_method.go — TCPConfig. */
class TcpSettings {
  header?: TcpHeader;
  acceptProxyProtocol?: boolean;
}

/** infra/conf/transport_method.go — KCPConfig (mtu/tti only; seed+header moved to finalmask). */
class KcpSettings {
  mtu?: number;
  tti?: number;
}

/** infra/conf/transport_method.go — WebSocketConfig. `?ed=N` in path is parsed by xray itself. */
class WsSettings {
  path?: string;
  host?: string;
}

/** infra/conf/transport_method.go — HttpUpgradeConfig. */
class HttpupgradeSettings {
  path?: string;
  host?: string;
}

/**
 * infra/conf/transport_method.go — SplitHTTPConfig. `extra` is a free-form object
 * that xray re-unmarshals into SplitHTTPConfig, so it is passed through verbatim.
 */
class XhttpSettings {
  path?: string;
  host?: string;
  mode?: string;
  extra?: XhttpExtra;
}

/** Free-form XHTTP `extra` payload; re-serialized untouched by JSON.stringify. */
export class XhttpExtra {
  scMaxEachPostBytes?: string;
  noGRPCHeader?: boolean;
  xPaddingBytes?: string;
}

/** infra/conf/transport_method.go — the removed H2 transport shape, kept for parity. */
class HttpSettings {
  host?: string[];
  path?: string;
}

/** infra/conf/transport_method.go — the removed QUIC transport shape, kept for parity. */
class QuicHeader {
  type?: string;
}

/** The removed QUIC transport shape, kept for parity. */
class QuicSettings {
  security?: string;
  key?: string;
  header?: QuicHeader;
}

/** infra/conf/transport_method.go — GRPCConfig. */
class GrpcSettings {
  serviceName?: string;
  authority?: string;
  multiMode?: boolean;
  idle_timeout?: number;
  health_check_timeout?: number;
}

/** infra/conf/transport_method.go — HysteriaConfig. */
class HysteriaSettings {
  version?: number;
  auth?: string;
}

/** infra/conf/transport_finalmask.go — UdpHop. */
class UdpHop {
  ports?: string;
  interval?: string;
}

/** infra/conf/transport_finalmask.go — QuicParamsConfig. */
class QuicParams {
  congestion?: string;
  brutalUp?: string;
  brutalDown?: string;
  udpHop?: UdpHop;
}

/** infra/conf/transport_finalmask.go — NoiseItem. */
class NoiseItem {
  rand?: string;
  delay?: string;
}

/** infra/conf/transport_finalmask.go — Mask settings, union of every mask this port emits. */
class MaskSettings {
  /** salamander */
  password?: string;
  /** mkcp-legacy */
  header?: string;
  /** mkcp-legacy (aes128gcm seed / dns domain) */
  value?: string;
  /** fragment */
  packets?: string;
  /** fragment */
  length?: string;
  /** fragment */
  delay?: string;
  /** fragment */
  maxSplit?: string;
  /** noise */
  reset?: number;
  /** noise */
  noise?: NoiseItem[];
}

/** infra/conf/transport_finalmask.go — Mask. */
class Mask {
  type?: string;
  settings?: MaskSettings;
}

/** infra/conf/transport_finalmask.go — FinalMask. */
class FinalMask {
  tcp?: Mask[];
  udp?: Mask[];
  quicParams?: QuicParams;
}

/** infra/conf/transport_internet.go — StreamConfig. */
class StreamSettings {
  network?: string;
  security?: string;
  tcpSettings?: TcpSettings;
  kcpSettings?: KcpSettings;
  wsSettings?: WsSettings;
  httpupgradeSettings?: HttpupgradeSettings;
  xhttpSettings?: XhttpSettings;
  httpSettings?: HttpSettings;
  quicSettings?: QuicSettings;
  grpcSettings?: GrpcSettings;
  hysteriaSettings?: HysteriaSettings;
  tlsSettings?: TlsSettings;
  realitySettings?: TlsSettings;
  finalmask?: FinalMask;
}

/** infra/conf/vmess.go etc. — outbound settings for every protocol but WireGuard. */
class OutSettings {
  address?: string;
  port?: number;
  level?: number;
  /** socks / http */
  user?: string;
  /** socks / http */
  pass?: string;
  /** vmess */
  id?: string;
  /** vmess cipher */
  security?: string;
  /** vless */
  encryption?: string;
  /** vless + trojan */
  flow?: string;
  /** trojan + shadowsocks */
  password?: string;
  /** shadowsocks */
  method?: string;
  /** hysteria2 */
  version?: number;
}

/** infra/conf/wireguard.go — WireGuardPeerConfig. */
class WireGuardPeer {
  publicKey?: string;
  preSharedKey?: string;
  endpoint?: string;
}

/** infra/conf/wireguard.go — WireGuardConfig (client). */
class WireGuardSettings {
  secretKey?: string;
  address?: string[];
  peers?: WireGuardPeer[];
  mtu?: number;
  reserved?: number[];
  /**
   * Present in the Android OutSettingsBean and populated from ProfileItem.remoteDNS.
   * This xray revision's WireGuardConfig has no `remoteDNS` field, so the core
   * ignores it (encoding/json drops unknown keys). Emitted anyway to keep the
   * port faithful and so the value survives for a future core that honours it.
   */
  remoteDNS?: string[];
}

/** infra/conf/xray.go — MuxConfig. */
class Mux {
  enabled?: boolean;
  concurrency?: number;
  xudpConcurrency?: number;
  xudpProxyUDP443?: string;
}

/** infra/conf/xray.go — OutboundDetourConfig. */
class Outbound {
  tag?: string;
  protocol?: string;
  settings?: OutSettings | WireGuardSettings | FreedomSettings | BlackholeSettings;
  streamSettings?: StreamSettings;
  mux?: Mux;
  sendThrough?: string;
}

/** infra/conf/freedom.go — FreedomConfig (the `direct` outbound). */
class FreedomSettings {
  domainStrategy?: string;
}

class BlackholeResponse {
  type?: string;
}

class BlackholeSettings {
  response?: BlackholeResponse;
}

/** infra/conf/xray.go — LogConfig. */
class LogConfig {
  loglevel?: string;
  error?: string;
}

/** infra/conf/xray.go — StatsConfig (an empty struct). */
class StatsConfig {
}

/** infra/conf/policy.go — Policy. */
class PolicyLevel {
  handshake?: number;
  connIdle?: number;
  uplinkOnly?: number;
  downlinkOnly?: number;
  statsUserUplink?: boolean;
  statsUserDownlink?: boolean;
  bufferSize?: number;
}

/**
 * infra/conf/policy.go — PolicyConfig.levels (map[uint32]*Policy), JSON-encoded as
 * an object keyed by the decimal level. "0" is the contract level; "8" mirrors
 * AppConfig.DEFAULT_LEVEL, which is what CoreOutboundBuilder stamps into every
 * outbound's settings.level — without it that level would have no policy at all.
 */
class PolicyLevels {
  '0'?: PolicyLevel;
  '8'?: PolicyLevel;
}

/** infra/conf/policy.go — SystemPolicy. */
class SystemPolicy {
  statsInboundUplink?: boolean;
  statsInboundDownlink?: boolean;
  statsOutboundUplink?: boolean;
  statsOutboundDownlink?: boolean;
}

/** infra/conf/policy.go — PolicyConfig. */
class PolicyConfig {
  levels?: PolicyLevels;
  system?: SystemPolicy;
}

/** infra/conf/socks.go — SocksAccount. */
class SocksAccount {
  user?: string;
  pass?: string;
}

/** infra/conf/xray.go — SocksServerConfig. */
class InboundSettings {
  auth?: string;
  udp?: boolean;
  userLevel?: number;
  accounts?: SocksAccount[];
}

/** infra/conf/xray.go — SniffingConfig. */
class Sniffing {
  enabled?: boolean;
  destOverride?: string[];
  routeOnly?: boolean;
}

/** infra/conf/xray.go — InboundDetourConfig. */
class Inbound {
  tag?: string;
  listen?: string;
  port?: number;
  protocol?: string;
  settings?: InboundSettings;
  sniffing?: Sniffing;
}

/** infra/conf/dns.go — NameServerConfig. */
class DnsServer {
  address?: string;
  port?: number;
  domains?: string[];
  expectIPs?: string[];
  skipFallback?: boolean;
  tag?: string;
}

/** infra/conf/fakedns.go — FakeDNSPoolElementConfig. */
class FakeDnsPool {
  ipPool?: string;
  poolSize?: number;
}

/** infra/conf/dns.go — DNSConfig. */
class DnsConfig {
  servers?: DnsServer[];
  tag?: string;
  queryStrategy?: string;
  enableParallelQuery?: boolean;
}

/** infra/conf/router.go — RawFieldRule. */
class RoutingRule {
  type?: string;
  ip?: string[];
  domain?: string[];
  port?: string;
  network?: string;
  inboundTag?: string[];
  outboundTag?: string;
  balancerTag?: string;
  process?: string[];
  protocol?: string[];
  attrs?: string;
  domainMatcher?: string;
}

/** infra/conf/router.go — RouterConfig. */
class Routing {
  domainStrategy?: string;
  domainMatcher?: string;
  rules?: RoutingRule[];
}

/** infra/conf/xray.go — Config. */
class XrayConfig {
  log?: LogConfig;
  stats?: StatsConfig;
  policy?: PolicyConfig;
  inbounds?: Inbound[];
  outbounds?: Outbound[];
  dns?: DnsConfig;
  routing?: Routing;
  fakeDns?: FakeDnsPool;
}

// ═════════════════════════════════════════════════════════════════════════════
//  XrayConfigBuilder
// ═════════════════════════════════════════════════════════════════════════════

export class XrayConfigBuilder {
  // ── small helpers (com.v2ray.ang.util.Utils) ──────────────────────────────

  private static isIpv4(v: string): boolean {
    const m: RegExpMatchArray | null = v.match(IPV4_RE);
    if (m === null) {
      return false;
    }
    for (let i = 1; i <= 4; i++) {
      const n: number = parseInt(m[i], 10);
      if (n > 255) {
        return false;
      }
    }
    return true;
  }

  private static isIpv6(v: string): boolean {
    if (v.indexOf(':') < 0) {
      return false;
    }
    return /^[0-9a-fA-F:.]+$/.test(v);
  }

  /** Utils.isPureIpAddress */
  private static isPureIpAddress(v: string): boolean {
    return XrayConfigBuilder.isIpv4(v) || XrayConfigBuilder.isIpv6(v);
  }

  /**
   * Utils.isDomainName. The Android original defers to Patterns.WEB_URL; a
   * hostname-shape check is the closest ArkTS equivalent.
   */
  private static isDomainName(v: string): boolean {
    if (v.length === 0 || XrayConfigBuilder.isPureIpAddress(v)) {
      return false;
    }
    return v.length <= 253 && DOMAIN_RE.test(v);
  }

  /** Utils.getIpv6Address — brackets a bare IPv6 literal for use in host:port. */
  private static ipv6Host(v: string): string {
    if (v.length > 0 && XrayConfigBuilder.isIpv6(v) && !v.includes('[') && !v.includes(']')) {
      return '[' + v + ']';
    }
    return v;
  }

  private static csv(raw: string): string[] {
    const out: string[] = [];
    for (const part of (raw ?? '').split(',')) {
      const t: string = part.trim();
      if (t.length > 0) {
        out.push(t);
      }
    }
    return out;
  }

  private static csvTrim(raw: string): string[] {
    return XrayConfigBuilder.csv(raw);
  }

  private static toInt(raw: string, fallback: number): number {
    const t: string = (raw ?? '').trim();
    if (t.length === 0) {
      return fallback;
    }
    const n: number = parseInt(t, 10);
    return Number.isFinite(n) ? n : fallback;
  }

  private static orNull(v: string): string | undefined {
    const t: string = (v ?? '').trim();
    return t.length > 0 ? t : undefined;
  }

  private static firstOr(arr: string[], fallback: string): string {
    return arr.length > 0 ? arr[0] : fallback;
  }

  // ── protocol entry point (CoreOutboundBuilder.convert) ───────────────────

  /**
   * Builds the `outbounds[]` element for one profile.
   *
   * Returns an empty string for config types this port does not model (CUSTOM and
   * ANYTLS). CoreOutboundBuilder returns null for those and CoreConfigManager
   * skips the entry; an empty string is this port's equivalent, and callers must
   * drop it. Emitting a placeholder outbound with an empty "protocol" instead
   * would make the whole config fail to load, because xray rejects the entire
   * outbounds array when any element has an unknown protocol.
   */
  static buildOutboundJson(profile: ProfileItem): string {
    const ob: Outbound | undefined = XrayConfigBuilder.buildOutbound(profile);
    if (ob === undefined) {
      return '';
    }
    return JSON.stringify(ob);
  }

  private static buildOutbound(profile: ProfileItem): Outbound | undefined {
    const ob: Outbound = new Outbound();
    ob.tag = TAG_PROXY;
    switch (profile.configType) {
      case EConfigType.VMESS:
        XrayConfigBuilder.outVmess(profile, ob);
        break;
      case EConfigType.VLESS:
        XrayConfigBuilder.outVless(profile, ob);
        break;
      case EConfigType.SHADOWSOCKS:
        XrayConfigBuilder.outShadowsocks(profile, ob);
        break;
      case EConfigType.TROJAN:
        XrayConfigBuilder.outTrojan(profile, ob);
        break;
      case EConfigType.SOCKS:
        XrayConfigBuilder.outSocks(profile, ob);
        break;
      case EConfigType.HTTP:
        XrayConfigBuilder.outHttp(profile, ob);
        break;
      case EConfigType.HYSTERIA2:
        XrayConfigBuilder.outHysteria2(profile, ob);
        break;
      case EConfigType.WIREGUARD:
        XrayConfigBuilder.outWireguard(profile, ob);
        break;
      default:
        Log.w('XrayConfigBuilder: no outbound builder for configType ' + profile.configType.toString() +
          '; the proxy outbound will be omitted');
        return undefined;
    }
    XrayConfigBuilder.applyGlobalOutboundSettings(ob);
    return ob;
  }

  private static outVmess(p: ProfileItem, ob: Outbound): void {
    const s: OutSettings = new OutSettings();
    s.address = XrayConfigBuilder.getServerAddress(p);
    s.port = XrayConfigBuilder.toInt(p.serverPort, 0);
    s.id = p.password ?? '';
    s.security = p.method;
    s.level = DEFAULT_LEVEL;
    ob.protocol = 'vmess';
    ob.settings = s;
    const sni: string | undefined = XrayConfigBuilder.populateTransportSettings(ob, p);
    XrayConfigBuilder.populateTlsSettings(ob, p, sni);
  }

  private static outVless(p: ProfileItem, ob: Outbound): void {
    const s: OutSettings = new OutSettings();
    s.address = XrayConfigBuilder.getServerAddress(p);
    s.port = XrayConfigBuilder.toInt(p.serverPort, 0);
    s.id = p.password ?? '';
    s.encryption = p.method;
    s.flow = p.flow;
    s.level = DEFAULT_LEVEL;
    ob.protocol = 'vless';
    ob.settings = s;
    const sni: string | undefined = XrayConfigBuilder.populateTransportSettings(ob, p);
    XrayConfigBuilder.populateTlsSettings(ob, p, sni);
  }

  private static outShadowsocks(p: ProfileItem, ob: Outbound): void {
    const s: OutSettings = new OutSettings();
    s.address = XrayConfigBuilder.getServerAddress(p);
    s.port = XrayConfigBuilder.toInt(p.serverPort, 0);
    s.password = p.password;
    s.method = p.method;
    s.level = DEFAULT_LEVEL;
    ob.protocol = 'shadowsocks';
    ob.settings = s;
    const sni: string | undefined = XrayConfigBuilder.populateTransportSettings(ob, p);
    XrayConfigBuilder.populateTlsSettings(ob, p, sni);
  }

  private static outTrojan(p: ProfileItem, ob: Outbound): void {
    const s: OutSettings = new OutSettings();
    s.address = XrayConfigBuilder.getServerAddress(p);
    s.port = XrayConfigBuilder.toInt(p.serverPort, 0);
    s.password = p.password;
    s.flow = p.flow;
    s.level = DEFAULT_LEVEL;
    ob.protocol = 'trojan';
    ob.settings = s;
    const sni: string | undefined = XrayConfigBuilder.populateTransportSettings(ob, p);
    XrayConfigBuilder.populateTlsSettings(ob, p, sni);
  }

  private static outSocks(p: ProfileItem, ob: Outbound): void {
    const s: OutSettings = new OutSettings();
    s.address = XrayConfigBuilder.getServerAddress(p);
    s.port = XrayConfigBuilder.toInt(p.serverPort, 0);
    s.level = DEFAULT_LEVEL;
    if (p.username.length > 0) {
      s.user = p.username;
      s.pass = p.password ?? '';
    }
    ob.protocol = 'socks';
    ob.settings = s;
  }

  private static outHttp(p: ProfileItem, ob: Outbound): void {
    const s: OutSettings = new OutSettings();
    s.address = XrayConfigBuilder.getServerAddress(p);
    s.port = XrayConfigBuilder.toInt(p.serverPort, 0);
    s.level = DEFAULT_LEVEL;
    if (p.username.length > 0) {
      s.user = p.username;
      s.pass = p.password ?? '';
    }
    ob.protocol = 'http';
    ob.settings = s;
  }

  private static outHysteria2(p: ProfileItem, ob: Outbound): void {
    // CoreOutboundBuilder.toOutboundHysteria2 mutates the profile (network=hysteria,
    // alpn=h3). Mutating the caller's ProfileItem here would corrupt the stored
    // entry, so the overrides are threaded through local copies instead.
    const forced: ProfileItem = XrayConfigBuilder.withNetwork(p, 'hysteria');
    const forcedAlpn: ProfileItem = XrayConfigBuilder.withAlpn(forced, 'h3');

    const s: OutSettings = new OutSettings();
    s.address = XrayConfigBuilder.getServerAddress(forcedAlpn);
    s.port = XrayConfigBuilder.toInt(forcedAlpn.serverPort, 0);
    s.version = 2;
    ob.protocol = 'hysteria';
    ob.settings = s;
    const sni: string | undefined = XrayConfigBuilder.populateTransportSettings(ob, forcedAlpn);
    XrayConfigBuilder.populateTlsSettings(ob, forcedAlpn, sni);
  }

  private static outWireguard(p: ProfileItem, ob: Outbound): void {
    const s: WireGuardSettings = new WireGuardSettings();
    const cfg: AppSettingsData = settings.get();

    let addresses: string[] = XrayConfigBuilder.csvTrim(p.localAddress);
    if (addresses.length === 0) {
      addresses = [WIREGUARD_LOCAL_ADDRESS_V4];
    }
    if (!cfg.ipv6Enabled) {
      const v4: string[] = addresses.filter((a: string) => !a.includes(':'));
      addresses = v4.length > 0 ? v4 : [WIREGUARD_LOCAL_ADDRESS_V4];
    }

    let remotes: string[] = XrayConfigBuilder.csvTrim(p.remoteDNS);
    if (remotes.length === 0) {
      remotes = XrayConfigBuilder.csvTrim(WIREGUARD_LOCAL_REMOTE_DNS);
    }
    if (remotes.length === 1 && remotes[0] === 'local') {
      // literal "local" sentinel: keep as-is
    } else if (cfg.ipv6Enabled) {
      // keep all
    } else {
      const v4: string[] = remotes.filter((a: string) => !a.includes(':'));
      remotes = v4.length > 0 ? v4 : [DNS_PROXY];
    }

    s.secretKey = p.secretKey;
    s.address = addresses;
    const peer: WireGuardPeer = new WireGuardPeer();
    peer.publicKey = p.publicKey ?? '';
    peer.preSharedKey = XrayConfigBuilder.orNull(p.preSharedKey);
    peer.endpoint = XrayConfigBuilder.ipv6Host(p.server) + ':' + p.serverPort;
    s.peers = [peer];
    s.mtu = p.mtu;
    s.remoteDNS = remotes;
    if (p.reserved.trim().length > 0) {
      const reserved: number[] = [];
      for (const part of p.reserved.split(',')) {
        const t: string = part.trim();
        if (t.length > 0) {
          const n: number = parseInt(t, 10);
          if (Number.isFinite(n)) {
            reserved.push(n);
          }
        }
      }
      if (reserved.length > 0) {
        s.reserved = reserved;
      }
    }

    ob.protocol = 'wireguard';
    ob.settings = s;

    if (p.finalMask.trim().length > 0) {
      const stream: StreamSettings = new StreamSettings();
      const mask: FinalMask | undefined = XrayConfigBuilder.parseFinalMask(p.finalMask);
      if (mask !== undefined) {
        stream.finalmask = mask;
        ob.streamSettings = stream;
      } else {
        Log.w('XrayConfigBuilder: invalid finalMask JSON, keeping previously generated finalmask');
      }
    }
  }

  private static withNetwork(p: ProfileItem, network: string): ProfileItem {
    const c: ProfileItem = XrayConfigBuilder.copyProfile(p);
    c.network = network;
    return c;
  }

  private static withAlpn(p: ProfileItem, alpn: string): ProfileItem {
    const c: ProfileItem = XrayConfigBuilder.copyProfile(p);
    c.alpn = alpn;
    return c;
  }

  private static copyProfile(p: ProfileItem): ProfileItem {
    const c: ProfileItem = new ProfileItem();
    c.guid = p.guid;
    c.configVersion = p.configVersion;
    c.configType = p.configType;
    c.subscriptionId = p.subscriptionId;
    c.addedTime = p.addedTime;
    c.remarks = p.remarks;
    c.description = p.description;
    c.server = p.server;
    c.serverPort = p.serverPort;
    c.password = p.password;
    c.method = p.method;
    c.flow = p.flow;
    c.username = p.username;
    c.network = p.network;
    c.headerType = p.headerType;
    c.host = p.host;
    c.path = p.path;
    c.seed = p.seed;
    c.kcpMtu = p.kcpMtu;
    c.kcpTti = p.kcpTti;
    c.quicSecurity = p.quicSecurity;
    c.quicKey = p.quicKey;
    c.mode = p.mode;
    c.serviceName = p.serviceName;
    c.authority = p.authority;
    c.xhttpMode = p.xhttpMode;
    c.xhttpExtra = p.xhttpExtra;
    c.finalMask = p.finalMask;
    c.security = p.security;
    c.sni = p.sni;
    c.alpn = p.alpn;
    c.fingerPrint = p.fingerPrint;
    c.insecure = p.insecure;
    c.echConfigList = p.echConfigList;
    c.verifyPeerCertByName = p.verifyPeerCertByName;
    c.pinnedCA256 = p.pinnedCA256;
    c.publicKey = p.publicKey;
    c.shortId = p.shortId;
    c.spiderX = p.spiderX;
    c.mldsa65Verify = p.mldsa65Verify;
    c.secretKey = p.secretKey;
    c.preSharedKey = p.preSharedKey;
    c.localAddress = p.localAddress;
    c.reserved = p.reserved;
    c.mtu = p.mtu;
    c.remoteDNS = p.remoteDNS;
    c.obfsPassword = p.obfsPassword;
    c.portHopping = p.portHopping;
    c.portHoppingInterval = p.portHoppingInterval;
    c.bandwidthDown = p.bandwidthDown;
    c.bandwidthUp = p.bandwidthUp;
    c.browserDialerMode = p.browserDialerMode;
    return c;
  }

  // ── global outbound options (updateOutboundWithGlobalSettings) ────────────

  private static applyGlobalOutboundSettings(ob: Outbound): void {
    const mux: Mux = new Mux();
    // AppSettingsData has no muxEnabled/muxConcurrency/xudpConcurrency/
    // xudpProxyUDP443 field, so the AppConfig defaults are used verbatim:
    // PREF_MUX_ENABLED=false, PREF_MUX_CONCURRENCY="8",
    // DEFAULT_MUX_XUDP_CONCURRENCY="8", PREF_MUX_XUDP_QUIC="reject".
    // Mux stays off, exactly as it is on a stock Android install.
    const MUX_ENABLED: boolean = false;
    const MUX_CONCURRENCY: number = 8;
    const MUX_XUDP_CONCURRENCY: number = 8;
    const MUX_XUDP_QUIC: string = 'reject';

    let muxEnabled: boolean = MUX_ENABLED;
    const protocol: string = (ob.protocol ?? '').toLowerCase();
    if (protocol === 'shadowsocks' || protocol === 'socks' || protocol === 'http' ||
      protocol === 'trojan' || protocol === 'wireguard' || protocol === 'hysteria') {
      muxEnabled = false;
    } else if (ob.streamSettings !== undefined && ob.streamSettings.network === NetworkType.XHTTP) {
      muxEnabled = false;
    }

    if (muxEnabled) {
      mux.enabled = true;
      mux.concurrency = MUX_CONCURRENCY;
      mux.xudpConcurrency = MUX_XUDP_CONCURRENCY;
      mux.xudpProxyUDP443 = MUX_XUDP_QUIC;
      if (protocol === 'vless') {
        const s: OutSettings | undefined = ob.settings as OutSettings | undefined;
        if (s !== undefined && s.flow !== undefined && s.flow.length > 0) {
          mux.concurrency = -1;
        }
      }
    } else {
      // Concurrency < 0 is how xray disables multiplexing entirely
      // (infra/conf/xray.go MuxConfig.Build).
      mux.enabled = false;
      mux.concurrency = -1;
    }
    ob.mux = mux;
  }

  // ── transport (populateTransportSettings) ─────────────────────────────────

  /** Returns the SNI hint the transport layer derived, or undefined. */
  private static populateTransportSettings(ob: Outbound, p: ProfileItem): string | undefined {
    const stream: StreamSettings = ob.streamSettings !== undefined ? ob.streamSettings : new StreamSettings();
    ob.streamSettings = stream;

    const transport: string = p.network.length > 0 ? p.network : DEFAULT_NETWORK;
    stream.network = transport;
    let sni: string | undefined;

    if (transport === NetworkType.TCP) {
      const tcp: TcpSettings = new TcpSettings();
      const header: TcpHeader = new TcpHeader();
      if (p.headerType === HEADER_TYPE_HTTP) {
        header.type = HEADER_TYPE_HTTP;
        const req: TcpRequest = XrayConfigBuilder.createTcpHttpRequest(p.host, p.path);
        header.request = req;
        const reqHeaders: TcpRequestHeaders | undefined = req.headers;
        if (reqHeaders !== undefined && reqHeaders.Host !== undefined) {
          const h: string[] = reqHeaders.Host;
          sni = h.length > 0 ? h[0] : undefined;
        }
      } else {
        header.type = 'none';
        sni = p.host.length > 0 ? p.host : undefined;
      }
      tcp.header = header;
      stream.tcpSettings = tcp;

    } else if (transport === NetworkType.KCP) {
      const kcp: KcpSettings = new KcpSettings();
      if (p.kcpMtu > 0) {
        kcp.mtu = p.kcpMtu;
      }
      if (p.kcpTti > 0) {
        kcp.tti = p.kcpTti;
      }
      stream.kcpSettings = kcp;

      // seed + header live in finalmask.udp as "mkcp-legacy" masks; the seed mask
      // is pushed last by the Kotlin (udpMaskList.reverse()) so it is applied first.
      const masks: Mask[] = [];
      if (p.headerType.length > 0 && p.headerType !== 'none') {
        const headerType: string = p.headerType === 'wechat-video' ? 'wechat' : p.headerType;
        const ms: MaskSettings = new MaskSettings();
        ms.header = headerType;
        if (headerType === 'dns' && p.host.length > 0) {
          ms.value = p.host;
        }
        const m: Mask = new Mask();
        m.type = 'mkcp-legacy';
        m.settings = ms;
        masks.push(m);
      }
      const seedMask: Mask = new Mask();
      seedMask.type = 'mkcp-legacy';
      if (p.seed.length > 0) {
        const ss: MaskSettings = new MaskSettings();
        ss.value = p.seed;
        seedMask.settings = ss;
      }
      masks.push(seedMask);
      masks.reverse();

      const fm: FinalMask = new FinalMask();
      fm.udp = masks;
      stream.finalmask = fm;

    } else if (transport === NetworkType.WS) {
      const ws: WsSettings = new WsSettings();
      ws.host = p.host ?? '';
      sni = p.host.length > 0 ? p.host : undefined;
      ws.path = p.path ?? '/';
      stream.wsSettings = ws;

    } else if (transport === NetworkType.HTTPUPGRADE) {
      const hu: HttpupgradeSettings = new HttpupgradeSettings();
      hu.host = p.host ?? '';
      sni = p.host.length > 0 ? p.host : undefined;
      hu.path = p.path ?? '/';
      stream.httpupgradeSettings = hu;

    } else if (transport === NetworkType.XHTTP || transport === NetworkType.SPLITHTP) {
      const xh: XhttpSettings = new XhttpSettings();
      xh.host = p.host ?? '';
      sni = p.host.length > 0 ? p.host : undefined;
      xh.path = p.path ?? '/';
      xh.mode = p.xhttpMode;
      if (p.xhttpExtra.trim().length > 0) {
        const extra: XhttpExtra | undefined = XrayConfigBuilder.parseXhttpExtra(p.xhttpExtra);
        if (extra !== undefined) {
          xh.extra = extra;
        } else {
          Log.w('XrayConfigBuilder: invalid xhttpExtra JSON, ignoring');
        }
      }
      // 'splithttp' is a legacy alias: xray maps both onto SplitHTTPConfig, which is
      // read from `xhttpSettings` (transport_internet.go StreamConfig.Build).
      stream.network = NetworkType.XHTTP;
      stream.xhttpSettings = xh;

    } else if (transport === NetworkType.HTTP) {
      const h2: HttpSettings = new HttpSettings();
      h2.host = XrayConfigBuilder.csvTrim(p.host);
      sni = h2.host.length > 0 ? h2.host[0] : undefined;
      h2.path = p.path ?? '/';
      stream.network = 'h2';
      stream.httpSettings = h2;

    } else if (transport === NetworkType.GRPC) {
      const g: GrpcSettings = new GrpcSettings();
      g.multiMode = p.mode === 'multi';
      g.serviceName = p.serviceName ?? '';
      g.authority = p.authority ?? '';
      g.idle_timeout = 60;
      g.health_check_timeout = 20;
      sni = p.authority.length > 0 ? p.authority : undefined;
      stream.grpcSettings = g;

    } else if (transport === 'quic') {
      const q: QuicSettings = new QuicSettings();
      q.security = p.quicSecurity.length > 0 ? p.quicSecurity : 'none';
      q.key = p.quicKey ?? '';
      const qh: QuicHeader = new QuicHeader();
      qh.type = p.headerType.length > 0 ? p.headerType : 'none';
      q.header = qh;
      stream.quicSettings = q;

    } else if (transport === 'hysteria') {
      const h: HysteriaSettings = new HysteriaSettings();
      h.version = 2;
      h.auth = p.password ?? '';
      stream.hysteriaSettings = h;

      const qp: QuicParams = new QuicParams();
      qp.brutalUp = XrayConfigBuilder.orNull(p.bandwidthUp);
      qp.brutalDown = XrayConfigBuilder.orNull(p.bandwidthDown);
      if (qp.brutalUp !== undefined || qp.brutalDown !== undefined) {
        qp.congestion = 'brutal';
      }
      if (p.portHopping.length > 0) {
        const hop: UdpHop = new UdpHop();
        hop.ports = p.portHopping;
        hop.interval = XrayConfigBuilder.normalizeHopInterval(p.portHoppingInterval);
        qp.udpHop = hop;
      }
      const fm: FinalMask = new FinalMask();
      fm.quicParams = qp;
      if (p.obfsPassword.length > 0) {
        const ms: MaskSettings = new MaskSettings();
        ms.password = p.obfsPassword;
        const m: Mask = new Mask();
        m.type = 'salamander';
        m.settings = ms;
        fm.udp = [m];
      }
      stream.finalmask = fm;

    } else {
      Log.w('XrayConfigBuilder: unknown transport "' + transport + '", using tcp defaults');
      stream.network = DEFAULT_NETWORK;
    }

    if (p.finalMask.trim().length > 0) {
      const parsed: FinalMask | undefined = XrayConfigBuilder.parseFinalMask(p.finalMask);
      if (parsed !== undefined) {
        stream.finalmask = parsed;
      } else {
        Log.w('XrayConfigBuilder: invalid finalMask JSON, keeping previously generated finalmask');
      }
    }
    return sni;
  }

  /**
   * CoreOutboundBuilder's mKCP port-hopping interval sanitiser. A bare number
   * below 5 is clamped to 30, an "a-b" range has both ends clamped to >= 5 and
   * ordered, anything unparseable falls back to "30".
   */
  private static normalizeHopInterval(raw: string): string {
    const t: string = (raw ?? '').trim();
    if (t.length === 0) {
      return '30';
    }
    if (t.indexOf('-') < 0) {
      const single: number = parseInt(t, 10);
      if (!Number.isFinite(single)) {
        return '30';
      }
      return single < 5 ? '30' : t;
    }
    const parts: string[] = t.split('-');
    if (parts.length !== 2) {
      return '30';
    }
    const start: number = parseInt(parts[0].trim(), 10);
    const end: number = parseInt(parts[1].trim(), 10);
    if (!Number.isFinite(start) || !Number.isFinite(end)) {
      return '30';
    }
    const minStart: number = Math.max(5, start);
    const minEnd: number = Math.max(minStart, end);
    return minStart.toString() + '-' + minEnd.toString();
  }

  /** CoreOutboundBuilder.createTcpHttpRequest */
  private static createTcpHttpRequest(host: string, path: string): TcpRequest {
    // The default header set is parsed from the very same JSON literal the
    // Android builder uses (CoreOutboundBuilder.createTcpHttpRequest). Going
    // through JSON also avoids indexed access on the quoted header names
    // ("User-Agent", "Accept-Encoding", ...), which ArkTS forbids.
    const requestJson = '{"version":"1.1","method":"GET","headers":'
      + '{"User-Agent":["' + TCP_HTTP_UA + '"],'
      + '"Accept-Encoding":["gzip, deflate"],"Connection":["keep-alive"],"Pragma":"no-cache"}}';
    const req: TcpRequest = JSON.parse(requestJson) as TcpRequest;
    if (req.headers === undefined) {
      req.headers = new TcpRequestHeaders();
    }
    const parsedHost: string[] = XrayConfigBuilder.csvTrim(host);
    if (parsedHost.length > 0) {
      (req.headers as TcpRequestHeaders).Host = parsedHost;
    }
    const parsedPath: string[] = XrayConfigBuilder.csvTrim(path);
    req.path = parsedPath.length > 0 ? parsedPath : ['/'];
    return req;
  }

  // ── TLS / REALITY (populateTlsSettings) ───────────────────────────────────

  private static populateTlsSettings(ob: Outbound, p: ProfileItem, sniExt: string | undefined): void {
    const stream: StreamSettings = ob.streamSettings !== undefined ? ob.streamSettings : new StreamSettings();
    ob.streamSettings = stream;

    const security: string = (p.security ?? '').trim();
    if (security.length === 0) {
      return;
    }
    // A pinned certificate makes allowInsecure meaningless, so it wins.
    const allowInsecure: boolean = p.insecure && p.pinnedCA256.trim().length === 0;

    let sni: string;
    if (p.sni.trim().length === 0) {
      if (sniExt !== undefined && sniExt.length > 0 && XrayConfigBuilder.isDomainName(sniExt)) {
        sni = sniExt;
      } else if (p.server.length > 0 && XrayConfigBuilder.isDomainName(p.server)) {
        sni = p.server;
      } else {
        sni = sniExt ?? '';
      }
    } else {
      sni = p.sni;
    }

    const tls: TlsSettings = new TlsSettings();
    tls.allowInsecure = allowInsecure;
    if (allowInsecure) {
      // The pinned xray-core *rejects* allowInsecure outright
      // (infra/conf/transport_security.go: `PrintRemovedFeatureError("allowInsecure", ...)`),
      // which fails the whole config load — the core never starts. The Android
      // builder has the same landmine, so behaviour is left faithful, but the
      // failure is made diagnosable here instead of arriving as an opaque
      // "config error" from the bridge.
      Log.w('XrayConfigBuilder: emitting allowInsecure=true, which this xray-core revision '
        + 'rejects; the connection will fail to start. Set a certificate fingerprint '
        + '(pinnedCA256) or verifyPeerCertByName on this server instead.');
    }
    tls.serverName = XrayConfigBuilder.orNull(sni);
    tls.fingerprint = XrayConfigBuilder.orNull(p.fingerPrint);
    const alpn: string[] = XrayConfigBuilder.csvTrim(p.alpn);
    if (alpn.length > 0) {
      tls.alpn = alpn;
    }
    tls.echConfigList = XrayConfigBuilder.orNull(p.echConfigList);
    tls.verifyPeerCertByName = XrayConfigBuilder.orNull(p.verifyPeerCertByName);
    tls.pinnedPeerCertSha256 = XrayConfigBuilder.orNull(p.pinnedCA256);
    tls.publicKey = XrayConfigBuilder.orNull(p.publicKey);
    tls.shortId = XrayConfigBuilder.orNull(p.shortId);
    tls.spiderX = XrayConfigBuilder.orNull(p.spiderX);
    tls.mldsa65Verify = XrayConfigBuilder.orNull(p.mldsa65Verify);

    stream.security = security;
    if (security === SecurityType.TLS) {
      stream.tlsSettings = tls;
      stream.realitySettings = undefined;
    } else if (security === SecurityType.REALITY) {
      stream.tlsSettings = undefined;
      stream.realitySettings = tls;
    }
    // SECURITY_TLS / SECURITY_REALITY cover every value ProfileItem.security can
    // hold; anything else leaves streamSettings.security set with neither block,
    // which is exactly what the Kotlin does too.

    // CoreOutboundBuilder.updateOutboundFragment is a no-op unless
    // PREF_FRAGMENT_ENABLED is true; AppSettingsData has no such field, so the
    // fragment/noise masks are not emitted. See the port report.
  }

  // ── server address (getServerAddress) ─────────────────────────────────────

  private static getServerAddress(p: ProfileItem): string {
    if (XrayConfigBuilder.isPureIpAddress(p.server)) {
      return p.server;
    }
    // HttpUtil.toIdnDomain() is a no-op for already-ASCII hosts, and HarmonyOS
    // share links carry punycode, so the value is passed through unchanged.
    //
    // PREF_OUTBOUND_DOMAIN_RESOLVE_METHOD has no AppSettingsData field; its
    // AppConfig default is "1", and the Kotlin only resolves-and-replaces when
    // the method is "2", so the domain is returned as-is.
    return p.server;
  }

  // ── free-form JSON passthrough ────────────────────────────────────────────

  private static parseFinalMask(raw: string): FinalMask | undefined {
    try {
      return JSON.parse(raw) as FinalMask;
    } catch (e) {
      Log.w('XrayConfigBuilder: finalMask is not valid JSON');
      return undefined;
    }
  }

  private static parseXhttpExtra(raw: string): XhttpExtra | undefined {
    try {
      return JSON.parse(raw) as XhttpExtra;
    } catch (e) {
      return undefined;
    }
  }

  // ═════════════════════════════════════════════════════════════════════════
  //  Full config
  // ═════════════════════════════════════════════════════════════════════════

  /**
   * The complete runtime config.
   *
   * `isDelayTest` strips inbounds and every routing rule that could divert or
   * drop the probe traffic; the native latency harness supplies its own
   * destination, so anything else is noise (CoreConfigManager's
   * postProcessForSpeedtest does the same).
   */
  static build(profile: ProfileItem, isDelayTest: boolean): string {
    const cfg: AppSettingsData = settings.get();
    const root: XrayConfig = new XrayConfig();

    const log: LogConfig = new LogConfig();
    log.loglevel = cfg.logLevel.length > 0 ? cfg.logLevel : 'warning';
    // Empty string keeps ErrorLogType at Console, so the bridge's log drain works.
    log.error = '';
    root.log = log;
    root.stats = new StatsConfig();
    root.policy = XrayConfigBuilder.buildPolicy();

    if (!isDelayTest) {
      root.inbounds = [XrayConfigBuilder.buildSocksInbound(cfg)];
    }

    const outbounds: Outbound[] = [];
    const proxy: Outbound | undefined = XrayConfigBuilder.buildOutbound(profile);
    if (proxy !== undefined) {
      outbounds.push(proxy);
    }
    outbounds.push(XrayConfigBuilder.buildDirectOutbound());
    outbounds.push(XrayConfigBuilder.buildBlockOutbound());
    root.outbounds = outbounds;

    root.dns = XrayConfigBuilder.buildDns(cfg);
    if (XrayConfigBuilder.fakeDnsEnabled(cfg)) {
      const pool: FakeDnsPool = new FakeDnsPool();
      pool.ipPool = FAKE_DNS_IP_POOL;
      pool.poolSize = FAKE_DNS_POOL_SIZE;
      root.fakeDns = pool;
    }

    const routing: Routing = new Routing();
    routing.domainStrategy = cfg.domainStrategy;
    routing.rules = isDelayTest ? [] : XrayConfigBuilder.buildRoutingRules(cfg);
    root.routing = routing;

    return JSON.stringify(root);
  }

  /**
   * Latency-test config: log level plus the three outbounds, nothing else.
   * No inbounds, no routing, no DNS, and mux is stripped from the proxy outbound
   * (CoreConfigManager.postProcessForSpeedtest nulls every outbound's mux).
   */
  static buildOutboundOnly(profile: ProfileItem): string {
    const cfg: AppSettingsData = settings.get();
    const root: XrayConfig = new XrayConfig();
    const log: LogConfig = new LogConfig();
    log.loglevel = cfg.logLevel.length > 0 ? cfg.logLevel : 'warning';
    log.error = '';
    root.log = log;
    const outbounds: Outbound[] = [];
    const proxy: Outbound | undefined = XrayConfigBuilder.buildOutbound(profile);
    if (proxy !== undefined) {
      proxy.mux = undefined;
      outbounds.push(proxy);
    }
    outbounds.push(XrayConfigBuilder.buildDirectOutbound());
    outbounds.push(XrayConfigBuilder.buildBlockOutbound());
    root.outbounds = outbounds;
    return JSON.stringify(root);
  }

  // ── config sections ───────────────────────────────────────────────────────

  private static buildPolicy(): PolicyConfig {
    const policy: PolicyConfig = new PolicyConfig();
    // policy.levels is keyed by level *numbers as strings* ("0", "8"), which
    // ArkTS cannot express as ordinary fields, so it is parsed from a literal
    // exactly like assets/v2ray_config.json in the Android build. Level 8 is
    // what AppConfig.DEFAULT_LEVEL puts on every outbound; level 0 keeps user
    // stats off, matching the Android defaults.
    const levelsJson = '{"0":{"statsUserUplink":false},'
      + '"8":{"handshake":4,"connIdle":300,"uplinkOnly":1,"downlinkOnly":1}}';
    policy.levels = JSON.parse(levelsJson) as PolicyLevels;
    const sys: SystemPolicy = new SystemPolicy();
    sys.statsInboundUplink = true;
    sys.statsInboundDownlink = true;
    sys.statsOutboundUplink = true;
    sys.statsOutboundDownlink = true;
    policy.system = sys;
    return policy;
  }

  private static buildSocksInbound(cfg: AppSettingsData): Inbound {
    const inb: Inbound = new Inbound();
    inb.tag = 'socks';
    inb.listen = LOOPBACK;
    inb.port = XrayConfigBuilder.toInt(cfg.socksPort, 10808);
    inb.protocol = 'socks';

    const st: InboundSettings = new InboundSettings();
    st.udp = true;
    st.userLevel = DEFAULT_LEVEL;
    if (cfg.socksUsername.length > 0 && cfg.socksPassword.length > 0) {
      st.auth = 'password';
      const acc: SocksAccount = new SocksAccount();
      acc.user = cfg.socksUsername;
      acc.pass = cfg.socksPassword;
      st.accounts = [acc];
    } else {
      st.auth = 'noauth';
    }
    inb.settings = st;

    // fakedns needs a sniffer even when general sniffing is off, otherwise the
    // core logs "Defined FakeDNS but haven't enabled FakeDNS destOverride".
    const fakeDns: boolean = XrayConfigBuilder.fakeDnsEnabled(cfg);
    if (cfg.sniffingEnabled || fakeDns) {
      const sn: Sniffing = new Sniffing();
      sn.enabled = true;
      const dest: string[] = [];
      if (cfg.sniffingEnabled) {
        dest.push('http');
        dest.push('tls');
        dest.push('quic');
      }
      if (fakeDns) {
        dest.push('fakedns');
      }
      sn.destOverride = dest;
      // No AppSettingsData field for PREF_ROUTE_ONLY_ENABLED; false is its default.
      sn.routeOnly = false;
      inb.sniffing = sn;
    }
    return inb;
  }

  private static buildDirectOutbound(): Outbound {
    const ob: Outbound = new Outbound();
    ob.tag = TAG_DIRECT;
    ob.protocol = 'freedom';
    const st: FreedomSettings = new FreedomSettings();
    st.domainStrategy = 'UseIP';
    ob.settings = st;
    return ob;
  }

  private static buildBlockOutbound(): Outbound {
    const ob: Outbound = new Outbound();
    ob.tag = TAG_BLOCKED;
    ob.protocol = 'blackhole';
    return ob;
  }

  private static fakeDnsEnabled(cfg: AppSettingsData): boolean {
    return cfg.localDnsEnabled && cfg.fakeDnsEnabled;
  }

  /**
   * DNS section, mirroring CoreConfigManager.configureDns /
   * configureLocalDns but reduced to the settings AppSettingsData actually has
   * (no per-ruleset domain collection, no balancers).
   *
   * remote DNS answers through the proxy; when localDnsEnabled, the CN and
   * private geo sets are answered by the local resolver and their DNS traffic is
   * pinned to the `direct` outbound.
   */
  private static buildDns(cfg: AppSettingsData): DnsConfig {
    const dns: DnsConfig = new DnsConfig();
    const servers: DnsServer[] = [];

    const fakeDns: boolean = XrayConfigBuilder.fakeDnsEnabled(cfg);
    const localDns: boolean = cfg.localDnsEnabled;
    const remoteList: string[] = XrayConfigBuilder.csv(cfg.remoteDns);
    const remoteDns: string[] = remoteList.length > 0 ? remoteList : [DNS_PROXY];

    if (fakeDns) {
      // First server wins, so the fakedns entry must stay at index 0.
      const fd: DnsServer = new DnsServer();
      fd.address = 'fakedns';
      fd.domains = [GEOSITE_CN, GEOSITE_PRIVATE, GEOIP_CN, GEOIP_PRIVATE];
      servers.push(fd);
    }

    for (const addr of remoteDns) {
      const s: DnsServer = new DnsServer();
      s.address = addr;
      servers.push(s);
    }

    if (localDns) {
      const localList: string[] = XrayConfigBuilder.csv(cfg.vpnDnsServers);
      const localDnsAddr: string = XrayConfigBuilder.firstOr(localList, DNS_DIRECT);
      const s: DnsServer = new DnsServer();
      s.address = localDnsAddr;
      s.domains = [GEOSITE_CN, GEOSITE_PRIVATE, GEOIP_CN, GEOIP_PRIVATE];
      s.skipFallback = true;
      s.tag = XrayConfigBuilder.TAG_DOMESTIC_DNS;
      servers.push(s);
    }

    dns.servers = servers;
    dns.tag = TAG_DNS;
    if (remoteDns.length + (localDns ? 1 : 0) > 2) {
      dns.enableParallelQuery = true;
    }
    if (localDns) {
      dns.queryStrategy = cfg.ipv6Enabled ? 'UseIPv6' : 'UseIPv4';
    }
    return dns;
  }

  private static readonly TAG_DOMESTIC_DNS: string = 'dns-direct';

  /**
   * Routing rules. Mirrors configureRouting + configureDns' routing tail:
   * the preset decides which geo sets go direct, and the DNS module's own
   * traffic is split between `direct` (local answers) and `proxy` (the rest).
   */
  private static buildRoutingRules(cfg: AppSettingsData): RoutingRule[] {
    const rules: RoutingRule[] = [];

    if (cfg.localDnsEnabled) {
      // Queries the local resolver answered must leave unproxied.
      const localRule: RoutingRule = new RoutingRule();
      localRule.type = 'field';
      localRule.outboundTag = TAG_DIRECT;
      localRule.inboundTag = [XrayConfigBuilder.TAG_DOMESTIC_DNS];
      rules.push(localRule);
    }

    const dnsRule: RoutingRule = new RoutingRule();
    dnsRule.type = 'field';
    dnsRule.outboundTag = TAG_PROXY;
    dnsRule.inboundTag = [TAG_DNS];
    rules.push(dnsRule);

    if (!cfg.routingEnabled) {
      return rules;
    }

    const preset: string = (cfg.routingPreset ?? '').toLowerCase();
    if (preset === 'bypass-mainland') {
      rules.push(XrayConfigBuilder.geoRule(TAG_DIRECT, [GEOIP_PRIVATE, GEOIP_CN], undefined));
      rules.push(XrayConfigBuilder.geoRule(TAG_DIRECT, undefined, [GEOSITE_CN, GEOSITE_PRIVATE]));
    } else if (preset === 'bypass-lan') {
      rules.push(XrayConfigBuilder.geoRule(TAG_DIRECT, [GEOIP_PRIVATE], undefined));
      rules.push(XrayConfigBuilder.geoRule(TAG_DIRECT, undefined, [GEOSITE_PRIVATE]));
    }
    // 'all', 'global' and 'custom' add no built-in direct rules: everything that
    // is not matched above falls through to the first outbound (the proxy).
    return rules;
  }

  private static geoRule(tag: string, ip: string[] | undefined, domain: string[] | undefined): RoutingRule {
    const rule: RoutingRule = new RoutingRule();
    rule.type = 'field';
    rule.outboundTag = tag;
    if (ip !== undefined) {
      rule.ip = ip;
    }
    if (domain !== undefined) {
      rule.domain = domain;
    }
    return rule;
  }
}
