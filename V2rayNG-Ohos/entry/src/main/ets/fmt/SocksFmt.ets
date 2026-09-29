import { ProfileItem, EConfigType } from '../model/Profile';
import { UriParts, parseUri, base64Decode, base64Encode } from './FmtUtil';
import { FmtQuery } from './FmtQuery';

/** Port of com.v2ray.ang.fmt.SocksFmt (socks://, socks4://, socks5://). */
export class SocksFmt {
  static parse(str: string): ProfileItem | null {
    const uri: UriParts | null = parseUri(str);
    if (uri === null) {
      return null;
    }
    if (uri.idnHost.length === 0 || uri.port <= 0) {
      return null;
    }
    const config = ProfileItem.create(EConfigType.SOCKS);
    config.remarks = uri.fragment.length === 0 ? 'none' : uri.fragment;
    config.server = uri.idnHost;
    config.serverPort = uri.port.toString();

    if (uri.userInfo.length > 0) {
      let result: string[] = [];
      if (uri.userInfo.indexOf(':') >= 0) {
        const i = uri.userInfo.indexOf(':');
        result = [uri.userInfo.substring(0, i), uri.userInfo.substring(i + 1)];
      } else {
        const decoded = base64Decode(uri.userInfo);
        if (decoded.indexOf(':') >= 0) {
          const j = decoded.indexOf(':');
          result = [decoded.substring(0, j), decoded.substring(j + 1)];
        }
      }
      if (result.length === 2) {
        config.username = result[0];
        config.password = result[1];
      }
    }
    return config;
  }

  static toUri(config: ProfileItem): string {
    const pw = config.username.length > 0 ? (config.username + ':' + config.password) : ':';
    return FmtQuery.buildUri(config, base64Encode(pw, true), null);
  }
}
