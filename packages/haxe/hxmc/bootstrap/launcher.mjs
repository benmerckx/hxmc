// The `haxe` command of the npm package @hxmc/haxe (and of @hxmc/cli, which
// runs this launcher; docs/using.md): runs, in this order,
// - the compiler `hxmc-rebuild` built from @hxmc/source (in the cache), while
//   @hxmc/source is installed (packages/source: not published);
// - the platform package's native compiler (@hxmc/haxe-<os>-<cpu>, an optional
//   dependency), when it can run here;
// - else the compiler as a WebAssembly module (@hxmc/haxe-wasm under node's
//   WASI: installed, or downloaded once into the cache: wasm.mjs).
// It gives the compiler the std (haxe/upstream/std), hxmc's std (@hxmc/target's
// std/: HXMC_STD) and the directories of the runtime objects (HXMC_RT_DIR: the
// installed @hxmc/rt-<target> packages, and those downloaded into the cache);
// a build for the hxmc target first downloads the runtime objects it needs
// that are in neither (runtime(), registry.mjs).
// On Unix the native compiler then replaces hxmc/bootstrap/haxe and dist/haxe,
// so npm's link and lix run it without node (hxmc builds come back here:
// hxmc.HaxeMain runs haxe.mjs).
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { PLATFORMS, RT_TARGETS } from './platforms.mjs';

export const bootDir = path.dirname(fileURLToPath(import.meta.url));
export const pkgDir = path.dirname(path.dirname(bootDir));
export const pkgJson = JSON.parse(fs.readFileSync(path.join(pkgDir, 'package.json'), 'utf8'));
export const version = pkgJson.version;
// (the repository's packages/haxe, where these files are sources)
const repo = path.join(pkgDir, '..', '..');
const checkout = fs.existsSync(path.join(repo, 'hxmc', 'bootstrap', 'stage0.wasm.br'));
// upstream's std: haxe/upstream/std of the package (of the repository in a checkout)
const stdDir = path.join(checkout ? repo : pkgDir, 'haxe', 'upstream', 'std');
const require = createRequire(import.meta.url);

// hxmc's name of this machine (null: no native build, WebAssembly only)
export function hostTarget() {
	const arch = { x64: 'x86_64', arm64: 'arm64' }[process.arch];
	const plat = { linux: 'linux', darwin: 'macos', win32: 'windows' }[process.platform];
	return arch && plat ? `${plat}-${arch}` : null;
}

// the user's cache directory, as the module cache's (hxmc/src/hxmc/CacheDir.hx):
// HXMC_CACHE, else $XDG_CACHE_HOME/hxmc or ~/.cache/hxmc, ~/Library/Caches/hxmc,
// %LOCALAPPDATA%\hxmc\cache
export function cacheBase() {
	if (process.env.HXMC_CACHE) return process.env.HXMC_CACHE;
	const home = os.homedir();
	if (process.platform === 'win32') return path.join(process.env.LOCALAPPDATA || path.join(home, 'AppData', 'Local'), 'hxmc', 'cache');
	if (process.platform === 'darwin') return path.join(home, 'Library', 'Caches', 'hxmc');
	const xdg = process.env.XDG_CACHE_HOME;
	return path.join(xdg && path.isAbsolute(xdg) ? xdg : path.join(home, '.cache'), 'hxmc');
}

// what the npm packages of this version keep there: <cache>/npm/<version>/
// (wasm/: @hxmc/haxe-wasm downloaded; rt-<target>/: @hxmc/rt-<target>
// downloaded; rebuild/<target>/: hxmc-rebuild's compiler)
export function npmCache() {
	return path.join(cacheBase(), 'npm', version);
}

export const exeName = process.platform === 'win32' ? 'haxe.exe' : 'haxe';

// a package of this version beside this one (resolved from here, else from
// the working directory: the project's node_modules): its directory, or null
export function findPackage(name) {
	for (const from of [import.meta.url, path.join(process.cwd(), 'index.js')]) {
		try {
			const p = createRequire(from).resolve(`${name}/package.json`);
			if (JSON.parse(fs.readFileSync(p, 'utf8')).version === version) return path.dirname(p);
		} catch {}
	}
	return null;
}

// hxmc's std (hxmc/std merged with upstream's by hxmc/src/hxmc/MkStd.hx):
// @hxmc/target's std/ (in a checkout packages/target/std, `make npm`, else
// bin/hxmc/std, `make std`), or null
export function targetStd() {
	if (checkout) {
		for (const d of [path.join(repo, 'packages', 'target', 'std'), path.join(repo, 'bin', 'hxmc', 'std')])
			if (fs.existsSync(d)) return d;
		return null;
	}
	const dir = findPackage('@hxmc/target');
	return dir && path.join(dir, 'std');
}

