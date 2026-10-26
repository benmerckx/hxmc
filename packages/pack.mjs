// The npm packages (docs/using.md; `make npm`, CI). Each folder of
// packages/ is one package, or for `platform` and `rt` the template of
// several:
//   node packages/pack.mjs <version> <natives dir> <out dir> [<rt dir> <std dir>]
// <natives dir>/<target>/haxe[.exe] are the native compilers and
// <natives dir>/wasm32-wasi/haxe.wasm the WebAssembly one (hxmc.HaxeMain,
// cross-built by the tool); <rt dir>/<target>/{rt,ssl,uv}.o the runtime
// objects (default bin/hxmc/rt) and <std dir> hxmc's merged std (default
// packages/target/std, which `make npm` writes). Writes to <out dir>, in the
// order they are published (each one's dependencies first), all at <version>:
//   hxmc-haxe-<os>-<cpu>-<version>.tgz  the six platform packages
//                                  @hxmc/haxe-<os>-<cpu> (packages/platform, its
//                                  {pkg}, {os}, {cpu} and {exe} filled in): the
//                                  native compiler
//   hxmc-haxe-wasm-<version>.tgz   @hxmc/haxe-wasm (packages/wasm): the compiler
//                                  as a wasm32-wasi module (haxe.wasm) and its
//                                  runner (hxmc/bootstrap/wasi.mjs)
//   hxmc-haxe-<version>.tgz        @hxmc/haxe (packages/haxe: the launcher, dist/
//                                  for lix): with upstream's std, its optional
//                                  dependencies on the platform packages and
//                                  the integrity of @hxmc/haxe-wasm's tarball
//                                  ("hxmc": {"wasmIntegrity"}: the launcher's
//                                  download)
//   hxmc-rt-<target>-<version>.tgz the ten runtime-object packages
//                                  @hxmc/rt-<target> (packages/rt, {target}
//                                  filled in): <target>/{rt,ssl,uv}.o and the
//                                  licenses of mbedtls and libuv
//   hxmc-target-<version>.tgz      @hxmc/target (packages/target): hxmc's std,
//                                  and the integrity of each runtime-object
//                                  tarball ("hxmc": {"rtIntegrity": {<target>:
//                                  ...}}: the launcher's download)
//   hxmc-cli-<version>.tgz         @hxmc/cli (packages/cli: `haxe` and `hxmc`):
//                                  dependencies on @hxmc/haxe and @hxmc/target
// and sizes.md, their sizes. (packages/source, @hxmc/source with
// hxmc-rebuild, is not published.)
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { PLATFORMS, RT_TARGETS } from './haxe/hxmc/bootstrap/platforms.mjs';

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
const [version, natives, out, rtDir = path.join(root, 'bin', 'hxmc', 'rt'), stdDir = path.join(here, 'target', 'std')] = argv;
if (!version || !natives || !out) {
	console.error('usage: node packages/pack.mjs <version> <natives dir> <out dir> [<rt dir> <std dir>]');
	process.exit(2);
}
fs.mkdirSync(out, { recursive: true });
const outAbs = path.resolve(out);

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

for (const [target, p] of Object.entries(PLATFORMS))
	stage('platform', p, [[p.exe, path.resolve(natives, target, p.exe)]], [p.exe]);

const wasm = stage('wasm', {}, [['haxe.wasm', path.resolve(natives, 'wasm32-wasi', 'haxe.wasm')], ['wasi.mjs', 'hxmc/bootstrap/wasi.mjs']]);

stage('haxe', {}, [['haxe/upstream/std', 'haxe/upstream/std'], ['haxe/upstream/LICENSE', 'haxe/upstream/LICENSE']],
	['hxmc/bootstrap/haxe', 'dist/haxe'], m => ({ ...m, hxmc: { wasmIntegrity: wasm.integrity } }));

const rtIntegrity = {};
for (const t of RT_TARGETS) {
	const files = ['rt.o', 'ssl.o', 'uv.o'].map(f => [`${t}/${f}`, path.resolve(rtDir, t, f)]);
	for (const l of ['LICENSE.mbedtls', 'LICENSE.libuv']) files.push([l, path.resolve(rtDir, l)]);
	rtIntegrity[t] = stage('rt', { target: t }, files).integrity;
}

stage('target', {}, [['std', path.resolve(stdDir)]], [], m => ({ ...m, hxmc: { rtIntegrity } }));

// (the repository's README is the package's page on npm)
stage('cli', {}, [['README.md', 'README.md']], ['bin/haxe.mjs', 'bin/hxmc.mjs']);

const kb = n => `${(n / 1024 / 1024).toFixed(1)} MB`;
fs.writeFileSync(path.join(outAbs, 'sizes.md'), [
	'| npm package | tarball | unpacked | files |', '| --- | ---: | ---: | ---: |',
	...sizes.map(s => `| ${s.name}@${s.version} | ${kb(s.size)} | ${kb(s.unpackedSize)} | ${s.entryCount} |`),
].join('\n') + '\n');
console.log(fs.readFileSync(path.join(outAbs, 'sizes.md'), 'utf8'));
