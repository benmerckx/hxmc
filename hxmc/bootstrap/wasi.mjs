// Runs a WebAssembly module hxmc built for wasm32-wasi under node's WASI, in
// this process: imported by the launcher, or as a command
//   node hxmc/bootstrap/wasi.mjs <module.wasm[.br]> [args...]
//   node hxmc/bootstrap/wasi.mjs --serve <module.wasm[.br]>
// The module sees the arguments, the environment and the whole file system
// (preopened as "/"; on Windows /c/<dir>, /d/<dir>, ... for C:\<dir>, ...), and resolves
// relative paths against $PWD. A module ending in .br (brotli) or .gz is
// decompressed first (the committed stage0 is hxmc/bootstrap/stage0.wasm.br).
// --serve runs one command line after another (serveWasm).
import fs from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import process from 'node:process';
import readline from 'node:readline';
import v8 from 'node:v8';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';
import { Worker, isMainThread, parentPort, workerData } from 'node:worker_threads';
// (node's WASI warns that it is experimental)
const emitWarning = process.emitWarning;
process.emitWarning = (w, ...rest) => {
	if (String(w).includes('WASI')) return;
	emitWarning.call(process, w, ...rest);
};
const { WASI } = await import('node:wasi');

// node 22: exception handling with exnref is behind a flag (not needed by a
// module built with -D hxmc.wasm-eh=legacy; HXMC_WASM_EXNREF=0 leaves it
// off), and WASI's fd_write as a fast API call can collect V8's heap and
// crash when the module's memory is large (node 22.22: uvwasi_fd_write's
// buffer, counted as external memory, starts a full collection inside the
// fast call, which segfaults walking the optimized frames; any program run
// by node's WASI, with any collector of its own)
if (process.env.HXMC_WASM_EXNREF !== '0') v8.setFlagsFromString('--experimental-wasm-exnref');
v8.setFlagsFromString('--no-turbo-fast-api-calls');

// Windows: the top-level directories of every drive as /<drive>/<name> (node's
// WASI does not resolve paths under a preopened drive root), at most 60 (the
// runtime's limit is 64), the drive of the working directory first
function preopens() {
	if (process.platform !== 'win32') return { '/': '/' };
	const r = {};
	let n = 0;
	const first = process.cwd().charAt(0).toUpperCase();
	const drives = [first, ...'CDEFGHIJKLMNOPQRSTUVWXYZ'.split('').filter(d => d !== first)];
	for (const d of drives) {
		let entries;
		try {
			entries = fs.readdirSync(`${d}:\\`, { withFileTypes: true });
		} catch {
			continue;
		}
		for (const e of entries) {
			if (n >= 60) return r;
			if (!e.isDirectory() || e.name.startsWith('$')) continue;
			// (unreadable system folders, e.g. C:\Recovery for a non-admin, fail uvwasi_init)
			try { fs.readdirSync(`${d}:\\${e.name}`); } catch { continue; }
			r[`/${d.toLowerCase()}/${e.name}`] = `${d}:\\${e.name}`;
			n++;
		}
	}
	return r;
}

export function wasiPath(p) {
	if (process.platform !== 'win32') return p;
	const m = /^([A-Za-z]):[\\/](.*)$/.exec(p);
	return m ? `/${m[1].toLowerCase()}/${m[2].replace(/\\/g, '/')}` : p.replace(/\\/g, '/');
}

// variables that hold paths (HAXE_STD_PATH may hold several, by the host's delimiter)
const PATH_VARS = ['HAXE_STD_PATH', 'HXMC_STD', 'HXMC_RT_DIR', 'HXMC_RT_OBJ', 'HXMC_EXE_LIST'];

