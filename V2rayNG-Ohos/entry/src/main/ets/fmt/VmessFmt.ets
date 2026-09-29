import { ProfileItem, EConfigType, NetworkType, SecurityType } from '../model/Profile';
import { UriParts, getQueryParamMap, parseUri, base64Decode, base64Encode } from './FmtUtil';
import { FmtQuery, DEFAULT_SECURITY } from './FmtQuery';
import { Log } from '../util/Log';

/**
 * Port of com.v2ray.ang.fmt.VmessFmt. Two wire formats are supported, exactly
 * like the original: the legacy base64-encoded JSON ("vmess://<base64>") and
 * the standard URI form ("vmess://uuid@host:port?...", recognised by having
 * both '?' and '&').
 */

class VmessQRCode {
  v: string = '';
  ps: string = '';
  add: string = '';
  port: string = '';
  id: string = '';
  aid: string = '0';
  scy: string = '';
  net: string = '';
  type: string = '';
  host: string = '';
  path: string = '';
  tls: string = '';
  sni: string = '';
  alpn: string = '';
  fp: string = '';
  insecure: string = '';
  vcn: string = '';
  pcs: string = '';
}

function isBlank(s: string): boolean {
  return s === undefined || s === null || s.length === 0;
}

export class VmessFmt {
  static parse(str: string): ProfileItem | null {
    if (str.indexOf('?') > 0 && str.indexOf('&') > 0) {
      return VmessFmt.parseVmessStd(str);
    }

    let result = str.substring('vmess://'.length);
    result = base64Decode(result);
    if (isBlank(result)) {
      Log.w('vmess: decoding failed');
      return null;
    }
    let qr: VmessQRCode;
    try {
      qr = JSON.parse(result) as VmessQRCode;
    } catch (e) {
      Log.w('vmess: json parse failed');
      return null;
    }
    if (isBlank(qr.add) || isBlank(qr.port) || isBlank(qr.id) || isBlank(qr.net)) {
      Log.w('vmess: incorrect protocol fields');
      return null;
    }

    const config = ProfileItem.create(EConfigType.VMESS);
    config.remarks = qr.ps ?? '';
    config.server = qr.add;
    config.serverPort = qr.port;
    config.password = qr.id;
    config.method = isBlank(qr.scy) ? DEFAULT_SECURITY : qr.scy;

    config.network = isBlank(qr.net) ? NetworkType.TCP : qr.net;
    config.headerType = qr.type ?? '';
    config.host = qr.host ?? '';
    config.path = qr.path ?? '';

    if (config.network === NetworkType.KCP) {
      config.seed = qr.path ?? '';
    } else if (config.network === NetworkType.GRPC) {
      config.mode = qr.type ?? '';
      config.serviceName = qr.path ?? '';
      config.authority = qr.host ?? '';
    }

    config.security = qr.tls ?? '';
    config.sni = qr.sni ?? '';
    config.fingerPrint = qr.fp ?? '';
    config.alpn = qr.alpn ?? '';
    config.insecure = qr.insecure === '1';
    config.verifyPeerCertByName = qr.vcn ?? '';
    config.pinnedCA256 = qr.pcs ?? '';
    return config;
  }

  static parseVmessStd(str: string): ProfileItem | null {
    const uri: UriParts | null = parseUri(str);
    if (uri === null || uri.rawQuery.length === 0) {
      return null;
    }
    const q = getQueryParamMap(uri.rawQuery);

    const config = ProfileItem.create(EConfigType.VMESS);
    config.remarks = uri.fragment.length === 0 ? 'none' : uri.fragment;
    config.server = uri.idnHost;
    config.serverPort = uri.port.toString();
    config.password = uri.userInfo;
    config.method = DEFAULT_SECURITY;

    FmtQuery.apply(config, q);
    return config;
  }

  static toUri(config: ProfileItem): string {
    const qr = new VmessQRCode();
    qr.v = '2';
    qr.ps = config.remarks;
    qr.add = config.server;
    qr.port = config.serverPort;
    qr.id = config.password;
    qr.scy = config.method;
    qr.aid = '0';
    qr.net = config.network;
    qr.type = config.headerType;
    if (config.network === NetworkType.KCP) {
      qr.path = config.seed;
    } else if (config.network === NetworkType.GRPC) {
      qr.type = config.mode;
      qr.path = config.serviceName;
      qr.host = config.authority;
    }
    if (config.host.trim().length > 0) {
      qr.host = config.host;
    }
    if (config.path.trim().length > 0) {
      qr.path = config.path;
    }
    qr.tls = config.security;
    qr.sni = config.sni;
    qr.fp = config.fingerPrint;
    qr.alpn = config.alpn;
    qr.insecure = config.insecure ? '1' : '0';
    qr.vcn = config.verifyPeerCertByName;
    qr.pcs = config.pinnedCA256;

    return base64Encode(JSON.stringify(qr), false);
  }
}