// the directories of the runtime objects (<dir>/<target>/rt.o, ssl.o, uv.o):
// the installed @hxmc/rt-<target> packages of this version, then those
// downloaded into the cache (in a checkout: bin/hxmc/rt, `make rt`)
export function rtDirs() {
	if (checkout) return [path.join(repo, 'bin', 'hxmc', 'rt')];
	const dirs = [];
	for (const t of RT_TARGETS) {
		const d = findPackage(`@hxmc/rt-${t}`);
		if (d) dirs.push(d);
	}
	for (const t of RT_TARGETS) {
		const d = rtCache(t);
		if (fs.existsSync(path.join(d, t, 'rt.o'))) dirs.push(d);
	}
	return dirs;
}

// where @hxmc/rt-<target> is downloaded: <cache>/npm/<version>/rt-<target>/
function rtCache(t) {
	return path.join(npmCache(), `rt-${t}`);
}

// what the compilers need to find the package's std, hxmc's std and the
// runtime objects (HXMC_RT_DIR always set: hxmc.HaxeMain, run without this
// launcher, passes a build for the hxmc target on to it)
export function toolEnv(extra = {}) {
	const env = { ...process.env, ...extra };
	if (!env.HAXE_STD_PATH) env.HAXE_STD_PATH = stdDir;
	if (!env.HXMC_STD) {
		const std = targetStd();
		if (std) env.HXMC_STD = std;
	}
	if (!env.HXMC_RT_DIR) env.HXMC_RT_DIR = [...rtDirs(), npmCache()].join(path.delimiter);
	// (`haxe --dev`: the dev loop's server, docs/dev.md)
	if (!env.HXMC_DEV_SCRIPT) env.HXMC_DEV_SCRIPT = path.join(bootDir, 'dev.mjs');
	return env;
}

// What a build for the hxmc target (--custom-target hxmc, in the arguments or
// the hxml files they name, as hxmc.HaxeMain sees it) needs: hxmc's std, and
// the runtime objects of each target it names (-D hxmc.target=<target>, else
// this machine; -D hxmc.libc=glibc: Linux's glibc mode; iOS: macOS's). Those
// neither installed nor in the cache are downloaded into it now:
// @hxmc/rt-<target> of this version, checked against the integrity pinned in
// @hxmc/target's package.json ("hxmc": {"rtIntegrity": {<target>: ...}}).
// HXMC_RT_TARBALLS (a directory or a URL with npm pack's file names,
// hxmc-rt-<target>-<version>.tgz) replaces the registry (tests).
export async function runtime(args) {
	const b = { selected: false, targets: new Set(), glibc: false };
	scanArgs(args, process.cwd(), 0, b);
	if (!b.selected) return;
	if (!process.env.HXMC_STD && !targetStd())
		fail(`a build for the hxmc target needs hxmc's std and runtime objects: install @hxmc/cli (npm i -D @hxmc/cli@${version}), or @hxmc/target@${version} beside @hxmc/haxe`);
	if (process.env.HXMC_RT_DIR || process.env.HXMC_RT_OBJ || checkout) return;
	if (b.targets.size === 0 && hostTarget()) b.targets.add(hostTarget());
	const have = rtDirs();
	for (const target of b.targets) {
		const t = target.startsWith('ios-') ? 'macos-arm64' : b.glibc && /^linux-(x86_64|arm64)$/.test(target) ? `${target}-glibc` : target;
		// (wasm32-wasi needs none; an unknown target is the compiler's error)
		if (!RT_TARGETS.includes(t) || have.some(d => fs.existsSync(path.join(d, t, 'rt.o')))) continue;
		const name = `@hxmc/rt-${t}`;
		const { download, tarballFile, tarballUrl } = await import('./registry.mjs');
		const base = process.env.HXMC_RT_TARBALLS;
		const tgt = findPackage('@hxmc/target');
		await download({
			name, integrity: tgt && JSON.parse(fs.readFileSync(path.join(tgt, 'package.json'), 'utf8')).hxmc?.rtIntegrity?.[t],
			dir: rtCache(t), check: path.join(t, 'rt.o'),
			url: base ? (/^[a-z]+:/i.test(base) && !/^[A-Za-z]:/.test(base) ? `${base.replace(/\/+$/, '')}/${tarballFile(name)}` : path.join(base, tarballFile(name))) : tarballUrl(name),
			why: `the runtime objects for ${t} are not installed`, how: `install them (npm i -D ${name}@${version})`, pinner: '@hxmc/target',
		});
		have.push(rtCache(t));
	}
}

