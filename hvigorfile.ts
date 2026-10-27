import { appTasks } from '@ohos/hvigor-ohos-plugin';
import * as fs from 'fs';
import * as path from 'path';
import { execSync } from 'child_process';

// Auto-fetch sibling TPC deps (full transitive closure) when missing. cjpm
// depends on them via ../../<dep> (SIBLINGS). Shared workspace / shell
// third_party already has them -> no-op (one copy, no dup). Standalone clone ->
// fetched next to this repo so it builds on its own.
(function syncSiblingDeps() {
  const DEPS = [
    { name: 'eudi_lib_cbor', url: 'https://github.com/CJPLUK/eudi-lib-hmos-cbor', ref: 'v0.1.0' },
    { name: 'eudi_lib_core_crypto', url: 'https://github.com/CJPLUK/eudi-lib-hmos-core-crypto', ref: 'v0.1.0' },
    { name: 'eudi_lib_mdoc_data_model', url: 'https://github.com/CJPLUK/eudi-lib-hmos-mdoc-data-model', ref: 'v0.1.0' },
  ];
  const root = path.resolve(__dirname, '..');
  for (const d of DEPS) {
    const dst = path.join(root, d.name);
    if (fs.existsSync(dst)) continue;
    try {
      console.log(`[deps] cloning ${d.name} -> ${dst}`);
      execSync(`git clone --quiet "${d.url}" "${dst}"`, { stdio: 'inherit' });
      execSync(`git -C "${dst}" fetch --quiet --tags`, { stdio: 'inherit' });
      execSync(`git -C "${dst}" checkout --quiet ${d.ref}`, { stdio: 'inherit' });
    } catch (e) {
      console.error(`[deps] failed to fetch ${d.name}: ${e}`);
    }
  }
})();

export default {
  system: appTasks,
  plugins: []
}
