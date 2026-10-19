#!/usr/bin/env node
// Generate Haxe from the pinned upstream's typed trees.
//   node tools/ml2hx/generate.mjs [--upstream dir] [--build-dir dir] [--verbose] [--check]
// The frontend is built from tools/ml2hx/frontend with the opam switch the
// pinned tag builds with (tools/ml2hx/build-frontend.mjs); see README.md.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {Program} from './emit.mjs';
import {format} from './format.mjs';

export const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const home = path.join(root, 'tools/ml2hx');
export function run(cmd, args, options = {}) {
  const r = spawnSync(cmd, args, {cwd: root, encoding: 'utf8', maxBuffer: 512 * 1024 * 1024, ...options});
  if (r.error) throw r.error;
  if (r.status !== 0) throw new Error(`${path.basename(cmd)} failed (${r.status}):\n${r.stderr || r.stdout}`);
  return r.stdout;
}
export function frontendPath() {
  if (process.env.ML2HX_FRONTEND) return process.env.ML2HX_FRONTEND;
  for (const f of ['frontend.exe', 'frontend.byte']) { const p = path.join(root, 'bin/ml2hx/build', f); if (fs.existsSync(p)) return p; }
  throw new Error('ml2hx frontend not built: run `make ml2hx-frontend` (needs the opam switch, see tools/ml2hx/README.md)');
}
// Run the frontend over files (.cmt or .ml); returns [{file, modname, source, load()}|{file, error}].
export function frontend(files, includeDirs = []) {
  const base = path.join(root, 'bin/ml2hx/ir');
  fs.mkdirSync(base, {recursive: true});
  const spool = fs.mkdtempSync(path.join(base, 'run-'));
  const out = run(frontendPath(), ['--out-dir', spool, ...includeDirs.flatMap(d => ['-I', d]), ...files]);
  const result = JSON.parse(out);
  if (result.protocol !== 2) throw new Error(`unsupported frontend protocol ${result.protocol}`);
  return result.files.map(f => f.error ? f : {...f, load: () => JSON.parse(fs.readFileSync(f.ir, 'utf8'))});
}
export function discover(upstream) {
  return run('git', ['-C', upstream, 'ls-files', '*.ml']).trim().split('\n').filter(Boolean).sort();
}
export function unitConfig(source) {
  const pieces = source.replace(/^src\//, '').replace(/\.ml$/, '').split('/');
  const module = pieces.pop(), name = module[0].toUpperCase() + module.slice(1);
  const pkg = ['upstream', ...pieces.map(x => x === 'macro' ? 'macros' : x.replaceAll('-', '_').toLowerCase())].join('.');
  return {source, module: name, class: name + 'Module', package: pkg, output: pkg.replaceAll('.', '/') + '/' + name + 'Module.hx'};
}
function walk(dir, visit) {
  for (const e of fs.readdirSync(dir, {withFileTypes: true})) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, visit); else if (e.isFile()) visit(p);
  }
}
// A clean checkout of the pin, built with dune (the typed trees).
export function prepare(upstream) {
  const commit = run('git', ['-C', upstream, 'rev-parse', 'HEAD']).trim();
  const build = path.join(root, 'bin/ml2hx/checkouts', commit);
  if (!fs.existsSync(build)) {
    fs.mkdirSync(path.dirname(build), {recursive: true});
    run('git', ['clone', '--shared', '--no-checkout', upstream, build]);
    run('git', ['-C', build, 'checkout', '--detach', commit]);
  }
  if (run('git', ['-C', build, 'rev-parse', 'HEAD']).trim() !== commit) throw new Error('cached upstream checkout does not match the pin');
  run('dune', ['build', '--root', build, '--profile', 'release', '@check'], {env: {...process.env, STATICLINK: '0', LIB_PARAMS: ''}});
  return build;
}
// Program units from a dune build: every tracked source with its CMT.
export function loadUnits({upstream, buildDir, files = null}) {
  const sources = files ?? discover(upstream);
  const cmts = [], includeDirs = new Set();
  walk(path.join(buildDir, '_build/default'), p => {
    if (p.endsWith('.cmt')) cmts.push(p);
    if (p.endsWith('.cmi')) includeDirs.add(path.dirname(p));
  });
  const ir = frontend(cmts.sort(), [...includeDirs].sort());
  const bySource = new Map();
  const errors = [];
  for (const f of ir) {
    if (f.error) { errors.push(f); continue; }
    // PPX-processed units record the preprocessed file (lexer.pp.ml).
    if (f.source) bySource.set(f.source.replace(/\.pp\.ml$/, '.ml'), f);
  }
  // Sources dune does not build (tests, plugins) are typed from source.
  const loose = sources.filter(s => !bySource.has(s));
  if (loose.length) for (const f of frontend(loose.map(s => path.join(upstream, s)), [...includeDirs].sort())) {
    const source = path.relative(upstream, f.file);
    if (f.error) errors.push({...f, file: f.file}); else bySource.set(source, {...f, source});
  }
  const units = [], failures = [];
  for (const source of sources) {
    const f = bySource.get(source);
    if (!f) { failures.push({source, stage: 'typing', error: 'no typed tree (not built by dune @check)'}); continue; }
    units.push({modname: f.modname, config: unitConfig(source), load: f.load});
  }
  // Sources dune generates (MetaList, DefineList, WarningList from src-json)
  // are units of the program too.
  const tracked = new Set(sources);
  for (const [source, f] of bySource) if (!tracked.has(source) && !/(^|\/)prebuild\.ml$/.test(source))
    units.push({modname: f.modname, config: unitConfig(source), load: f.load, generatedSource: true});
  for (const e of errors) failures.push({source: path.relative(e.file.startsWith(upstream) ? upstream : buildDir, e.file), stage: 'typing', error: e.error});
  return {sources, units, failures};
}
// Emit every unit; returns the outputs and per-unit failures.
export function emitUnits(units, options = {}) {
  const program = new Program({units, ...options});
  const outputs = new Map(), failures = [], deps = new Map();
  for (const u of units) {
    try {
      const {code, deps: d} = program.emit(u.modname);
      outputs.set(u.config.output, format(code));
      deps.set(u.modname, d);
    } catch (e) {
      if (e.name !== 'Unsupported' && !process.env.ML2HX_DEBUG) failures.push({source: u.config.source, stage: 'lowering', error: `internal: ${e.stack.split('\n').slice(0, 3).join(' ')}`});
      else failures.push({source: u.config.source, stage: 'lowering', error: e.name === 'Unsupported' ? e.message : e.stack});
    }
  }
  return {program, outputs, failures, deps};
}
// The library interface the generated code calls: one extern class per
// ml2hx.std module, from the OCaml signatures (for typing the output before
// the runtime implements everything, and as the runtime's checklist).
export function libraryInterface(program) {
  const files = new Map();
  for (const [cls, members] of [...program.libraryUses].sort()) {
    const lines = [...members].sort().map(([m, sig]) => `\t// ${m}${sig}`);
    files.set(cls, lines);
  }
  return files;
}
export function writeOutputs(out, outputs) {
  fs.mkdirSync(out, {recursive: true});
  const owned = path.join(out, '.ml2hx-files');
  const previous = fs.existsSync(owned) ? fs.readFileSync(owned, 'utf8').trim().split('\n').filter(Boolean) : [];
  for (const p of previous) {
    const dest = path.resolve(out, p);
    if (!dest.startsWith(out + path.sep)) throw new Error('unsafe previous output');
    if (!outputs.has(p) && fs.existsSync(dest)) fs.unlinkSync(dest);
  }
  for (const [p, code] of outputs) { const dest = path.join(out, p); fs.mkdirSync(path.dirname(dest), {recursive: true}); fs.writeFileSync(dest, code); }
  fs.writeFileSync(owned, [...outputs.keys()].sort().join('\n') + '\n');
}
export function generate({upstream = path.join(root, 'haxe/upstream'), out = path.join(root, 'bin/ml2hx/generated'), buildDir = null} = {}) {
  upstream = path.resolve(upstream); out = path.resolve(out);
  buildDir ??= prepare(upstream);
  const {sources, units, failures} = loadUnits({upstream, buildDir});
  const emitted = emitUnits(units);
  const outputs = emitted.outputs;
  walk(path.join(home, 'runtime'), p => outputs.set(path.relative(path.join(home, 'runtime'), p), fs.readFileSync(p, 'utf8')));
  writeOutputs(out, outputs);
  const uses = [];
  for (const [cls, members] of [...emitted.program.libraryUses].sort()) for (const [m, sig] of [...members].sort()) uses.push(`${cls}.${m}${sig}`);
  fs.writeFileSync(path.join(out, '.library-uses'), uses.join('\n') + '\n');
  const all = [...failures, ...emitted.failures];
  all.forEach(f => { f.error = f.error.split(upstream + path.sep).join('').split(root + path.sep).join(''); });
  const result = {sources: sources.length, typed: units.length, emitted: emitted.outputs.size - 0, failures: all};
  const trackedOutputs = new Set(units.filter(u => !u.generatedSource).map(u => u.config.output));
  result.emitted = [...outputs.keys()].filter(k => trackedOutputs.has(k)).length;
  result.complete = all.length === 0 && result.emitted === sources.length;
  fs.writeFileSync(path.join(out, '.status'), result.complete ? 'complete\n' : 'incomplete\n');
  return result;
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = process.argv.slice(2), options = {};
    let verbose = false;
    for (let i = 0; i < args.length; i++) {
      if (args[i] === '--upstream') options.upstream = args[++i];
      else if (args[i] === '--build-dir') options.buildDir = args[++i];
      else if (args[i] === '--verbose') verbose = true;
      else throw new Error('unknown argument ' + args[i]);
    }
    const result = generate(options);
    console.log(`ML sources: ${result.sources}; typed: ${result.typed}; emitted: ${result.emitted}; failed: ${result.failures.length}`);
    for (const f of verbose ? result.failures : result.failures.slice(0, 15)) console.error(`${f.source} [${f.stage}]: ${f.error.replace(/\s+/g, ' ').trim().slice(0, 300)}`);
    if (!result.complete) { console.error('Incomplete generation. Use --verbose for every failure.'); process.exitCode = 1; }
  } catch (e) { console.error(e.stack); process.exitCode = 1; }
}
