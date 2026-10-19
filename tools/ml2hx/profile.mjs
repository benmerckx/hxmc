#!/usr/bin/env node
// The generated compiler against the port on the same workloads, both built
// from this tree with the same flags (make ml2hx-profile builds them, with
// symbols, into bin/ml2hx/profile: port, generated, and the census builds
// port-census, generated-census). Writes bin/ml2hx/profile/profile.md and the
// raw data beside it:
//   1. phase times (upstream's --times), median of the runs, side by side;
//   2. a differential profile (perf record -g, frame pointers) by upstream
//      function: the generated XModule.f is x.ml's f, the port's class X (or
//      a class of X.hx) the same; symbols of neither are listed with their share;
//   3. allocations and the live heap at exit by type (the census builds,
//      RT_CENSUS=1), the generated compiler's grouped by representation;
//   4. counters (perf stat).
// Environment: ML2HX_PROFILE_RUNS (timing runs per side, default 3),
// ML2HX_PROFILE_FREQ (perf sampling Hz, default 999), PERF (the perf binary),
// ML2HX_UTEST (a utest checkout: adds upstream's unit tests compiled to JS).
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync, spawn} from 'node:child_process';
import readline from 'node:readline';

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..');
const dir = path.join(root, 'bin/ml2hx/profile');
const sides = ['port', 'generated'];
const bin = s => path.join(dir, s);
for (const s of [...sides, ...sides.map(s => `${s}-census`)]) if (!fs.existsSync(bin(s))) throw new Error(`build ${bin(s)} first (make ml2hx-profile)`);
const runs = Number(process.env.ML2HX_PROFILE_RUNS ?? 3);
const freq = Number(process.env.ML2HX_PROFILE_FREQ ?? 999);
const env = {...process.env, HAXE_STD_PATH: path.join(root, 'haxe/upstream/std'), HXMC_MODULE_CACHE: '0'};
const sh = (cmd, args, o = {}) => spawnSync(cmd, args, {encoding: 'utf8', maxBuffer: 1 << 30, ...o});

function findPerf() {
  const cands = [process.env.PERF, 'perf'];
  const tools = '/usr/lib';
  if (fs.existsSync(tools)) for (const d of fs.readdirSync(tools).filter(d => d.startsWith('linux-tools-')).sort().reverse()) cands.push(path.join(tools, d, 'perf'));
  for (const c of cands) if (c && sh(c, ['--version']).status === 0) return c;
  throw new Error('perf not found (set PERF)');
}
const perf = findPerf();

// ---- workloads
const workloads = [{id: 'self', name: 'self-typing (haxe/src, --interp --no-output)', cwd: root,
  args: () => ['-cp', 'haxe/src', '-main', 'haxe.Main', '--interp', '--no-output', '-D', 'disable-parallelism', '-D', 'hih_no_generators']}];
if (process.env.ML2HX_UTEST) {
  const utest = path.resolve(process.env.ML2HX_UTEST);
  const unit = path.join(root, 'haxe/upstream/tests/unit');
  const version = JSON.parse(fs.readFileSync(path.join(utest, 'haxelib.json'), 'utf8')).version;
  const extra = fs.existsSync(path.join(utest, 'extraParams.hxml')) ? fs.readFileSync(path.join(utest, 'extraParams.hxml'), 'utf8') : '';
  const each = fs.readFileSync(path.join(unit, 'compile-each.hxml'), 'utf8').replace(/^-lib utest\s*$/m, `-cp ${path.join(utest, 'src')}\n-D utest=${version}\n${extra}`);
  fs.mkdirSync(path.join(dir, 'js'), {recursive: true});
  workloads.push({id: 'js', name: 'unit tests to JS (tests/unit, compile-js.hxml)', cwd: unit, args: side => {
    const f = path.join(dir, 'js', `${side}.hxml`);
    fs.writeFileSync(f, `${each}\n--main unit.TestMain\n-js ${path.join(dir, 'js', side + '.js')}\n-D disable-parallelism\n`);
    return [f];
  }});
}

