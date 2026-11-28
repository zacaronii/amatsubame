// Looks texts up with Hachidori's own engine: a Hachidori release's hoshidicts.wasm, on dictionaries
// copied from a host, as its popup does (32 results, a 16-character scan), plus every redirect
// target a result names (8 results, as LookupService follows them). Used by hachidori-parity.sh.
//
//   node scripts/parity-reference.mjs <Hachidori checkout> <manifest.json> <options.json> <texts.txt> <out.jsonl>
//
// Each output line is {text, page, redirects: {term: page}}, pages as hd_lookup replies, with
// glossary text kept only where it's a redirect and no frequencies or pitches (nothing compares them).
import { readFileSync, readdirSync, statSync, writeFileSync, appendFileSync } from 'node:fs';
import { join } from 'node:path';

const [release, manifestPath, optionsPath, textsPath, outPath] = process.argv.slice(2);
const { default: createHoshidicts } = await import(join(release, 'extension', 'vendor', 'hoshidicts.mjs'));
const M = await createHoshidicts();
const call = (name, ret, types, args) => M.ccall(name, ret, types, args);
const fail = (what) => { throw new Error(`${what}: ${call('hdw_last_error', 'string', [], [])}`); };

if (call('hdw_init_storage', 'number', ['number'], [0]) !== 1) fail('storage');
M.FS.mkdir('/d');
const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')).filter(d => d.enabled);
const paths = manifest.map((d, i) => {
  const dir = `/d/${i}`;
  M.FS.mkdir(dir);
  for (const name of readdirSync(d.folder)) {
    if (statSync(join(d.folder, name)).isFile()) M.FS.writeFile(`${dir}/${name}`, readFileSync(join(d.folder, name)));
  }
  // Kinds: 0 terms, 1 frequencies, 2 pitches, 3 kanji (hdw_add_dict).
  for (const [kind, count] of [[0, d.terms], [1, d.frequencies], [2, d.pitches], [3, d.kanji]]) {
    if (count > 0 && call('hdw_add_dict', 'number', ['string', 'number', 'number', 'number'], [dir, kind, 0, 0]) !== 1) {
      fail(`${d.title} (kind ${kind})`);
    }
  }
  return dir;
});
if (call('hdw_set_dict_order', 'number', ['string'], [JSON.stringify(paths)]) !== 1) fail('dictionary order');

const options = readFileSync(optionsPath, 'utf8');
const lookup = (text, maxResults) =>
  JSON.parse(call('hdw_lookup', 'string', ['string', 'number', 'number', 'string'], [text, maxResults, 16, options]));
// Jitendex-style redirects: a definition that is [term, [rules]].
const definitions = (glossary) => { try { return JSON.parse(glossary); } catch { return []; } };
const isRedirect = (glossary) => definitions(glossary).some(d => Array.isArray(d));
const targets = (page) => [...new Set(page.results.flatMap(r => (r.term?.glossaries ?? [])
  .flatMap(g => definitions(g.glossary).filter(d => Array.isArray(d) && typeof d[0] === 'string' && d[0]).map(d => d[0]))))];
const compact = (page) => {
  for (const r of page.results) {
    for (const g of r.term?.glossaries ?? []) if (!isRedirect(g.glossary)) g.glossary = '';
    if (r.term) { r.term.frequencies = []; r.term.pitches = []; }
  }
};

writeFileSync(outPath, '');
const texts = readFileSync(textsPath, 'utf8').split('\n').filter(Boolean);
for (const text of texts) {
  const page = lookup(text, 32);
  const redirects = {};
  for (const term of targets(page)) redirects[term] = lookup(term, 8);
  for (const p of [page, ...Object.values(redirects)]) compact(p);
  appendFileSync(outPath, JSON.stringify({ text, page, redirects }) + '\n');
}
console.log(`Hachidori's engine looked up ${texts.length} texts in ${manifest.length} dictionaries (${options.trim()})`);
