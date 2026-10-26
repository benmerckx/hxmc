// `hxmc-rebuild` (packages/source, @hxmc/source: not published for now):
// builds the compiler again from the package's (possibly edited) haxe/src,
// hxmc/src and hxmc/std, with @hxmc/haxe's std and the installed runtime
// objects, into the cache (<cache>/npm/<version>/rebuild/<target>/: haxe[.exe]
// and hxmc-std), where @hxmc/haxe's launcher prefers it while @hxmc/source is
// installed.
//   hxmc-rebuild            the native compiler builds it (the platform
//                           package's: seconds; its compiled modules are kept
//                           in build/, so the next rebuild compiles only what
//                           changed); without one that runs, the WebAssembly
//                           compiler (@hxmc/haxe-wasm, installed or downloaded)
//   hxmc-rebuild --reset    back to the published compiler
// One build at a time: <dir>/build.lock holds the builder's process id.
import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const srcDir = path.dirname(path.dirname(path.dirname(fileURLToPath(import.meta.url))));
// @hxmc/haxe's launcher
let launcherPath;
try {
	launcherPath = path.join(path.dirname(createRequire(import.meta.url).resolve('@hxmc/haxe/package.json')), 'hxmc', 'bootstrap', 'launcher.mjs');
} catch {
	console.error('hxmc-rebuild: @hxmc/haxe is not installed (npm i -D @hxmc/cli @hxmc/source)');
	process.exit(1);
}
const L = await import(pathToFileURL(launcherPath).href);
const srcVersion = JSON.parse(fs.readFileSync(path.join(srcDir, 'package.json'), 'utf8')).version;
if (srcVersion !== L.version) {
	console.error(`hxmc-rebuild: @hxmc/source ${srcVersion} needs @hxmc/haxe ${srcVersion} (installed: ${L.version})`);
	process.exit(1);
}
const host = L.hostTarget();
if (!host) {
	console.error(`hxmc-rebuild: no native compiler for ${process.platform}-${process.arch}`);
	process.exit(1);
}
const dir = L.rebuildDir();

if (process.argv.includes('--reset')) {
	fs.rmSync(dir, { recursive: true, force: true });
	const native = L.platformBinary();
	if (native && L.nativeRuns(native)) L.install(native);
	console.log(`hxmc-rebuild: removed ${dir}: haxe runs the published compiler`);
	process.exit(0);
}

fs.mkdirSync(dir, { recursive: true });
const lock = path.join(dir, 'build.lock');
while (true) {
	try {
		fs.writeFileSync(lock, String(process.pid), { flag: 'wx' });
		break;
	} catch {
		if (!L.lockHeld(lock)) {
			fs.writeFileSync(lock, String(process.pid)); // a stale lock
			break;
		}
		console.log('hxmc-rebuild: waiting for another build');
		while (L.lockHeld(lock)) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 500);
	}
}

let code = 1;
try {
	// the compiler that builds: the platform package's native one, else WebAssembly
	const native = L.platformBinary();
	let run;
	if (native && L.nativeRuns(native)) {
		console.log(`hxmc-rebuild: building with ${native}`);
		run = (args, env) => {
			const r = spawnSync(native, args, { stdio: 'inherit', env: L.toolEnv(env) });
			if (r.error) throw r.error;
			return r.status ?? 1;
		};
	} else {
		const { wasmPackage } = await import(pathToFileURL(path.join(path.dirname(launcherPath), 'wasm.mjs')).href);
		const wasm = await wasmPackage();
		const { wasiPath } = await import(pathToFileURL(path.join(wasm, 'wasi.mjs')).href);
		console.log(`hxmc-rebuild: no native compiler runs here: building with the WebAssembly one (${wasm}; slower)`);
		run = (args, env) => L.wasm(wasm, args.map(a => a.startsWith('hxmc=') ? `hxmc=${wasiPath(a.slice(5))}` : a), host, env);
	}
	const t0 = Date.now();
	// hxmc's std as programs see it (hxmc/src/hxmc/MkStd.hx, on Eval)
	const std = path.join(dir, 'hxmc-std');
	console.log(`hxmc-rebuild: merging hxmc/std into ${std}`);
	code = await run(['-cp', path.join(srcDir, 'hxmc', 'src'), '--run', 'hxmc.MkStd', path.join(srcDir, 'hxmc', 'std'),
		L.toolEnv().HAXE_STD_PATH, std], {});
	if (code !== 0) throw new Error(`hxmc.MkStd failed (exit ${code})`);
	// (build/: the output and its compiled modules, kept for the next rebuild)
	const work = path.join(dir, 'build');
	fs.mkdirSync(work, { recursive: true });
	const out = path.join(work, 'haxe');
	for (const f of [out, `${out}.exe`]) fs.rmSync(f, { force: true });
	console.log(`hxmc-rebuild: building the compiler for ${host}`);
	code = await run([
		'-cp', path.join(srcDir, 'haxe', 'src'), '-cp', path.join(srcDir, 'hxmc', 'src'), '-main', 'hxmc.HaxeMain',
		'-D', 'disable-parallelism', '-D', `hxmc.target=${host}`, '--custom-target', `hxmc=${out}`,
	], { HXMC_STD: std });
	const built = fs.existsSync(out) ? out : fs.existsSync(`${out}.exe`) ? `${out}.exe` : null;
	if (code === 0 && built) {
		const exe = path.join(dir, L.exeName);
		fs.copyFileSync(built, `${exe}.new`);
		fs.chmodSync(`${exe}.new`, 0o755);
		fs.renameSync(`${exe}.new`, exe);
		// (npm's link and dist/haxe run the launcher again, which runs this compiler)
		L.restoreLaunchers();
		console.log(`hxmc-rebuild: done in ${((Date.now() - t0) / 1000).toFixed(1)} s: ${exe}`);
		if (!L.sourcePackage()) console.log('hxmc-rebuild: (haxe runs it while @hxmc/source is installed)');
	} else {
		console.error(`hxmc-rebuild: the build failed (exit ${code})`);
		if (code === 0) code = 1;
	}
} catch (e) {
	console.error(`hxmc-rebuild: ${e.message}`);
	code = 1;
} finally {
	fs.rmSync(lock, { force: true });
}
process.exit(code);
