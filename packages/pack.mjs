// The npm packages (docs/using.md; `make npm`, CI). Each folder of
// packages/ is one package, or for `platform` the template of six:
//   node packages/pack.mjs <version> <natives dir> <out dir> [<rt dir>]
// <natives dir>/<target>/haxe[.exe] are the native compilers, <rt dir>/<target>/
// {rt,ssl,uv}.o the runtime objects (default bin/hxmc/rt). Writes to <out dir>,
// in the order they are published (each one's dependencies first), all at
// <version>:
//   hxmc-<os>-<cpu>-<version>.tgz  the six platform packages @hxmc/<os>-<cpu>
//                                  (packages/platform, its {pkg}, {os}, {cpu},
//                                  {exe} and {rtList} filled in): the native
//                                  compiler and the runtime objects of the
//                                  machine's targets (<target>/; Linux's with
//                                  the glibc mode's), with the licenses of
//                                  mbedtls and libuv
//   hxmc-cli-<version>.tgz         @hxmc/cli (packages/cli: the launcher, dist/
//                                  for lix, hxmc's merged std that `make npm`
//                                  puts there): with upstream's std and its
//                                  optional dependencies on the platform
//                                  packages at this version; its package.json's
//                                  "hxmc": {"rt": "rt-<hash>"} names the GitHub
//                                  release of the runtime objects packed here
//                                  (<rt dir>/HASH, which must be this checkout's
//                                  hxmc/bootstrap/rt.mjs hash): the source of the
//                                  targets in no package (Android)
//   hxmc-source-<version>.tgz      @hxmc/source (packages/source: hxmc-rebuild):
//                                  the compiler's sources (haxe/src, hxmc/src,
//                                  hxmc/std, hxmc/portable), which @hxmc/cli's
//                                  haxe builds (frontends, docs/hxmc.md); a
//                                  peer dependency on @hxmc/cli at this version
// and sizes.md, their sizes.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { PLATFORMS } from './cli/hxmc/bootstrap/platforms.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.dirname(here);
const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm';
const readJson = file => JSON.parse(fs.readFileSync(file, 'utf8'));
const sizes = [];

// npm pack's report: {filename, size, unpackedSize, entryCount, integrity}
function pack(cwd, outAbs) {
	const r = JSON.parse(execFileSync(npm, ['pack', '--json', '--pack-destination', outAbs], { cwd, stdio: ['ignore', 'pipe', 'inherit'], shell: process.platform === 'win32' }).toString())[0];
	console.log(`pack: ${r.filename} (${(r.size / 1024).toFixed(0)} KB, ${(r.unpackedSize / 1024).toFixed(0)} KB unpacked, ${r.entryCount} files)`);
	sizes.push(r);
	return r;
}

const argv = process.argv.slice(2);
const [version, natives, out, rtDir = path.join(root, 'bin', 'hxmc', 'rt')] = argv;
if (!version || !natives || !out) {
	console.error('usage: node packages/pack.mjs <version> <natives dir> <out dir> [<rt dir>]');
	process.exit(2);
}
fs.mkdirSync(out, { recursive: true });
const outAbs = path.resolve(out);

// the runtime objects' identity: <rt dir>/HASH (rt.mjs fetch, make rt-layouts),
// the hash of the hxmc/deps they were built from, which is this checkout's
const stamp = path.join(rtDir, 'HASH');
const rtHash = fs.existsSync(stamp) ? fs.readFileSync(stamp, 'utf8').trim() : null;
const wantHash = execFileSync(process.execPath, [path.join(root, 'hxmc', 'bootstrap', 'rt.mjs'), 'hash']).toString().trim();
if (rtHash !== wantHash) {
	console.error(`pack: ${stamp} ${rtHash ? `says rt-${rtHash}` : 'is missing'}, hxmc/deps is rt-${wantHash} (make rt)`);
	process.exit(1);
}

