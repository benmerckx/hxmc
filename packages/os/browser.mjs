// Runs a WebAssembly module hxmc built for wasm32-wasi in a browser, with the
// imports of the packages it uses: the browser's counterpart of node's
// hxmc/bootstrap/wasi.mjs.
//
//   import { run } from './browser.mjs';
//   const { host, exitCode } = await run('triangle.wasm', {
//     imports: ['os/imports.mjs', 'gfx/imports.mjs'], canvas: 'demo' });
//
// The module: its URL, a Response, a WebAssembly.Module or its bytes, or a
// promise of one (WebAssembly.compileStreaming(fetch(url)) started before
// run: compiled while the imports load).
//
// The import convention: a package whose externs are imports of a module
// (`@:hxmc.lib("hxmc_gfx")`) ships `imports.mjs`, whose default export is a
// function (host) => ({module: {name: function}}), or a promise of that (it
// may wait for what it needs before the module starts: WebGPU's device). The
// objects are merged and the module instantiated, then _start runs main.
// The host each package gets:
//   options        run's options (canvas: an element or its id, and
//                  audioContext: a function (sampleRate, channels) =>
//                  an AudioContext or OfflineAudioContext, and
//                  touchAction: the canvas's CSS touch-action, by default
//                  'none' (every touch drag the program's; 'pan-y': the
//                  page scrolls on vertical swipes over the canvas that
//                  Window.scrollsAt does not take), for os; gfx:
//                  'webgl2' for gfx, WebGL2 even where WebGPU is, and
//                  antialias: true, the canvas's frames multisampled)
//   memory()       the module's memory; bytes(p, n), string(p) read it (a
//                  view made anew each time: the memory may have grown)
//   handles        the JavaScript objects the module refers to by integer
//                  (add(o) gives the handle, get(h), remove(h); 0 is none)
//   call(f, ...a)  a @:hxmc.callback through its address (an index in the
//                  module's function table), also after main returned; if
//                  the program exits there (proc_exit), its result is
//                  undefined and host.exitCode is set
// WASI preview 1 is what the runtime needs without a file system: the
// arguments and environment, stdout and stderr (lines to options.stdout and
// options.stderr, else the console), the clocks, random bytes, proc_exit;
// any other function fails with ENOSYS. Files a program reads are fetched
// before it starts, in parallel with the module's download and compilation,
// and served read-only from a preopened "." (sys.io.File.getBytes and
// friends): options.files ({path: URL}) and options.assets (the URL of a
// JSON list of paths, relative to it: the one a build writes beside the
// module for the files its static references name, e.g. @hxmc/3d's
// Model.of; <module>.assets.json).
//
// A module built with -D hxmc.wasm-gc (its Haxe values in the engine's
// collector, a small linear memory for what crosses to the host: the same
// memory(), handles and call for the packages) imports the runtime's host
// as "hxmc" instead (hxmc/bootstrap/wasmgc.mjs is node's): the output, the
// clocks, Math, float formatting and parsing, the calendar, exit; no files.
//
// Swapping a module in the same page (hxmc dev; docs/dev.md, "No reloads"):
// with the option track, what the instance registers with the page while
// it is the page's (listeners on anything it did not create, animation
// frames, timers, observers, audio contexts, the elements it created) is
// recorded, and host.dispose() drops it all: the packages' own disposals
// first (host.onDispose(f), last given first: os keeps its canvases, gfx
// releases its GPU objects but keeps the device and the canvases'
// contexts), then what is left. The elements marked kept (host.keep(e):
// os's canvases) stay, without the instance's properties (hxmc*). After
// dispose host.call does nothing. One instance is tracked at a time: the
// page disposes the old one before it runs the new one. The option gpu
// ({adapter, device}: host.gfx of an earlier instance) gives gfx the device
// to use, so a new instance draws with the same GPUDevice.
//
// Memory: the module's own memory grows as it needs (the runtime reports
// what memory.grow refused on stderr: "out of memory: ..."); a RangeError of
// the browser's (the memory of a new instance, an ArrayBuffer) becomes
// an Error whose message says "out of memory" and how much was asked.