// (hxmc.HaxeMain.selectsHxmc's reading of the arguments and hxml files)
function scanArgs(args, cwd, depth, b) {
	for (let i = 0; i < args.length; i++) {
		const a = args[i], next = args[i + 1];
		if ((a === '--custom-target' || a === '-custom-target') && next && (next === 'hxmc' || next.startsWith('hxmc='))) b.selected = true;
		if (a === '--cwd' && next) cwd = path.resolve(cwd, next);
		if ((a === '-D' || a === '--define') && next) {
			const eq = next.indexOf('=');
			const k = (eq < 0 ? next : next.slice(0, eq)).replaceAll('-', '_'), v = eq < 0 ? '' : next.slice(eq + 1);
			if (k === 'hxmc.target' && v) b.targets.add(v);
			if (k === 'hxmc.libc') b.glibc = v === 'glibc';
		}
		if (a.endsWith('.hxml') && depth < 8) {
			let text;
			try {
				text = fs.readFileSync(path.resolve(cwd, a), 'utf8');
			} catch {
				continue;
			}
			const words = [];
			for (let line of text.split('\n')) {
				line = line.trim();
				if (line === '' || line.startsWith('#')) continue;
				const sp = line.indexOf(' ');
				if (sp < 0) words.push(line);
				else words.push(line.slice(0, sp), line.slice(sp + 1).trim());
			}
			scanArgs(words, cwd, depth + 1, b);
		}
	}
}

function fail(text) {
	process.stderr.write(`hxmc: ${text}\n`);
	process.exit(1);
}

// lix's name of this machine (haxeshim's Platform; its NekoInstallation reads it
// from <installation>/platform.txt)
const LIX_PLATFORM = {
	'linux-x86_64': 'linux64', 'linux-arm64': 'linux-arm64', 'macos-x86_64': 'mac64', 'macos-arm64': 'mac-arm',
	'windows-x86_64': 'win64', 'windows-arm64': 'win64',
};

// dist/: an installation lix can use (`lix use haxe ./node_modules/@hxmc/haxe/dist`):
// dist/haxe (this launcher, then the native compiler), dist/std (upstream's
// std: a symbolic link, a junction on Windows, else a copy), dist/platform.txt
export function setupDist() {
	const dist = path.join(pkgDir, 'dist');
	try {
		const std = path.join(dist, 'std');
		if (!fs.existsSync(std)) {
			try {
				// (relative on Unix: the package can move; a junction needs an absolute target)
				if (process.platform === 'win32') fs.symlinkSync(stdDir, std, 'junction');
				else fs.symlinkSync(path.relative(dist, stdDir), std, 'dir');
			} catch {
				fs.cpSync(stdDir, std, { recursive: true });
			}
		}
		const platform = path.join(dist, 'platform.txt');
		const host = hostTarget();
		if (host && !fs.existsSync(platform)) fs.writeFileSync(platform, LIX_PLATFORM[host]);
	} catch {
		// a read-only package: lix cannot use dist/ then
	}
}

// a notice on an interactive terminal only: editors run `haxe --wait stdio`
// (length-prefixed answers on stderr) and parse `haxe --version`
export function notice(text) {
	if (process.stderr.isTTY && !process.env.HXMC_QUIET) process.stderr.write(text);
}

// the native compiler of the platform package (@hxmc/haxe-<os>-<cpu>, an optional
// dependency), unless HXMC_PLATFORM_PACKAGE=0
export function platformBinary() {
	const p = PLATFORMS[hostTarget()];
	if (!p || process.env.HXMC_PLATFORM_PACKAGE === '0') return null;
	try {
		const bin = path.join(path.dirname(require.resolve(`${p.pkg}/package.json`)), p.exe);
		return fs.existsSync(bin) ? bin : null;
	} catch {
		return null;
	}
}

// whether a native compiler starts here (not on a noexec file system, in a
// sandbox without processes such as WebContainers, under an emulator without
// that architecture, ...)
export function nativeRuns(bin) {
	try {
		const r = spawnSync(bin, ['--version'], { stdio: 'ignore', timeout: 60000, windowsHide: true });
		return !r.error && r.status === 0;
	} catch {
		return false;
	}
}

// @hxmc/source at this version, when it is installed (its package directory)
export function sourcePackage() {
	try {
		const p = require.resolve('@hxmc/source/package.json');
		return JSON.parse(fs.readFileSync(p, 'utf8')).version === version ? path.dirname(p) : null;
	} catch {
		return null;
	}
}

// where hxmc-rebuild writes the compiler it builds: <dir>/haxe[.exe] and
// <dir>/hxmc-std (hxmc's std merged from @hxmc/source's hxmc/std)
export function rebuildDir() {
	return path.join(npmCache(), 'rebuild', hostTarget() ?? 'none');
}

