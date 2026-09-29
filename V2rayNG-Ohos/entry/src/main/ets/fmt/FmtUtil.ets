import buffer from '@ohos.buffer';
import { Log } from '../util/Log';

/**
 * Shared helpers for the share-link parsers — the HarmonyOS counterpart of
 * com.v2ray.ang.util.Utils (the subset fmt/ needs) plus the parts of
 * java.net.URI that the Kotlin parsers rely on.
 *
 * Behaviour deliberately mirrors the Kotlin/Java semantics rather than the
 * WHATWG URL semantics, because node links in the wild are parsed by the
 * Android build with java.net.URI and the two differ on the edges that matter
 * here (percent-decoding of userInfo/fragment, host validation, port = -1).
 */

const BASE64_STANDARD = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
const BASE64_URLSAFE = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

function hex2(n: number): string {
  const s = n.toString(16).toUpperCase();
  return s.length >= 2 ? s : '0' + s;
}

/** Utils.encode(text, removePadding) — standard base64, padding optionally trimmed. */
export function base64Encode(text: string, removePadding: boolean): string {
  try {
    const encoded = buffer.from(text, 'utf-8').toString('base64');
    if (removePadding) {
      let end = encoded.length;
      while (end > 0 && encoded.charAt(end - 1) === '=') {
        end--;
      }
      return encoded.substring(0, end);
    }
    return encoded;
  } catch (e) {
    Log.e('base64Encode failed: ' + JSON.stringify(e));
    return '';
  }
}

function tryDecodeAlphabet(text: string, urlSafe: boolean): string | null {
  if (text.length === 0) {
    return null;
  }
  const alphabet = urlSafe ? BASE64_URLSAFE : BASE64_STANDARD;
  let body = text;
  while (body.length > 0 && body.charAt(body.length - 1) === '=') {
    body = body.substring(0, body.length - 1);
  }
  // android.util.Base64 throws on any character outside the alphabet; reject
  // instead of letting the platform decoder silently drop characters.
  for (let i = 0; i < body.length; i++) {
    if (alphabet.indexOf(body.charAt(i)) < 0) {
      return null;
    }
  }
  const rem = body.length % 4;
  if (rem === 1) {
    return null; // impossible base64 length
  }
  let padded = body;
  if (rem === 2) {
    padded += '==';
  } else if (rem === 3) {
    padded += '=';
  }
  try {
    if (urlSafe) {
      padded = padded.split('-').join('+').split('_').join('/');
    }
    return buffer.from(padded, 'base64').toString('utf-8');
  } catch (e) {
    return null;
  }
}

/**
 * Utils.decode(text): try standard base64, then URL-safe, then the same two
 * with trailing '=' trimmed. Returns '' when nothing decodes.
 */