// ---- 1. timings and --times
function parseTimes(out) {
  const phases = new Map(), stack = [];
  for (const line of out.split('\n')) {
    const m = /^( *)(\S.*?)\s*\|\s*([\d.]+)\s*\|/.exec(line);
    if (!m || m[2] === 'name') continue;
    const depth = m[1].length / 2;
    stack.length = depth;
    stack.push(m[2]);
    phases.set(stack.join(' / '), Number(m[3]));
  }
  return phases;
}
const median = xs => { const s = [...xs].sort((a, b) => a - b); return s.length ? s[Math.floor(s.length / 2)] : NaN; };
function timed(w, side) {
  const tf = path.join(dir, 'time.txt');
  const p = sh('/usr/bin/time', ['-f', '%e %U %S %M', '-o', tf, bin(side), ...w.args(side), '--times'], {cwd: w.cwd, env});
  if (p.status !== 0) throw new Error(`${side} ${w.id}: exit ${p.status}\n${p.stdout}\n${p.stderr}`.slice(0, 4000));
  const [wall, user, sys, rss] = fs.readFileSync(tf, 'utf8').trim().split(/\s+/).map(Number);
  return {wall, user, sys, rss, out: p.stdout + p.stderr};
}

// ---- 2. perf record, by upstream function
// class name -> its file, per package (the port: haxe/src/<pkg>/<File>.hx)
const portClasses = new Map();
(function scan(d, pkg) {
  for (const e of fs.readdirSync(d, {withFileTypes: true})) {
    if (e.isDirectory()) { scan(path.join(d, e.name), [...pkg, e.name]); continue; }
    if (!e.name.endsWith('.hx')) continue;
    const file = e.name.slice(0, -3);
    const src = fs.readFileSync(path.join(d, e.name), 'utf8');
    for (const m of src.matchAll(/^\s*(?:@:[^\n]*\s+)*(?:(?:private|final|extern)\s+)*(?:class|abstract|enum)\s+([A-Z]\w*)/gm))
      if (!portClasses.has([...pkg, m[1]].join('_'))) portClasses.set([...pkg, m[1]].join('_'), {pkg, file});
  }
})(path.join(root, 'haxe/src'), []);
const lcfirst = s => s[0].toLowerCase() + s.slice(1);
const snake = s => s.replace(/([a-z0-9])([A-Z])/g, '$1_$2').toLowerCase();
// F_<pkg>_<Class...>_<member>[__lambdaN...]: the tokens
function splitSym(sym) {
  if (!sym.startsWith('F_')) return null;
  const body = sym.slice(2).split('__')[0]; // lambdas fold into their function
  const t = body.split('_');
  let i = 0;
  while (i < t.length && /^[a-z0-9]/.test(t[i])) i++;
  let j = i;
  while (j < t.length && /^[A-Z]/.test(t[j])) j++;
  if (i === j || j === t.length) return null;
  return {pkg: t.slice(0, i), cls: t.slice(i, j), member: t.slice(j).join('_')};
}
const genModules = new Map(); // package path -> unit names (XModule.hx)
function genUnits(pkg) {
  const k = pkg.join('/');
  if (!genModules.has(k)) {
    const d = path.join(root, 'bin/ml2hx/generated', ...pkg);
    genModules.set(k, fs.existsSync(d) ? fs.readdirSync(d).filter(f => f.endsWith('Module.hx')).map(f => f.slice(0, -9)).sort((a, b) => b.length - a.length) : []);
  }
  return genModules.get(k);
}
function key(pkgPath, unit, subs, member) { return `${pkgPath}${pkgPath ? '/' : ''}${lcfirst(unit)}.ml:${[...subs, member].join('.')}`; }
function mapGenerated(sym) {
  const s = splitSym(sym);
  if (!s || !['upstream', 'ocaml'].includes(s.pkg[0])) return null;
  const pkg = s.pkg[0] === 'upstream' ? s.pkg.slice(1) : s.pkg;
  let [first, ...subs] = s.cls;
  let unit;
  if (first.endsWith('Module')) unit = first.slice(0, -6);
  else if (subs.length) unit = first;
  else {
    // a type's class (FooT, FooBarT): its unit by the longest prefix
    unit = genUnits(s.pkg).find(u => first.startsWith(u));
    if (!unit) return null;
    subs = [`(${first.slice(unit.length)})`];
  }
  return key(pkg.join('/'), unit, subs, s.member);
}
function mapPort(sym) {
  const s = splitSym(sym);
  if (!s) return null;
  // the class: the longest run of class tokens declared in haxe/src
  for (let n = s.cls.length; n > 0; n--) {
    const c = portClasses.get([...s.pkg, s.cls.slice(0, n).join('_')].join('_'));
    if (!c) continue;
    const cls = s.cls.slice(0, n).join('_');
    const subs = cls === c.file ? [] : [cls];
    return key(c.pkg.join('/'), c.file, subs, [...s.cls.slice(n), s.member].join('_'));
  }
  return null;
}
// what a leaf outside upstream code is
function category(sym) {
  if (/^F_hxmc_rt_Gc_|^hxmc_zero$|^F_hxmc_rt_Gc|clear_page|page_fault|addr_fault|^rt_alloc|^hx_alloc|^hxmc_new/.test(sym)) return 'allocation and collection (Gc, zeroing, page faults)';
  if (/^F_ml2hx_rt_Poly_/.test(sym)) return 'polymorphic compare and hash (ml2hx.rt.Poly)';
  if (/^F_hxmc_rt_Dyn_|^F_Type_|^F_Reflect_|^F_Std_|^hx_dyn|^F_hxmc_rt_Enum/.test(sym)) return 'reflection and dynamic access (Dyn, Type, Std)';
  if (/^hx_(un)?box_/.test(sym)) return 'boxing';
  if (/^F_haxe_ds_/.test(sym)) return 'Haxe maps (haxe.ds)';
  if (/^F_hxmc_rt_Arr_|^hx_a|^hx_arr/.test(sym)) return 'arrays (runtime)';
  if (/^F_hxmc_rt_Str|^F_StringBuf|^F_StringTools|^hx_str|^F_String_/.test(sym)) return 'strings (runtime)';
  if (/^F_ml2hx_/.test(sym)) return 'ml2hx runtime and prims';
  if (/^F_hxmc_|^hx_|^rt_/.test(sym)) return 'other hxmc runtime';
  if (/^F_/.test(sym)) return 'Haxe code mapped to no upstream unit';
  return 'libc and kernel';
}
async function profile(w, side, data) {
  const p = sh(perf, ['record', '-F', String(freq), '-g', '-o', data, '--', bin(side), ...w.args(side)], {cwd: w.cwd, env});
  if (p.status !== 0) throw new Error(`perf record ${side}: ${p.stderr}`.slice(0, 4000));
  const map = side === 'port' ? mapPort : mapGenerated;
  const self = new Map(), selfRt = new Map(), incl = new Map(), unmappedSelf = new Map(), categories = new Map();
  let samples = 0;
  const cache = new Map();
  const mapped = sym => { if (!cache.has(sym)) cache.set(sym, map(sym)); return cache.get(sym); };
  const child = spawn(perf, ['script', '-i', data, '-F', 'ip,sym', '--no-inline'], {stdio: ['ignore', 'pipe', 'ignore']});
  const rl = readline.createInterface({input: child.stdout, crlfDelay: Infinity});
  let frames = [];
  const flush = () => {
    if (!frames.length) return;
    samples++;
    const leaf = frames[0], lk = mapped(leaf);
    if (lk) self.set(lk, (self.get(lk) ?? 0) + 1); else unmappedSelf.set(leaf, (unmappedSelf.get(leaf) ?? 0) + 1);
    const cat = lk ? 'upstream code' : category(leaf);
    categories.set(cat, (categories.get(cat) ?? 0) + 1);
    // the runtime's leaf time charged to the nearest upstream caller
    const owner = frames.map(mapped).find(k => k);
    if (owner) selfRt.set(owner, (selfRt.get(owner) ?? 0) + 1);
    const seen = new Set();
    for (const f of frames) { const k = mapped(f) ?? `?${f}`; if (!seen.has(k)) { seen.add(k); incl.set(k, (incl.get(k) ?? 0) + 1); } }
    frames = [];
  };
  for await (const line of rl) {
    const t = line.trim();
    if (!t) { flush(); continue; }
    const m = /^[0-9a-f]+\s+(.*)$/.exec(t);
    if (m) frames.push(m[1].replace(/\+0x[0-9a-f]+$/, ''));
  }
  flush();
  return {samples, self, selfRt, incl, unmappedSelf, categories};
}

