// hxmc's runtime objects (rt.o, ssl.o, uv.o for the six native targets and
// Linux's dynamic glibc mode) are built by zig (the C library's members,
// mbedtls and libuv: hxmc/deps/deps.sh,
// mkrt.sh), which a source-only bootstrap cannot do. They are keyed by a hash
// of their inputs (every file of hxmc/deps, the zig version it pins) and
// published as the assets of the GitHub release `rt-<hash>`:
//   node hxmc/bootstrap/rt.mjs hash                  the hash
//   node hxmc/bootstrap/rt.mjs fetch <dir>           <dir>/<target>/{rt,ssl,uv}.o and
//                                                    <dir>/LICENSE.{mbedtls,libuv}
//                                                    (exit 2: no such release, an
//                                                    HTTP 404; exit 3: the network
//                                                    failed, after retries)
//   node hxmc/bootstrap/rt.mjs pack <dir> <out dir>  the assets of <dir>, gzipped
// <dir>/HASH records what <dir> holds. HXMC_RT_REPO names the repository
// (default benmerckx/hxmc), HXMC_RT_URL the server (default
// https://github.com: <url>/<repo>/releases/download/rt-<hash>/<asset>).
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';

const root = path.dirname(path.dirname(path.dirname(fileURLToPath(import.meta.url))));
// (the six targets, Linux in the dynamic glibc mode: -D hxmc.libc=glibc, and Android)
export const TARGETS = ['linux-x86_64', 'linux-arm64', 'windows-x86_64', 'windows-arm64', 'macos-x86_64', 'macos-arm64', 'linux-x86_64-glibc', 'linux-arm64-glibc', 'android-arm64', 'android-x86_64'];
const OBJECTS = ['rt.o', 'ssl.o', 'uv.o'];
const LICENSES = ['LICENSE.mbedtls', 'LICENSE.libuv'];

function files(dir, rel = '') {
	const out = [];
	for (const n of fs.readdirSync(path.join(dir, rel)).sort()) {
		const r = rel ? `${rel}/${n}` : n;
		if (fs.statSync(path.join(dir, r)).isDirectory()) out.push(...files(dir, r));
		else out.push(r);
	}
	return out;
}

export function hash() {
	const h = crypto.createHash('sha256');
	const c = path.join(root, 'hxmc', 'deps');
	for (const f of files(c)) {
		h.update(`${f}\0`);
		// (line ends as committed: a Windows checkout may have CRLF)
		h.update(fs.readFileSync(path.join(c, f), 'utf8').replace(/\r\n/g, '\n'));
		h.update('\0');
	}
	h.update(TARGETS.join(','));
	return h.digest('hex').slice(0, 16);
}

function assets() {
	return [...TARGETS.flatMap(t => OBJECTS.map(o => [`${t}/${o}`, `${t}-${o}.gz`])), ...LICENSES.map(l => [l, `${l}.gz`])];
}

// exit codes of fetch
const MISSING = 2, NETWORK = 3;
// per asset: attempts, the pause before each retry (ms: a 504 of GitHub's
// release downloads can last tens of seconds); per attempt: the
// time to connect, to stall (below 1 KiB/s) and in all (s)
const ATTEMPTS = 5, BACKOFF = [5000, 15000, 30000, 60000];
const CONNECT_TIMEOUT = 30, STALL_TIME = 30, MAX_TIME = 300;

// one attempt: {data} | {missing: true} (HTTP 404: no such release or asset)
// | {error} (no response, a reset, a timeout, any other status)
function attempt(url) {
	// curl follows the environment's proxy settings, node's fetch does not
	const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'hxmc-rt-'));
	const out = path.join(tmp, 'asset');
	try {
		let code, err = '';
		try {
			code = execFileSync('curl', ['-sSL', '--connect-timeout', `${CONNECT_TIMEOUT}`, '--speed-limit', '1024', '--speed-time', `${STALL_TIME}`,
				'--max-time', `${MAX_TIME}`, '-o', out, '-w', '%{http_code}', url], { stdio: ['ignore', 'pipe', 'pipe'] }).toString().trim();
		} catch (e) {
			if (e.code === 'ENOENT') return null;
			code = (e.stdout || '').toString().trim();
			err = (e.stderr || '').toString().trim() || `curl exited with ${e.status}`;
		}
		if (code === '404') return { missing: true };
		if (!err && /^2\d\d$/.test(code)) return { data: fs.readFileSync(out) };
		return { error: err || `HTTP ${code}` };
	} finally {
		fs.rmSync(tmp, { recursive: true, force: true });
	}
}

