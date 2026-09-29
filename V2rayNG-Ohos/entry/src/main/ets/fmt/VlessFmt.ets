import { ProfileItem, EConfigType } from '../model/Profile';
import { UriParts, getQueryParamMap, parseUri } from './FmtUtil';
import { FmtQuery, DEFAULT_SECURITY } from './FmtQuery';

/**
 * Port of com.v2ray.ang.fmt.VlessFmt — no behaviour changes.
 * One divergence: java.net.URI's `idnHost` applies IDNA punycode to non-ASCII
 * hosts; this port keeps the host as written. See docs/OHOS_PORT.md §5.
 */
export class VlessFmt {
  static parse(str: string): ProfileItem | null {
    const uri: UriParts | null = parseUri(str);
    if (uri === null) {
      return null;
    }
    if (uri.rawQuery.length === 0) {
      return null;
    }
    const q = getQueryParamMap(uri.rawQuery);

    const config = ProfileItem.create(EConfigType.VLESS);
    config.remarks = uri.fragment.length === 0 ? 'none' : uri.fragment;
    config.server = uri.idnHost;
    config.serverPort = uri.port.toString();
    config.password = uri.userInfo;
    config.method = q.has('encryption') ? (q.get('encryption') as string) : 'none';
    void DEFAULT_SECURITY;

    FmtQuery.apply(config, q);
    return config;
  }

  static toUri(config: ProfileItem): string {
    const dic = FmtQuery.toQueryDic(config);
    dic.set('encryption', config.method.length > 0 ? config.method : 'none');
    return FmtQuery.buildUri(config, config.password, dic);
  }
}
