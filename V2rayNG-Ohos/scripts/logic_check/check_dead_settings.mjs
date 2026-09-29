#!/usr/bin/env node
/**
 * Fails if a setting declared in model/AppSettings.ets has no consumer outside
 * the settings model and the settings page.
 *
 * Why this is a gate and not a note: a setting that is written but never read is
 * a toggle that lies — the user flips it, nothing happens, and nothing reports
 * an error. That is exactly the failure this port already had four times
 * (appendHttpProxy, vpnMode, localProxyEnabled, httpPort) and had to find by
 * hand. "Documented in the gaps list" does not survive a refactor; an assertion
 * does.
 *
 * Settings that are intentionally inert (kept so a settings export from the
 * Android build round-trips) must be listed in EXEMPT with the reason, so the
 * exemption is visible in review rather than implied by silence.
 */
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, dirname, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ETS = join(HERE, '..', '..', 'entry', 'src', 'main', 'ets');

/** Declared but deliberately inert — each needs a reason. */
const EXEMPT = {
  appendHttpProxy: 'Android-only: VpnService.Builder.setHttpProxy(); VpnConfig has no proxy field',
  vpnMode: 'proxy-only mode not implemented (see docs/OHOS_PORT.md §5)',
  localProxyEnabled: 'inert until proxy-only mode exists; socks inbound is currently unconditional',
  httpPort: 'no http inbound yet (see docs/OHOS_PORT.md §5)',
  currentProfileGuid: 'selection lives in ProfileStore.selectedGuid(); kept for settings import compat'
};

function walk(dir, acc = []) {
  for (const entry of readdirSync(dir)) {
    const p = join(dir, entry);
    if (statSync(p).isDirectory()) {
      walk(p, acc);
    } else if (entry.endsWith('.ets')) {
      acc.push(p);
    }
  }
  return acc;
}

const files = walk(ETS);
const model = files.find((f) => f.endsWith(join('model', 'AppSettings.ets')));
const page = files.find((f) => f.endsWith(join('pages', 'Settings.ets')));
if (!model || !page) {
  console.error('check_dead_settings: cannot locate AppSettings.ets / Settings.ets');
  process.exit(2);
}

// Field declarations inside the settings data interface.
const fields = [];
for (const m of readFileSync(model, 'utf-8').matchAll(/^\s{2}([a-z][A-Za-z0-9]*)\s*[:=]/gm)) {
  fields.push(m[1]);
}

// Anything that is not the model itself nor the settings page.
const others = files.filter((f) => f !== model && f !== page);
const sources = others.map((f) => [relative(ETS, f), readFileSync(f, 'utf-8')]);

let problems = 0;
let exempted = 0;
const seen = new Set();
for (const field of fields) {
  if (seen.has(field)) {
    continue;
  }
  seen.add(field);
  const re = new RegExp(`\\b${field}\\b`);
  const consumers = sources.filter(([, text]) => re.test(text)).map(([name]) => name);
  if (consumers.length === 0) {
    if (EXEMPT[field]) {
      exempted++;
      console.log(`  exempt  ${field.padEnd(20)} ${EXEMPT[field]}`);
    } else {
      problems++;
      console.error(`  FAIL    ${field.padEnd(20)} declared in AppSettings.ets but nothing reads it`);
      console.error('          → wire it up, drop it, or add it to EXEMPT in check_dead_settings.mjs');
    }
  }
}

// An exemption that is no longer needed hides a live consumer behind a stale
// reason; warn so it gets removed.
for (const field of Object.keys(EXEMPT)) {
  const re = new RegExp(`\\b${field}\\b`);
  if (sources.some(([, text]) => re.test(text))) {
    console.warn(`  note    ${field}: exempt but someone reads it now — remove the exemption`);
  }
}

console.log(`check_dead_settings: ${fields.length} settings, ${exempted} exempt, ${problems} problem(s)`);
process.exit(problems === 0 ? 0 : 1);