export function base64Decode(text: string): string {
  if (!text || text.length === 0) {
    return '';
  }
  let r = tryDecodeAlphabet(text, false);
  if (r !== null) {
    return r;
  }
  r = tryDecodeAlphabet(text, true);
  if (r !== null) {
    return r;
  }
  let trimmed = text;
  while (trimmed.length > 0 && trimmed.charAt(trimmed.length - 1) === '=') {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  r = tryDecodeAlphabet(trimmed, false);
  if (r !== null) {
    return r;
  }
  r = tryDecodeAlphabet(trimmed, true);
  if (r !== null) {
    return r;
  }
  return '';
}

/**
 * Utils.encodeURIComponent(s): java URLEncoder semantics — unreserved set is
 * A-Za-z0-9 plus ".", "-", "*", "_", everything else (including "~") is
 * percent-encoded, and space becomes %20 (URLEncoder would emit "+").
 */
export function encodeURIComponentExt(s: string): string {
  let out = '';
  const bytes: buffer.Buffer = buffer.from(s, 'utf-8');
  for (let i = 0; i < bytes.length; i++) {
    const b: number = bytes[i];
    const c = String.fromCharCode(b);
    const isAlphaNum = (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39);
    if (isAlphaNum || c === '.' || c === '-' || c === '*' || c === '_') {
      out += c;
    } else if (c === ' ') {
      out += '%20';
    } else {
      out += '%' + hex2(b);
    }
  }
  return out;
}

function isHexDigit(c: string): boolean {
  return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

/**
 * Utils.decodeURIComponent(s): '+' is a literal plus and must NOT become a
 * space; a malformed escape returns the input unchanged (URLDecoder throws and
 * the Kotlin helper swallows it).
 */
export function decodeURIComponentExt(s: string): string {
  const t = s.split('+').join('%2B');
  const bytes: number[] = [];
  let i = 0;
  while (i < t.length) {
    const c = t.charAt(i);
    if (c === '%') {
      if (i + 2 >= t.length) {
        return s;
      }
      const h1 = t.charAt(i + 1);
      const h2 = t.charAt(i + 2);
      if (!isHexDigit(h1) || !isHexDigit(h2)) {
        return s;
      }
      bytes.push(Number.parseInt(h1 + h2, 16));
      i += 3;
    } else {
      const chunk = buffer.from(c, 'utf-8');
      for (let k = 0; k < chunk.length; k++) {
        bytes.push(chunk[k]);
      }
      i += 1;
    }
  }
  try {
    const arr = new Uint8Array(bytes.length);
    for (let k = 0; k < bytes.length; k++) {
      arr[k] = bytes[k];
    }
    return buffer.from(arr).toString('utf-8');
  } catch (e) {
    return s;
  }
}

/** Utils.fixIllegalUrl: spaces and pipes break java.net.URI. */
export function fixIllegalUrl(s: string): string {
  return s.split(' ').join('%20').split('|').join('%7C');
}

/** Utils.getIpv6Address: wrap a bare IPv6 literal in brackets. */
export function getIpv6Address(address: string): string {
  if (!address || address.length === 0) {
    return '';
  }
  if (isIpv6Address(address) && address.indexOf('[') < 0 && address.indexOf(']') < 0) {
    return '[' + address + ']';
  }
  return address;
}

export function isIpv4Address(s: string): boolean {
  const parts = s.split('.');
  if (parts.length !== 4) {
    return false;
  }
  for (const p of parts) {
    if (p.length === 0 || p.length > 3) {
      return false;
    }
    for (let i = 0; i < p.length; i++) {
      const c = p.charAt(i);
      if (c < '0' || c > '9') {
        return false;
      }
    }
    if (Number.parseInt(p, 10) > 255) {
      return false;
    }
  }
  return true;
}

export function isIpv6Address(s: string): boolean {
  if (s.length === 0 || s.indexOf(':') < 0) {
    return false;
  }
  const inner = s.startsWith('[') && s.endsWith(']') ? s.substring(1, s.length - 1) : s;
  if (inner.indexOf(':') < 0) {
    return false;
  }
  if (inner.indexOf('%') >= 0) {
    return false; // no zone id support
  }
  let value = inner;
  // IPv4-mapped tail is allowed
  const lastColon = value.lastIndexOf(':');
  const tail = value.substring(lastColon + 1);
  if (tail.indexOf('.') >= 0) {
    if (!isIpv4Address(tail)) {
      return false;
    }
    value = value.substring(0, lastColon + 1) + '0:0';
  }
  const halves = value.split('::');
  if (halves.length > 2) {
    return false;
  }
  const validGroup = (g: string): boolean => {
    if (g.length === 0 || g.length > 4) {
      return false;
    }
    for (let i = 0; i < g.length; i++) {
      if (!isHexDigit(g.charAt(i))) {
        return false;
      }
    }
    return true;
  };
  const left = halves[0].length > 0 ? halves[0].split(':') : [];
  const right = halves.length === 2 && halves[1].length > 0 ? halves[1].split(':') : [];
  for (const g of left) {
    if (!validGroup(g)) {
      return false;
    }
  }
  for (const g of right) {
    if (!validGroup(g)) {
      return false;
    }
  }
  if (halves.length === 1) {
    return left.length === 8;
  }
  return left.length + right.length <= 7;
}

/** Utils.parseInt. */
export function parseIntOrZero(s: string): number {
  const n = Number.parseInt(s, 10);
  return Number.isNaN(n) ? 0 : n;
}

/**
 * java.net.URI-ish parser. Returns null when the string has no scheme or the
 * authority cannot be read as a server authority (java returns host == null /
 * idnHost empty in that case, which every caller treats as "not this link").
 */
export class UriParts {
  scheme: string = '';
  /** percent-decoded, like URI.getUserInfo() */
  userInfo: string = '';
  /** host as written; punycode conversion is NOT applied (see docs/OHOS_PORT.md) */
  idnHost: string = '';
  /** -1 when absent, like URI.getPort() */
  port: number = -1;
  /** raw, like URI.getRawQuery() */
  rawQuery: string = '';
  /** percent-decoded, like URI.getFragment() */
  fragment: string = '';
}

function isValidRegName(host: string): boolean {
  // Mirrors java.net.URI's server-authority hostname rule closely enough for
  // node links: dot-separated labels of [A-Za-z0-9-] that neither start nor
  // end with '-'.  Empty labels ("host..com", "host.com.", ".host.com") and
  // leading/trailing hyphens ("-host.com", "host-.com") are rejected, which is
  // what java.net.URI does too.
  if (host.length === 0) {
    return false;
  }
  for (const label of host.split('.')) {
    if (label.length === 0) {
      return false;
    }
    if (label.charAt(0) === '-' || label.charAt(label.length - 1) === '-') {
      return false;
    }
    for (let i = 0; i < label.length; i++) {
      const c = label.charAt(i);
      const ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c === '-';
      if (!ok) {
        return false;
      }
    }
  }
  return true;
}

export function parseUri(str: string): UriParts | null {
  const s = fixIllegalUrl(str);
  const schemeEnd = s.indexOf(':');
  if (schemeEnd <= 0) {
    return null;
  }
  const parts = new UriParts();
  parts.scheme = s.substring(0, schemeEnd);
  let rest = s.substring(schemeEnd + 1);
  if (!rest.startsWith('//')) {
    return null;
  }
  rest = rest.substring(2);

  // authority ends at the first '/', '?' or '#'
  let authEnd = rest.length;
  for (let i = 0; i < rest.length; i++) {
    const c = rest.charAt(i);
    if (c === '/' || c === '?' || c === '#') {
      authEnd = i;
      break;
    }
  }
  let authority = rest.substring(0, authEnd);
  let tail = rest.substring(authEnd);

  // path | query | fragment, in that order
  let pathAndQuery = tail;
  let fragment = '';
  const hashIdx = tail.indexOf('#');
  if (hashIdx >= 0) {
    fragment = tail.substring(hashIdx + 1);
    pathAndQuery = tail.substring(0, hashIdx);
  }
  let query = '';
  const qIdx = pathAndQuery.indexOf('?');
  if (qIdx >= 0) {
    query = pathAndQuery.substring(qIdx + 1);
  }

  const atIdx = authority.lastIndexOf('@');
  let hostPort = authority;
  if (atIdx >= 0) {
    parts.userInfo = decodeURIComponentExt(authority.substring(0, atIdx));
    hostPort = authority.substring(atIdx + 1);
  }

  let host = hostPort;
  if (hostPort.startsWith('[')) {
    const close = hostPort.indexOf(']');
    if (close < 0) {
      return null;
    }
    host = hostPort.substring(1, close);
    const after = hostPort.substring(close + 1);
    if (after.length > 0) {
      if (!after.startsWith(':')) {
        return null;
      }
      const p = after.substring(1);
      parts.port = p.length === 0 ? -1 : parseIntOrZero(p);
    }
    if (!isIpv6Address(host)) {
      return null;
    }
    const bracketless = host;
    host = bracketless;
  } else {
    const colon = hostPort.lastIndexOf(':');
    if (colon >= 0) {
      host = hostPort.substring(0, colon);
      const p = hostPort.substring(colon + 1);
      parts.port = p.length === 0 ? -1 : parseIntOrZero(p);
    }
    if (!isIpv4Address(host) && !isValidRegName(host)) {
      return null;
    }
  }
  parts.idnHost = host;
  parts.rawQuery = query;
  parts.fragment = decodeURIComponentExt(fragment);
  return parts;
}

/**
 * FmtBase.getQueryParam: split on '&' then on '='. Like the Kotlin original,
 * a token without '=' is an error and propagates to the caller (which returns
 * null), rather than being silently ignored.
 */
export function getQueryParamMap(rawQuery: string): Map<string, string> {
  const out = new Map<string, string>();
  if (rawQuery.length === 0) {
    return out;
  }
  for (const token of rawQuery.split('&')) {
    const eq = token.indexOf('=');
    if (eq < 0) {
      throw new Error('query parameter without "=": ' + token);
    }
    const k = token.substring(0, eq);
    const v = token.substring(eq + 1);
    out.set(k, decodeURIComponentExt(v));
  }
  return out;
}

/** "" -> null, mirroring Kotlin's nullIfBlank(). */
export function nullIfBlank(s: string | null): string | null {
  if (s === null) {
    return null;
  }
  return s.trim().length === 0 ? null : s;
}

export function isNotNullEmpty(s: string | null): boolean {
  return s !== null && s.length > 0;
}

/** Kotlin removeWhiteSpace(). */
export function removeWhiteSpace(s: string): string {
  return s.split(' ').join('').split('\t').join('').split('\r').join('').split('\n').join('');
}
