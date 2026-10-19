// Runs a module built with -D hxmc.wasm-gc (hxmc/src/hxmc/wasmgc) under node:
//   node hxmc/bootstrap/wasmgc.mjs prog.wasm [args...]
// The module imports its host from "hxmc" and exports _start, plus the
// accessors that read its strings (arrays of UTF-16 units).
import * as fs from "node:fs";
import * as path from "node:path";
import { createRequire } from "node:module";
import { spawnSync } from "node:child_process";
import { constants as osConstants } from "node:os";
import { Worker } from "node:worker_threads";
const { readFileSync, writeSync } = fs;

const [file, ...args] = process.argv.slice(2);
if (!file) {
	console.error("usage: node wasmgc.mjs prog.wasm [args...]");
	process.exit(2);
}
// (one processor: the module has one thread, and the port sizes its task pool by this)
process.env.NUMBER_OF_PROCESSORS = "1";
let exports;
// a string of the module as a JavaScript string
function str(s) {
	if (s === null) return "null";
	const n = exports.hxmc_str_len(s);
	let out = "";
	for (let i = 0; i < n; i += 4096) {
		const units = [];
		for (let k = i; k < Math.min(n, i + 4096); k++) units.push(exports.hxmc_str_get(s, k));
		out += String.fromCharCode(...units);
	}
	return out;
}
// a write of the whole buffer (a pipe that is full: EAGAIN, written again
// after a millisecond), at the position when one is given (else the file's)
function writeAll(fd, buf, position = null) {
	let at = 0;
	while (at < buf.length) {
		try {
			at += writeSync(fd, buf, at, buf.length - at, position === null ? null : position + at);
		} catch (e) {
			if (e.code !== "EAGAIN") throw e;
			Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1);
		}
	}
	return at;
}
// the descriptors opened by fileIo: their position (node's fs has no lseek), append mode
const files = new Map();
// the processes of sys.io.Process (GcSys: fileIo's ops 6-8, and the
// descriptors PROC_FD + 4 * pid + 0/1/2 of their standard streams), run by a
// worker thread that node's events reach while this thread waits for its
// answer (Atomics.wait): the answer's number in ctl[1], bytes read in data
const PROC_FD = 0x40000000;
const PROC_WORKER = `
const { parentPort, workerData } = require("node:worker_threads");
const { spawn } = require("node:child_process");
const { constants } = require("node:os");
const ctl = new Int32Array(workerData.ctl), data = new Uint8Array(workerData.data);
const procs = new Map();
let failed = 0;
function reply(n) {
	ctl[1] = n;
	Atomics.store(ctl, 0, 1);
	Atomics.notify(ctl, 0);
}
// a pending read answered: the stream's bytes (at most len) into data, or 0 at its end
function serve(p) {
	const r = p.pending;
	if (!r) return;
	const s = p.streams[r.k];
	if (s.chunks.length === 0 && !s.ended) return;
	p.pending = null;
	let n = 0;
	while (n < r.len && s.chunks.length > 0) {
		const c = s.chunks[0], m = Math.min(c.length, r.len - n);
		data.set(c.subarray(0, m), n);
		n += m;
		if (m === c.length) s.chunks.shift(); else s.chunks[0] = c.subarray(m);
	}
	reply(n);
}
function waited(p) {
	const w = p.waiter;
	if (!w || p.code === null) return;
	p.waiter = null;
	reply(p.code);
}
parentPort.on("message", m => {
	const p = procs.get(m.pid);
	switch (m.op) {
		case "run": {
			const opts = { env: m.env, stdio: ["pipe", "pipe", "pipe"], shell: m.shell ? "/bin/sh" : false };
			let child = null;
			try {
				child = m.shell ? spawn(m.cmd, opts) : spawn(m.cmd, m.args, opts);
			} catch (e) {}
			const q = { code: null, pending: null, waiter: null, streams: [null, { chunks: [], ended: false }, { chunks: [], ended: false }], child };
			if (!child || child.pid === undefined) {
				// (exec failed: as a child that exits 127 without output)
				if (child) child.on("error", () => {});
				q.streams[1].ended = q.streams[2].ended = true;
				q.code = 127;
				const pid = 4194304 + failed++;
				procs.set(pid, q);
				return reply(pid);
			}
			// (a child's later errors, a pipe closed early: what reading and waiting tell)
			child.on("error", () => {});
			child.stdin.on("error", () => {});
			[child.stdout, child.stderr].forEach((s, i) => {
				s.on("data", c => {
					q.streams[i + 1].chunks.push(c);
					serve(q);
				});
				s.on("end", () => {
					q.streams[i + 1].ended = true;
					serve(q);
				});
			});
			child.on("exit", (code, signal) => {
				q.code = code !== null ? code : 128 + (constants.signals[signal] ?? 0);
				waited(q);
			});
			procs.set(child.pid, q);
			return reply(child.pid);
		}
		case "read":
			if (!p || !p.streams[m.k]) return reply(-1);
			p.pending = { k: m.k, len: m.len };
			return serve(p);
		case "write":
			if (!p || !p.child) return reply(-1);
			p.child.stdin.write(Buffer.from(data.subarray(0, m.len)));
			return reply(m.len);
		case "close":
			if (p && p.child) {
				if (m.k === 0) p.child.stdin.end();
				else p.child[m.k === 1 ? "stdout" : "stderr"].destroy();
			}
			return reply(0);
		case "wait":
			if (!p) return reply(-1);
			if (p.code !== null || !m.block) return reply(p.code === null ? -1 : p.code);
			p.waiter = true;
			return;
		case "kill":
			if (p && p.child && p.code === null) p.child.kill("SIGKILL");
			return reply(0);
	}
});
`;
let procWorker = null, procCtl = null, procData = null;
function procCall(msg) {
	if (procWorker === null) {
		procCtl = new Int32Array(new SharedArrayBuffer(8));
		procData = new Uint8Array(new SharedArrayBuffer(1 << 20));
		procWorker = new Worker(PROC_WORKER, { eval: true, workerData: { ctl: procCtl.buffer, data: procData.buffer } });
		// (it does not keep node running once the module is done)
		procWorker.unref();
	}
	Atomics.store(procCtl, 0, 0);
	procWorker.postMessage(msg);
	while (Atomics.load(procCtl, 0) === 0) Atomics.wait(procCtl, 0, 0);
	return procCtl[1];
}
// a process stream's descriptor: read into, written from the bytes x at a, b of them; closed
function procIo(op, fd, x, a, b) {
	const pid = Math.floor((fd - PROC_FD) / 4), k = (fd - PROC_FD) % 4;
	switch (op) {
		case 1: {
			const n = procCall({ op: "read", pid, k, len: Math.min(b, procData.length) });
			for (let i = 0; i < n; i++) exports.hxmc_bytes_set(x, a + i, procData[i]);
			return n;
		}
		case 2: {
			const n = Math.min(b, procData.length);
			for (let i = 0; i < n; i++) procData[i] = exports.hxmc_bytes_get(x, a + i);
			return procCall({ op: "write", pid, len: n });
		}
		case 3:
			return procCall({ op: "close", pid, k });
		default:
			return -1;
	}
}
const hxmc = {
	write(fd, s) {
		writeAll(fd === 2 ? 2 : 1, Buffer.from(str(s), "utf8"));
	},
	now() {
		return performance.now() / 1000;
	},
	fmt(v) {
		return ofJs(String(v));
	},
	parseFloat(s) {
		return parseFloat(str(s));
	},
	math(op, x, y) {
		switch (op) {
			case 0: return Math.sin(x);
			case 1: return Math.cos(x);
			case 2: return Math.tan(x);
			case 3: return Math.asin(x);
			case 4: return Math.acos(x);
			case 5: return Math.atan(x);
			case 6: return Math.atan2(x, y);
			case 7: return Math.exp(x);
			case 8: return Math.log(x);
			default: return Math.pow(x, y);
		}
	},
	random() {
		return Math.random();
	},
	// GcSys's op codes
	sysStr(op, a, b) {
		const s = a === null ? null : str(a);
		try {
			switch (op) {
				case 0: return process.env[s] === undefined ? null : ofJs(process.env[s]);
				case 1: return ofJs(process.cwd());
				case 2: return ofJs(path.resolve(s));
				case 3: {
					// (in the directory's order, as readdir gives it: readdirSync sorts)
					const d = fs.opendirSync(s), names = [];
					try {
						for (let e; (e = d.readSync()) !== null; ) names.push(e.name);
					} finally {
						d.closeSync();
					}
					return ofJs(names.join("\0"));
				}
				case 4: return ofJs(args.join("\0"));
				case 5: return ofJs(Object.entries(process.env).map(([k, v]) => k + "=" + v).join("\0"));
				case 6: return ofJs(path.resolve(file));
				case 7: {
					const st = fs.statSync(s);
					const t = (d) => Math.floor(d.getTime() / 1000);
					return ofJs([st.gid, st.uid, t(st.atime), t(st.mtime), t(st.ctime), st.dev, st.ino, st.nlink, st.rdev, st.size, st.mode].join("\0"));
				}
				default: return ofJs("Wasi");
			}
		} catch (e) {
			return null;
		}
	},
	sysNum(op, a, b, n) {
		const s = a === null ? null : str(a), t = b === null ? null : str(b);
		try {
			switch (op) {
				case 0: return fs.existsSync(s) ? 1 : 0;
				case 1: return fs.existsSync(s) && fs.statSync(s).isDirectory() ? 1 : 0;
				case 2: fs.mkdirSync(s, { recursive: true }); return 1;
				case 3: fs.unlinkSync(s); return 1;
				case 4: fs.rmdirSync(s); return 1;
				case 5: fs.renameSync(s, t); return 1;
				case 6: process.chdir(s); return 1;
				case 7: process.exit(n);
				case 8: return Date.now() / 1000;
				case 9: { const u = process.cpuUsage(); return (u.user + u.system) / 1e6; }
				case 10: Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, n * 1000); return 0;
				case 11: if (t === null) delete process.env[s]; else process.env[s] = t; return 0;
				case 12: {
					// (Sys.command: through the shell; a signal as the shell reports it)
					const r = spawnSync(s, { shell: true, stdio: "inherit" });
					if (r.error) return -1;
					return r.status !== null ? r.status : 128 + (osConstants.signals[r.signal] ?? 0);
				}
				// (hxmc.NativeGc.heapBytes: V8's heap in use)
				case 13: return process.memoryUsage().heapUsed;
				default: return 0;
			}
		} catch (e) {
			return 0;
		}
	},
	// GcDate's op codes
	dateNum(op, t, y, m, d, h, mi, s) {
		const date = new Date(t);
		switch (op) {
			case 0: return new Date(y, m, d, h, mi, s).getTime();
			case 1: return date.getFullYear();
			case 2: return date.getMonth();
			case 3: return date.getDate();
			case 4: return date.getDay();
			case 5: return date.getHours();
			case 6: return date.getMinutes();
			case 7: return date.getSeconds();
			case 8: return date.getUTCFullYear();
			case 9: return date.getUTCMonth();
			case 10: return date.getUTCDate();
			case 11: return date.getUTCDay();
			case 12: return date.getUTCHours();
			case 13: return date.getUTCMinutes();
			case 14: return date.getUTCSeconds();
			case 15: return date.getTimezoneOffset();
			default: return Date.now();
		}
	},
	readFile(p) {
		let data;
		try {
			data = readFileSync(str(p));
		} catch (e) {
			return null;
		}
		const b = exports.hxmc_bytes_new(data.length);
		for (let i = 0; i < data.length; i++) exports.hxmc_bytes_set(b, i, data[i]);
		return b;
	},
	// GcSys's descriptors: 0 open (x the path, a the mode: 0 read, 1 write, 2
	// append, 3 update), 1 read and 2 write (x the bytes, at a, b of them), 3
	// close, 4 seek (to a, b: whence), 5 tell; processes: 6 run (the pid), 7 wait
	// (fd the pid, a: block; -1 while it runs), 8 kill; -1 on errors
	fileIo(op, fd, x, a, b) {
		if (fd >= PROC_FD && op >= 1 && op <= 3) return procIo(op, fd, x, a, b);
		try {
			const f = files.get(fd);
			switch (op) {
				case 0: {
					const c = fs.constants;
					const flags = a === 0 ? "r" : a === 1 ? "w" : a === 2 ? "a" : a === 3 ? c.O_RDWR | c.O_CREAT : null;
					if (flags === null) return -1;
					const n = fs.openSync(str(x), flags);
					files.set(n, { pos: 0, append: a === 2 });
					return n;
				}
				case 1: {
					const buf = Buffer.alloc(b);
					let n;
					while (true) {
						try {
							n = fs.readSync(fd, buf, 0, b, f ? f.pos : null);
							break;
						} catch (e) {
							if (e.code === "EOF") return 0;
							if (e.code !== "EAGAIN") throw e;
							Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1);
						}
					}
					if (f) f.pos += n;
					for (let i = 0; i < n; i++) exports.hxmc_bytes_set(x, a + i, buf[i]);
					return n;
				}
				case 2: {
					const buf = Buffer.alloc(b);
					for (let i = 0; i < b; i++) buf[i] = exports.hxmc_bytes_get(x, a + i);
					if (f && f.append) {
						writeAll(fd, buf);
						f.pos = fs.fstatSync(fd).size;
					} else {
						writeAll(fd, buf, f ? f.pos : null);
						if (f) f.pos += b;
					}
					return b;
				}
				case 3:
					files.delete(fd);
					fs.closeSync(fd);
					return 0;
				case 4: {
					if (!f) return -1;
					const p = b === 0 ? a : b === 1 ? f.pos + a : fs.fstatSync(fd).size + a;
					if (p < 0) return -1;
					f.pos = p;
					return 0;
				}
				case 5:
					return f ? f.pos : -1;
				case 6: {
					// (a process: x the command, then its arguments when a is 1, by NULs; else through the shell)
					const parts = str(x).split("\0");
					return procCall({ op: "run", cmd: parts[0], args: parts.slice(1), shell: a === 0, env: { ...process.env } });
				}
				case 7:
					return procCall({ op: "wait", pid: fd, block: a !== 0 });
				case 8:
					return procCall({ op: "kill", pid: fd });
				default:
					return -1;
			}
		} catch (e) {
			return -1;
		}
	},
	writeFile(p, b, append) {
		const n = exports.hxmc_bytes_len(b), data = new Uint8Array(n);
		for (let i = 0; i < n; i++) data[i] = exports.hxmc_bytes_get(b, i);
		try {
			(append ? fs.appendFileSync : fs.writeFileSync)(str(p), data);
			return 1;
		} catch (e) {
			return 0;
		}
	},
};
// a JavaScript string as one of the module's
function ofJs(t) {
	const s = exports.hxmc_str_new(t.length);
	for (let i = 0; i < t.length; i++) exports.hxmc_str_set(s, i, t.charCodeAt(i));
	return s;
}
// HXMC_WASM_IMPORTS=<file.cjs>: the modules of the program's imports that take
// and return numbers (@:hxmc.lib externs), as hxmc/bootstrap/wasi.mjs takes
// them (getMemory: the module's linear memory, when it has one)
const imports = { hxmc };
if (process.env.HXMC_WASM_IMPORTS) Object.assign(imports, createRequire(import.meta.url)(path.resolve(process.env.HXMC_WASM_IMPORTS))(() => exports.memory ?? null, () => exports));
const { instance } = await WebAssembly.instantiate(readFileSync(file), imports);
exports = instance.exports;
try {
	exports._start();
} catch (e) {
	if (e instanceof WebAssembly.Exception) {
		console.error("Uncaught exception (a Haxe value)");
		process.exit(1);
	}
	throw e;
}