// ---- 3. census
function census(w, side) {
  const p = sh(bin(`${side}-census`), w.args(`${side}-census`), {cwd: w.cwd, env: {...env, RT_CENSUS: '1', RT_CENSUS_TOP: '1000000'}});
  if (p.status !== 0) throw new Error(`census ${side}: exit ${p.status}\n${p.stderr}`.slice(0, 4000));
  const out = p.stdout + p.stderr;
  fs.writeFileSync(path.join(dir, `census-${w.id}-${side}.txt`), out);
  const table = (start, stop) => {
    const m = new Map();
    const lines = out.split('\n');
    let i = lines.findIndex(l => l.startsWith(start));
    if (i < 0) return m;
    while (i < lines.length && !/^\s+type\s+count/.test(lines[i])) i++;
    for (i++; i < lines.length; i++) {
      const l = lines[i];
      if (stop.test(l) || !l.startsWith('  ')) break;
      const x = /^  (.+?)\s+(\d+)\s+([\d.]+)\s+(?:[\d.]+\s+)?([\d.]+)\s*$/.exec(l);
      if (x) m.set(x[1].trim(), {count: Number(x[2]), mb: Number(x[3])});
    }
    return m;
  };
  return {live: table('census (exit)', /^  arrays \(with data\)/), alloc: table('allocations:', /^\S/),
    liveTotal: /census \(exit\): (\d+) objects, ([\d.]+) MB/.exec(out), allocTotal: /allocations: (\d+) objects, ([\d.]+) MB/.exec(out)};
}
function kindOf(t) {
  if (/^ValueType\./.test(t)) return 'Type.typeof results (ValueType)';
  if (t === 'haxe.Int64') return 'Int64 boxes (OCaml ints as Dynamic)';
  if (/^ml2hx\.rt\.Tuple\d+$/.test(t)) return 'tuples';
  if (/^ml2hx\.rt\.MlList\./.test(t)) return 'list cells';
  if (/^ml2hx\.rt\.Ref$/.test(t)) return 'refs';
  if (/^ml2hx\.rt\.MlOption\./.test(t)) return 'options';
  if (/^Ref</.test(t)) return 'captured locals (Ref<>)';
  if (t === 'String') return 'strings';
  if (/^Array|^ArrayData/.test(t)) return 'arrays';
  if (/^(Int|Float|Bool)$/.test(t)) return 'Int, Float, Bool boxes';
  if (/^haxe\.ds\./.test(t)) return 'maps';
  if (/^\{/.test(t)) return 'anonymous objects';
  if (/[Cc]losure|^fn|^\$/.test(t)) return 'closures';
  if (/^(upstream|ocaml)\./.test(t)) return /\.[A-Z]\w*\.[A-Z]\w*$/.test(t) ? 'variants' : 'records and objects';
  if (/^ml2hx\.|^StringBuf$|^haxe\.io\./.test(t)) return 'runtime (ml2hx, StringBuf, Bytes)';
  return 'other';
}

// ---- 4. perf stat
const events = ['task-clock', 'cycles', 'instructions', 'branches', 'branch-misses', 'cache-references', 'cache-misses', 'L1-dcache-load-misses', 'LLC-load-misses', 'page-faults', 'context-switches'];
function stat(w, side) {
  const f = path.join(dir, `stat-${w.id}-${side}.csv`);
  const p = sh(perf, ['stat', '-x,', '-o', f, '-e', events.join(','), '--', bin(side), ...w.args(side)], {cwd: w.cwd, env});
  if (p.status !== 0) throw new Error(`perf stat ${side}: ${p.stderr}`.slice(0, 4000));
  const m = new Map();
  for (const l of fs.readFileSync(f, 'utf8').split('\n')) {
    const c = l.split(',');
    if (c.length > 3 && events.includes(c[2])) m.set(c[2], c[0].startsWith('<') ? null : Number(c[0]));
  }
  return m;
}

// ---- the report
const fmt = (x, d = 2) => x == null || Number.isNaN(x) ? '—' : x.toFixed(d);
const ratio = (g, p) => p ? fmt(g / p) + 'x' : '—';
const sign = (x, d = 2) => x == null || Number.isNaN(x) ? '—' : (x >= 0 ? '+' : '') + x.toFixed(d);
const md = [];
const git = a => sh('git', a, {cwd: root}).stdout.trim();
md.push('# The generated compiler against the port: profile', '');
md.push(`- commit: ${git(['rev-parse', '--short', 'HEAD'])}${git(['status', '--porcelain', '--untracked-files=no']) ? ' (with local changes)' : ''}, ${new Date().toISOString().slice(0, 16).replace('T', ' ')} UTC`);
md.push('- builds (make ml2hx-profile, HXMC_SYMBOLS=1): port `-cp haxe/src -main haxe.Main`, generated `-cp bin/ml2hx/generated -main Ml2hxCompiler`; both `-D disable-parallelism -D hxmc.gc-prefault -cp bin/hxmc/std --custom-target hxmc`; census builds add `-D hxmc.census`');
md.push(`- runs: ${runs} timed per side (alternating, medians), perf record at ${freq} Hz with frame-pointer call graphs, one perf stat and one census run per side; host ${sh('uname', ['-srm']).stdout.trim()}, ${sh('nproc', []).stdout.trim()} CPUs, load ${fs.readFileSync('/proc/loadavg', 'utf8').split(' ').slice(0, 3).join(' ')}`);
md.push(`- raw data: bin/ml2hx/profile (times-*.txt, perf-*.data, profile-*.json, census-*.txt, stat-*.csv)`, '');

for (const w of workloads) {
  md.push(`## ${w.name}`, '');
  // 1
  const t = {port: [], generated: []};
  for (let i = 0; i < runs; i++) for (const s of i % 2 ? [...sides].reverse() : sides) {
    const r = timed(w, s);
    fs.writeFileSync(path.join(dir, `times-${w.id}-${s}-${t[s].length}.txt`), r.out);
    t[s].push(r);
  }
  const med = s => ({wall: median(t[s].map(r => r.wall)), user: median(t[s].map(r => r.user)), sys: median(t[s].map(r => r.sys)), rss: median(t[s].map(r => r.rss)) / 1024});
  const mp = med('port'), mg = med('generated');
  md.push('### Time', '', '| | port | generated | Δ | ratio |', '| --- | ---: | ---: | ---: | ---: |');
  for (const [k, n, d] of [['wall', 'wall (s)', 2], ['user', 'user (s)', 2], ['sys', 'sys (s)', 2], ['rss', 'peak RSS (MB)', 0]]) md.push(`| ${n} | ${fmt(mp[k], d)} | ${fmt(mg[k], d)} | ${sign(mg[k] - mp[k], d)} | ${ratio(mg[k], mp[k])} |`);
  md.push('', '### Phases (--times, medians)', '', '| phase | port (s) | generated (s) | Δ | ratio |', '| --- | ---: | ---: | ---: | ---: |');
  const ph = s => { const all = t[s].map(r => parseTimes(r.out)); const keys = new Set(all.flatMap(m => [...m.keys()])); return new Map([...keys].map(k => [k, median(all.map(m => m.get(k) ?? 0))])); };
  const pp = ph('port'), pg = ph('generated');
  for (const k of new Set([...pp.keys(), ...pg.keys()])) md.push(`| ${k.split(' / ').map((x, i, a) => i < a.length - 1 ? '' : '&nbsp;&nbsp;'.repeat(i) + x).join('')} | ${fmt(pp.get(k), 3)} | ${fmt(pg.get(k), 3)} | ${sign((pg.get(k) ?? 0) - (pp.get(k) ?? 0), 3)} | ${ratio(pg.get(k), pp.get(k))} |`);
  md.push('');
  // 2
  const prof = {};
  for (const s of sides) {
    prof[s] = await profile(w, s, path.join(dir, `perf-${w.id}-${s}.data`));
    fs.writeFileSync(path.join(dir, `profile-${w.id}-${s}.json`), JSON.stringify({samples: prof[s].samples, self: Object.fromEntries(prof[s].self), selfWithRuntime: Object.fromEntries(prof[s].selfRt), inclusive: Object.fromEntries(prof[s].incl), unmappedSelf: Object.fromEntries(prof[s].unmappedSelf), categories: Object.fromEntries(prof[s].categories)}));
  }
  // seconds of CPU: samples scaled to each side's median user + sys time
  const secs = s => (s === 'port' ? mp.user + mp.sys : mg.user + mg.sys) / prof[s].samples;
  const rows = what => {
    const keys = new Set([...prof.port[what].keys(), ...prof.generated[what].keys()].filter(k => !k.startsWith('?')));
    return [...keys].map(k => { const p = (prof.port[what].get(k) ?? 0) * secs('port'), g = (prof.generated[what].get(k) ?? 0) * secs('generated'); return {k, p, g, d: g - p}; });
  };
  const show = k => { const [file, fn] = k.split(':'); return `${file} ${fn.split('.').map(x => /^\(/.test(x) ? x : snake(x)).join('.')}`; };
  md.push(`### Differential profile by upstream function`, '', `perf samples: port ${prof.port.samples}, generated ${prof.generated.samples}; seconds are each side's CPU time (median user + sys) apportioned by samples. Closures fold into the function that contains them; a symbol neither maps is listed below.`, '');
  md.push('#### Where the time goes (leaf samples by category)', '', '| category | port (s) | generated (s) | Δ | ratio |', '| --- | ---: | ---: | ---: | ---: |');
  for (const k of [...new Set([...prof.port.categories.keys(), ...prof.generated.categories.keys()])].sort((a, b) => (prof.generated.categories.get(b) ?? 0) * secs('generated') - (prof.port.categories.get(b) ?? 0) * secs('port') - ((prof.generated.categories.get(a) ?? 0) * secs('generated') - (prof.port.categories.get(a) ?? 0) * secs('port')))) {
    const p = (prof.port.categories.get(k) ?? 0) * secs('port'), g = (prof.generated.categories.get(k) ?? 0) * secs('generated');
    md.push(`| ${k} | ${fmt(p)} | ${fmt(g)} | ${sign(g - p)} | ${ratio(g, p)} |`);
  }
  md.push('');
  for (const [what, title] of [['incl', 'Inclusive (the function and what it calls)'], ['selfRt', 'Self, with the runtime it calls (leaf samples charged to the nearest upstream function)'], ['self', 'Self (leaf samples in the function itself)']]) {
    const all = rows(what);
    const both = all.filter(r => r.p > 0 && r.g > 0), one = all.filter(r => !(r.p > 0 && r.g > 0));
    md.push(`#### ${title}: top 30 by |Δ| among functions found on both sides`, '', '| function | port (s) | generated (s) | Δ | ratio |', '| --- | ---: | ---: | ---: | ---: |');
    for (const r of both.sort((a, b) => Math.abs(b.d) - Math.abs(a.d)).slice(0, 30)) md.push(`| ${show(r.k)} | ${fmt(r.p)} | ${fmt(r.g)} | ${sign(r.d)} | ${ratio(r.g, r.p)} |`);
    md.push('', `Found on one side only (names that differ: the generated compiler's library units, closures numbered by OCaml, the port's own helpers), top 15 by time:`, '', '| function | port (s) | generated (s) |', '| --- | ---: | ---: |');
    for (const r of one.sort((a, b) => Math.max(b.p, b.g) - Math.max(a.p, a.g)).slice(0, 15)) md.push(`| ${show(r.k)} | ${fmt(r.p)} | ${fmt(r.g)} |`);
    md.push('');
  }
  md.push('#### Leaf samples in no upstream function (runtime, collector, libc, unmapped)', '');
  for (const s of sides) {
    const u = [...prof[s].unmappedSelf].sort((a, b) => b[1] - a[1]);
    const tot = u.reduce((a, [, n]) => a + n, 0);
    md.push(`${s}: ${fmt(100 * tot / prof[s].samples, 1)}% of samples (${fmt(tot * secs(s))} s); top 25:`, '', '| symbol | share | s |', '| --- | ---: | ---: |');
    for (const [sym, n] of u.slice(0, 25)) md.push(`| \`${sym}\` | ${fmt(100 * n / prof[s].samples, 1)}% | ${fmt(n * secs(s))} |`);
    md.push('');
  }
  // 3
  const c = {port: census(w, 'port'), generated: census(w, 'generated')};
  md.push('### Allocations (census builds)', '');
  md.push(`Allocated over the run: port ${c.port.allocTotal?.[1] ?? '—'} objects, ${c.port.allocTotal?.[2] ?? '—'} MB; generated ${c.generated.allocTotal?.[1] ?? '—'} objects, ${c.generated.allocTotal?.[2] ?? '—'} MB. Live at exit (after a major collection): port ${c.port.liveTotal?.[1] ?? '—'} objects, ${c.port.liveTotal?.[2] ?? '—'} MB; generated ${c.generated.liveTotal?.[1] ?? '—'} objects, ${c.generated.liveTotal?.[2] ?? '—'} MB. The census counts by type: it has no allocation sites (a type's name gives its upstream module).`, '');
  const kinds = new Map();
  for (const [ty, v] of c.generated.alloc) { const k = kindOf(ty); const e = kinds.get(k) ?? {count: 0, mb: 0, live: 0}; e.count += v.count; e.mb += v.mb; kinds.set(k, e); }
  for (const [ty, v] of c.generated.live) { const k = kindOf(ty); const e = kinds.get(k) ?? {count: 0, mb: 0, live: 0}; e.live += v.mb; kinds.set(k, e); }
  md.push('#### The generated compiler by kind', '', '| kind | allocated objects | allocated MB | live MB at exit |', '| --- | ---: | ---: | ---: |');
  for (const [k, e] of [...kinds].sort((a, b) => b[1].mb - a[1].mb)) md.push(`| ${k} | ${e.count} | ${fmt(e.mb)} | ${fmt(e.live)} |`);
  md.push('');
  for (const [what, title] of [['alloc', 'Allocated by type, top 40 by MB'], ['live', 'Live at exit by type, top 25 by MB']]) {
    md.push(`#### ${title}`, '', '| port type | objects | MB | | generated type | objects | MB |', '| --- | ---: | ---: | --- | --- | ---: | ---: |');
    const a = [...c.port[what]].sort((x, y) => y[1].mb - x[1].mb), b = [...c.generated[what]].sort((x, y) => y[1].mb - x[1].mb);
    for (let i = 0; i < (what === 'alloc' ? 40 : 25); i++) {
      const x = a[i], y = b[i];
      if (!x && !y) break;
      md.push(`| ${x ? '`' + x[0] + '`' : ''} | ${x ? x[1].count : ''} | ${x ? fmt(x[1].mb) : ''} | | ${y ? '`' + y[0] + '`' : ''} | ${y ? y[1].count : ''} | ${y ? fmt(y[1].mb) : ''} |`);
    }
    md.push('');
  }
  // 4
  const st = {port: stat(w, 'port'), generated: stat(w, 'generated')};
  md.push('### Counters (perf stat)', '', 'Hardware counters read "not supported" on a host without a PMU (a VM): the software ones remain.', '', '| counter | port | generated | ratio |', '| --- | ---: | ---: | ---: |');
  for (const e of events) {
    const p = st.port.get(e), g = st.generated.get(e);
    md.push(`| ${e} | ${p == null ? 'not supported' : p.toLocaleString('en')} | ${g == null ? 'not supported' : g.toLocaleString('en')} | ${p && g ? ratio(g, p) : '—'} |`);
  }
  const ipc = s => st[s].get('instructions') && st[s].get('cycles') ? st[s].get('instructions') / st[s].get('cycles') : null;
  md.push(`| IPC | ${fmt(ipc('port'))} | ${fmt(ipc('generated'))} | ${ipc('port') && ipc('generated') ? ratio(ipc('generated'), ipc('port')) : '—'} |`, '');
}
fs.writeFileSync(path.join(dir, 'profile.md'), md.join('\n') + '\n');
console.log(`wrote ${path.relative(root, path.join(dir, 'profile.md'))}`);
