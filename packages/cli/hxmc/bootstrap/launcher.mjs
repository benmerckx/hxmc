// The `haxe` and `hxmc` commands of the npm package @hxmc/cli (docs/using.md):
// runs, in this order,
// - the compiler `hxmc-rebuild` built from @hxmc/source (in the cache), while
//   @hxmc/source is installed (packages/source: not published);
// - the platform package's native compiler (@hxmc/<os>-<cpu>, an optional
//   dependency);
// with neither, it says which machines it runs on and exits non-zero.
// It gives the compiler the std (haxe/upstream/std), hxmc's std
// (hxmc/bootstrap/hxmc-std: HXMC_STD) and the directories of the runtime
// objects (HXMC_RT_DIR: rtDirs()).
// On Unix the native compiler then replaces hxmc/bootstrap/haxe and dist/haxe,
// so npm's link and lix run it without node (builds for the hxmc target come
// back here: hxmc.HaxeMain runs haxe.mjs).
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { PLATFORMS } from './platforms.mjs';

export const bootDir = path.dirname(fileURLToPath(import.meta.url));
export const pkgDir = path.dirname(path.dirname(bootDir));
export const pkgJson = JSON.parse(fs.readFileSync(path.join(pkgDir, 'package.json'), 'utf8'));
export const version = pkgJson.version;
// (the repository's packages/cli, where these files are sources)
const repo = path.join(pkgDir, '..', '..');
const checkout = fs.existsSync(path.join(repo, 'hxmc', 'bootstrap', 'stage0.wasm.br'));
// upstream's std: haxe/upstream/std of the package (of the repository in a checkout)
const stdDir = path.join(checkout ? repo : pkgDir, 'haxe', 'upstream', 'std');
const require = createRequire(import.meta.url);

// hxmc's name of this machine (null: no platform package)
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
// (rebuild/<target>/: hxmc-rebuild's compiler)
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
// the package's hxmc/bootstrap/hxmc-std (`make npm` writes it there in a
// checkout, else bin/hxmc/std, `make std`)
function hxmcStd() {
	const own = path.join(bootDir, 'hxmc-std');
	if (!checkout || fs.existsSync(own)) return own;
	return path.join(repo, 'bin', 'hxmc', 'std');
}

// the directories of the runtime objects (<dir>/<target>/rt.o, ssl.o, uv.o),
// in this order: HXMC_RT_DIR's (added to the search, as the compiler's own
// search does: hxmc/src/hxmc/Options.hx, rtSearch); this machine's platform
// package; the other platform packages of this version installed (cross
// builds: `npm i -D --force @hxmc/win32-x64`). In a checkout: bin/hxmc/rt
// (`make rt`) after HXMC_RT_DIR's.
export function rtDirs() {
	const own = (process.env.HXMC_RT_DIR ?? '').split(path.delimiter).filter(d => d);
	if (checkout) return [...own, path.join(repo, 'bin', 'hxmc', 'rt')];
	const host = PLATFORMS[hostTarget()];
	const dirs = [];
	for (const p of [...(host ? [host] : []), ...Object.values(PLATFORMS).filter(p => p !== host)]) {
		const d = findPackage(p.pkg);
		if (d && p.rt.some(t => fs.existsSync(path.join(d, t, 'rt.o')))) dirs.push(d);
	}
	return [...own, ...dirs];
}

// what the compilers need to find the package's std, hxmc's std and the
// runtime objects (HXMC_RT_DIR always set: hxmc.HaxeMain, run without this
// launcher in its place, passes a build for the hxmc target on to it; the
// platform package's compiler, run directly, also finds them beside itself)
export function toolEnv(extra = {}) {
	const env = { ...process.env, ...extra };
	if (!env.HAXE_STD_PATH) env.HAXE_STD_PATH = stdDir;
	if (!env.HXMC_STD) env.HXMC_STD = hxmcStd();
	env.HXMC_RT_DIR = [...rtDirs(), npmCache()].join(path.delimiter);
	// (`haxe --dev`: the dev loop's server, docs/dev.md)
	if (!env.HXMC_DEV_SCRIPT) env.HXMC_DEV_SCRIPT = path.join(bootDir, 'dev.mjs');
	return env;
}

// lix's name of this machine (haxeshim's Platform; its NekoInstallation reads it
// from <installation>/platform.txt)
const LIX_PLATFORM = {
	'linux-x86_64': 'linux64', 'linux-arm64': 'linux-arm64', 'macos-x86_64': 'mac64', 'macos-arm64': 'mac-arm',
	'windows-x86_64': 'win64', 'windows-arm64': 'win64',
};

// dist/: an installation lix can use (`lix use haxe ./node_modules/@hxmc/cli/dist`):
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

// the native compiler of the platform package (@hxmc/<os>-<cpu>, an optional
// dependency)
export function platformBinary() {
	const p = PLATFORMS[hostTarget()];
	if (!p) return null;
	try {
		const bin = path.join(path.dirname(require.resolve(`${p.pkg}/package.json`)), p.exe);
		return fs.existsSync(bin) ? bin : null;
	} catch {
		return null;
	}
}

// whether a native compiler starts here (not on a noexec file system, in a
// sandbox without processes, under an emulator without that architecture, ...)
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
	setupDist();
	const r = rebuilt();
	const native = r?.bin ?? platformBinary();
	if (!native) {
		const hosts = Object.values(PLATFORMS).map(p => `${p.os}-${p.cpu}`).join(', ');
		const p = PLATFORMS[hostTarget()];
		fail(p
			? `${p.pkg}, the compiler for this machine, is not installed (an install without optional dependencies?): npm i -D @hxmc/cli@${version} ${p.pkg}@${version}`
			: `no compiler for ${process.platform}-${process.arch}: @hxmc/cli runs on ${hosts}`);
	}
	const p = spawnSync(native, args, { stdio: 'inherit', env: toolEnv(r?.env) });
	// (an error: it did not start; it ran otherwise, whatever its exit)
	if (p.error) fail(`the native compiler ${native} cannot run here (${p.error.code ?? p.error.message})`);
	if (!r) install(native);
	process.exit(p.status ?? (p.signal ? 1 : 0));
}

function fail(text) {
	process.stderr.write(`hxmc: ${text}\n`);
	process.exit(1);
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
