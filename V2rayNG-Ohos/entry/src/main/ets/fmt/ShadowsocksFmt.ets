import { ProfileItem, EConfigType, NetworkType } from '../model/Profile';
import { UriParts, getQueryParamMap, parseUri, base64Decode, base64Encode, encodeURIComponentExt, decodeURIComponentExt } from './FmtUtil';
import { FmtQuery } from './FmtQuery';
import { Log } from '../util/Log';

/**
 * Port of com.v2ray.ang.fmt.ShadowsocksFmt: SIP002 first, legacy second.
 */
export class ShadowsocksFmt {
  static parse(str: string): ProfileItem | null {
    const sip002 = ShadowsocksFmt.parseSip002(str);
    return sip002 !== null ? sip002 : ShadowsocksFmt.parseLegacy(str);
  }

  static parseSip002(str: string): ProfileItem | null {
    const uri: UriParts | null = parseUri(str);
    if (uri === null) {
      return null;
    }
    if (uri.idnHost.length === 0 || uri.port <= 0 || uri.userInfo.length === 0) {
      return null;
    }

    const config = ProfileItem.create(EConfigType.SHADOWSOCKS);
    config.remarks = uri.fragment.length === 0 ? 'none' : uri.fragment;
    config.server = uri.idnHost;
    config.serverPort = uri.port.toString();

    // userInfo is already percent-decoded here (java.net.URI behaviour), so
    // only the legacy base64 branch needs an extra decode — same as upstream.
    const result: string[] = ShadowsocksFmt.split2(uri.userInfo);
    if (result.length === 2) {
      config.method = result[0];
      config.password = result[1];
    }

    if (uri.rawQuery.length > 0) {
      const q = getQueryParamMap(uri.rawQuery);
      const plugin = q.has('plugin') ? (q.get('plugin') as string) : '';
      if (plugin.indexOf('obfs=http') >= 0) {
        const pairs = new Map<string, string>();
        for (const pair of plugin.split(';')) {
          const idx = pair.split('=');
          if (idx.length === 2) {
            pairs.set(idx[0], idx[1]);
          }
        }
        config.network = NetworkType.TCP;
        config.headerType = 'http';
        config.host = pairs.has('obfs-host') ? (pairs.get('obfs-host') as string) : '';
        config.path = pairs.has('path') ? (pairs.get('path') as string) : '';
      }
    }
    return config;
  }

  private static split2(s: string): string[] {
    const out: string[] = [];
    if (s.indexOf(':') >= 0) {
      const i = s.indexOf(':');
      out.push(s.substring(0, i));
      out.push(s.substring(i + 1));
      return out;
    }
    const decoded = base64Decode(s);
    if (decoded.indexOf(':') >= 0) {
      const j = decoded.indexOf(':');
      out.push(decoded.substring(0, j));
      out.push(decoded.substring(j + 1));
      return out;
    }
    return [];
  }

  static parseLegacy(str: string): ProfileItem | null {
    let result = str.substring('ss://'.length);
    let remarks = '';
    const indexSplit = result.indexOf('#');
    if (indexSplit > 0) {
      remarks = decodeURIComponentExt(result.substring(indexSplit + 1));
      result = result.substring(0, indexSplit);
    }

    // Partial decode: only the method:password blob in front of '@'.
    const indexS = result.indexOf('@');
    if (indexS > 0) {
      result = decodeURIComponentExt(result.substring(0, indexS)) + result.substring(indexS);
    } else {
      result = base64Decode(result);
    }

    // Same regex as the Kotlin original: "^(.+?):(.*)@(.+?):(\d+?)/?$".
    // Groups: 1 = method, 2 = password, 3 = host (maybe bracketed), 4 = port.
    const re = new RegExp('^(.+?):(.*)@(.+?):(\\d+?)/?$');
    const m = re.exec(result);
    if (m === null) {
      return null;
    }

    const config = ProfileItem.create(EConfigType.SHADOWSOCKS);
    config.remarks = remarks;
    let host = m[3];
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    config.server = host;
    config.serverPort = m[4];
    config.password = m[2];
    config.method = m[1].toLowerCase();
    return config;
  }

  static toUri(config: ProfileItem): string {
    const pw = config.method + ':' + config.password;
    return FmtQuery.buildUri(config, base64Encode(pw, true), null);
  }
}
