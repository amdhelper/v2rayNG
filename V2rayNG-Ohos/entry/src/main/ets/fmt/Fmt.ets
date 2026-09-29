import { ProfileItem, EConfigType } from '../model/Profile';
import { base64Decode } from './FmtUtil';
import { VmessFmt } from './VmessFmt';
import { VlessFmt } from './VlessFmt';
import { ShadowsocksFmt } from './ShadowsocksFmt';
import { TrojanFmt } from './TrojanFmt';
import { Hysteria2Fmt } from './Hysteria2Fmt';
import { SocksFmt } from './SocksFmt';
import { WireguardFmt } from './WireguardFmt';
import { V2rayNFmt } from './V2rayNFmt';
import { CustomFmt } from './CustomFmt';
import { Log } from '../util/Log';

/**
 * Share-link dispatcher — the HarmonyOS counterpart of the `configFmtParsers`
 * map in com.v2ray.ang.handler.AngConfigManager, i.e. the same scheme ->
 * parser table the Android build routes on.
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

      // Raw Xray JSON config (EConfigType.CUSTOM; AppConfig.CUSTOM == "").
      if (s.charAt(0) === '{') {
        return CustomFmt.parse(s);
      }
      // A whole WireGuard .conf file.
      if (lower.indexOf('[interface]') >= 0) {
        return WireguardFmt.parseConfFile(s);
      }
      if (lower.startsWith('vmess://')) {
        return VmessFmt.parse(s);
      }
      if (lower.startsWith('ss://')) {
        return ShadowsocksFmt.parse(s);
      }
      if (lower.startsWith('socks://') || lower.startsWith('socks4://') || lower.startsWith('socks5://')) {
        return SocksFmt.parse(s);
      }
      if (lower.startsWith('trojan://')) {
        return TrojanFmt.parse(s);
      }
      if (lower.startsWith('vless://')) {
        return VlessFmt.parse(s);
      }
      if (lower.startsWith('wireguard://')) {
        return WireguardFmt.parse(s);
      }
      if (lower.startsWith('hysteria2://') || lower.startsWith('hy2://')) {
        return Hysteria2Fmt.parse(s);
      }
      // Desktop-client share format. AngConfigManager does not route this
      // scheme; it is accepted here because subscriptions exported by v2rayN
      // routinely contain it, and dropping them silently would be worse.
      if (lower.startsWith('v2rayn://')) {
        return V2rayNFmt.parse(s);
      }
      Log.w('Fmt.parse: unrecognised link scheme');
      return null;
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
      case EConfigType.WIREGUARD: return WireguardFmt.toUri(profile);
      case EConfigType.CUSTOM: return CustomFmt.toUri(profile);
      default: return '';
    }
  }

  /**
   * Parses a subscription payload: a list of share links (newline separated)
   * or a base64-encoded blob of such a list. Mirrors the decode step in
   * com.v2ray.ang.handler.SubscriptionUpdater.
   */
  static parseSubscription(text: string): ProfileItem[] {
    let body = (text ?? '').trim();
    if (body.length === 0) {
      return [];
    }
    const first = body.charAt(0);
    if (body.indexOf('://') < 0 && first !== '{' && first !== '[') {
      const decoded = base64Decode(body);
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