// Shared dev-loop helpers: hxml expansion, resident compilation server, source watch.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import process from 'node:process';

export function words(list, depth = 0) {
	const out = [];
	for (const a of list) {
		if (a.endsWith('.hxml') && depth < 8 && fs.existsSync(a)) {
			const ws = [];
			for (let line of fs.readFileSync(a, 'utf8').split('\n')) {
				line = line.trim();
				if (line === '' || line.startsWith('#')) continue;
				const sp = line.indexOf(' ');
				if (sp < 0) ws.push(line);
				else ws.push(line.slice(0, sp), line.slice(sp + 1).trim());
			}
			out.push(...words(ws, depth + 1));
		} else out.push(a);
	}
	return out;
}

export function defineName(val) {
	const eq = val.indexOf('=');
	return eq < 0 ? val : val.slice(0, eq);
}

export function defineTruthy(all, name) {
	for (let i = 0; i < all.length; i++) {
		if ((all[i] === '-D' || all[i] === '--define') && all[i + 1]) {
			const n = defineName(all[i + 1]);
			if (n !== name) continue;
			const eq = all[i + 1].indexOf('=');
			const v = eq < 0 ? '1' : all[i + 1].slice(eq + 1);
			return v !== '0' && v !== 'false';
		}
	}
	return false;
}

export function hxmcOutput(all) {
	for (let i = 0; i < all.length; i++) {
		if ((all[i] === '--custom-target' || all[i] === '-custom-target') && all[i + 1]?.startsWith('hxmc='))
			return all[i + 1].slice(5);
	}
	return null;
}

export function jsEntry(all) {
	for (let i = 0; i < all.length; i++) {
		if ((all[i] === '-js' || all[i] === '--js') && all[i + 1]) return all[i + 1];
	}
	return null;
}

export function parsePathsFromAll(all, cwd) {
	const classPaths = [];
	const libs = [];
	for (let i = 0; i < all.length; i++) {
		const a = all[i];
		if (a === '-cp' || a === '-p' || a === '--class-path') classPaths.push(path.resolve(cwd, all[i + 1]));
		if (a === '-lib' || a === '-L' || a === '--library') libs.push(all[i + 1].split(':')[0]);
	}
	return { classPaths, libs };
}

export function resolveHxmcStd(compiler) {
	const compilerDir = path.dirname(compiler);
	return [process.env.HXMC_STD, path.join(compilerDir, 'std')].find((d) => d && fs.existsSync(d));
}

export function hxbCacheArgs() {
	return process.env.HXMC_DEV_HXB_CACHE === '1' ? [] : ['-D', 'disable-hxb-cache'];
}

export function hasDceNo(all) {
	for (let i = 0; i < all.length; i++) {
		if ((all[i] === '-dce' || all[i] === '--dce') && all[i + 1] === 'no') return true;
		if ((all[i] === '-D' || all[i] === '--define') && defineName(all[i + 1]) === 'dce' && all[i + 1].includes('no')) return true;
	}
	return false;
}

export function esmHotBuildExtra(all) {
	const extra = ['-D', 'esm.hot', ...hxbCacheArgs()];
	if (!hasDceNo(all)) extra.push('-dce', 'no');
	return extra;
}

export function packageOf(dir) {
	for (let d = dir; ; d = path.dirname(d)) {
		const p = path.join(d, 'package.json');
		if (fs.existsSync(p)) {
			try {
				const j = JSON.parse(fs.readFileSync(p, 'utf8'));
				if (j.haxe) return { dir: d, json: j };
			} catch {}
		}
		if (path.dirname(d) === d) return null;
	}
}

export function nodeLibs(cwd) {
	const found = new Map();
	for (let d = cwd; ; d = path.dirname(d)) {
		const nm = path.join(d, 'node_modules');
		if (fs.existsSync(nm)) {
			const dirs = [];
			for (const n of fs.readdirSync(nm)) {
				if (n.startsWith('@')) for (const m of fs.readdirSync(path.join(nm, n))) dirs.push(path.join(nm, n, m));
				else dirs.push(path.join(nm, n));
			}
			for (const p of dirs) {
				try {
					const j = JSON.parse(fs.readFileSync(path.join(p, 'package.json'), 'utf8'));
					if (j.haxe?.name && !found.has(j.haxe.name)) found.set(j.haxe.name, { dir: fs.realpathSync(p), json: j });
				} catch {}
			}
		}
		if (path.dirname(d) === d) return found;
	}
}

