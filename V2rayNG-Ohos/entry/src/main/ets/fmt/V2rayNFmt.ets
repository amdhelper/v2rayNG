import { ProfileItem, EConfigType, NetworkType } from '../model/Profile';
import { base64Decode, nullIfBlank } from './FmtUtil';
import { Log } from '../util/Log';

/**
 * Port of com.v2ray.ang.fmt.V2rayNFmt — the desktop client's share format,
 * "v2rayn://<base64(json)>" per line.
 *
 * Scope note (documented gap, see docs/OHOS_PORT.md §5): the Android version
 * also handles groups — ConfigType 101 (policy group) and 102 (proxy chain) —
 * by resolving ChildItems against the other items in the same paste. Policy
 * groups and proxy chains are not implemented in this port, so those entries
 * are skipped with a warning instead of being silently mis-imported.
 */

class ProtoExtra {
  Flow: string = '';
  VmessSecurity: string = '';
  VlessEncryption: string = '';
  SsMethod: string = '';
  WgPresharedKey: string = '';
  WgInterfaceAddress: string = '';
  WgReserved: string = '';
  WgMtu: number = 0;
  SalamanderPass: string = '';
  UpMbps: number = 0;
  DownMbps: number = 0;
  Ports: string = '';
  HopInterval: string = '';
}

class TransportExtra {
  RawHeaderType: string = '';
  Host: string = '';
  Path: string = '';
  XhttpMode: string = '';
  XhttpExtra: string = '';
  GrpcAuthority: string = '';
  GrpcServiceName: string = '';
  GrpcMode: string = '';
  KcpHeaderType: string = '';
  KcpSeed: string = '';
  KcpMtu: number = 0;
}

class ShareItem {
  IndexId: string = '';
  ConfigType: number = 0;
  ConfigVersion: number = 0;
  Remarks: string = '';
  Address: string = '';
  Port: number = 0;
  Password: string = '';
  Username: string = '';
  Network: string = '';
  StreamSecurity: string = '';
  AllowInsecure: string = '';
  Sni: string = '';
  Alpn: string = '';
  Fingerprint: string = '';
  PublicKey: string = '';
  ShortId: string = '';
  SpiderX: string = '';
  Mldsa65Verify: string = '';
  CertSha: string = '';
  EchConfigList: string = '';
  VerifyPeerCertByName: string = '';
  Finalmask: string = '';
  ProtoExtraObj: ProtoExtra | null = null; // may be absent in the JSON
  TransportExtraObj: TransportExtra | null = null;
}

/**
 * Coerces a v2rayn field to a string.
 *
 * A key that the JSON omits parses to `undefined`, and ProfileItem's fields are
 * plain `string`s whose defaults only apply at construction — assigning
 * `undefined` over them leaves a trap that blows up later at the first
 * `.trim()` / `.length`. Every optional v2rayn field goes through here.
 */
function opt(v: string | null | undefined): string {
  return (v === undefined || v === null) ? '' : v;
}

export class V2rayNFmt {
  static parse(str: string): ProfileItem | null {
    const s = str.trim();
    const slash = s.lastIndexOf('/');
    if (slash < 0) {
      return null;
    }
    const payload = base64Decode(s.substring(slash + 1));
    if (payload.length === 0) {
      return null;
    }
    let item: ShareItem;
    try {
      item = JSON.parse(payload) as ShareItem;
    } catch (e) {
      Log.e('v2rayn: failed to parse share item');
      return null;
    }
    if (item.ConfigType === 101 || item.ConfigType === 102) {
      Log.w('v2rayn: policy-group / proxy-chain entries are not supported yet — skipped');
      return null;
    }
    return V2rayNFmt.toProfileItem(item);
  }

