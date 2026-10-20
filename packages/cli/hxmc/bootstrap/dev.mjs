// `hxmc dev` and `haxe --dev` (docs/dev.md): the dev loop. Save a file, see
// the change, keep where you were.
//
//   node dev.mjs <compiler> [--port <n>] [--host <address>] [--quiet] <haxe arguments: build.hxml, ...>
//
// The compiler (hxmc's native one: the npm package's haxe, or the tool) stays
// resident as a compilation server (`--server-connect`: typed modules, lowered bodies
// and compiled objects kept in memory); each build is a request to it, with
// -D hxmc.dev added (fast refresh's primitives, hxmc.dev.Hot, and the dev
// client in hxmc.os.App). The class paths and libraries the build names are
// watched; a change builds again, and a build that compiles reloads the
// program, which is a fresh start of the new build with the old one's
// state carried over by key (a snapshot). A build with errors changes
// nothing: the last good build keeps running, the errors show here and, in
// the browser, in an overlay.
//
// The output (--custom-target hxmc=<out>) says how the program runs:
// - <out>.wasm: in the browser. This serves a page at http://localhost:<port>/
//   running it with the browser modules of the packages it uses (each
//   package's imports.mjs, @hxmc/os's browser.mjs), and talks to it over a
//   WebSocket (/__hxmc/ws). A reload swaps the new build in, in the same
//   page: the running module snapshots and disposes (what it registered with
//   the page dropped, its GPU objects released), and the new one runs from
//   the snapshot against the same canvas and GPU device (WebGPU, or the
//   canvas's WebGL2 context: ?gfx=webgl2); the page never loads again.
// - anything else: a native program, started here with HXMC_DEV=<host:port>
//   (this server's socket for it) and HXMC_DEV_SNAPSHOT=<file>. On Linux in
//   the glibc mode it runs in a dev host (hxmc.dev.DevHost: one process for
//   the session, each build a shared library it loads; the window and the GL
//   context kept): a reload names the new library, the build writes its
//   snapshot, disposes and returns, the host runs the new one. Otherwise a
//   reload: it writes its snapshot to that file and exits; the new build
//   starts with it.
//
// The protocol, JSON lines (natively) or WebSocket text messages (browser):
//   to the program:   {"type":"reload"[,"snapshot":<file>]}   a new build is ready:
//                       snapshot, dispose, hand over (natively: write the file, exit)
//                     {"type":"error","message":<text>}   the build failed (overlay)
//                     {"type":"ok"}                        the build compiles again
//                     {"type":"assets",...}                reserved (styles, images)
//   from the program: {"type":"saved"}                     the snapshot is written (natively)
//                     {"type":"frame"}                     the first frame is drawn
//                     {"type":"log","text":<text>}         its output (the page's console)
// The snapshot is a string: haxe.Serializer's of an array of strings, key,
// type hash, value (Hot.save's encoding: haxe.Serializer's by default), ...
// This prints one line per swap: `hxmc dev: swapped in <n> ms (build <m> ms)`
// (a native program without the dev host: `reloaded`, a new process),
// from the change seen to the new build's first frame.
import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));

function usage(msg) {
	if (msg) console.error('hxmc dev: ' + msg);
	console.error('usage: hxmc dev [--port <n>] [--host <address>] <build.hxml | haxe arguments> (the output: --custom-target hxmc=<out>; <out>.wasm runs in the browser)');
	process.exit(2);
}

// --- arguments ---

const argv = process.argv.slice(2);
const compiler = argv.shift();
if (!compiler) usage('no compiler');
let port = Number(process.env.HXMC_DEV_PORT ?? 4321);
// (the page on this machine only; --host 0.0.0.0 shows it to the network: a phone)
let host = process.env.HXMC_DEV_HOST ?? '127.0.0.1';
let quiet = false;
const args = [];
for (let i = 0; i < argv.length; i++) {
	if (argv[i] === '--port') port = Number(argv[++i]);
	else if (argv[i] === '--host') host = argv[++i];
	else if (argv[i] === '--quiet') quiet = true;
	else args.push(argv[i]);
}
if (args.length === 0) usage();
const cwd = process.cwd();

