import { ProfileItem, EConfigType, NetworkType } from '../model/Profile';
import { UriParts, getQueryParamMap, parseUri } from './FmtUtil';
import { FmtQuery, TLS } from './FmtQuery';

/** Port of com.v2ray.ang.fmt.Hysteria2Fmt (hysteria2:// and hy2://). */
export class Hysteria2Fmt {
  static parse(str: string): ProfileItem | null {
    const uri: UriParts | null = parseUri(str);
    if (uri === null) {
      return null;
    }
    const config = ProfileItem.create(EConfigType.HYSTERIA2);
    config.remarks = uri.fragment.length === 0 ? 'none' : uri.fragment;
    config.server = uri.idnHost;
    config.serverPort = uri.port.toString();
    config.password = uri.userInfo;
    config.security = TLS;
    config.network = NetworkType.HYSTERIA;

    if (uri.rawQuery.length > 0) {
      const q = getQueryParamMap(uri.rawQuery);
      FmtQuery.apply(config, q);
      config.security = q.has('security') ? (q.get('security') as string) : TLS;
      config.obfsPassword = q.has('obfs-password') ? (q.get('obfs-password') as string) : '';
      config.portHopping = q.has('mport') ? (q.get('mport') as string) : '';
      config.pinnedCA256 = q.has('pinSHA256') ? (q.get('pinSHA256') as string) : '';
    }
    return config;
  }

  static toUri(config: ProfileItem): string {
    const d = new Map<string, string>();
    if (config.security.length > 0) {
      d.set('security', config.security);
    }
    if (config.sni.trim().length > 0) {
      d.set('sni', config.sni);
    }
    if (config.alpn.trim().length > 0) {
      d.set('alpn', config.alpn);
    }
    d.set('insecure', config.insecure ? '1' : '0');
    if (config.obfsPassword.length > 0) {
      d.set('obfs', 'salamander');
      d.set('obfs-password', config.obfsPassword);
    }
    if (config.portHopping.length > 0) {
      d.set('mport', config.portHopping);
    }
    if (config.pinnedCA256.length > 0) {
      d.set('pinSHA256', config.pinnedCA256);
    }
    return FmtQuery.buildUri(config, config.password, d);
  }
}