// the compiler hxmc-rebuild built, while @hxmc/source is installed: {bin, env}
export function rebuilt() {
	if (!hostTarget() || !sourcePackage()) return null;
	const dir = rebuildDir();
	const bin = path.join(dir, exeName);
	if (!fs.existsSync(bin)) return null;
	const std = path.join(dir, 'hxmc-std');
	return { bin, env: fs.existsSync(std) ? { HXMC_STD: std } : {} };
}

export async function main(args) {
	const host = hostTarget();
	setupDist();
	await runtime(args);
	if (host && process.env.HXMC_NATIVE !== '0') {
		const r = rebuilt();
		const native = r?.bin ?? platformBinary();
		if (native) {
			const p = spawnSync(native, args, { stdio: 'inherit', env: toolEnv(r?.env) });
			// (an error: it did not start; it ran otherwise, whatever its exit)
			if (!p.error) {
				if (!r) install(native);
				process.exit(p.status ?? (p.signal ? 1 : 0));
			}
			notice(`hxmc: the native compiler cannot run here (${p.error.code ?? p.error.message}): using the WebAssembly one\n`);
		}
	}
	// no native compiler that runs here: the WebAssembly one
	const { wasmPackage } = await import('./wasm.mjs');
	process.exitCode = await wasm(await wasmPackage(), args, host);
}

// the WebAssembly compiler (@hxmc/haxe-wasm's haxe.wasm under its wasi.mjs):
// executables it writes are marked here (WASI has no chmod)
export async function wasm(dir, args, host, env = {}) {
	const { runWasm } = await import(pathToFileURL(path.join(dir, 'wasi.mjs')).href);
	const list = path.join(os.tmpdir(), `hxmc-${process.pid}.exe-list`);
	const extra = { ...env, HXMC_EXE_LIST: list };
	if (host) extra.HXMC_HOST = host;
	try {
		return runWasm(path.join(dir, 'haxe.wasm'), args, toolEnv(extra));
	} finally {
		if (fs.existsSync(list)) {
			// (Windows has no executable bit)
			if (process.platform !== 'win32')
				for (const f of fs.readFileSync(list, 'utf8').split('\n')) if (f) try { fs.chmodSync(f, 0o755); } catch {}
			fs.rmSync(list, { force: true });
		}
	}
}

// The native compiler replaces the launcher where npm's link and lix point:
// on Unix hxmc/bootstrap/haxe and dist/haxe (renames in those directories:
// the links keep pointing at them); on Windows npm's haxe.cmd keeps running
// this launcher, and the native compiler is copied to dist/haxe.exe for lix.
export function install(native) {
	if (process.env.HXMC_INSTALL === '0' || checkout) return;
	const targets = process.platform === 'win32' ? [path.join(pkgDir, 'dist', 'haxe.exe')] : [path.join(bootDir, 'haxe'), path.join(pkgDir, 'dist', 'haxe')];
	for (const target of targets) {
		// (already there: the same size, and not older than the native compiler)
		if (fs.existsSync(target)) {
			const t = fs.statSync(target), n = fs.statSync(native);
			if (t.size === n.size && t.mtimeMs >= n.mtimeMs) continue;
		}
		replace(target, tmp => fs.copyFileSync(native, tmp));
	}
}

// The launcher back in place of the native compiler (hxmc-rebuild: the
// compiler it built runs through the launcher, which gives it its std)
const LAUNCHERS = {
	'hxmc/bootstrap/haxe': "import { main } from './launcher.mjs';",
	'dist/haxe': "import { main } from '../hxmc/bootstrap/launcher.mjs';",
};
export function restoreLaunchers() {
	if (process.platform === 'win32' || checkout) return;
	for (const [rel, imp] of Object.entries(LAUNCHERS)) {
		const target = path.join(pkgDir, rel);
		if (fs.existsSync(target) && fs.readFileSync(target).subarray(0, 2).toString() === '#!') continue;
		replace(target, tmp => fs.writeFileSync(tmp, `#!/usr/bin/env node\n// hxmc's launcher (hxmc/bootstrap/launcher.mjs)\n${imp}\nmain(process.argv.slice(2));\n`));
	}
}

function replace(target, write) {
	const tmp = `${target}.${process.pid}.new`;
	try {
		write(tmp);
		fs.chmodSync(tmp, 0o755);
		fs.renameSync(tmp, target);
	} catch {
		fs.rmSync(tmp, { force: true }); // a read-only package: stays as it is
	}
}

export function lockHeld(lock) {
	try {
		const pid = Number(fs.readFileSync(lock, 'utf8'));
		process.kill(pid, 0); // throws when that process is gone
		return true;
	} catch (e) {
		return e.code === 'EPERM';
	}
}