  private static toProfileItem(item: ShareItem): ProfileItem | null {
    let configType: EConfigType;
    switch (item.ConfigType) {
      case 1: configType = EConfigType.VMESS; break;
      case 2: configType = EConfigType.CUSTOM; break;
      case 3: configType = EConfigType.SHADOWSOCKS; break;
      case 4: configType = EConfigType.SOCKS; break;
      case 5: configType = EConfigType.VLESS; break;
      case 6: configType = EConfigType.TROJAN; break;
      case 7: configType = EConfigType.HYSTERIA2; break;
      case 9: configType = EConfigType.WIREGUARD; break;
      case 10: configType = EConfigType.HTTP; break;
      default:
        Log.w('v2rayn: unknown ConfigType ' + item.ConfigType);
        return null;
    }

    // A key that is absent from the JSON parses to `undefined`, NOT `null`, so
    // both have to be normalised here — checking only for null threw for every
    // v2rayn item that omitted the optional sub-objects.
    const proto: ProtoExtra | null =
      (item.ProtoExtraObj === undefined || item.ProtoExtraObj === null) ? null : item.ProtoExtraObj;
    const trans: TransportExtra | null =
      (item.TransportExtraObj === undefined || item.TransportExtraObj === null) ? null : item.TransportExtraObj;

    let network = '';
    if (configType === EConfigType.HYSTERIA2) {
      network = NetworkType.HYSTERIA;
    } else if (item.Network === 'raw') {
      network = NetworkType.TCP;
    } else {
      const nw = opt(item.Network);
      network = nw.length > 0 ? nw : NetworkType.TCP;
    }

    const config = ProfileItem.create(configType);
    config.remarks = opt(item.Remarks);
    config.server = opt(item.Address);
    config.serverPort = item.Port === undefined || item.Port === null ? '' : item.Port.toString();
    config.password = opt(item.Password);
    config.method = V2rayNFmt.methodFor(configType, proto);
    config.flow = proto === null ? '' : opt(proto.Flow);
    config.username = opt(item.Username);
    config.network = network;

    if (network === NetworkType.TCP) {
      config.headerType = trans === null ? '' : opt(trans.RawHeaderType);
    } else if (network === NetworkType.KCP) {
      config.headerType = trans === null ? '' : opt(trans.KcpHeaderType);
    }
    if (trans !== null) {
      config.host = opt(trans.Host);
      config.path = opt(trans.Path);
      config.seed = opt(trans.KcpSeed);
      config.kcpMtu = trans.KcpMtu === undefined || trans.KcpMtu === null ? 0 : trans.KcpMtu;
      config.mode = opt(trans.GrpcMode);
      config.serviceName = opt(trans.GrpcServiceName);
      config.authority = opt(trans.GrpcAuthority);
      config.xhttpMode = opt(trans.XhttpMode);
      config.xhttpExtra = opt(trans.XhttpExtra);
    }

    config.finalMask = opt(item.Finalmask);
    config.security = opt(item.StreamSecurity);
    config.sni = opt(item.Sni);
    config.alpn = opt(item.Alpn);
    config.fingerPrint = opt(item.Fingerprint);
    config.insecure = item.AllowInsecure === 'true' || item.AllowInsecure === '1';
    config.echConfigList = opt(item.EchConfigList);
    config.verifyPeerCertByName = opt(item.VerifyPeerCertByName);
    config.pinnedCA256 = opt(item.CertSha);
    config.publicKey = opt(item.PublicKey);
    config.shortId = opt(item.ShortId);
    config.spiderX = opt(item.SpiderX);
    config.mldsa65Verify = opt(item.Mldsa65Verify);

    if (configType === EConfigType.WIREGUARD) {
      config.secretKey = opt(item.Password);
    }
    if (proto !== null) {
      config.preSharedKey = opt(proto.WgPresharedKey);
      config.localAddress = opt(proto.WgInterfaceAddress);
      config.reserved = opt(proto.WgReserved);
      config.mtu = proto.WgMtu === undefined || proto.WgMtu === null ? 0 : proto.WgMtu;
      config.obfsPassword = opt(proto.SalamanderPass);
      config.portHopping = opt(proto.Ports);
      config.portHoppingInterval = opt(proto.HopInterval);
      const down = proto.DownMbps === undefined || proto.DownMbps === null ? 0 : proto.DownMbps;
      if (down > 0) {
        config.bandwidthDown = down.toString() + 'Mbps';
      }
      const up = proto.UpMbps === undefined || proto.UpMbps === null ? 0 : proto.UpMbps;
      if (up > 0) {
        config.bandwidthUp = up.toString() + 'Mbps';
      }
    }
    return config;
  }

  private static methodFor(configType: EConfigType, proto: ProtoExtra | null): string {
    if (proto === null || proto === undefined) {
      return configType === EConfigType.VMESS ? 'auto' : 'none';
    }
    if (configType === EConfigType.VMESS) {
      const sec = opt(proto.VmessSecurity);
      return sec.length > 0 ? sec : 'auto';
    }
    if (configType === EConfigType.SHADOWSOCKS) {
      return opt(proto.SsMethod);
    }
    if (configType === EConfigType.VLESS) {
      const enc = opt(proto.VlessEncryption);
      return enc.length > 0 ? enc : 'none';
    }
    return '';
  }

  /** V2rayN entries have no share URI; export falls back to the protocol's own. */
  static toUri(config: ProfileItem): string {
    return '';
  }
}
