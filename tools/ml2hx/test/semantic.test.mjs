// Semantic tests: each tools/ml2hx/test/cases/<name>.ml (or <name>/ with
// several units, compiled in the order of <name>/order) is compiled by OCaml
// and by ml2hx; the generated Haxe, run by hxmc, must print what the OCaml
// program prints.
//   node --test tools/ml2hx/test/semantic.test.mjs
// Environment: ML2HX_HAXE selects a Haxe compiler for the generated code
// (default: hxmc's committed stage0); ML2HX_ONLY=name1,name2 runs a subset;
// ML2HX_NATIVE=1 compiles each case to an hxmc executable (the generated
// compiler's target) instead of running it in the interpreter.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {root, frontend, emitUnits, libraryUnits, nativesClassPath} from '../generate.mjs';
import {format} from '../format.mjs';
import {Unsupported} from '../emit.mjs';

const casesDir = path.join(root, 'tools/ml2hx/test/cases');
const work = path.join(root, 'bin/ml2hx/tests');
const env = {...process.env, HAXE_STD_PATH: path.join(root, 'haxe/upstream/std')};
function exec(cmd, args, options = {}) {
  const p = spawnSync(cmd, args, {cwd: root, env, encoding: 'latin1', timeout: 600000, maxBuffer: 64 * 1024 * 1024, ...options});
  if (p.error) throw p.error;
  return p;
}
function ok(cmd, args, options) {
  const p = exec(cmd, args, options);
  assert.equal(p.status, 0, `${cmd} ${args.join(' ')}\n${p.stdout}\n${p.stderr}`);
  return p.stdout;
}
function haxe(args) {
  if (process.env.ML2HX_HAXE) return exec(process.env.ML2HX_HAXE, args, {env: process.env});
  return exec(process.execPath, ['--stack-size=4096', 'hxmc/bootstrap/wasi.mjs', 'hxmc/bootstrap/stage0.wasm.br', ...args]);
}
// Compile OCaml units (in order) with -bin-annot; returns the CMTs and the program's output.
export function ocaml(name, files, dir) {
  fs.mkdirSync(dir, {recursive: true});
  const copies = files.map(f => { const d = path.join(dir, path.basename(f)); fs.copyFileSync(f, d); return d; });
  ok('ocamlfind', ['ocamlc', '-package', 'str', '-linkpkg', '-bin-annot', '-I', dir, '-o', path.join(dir, 'reference.byte'), ...copies]);
  const out = ok('ocamlrun', [path.join(dir, 'reference.byte')]);
  return {cmts: copies.map(f => f.replace(/\.ml$/, '.cmt')), expected: out};
}
// Generate Haxe for the units; returns the class path and the main class.
export function generateCase(name, cmts, dir, options = {}) {
  const ir = frontend(cmts, [dir]);
  for (const f of ir) if (f.error) throw new Error(f.error);
  const pkg = `cases.${name.replace(/\W/g, '_').toLowerCase()}`;
  const units = ir.map(f => ({modname: f.modname, irPath: f.ir, config: {source: path.basename(f.source ?? f.file), module: f.modname, class: `${f.modname}Module`, package: pkg, output: `${pkg.replaceAll('.', '/')}/${f.modname}Module.hx`}, load: f.load}));
  // The library units the case reaches (OCaml's Stdlib...), converted too.
  const libFailures = [];
  const libs = libraryUnits(units, libFailures, ['Std_exit']);
  const all = [...libs, ...units];
  const {outputs, failures, deps} = emitUnits(all, options);
  failures.push(...libFailures);
  if (failures.length) throw new Unsupported(null, failures.map(f => `${f.source}: ${f.error}`).join('\n'));
  const out = path.join(dir, 'hx');
  fs.rmSync(out, {recursive: true, force: true});
  for (const [p, code] of outputs) { fs.mkdirSync(path.dirname(path.join(out, p)), {recursive: true}); fs.writeFileSync(path.join(out, p), code); }
  const main = `${pkg}.Main`;
  // Initialisation in link order: libraries first (by dependency), the case's
  // units in order, Std_exit (at_exit functions) last.
  const order = [], seen = new Set();
  const visit = m => { if (seen.has(m) || !deps.has(m)) return; seen.add(m); for (const d of deps.get(m)) visit(d); order.push(m); };
  for (const u of libs) if (u.modname !== 'Std_exit') visit(u.modname);
  for (const u of units) visit(u.modname);
  visit('Std_exit');
  const cls = new Map(all.map(u => [u.modname, `${u.config.package}.${u.config.class}`]));
  fs.writeFileSync(path.join(out, pkg.replaceAll('.', '/'), 'Main.hx'), format(`package ${pkg};\nclass Main {\n\tstatic function main() {\n${order.map(m => `\t\t${cls.get(m)}.ml2hxInit();`).join('\n')}\n\t}\n}\n`));
  return {out, main};
}
const runtime = ['-cp', 'tools/ml2hx/runtime', '-cp', nativesClassPath()];
const only = process.env.ML2HX_ONLY?.split(',');
const cases = fs.existsSync(casesDir) ? fs.readdirSync(casesDir).filter(f => f.endsWith('.ml') || fs.statSync(path.join(casesDir, f)).isDirectory()).sort() : [];
for (const entry of cases) {
  const name = entry.replace(/\.ml$/, '');
  if (only && !only.includes(name)) continue;
  test(`semantics: ${name}`, () => {
    const dir = path.join(work, name);
    const files = entry.endsWith('.ml') ? [path.join(casesDir, entry)]
      : fs.readFileSync(path.join(casesDir, entry, 'order'), 'utf8').trim().split(/\s+/).map(f => path.join(casesDir, entry, f));
    const {cmts, expected} = ocaml(name, files, dir);
    const {out, main} = generateCase(name, cmts, dir);
    const args = [...runtime, '-cp', path.relative(root, out), '-main', main];
    let p;
    if (process.env.ML2HX_NATIVE) {
      const exe = path.join(dir, 'native');
      const c = haxe([path.relative(root, exe), ...args, '-cp', 'bin/hxmc/std', '--custom-target', 'hxmc']);
      assert.equal(c.status, 0, `${c.stdout}\n${c.stderr}`);
      p = exec(exe, []);
    } else p = haxe([...args, '--interp']);
    assert.equal(p.status, 0, `${p.stdout}\n${p.stderr}`);
    assert.equal(p.stdout, expected);
  });
}
test('unsupported constructs fail explicitly', () => {
  const dir = path.join(work, 'unsupported');
  const probe = (src, re) => {
    fs.mkdirSync(dir, {recursive: true});
    const f = path.join(dir, 'probe.ml');
    fs.writeFileSync(f, src);
    ok('ocamlfind', ['ocamlc', '-bin-annot', '-c', '-I', dir, '-o', path.join(dir, 'probe.cmo'), f]);
    assert.throws(() => generateCase('unsupported', [f.replace(/\.ml$/, '.cmt')], dir), e => e instanceof Unsupported && re.test(e.message), src);
  };
  probe('let rec l = 1 :: l\n', /recursive non-function value/);
});
