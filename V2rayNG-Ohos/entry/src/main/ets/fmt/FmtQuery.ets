import { ProfileItem, NetworkType, SecurityType } from '../model/Profile';
import { encodeURIComponentExt, getIpv6Address } from './FmtUtil';

/**
 * Port of com.v2ray.ang.fmt.FmtBase — the three shared operations every
 * protocol module uses: build a share URI, read a ProfileItem out of query
 * parameters, and write the query dictionary back out.
 *
 * Field names and key spellings are kept identical to the Kotlin original so
 * links round-trip against the Android build.
 */

export const DEFAULT_SECURITY = 'auto';
export const TLS = 'tls';
export const REALITY = 'reality';

export const DEFAULT_LOOPBACK = '127.0.0.1';
export const DEFAULT_PORT_SOCKS = '10808';

const ALLOW_INSECURE_KEYS: string[] = ['insecure', 'allowInsecure', 'allow_insecure'];

export class FmtQuery {
  /** FmtBase.toUri(config, userInfo, dicQuery). */
  static buildUri(config: ProfileItem, userInfo: string, dicQuery: Map<string, string> | null): string {
    let query = '';
    if (dicQuery !== null) {
      const pairs: string[] = [];
      dicQuery.forEach((v: string, k: string) => {
        pairs.push(k + '=' + encodeURIComponentExt(v));
      });
      query = '?' + pairs.join('&');
    }
    const url = encodeURIComponentExt(userInfo)
      + '@' + getIpv6Address(config.server)
      + ':' + config.serverPort;
    return url + query + '#' + encodeURIComponentExt(config.remarks);
  }

  /** FmtBase.getItemFormQuery(config, queryParam). */
  static apply(config: ProfileItem, q: Map<string, string>): void {
    // ArkTS forbids null on a `string` field, so "absent" is represented by ''.
    // The outbound builder treats a blank value as absent, same as gson's null.
    const get = (k: string): string => (q.has(k) ? (q.get(k) as string) : '');
    const getInt = (k: string): number => {
      const v = get(k);
      if (v.length === 0) {
        return 0;
      }
      const n = Number.parseInt(v, 10);
      return Number.isNaN(n) ? 0 : n;
    };

    config.network = get('type').length > 0 ? get('type') : NetworkType.TCP;
    config.headerType = get('headerType');
    config.host = get('host');
    config.path = get('path');

    config.seed = get('seed');
    config.kcpMtu = getInt('mtu');
    config.kcpTti = getInt('tti');
    config.quicSecurity = get('quicSecurity');
    config.quicKey = get('key');
    config.mode = get('mode');
    config.serviceName = get('serviceName');
    config.authority = get('authority');
    config.xhttpMode = get('mode');
    config.xhttpExtra = get('extra');
    config.finalMask = get('fm');

    const sec = get('security');
    config.security = (sec === TLS || sec === REALITY) ? sec : '';

    config.insecure = FmtQuery.anyEquals(q, ALLOW_INSECURE_KEYS, '1');

    config.sni = get('sni');
    config.fingerPrint = get('fp');
    config.alpn = get('alpn');
    config.echConfigList = get('ech');
    config.verifyPeerCertByName = get('vcn');
    config.pinnedCA256 = get('pcs');
    config.publicKey = get('pbk');
    config.shortId = get('sid');
    config.spiderX = get('spx');
    config.mldsa65Verify = get('pqv');
    config.flow = get('flow');
  }

  private static anyEquals(q: Map<string, string>, keys: string[], want: string): boolean {
    for (const k of keys) {
      if (q.has(k) && q.get(k) === want) {
        return true;
      }
    }
    return false;
  }

  /** FmtBase.getQueryDic(config). */
  static toQueryDic(config: ProfileItem): Map<string, string> {
    const d = new Map<string, string>();
    d.set('security', config.security.length > 0 ? config.security : 'none');

    const put = (k: string, v: string | null): void => {
      if (v !== null && v.trim().length > 0) {
        d.set(k, v);
      }
    };
    put('sni', config.sni);
    put('alpn', config.alpn);
    put('ech', config.echConfigList);
    put('vcn', config.verifyPeerCertByName);
    put('pcs', config.pinnedCA256);
    put('fp', config.fingerPrint);
    put('pbk', config.publicKey);
    put('sid', config.shortId);
    put('spx', config.spiderX);
    put('pqv', config.mldsa65Verify);
    put('flow', config.flow);
    put('fm', config.finalMask);
    if (config.kcpMtu > 0) {
      d.set('mtu', config.kcpMtu.toString());
    }
    if (config.kcpTti > 0) {
      d.set('tti', config.kcpTti.toString());
    }
    // Keep both keys for compatibility, exactly like the Kotlin original.
    if (config.security === TLS) {
      const flag = config.insecure ? '1' : '0';
      d.set('insecure', flag);
      d.set('allowInsecure', flag);
    }

    const nt = config.network;
    d.set('type', nt.length > 0 ? nt : NetworkType.TCP);

    if (nt === NetworkType.TCP) {
      d.set('headerType', config.headerType.length > 0 ? config.headerType : 'none');
      put('host', config.host);
    } else if (nt === NetworkType.KCP) {
      d.set('headerType', config.headerType.length > 0 ? config.headerType : 'none');
      put('seed', config.seed);
    } else if (nt === NetworkType.WS || nt === NetworkType.HTTPUPGRADE) {
      put('host', config.host);
      put('path', config.path);
    } else if (nt === NetworkType.XHTTP) {
      put('host', config.host);
      put('path', config.path);
      put('mode', config.xhttpMode);
      put('extra', config.xhttpExtra);
    } else if (nt === NetworkType.HTTP || nt === NetworkType.H2) {
      d.set('type', 'http');
      put('host', config.host);
      put('path', config.path);
    } else if (nt === NetworkType.GRPC) {
      put('mode', config.mode);
      put('authority', config.authority);
      put('serviceName', config.serviceName);
    }
    return d;
  }
}