export function collectWatchClassPaths(cwd, classPaths, libs) {
	const paths = [...classPaths];
	const packages = new Map();
	for (const cp of classPaths) {
		const p = packageOf(cp);
		if (p) packages.set(p.dir, p);
	}
	if (libs.length > 0) {
		const known = nodeLibs(cwd);
		const add = (name) => {
			const p = known.get(name);
			if (!p || packages.has(p.dir)) return;
			packages.set(p.dir, p);
			paths.push(path.join(p.dir, p.json.haxe.classPath ?? ''));
			for (const d of p.json.haxe.dependencies ?? []) add(d);
		};
		libs.forEach(add);
	}
	return [...new Set(paths.filter((d) => fs.existsSync(d)))];
}

/**
 * Resident compilation server (--server-connect).
 * @param {string} compiler
 * @param {{ cwd: string, progress?: boolean, onOutput?: (chunk: string) => void, onFatalExit?: (code: number | null, tail: string) => void }} opts
 */
export async function createCompilationServer(compiler, opts) {
	const serverEnv = {
		...process.env,
		RT_OLD_MB: process.env.RT_OLD_MB ?? '4096',
		RT_MINOR_KB: process.env.RT_MINOR_KB ?? '32768',
		...(opts.progress ? { HXMC_DEV_PROGRESS: '1' } : {}),
	};
	let link = null;
	let linked = null;
	const linkServer = net.createServer((sock) => {
		if (link) return sock.destroy();
		link = sock;
		let buf = Buffer.alloc(0);
		sock.on('data', (d) => {
			buf = Buffer.concat([buf, d]);
			while (buf.length >= 4 && buf.length >= 4 + buf.readInt32LE(0)) {
				const n = buf.readInt32LE(0);
				const answer = buf.subarray(4, 4 + n).toString('utf8');
				buf = buf.subarray(4 + n);
				const r = requests.shift();
				r.resolve(answer);
				if (requests.length > 0) sendRequest(requests[0]);
			}
		});
		sock.on('error', () => {});
		linked();
	});
	const linkedPromise = new Promise((r) => (linked = r));
	await new Promise((r) => linkServer.listen(0, '127.0.0.1', r));
	const server = spawn(compiler, ['--server-connect', '127.0.0.1:' + linkServer.address().port], { env: serverEnv, stdio: ['ignore', 'pipe', 'pipe'] });
	let serverOutput = '';
	const output = (d) => {
		const chunk = String(d);
		serverOutput = (serverOutput + chunk).slice(-65536);
		opts.onOutput?.(chunk);
	};
	server.stdout.on('data', output);
	server.stderr.on('data', output);
	server.on('exit', (code) => {
		opts.onFatalExit?.(code, serverOutput.slice(-2000));
	});
	const requests = [];
	function sendRequest(r) {
		const body = Buffer.from(['--cwd', opts.cwd, ...r.words].join('\n'), 'utf8');
		const head = Buffer.alloc(4);
		head.writeInt32LE(body.length);
		link.write(Buffer.concat([head, body]));
	}
	async function request(words) {
		await linkedPromise;
		const answer = await new Promise((resolve) => {
			requests.push({ words, resolve });
			if (requests.length === 1) sendRequest(requests[0]);
		});
		let ok = true;
		const messages = [];
		for (const line of answer.split('\n')) {
			if (line.startsWith('\x01')) process.stdout.write(line.slice(1).replaceAll('\x01', '\n'));
			else if (line.startsWith('\x02')) ok = false;
			else if (line !== '') messages.push(line);
		}
		return { ok, messages: messages.join('\n') };
	}
	return {
		request,
		server,
		kill() {
			server.removeAllListeners('exit');
			server.kill();
		},
	};
}

export function setupSourceWatch({ classPaths, hxmls, skip, onChange }) {
	const changedFiles = new Set();
	let pending = null;
	let firstSeen = null;
	const changed = (file) => {
		if (!file) return;
		const base = path.basename(file);
		if (base.startsWith('.') || base.endsWith('~') || base.endsWith('.swp') || base.endsWith('.tmp') || base.startsWith('#')) return;
		const full = path.resolve(file);
		if (skip?.(full)) return;
		changedFiles.add(full);
		if (firstSeen === null) firstSeen = performance.now();
		clearTimeout(pending);
		pending = setTimeout(() => {
			const seen = firstSeen;
			firstSeen = null;
			const files = [...changedFiles];
			changedFiles.clear();
			onChange(files, seen);
		}, 10);
	};
	const watched = new Set();
	for (const d of classPaths) {
		if ([...watched].some((w) => d.startsWith(w + path.sep))) continue;
		watched.add(d);
		fs.watch(d, { recursive: true }, (_, f) => f && changed(path.join(d, f)));
	}
	for (const h of hxmls) fs.watch(h, () => changed(h));
	return { watched, changed, takeChanged: () => { const f = [...changedFiles]; changedFiles.clear(); return f; } };
}

export async function invalidateHx(server, files) {
	for (const file of files)
		if (file.endsWith('.hx')) await server.request(['--display', JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'server/invalidate', params: { file } })]);
}