const cli = readJson(path.join(here, 'cli', 'package.json'));
const common = { version, license: cli.license, repository: cli.repository };

// <out dir>/stage/<name>: packages/<template> (its package.json filled in from
// vars, with this version and @hxmc/cli's license and repository), then files
// ([to, from]: from relative to the repository, or absolute), LICENSE and
// COPYING; exec: files made executable
function stage(template, vars, files, exec = [], edit = m => m) {
	let text = fs.readFileSync(path.join(here, template, 'package.json'), 'utf8');
	for (const [k, v] of Object.entries({ version, ...vars })) text = text.replaceAll(`{${k}}`, v);
	// (@hxmc/cli's own fields stay where they are, the others follow the name)
	const t = JSON.parse(text);
	const m = { name: t.name };
	for (const [k, v] of Object.entries(common)) if (!(k in t)) m[k] = v;
	Object.assign(m, t, { version });
	const name = m.name;
	const dir = path.join(outAbs, 'stage', name.replace('/', '-').replace('@', ''));
	fs.rmSync(dir, { recursive: true, force: true });
	fs.cpSync(path.join(here, template), dir, { recursive: true });
	for (const [to, from] of [...files, ['LICENSE', 'LICENSE'], ['COPYING', 'COPYING']]) {
		const src = path.resolve(root, from);
		if (!fs.existsSync(src)) {
			console.error(`pack: ${src} is missing`);
			process.exit(1);
		}
		fs.mkdirSync(path.dirname(path.join(dir, to)), { recursive: true });
		fs.cpSync(src, path.join(dir, to), { recursive: true });
	}
	for (const f of exec) fs.chmodSync(path.join(dir, f), 0o755);
	fs.writeFileSync(path.join(dir, 'package.json'), JSON.stringify(edit(m), null, 2) + '\n');
	return pack(dir, outAbs);
}

for (const [target, p] of Object.entries(PLATFORMS)) {
	const files = [[p.exe, path.resolve(natives, target, p.exe)]];
	for (const t of p.rt) for (const f of ['rt.o', 'ssl.o', 'uv.o']) files.push([`${t}/${f}`, path.resolve(rtDir, t, f)]);
	for (const l of ['LICENSE.mbedtls', 'LICENSE.libuv']) files.push([l, path.resolve(rtDir, l)]);
	stage('platform', { ...p, rtList: p.rt.join(' and ') }, files, [p.exe], m => ({ ...m, files: [...m.files, ...p.rt.map(t => `${t}/`)] }));
}

// (the repository's README is the package's page on npm)
// (the runtime objects' release: docs/using.md, "Cross builds")
stage('cli', {}, [['haxe/upstream/std', 'haxe/upstream/std'], ['haxe/upstream/LICENSE', 'haxe/upstream/LICENSE'], ['README.md', 'README.md']],
	['hxmc/bootstrap/haxe', 'dist/haxe'], m => ({ ...m, hxmc: { ...m.hxmc, rt: `rt-${rtHash}` } }));

// (sources only: no tests, no stage0; hxmc/portable for hxmc-rebuild's MkStd)
stage('source', {}, [['haxe/src', 'haxe/src'], ['hxmc/src', 'hxmc/src'], ['hxmc/std', 'hxmc/std'], ['hxmc/portable', 'hxmc/portable']],
	['hxmc/bootstrap/hxmc-rebuild']);

const kb = n => `${(n / 1024 / 1024).toFixed(1)} MB`;
fs.writeFileSync(path.join(outAbs, 'sizes.md'), [
	'| npm package | tarball | unpacked | files |', '| --- | ---: | ---: | ---: |',
	...sizes.map(s => `| ${s.name}@${s.version} | ${kb(s.size)} | ${kb(s.unpackedSize)} | ${s.entryCount} |`),
].join('\n') + '\n');
console.log(fs.readFileSync(path.join(outAbs, 'sizes.md'), 'utf8'));