// the module compiled (o.mod: compiled before, serveWasm's) and run in a new
// instance; o.stdout, o.stderr: descriptors for its standard streams
export function runWasm(module, args, env = process.env, o = {}) {
	const e = { ...env, PWD: wasiPath(process.cwd()) };
	// (one thread: the port sizes its task pool by NUMBER_OF_PROCESSORS, set on Windows)
	delete e.NUMBER_OF_PROCESSORS;
	// the runtime's shadow stack as large as node's stack (--stack-size, in KB:
	// deep recursion, the compiler's) unless RT_STACK_MB says (default 4 MB)
	const stackKb = requestedStackKb();
	if (e.RT_STACK_MB === undefined && stackKb > 4096) e.RT_STACK_MB = String(Math.ceil(stackKb / 1024));
	for (const k of PATH_VARS) if (e[k]) e[k] = e[k].split(path.delimiter).map(wasiPath).join(':');
	const pre = preopens();
	// (HXMC_WASI_DEBUG=1: what the module is given)
	if (env.HXMC_WASI_DEBUG) console.error(JSON.stringify({ preopens: pre, PWD: e.PWD, HAXE_STD_PATH: e.HAXE_STD_PATH }));
	const wasi = new WASI({
		version: 'preview1',
		// (arguments that are Windows paths, as the module spells them)
		args: [wasiPath(path.resolve(module)), ...args.map(a => /^[A-Za-z]:[\\/]/.test(a) ? wasiPath(a) : a)],
		env: e,
		preopens: pre,
		returnOnExit: true,
		...(o.stdout === undefined ? {} : { stdout: o.stdout }),
		...(o.stderr === undefined ? {} : { stderr: o.stderr }),
	});
	const mod = o.mod ?? compileWasm(module);
	const imports = wasi.getImportObject();
	let memory = null;
	if (process.platform === 'win32' || env.HXMC_WASI_READDIR) readdirShim(imports.wasi_snapshot_preview1, pre, () => memory);
	// HXMC_WASM_IMPORTS=<file.cjs>: the modules of the C functions a program
	// declares (@:hxmc.lib; "env" by default), from a CommonJS module
	// exporting (getMemory, getExports) => ({module: {name: function}}); the
	// exports' __indirect_function_table holds the @:hxmc.callback functions
	// whose addresses the program passes (callable after _start returned)
	let inst = null;
	if (env.HXMC_WASM_IMPORTS) Object.assign(imports, createRequire(import.meta.url)(path.resolve(env.HXMC_WASM_IMPORTS))(() => memory, () => inst.exports));
	inst = new WebAssembly.Instance(mod, imports);
	memory = inst.exports.memory;
	return wasi.start(inst) ?? 0;
}

// node's --stack-size, in KB (undefined: not given)
function requestedStackKb() {
	return [...process.execArgv, ...(process.env.NODE_OPTIONS ?? '').split(/\s+/)]
		.map((a) => /^--stack[-_]size=(\d+)$/.exec(a)).filter(Boolean).map((m) => +m[1]).pop();
}

export function compileWasm(module) {
	let bytes = fs.readFileSync(module);
	if (module.endsWith('.br')) bytes = zlib.brotliDecompressSync(bytes);
	else if (module.endsWith('.gz')) bytes = zlib.gunzipSync(bytes);
	return new WebAssembly.Module(bytes);
}

// Command lines run one after another in new instances of the module
// compiled once: each as its own process would run it (its own memory and
// WASI), but without compiling the module again and optimizing its hot
// functions again (V8 shares a module's code between its instances; a build
// of hxmc as a module is 16 MB, a process of its own cost twice the CPU
// time). A JSON line on stdin per run, {args, env, log}: env added to this
// process's, the run's stdout and stderr to the file log; its exit code a
// line on stdout (70 when the module trapped, the error in the log).
// Crosshost's workers.
export async function serveWasm(module) {
	const mod = compileWasm(module);
	for await (const line of readline.createInterface({ input: process.stdin })) {
		if (line.trim() === '') continue;
		process.stdout.write(`${serveOne(module, mod, JSON.parse(line))}\n`);
	}
}

function serveOne(module, mod, j) {
	const log = fs.openSync(j.log, 'w');
	let code;
	try {
		code = runWasm(module, j.args, { ...process.env, ...j.env }, { mod, stdout: log, stderr: log });
	} catch (e) {
		fs.writeSync(log, `${e?.stack ?? e}\n`);
		code = 70;
	}
	fs.closeSync(log);
	return code;
}

