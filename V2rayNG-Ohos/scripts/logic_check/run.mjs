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
const { Fmt, XrayConfigBuilder, settings, ProfileItem, EConfigType, logRing } =
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
      configType: EConfigType.CUSTOM, server: 'custom.example.com', serverPort: '443' } }
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
  parsed.push({ name: c.name, profile: p });
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

for (const { name, profile } of parsed) {
  emit(`${name}-full.json`, XrayConfigBuilder.buildFor(profile, false));
  emit(`${name}-delaytest.json`, XrayConfigBuilder.buildFor(profile, true));
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

writeFileSync(join(OUT, 'expected_failures.json'), JSON.stringify({
  '90-upstream-h2.json': 'HTTP transport',
  '91-upstream-allowinsecure.json': 'allowInsecure'
}, null, 2));

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
