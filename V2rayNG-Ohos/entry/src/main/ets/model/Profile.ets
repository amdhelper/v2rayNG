/**
 * Profile data model — HarmonyOS port of
 * V2rayNG/app/src/main/java/com/v2ray/ang/dto/entities/ProfileItem.kt
 *
 * Field names are kept byte-identical to the Android entity so that the
 * import / export / JSON persistence formats stay interchangeable with the
 * Android build, and so the outbound builder can be ported 1:1.
 */

export enum EConfigType {
  VMESS = 1,
  SHADOWSOCKS = 2,
  SOCKS = 3,
  VLESS = 4,
  TROJAN = 5,
  WIREGUARD = 6,
  HYSTERIA2 = 7,
  CUSTOM = 8,
  HTTP = 9,
  ANYTLS = 10,
}

export function configTypeName(t: EConfigType): string {
  switch (t) {
    case EConfigType.VMESS: return 'vmess';
    case EConfigType.SHADOWSOCKS: return 'shadowsocks';
    case EConfigType.SOCKS: return 'socks';
    case EConfigType.VLESS: return 'vless';
    case EConfigType.TROJAN: return 'trojan';
    case EConfigType.WIREGUARD: return 'wireguard';
    case EConfigType.HYSTERIA2: return 'hysteria2';
    case EConfigType.CUSTOM: return 'custom';
    case EConfigType.HTTP: return 'http';
    case EConfigType.ANYTLS: return 'anytls';
    default: return 'unknown';
  }
}

export function configTypeFromName(s: string): EConfigType {
  const v = s.toLowerCase();
  if (v === 'vmess') return EConfigType.VMESS;
  if (v === 'shadowsocks' || v === 'ss') return EConfigType.SHADOWSOCKS;
  if (v === 'socks') return EConfigType.SOCKS;
  if (v === 'vless') return EConfigType.VLESS;
  if (v === 'trojan') return EConfigType.TROJAN;
  if (v === 'wireguard' || v === 'wg') return EConfigType.WIREGUARD;
  if (v === 'hysteria2' || v === 'hy2') return EConfigType.HYSTERIA2;
  if (v === 'custom') return EConfigType.CUSTOM;
  if (v === 'http') return EConfigType.HTTP;
  if (v === 'anytls') return EConfigType.ANYTLS;
  return EConfigType.VMESS;
}

/** Network transport values used by `ProfileItem.network`. */
export class NetworkType {
  static readonly TCP = 'tcp';
  static readonly KCP = 'kcp';
  static readonly WS = 'ws';
  static readonly HTTP = 'http';
  static readonly QUIC = 'quic';
  static readonly GRPC = 'grpc';
  static readonly HTTPUPGRADE = 'httpupgrade';
  static readonly SPLITHTP = 'splithttp';
  static readonly XHTTP = 'xhttp';
}

/** Security values used by `ProfileItem.security`. */
export class SecurityType {
  static readonly NONE = 'none';
  static readonly TLS = 'tls';
  static readonly REALITY = 'reality';
}

/**
 * One server entry. Mirrors ProfileItem.kt field-for-field.
 * `guid` is the stable identity used by the UI and by persistence.
 */
export class ProfileItem {
  guid: string = '';
  configVersion: number = 4;
  configType: EConfigType = EConfigType.VMESS;
  subscriptionId: string = '';
  addedTime: number = 0;

  remarks: string = '';
  description: string = '';
  server: string = '';
  serverPort: string = '';

  password: string = '';
  method: string = '';
  flow: string = '';
  username: string = '';

  network: string = '';
  headerType: string = '';
  host: string = '';
  path: string = '';
  seed: string = '';
  kcpMtu: number = 0;
  kcpTti: number = 0;

  quicSecurity: string = '';
  quicKey: string = '';
  mode: string = '';
  serviceName: string = '';
  authority: string = '';
  xhttpMode: string = '';
  xhttpExtra: string = '';
  finalMask: string = '';

  security: string = '';
  sni: string = '';
  alpn: string = '';
  fingerPrint: string = '';
  insecure: boolean = false;
  echConfigList: string = '';
  verifyPeerCertByName: string = '';
  pinnedCA256: string = '';

  publicKey: string = '';
  shortId: string = '';
  spiderX: string = '';
  mldsa65Verify: string = '';

  secretKey: string = '';
  preSharedKey: string = '';
  localAddress: string = '';
  reserved: string = '';
  mtu: number = 0;
  remoteDNS: string = '';

  obfsPassword: string = '';
  portHopping: string = '';
  portHoppingInterval: string = '';
  bandwidthDown: string = '';
  bandwidthUp: string = '';

  browserDialerMode: string = '';

  /** "host:port" for display, matching ProfileItem.getServerAddressAndPort(). */
  getServerAddressAndPort(): string {
    return this.server + ':' + this.serverPort;
  }

  /**
   * Dedicated identity for "remove duplicate configurations" — ignores
   * metadata that does not affect connectivity. Mirrors duplicateIdentity().
   */
  duplicateIdentity(): string {
    return JSON.stringify({
      configType: this.configType,
      server: this.server,
      serverPort: this.serverPort,
      password: this.password,
      method: this.method,
      flow: this.flow,
      username: this.username,
      network: this.network,
      headerType: this.headerType,
      host: this.host,
      path: this.path,
      seed: this.seed,
      quicSecurity: this.quicSecurity,
      quicKey: this.quicKey,
      mode: this.mode,
      serviceName: this.serviceName,
      authority: this.authority,
      xhttpMode: this.xhttpMode,
      security: this.security,
      sni: this.sni,
      alpn: this.alpn,
      fingerPrint: this.fingerPrint,
      publicKey: this.publicKey,
      shortId: this.shortId,
      spiderX: this.spiderX,
      secretKey: this.secretKey,
      preSharedKey: this.preSharedKey,
      localAddress: this.localAddress,
      obfsPassword: this.obfsPassword
    });
  }

  static create(configType: EConfigType): ProfileItem {
    const p = new ProfileItem();
    p.configType = configType;
    return p;
  }
}
