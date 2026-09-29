import { ProfileItem, EConfigType } from '../model/Profile';
import { UriParts, getQueryParamMap, parseUri, removeWhiteSpace, parseIntOrZero, nullIfBlank } from './FmtUtil';
import { FmtQuery } from './FmtQuery';

/** Defaults mirrored from com.v2ray.ang.AppConfig. */
export const WG_LOCAL_ADDRESS_V4 = '172.16.0.2/32';
export const WG_LOCAL_ADDRESS_V6 = '2606:4700:110:8f81:d551:a0:532e:a2b3/128';
export const WG_LOCAL_MTU = '1420';
export const WG_LOCAL_REMOTE_DNS = '1.1.1.1,1.0.0.1,2606:4700:4700::1111,2606:4700:4700::1001';

/** Port of com.v2ray.ang.fmt.WireguardFmt (URI + .conf file forms). */
export class WireguardFmt {
  static parse(str: string): ProfileItem | null {
    const uri: UriParts | null = parseUri(str);
    if (uri === null || uri.rawQuery.length === 0) {
      return null;
    }
    const q = getQueryParamMap(uri.rawQuery);

    const config = ProfileItem.create(EConfigType.WIREGUARD);
    config.remarks = uri.fragment.length === 0 ? 'none' : uri.fragment;
    config.server = uri.idnHost;
    config.serverPort = uri.port.toString();
    config.secretKey = uri.userInfo;
    config.localAddress = q.has('address') ? (q.get('address') as string) : WG_LOCAL_ADDRESS_V4;
    config.publicKey = q.has('publickey') ? (q.get('publickey') as string) : '';
    const psk = nullIfBlank(q.has('presharedkey') ? (q.get('presharedkey') as string) : null);
    config.preSharedKey = psk === null ? '' : psk;
    config.mtu = parseIntOrZero(q.has('mtu') ? (q.get('mtu') as string) : WG_LOCAL_MTU);
    config.remoteDNS = q.has('dns') ? (q.get('dns') as string) : WG_LOCAL_REMOTE_DNS;
    config.reserved = q.has('reserved') ? (q.get('reserved') as string) : '0,0,0';
    const fm = q.has('fm') ? (q.get('fm') as string)
      : (q.has('finalmask') ? (q.get('finalmask') as string)
        : (q.has('finalMask') ? (q.get('finalMask') as string) : null));
    const fm2 = nullIfBlank(fm);
    config.finalMask = fm2 === null ? '' : fm2;
    return config;
  }

  static parseConfFile(str: string): ProfileItem {
    const iface = new Map<string, string>();
    const peer = new Map<string, string>();
    let section = '';

    for (const rawLine of str.split('\n')) {
      const line = rawLine.trim();
      if (line.length === 0 || line.startsWith('#')) {
        continue;
      }
      const lower = line.toLowerCase();
      if (lower.startsWith('[interface]')) {
        section = 'Interface';
      } else if (lower.startsWith('[peer]')) {
        section = 'Peer';
      } else if (section.length > 0) {
        const eq = line.indexOf('=');
        if (eq >= 0) {
          const key = line.substring(0, eq).trim().toLowerCase();
          const value = line.substring(eq + 1).trim();
          if (section === 'Interface') {
            iface.set(key, value);
          } else {
            peer.set(key, value);
          }
        }
      }
    }

    const config = ProfileItem.create(EConfigType.WIREGUARD);
    config.secretKey = iface.has('privatekey') ? (iface.get('privatekey') as string) : '';
    config.remarks = Date.now().toString();
    config.localAddress = iface.has('address') ? (iface.get('address') as string) : WG_LOCAL_ADDRESS_V4;
    config.mtu = parseIntOrZero(iface.has('mtu') ? (iface.get('mtu') as string) : WG_LOCAL_MTU);
    config.remoteDNS = iface.has('dns') ? (iface.get('dns') as string) : WG_LOCAL_REMOTE_DNS;
    config.publicKey = peer.has('publickey') ? (peer.get('publickey') as string) : '';
    const psk = nullIfBlank(peer.has('presharedkey') ? (peer.get('presharedkey') as string) : null);
    config.preSharedKey = psk === null ? '' : psk;

    const endpoint = peer.has('endpoint') ? (peer.get('endpoint') as string) : '';
    const colon = endpoint.lastIndexOf(':');
    if (colon > 0) {
      config.server = endpoint.substring(0, colon);
      config.serverPort = endpoint.substring(colon + 1);
    } else {
      config.server = endpoint;
      config.serverPort = '';
    }
    config.reserved = peer.has('reserved') ? (peer.get('reserved') as string) : '0,0,0';
    const fm = peer.has('finalmask') ? (peer.get('finalmask') as string)
      : (peer.has('fm') ? (peer.get('fm') as string)
        : (iface.has('finalmask') ? (iface.get('finalmask') as string)
          : (iface.has('fm') ? (iface.get('fm') as string) : null)));
    const fm2 = nullIfBlank(fm);
    config.finalMask = fm2 === null ? '' : fm2;
    return config;
  }

  static toUri(config: ProfileItem): string {
    const d = new Map<string, string>();
    d.set('publickey', config.publicKey);
    d.set('reserved', removeWhiteSpace(config.reserved));
    d.set('address', removeWhiteSpace(config.localAddress));
    if (config.mtu !== 0) {
      d.set('mtu', config.mtu.toString());
    }
    if (config.preSharedKey.length > 0) {
      d.set('presharedkey', removeWhiteSpace(config.preSharedKey));
    }
    if (config.remoteDNS.length > 0) {
      d.set('dns', removeWhiteSpace(config.remoteDNS));
    }
    if (config.finalMask.trim().length > 0) {
      d.set('fm', config.finalMask);
    }
    return FmtQuery.buildUri(config, config.secretKey, d);
  }
}
