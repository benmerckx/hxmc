// Runs a WebAssembly module hxmc built for wasm32-wasi under node's WASI, in
// this process: imported by the launcher, or as a command
//   node hxmc/bootstrap/wasi.mjs <module.wasm[.br]> [args...]
// The module sees the arguments, the environment and the whole file system
// (preopened as "/"; on Windows /c/<dir>, /d/<dir>, ... for C:\<dir>, ...), and resolves
// relative paths against $PWD. A module ending in .br (brotli) or .gz is
// decompressed first (the committed stage0 is hxmc/bootstrap/stage0.wasm.br).
import fs from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import process from 'node:process';
import v8 from 'node:v8';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';
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

export function runWasm(module, args, env = process.env) {
	const e = { ...env, PWD: wasiPath(process.cwd()) };
	// (one thread: the port sizes its task pool by NUMBER_OF_PROCESSORS, set on Windows)
	delete e.NUMBER_OF_PROCESSORS;
	// the runtime's shadow stack as large as node's stack (--stack-size, in KB:
	// deep recursion, the compiler's) unless RT_STACK_MB says (default 4 MB)
	const stackKb = [...process.execArgv, ...(process.env.NODE_OPTIONS ?? '').split(/\s+/)]
		.map((a) => /^--stack[-_]size=(\d+)$/.exec(a)).filter(Boolean).map((m) => +m[1]).pop();
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
	});
	let bytes = fs.readFileSync(module);
	if (module.endsWith('.br')) bytes = zlib.brotliDecompressSync(bytes);
	else if (module.endsWith('.gz')) bytes = zlib.gunzipSync(bytes);
	const mod = new WebAssembly.Module(bytes);
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

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
	if (process.argv.length < 3) {
		console.error('usage: node wasi.mjs <module.wasm[.br]> [args...]');
		process.exit(2);
	}
	process.exitCode = runWasm(process.argv[2], process.argv.slice(3));
}
