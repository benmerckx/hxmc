// Packages the launcher downloads from the npm registry on first use, into
// the cache (<cache>/npm/<version>/): @hxmc/haxe-wasm (wasm.mjs) and the
// runtime objects of a target, @hxmc/rt-<target> (launcher.mjs, runtime()). The tarball
// of the same version, from npm_config_registry, else the registry of an
// .npmrc, else registry.npmjs.org, checked against the integrity hash
// packages/pack.mjs pinned when it packed the package that downloads it
// (@hxmc/haxe's "hxmc": {"wasmIntegrity"}, @hxmc/target's "hxmc":
// {"rtIntegrity"}), then unpacked next to its place and renamed into it.
import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import zlib from 'node:zlib';
import { notice, version } from './launcher.mjs';

export function fail(text) {
	process.stderr.write(`hxmc: ${text}\n`);
	process.exit(1);
}

// npm's registry for @hxmc: the environment (npm and npx pass their
// configuration on as npm_config_*), else the first .npmrc that names one (the
// project's and its parents', the user's), else npm's default
export function registry() {
	const env = process.env['npm_config_@hxmc:registry'] || process.env.npm_config_registry;
	if (env) return env;
	const rcs = [];
	for (let d = process.cwd(); ; d = path.dirname(d)) {
		rcs.push(path.join(d, '.npmrc'));
		if (path.dirname(d) === d) break;
	}
	rcs.push(process.env.npm_config_userconfig || path.join(os.homedir(), '.npmrc'));
	for (const rc of rcs) {
		let text;
		try {
			text = fs.readFileSync(rc, 'utf8');
		} catch {
			continue;
		}
		const conf = {};
		for (const line of text.split(/\r?\n/)) {
			const m = /^\s*([^#;=\s][^=]*?)\s*=\s*(.*?)\s*$/.exec(line);
			if (m) conf[m[1]] = m[2].replace(/^"(.*)"$/, '$1').replace(/\$\{([^}]+)\}/g, (_, v) => process.env[v] ?? '');
		}
		const r = conf['@hxmc:registry'] || conf.registry;
		if (r) return r;
	}
	return 'https://registry.npmjs.org/';
}

async function fetchBytes(url) {
	if (!/^https?:/.test(url)) return fs.readFileSync(url.startsWith('file:') ? new URL(url) : url);
	let first;
	try {
		const r = await fetch(url);
		if (!r.ok) throw new Error(`HTTP ${r.status}`);
		return Buffer.from(await r.arrayBuffer());
	} catch (e) {
		first = e;
	}
	// (node's fetch does not follow the environment's proxy settings, curl does)
	try {
		return execFileSync('curl', ['-sSfL', '--retry', '2', url], { maxBuffer: 1 << 30, stdio: ['ignore', 'pipe', 'pipe'] });
	} catch {}
	throw first.cause ?? first;
}

// the tarball's URL on the registry (npm's: <registry>/@hxmc/<name>/-/<name>-<version>.tgz)
export function tarballUrl(name) {
	const base = name.split('/').pop();
	return `${registry().replace(/\/+$/, '')}/${name}/-/${base}-${version}.tgz`;
}

// npm pack's file name of a package's tarball (@hxmc/rt-x -> hxmc-rt-x-<version>.tgz)
export function tarballFile(name) {
	return `${name.replace('@', '').replace('/', '-')}-${version}.tgz`;
}

// name@version into dir (its files without npm's package/ prefix), when the
// downloaded tarball has the integrity pinned for it and contains check:
//   url: where from (a URL, a path or a file: URL); why: what needs it (the
//   messages); how: what else the user can do; pinner: the package that pins it
export async function download({ name, integrity, dir, check, url, why, how, pinner }) {
	if (!integrity) fail(`${why}, and this ${pinner} pins no ${name} to download: ${how}`);
	notice(`hxmc: ${why}: downloading ${name}@${version} (${url})\n`);
	let tgz;
	try {
		tgz = await fetchBytes(url);
	} catch (e) {
		fail(`${why}, and ${name}@${version} could not be downloaded from ${url} (${/^HTTP /.test(e.message) ? e.message : `${e.code ?? e.message}; offline?`}): ${how}, or connect to the network`);
	}
	const [algo, want] = integrity.split('-', 2);
	if (crypto.createHash(algo).update(tgz).digest('base64') !== want) fail(`${url} is not the ${name}@${version} this ${pinner} pins (integrity mismatch)`);
	// extracted next to its place, then renamed into place (a concurrent download wins)
	fs.mkdirSync(path.dirname(dir), { recursive: true });
	const tmp = fs.mkdtempSync(`${dir}.tmp-`);
	try {
		untar(zlib.gunzipSync(tgz), tmp);
		if (!fs.existsSync(path.join(tmp, check))) throw new Error(`no ${check} in the tarball`);
		try {
			fs.renameSync(tmp, dir);
		} catch (e) {
			if (!fs.existsSync(path.join(dir, check))) throw e;
		}
		notice(`hxmc: ${name}@${version} is in ${dir}\n`);
	} catch (e) {
		fail(`unpacking ${name}@${version} into ${dir} failed: ${e.message}`);
	} finally {
		fs.rmSync(tmp, { recursive: true, force: true });
	}
}

// the regular files of an npm tarball (ustar, with pax and GNU long names),
// without its package/ prefix
function untar(buf, out) {
	let longName = null;
	for (let at = 0; at + 512 <= buf.length;) {
		const h = buf.subarray(at, at + 512);
		if (h.every(b => b === 0)) break;
		const str = (o, n) => h.subarray(o, o + n).toString('utf8').replace(/\0.*$/s, '');
		const size = parseInt(str(124, 12).trim() || '0', 8);
		const type = String.fromCharCode(h[156] || 48);
		const data = buf.subarray(at + 512, at + 512 + size);
		at += 512 + Math.ceil(size / 512) * 512;
		if (type === 'x') {
			const m = /\d+ path=([^\n]*)\n/.exec(data.toString('utf8'));
			if (m) longName = m[1];
			continue;
		}
		if (type === 'L') {
			longName = data.toString('utf8').replace(/\0.*$/s, '');
			continue;
		}
		if (type === 'g') continue;
		const prefix = str(345, 155);
		let name = longName ?? (prefix ? `${prefix}/${str(0, 100)}` : str(0, 100));
		longName = null;
		if (type !== '0' && type !== '7') continue;
		name = name.replace(/^[^/]*\//, ''); // package/
		if (!name || name.split(/[\\/]/).some(s => s === '..' || s === '') || path.isAbsolute(name)) throw new Error(`bad entry ${name}`);
		const file = path.join(out, name);
		fs.mkdirSync(path.dirname(file), { recursive: true });
		fs.writeFileSync(file, data);
	}
}
