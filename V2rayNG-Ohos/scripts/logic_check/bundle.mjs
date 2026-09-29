#!/usr/bin/env node
/**
 * Copies the port's .ets sources to .build/ets as .ts and bundles a test entry
 * with esbuild.
 *
 * Why copy instead of compiling in place: the ArkTS compiler owns the real
 * build; this harness only needs the *pure logic* (fmt parsing, config
 * generation) to run under Node so a machine without a HarmonyOS device can
 * still catch regressions. Nothing here is a substitute for the HAP build.
 */
import { cpSync, mkdirSync, rmSync, writeFileSync, readdirSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as esbuild from 'esbuild';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const SRC = join(ROOT, 'entry', 'src', 'main', 'ets');
const BUILD = join(HERE, '.build');
const ETS = join(BUILD, 'ets');
const DIST = join(HERE, 'dist');

function copyEtsAsTs(from, to) {
  mkdirSync(to, { recursive: true });
  for (const entry of readdirSync(from)) {
    const s = join(from, entry);
    const d = join(to, entry);
    if (statSync(s).isDirectory()) {
      copyEtsAsTs(s, d);
    } else if (entry.endsWith('.ets')) {
      cpSync(s, join(to, entry.slice(0, -4) + '.ts'));
    }
  }
}

rmSync(BUILD, { recursive: true, force: true });
rmSync(DIST, { recursive: true, force: true });
copyEtsAsTs(SRC, ETS);

// The entry lives inside the copied tree so relative imports resolve normally.
writeFileSync(join(BUILD, 'harness.ts'), `export { Fmt } from './ets/fmt/Fmt';
export { CustomFmt } from './ets/fmt/CustomFmt';
export { XrayConfigBuilder } from './ets/core/XrayConfigBuilder';
export { HevTunConfig } from './ets/core/HevTunConfig';
export { settings } from './ets/model/AppSettings';
export { ProfileItem, EConfigType } from './ets/model/Profile';
export { logRing } from './ets/util/Log';
`);

const shim = (name) => join(HERE, 'shims', name);
const ohosShimPlugin = {
  name: 'ohos-shim',
  setup(build) {
    build.onResolve({ filter: /^@ohos\./ }, (args) => {
      const map = {
        '@ohos.buffer': shim('ohos.buffer.mjs'),
        '@ohos.hilog': shim('ohos.hilog.mjs'),
        '@ohos.data.preferences': shim('ohos.preferences.mjs'),
        '@ohos.app.ability.common': shim('ohos.common.mjs')
      };
      const hit = map[args.path];
      if (!hit) return { errors: [{ text: `logic_check: no shim for ${args.path}` }] };
      return { path: hit };
    });
  }
};

mkdirSync(DIST, { recursive: true });
await esbuild.build({
  entryPoints: [join(BUILD, 'harness.ts')],
  outfile: join(DIST, 'harness.mjs'),
  bundle: true,
  format: 'esm',
  platform: 'neutral',
  target: 'es2022',
  mainFields: ['module', 'main'],
  conditions: ['import', 'default'],
  plugins: [ohosShimPlugin],
  logLevel: 'info'
});
console.log('logic_check: bundled dist/harness.mjs');
