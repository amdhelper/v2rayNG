import { ProfileItem, EConfigType, NetworkType } from '../model/Profile';
import { UriParts, getQueryParamMap, parseUri } from './FmtUtil';
import { FmtQuery, TLS } from './FmtQuery';

/** Port of com.v2ray.ang.fmt.TrojanFmt. */
export class TrojanFmt {
  static parse(str: string): ProfileItem | null {
    const uri: UriParts | null = parseUri(str);
    if (uri === null) {
      return null;
    }
    const config = ProfileItem.create(EConfigType.TROJAN);
    config.remarks = uri.fragment.length === 0 ? 'none' : uri.fragment;
    config.server = uri.idnHost;
    config.serverPort = uri.port.toString();
    config.password = uri.userInfo;

    if (uri.rawQuery.length === 0) {
      config.network = NetworkType.TCP;
      config.security = TLS;
      config.insecure = false;
    } else {
      const q = getQueryParamMap(uri.rawQuery);
      FmtQuery.apply(config, q);
      config.security = q.has('security') ? (q.get('security') as string) : TLS;
    }
    return config;
  }

  static toUri(config: ProfileItem): string {
    return FmtQuery.buildUri(config, config.password, FmtQuery.toQueryDic(config));
  }
}