// node's WASI (uvwasi) has no fd_readdir on Windows (no seekdir/telldir
// there): directories opened through path_open are tracked here and listed
// with node's fs, as WASI preview 1 lays out its dirents (d_next u64, d_ino
// u64, d_namlen u32, d_type u8, padding to 24 bytes, then the name; the cookie
// is the index of the next entry)
function readdirShim(w, pre, mem) {
	const dirs = new Map();
	let fd = 3;
	for (const real of Object.values(pre)) dirs.set(fd++, real);
	const pathOpen = w.path_open, fdClose = w.fd_close;
	w.path_open = (dirfd, lookup, p, plen, oflags, base, inh, fdflags, out) => {
		const r = pathOpen(dirfd, lookup, p, plen, oflags, base, inh, fdflags, out);
		if (r === 0 && dirs.has(dirfd)) {
			const m = mem();
			const rel = Buffer.from(m.buffer, p, plen).toString('utf8');
			dirs.set(new DataView(m.buffer).getUint32(out, true), path.join(dirs.get(dirfd), rel));
		}
		return r;
	};
	w.fd_close = f => {
		dirs.delete(f);
		return fdClose(f);
	};
	w.fd_readdir = (f, buf, len, cookie, used) => {
		const dir = dirs.get(f);
		const m = mem();
		const view = new DataView(m.buffer);
		if (dir === undefined) return 8; // EBADF
		let entries;
		try {
			entries = [['.', 3], ['..', 3], ...fs.readdirSync(dir, { withFileTypes: true }).map(e => [e.name, e.isDirectory() ? 3 : e.isSymbolicLink() ? 7 : e.isFile() ? 4 : 0])];
		} catch {
			return 54; // ENOTDIR
		}
		let at = 0;
		for (let i = Number(cookie); i < entries.length; i++) {
			const name = Buffer.from(entries[i][0], 'utf8');
			const ent = Buffer.alloc(24 + name.length);
			ent.writeBigUInt64LE(BigInt(i + 1), 0);
			ent.writeUInt32LE(name.length, 16);
			ent[20] = entries[i][1];
			name.copy(ent, 24);
			const n = Math.min(ent.length, len - at);
			Buffer.from(m.buffer, buf + at, n).set(ent.subarray(0, n));
			at += n;
			if (at >= len) break;
		}
		view.setUint32(used, at, true);
		return 0;
	};
}

// As a command given a --stack-size beyond node's default (984 KB), the
// module runs on a worker thread with a stack of that size: node's main
// thread has the system's (ulimit -s: 8 MB on Linux and macOS, 1 MB on
// Windows), past which deep recursion, the compiler's, crashes node with a
// segmentation fault instead of a RangeError. --serve's lines go to the
// worker, its exit codes come back.
const command = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (command && isMainThread) {
	const argv = process.argv.slice(2);
	if (argv.length < 1 || (argv[0] === '--serve' && argv.length !== 2)) {
		console.error('usage: node wasi.mjs <module.wasm[.br]> [args...] | --serve <module.wasm[.br]>');
		process.exit(2);
	}
	const stackKb = requestedStackKb();
	if (!(stackKb > 984)) {
		if (argv[0] === '--serve') await serveWasm(argv[1]);
		else process.exitCode = runWasm(argv[0], argv.slice(1));
	} else {
		const w = new Worker(fileURLToPath(import.meta.url), { workerData: argv, resourceLimits: { stackSizeMb: Math.ceil(stackKb / 1024) + 1 } });
		if (argv[0] === '--serve')
			readline.createInterface({ input: process.stdin }).on('line', (line) => w.postMessage(line)).on('close', () => w.postMessage(null));
		w.on('message', (code) => process.stdout.write(`${code}\n`));
		w.on('error', (e) => {
			console.error(e?.stack ?? e);
			process.exitCode = 70;
		});
		w.on('exit', (code) => {
			if (process.exitCode === undefined) process.exitCode = code;
		});
	}
} else if (!isMainThread && Array.isArray(workerData)) {
	const argv = workerData;
	if (argv[0] !== '--serve') process.exit(runWasm(argv[0], argv.slice(1)));
	const module = argv[1], mod = compileWasm(module);
	parentPort.on('message', (line) => {
		if (line === null) return parentPort.close();
		if (line.trim() === '') return;
		parentPort.postMessage(serveOne(module, mod, JSON.parse(line)));
	});
}
