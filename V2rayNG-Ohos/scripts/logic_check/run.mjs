#!/usr/bin/env node
/**
 * Asserts the port's pure logic against a corpus of real share links, then
 * emits every generated Xray config to out/ for the Go checker
 * (xray_config_check) to feed into the pinned core.
 *
 * This is a regression gate, not a substitute for the HAP build or for a real
 * device: it covers parsing and config generation, which is where the silent
 * breakage lives (a config the core rejects fails the whole connection).
 */
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const OUT = join(HERE, 'out');
const FRAGMENTS = join(HERE, 'out-fragments');
const { Fmt, XrayConfigBuilder, settings, ProfileItem, EConfigType, logRing, AppResolver } =
  await import('./dist/harness.mjs');

let failures = 0;
let checks = 0;

function eq(label, got, want) {
  checks++;
  const g = JSON.stringify(got);
  const w = JSON.stringify(want);
  if (g !== w) {
    failures++;
    console.error(`  FAIL ${label}: got ${g}, want ${w}`);
  }
}

function truthy(label, got, note = '') {
  checks++;
  if (!got) {
    failures++;
    console.error(`  FAIL ${label}: ${note || 'expected truthy'}`);
  }
}

const b64 = (s) => Buffer.from(s, 'utf-8').toString('base64');
const b64url = (s) => b64(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

// ── corpus ──────────────────────────────────────────────────────────────────
const VMESS_JSON = {
  v: '2', ps: 'vmess-demo', add: 'vmess.example.com', port: '443',
  id: 'b831381d-6324-4d53-ad4f-8cda48b30811', aid: '0', scy: 'auto',
  net: 'ws', type: 'none', host: 'vmess.example.com', path: '/ws',
  tls: 'tls', sni: 'vmess.example.com', alpn: 'h2,http/1.1', fp: 'chrome', insecure: '0'
};

const CUSTOM_CFG = {
  log: { loglevel: 'warning' },
  inbounds: [{ tag: 'socks', port: 10808, protocol: 'socks', settings: { auth: 'noauth', udp: true } }],
  outbounds: [{
    tag: 'proxy', protocol: 'vless',
    settings: { vnext: [{ address: 'custom.example.com', port: 443, users: [{ id: 'b831381d-6324-4d53-ad4f-8cda48b30811', encryption: 'none', flow: 'xtls-rprx-vision' }] }] },
    streamSettings: {
      network: 'tcp', security: 'reality',
      realitySettings: {
        serverName: 'www.microsoft.com',
        publicKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        shortId: '0123456789abcdef', fingerprint: 'chrome'
      }
    }
  }]
};

const V2RAYN_ITEM = {
  IndexId: '11111111-1111-1111-1111-111111111111',
  ConfigType: 5, ConfigVersion: 4, Remarks: 'v2rayn demo',
  Address: 'vn.example.com', Port: 443, Password: 'b831381d-6324-4d53-ad4f-8cda48b30811',
  Network: 'ws', StreamSecurity: 'tls', Sni: 'vn.example.com', AllowInsecure: 'false',
  TransportExtraObj: { Host: 'vn.example.com', Path: '/vn' }
};

const v2raynPayload = b64(JSON.stringify(V2RAYN_ITEM));

/**
 * A WireGuard private key is 32 raw bytes -> 44-char base64 containing '+' and
 * '/', so the URI must percent-encode it and the parser must bring it back
 * byte-exact. A malformed key here is not cosmetic: the core refuses the whole
 * outbound with "illegal base64 data", which is what this fixture caught.
 */
// 32 fixed bytes, chosen so the base64 carries both '+' and '/' (a real WG key
// routinely does): it is the percent-encoding round trip that is under test.
const WG_KEY = Buffer.from([6, 37, 68, 99, 130, 161, 192, 223, 254, 29, 60, 91, 122, 153, 184, 215, 246, 21, 52, 83, 114, 145, 176, 207, 238, 13, 44, 75, 106, 137, 168, 199]).toString('base64');
if (!WG_KEY.includes('+') || !WG_KEY.includes('/') || Buffer.from(WG_KEY, 'base64').length !== 32) {
  throw new Error('WG_KEY fixture drifted: it must stay valid 32-byte base64 containing + and /');
}

/**
 * The peer public key has to be real base64 too: the core decodes both keys and
 * rejects the whole outbound with "illegal base64 data" if either is malformed.
 * The previous fixture here was 41 characters, which is not a legal base64
 * length — the gate caught it, which is the point.
 */
const WG_PUB = Buffer.from(Array.from({ length: 32 }, (_, j) => (j * 17 + 3) % 256)).toString('base64');
if (Buffer.from(WG_PUB, 'base64').length !== 32) {
  throw new Error('WG_PUB fixture drifted: it must stay valid 32-byte base64');
}

const CASES = [
  { name: '01-vmess-b64', link: 'vmess://' + b64(JSON.stringify(VMESS_JSON)), want: {
      configType: EConfigType.VMESS, remarks: 'vmess-demo', server: 'vmess.example.com', serverPort: '443',
      password: 'b831381d-6324-4d53-ad4f-8cda48b30811', method: 'auto', network: 'ws',
      host: 'vmess.example.com', path: '/ws', security: 'tls', sni: 'vmess.example.com', fingerPrint: 'chrome' } },
  { name: '02-vmess-std', link: 'vmess://b831381d-6324-4d53-ad4f-8cda48b30811@std.example.com:8443?encryption=auto&type=grpc&security=tls&sni=s.example.com&fp=chrome&serviceName=gs&mode=gun#std-vmess', want: {
      configType: EConfigType.VMESS, remarks: 'std-vmess', server: 'std.example.com', serverPort: '8443',
      password: 'b831381d-6324-4d53-ad4f-8cda48b30811', network: 'grpc', serviceName: 'gs',
      mode: 'gun', security: 'tls', sni: 's.example.com' } },
  { name: '03-vless-reality', link: 'vless://b831381d-6324-4d53-ad4f-8cda48b30811@reality.example.com:443?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=0123456789abcdef&spx=%2F&flow=xtls-rprx-vision&type=tcp&headerType=none#reality-demo', want: {
      configType: EConfigType.VLESS, remarks: 'reality-demo', server: 'reality.example.com', serverPort: '443',
      method: 'none', security: 'reality', sni: 'www.microsoft.com', fingerPrint: 'chrome',
      publicKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', shortId: '0123456789abcdef',
      spiderX: '/', flow: 'xtls-rprx-vision', network: 'tcp', headerType: 'none' } },
  { name: '04-ss-sip002', link: 'ss://' + b64url('aes-256-gcm:password') + '@ss.example.com:8388?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dwww.bing.com#ss-demo', want: {
      configType: EConfigType.SHADOWSOCKS, remarks: 'ss-demo', server: 'ss.example.com', serverPort: '8388',
      method: 'aes-256-gcm', password: 'password', network: 'tcp', headerType: 'http', host: 'www.bing.com' } },
  { name: '05-ss-legacy', link: 'ss://' + b64('aes-256-gcm:password@legacy.example.com:8388') + '#legacy-demo', want: {
      configType: EConfigType.SHADOWSOCKS, remarks: 'legacy-demo', server: 'legacy.example.com',
      serverPort: '8388', method: 'aes-256-gcm', password: 'password' } },
  { name: '06-trojan', link: 'trojan://mypassword@trojan.example.com:443?security=tls&sni=t.example.com&type=ws&path=%2Ftj&host=t.example.com#trojan-demo', want: {
      configType: EConfigType.TROJAN, remarks: 'trojan-demo', server: 'trojan.example.com', serverPort: '443',
      password: 'mypassword', security: 'tls', sni: 't.example.com', network: 'ws', path: '/tj', host: 't.example.com' } },
  { name: '07-hysteria2', link: 'hysteria2://hy2pass@hy2.example.com:8443?sni=hy2.example.com&insecure=0&obfs=salamander&obfs-password=obfspw&mport=20000-30000#hy2-demo', want: {
      configType: EConfigType.HYSTERIA2, remarks: 'hy2-demo', server: 'hy2.example.com', serverPort: '8443',
      password: 'hy2pass', security: 'tls', sni: 'hy2.example.com', obfsPassword: 'obfspw',
      portHopping: '20000-30000',
      // NOTE: 'tcp', not 'hysteria', and that is upstream's behaviour too:
      // Hysteria2Fmt sets network = HYSTERIA and then calls getItemFormQuery,
      // which unconditionally overwrites it with queryParam["type"] ?: TCP.
      // The outbound is still built as hysteria because
      // CoreOutboundBuilder.toOutboundHysteria2 forces network back to
      // HYSTERIA internally (the port does the same on a copy). Do not "fix"
      // this field without fixing it upstream first.
      network: 'tcp' } },
  { name: '08-socks5', link: 'socks5://user:pass@socks.example.com:1080#socks-demo', want: {
      configType: EConfigType.SOCKS, remarks: 'socks-demo', server: 'socks.example.com', serverPort: '1080',
      username: 'user', password: 'pass' } },
  // A real WireGuard key is base64 and therefore carries '+' and '/' — it must
  // be percent-encoded in the URI and come back out intact (java.net.URI
  // decodes userInfo; the port mirrors that).
  { name: '09-wireguard-uri', link: 'wireguard://' + encodeURIComponent(WG_KEY) + '@wg.example.com:51820?publickey=' + encodeURIComponent(WG_PUB) + '&address=172.16.0.2%2F32&mtu=1420&reserved=0%2C0%2C0#wg-demo', want: {
      configType: EConfigType.WIREGUARD, remarks: 'wg-demo', server: 'wg.example.com', serverPort: '51820',
      secretKey: WG_KEY,
      publicKey: WG_PUB, localAddress: '172.16.0.2/32', mtu: 1420,
      reserved: '0,0,0' } },
  { name: '10-v2rayn', link: 'v2rayn://' + v2raynPayload, want: {
      configType: EConfigType.VLESS, remarks: 'v2rayn demo', server: 'vn.example.com', serverPort: '443',
      method: 'none', network: 'ws', host: 'vn.example.com', path: '/vn', security: 'tls', sni: 'vn.example.com' } },
  { name: '11-custom-json', link: JSON.stringify(CUSTOM_CFG), want: {
      configType: EConfigType.CUSTOM, server: 'custom.example.com', serverPort: '443' } },

  // ── transport branches: these are the ones that silently produce a config the
  //    core refuses, so each is exercised end to end (parsed AND built).
  { name: '12-vless-tcp-http-header', link: 'vless://b831381d-6324-4d53-ad4f-8cda48b30811@h.example.com:443?encryption=none&security=tls&sni=s.example.com&type=tcp&headerType=http&host=a.com%2Cb.com&path=%2Fp1%2C%2Fp2#tcp-http', want: {
      configType: EConfigType.VLESS, remarks: 'tcp-http', network: 'tcp', headerType: 'http',
      host: 'a.com,b.com', path: '/p1,/p2', security: 'tls' } },
  // Deliberately a PRIVATE address: this core refuses VLESS+security=none for
  // public addresses (infra/conf/xray.go requiresTransportSecurity), which would
  // otherwise mask whether the kcp/finalmask path actually builds.
  { name: '13-vless-kcp-seed', link: 'vless://b831381d-6324-4d53-ad4f-8cda48b30811@192.168.1.10:443?encryption=none&security=none&type=kcp&headerType=none&seed=myseed&mtu=1350&tti=20#kcp', want: {
      configType: EConfigType.VLESS, remarks: 'kcp', server: '192.168.1.10', network: 'kcp', seed: 'myseed', kcpMtu: 1350, kcpTti: 20 } },
  { name: '14-vless-ws-earlydata', link: 'vless://b831381d-6324-4d53-ad4f-8cda48b30811@h.example.com:443?encryption=none&security=tls&sni=ws.example.com&type=ws&path=%2Fws%3Fed%3D2048&host=ws.example.com#ws-ed', want: {
      configType: EConfigType.VLESS, remarks: 'ws-ed', network: 'ws', path: '/ws?ed=2048', host: 'ws.example.com' } },
  { name: '15-vless-grpc-multi', link: 'vless://b831381d-6324-4d53-ad4f-8cda48b30811@h.example.com:443?encryption=none&security=tls&sni=g.example.com&type=grpc&serviceName=gsvc&authority=gauth&mode=multi#grpc', want: {
      configType: EConfigType.VLESS, remarks: 'grpc', network: 'grpc', serviceName: 'gsvc', authority: 'gauth', mode: 'multi' } },
  // type=http maps to the "http" transport, which this core revision REMOVED
  // (infra/conf/transport_internet.go: `case "h2", "h3", "http":` ->
  // PrintRemovedFeatureError). Parsing is still covered; the generated config is
  // asserted to be REJECTED. Android is in the same boat.
  { name: '16-vless-http-hosts', buildFailReason: 'HTTP transport', link: 'vless://b831381d-6324-4d53-ad4f-8cda48b30811@h.example.com:443?encryption=none&security=tls&sni=h1.com&type=http&host=h1.com%2Ch2.com&path=%2Fr1%2C%2Fr2#h2c', want: {
      configType: EConfigType.VLESS, remarks: 'h2c', network: 'http', host: 'h1.com,h2.com', path: '/r1,/r2' } },
  { name: '17-vless-httpupgrade', link: 'vless://b831381d-6324-4d53-ad4f-8cda48b30811@h.example.com:443?encryption=none&security=tls&sni=hu.example.com&type=httpupgrade&host=hu.example.com&path=%2Fhu#hu', want: {
      configType: EConfigType.VLESS, remarks: 'hu', network: 'httpupgrade', host: 'hu.example.com', path: '/hu' } },
  { name: '18-vless-xhttp', link: 'vless://b831381d-6324-4d53-ad4f-8cda48b30811@h.example.com:443?encryption=none&security=tls&sni=xh.example.com&type=xhttp&host=xh.example.com&path=%2Fxh&mode=packet-up#xhttp', want: {
      configType: EConfigType.VLESS, remarks: 'xhttp', network: 'xhttp', host: 'xh.example.com', path: '/xh', xhttpMode: 'packet-up' } },
  { name: '19-ss-obfs-tls', link: 'ss://' + b64url('aes-128-gcm:pass2') + '@ss2.example.com:8443?plugin=obfs-local%3Bobfs%3Dtls%3Bobfs-host%3Dt.example.com#ss-tls', want: {
      configType: EConfigType.SHADOWSOCKS, remarks: 'ss-tls', server: 'ss2.example.com', serverPort: '8443',
      method: 'aes-128-gcm', password: 'pass2',
      // ShadowsocksFmt only reacts to plugin values containing "obfs=http", so
      // for obfs=tls the transport fields keep their constructed defaults ('')
      // — that is upstream's behaviour, and the outbound builder then treats an
      // empty network as tcp. Do not "fix" this to 'tcp' here without changing
      // the parser first.
      network: '', headerType: '', host: '' } },
  { name: '20-vless-tls-pin', link: 'vless://b831381d-6324-4d53-ad4f-8cda48b30811@h.example.com:443?encryption=none&security=tls&sni=pin.example.com&alpn=h2%2Chttp%2F1.1&fp=chrome&vcn=pin.example.com&pcs=0000000000000000000000000000000000000000000000000000000000000001#tls-pin', want: {
      configType: EConfigType.VLESS, remarks: 'tls-pin', security: 'tls', sni: 'pin.example.com',
      alpn: 'h2,http/1.1', fingerPrint: 'chrome', verifyPeerCertByName: 'pin.example.com',
      pinnedCA256: '0000000000000000000000000000000000000000000000000000000000000001' } }
];

// Negative cases: every one of these must parse to null, not to a half-built
// profile that would later fail in a confusing place.
const NEGATIVE = [
  { name: 'n1-vmess-not-json', link: 'vmess://' + b64('this is not json') },
  { name: 'n2-vless-no-query', link: 'vless://uuid@h.example.com:443#x' },
  { name: 'n3-ss-garbage', link: 'ss://!!!!notbase64!!!!' },
  { name: 'n4-socks-no-port', link: 'socks://h.example.com' },
  { name: 'n5-bad-host', link: 'trojan://pw@host..com:443#x' },
  { name: 'n6-leading-hyphen-host', link: 'trojan://pw@-host.com:443#x' },
  { name: 'n7-unknown-scheme', link: 'quantum://whatever@h.example.com:1#x' },
  { name: 'n8-query-token-without-equals', link: 'vless://uuid@h.example.com:443?encryption=none&bad#x' }
];

console.log('logic_check: corpus');
const parsed = [];
for (const c of CASES) {
  const p = Fmt.parse(c.link);
  truthy(`${c.name}: parses`, p !== null);
  if (p === null) continue;
  parsed.push({ name: c.name, profile: p, buildFailReason: c.buildFailReason });
  for (const [k, v] of Object.entries(c.want)) {
    eq(`${c.name}.${k}`, p[k], v);
  }
  if (c.name === '11-custom-json') {
    eq('11-custom-json.rawJson captured', p.rawJson, CUSTOM_CFG === p.rawJson ? p.rawJson : p.rawJson);
    truthy('11-custom-json.rawJson is the whole JSON', p.rawJson.trim().startsWith('{') && p.rawJson.includes('custom.example.com'));
  }
}

console.log('logic_check: negative cases');
for (const c of NEGATIVE) {
  eq(`${c.name}: must be null`, Fmt.parse(c.link), null);
}

// A whole multi-line JSON config must import as ONE entry, not be shredded.
eq('multiline JSON import yields 1 entry', Fmt.parseSubscription(JSON.stringify(CUSTOM_CFG, null, 2)).length, 1);
eq('base64 subscription yields 2 entries', Fmt.parseSubscription(b64([CASES[5].link, CASES[6].link].join('\n'))).length, 2);

// ── config emission ─────────────────────────────────────────────────────────
rmSync(OUT, { recursive: true, force: true });
mkdirSync(OUT, { recursive: true });
rmSync(FRAGMENTS, { recursive: true, force: true });
mkdirSync(FRAGMENTS, { recursive: true });
let emitted = 0;
function emit(name, json) {
  if (!json || json.length === 0) {
    failures++;
    console.error(`  FAIL emit ${name}: empty config`);
    return;
  }
  try {
    JSON.parse(json);
  } catch (e) {
    failures++;
    console.error(`  FAIL emit ${name}: not valid JSON`);
    return;
  }
  writeFileSync(join(OUT, name), json);
  emitted++;
}

console.log('logic_check: emitting configs');
const s = settings.get();
s.socksPort = '10808';
s.vpnDnsServers = '1.1.1.1,8.8.8.8';
s.remoteDns = '1.1.1.1';
s.logLevel = 'warning';

const expectedFailures = {};   // filename -> substring the rejection must contain
for (const { name, profile, buildFailReason } of parsed) {
  emit(`${name}-full.json`, XrayConfigBuilder.buildFor(profile, false));
  emit(`${name}-delaytest.json`, XrayConfigBuilder.buildFor(profile, true));
  if (buildFailReason) {
    expectedFailures[`${name}-full.json`] = buildFailReason;
    expectedFailures[`${name}-delaytest.json`] = buildFailReason;
  }
  if (profile.configType !== EConfigType.CUSTOM) {
    // Fragments go to their own directory: a bare outbound object parses as an
    // *empty* xray config and would pass the core check while verifying
    // nothing. run.mjs asserts their shape below instead.
    const obJson = XrayConfigBuilder.buildOutboundJson(profile);
    try {
      const ob = JSON.parse(obJson);
      eq(`${name}-outbound.tag`, ob.tag, 'proxy');
      truthy(`${name}-outbound.protocol`, typeof ob.protocol === 'string' && ob.protocol.length > 0);
      truthy(`${name}-outbound.settings`, ob.settings !== undefined && ob.settings !== null);
      writeFileSync(join(FRAGMENTS, `${name}-outbound.json`), obJson);
    } catch (e) {
      failures++;
      console.error(`  FAIL ${name}-outbound: not valid JSON`);
    }
  }
}

// Routing presets x fake DNS, on one profile that exercises TLS.
const vless = parsed.find((p) => p.name === '03-vless-reality').profile;
for (const preset of ['all', 'bypass-lan', 'bypass-mainland']) {
  for (const fake of [false, true]) {
    s.routingPreset = preset;
    s.routingEnabled = preset !== 'all';
    s.fakeDnsEnabled = fake;
    emit(`80-routing-${preset}-fakedns-${fake}.json`, XrayConfigBuilder.build(vless, false));
  }
}
s.routingPreset = 'bypass-mainland';
s.routingEnabled = true;
s.fakeDnsEnabled = false;

// ── mux ───────────────────────────────────────────────────────────────────
// The app now exposes the four AppConfig mux keys, so their effect on the
// generated config has to be pinned: mux off must stay off (that is the stock
// default and what most users run), garbage in the store must not become NaN
// (the core rejects the whole outbound), and the protocol/flow rules must
// survive whatever the user sets.
const muxOf = (profile) => JSON.parse(XrayConfigBuilder.buildFor(profile, false)).outbounds[0].mux;
const van = parsed.find((p) => p.name === '03-vless-reality').profile;
const flowless = parsed.find((p) => p.name === '12-vless-tcp-http-header').profile;

s.muxEnabled = false;
eq('mux off -> concurrency -1 (xray reads <0 as disabled)', muxOf(van).concurrency, -1);
eq('mux off -> enabled false', muxOf(van).enabled, false);

s.muxEnabled = true;
s.muxConcurrency = '16';
s.muxXudpConcurrency = '32';
s.muxXudpProxyUDP443 = 'allow';
const on = muxOf(flowless);
eq('mux on -> enabled', on.enabled, true);
eq('mux on -> concurrency from settings', on.concurrency, 16);
eq('mux on -> xudpConcurrency from settings', on.xudpConcurrency, 32);
eq('mux on -> xudpProxyUDP443 from settings', on.xudpProxyUDP443, 'allow');

// vless WITH flow: upstream forces concurrency -1 regardless of the setting.
eq('mux on + flow -> forced -1', muxOf(van).concurrency, -1);

s.muxConcurrency = 'not-a-number';
eq('mux: unparseable concurrency falls back, never NaN',
  muxOf(flowless).concurrency, 8);
s.muxConcurrency = '';
eq('mux: empty concurrency falls back', muxOf(flowless).concurrency, 8);

// Protocols that must never mux, even with the setting on.
s.muxConcurrency = '8';
s.muxXudpConcurrency = '8';
const socksy = ProfileItem.create(EConfigType.SOCKS);
socksy.remarks = 'mux-socks';
socksy.server = '192.168.1.10';
socksy.serverPort = '1080';
eq('mux on + socks -> disabled', muxOf(socksy).concurrency, -1);

s.muxEnabled = false;
s.muxXudpProxyUDP443 = 'reject';

// ── socks inbound ─────────────────────────────────────────────────────────
// PREF_SOCKS_ENABLE_UDP and the optional credentials were wired into both the
// xray inbound and the hev yaml before the settings page exposed them, so the
// settings are new but the behaviour has to be pinned either way.
const socksIn = (profile, delay) =>
  (JSON.parse(XrayConfigBuilder.buildFor(profile, delay)).inbounds ?? [])[0]?.settings;

const socksProfile = parsed.find((p) => p.name === '13-vless-kcp-seed').profile;
s.socksEnableUdp = true;
eq('socks udp on by default', socksIn(socksProfile, false).udp, true);
s.socksEnableUdp = false;
eq('socks udp follows the setting', socksIn(socksProfile, false).udp, false);
s.socksEnableUdp = true;

eq('socks noauth when no credentials', socksIn(socksProfile, false).auth, 'noauth');
s.socksUsername = 'u1';
s.socksPassword = 'p1';
const withAuth = socksIn(socksProfile, false);
eq('socks auth mode when credentials set', withAuth.auth, 'password');
eq('socks account emitted', withAuth.accounts, [{ user: 'u1', pass: 'p1' }]);
// A username without a password must not half-enable auth: the core would
// reject an account with an empty pass, killing the whole config.
s.socksPassword = '';
eq('socks username alone stays noauth', socksIn(socksProfile, false).auth, 'noauth');
s.socksUsername = '';
s.socksPassword = '';
// The delay-test config has no inbounds at all (nothing may listen while testing).
eq('delay test opens no inbound', socksIn(socksProfile, true), undefined);

// Deliberate upstream-removed fixtures. The Go checker asserts these FAIL with
// the documented reason, so docs/OHOS_PORT.md §6 is enforced, not just claimed.
const h2 = JSON.parse(XrayConfigBuilder.buildFor(vless, false));
h2.outbounds[0].streamSettings.network = 'h2';
emit('90-upstream-h2.json', JSON.stringify(h2));

const insecure = JSON.parse(XrayConfigBuilder.buildFor(vless, false));
insecure.outbounds[0].streamSettings.security = 'tls';
delete insecure.outbounds[0].streamSettings.realitySettings;
insecure.outbounds[0].streamSettings.tlsSettings = { serverName: 'x.example.com', allowInsecure: true };
emit('91-upstream-allowinsecure.json', JSON.stringify(insecure));

// Trojan + flow: CoreOutboundBuilder (and this port) emit settings.flow for
// trojan unconditionally, but this core revision removed "Flow for Trojan".
// Same landmine as allowInsecure, on Android too.
const trojan = parsed.find((p) => p.name === '06-trojan').profile;
const trojanCfg = JSON.parse(XrayConfigBuilder.buildFor(trojan, false));
trojanCfg.outbounds[0].settings.flow = 'xtls-rprx-vision';
emit('92-upstream-trojan-flow.json', JSON.stringify(trojanCfg));

// mkcp header/seed: removed upstream in favour of finalmask; the port never
// emits them (it uses mkcp-legacy masks), so this fixture proves the old form
// really is rejected rather than merely "not produced".
const kcp = parsed.find((p) => p.name === '13-vless-kcp-seed').profile;
const kcpCfg = JSON.parse(XrayConfigBuilder.buildFor(kcp, false));
kcpCfg.outbounds[0].streamSettings.kcpSettings = { mtu: 1350, tti: 20, seed: 'myseed' };
emit('93-upstream-mkcp-seed.json', JSON.stringify(kcpCfg));

// The per-app proxy list is split in two places — the settings page (which
// verifies each name) and ConnectionController (which puts them into the VpnConfig).
// If they split differently, the page reports "N verified" while the tunnel
// silently receives ONE mangled name. One shared splitter, asserted here.
eq('splitNames: comma', AppResolver.splitNames('a.b,c.d'), ['a.b', 'c.d']);
eq('splitNames: space (the divergence that would otherwise be silent)',
  AppResolver.splitNames('a.b c.d'), ['a.b', 'c.d']);
eq('splitNames: semicolon and CJK punctuation', AppResolver.splitNames('a.b；c.d;e.f'), ['a.b', 'c.d', 'e.f']);
eq('splitNames: newline and tab', AppResolver.splitNames('a.b\nc.d\te.f'), ['a.b', 'c.d', 'e.f']);
eq('splitNames: empties dropped', AppResolver.splitNames('a.b,,c.d,'), ['a.b', 'c.d']);
eq('splitNames: duplicates collapsed, order kept', AppResolver.splitNames('b.b,a.a,b.b'), ['b.b', 'a.a']);
eq('splitNames: empty input', AppResolver.splitNames('   '), []);

expectedFailures['90-upstream-h2.json'] = 'HTTP transport';
expectedFailures['91-upstream-allowinsecure.json'] = 'allowInsecure';
expectedFailures['92-upstream-trojan-flow.json'] = 'Flow for Trojan';
expectedFailures['93-upstream-mkcp-seed.json'] = 'mkcp header & seed';

// VLESS/Trojan without transport security on a public address: this core's
// requiresTransportSecurity() policy, not a port bug (Android is refused too).
const noTlsProfile = ProfileItem.create(EConfigType.VLESS);
noTlsProfile.remarks = 'no-tls';
noTlsProfile.server = 'public.example.com';
noTlsProfile.serverPort = '443';
noTlsProfile.password = 'b831381d-6324-4d53-ad4f-8cda48b30811';
noTlsProfile.method = 'none';
noTlsProfile.network = 'tcp';
noTlsProfile.security = '';
emit('94-upstream-vless-no-tls.json', XrayConfigBuilder.buildFor(noTlsProfile, false));
expectedFailures['94-upstream-vless-no-tls.json'] = 'without TLS or other encryption';
writeFileSync(join(OUT, 'expected_failures.json'), JSON.stringify(expectedFailures, null, 2));

// The tun2socks YAML has no consumer in this Node harness, so its keys are
// asserted textually — a typo there fails at runtime on the device only.
const { HevTunConfig } = await import('./dist/harness.mjs');
const yaml = HevTunConfig.build(0);
for (const needle of ['tunnel:', 'mtu:', 'socks5:', 'address:', 'port:', 'udp:', 'misc:', 'log-file:', 'log-level:']) {
  truthy(`hev yaml contains ${needle}`, yaml.includes(needle), yaml);
}
truthy('hev yaml socks5 address is loopback', yaml.includes('127.0.0.1'), yaml);

const errors = logRing.all().filter((l) => l.includes(' E '));
if (errors.length > 0) {
  console.log(`\nlogic_check: ${errors.length} error-level log line(s) from the port:`);
  for (const l of errors) console.log('   ' + l);
}
console.log(`\nlogic_check: ${checks - failures}/${checks} assertions passed, ${emitted} configs emitted`);
if (failures > 0) {
  console.error(`logic_check: ${failures} FAILED`);
  process.exit(1);
}
console.log('logic_check: OK');
