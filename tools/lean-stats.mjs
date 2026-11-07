// Reproducible lean-plan measurements. No application files or caches are
// removed; each invocation gets a directory under ignored bin/lean-stats.
// LEAN_TIME=/path/to/GNU/time make lean-stats
// Optional: LEAN_BASELINE=/path/to/hxmc LEAN_BASELINE_STD=/path/to/std
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const output = fs.mkdtempSync(path.join(root, 'bin', 'lean-stats-'));
const timer = process.env.LEAN_TIME || '/usr/bin/time';
const runs = Number(process.env.LEAN_RUNS || 3);
if (!Number.isInteger(runs) || runs < 1 || runs > 20) throw new Error('LEAN_RUNS must be 1..20');
if (!fs.existsSync(timer)) throw new Error('GNU time is required; set LEAN_TIME to its executable');
const variants = [{ name: 'current', tool: path.join(root, 'bin/hxmc/hxmc'), std: path.join(root, 'bin/hxmc/std') }];
if (process.env.LEAN_BASELINE) variants.unshift({ name: 'baseline', tool: path.resolve(process.env.LEAN_BASELINE), std: path.resolve(process.env.LEAN_BASELINE_STD || variants[0].std) });
for (const v of variants) v.sha256 = createHash('sha256').update(fs.readFileSync(v.tool)).digest('hex');
const env = { ...process.env, LC_ALL: 'C', HAXE_STD_PATH: path.join(root, 'haxe/upstream/std'), HXMC_RT_DIR: path.join(root, 'bin/hxmc/rt'), HXMC_MODULE_CACHE: '0', HXMC_STATS: '1', HXMC_JOBS: '4' };
const samples = [];

function run(name, variant, command, cwd = root) {
  const base = path.join(output, `${name}-${variant.name}-${samples.length}`);
  const fd = fs.openSync(base + '.log', 'w');
  let r;
  try {
    r = spawnSync(timer, ['-f', '%e %U %S %M', '-o', base + '.time', ...command], { cwd, env: { ...env, HXMC_CACHE: base + '.cache' }, stdio: ['ignore', fd, fd] });
  } finally { fs.closeSync(fd); }
  if (r.error || r.status !== 0) throw new Error(`${name} (${variant.name}) failed: ${r.error || r.signal || r.status}; see ${base}.log`);
  const text = fs.readFileSync(base + '.time', 'utf8').trim();
  if (!/^\d+(?:\.\d+)? \d+(?:\.\d+)? \d+(?:\.\d+)? \d+$/.test(text)) throw new Error(`Invalid GNU time result: ${base}.time`);
  const [wall, user, system, rss] = text.split(' ').map(Number);
  const s = { name, variant: variant.name, wall_s: wall, cpu_s: user + system, rss_kib: rss, log: path.relative(root, base + '.log') };
  samples.push(s);
  console.log(`${name} ${variant.name}: ${wall}s wall, ${s.cpu_s.toFixed(2)}s CPU, ${(rss / 1024).toFixed(1)} MiB peak RSS`);
  return s;
}

// Alternate compilers to spread machine drift across both sides. Every
// self-build is cold: module/object cache off, fresh output path. The
// compiler's normal internal parallelism is fixed at four workers.
for (let round = 0; round < runs; round++) {
  for (const v of variants) {
    const exe = path.join(output, `${v.name}-self-${round}`);
    run('self-build', v, [v.tool, exe, '-cp', 'haxe/src', '-cp', 'hxmc/src', '-main', 'hxmc.Main', '-D', 'disable-parallelism', '-D', 'hih_no_generators', '-cp', v.std, '-D', 'hxmc.gc-prefault', '--custom-target', 'hxmc']);
    v.binary_bytes = fs.statSync(exe).size;
    v.tool_bytes = fs.statSync(v.tool).size;
  }
}

// The same pinned HaxeBenchmarks programs as Bench.hx, without installing
// unrelated target toolchains. Prepare them with Bench --setup -t hxmc.
const benchmarks = [
  ['json', 'BMJsonCode', 'CheckJson'], ['alloc', 'BMAllocCode', 'CheckAlloc'],
  ['nbody', 'BMNBodyCode', 'CheckNbody'], ['mandelbrot', 'BMMandelbrotCode', 'CheckMandelbrot'],
];
for (const [name, main, check] of benchmarks) {
  const source = path.join(root, 'bin/bench/runner/cases', name);
  if (!fs.existsSync(path.join(source, main + '.hx'))) throw new Error('Run Bench --setup -t hxmc first (docs/testing.md)');
  const cwd = path.join(source, 'out');
  fs.mkdirSync(cwd, { recursive: true });
  for (const v of variants) {
    const exe = path.join(output, `${name}-${v.name}`);
    run(`${name}-build`, v, [v.tool, exe, '-cp', source, '-main', main, '-cp', v.std, '--custom-target', 'hxmc']);
    v.benchmarks ??= {};
    v.benchmarks[name] = { bytes: fs.statSync(exe).size, exe };
  }
  for (let round = 0; round < runs; round++)
    for (const v of variants) run(name, v, [v.benchmarks[name].exe], cwd);
  let expected;
  for (const v of variants) {
    const exe = path.join(output, `${name}-check-${v.name}`);
    run(`${name}-check-build`, v, [v.tool, exe, '-cp', source, '-cp', path.join(root, 'hxmc/test/bench'), '-main', check, '-cp', v.std, '--custom-target', 'hxmc']);
    const result = run(`${name}-check`, v, [exe], cwd);
    const text = fs.readFileSync(path.join(root, result.log), 'utf8');
    if (!text.trim()) throw new Error(`${check} did not print its result`);
    if (expected !== undefined && text !== expected) throw new Error(`${check} differs between compilers`);
    expected = text;
  }
}

function lines(dir) {
  let n = 0;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) n += lines(p);
    else if (p.endsWith('.hx')) n += fs.readFileSync(p, 'utf8').split('\n').length - 1;
  }
  return n;
}
function median(a) { a.sort((x, y) => x - y); const i = Math.floor(a.length / 2); return a.length % 2 ? a[i] : (a[i - 1] + a[i]) / 2; }
const medians = [];
for (const v of variants) for (const name of ['self-build', ...benchmarks.map(b => b[0])]) {
  const ss = samples.filter(s => s.name === name && s.variant === v.name);
  medians.push({ name, variant: v.name, wall_s: median(ss.map(s => s.wall_s)), cpu_s: median(ss.map(s => s.cpu_s)), rss_kib: median(ss.map(s => s.rss_kib)) });
}
const sourceCommit = spawnSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' });
if (sourceCommit.status !== 0) throw new Error('Cannot identify the measured source revision');
const dirty = spawnSync('git', ['status', '--porcelain'], { cwd: root, encoding: 'utf8' });
if (dirty.status !== 0) throw new Error('Cannot identify the measured source state');
const doc = { schema: 1, date: new Date().toISOString(), source_commit: sourceCommit.stdout.trim(), source_dirty: dirty.stdout.length > 0, runs, jobs: 4, cache: 'cold', lines: { compiler: lines(path.join(root, 'hxmc/src')), runtime: lines(path.join(root, 'hxmc/std')) }, variants, medians, samples };
fs.writeFileSync(path.join(output, 'results.json'), JSON.stringify(doc, null, 2) + '\n');
console.log(`Results: ${path.join(output, 'results.json')}`);