// (the instance whose registrations are recorded: one at a time)
let tracking = null;
let tracked = false;
function installTracking() {
	if (tracked) return;
	tracked = true;
	const g = globalThis, ET = EventTarget.prototype, add = ET.addEventListener;
	ET.addEventListener = function (type, f, o) {
		// (listeners on the instance's own elements go with them)
		if (tracking && f && !tracking.created.has(this)) tracking.listeners.push([new WeakRef(this), type, f, o]);
		return add.call(this, type, f, o);
	};
	const raf = g.requestAnimationFrame.bind(g);
	g.requestAnimationFrame = (cb) => {
		const r = tracking;
		if (!r) return raf(cb);
		const id = raf((t) => {
			r.frames.delete(id);
			cb(t);
		});
		r.frames.add(id);
		return id;
	};
	const timeout = g.setTimeout.bind(g), interval = g.setInterval.bind(g);
	g.setTimeout = (cb, ms, ...a) => {
		const r = tracking;
		if (!r || typeof cb !== 'function') return timeout(cb, ms, ...a);
		const id = timeout(() => {
			r.timers.delete(id);
			cb(...a);
		}, ms);
		r.timers.add(id);
		return id;
	};
	g.setInterval = (cb, ms, ...a) => {
		const id = interval(cb, ms, ...a);
		tracking?.intervals.add(id);
		return id;
	};
	for (const name of ['ResizeObserver', 'IntersectionObserver', 'MutationObserver', 'PerformanceObserver']) {
		const O = g[name];
		if (O) g[name] = class extends O {
			constructor(...a) {
				super(...a);
				tracking?.observers.push(this);
			}
		};
	}
	for (const name of ['AudioContext', 'OfflineAudioContext']) {
		const A = g[name];
		if (A) g[name] = class extends A {
			constructor(...a) {
				super(...a);
				if (name === 'AudioContext') tracking?.audio.push(this);
			}
		};
	}
	const D = Document.prototype;
	for (const k of ['createElement', 'createElementNS']) {
		const f = D[k];
		D[k] = function (...a) {
			const e = f.apply(this, a);
			if (tracking) {
				tracking.created.add(e);
				const list = tracking.elements;
				list.push(new WeakRef(e));
				// (the ones collected dropped now and then)
				if (list.length >= tracking.compactAt) {
					const live = list.filter((w) => w.deref() !== undefined);
					list.length = 0;
					list.push(...live);
					tracking.compactAt = Math.max(4096, live.length * 2);
				}
			}
			return e;
		};
	}
}

class Exit {
	constructor(code) {
		this.code = code;
	}
}

