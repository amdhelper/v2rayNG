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
  ProtoExtraObj: ProtoExtra | null = null;
  TransportExtraObj: TransportExtra | null = null;
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

    const proto = item.ProtoExtraObj;
    const trans = item.TransportExtraObj;

    let network = '';
    if (configType === EConfigType.HYSTERIA2) {
      network = NetworkType.HYSTERIA;
    } else if (item.Network === 'raw') {
      network = NetworkType.TCP;
    } else {
      network = item.Network.length > 0 ? item.Network : NetworkType.TCP;
    }

    const config = ProfileItem.create(configType);
    config.remarks = item.Remarks;
    config.server = item.Address;
    config.serverPort = item.Port.toString();
    config.password = item.Password;
    config.method = V2rayNFmt.methodFor(configType, proto);
    config.flow = proto === null ? '' : proto.Flow;
    config.username = item.Username;
    config.network = network;

    if (network === NetworkType.TCP) {
      config.headerType = trans === null ? '' : trans.RawHeaderType;
    } else if (network === NetworkType.KCP) {
      config.headerType = trans === null ? '' : trans.KcpHeaderType;
    }
    if (trans !== null) {
      config.host = trans.Host;
      config.path = trans.Path;
      config.seed = trans.KcpSeed;
      config.kcpMtu = trans.KcpMtu;
      config.mode = trans.GrpcMode;
      config.serviceName = trans.GrpcServiceName;
      config.authority = trans.GrpcAuthority;
      config.xhttpMode = trans.XhttpMode;
      config.xhttpExtra = trans.XhttpExtra;
    }

    config.finalMask = item.Finalmask;
    config.security = item.StreamSecurity;
    config.sni = item.Sni;
    config.alpn = item.Alpn;
    config.fingerPrint = item.Fingerprint;
    config.insecure = item.AllowInsecure === 'true' || item.AllowInsecure === '1';
    config.echConfigList = item.EchConfigList;
    config.verifyPeerCertByName = item.VerifyPeerCertByName;
    config.pinnedCA256 = item.CertSha;
    config.publicKey = item.PublicKey;
    config.shortId = item.ShortId;
    config.spiderX = item.SpiderX;
    config.mldsa65Verify = item.Mldsa65Verify;

    if (configType === EConfigType.WIREGUARD) {
      config.secretKey = item.Password;
    }
    if (proto !== null) {
      config.preSharedKey = proto.WgPresharedKey;
      config.localAddress = proto.WgInterfaceAddress;
      config.reserved = proto.WgReserved;
      config.mtu = proto.WgMtu;
      config.obfsPassword = proto.SalamanderPass;
      config.portHopping = proto.Ports;
      config.portHoppingInterval = proto.HopInterval;
      if (proto.DownMbps > 0) {
        config.bandwidthDown = proto.DownMbps.toString() + 'Mbps';
      }
      if (proto.UpMbps > 0) {
        config.bandwidthUp = proto.UpMbps.toString() + 'Mbps';
      }
    }
    return config;
  }

  private static methodFor(configType: EConfigType, proto: ProtoExtra | null): string {
    if (proto === null) {
      return configType === EConfigType.VMESS ? 'auto' : 'none';
    }
    if (configType === EConfigType.VMESS) {
      return proto.VmessSecurity.length > 0 ? proto.VmessSecurity : 'auto';
    }
    if (configType === EConfigType.SHADOWSOCKS) {
      return proto.SsMethod;
    }
    if (configType === EConfigType.VLESS) {
      return proto.VlessEncryption.length > 0 ? proto.VlessEncryption : 'none';
    }
    return '';
  }

  /** V2rayN entries have no share URI; export falls back to the protocol's own. */
  static toUri(config: ProfileItem): string {
    return '';
  }
}
