import { ProfileItem, EConfigType } from '../model/Profile';
import { Log } from '../util/Log';

/**
 * Port of com.v2ray.ang.fmt.CustomFmt: a whole Xray JSON config pasted as a
 * server entry.
 *
 * Simplification vs. the Android original: the Kotlin version deserialises the
 * full V2rayConfig and asks the proxy outbound for its address/port through
 * typed accessors. This port declares the small slice of that schema it needs
 * (`remarks`, `outbounds[].tag`, `outbounds[].settings.vnext|servers[].address|port`)
 * and reads the two display fields from it. The config body itself is stored
 * verbatim and used unchanged at connect time, so nothing is lost.
 */

class AddrPortItem {
  address: string = '';
  port: number = 0;
}

class OutboundSettings {
  vnext: AddrPortItem[] = [];
  servers: AddrPortItem[] = [];
}

class OutboundBean {
  tag: string = '';
  settings: OutboundSettings | null = null;
}

class CustomConfigRoot {
  remarks: string = '';
  outbounds: OutboundBean[] = [];
}

export class CustomFmt {
  static parse(str: string): ProfileItem | null {
    let root: CustomConfigRoot;
    try {
      root = JSON.parse(str) as CustomConfigRoot;
    } catch (e) {
      Log.w('custom: not a JSON config');
      return null;
    }
    if (root === null || root === undefined) {
      return null;
    }

    const config = ProfileItem.create(EConfigType.CUSTOM);
    config.remarks = (root.remarks !== undefined && root.remarks !== null && root.remarks.length > 0)
      ? root.remarks : Date.now().toString();

    const addr = CustomFmt.extractAddress(root);
    config.server = addr[0];
    config.serverPort = addr[1];
    // The whole JSON is the configuration; CoreConfigManager uses it verbatim
    // (buildV2rayCustomConfig), so keep it on the profile.
    config.rawJson = str;
    return config;
  }

  /** Returns [address, port-as-string]; blanks when nothing usable is found. */
  private static extractAddress(root: CustomConfigRoot): string[] {
    const out: string[] = ['', ''];
    const list = root.outbounds;
    if (list === undefined || list === null) {
      return out;
    }
    for (const ob of list) {
      const tag = ob.tag;
      if (tag !== undefined && tag !== null && tag.length > 0 && tag !== 'proxy') {
        continue;
      }
      const settings = ob.settings;
      if (settings === undefined || settings === null) {
        continue;
      }
      const candidates: AddrPortItem[] = (settings.vnext !== undefined && settings.vnext !== null)
        ? settings.vnext : settings.servers;
      if (candidates === undefined || candidates === null || candidates.length === 0) {
        continue;
      }
      const first = candidates[0];
      out[0] = first.address !== undefined && first.address !== null ? first.address : '';
      out[1] = first.port !== undefined && first.port !== null ? first.port.toString() : '';
      return out;
    }
    return out;
  }

  static toUri(config: ProfileItem): string {
    // A custom config has no share-link form in the Android build either.
    return '';
  }
}