async function attemptFetch(url) {
	try {
		const r = await fetch(url, { signal: AbortSignal.timeout(MAX_TIME * 1000) });
		if (r.status === 404) return { missing: true };
		if (!r.ok) return { error: `HTTP ${r.status}` };
		return { data: Buffer.from(await r.arrayBuffer()) };
	} catch (e) {
		return { error: (e.cause && (e.cause.code || e.cause.message)) || e.name || e.message };
	}
}

// with retries of what failed transiently; a 404 is final
async function download(url, asset) {
	let r;
	for (let i = 0; i < ATTEMPTS; i++) {
		if (i > 0) {
			console.error(`rt: ${asset}: ${r.error}; retrying in ${BACKOFF[i - 1] / 1000}s (${i + 1}/${ATTEMPTS})`);
			await new Promise(res => setTimeout(res, BACKOFF[i - 1]));
		}
		r = attempt(url) || await attemptFetch(url);
		if (!r.error) return r;
	}
	return r;
}

async function fetchAll(dir) {
	const h = hash();
	const stamp = path.join(dir, 'HASH');
	if (fs.existsSync(stamp) && fs.readFileSync(stamp, 'utf8').trim() === h && assets().every(([f]) => fs.existsSync(path.join(dir, f)))) {
		console.log(`rt: ${dir} holds rt-${h}`);
		return 0;
	}
	const repo = process.env.HXMC_RT_REPO || 'benmerckx/hxmc';
	const server = (process.env.HXMC_RT_URL || 'https://github.com').replace(/\/+$/, '');
	const base = `${server}/${repo}/releases/download/rt-${h}/`;
	const got = [];
	for (const [file, asset] of assets()) {
		const r = await download(base + asset, asset);
		if (r.missing) {
			console.error(`rt: no release rt-${h} in ${repo} (${asset}: HTTP 404): build them with zig (make rt-build)`);
			return MISSING;
		}
		if (r.error) {
			console.error(`rt: could not download rt-${h} from ${repo} (${asset}: ${r.error}, ${ATTEMPTS} attempts): a network failure, not a missing release; try again`);
			return NETWORK;
		}
		got.push([file, zlib.gunzipSync(r.data)]);
	}
	for (const [file, data] of got) {
		fs.mkdirSync(path.dirname(path.join(dir, file)), { recursive: true });
		fs.writeFileSync(path.join(dir, file), data);
	}
	fs.writeFileSync(stamp, h + '\n');
	console.log(`rt: downloaded rt-${h} into ${dir}`);
	return 0;
}

function pack(dir, out) {
	fs.mkdirSync(out, { recursive: true });
	for (const [file, asset] of assets())
		fs.writeFileSync(path.join(out, asset), zlib.gzipSync(fs.readFileSync(path.join(dir, file)), { level: 9 }));
	console.log(`rt: ${assets().length} assets of rt-${hash()} in ${out}`);
	return 0;
}

const [cmd, ...args] = process.argv.slice(2);
if (cmd === 'hash') console.log(hash());
else if (cmd === 'fetch' && args.length === 1) process.exitCode = await fetchAll(args[0]);
else if (cmd === 'pack' && args.length === 2) process.exitCode = pack(args[0], args[1]);
else {
	console.error('usage: node hxmc/bootstrap/rt.mjs hash | fetch <dir> | pack <dir> <out dir>');
	process.exitCode = 1;
}