export async function run(wasm, options = {}) {
	// (the files, fetched while the module loads)
	const files = fetchFiles(options);
	let served = null;
	const args = ['main.wasm', ...(options.args ?? [])];
	const env = Object.entries(options.env ?? {}).map(([k, v]) => `${k}=${v}`);
	let memory = null, exports = null;
	const enc = new TextEncoder();
	const view = () => new DataView(memory.buffer);
	const bytes = (p, n) => new Uint8Array(memory.buffer, p, n);
	const string = (p) => {
		const m = new Uint8Array(memory.buffer);
		let e = p;
		while (m[e]) e++;
		return new TextDecoder().decode(m.subarray(p, e));
	};
	const objects = [null];
	const free = [];
	const handles = {
		add(o) {
			const h = free.length ? free.pop() : objects.length;
			objects[h] = o;
			return h;
		},
		get: (h) => objects[h],
		// (one past the highest handle given)
		size: () => objects.length,
		remove(h) {
			objects[h] = null;
			free.push(h);
		},
	};
	// (option track: what the instance registers, dropped by dispose)
	const registry = options.track ? { listeners: [], frames: new Set(), timers: new Set(), intervals: new Set(), observers: [], audio: [], created: new WeakSet(), elements: [], compactAt: 4096, kept: new Set() } : null;
	const disposals = [];
	if (registry) {
		installTracking();
		tracking = registry;
	}
	const host = {
		options, handles, bytes, string, exitCode: null, disposed: false,
		// (true while the page swaps in a new build: the packages keep what the next instance takes over)
		swapping: false,
		memory: () => memory,
		onDispose: (f) => disposals.push(f),
		keep(e) {
			registry?.kept.add(e);
		},
		// drops the instance: the packages' disposals, then what it registered
		dispose() {
			if (host.disposed) return;
			host.swapping = true;
			for (const f of disposals.reverse()) {
				try {
					f();
				} catch (e) {
					console.error('hxmc: a dispose function failed:', e);
				}
			}
			host.disposed = true;
			if (!registry) return;
			if (tracking === registry) tracking = null;
			for (const [t, type, f, o] of registry.listeners) t.deref()?.removeEventListener(type, f, o);
			for (const id of registry.frames) cancelAnimationFrame(id);
			for (const id of registry.timers) clearTimeout(id);
			for (const id of registry.intervals) clearInterval(id);
			for (const o of registry.observers) o.disconnect();
			for (const a of registry.audio) if (a.state !== 'closed') a.close().catch(() => {});
			for (const w of registry.elements) {
				const e = w.deref();
				if (!e) continue;
				if (registry.kept.has(e)) {
					for (const k of Object.keys(e)) if (k.startsWith('hxmc') && !k.startsWith('hxmcKeep')) delete e[k];
				} else if (e.isConnected) e.remove();
			}
			registry.listeners.length = registry.observers.length = registry.audio.length = registry.elements.length = 0;
		},
		call(f, ...a) {
			if (host.exitCode !== null || host.disposed) return undefined;
			try {
				return exports.__indirect_function_table.get(f)(...a);
			} catch (e) {
				if (!(e instanceof Exit)) throw e;
				host.exitCode = e.code;
				return undefined;
			}
		},
	};

	// stdout and stderr, by lines
	const sinks = {
		1: { out: options.stdout ?? ((s) => console.log(s)), text: '', dec: new TextDecoder() },
		2: { out: options.stderr ?? ((s) => console.error(s)), text: '', dec: new TextDecoder() },
	};
	function write(fd, data) {
		const s = sinks[fd];
		s.text += s.dec.decode(data, { stream: true });
		const lines = s.text.split('\n');
		s.text = lines.pop();
		for (const l of lines) s.out(l);
	}
	// (arguments and environment variables: a table of pointers, then the strings)
	function strings(list, ptrs, buf) {
		const v = view();
		for (const s of list) {
			const b = enc.encode(s + '\0');
			v.setUint32(ptrs, buf, true);
			bytes(buf, b.length).set(b);
			ptrs += 4;
			buf += b.length;
		}
		return 0;
	}
	function sizes(list, count, size) {
		view().setUint32(count, list.length, true);
		view().setUint32(size, list.reduce((n, s) => n + enc.encode(s).length + 1, 0), true);
		return 0;
	}
	const wasi = {
		args_get: (p, b) => strings(args, p, b),
		args_sizes_get: (c, s) => sizes(args, c, s),
		environ_get: (p, b) => strings(env, p, b),
		environ_sizes_get: (c, s) => sizes(env, c, s),
		clock_time_get(id, precision, out) {
			const ns = id === 0 ? BigInt(Date.now()) * 1000000n : BigInt(Math.round(performance.now() * 1e6));
			view().setBigUint64(out, ns, true);
			return 0;
		},
		clock_res_get(id, out) {
			view().setBigUint64(out, 1000n, true);
			return 0;
		},
		fd_write(fd, iovs, n, written) {
			if (!sinks[fd]) return 8; // EBADF
			const v = view();
			let total = 0;
			for (let i = 0; i < n; i++) {
				const p = v.getUint32(iovs + 8 * i, true), len = v.getUint32(iovs + 8 * i + 4, true);
				write(fd, bytes(p, len).slice());
				total += len;
			}
			view().setUint32(written, total, true);
			return 0;
		},
		random_get(p, n) {
			for (let i = 0; i < n; i += 65536) crypto.getRandomValues(bytes(p + i, Math.min(65536, n - i)));
			return 0;
		},
		sched_yield: () => 0,
		// (a read-only "." of the fetched files, fd 3, when there are any)
		fd_prestat_get(fd, out) {
			if (fd !== 3 || !served) return 8; // EBADF
			view().setUint8(out, 0);
			view().setUint32(out + 4, 1, true);
			return 0;
		},
		fd_prestat_dir_name(fd, p, n) {
			if (fd !== 3 || !served) return 8;
			bytes(p, 1)[0] = 46; // "."
			return 0;
		},
		fd_fdstat_get(fd, out) {
			const f = fd === 3 && served ? { dir: true } : open.get(fd);
			if (!f) return 8;
			const v = view();
			v.setUint8(out, f.dir ? 3 : 4);
			v.setUint16(out + 2, 0, true);
			v.setBigUint64(out + 8, 0xffffffffn, true);
			v.setBigUint64(out + 16, 0xffffffffn, true);
			return 0;
		},
		path_open(dirfd, lookup, p, n, oflags, base, inh, fdflags, out) {
			if (dirfd !== 3 || !served) return 8;
			const path = new TextDecoder().decode(bytes(p, n).slice()).replace(/^\.\//, '');
			const data = served.get(path);
			if (!data) return 44; // ENOENT
			if (oflags & 9) return 63; // EPERM: no creating or truncating here
			const fd = nextFd++;
			open.set(fd, { data, pos: 0 });
			view().setUint32(out, fd, true);
			return 0;
		},
		path_filestat_get(dirfd, lookup, p, n, out) {
			if (dirfd !== 3 || !served) return 8;
			const data = served.get(new TextDecoder().decode(bytes(p, n).slice()).replace(/^\.\//, ''));
			if (!data) return 44;
			stat(out, data.length);
			return 0;
		},
		fd_filestat_get(fd, out) {
			const f = open.get(fd);
			if (!f) return 8;
			stat(out, f.data.length);
			return 0;
		},
		fd_read(fd, iovs, n, read) {
			const f = open.get(fd);
			if (!f) return 8;
			const v = view();
			let total = 0;
			for (let i = 0; i < n; i++) {
				const p = v.getUint32(iovs + 8 * i, true), len = v.getUint32(iovs + 8 * i + 4, true);
				const chunk = f.data.subarray(f.pos, f.pos + len);
				bytes(p, chunk.length).set(chunk);
				f.pos += chunk.length;
				total += chunk.length;
				if (chunk.length < len) break;
			}
			view().setUint32(read, total, true);
			return 0;
		},
		fd_seek(fd, offset, whence, out) {
			const f = open.get(fd);
			if (!f) return 8;
			const base = whence === 0 ? 0 : whence === 1 ? f.pos : f.data.length;
			f.pos = Math.max(0, base + Number(offset));
			view().setBigUint64(out, BigInt(f.pos), true);
			return 0;
		},
		fd_tell(fd, out) {
			const f = open.get(fd);
			if (!f) return 8;
			view().setBigUint64(out, BigInt(f.pos), true);
			return 0;
		},
		fd_close(fd) {
			return open.delete(fd) ? 0 : 8;
		},
		proc_exit(code) {
			throw new Exit(code);
		},
	};
	// (-D hxmc.wasm-gc: its strings are arrays of UTF-16 units, read and made through its exports)
	const str = (s) => {
		if (s === null) return null;
		const n = exports.hxmc_str_len(s);
		let out = '';
		for (let i = 0; i < n; i += 4096) {
			const units = [];
			for (let k = i; k < Math.min(n, i + 4096); k++) units.push(exports.hxmc_str_get(s, k));
			out += String.fromCharCode(...units);
		}
		return out;
	};
	const ofJs = (t) => {
		const s = exports.hxmc_str_new(t.length);
		for (let i = 0; i < t.length; i++) exports.hxmc_str_set(s, i, t.charCodeAt(i));
		return s;
	};
	const math = [Math.sin, Math.cos, Math.tan, Math.asin, Math.acos, Math.atan, Math.atan2, Math.exp, Math.log, Math.pow];
	const gc = {
		write: (fd, s) => write(fd === 2 ? 2 : 1, enc.encode(str(s))),
		now: () => performance.now() / 1000,
		fmt: (v) => ofJs(String(v)),
		parseFloat: (s) => parseFloat(str(s)),
		math: (op, x, y) => math[op](x, y),
		random: Math.random,
		// (GcSys's op codes: the environment, the arguments; no files)
		sysStr(op, a) {
			switch (op) {
				case 0: return options.env?.[str(a)] === undefined ? null : ofJs(options.env[str(a)]);
				case 4: return ofJs(args.slice(1).join('\0'));
				case 5: return ofJs(env.join('\0'));
				case 6: return ofJs(args[0]);
				case 8: return ofJs('Wasi');
				default: return null;
			}
		},
		sysNum(op, a, b, n) {
			switch (op) {
				case 7: throw new Exit(n);
				case 8: return Date.now() / 1000;
				case 9: return performance.now() / 1000;
				default: return 0;
			}
		},
		readFile: () => null,
		writeFile: () => 0,
		// (GcSys's descriptors: no files here, but writes to stdout and stderr)
		fileIo(op, fd, x, a, b) {
			if (op !== 2 || (fd !== 1 && fd !== 2)) return -1;
			const buf = new Uint8Array(b);
			for (let i = 0; i < b; i++) buf[i] = exports.hxmc_bytes_get(x, a + i);
			write(fd, buf);
			return b;
		},
		dateNum(op, t, y, m, d, h, mi, s) {
			const date = new Date(t);
			const f = [null, 'FullYear', 'Month', 'Date', 'Day', 'Hours', 'Minutes', 'Seconds'];
			if (op === 0) return new Date(y, m, d, h, mi, s).getTime();
			if (op <= 7) return date['get' + f[op]]();
			if (op <= 14) return date['getUTC' + f[op - 7]]();
			return op === 15 ? date.getTimezoneOffset() : Date.now();
		},
	};
	// (a filestat: a regular file of size bytes)
	function stat(out, size) {
		const v = view();
		for (let k = 0; k < 64; k += 8) v.setBigUint64(out + k, 0n, true);
		v.setUint8(out + 16, 4);
		v.setBigUint64(out + 24, 1n, true);
		v.setBigUint64(out + 32, BigInt(size), true);
	}
	const open = new Map();
	let nextFd = 4;
	const imports = { wasi_snapshot_preview1: new Proxy(wasi, { get: (o, k) => o[k] ?? (() => 52) }), hxmc: gc }; // ENOSYS
	for (const m of options.imports ?? []) {
		const f = typeof m === 'string' ? (await import(new URL(m, document.baseURI).href)).default : m;
		Object.assign(imports, await f(host));
	}
	// (wasm: a URL, a Response, a compiled WebAssembly.Module or the bytes, or a
	// promise of one: a module compiling while the imports above were loading)
	if (wasm && typeof wasm.then === 'function') wasm = await wasm;
	let instance;
	try {
		instance = wasm instanceof WebAssembly.Module ? await WebAssembly.instantiate(wasm, imports)
			: typeof wasm === 'string' || wasm instanceof Response ? (await WebAssembly.instantiateStreaming(typeof wasm === 'string' ? fetch(wasm) : wasm, imports)).instance
			: (await WebAssembly.instantiate(wasm, imports)).instance;
	} catch (e) {
		throw outOfMemory(e, await initialMemory(wasm).catch(() => 0));
	}
	exports = instance.exports;
	memory = exports.memory;
	served = await files;
	try {
		exports._start();
	} catch (e) {
		if (!(e instanceof Exit)) throw outOfMemory(e, 0, memory);
		host.exitCode = e.code;
	}
	return { host, instance, exitCode: host.exitCode ?? 0 };
}

// the files run serves (options.files, options.assets' list), fetched at
// once: a Map of path to bytes, or null without any
async function fetchFiles(options) {
	const urls = Object.entries(options.files ?? {});
	if (options.assets) {
		const base = new URL(options.assets, document.baseURI);
		const list = await (await fetch(base)).json();
		for (const p of list) urls.push([p, new URL(p, base).href]);
	}
	if (urls.length === 0) return null;
	const got = await Promise.all(urls.map(async ([p, u]) => {
		const r = await fetch(u);
		if (!r.ok) throw new Error(`${p}: ${r.status} ${r.statusText}`);
		return [p.replace(/^\.\//, ''), new Uint8Array(await r.arrayBuffer())];
	}));
	return new Map(got);
}

// a RangeError where the browser refused memory, as "out of memory: ..." with
// the size asked (bytes, when known) and the memory in use; e itself otherwise
// (a deep recursion's "Maximum call stack size exceeded" is no memory error)
export function outOfMemory(e, bytes, memory = null) {
	if (!(e instanceof RangeError) || !/memory|alloc/i.test(e.message) || /call stack/i.test(e.message)) return e;
	const mb = (n) => (n / 1048576).toFixed(1) + ' MB';
	const r = new Error('out of memory: ' + (bytes ? 'the browser refused ' + mb(bytes) + ' of WebAssembly memory' : 'the browser refused memory')
		+ (memory ? ' (the module has ' + mb(memory.buffer.byteLength) + ')' : '') + ': ' + e.message, { cause: e });
	r.outOfMemory = true;
	return r;
}

// the initial size of a module's memory (bytes): its memory section's limits
async function initialMemory(wasm) {
	const b = new Uint8Array(wasm instanceof WebAssembly.Module ? [] : typeof wasm === 'string' ? await (await fetch(wasm)).arrayBuffer()
		: wasm instanceof Response ? [] : wasm.buffer ? new Uint8Array(wasm.buffer, wasm.byteOffset, wasm.byteLength) : wasm);
	let p = 8;
	const leb = () => {
		let r = 0, k = 0, x;
		do {
			x = b[p++];
			r += (x & 0x7f) * 2 ** k;
			k += 7;
		} while (x & 0x80);
		return r;
	};
	while (p < b.length) {
		const id = b[p++], size = leb(), end = p + size;
		if (id === 5 && leb() > 0) {
			p++; // (the limits' flags)
			return leb() * 65536;
		}
		p = end;
	}
	return 0;
}
