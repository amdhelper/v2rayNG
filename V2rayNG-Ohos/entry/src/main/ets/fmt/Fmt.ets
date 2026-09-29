import { ProfileItem, EConfigType } from '../model/Profile';
import { VmessFmt } from './VmessFmt';
import { VlessFmt } from './VlessFmt';
import { ShadowsocksFmt } from './ShadowsocksFmt';
import { TrojanFmt } from './TrojanFmt';
import { Hysteria2Fmt } from './Hysteria2Fmt';
import { SocksFmt } from './SocksFmt';
import { V2rayNFmt } from './V2rayNFmt';
import { CustomFmt } from './CustomFmt';
import { Log } from '../util/Log';

/**
 * Share-link dispatcher — the HarmonyOS counterpart of
 * com.v2ray.ang.fmt.FmtBase.
 *
 * Every protocol module exposes the same two statics:
 *   parse(str: string): ProfileItem | null
 *   toUri(profile: ProfileItem): string
 */
export class Fmt {
  static parse(str: string): ProfileItem | null {
    const s = (str ?? '').trim();
    if (s.length === 0) {
      return null;
    }
    try {
      const lower = s.toLowerCase();
      if (lower.startsWith('vmess://')) {
        return VmessFmt.parse(s);
      }
      if (lower.startsWith('vless://')) {
        return VlessFmt.parse(s);
      }
      if (lower.startsWith('ss://')) {
        return ShadowsocksFmt.parse(s);
      }
      if (lower.startsWith('trojan://')) {
        return TrojanFmt.parse(s);
      }
      if (lower.startsWith('hysteria2://') || lower.startsWith('hy2://')) {
        return Hysteria2Fmt.parse(s);
      }
      if (lower.startsWith('socks://')) {
        return SocksFmt.parse(s);
      }
      if (lower.startsWith('http://') || lower.startsWith('https://')) {
        return CustomFmt.parse(s);
      }
      // v2rayN-style "protocol,param=value,..." lines (optionally prefixed
      // by `remark,`), used by clipboards exported from the desktop client.
      return V2rayNFmt.parse(s);
    } catch (e) {
      Log.e('Fmt.parse failed: ' + JSON.stringify(e));
      return null;
    }
  }

  static toUri(profile: ProfileItem): string {
    switch (profile.configType) {
      case EConfigType.VMESS: return VmessFmt.toUri(profile);
      case EConfigType.VLESS: return VlessFmt.toUri(profile);
      case EConfigType.SHADOWSOCKS: return ShadowsocksFmt.toUri(profile);
      case EConfigType.TROJAN: return TrojanFmt.toUri(profile);
      case EConfigType.HYSTERIA2: return Hysteria2Fmt.toUri(profile);
      case EConfigType.SOCKS: return SocksFmt.toUri(profile);
      case EConfigType.CUSTOM: return CustomFmt.toUri(profile);
      default: return V2rayNFmt.toUri(profile);
    }
  }

  /**
   * Parses a subscription payload: either a plain list of share links
   * (newline separated) or a base64-encoded blob of such a list.
   * Mirrors com.v2ray.ang.handler.SubscriptionUpdater's decode behaviour.
   */
  static parseSubscription(text: string): ProfileItem[] {
    let body = (text ?? '').trim();
    if (body.length === 0) {
      return [];
    }
    if (!body.includes('://')) {
      const decoded = base64DecodeLenient(body);
      if (decoded.length > 0) {
        body = decoded;
      }
    }
    const out: ProfileItem[] = [];
    for (const line of body.split('\n')) {
      const item = Fmt.parse(line.trim());
      if (item !== null) {
        out.push(item);
      }
    }
    return out;
  }
}

/** base64 decode that tolerates missing padding, URL-safe alphabet and blanks. */
export function base64DecodeLenient(s: string): string {
  let t = s.replace(/-/g, '+').replace(/_/g, '/').replace(/\s+/g, '');
  const pad = t.length % 4;
  if (pad === 2) {
    t += '==';
  } else if (pad === 3) {
    t += '=';
  } else if (pad === 1) {
    return '';
  }
  try {
    return buffer.from(t, 'base64').toString('utf-8');
  } catch (e) {
    return '';
  }
}
