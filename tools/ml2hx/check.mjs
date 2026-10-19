#!/usr/bin/env node
// The progress number of tools/ml2hx: modules of the pinned tag that emit
// Haxe that types (with the runtime, and every module they use typing too).
//   node tools/ml2hx/check.mjs [--haxe cmd] [--json file]
// Generates into bin/ml2hx/generated, then type-checks: modules with errors
// are removed and the rest checked again until what remains types.
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {generate, root} from './generate.mjs';

function haxeCommand(args, haxe) {
  if (haxe) return spawnSync(haxe, args, {cwd: root, encoding: 'utf8', maxBuffer: 256 * 1024 * 1024});
  return spawnSync(process.execPath, ['--stack-size=4096', 'hxmc/bootstrap/wasi.mjs', 'hxmc/bootstrap/stage0.wasm.br', ...args],
    {cwd: root, encoding: 'utf8', maxBuffer: 256 * 1024 * 1024, env: {...process.env, HAXE_STD_PATH: path.join(root, 'haxe/upstream/std')}});
}
function walk(dir, visit) {
  for (const e of fs.readdirSync(dir, {withFileTypes: true})) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, visit); else visit(p);
  }
}
export function typecheck(generated, {haxe = null, log = () => {}} = {}) {
  const work = path.join(root, 'bin/ml2hx/typecheck');
  fs.rmSync(work, {recursive: true, force: true});
  const modules = new Set();
  for (const top of ['upstream', 'ocaml']) if (fs.existsSync(path.join(generated, top))) walk(path.join(generated, top), p => {
    if (!p.endsWith('.hx')) return;
    const rel = path.relative(generated, p);
    fs.mkdirSync(path.dirname(path.join(work, rel)), {recursive: true});
    fs.copyFileSync(p, path.join(work, rel));
    modules.add(rel);
  });
  const removed = new Map(), missing = new Map();
  for (let round = 0; modules.size; round++) {
    const classes = [...modules].map(m => m.replace(/\.hx$/, '').replaceAll('/', '.'));
    fs.writeFileSync(path.join(work, 'CheckAll.hx'), `class CheckAll {\n\tstatic function main() {\n${classes.map(c => `\t\t${c}.ml2hxInit();`).join('\n')}\n\t}\n}\n`);
    const r = haxeCommand(['-cp', path.relative(root, work), '-cp', 'tools/ml2hx/runtime', '-main', 'CheckAll', '--no-output', '-D', 'no-deprecation-warnings'], haxe);
    const out = (r.stdout ?? '') + (r.stderr ?? '');
    if (r.status === 0) break;
    const bad = new Set();
    let runtimeErrors = [];
    const lines = out.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const m = lines[i].match(/\[ERROR\]\s*([^\s:]+\.hx):(\d+)/);
      if (!m) continue;
      let file = m[1];
      const ctx = lines.slice(i + 1, i + 8).filter(l => /^\s*\|\s+\S/.test(l)).map(l => l.replace(/^\s*\|\s*/, '').trim()).filter(l => !/^\^+$/.test(l));
      const msg = ctx[0] ?? lines[i];
      const abs = path.resolve(root, file);
      if (abs.startsWith(work + path.sep)) {
        const rel = path.relative(work, abs);
        if (modules.has(rel)) {
          bad.add(rel);
          if (!removed.has(rel)) removed.set(rel, msg);
          const lib = msg.match(/(ml2hx\.std\.\w+|Class<ml2hx\.std\.\w+>) has no field (\w+)/);
          if (lib) { const key = `${lib[1].replace(/Class<|>/g, '')}.${lib[2]}`; missing.set(key, (missing.get(key) ?? 0) + 1); }
          const tnf = msg.match(/Type not found : (ml2hx\.std\.[\w.]+)/);
          if (tnf) missing.set(tnf[1], (missing.get(tnf[1]) ?? 0) + 1);
        }
      } else if (abs.includes(path.join('tools', 'ml2hx', 'runtime'))) runtimeErrors.push(`${file}:${m[2]}: ${msg}`);
    }
    if (!bad.size) {
      if (runtimeErrors.length) throw new Error(`the runtime does not type:\n${[...new Set(runtimeErrors)].slice(0, 20).join('\n')}`);
      throw new Error(`type check failed without a module to blame:\n${out.slice(0, 4000)}`);
    }
    log(`round ${round}: ${modules.size} modules, ${bad.size} with errors`);
    for (const m of bad) { modules.delete(m); fs.rmSync(path.join(work, m)); }
  }
  return {typed: [...modules].sort(), removed, missing};
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const opt = k => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : null; };
  const haxe = opt('--haxe') ?? process.env.ML2HX_HAXE ?? null;
  const result = generate({});
  console.log(`ML sources: ${result.sources}; typed by OCaml: ${result.typed}; emitted: ${result.emitted}; emit failures: ${result.failures.length}`);
  const tc = typecheck(path.join(root, 'bin/ml2hx/generated'), {haxe, log: s => console.log(s)});
  const tracked = new Set(result.trackedOutputs);
  const typedTracked = tc.typed.filter(m => tracked.has(m));
  console.log(`\nModules that emit and type: ${typedTracked.length} of ${result.sources}`);
  // The library units the program reaches (OCaml's Stdlib, extlib...), converted too.
  const libOutputs = result.libraryOutputs ?? [];
  const libTyped = tc.typed.filter(m => libOutputs.includes(m));
  console.log(`Library units that emit and type: ${libTyped.length} of ${result.libraryUnits ?? libOutputs.length}; with the compiler's: ${typedTracked.length + libTyped.length} of ${result.sources + (result.libraryUnits ?? libOutputs.length)}`);
  const summary = {sources: result.sources, emitted: result.emitted, typed: typedTracked.length, libraryUnits: result.libraryUnits, libraryTyped: libTyped.length,
    emitFailures: result.failures.map(f => ({source: f.source, error: f.error.slice(0, 300)})),
    typeFailures: [...tc.removed].map(([m, e]) => ({module: m, error: e.slice(0, 300)})),
    missingLibrary: [...tc.missing].sort((a, b) => b[1] - a[1])};
  fs.writeFileSync(opt('--json') ?? path.join(root, 'bin/ml2hx/check.json'), JSON.stringify(summary, null, 1));
  const firstErrors = new Map();
  for (const [m, e] of tc.removed) { const k = e.replace(/[\w.]*\d+[\w.]*/g, 'N').slice(0, 80); firstErrors.set(k, (firstErrors.get(k) ?? 0) + 1); }
  console.log('Most common first type errors:');
  for (const [k, v] of [...firstErrors].sort((a, b) => b[1] - a[1]).slice(0, 15)) console.log(`  ${v}  ${k}`);
  if (tc.missing.size) console.log(`Library members missing from the runtime: ${tc.missing.size} (bin/ml2hx/check.json)`);
}