// the build's words, hxml files expanded (as the compiler reads them: a line
// is an option and its argument; # comments)
function words(list, depth = 0) {
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
const all = words(args);
let out = null;
const classPaths = [], libs = [], hxmls = args.filter((a) => a.endsWith('.hxml')).map((a) => path.resolve(a));
for (let i = 0; i < all.length; i++) {
	const a = all[i];
	if ((a === '--custom-target' || a === '-custom-target') && all[i + 1]?.startsWith('hxmc=')) out = all[i + 1].slice(5);
	if (a === '-cp' || a === '-p' || a === '--class-path') classPaths.push(path.resolve(all[i + 1]));
	if (a === '-lib' || a === '-L' || a === '--library') libs.push(all[i + 1].split(':')[0]);
}
if (!out) usage('the build names no output (--custom-target hxmc=<out>)');
out = path.resolve(out);
const browser = out.endsWith('.wasm');
// an APK: on the Android device or emulator adb reaches (the dev host: below)
const android = out.endsWith('.apk');
// an app for the iOS simulator: on the booted simulator (the app is the dev
// host: each later build a dylib, -D hxmc.shared, written beside it as
// -D hxmc.output names, which the simulator's app loads from the Mac's files)
const defineOf = (k) => {
	const i = all.findIndex((a, n) => (a === '-D' || a === '--define') && all[n + 1]?.startsWith(k + '='));
	return i >= 0 ? all[i + 1].slice(k.length + 1) : null;
};
const iosSim = out.endsWith('.app') && (defineOf('hxmc.target') ?? '').startsWith('ios-sim');

// the packages the build uses: a class path's package (the nearest
// package.json with a "haxe" field) and the -lib packages from node_modules
// (and their dependencies): their sources are watched, their imports.mjs
// given to the page
function packageOf(dir) {
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
function nodeLibs() {
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
const packages = new Map();
for (const cp of classPaths) {
	const p = packageOf(cp);
	if (p) packages.set(p.dir, p);
}
if (libs.length > 0) {
	const known = nodeLibs();
	const add = (name) => {
		const p = known.get(name);
		if (!p || packages.has(p.dir)) return;
		packages.set(p.dir, p);
		classPaths.push(path.join(p.dir, p.json.haxe.classPath ?? ''));
		for (const d of p.json.haxe.dependencies ?? []) add(d);
	};
	libs.forEach(add);
}
const imports = [...packages.values()].filter((p) => fs.existsSync(path.join(p.dir, 'imports.mjs')));
const osPackage = [...packages.values()].find((p) => p.json.haxe.name === 'hxmc.os');
const FONT_DIRS = ['/usr/share/fonts/truetype/dejavu', '/usr/share/fonts/TTF', '/usr/share/fonts/dejavu', '/Library/Fonts', 'C:\\Windows\\Fonts'];
const fonts = [...packages.values()].some((p) => p.json.haxe.name === 'hxmc.text')
	? ['DejaVuSans.ttf', 'DejaVuSans-Bold.ttf'].map((f) => FONT_DIRS.map((d) => path.join(d, f)).find((p) => fs.existsSync(p))).filter(Boolean)
	: [];

// --- the compilation server ---

const log = (s) => {
	if (!quiet || s.startsWith('hxmc dev: swapped') || s.startsWith('hxmc dev: reloaded') || s.startsWith('hxmc dev: error')) console.log(s);
};

// hxmc's std, given last to each build as the compiler does to its own
// arguments (hxmc.HaxeMain): HXMC_STD, else beside the compiler (the npm
// package's hxmc/bootstrap/hxmc-std, the repository's bin/hxmc/std)
const compilerDir = path.dirname(compiler);
const hxmcStd = [process.env.HXMC_STD, path.join(compilerDir, 'hxmc-std'), path.join(compilerDir, '..', 'hxmc', 'bootstrap', 'hxmc-std'), path.join(compilerDir, 'std')]
	.find((d) => d && fs.existsSync(d));
const serverEnv = {
	...process.env,
	// (a resident compiler keeps what it makes: a large nursery and old space spare it collections)
	RT_OLD_MB: process.env.RT_OLD_MB ?? '4096',
	RT_MINOR_KB: process.env.RT_MINOR_KB ?? '32768',
	HXMC_DEV_PROGRESS: '1',
};
// (--server-connect: the server connects here and takes its requests on that
// connection, each one length-prefixed: where a connection per request
// (--wait) may find the server reading before the request is sent, and
// waiting 50 ms for it)
let link = null, linked = null;
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
// the build in progress (the module is served once it ends), and whether
// the page was told to load again before it ended; the pages connected
let building = false, again = false, early = false, built = Promise.resolve();
const clients = new Set();
// (in the browser, the page loads again once the program is typed, while its
// code is made: HXMC_DEV_PROGRESS has the server say so, "hxmc dev:
// generating"; the page's module is held back until the build ends)
const output = (d) => {
	serverOutput = (serverOutput + d).slice(-65536);
	if (browser && building && !early && clients.size > 0 && serverOutput.indexOf('hxmc dev: generating\n', serverOutput.length - String(d).length - 32) >= 0) {
		early = true;
		sendAll({ type: 'reload' });
	}
};
server.stdout.on('data', output);
server.stderr.on('data', output);
server.on('exit', (code) => {
	console.error('hxmc dev: the compilation server stopped (' + code + ')\n' + serverOutput.slice(-2000));
	process.exit(1);
});
const stop = () => {
	server.removeAllListeners('exit');
	server.kill();
	if (child) child.kill();
	process.exit(0);
};
process.on('SIGINT', stop);
process.on('SIGTERM', stop);

// a request to the compilation server (its protocol: the arguments, one per
// line, after their length, a 32-bit little-endian integer; the answer, after
// its length too, in lines: \x01 output, \x02 failure, any other a message),
// one at a time
const requests = [];
function sendRequest(r) {
	const body = Buffer.from(['--cwd', cwd, ...r.words].join('\n'), 'utf8');
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

// a build, with -D hxmc.dev; the files changed since the last one invalidated
// first (server/invalidate): the server compares a file's time, which two
// saves in one second share (and file systems with coarse times).
// -D disable-hxb-cache: the server keeps its typed modules in memory (Haxe's
// own mode, "use in-memory cache instead of hxb powered cache"), where the
// default writes every module as HXB after each build and reads each back
// in the next (0.3-0.4 s of an edit's build). The outputs are the same
// (hxmc/test/dev/server-verify.mjs); HXMC_DEV_HXB_CACHE=1 keeps the HXB cache.
const hxbCache = process.env.HXMC_DEV_HXB_CACHE === '1' ? [] : ['-D', 'disable-hxb-cache'];
// natively on Linux in the glibc mode, a dev host (hxmc.dev.DevHost): one
// process for the session, which loads each build as a shared library
// (-D hxmc.shared -D hxmc.dev-host; the output renamed to a fresh name per
// build, <out>.dev/<n>.so) and keeps the window and the GPU context across
// builds; HXMC_DEV_HOST=0: a new process per build instead
// (macOS: each build a dylib)
const hosted = !browser && !android && !out.endsWith('.app') && osPackage && process.env.HXMC_DEV_HOST !== '0'
	&& (process.platform === 'darwin' || process.platform === 'win32'
		|| process.platform === 'linux' && all.some((a, i) => (a === '-D' || a === '--define') && all[i + 1] === 'hxmc.libc=glibc'));
const libExt = process.platform === 'darwin' ? '.dylib' : process.platform === 'win32' ? '.dll' : '.so';
// Android: the APK is the dev host, installed once: its library's activity
// glue keeps the window, the EGL context and the input queue, and each
// later build's library (taken from its APK) is fetched by the running
// build over the dev server's socket (adb reverse) into the app's files and
// loaded there, in the same process; the APK built for this server's port
// (-D hxmc.dev-server), asking for the INTERNET permission (its socket)
const androidPort = Number(process.env.HXMC_DEV_ANDROID_PORT ?? port + 1);
const IOS_APP = ['-D', 'hxmc.dev-host', '-D', 'hxmc.exports=hxmc_dev_run,hxmc_dev_state'];
let iosInstalled = false;
const hostArgs = hosted ? ['-D', 'hxmc.shared', '-D', 'hxmc.dev-host', '-D', 'hxmc.exports=hxmc_dev_run,hxmc_dev_state']
	: android ? ['-D', 'hxmc.dev-host', '-D', 'hxmc.exports=hxmc_dev_run,hxmc_dev_state', '-D', 'hxmc.dev-server=127.0.0.1:' + androidPort,
		'-D', 'hxmc.android-permissions=INTERNET'] : [];
const changedFiles = new Set();
async function build() {
	const files = [...changedFiles];
	changedFiles.clear();
	for (const file of files)
		if (file.endsWith('.hx')) await request(['--display', JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'server/invalidate', params: { file } })]);
	// (the iOS simulator: the app first, then dylibs)
	// (Windows: a DLL prefers one of two bases, the other build's while it is loaded)
	const extra = hosted && process.platform === 'win32' ? [...hostArgs, '-D', 'hxmc.dll-base=' + (libCount % 2 === 0 ? '0x10000000' : '0x30000000')]
		: !iosSim ? hostArgs : iosInstalled ? [...IOS_APP, '-D', 'hxmc.shared', '-D', 'hxmc.output=' + path.join(hostDir, 'next.dylib')] : IOS_APP;
	return request([...args, '-D', 'hxmc.dev', ...extra, ...hxbCache, ...(hxmcStd ? ['-cp', hxmcStd] : [])]);
}

// the dev host's executable: built once (beside the compiler's cache, by
// its sources' and the compiler's hash), while the first build runs
const hostDir = out + '.dev';
let hostExe = null, hostBuilt = Promise.resolve(), libCount = 0;
if (iosSim) {
	fs.rmSync(hostDir, { recursive: true, force: true });
	fs.mkdirSync(hostDir, { recursive: true });
}
if (hosted) {
	fs.rmSync(hostDir, { recursive: true, force: true });
	fs.mkdirSync(hostDir, { recursive: true });
	const src = path.join(osPackage.dir, osPackage.json.haxe.classPath ?? 'src');
	const h = crypto.createHash('sha256');
	for (const f of ['DevHost.hx']) h.update(fs.readFileSync(path.join(src, 'hxmc', 'dev', f)));
	h.update(String(fs.statSync(compiler).mtimeMs));
	const cacheDir = path.join(process.env.XDG_CACHE_HOME ?? path.join(os.homedir(), '.cache'), 'hxmc', 'dev-host');
	hostExe = path.join(cacheDir, 'host-' + h.digest('hex').slice(0, 16)) + (process.platform === 'win32' ? '.exe' : '');
	if (!fs.existsSync(hostExe)) hostBuilt = new Promise((resolve, reject) => {
		fs.mkdirSync(cacheDir, { recursive: true });
		const tmp = hostExe.replace(/\.exe$/, '') + '.' + process.pid + (process.platform === 'win32' ? '.exe' : '');
		const p = spawn(compiler, ['-cp', src, '-main', 'hxmc.dev.DevHost', ...(process.platform === 'linux' ? ['-D', 'hxmc.libc=glibc'] : []), '--custom-target', 'hxmc=' + tmp,
			...(hxmcStd ? ['-cp', hxmcStd] : [])],
			{ stdio: ['ignore', 'pipe', 'pipe'] });
		let o = '';
		p.stdout.on('data', (d) => (o += d));
		p.stderr.on('data', (d) => (o += d));
		p.on('exit', (code) => {
			if (code !== 0) return reject(new Error('hxmc dev: the dev host does not build:\n' + o));
			fs.renameSync(tmp, hostExe);
			resolve();
		});
	});
}
// (the build's output, a shared library, under a name of its own: a library loaded is not written over, nor loaded twice under one name)
function nextLibrary() {
	const lib = path.join(hostDir, `${++libCount}${libExt}`);
	fs.renameSync(out, lib);
	// (two builds back: closed by the host)
	try { fs.unlinkSync(path.join(hostDir, `${libCount - 2}${libExt}`)); } catch {}
	return lib;
}

// --- the program ---

const snapshotFile = path.join(os.tmpdir(), `hxmc-dev-${process.pid}.snapshot`);
let child = null, childSocket = null;
let lastError = null;
// the reload being measured: when the change was seen, how long the build took
let timing = null;

function measured() {
	if (!timing) return;
	const t = timing;
	timing = null;
	log(`hxmc dev: ${browser || hosted || android || iosSim ? 'swapped' : 'reloaded'} in ${Math.round(performance.now() - t.seen)} ms (build ${t.build} ms)`);
}

// natively: the program's connection (Android: also "lib <n>", a build's library asked for on a connection of its own)
const appServer = net.createServer((sock) => {
	const before = childSocket;
	childSocket = sock;
	// (Android, the iOS simulator: the device's program reached the server)
	if (android || iosSim) setTimeout(() => childSocket === sock && !sock.destroyed && log('hxmc dev: the program connected'), 50);
	let buf = '';
	sock.on('data', (d) => {
		buf += d;
		let nl;
		while ((nl = buf.indexOf('\n')) >= 0) {
			const line = buf.slice(0, nl);
			buf = buf.slice(nl + 1);
			if (line.startsWith('lib ')) {
				if (childSocket === sock) childSocket = before;
				const lib = androidLibs.get(line.slice(4).trim());
				if (lib) sock.end(lib);
				else sock.destroy();
				return;
			}
			try {
				const m = JSON.parse(line);
				if (m.type === 'frame') measured();
				if (m.type === 'saved') sock.saved?.();
			} catch {}
		}
	});
	sock.on('error', () => {});
	sock.on('close', () => {
		if (childSocket === sock) childSocket = null;
	});
}).listen(android ? androidPort : 0, '127.0.0.1');
await new Promise((r, reject) => {
	appServer.on('listening', r);
	appServer.on('error', (e) => (console.error('hxmc dev: the port for the device: ' + e.message + ' (HXMC_DEV_ANDROID_PORT)'), process.exit(1)));
});

// --- Android ---

const androidLibs = new Map();
let androidInstalled = false, androidCount = 0;
const adb = (args, opts = {}) => new Promise((resolve) => {
	const p = spawn(process.env.ADB ?? 'adb', args, { stdio: ['ignore', 'pipe', 'pipe'], ...opts });
	let o = '';
	p.stdout.on('data', (d) => (o += d));
	p.stderr.on('data', (d) => (o += d));
	p.on('error', (e) => resolve({ code: -1, out: String(e) }));
	p.on('exit', (code) => resolve({ code, out: o }));
});
// the APK's library (lib/<abi>/libmain.so: a zip's entry, stored or deflated)
function apkLibrary(file) {
	const b = fs.readFileSync(file);
	let e = b.length - 22;
	while (e >= 0 && b.readUInt32LE(e) !== 0x06054b50) e--;
	let at = b.readUInt32LE(e + 16);
	const n = b.readUInt16LE(e + 10);
	for (let i = 0; i < n; i++) {
		const method = b.readUInt16LE(at + 10), size = b.readUInt32LE(at + 20), nameLen = b.readUInt16LE(at + 28), extra = b.readUInt16LE(at + 30), comment = b.readUInt16LE(at + 32);
		const local = b.readUInt32LE(at + 42), name = b.toString('utf8', at + 46, at + 46 + nameLen);
		at += 46 + nameLen + extra + comment;
		if (!/^lib\/[^/]+\/lib[^/]+\.so$/.test(name)) continue;
		const data = local + 30 + b.readUInt16LE(local + 26) + b.readUInt16LE(local + 28);
		const raw = b.subarray(data, data + size);
		return method === 0 ? raw : zlib.inflateRawSync(raw);
	}
	throw new Error('hxmc dev: ' + file + ' has no library');
}
function androidPackage() {
	const i = all.findIndex((a, k) => (a === '-D' || a === '--define') && all[k + 1]?.startsWith('hxmc.android-package='));
	return i >= 0 ? all[i + 1].split('=')[1] : 'org.hxmc.' + path.basename(out, '.apk').toLowerCase().replace(/[^a-z0-9_]/g, '_');
}
async function androidStart() {
	const pkg = androidPackage();
	let r = await adb(['install', '-r', out]);
	if (r.code !== 0) return console.error('hxmc dev: adb install failed:\n' + r.out);
	r = await adb(['reverse', 'tcp:' + androidPort, 'tcp:' + androidPort]);
	if (r.code !== 0) return console.error('hxmc dev: adb reverse failed:\n' + r.out);
	await adb(['shell', 'am', 'force-stop', pkg]);
	r = await adb(['shell', 'monkey', '-p', pkg, '-c', 'android.intent.category.LAUNCHER', '1']);
	if (r.code !== 0) return console.error('hxmc dev: the app did not start:\n' + r.out);
	androidInstalled = true;
	log(`hxmc dev: ${pkg} installed and started (its output: adb logcat -s hxmc)`);
}
// a build: the running one fetches its library and hands over to it; none running: the APK installed (again) and started
async function swapAndroid() {
	const sock = childSocket;
	if (androidInstalled && sock) {
		const n = String(++androidCount);
		androidLibs.clear();
		androidLibs.set(n, apkLibrary(out));
		const saved = new Promise((r) => (sock.saved = r));
		const closed = new Promise((r) => sock.once('close', r));
		sock.write(JSON.stringify({ type: 'reload', snapshot: '-', fetch: n }) + '\n');
		await Promise.race([saved, closed]);
		return;
	}
	await androidStart();
}

function startNative(withSnapshot, lib) {
	const env = { ...process.env, HXMC_DEV: '127.0.0.1:' + appServer.address().port };
	if (withSnapshot || hosted) env.HXMC_DEV_SNAPSHOT = snapshotFile;
	if (hosted && !withSnapshot) try { fs.unlinkSync(snapshotFile); } catch {}
	const p = hosted ? spawn(hostExe, [lib], { env, stdio: 'inherit' }) : spawn(out, [], { env, stdio: 'inherit' });
	child = p;
	p.on('exit', (code, signal) => {
		if (child === p) {
			child = null;
			log(`hxmc dev: the program ended (${signal ?? code}); it starts again with the next build`);
		}
	});
}

// natively with the dev host: the running build snapshots, disposes and
// hands over to the new library, in the same process
async function swapHosted() {
	await hostBuilt;
	const lib = nextLibrary();
	const sock = childSocket;
	if (child && sock) {
		try { fs.unlinkSync(snapshotFile); } catch {}
		const saved = new Promise((r) => (sock.saved = r));
		const exited = new Promise((r) => child.once('exit', r));
		sock.write(JSON.stringify({ type: 'reload', snapshot: snapshotFile, library: lib }) + '\n');
		await Promise.race([saved, exited]);
		if (child) return;
	} else if (child) {
		// (a program that has not connected, or not hxmc.os's: stopped, a cold start)
		const old = child;
		child = null;
		old.kill();
		await new Promise((r) => old.once('exit', r));
	}
	startNative(fs.existsSync(snapshotFile), lib);
}

// natively: the running program snapshots and exits; the new build starts with its state
// the iOS simulator: the app installed and launched on the booted
// simulator once; then each build's dylib handed over to by the running build
async function swapIosSim() {
	const sock = childSocket;
	if (iosInstalled && sock) {
		const lib = path.join(hostDir, `${++libCount}.dylib`);
		fs.renameSync(path.join(hostDir, 'next.dylib'), lib);
		try { fs.unlinkSync(snapshotFile); } catch {}
		const saved = new Promise((r) => (sock.saved = r));
		const closed = new Promise((r) => sock.once('close', r));
		sock.write(JSON.stringify({ type: 'reload', snapshot: snapshotFile, library: lib }) + '\n');
		await Promise.race([saved, closed]);
		return;
	}
	if (iosInstalled) return log('hxmc dev: the app is not connected; relaunch it, or restart hxmc dev to install it again');
	const id = defineOf('hxmc.ios-bundle-id') ?? 'org.hxmc.' + path.basename(out, '.app').replace(/[^a-zA-Z0-9.-]/g, '-');
	const run = (a, env = {}) => new Promise((resolve) => {
		const p = spawn('xcrun', ['simctl', ...a], { stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, ...env } });
		let o = '';
		p.stdout.on('data', (d) => (o += d));
		p.stderr.on('data', (d) => (o += d));
		p.on('error', (e) => resolve({ code: -1, out: String(e) }));
		p.on('exit', (code) => resolve({ code, out: o }));
	});
	let r = await run(['install', 'booted', out]);
	if (r.code !== 0) return console.error('hxmc dev: simctl install (a booted simulator?) failed:\n' + r.out);
	try { fs.unlinkSync(snapshotFile); } catch {}
	const logOut = path.join(hostDir, 'stdout.txt'), logErr = path.join(hostDir, 'stderr.txt');
	r = await run(['launch', '--terminate-running-process', '--stdout=' + logOut, '--stderr=' + logErr, 'booted', id],
		{ SIMCTL_CHILD_HXMC_DEV: '127.0.0.1:' + appServer.address().port, SIMCTL_CHILD_HXMC_DEV_SNAPSHOT: snapshotFile });
	if (r.code !== 0) return console.error('hxmc dev: simctl launch failed:\n' + r.out);
	iosInstalled = true;
	log(`hxmc dev: ${id} installed and launched on the booted simulator (its output: ${path.relative(cwd, logOut)})`);
}

async function reloadNative() {
	if (hosted) return swapHosted();
	if (iosSim) return swapIosSim();
	if (android) return swapAndroid();
	const old = child, sock = childSocket;
	let withSnapshot = false;
	if (old) {
		child = null;
		if (sock) {
			try { fs.unlinkSync(snapshotFile); } catch {}
			const exited = new Promise((r) => old.once('exit', r));
			const saved = new Promise((r) => (sock.saved = r));
			sock.write(JSON.stringify({ type: 'reload', snapshot: snapshotFile }) + '\n');
			// (a program that does not answer, its loop busy or not hxmc.os's: stopped, a cold start)
			const t = setTimeout(() => old.kill(), 3000);
			// (the new build starts once the snapshot is written, while the old one exits)
			exited.then(() => clearTimeout(t));
			await Promise.race([saved, exited]);
			withSnapshot = fs.existsSync(snapshotFile);
		} else {
			old.kill();
			await new Promise((r) => old.once('exit', r));
		}
	}
	startNative(withSnapshot);
}

// --- the page (browser) ---

function sendAll(m) {
	for (const c of clients) wsSend(c, JSON.stringify(m));
}

const page = () => `<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${path.basename(out, '.wasm')} (hxmc dev)</title>
<style>
body { margin: 0; background: #fff; }
@media (prefers-color-scheme: dark) { body { background: #0b0b0c; } }
#hxmc-dev-overlay { position: fixed; inset: 0; z-index: 2147483647; display: none; overflow: auto; margin: 0; padding: 16px;
	background: rgba(20, 0, 0, .9); color: #ffd7d7; font: 13px/1.45 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; white-space: pre-wrap; }
#hxmc-dev-overlay b { color: #fff; }
</style>
${[...imports.map((p) => `/__hxmc/pkg/${p.json.haxe.name}/imports.mjs`), '/__hxmc/os/browser.mjs'].map((u) => `<link rel="modulepreload" href="${u}">`).join('\n')}
<script>
// (the module and the fonts, fetched and compiled from the start, while the scripts load)
window.hxmcDevLoad = { wasm: WebAssembly.compileStreaming(fetch('/__hxmc/app.wasm?' + Date.now())),
	fonts: Promise.all([${fonts.map((f) => `'/__hxmc/fonts/${path.basename(f)}'`).join(', ')}].map((u) => fetch(u).then((r) => r.arrayBuffer()))) };
window.hxmcDevLoad.wasm.catch(() => {});
window.hxmcDevLoad.fonts.catch(() => {});
</script></head><body>
<pre id="hxmc-dev-overlay" role="alert"></pre>
<script type="module">
import { run } from '/__hxmc/os/browser.mjs';
// A new build is swapped in, in this page: the running one snapshots and
// disposes (host.dispose(): what it registered dropped, its GPU objects
// released), and the new one runs from the snapshot against the same
// canvas and GPU device; the page never loads again.
const overlay = document.getElementById('hxmc-dev-overlay');
const show = (text) => {
	overlay.innerHTML = '';
	const b = document.createElement('b');
	b.textContent = 'hxmc dev: the build failed; the last good build keeps running\\n\\n';
	overlay.append(b, text);
	overlay.style.display = 'block';
};
let ws = null;
const pending = [];
const send = (m) => (ws && ws.readyState === 1 ? ws.send(JSON.stringify(m)) : pending.push(m));
window.hxmcDev = { log: [], frames: 0, swaps: 0, gpu: null, canvas: null, instance: null };
const out = (s) => { window.hxmcDev.log.push(s); console.log(s); send({ type: 'log', text: s }); };
const IMPORTS = [${imports.map((p) => `'/__hxmc/pkg/${p.json.haxe.name}/imports.mjs'`).join(', ')}];
const fonts = await window.hxmcDevLoad.fonts.catch(() => []);
// the running build: its host, its reload callback, the snapshot it sent
let current = null, gpu = null, canvases = [];
async function start(wasm, restoreBytes) {
	const state = { host: null, reloadFn: 0, snapshot: null };
	const dev = (h) => {
		state.host = h;
		return { hxmc_dev: {
			restore_length: () => restoreBytes === null ? -1 : restoreBytes.length,
			restore_take: (p) => h.bytes(p, restoreBytes.length).set(restoreBytes),
			register: (f) => (state.reloadFn = f),
			send: (p, n) => (state.snapshot = new TextDecoder().decode(h.bytes(p, n).slice())),
			frame: () => { window.hxmcDev.frames++; send({ type: 'frame' }); },
		} };
	};
	current = state;
	window.hxmcDev.instance = state;
	await run(wasm, { imports: [...IMPORTS, dev], fonts, stdout: out, stderr: (s) => out(s), track: true, canvas: canvases[0], gpu,
		// (?gfx=webgl2: WebGL2, even where WebGPU is)
		gfx: new URLSearchParams(location.search).get('gfx') ?? undefined });
	const g = state.host.gfx;
	if (!gpu && g && g.device) gpu = window.hxmcDev.gpu = { adapter: g.adapter, device: g.device };
	window.hxmcDev.canvas = state.host.os?.canvases?.[0] ?? document.querySelector('canvas');
}
// a new build: compiled as it arrives (the server holds it back until the
// build ends; 409: it failed, the running one stays), then swapped in
async function swap() {
	const r = await fetch('/__hxmc/app.wasm?swap=' + Date.now());
	if (!r.ok) return;
	const module = await WebAssembly.compileStreaming(r);
	const old = current;
	let snapshot = null;
	if (old && old.host) {
		old.host.swapping = true;
		if (old.reloadFn) old.host.call(old.reloadFn);
		snapshot = old.snapshot;
		old.host.dispose();
		window.hxmcDev.left = old.host.gfx?.left ?? 0;
		if (old.host.os?.canvases?.length) canvases = old.host.os.canvases;
	}
	await start(module, snapshot === null ? null : new TextEncoder().encode(snapshot));
	window.hxmcDev.swaps++;
}
let swaps = Promise.resolve();
const queueSwap = () => (swaps = swaps.then(swap).catch((e) => { show(String(e && e.stack || e)); send({ type: 'log', text: 'error: ' + (e && e.stack || e) }); }));
// (the dev server's socket; gone, it is asked for again, and a build it made meanwhile swapped in)
function connect(again) {
	ws = new WebSocket('ws://' + location.host + '/__hxmc/ws');
	ws.onopen = () => {
		for (const m of pending.splice(0)) ws.send(JSON.stringify(m));
		if (again) queueSwap();
	};
	ws.onmessage = (e) => {
		const m = JSON.parse(e.data);
		if (m.type === 'error') show(m.message);
		if (m.type === 'ok') overlay.style.display = 'none';
		if (m.type === 'reload') queueSwap();
	};
	ws.onclose = () => setTimeout(() => connect(true), 1000);
}
connect(false);
swaps = start(window.hxmcDevLoad.wasm, null)
	.catch((e) => { show(String(e && e.stack || e)); send({ type: 'log', text: 'error: ' + (e && e.stack || e) }); });
</script></body></html>`;

const types = { '.mjs': 'text/javascript', '.js': 'text/javascript', '.wasm': 'application/wasm', '.ttf': 'font/ttf', '.png': 'image/png', '.json': 'application/json', '.html': 'text/html', '.css': 'text/css', '.svg': 'image/svg+xml' };
function serveFile(res, file) {
	fs.readFile(file, (err, b) => {
		if (err) {
			res.writeHead(404);
			res.end();
			return;
		}
		res.writeHead(200, { 'content-type': types[path.extname(file)] ?? 'application/octet-stream', 'cache-control': 'no-store' });
		res.end(b);
	});
}
const httpServer = http.createServer((req, res) => {
	const p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
	if (p === '/' || p === '/index.html') {
		res.writeHead(200, { 'content-type': 'text/html', 'cache-control': 'no-store' });
		res.end(page());
	} else if (p === '/__hxmc/app.wasm') built.then(() => {
		// (a swap after a build that failed: the running build stays)
		if (lastError !== null && new URL(req.url, 'http://x').searchParams.has('swap')) {
			res.writeHead(409, { 'cache-control': 'no-store' });
			res.end();
		} else serveFile(res, out);
	});
	else if (p === '/__hxmc/os/browser.mjs' && osPackage) serveFile(res, path.join(osPackage.dir, 'browser.mjs'));
	else if (p.startsWith('/__hxmc/pkg/')) {
		const [name, ...rest] = p.slice(12).split('/');
		const pkg = [...packages.values()].find((x) => x.json.haxe.name === name);
		const file = pkg && path.join(pkg.dir, ...rest);
		if (file && file.startsWith(pkg.dir + path.sep)) serveFile(res, file);
		else res.writeHead(404), res.end();
	} else if (p.startsWith('/__hxmc/fonts/')) {
		const f = fonts.find((x) => path.basename(x) === p.slice(14));
		if (f) serveFile(res, f);
		else res.writeHead(404), res.end();
	} else {
		// (the working directory's files: what the program fetches)
		const file = path.join(cwd, p);
		if (file.startsWith(cwd + path.sep)) serveFile(res, file);
		else res.writeHead(404), res.end();
	}
});

// WebSocket (RFC 6455), what the page needs: text messages both ways
httpServer.on('upgrade', (req, sock) => {
	if (new URL(req.url, 'http://x').pathname !== '/__hxmc/ws') return sock.destroy();
	const accept = crypto.createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
	sock.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n');
	clients.add(sock);
	let buf = Buffer.alloc(0);
	sock.on('data', (d) => {
		buf = Buffer.concat([buf, d]);
		for (;;) {
			if (buf.length < 2) return;
			const op = buf[0] & 15;
			let len = buf[1] & 127, at = 2;
			if (len === 126) {
				if (buf.length < 4) return;
				len = buf.readUInt16BE(2);
				at = 4;
			} else if (len === 127) {
				if (buf.length < 10) return;
				len = Number(buf.readBigUInt64BE(2));
				at = 10;
			}
			const masked = buf[1] & 128;
			if (buf.length < at + (masked ? 4 : 0) + len) return;
			const mask = masked ? buf.subarray(at, at + 4) : null;
			at += masked ? 4 : 0;
			const data = Buffer.from(buf.subarray(at, at + len));
			if (mask) for (let i = 0; i < data.length; i++) data[i] ^= mask[i & 3];
			buf = buf.subarray(at + len);
			if (op === 8) return sock.end();
			if (op === 1) onPageMessage(data.toString('utf8'));
		}
	});
	const gone = () => clients.delete(sock);
	sock.on('close', gone);
	sock.on('error', gone);
	if (lastError !== null) wsSend(sock, JSON.stringify({ type: 'error', message: lastError }));
});
function wsSend(sock, text) {
	const b = Buffer.from(text, 'utf8');
	const head = b.length < 126 ? Buffer.from([0x81, b.length]) : b.length < 65536 ? Buffer.from([0x81, 126, b.length >> 8, b.length & 255]) : Buffer.concat([Buffer.from([0x81, 127]), (() => {
		const x = Buffer.alloc(8);
		x.writeBigUInt64BE(BigInt(b.length));
		return x;
	})()]);
	try { sock.write(Buffer.concat([head, b])); } catch {}
}
function onPageMessage(text) {
	try {
		const m = JSON.parse(text);
		if (m.type === 'frame') measured();
		if (m.type === 'log') console.log(m.text);
	} catch {}
}

// --- the loop ---

async function rebuild(seen) {
	if (building) {
		again = true;
		return;
	}
	building = true;
	early = false;
	let ended;
	built = new Promise((r) => (ended = r));
	const t0 = performance.now();
	// (natively: the running program's file moved aside, as a running executable cannot be written over)
	const aside = out + '.running';
	const moved = !browser && !hosted && !android && !iosSim && child !== null && fs.existsSync(out) && (() => {
		try { fs.renameSync(out, aside); return true; } catch { return false; }
	})();
	const r = await build();
	if (moved && !fs.existsSync(out)) fs.renameSync(aside, out);
	const ms = Math.round(performance.now() - t0);
	if (r.messages) (r.ok ? console.log : console.error)(r.messages);
	if (!r.ok) {
		lastError = r.messages || 'the build failed';
		log(`hxmc dev: error (build ${ms} ms); the last good build keeps running`);
		// (a page that loaded again early gets the last good build, the overlay as it connects)
		if (browser) sendAll({ type: 'error', message: lastError });
	} else {
		const wasError = lastError !== null;
		lastError = null;
		timing = seen === null ? null : { seen, build: ms };
		if (browser) {
			if (wasError) sendAll({ type: 'ok' });
			if (early) {} else if (clients.size > 0) sendAll({ type: 'reload' });
			else timing = null;
		} else await reloadNative();
		if (seen === null) log(`hxmc dev: built in ${ms} ms`);
	}
	building = false;
	ended();
	if (again) {
		again = false;
		rebuild(performance.now());
	}
}

// the sources: the class paths and hxml files (not the output, nor files editors write beside)
let pending = null, firstSeen = null;
function changed(file) {
	if (!file) return;
	const base = path.basename(file);
	if (base.startsWith('.') || base.endsWith('~') || base.endsWith('.swp') || base.endsWith('.tmp') || base.startsWith('#')) return;
	const full = path.resolve(file);
	if (full === out || full.startsWith(out + '.')) return;
	changedFiles.add(full);
	if (firstSeen === null) firstSeen = performance.now();
	clearTimeout(pending);
	pending = setTimeout(() => {
		const seen = firstSeen;
		firstSeen = null;
		rebuild(seen);
	}, 10);
}
const watched = new Set();
for (const d of [...new Set(classPaths)].filter((d) => fs.existsSync(d))) {
	if ([...watched].some((w) => d.startsWith(w + path.sep))) continue;
	watched.add(d);
	fs.watch(d, { recursive: true }, (_, f) => f && changed(path.join(d, f)));
}
for (const h of hxmls) fs.watch(h, () => changed(h));

if (browser) {
	await new Promise((resolve, reject) => {
		httpServer.once('error', (e) => (e.code === 'EADDRINUSE' ? httpServer.listen(++port, host, resolve) : reject(e)));
		httpServer.listen(port, host, resolve);
	});
	log(`hxmc dev: http://localhost:${port}/ (${path.relative(cwd, out)}; watching ${watched.size} class paths)`);
} else log(`hxmc dev: ${path.relative(cwd, out)} (watching ${watched.size} class paths)`);
await rebuild(null);
