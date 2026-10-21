package hxmc.wasm;

import hxmc.Obj;
import hxmc.Buf;
import hxmc.wasm.Enc;

// The WebAssembly linker: the program's objects (functions written by
// WasmGen, data by DataGen) to one module, with nothing else linked in (the
// runtime is Haxe compiled with the program; docs/hxmc.md,
// "WebAssembly"). It keeps the functions and data sections reachable from
// _start, lays the data out in linear memory (from 4 KB; then the stack of
// frame slots that runs rt_init, whose end is rt_cstack_lo's first value,
// then the heap the runtime manages from __heap_base; _start then moves the
// stack pointer to the runtime's stack, wasm/Gc.hx),
// numbers the functions (the WASI imports first), puts the functions whose
// address is taken in the table (index 0: null; exported), makes a global of each
// thread-local variable (one thread), writes a few functions itself
// (memcpy and friends as bulk-memory instructions, the f64 rounding
// functions, rt_throw as a throw of the exception tag, memory.size/grow) and
// resolves every relocation.
class LinkWasm {
	public static inline var START = "_start";
	public static inline var HEAP_BASE = "__heap_base";
	public static inline var TABLE = "__indirect_function_table";
	public static inline var DATA_BASE = 4096;

	var objs:Array<Obj>;
	var stackSize:Int;
	var defs = new Map<String, Symbol>(); // global definitions
	var defObj = new Map<Symbol, Obj>();

	// functions by symbol: their index; imports first
	var funcIndex = new Map<String, Int>();
	var funcs:Array<{name:String, sym:Null<Symbol>, sig:String, builtin:Bool}> = [];
	var imports:Array<{name:String, sig:String, module:String}> = [];
	var types:Array<String> = [];
	var typeIndex = new Map<String, Int>();
	var table:Array<String> = [];
	var tableIndex = new Map<String, Int>();
	var globals:Array<String> = [];
	var globalIndex = new Map<String, Int>();
	var addrOf = new Map<Section, Int>(); // data sections' addresses
	var cells = new Map<String, Int>(); // runtime variables the linker defines (8 bytes, zero)
	var heapBase = 0;
	public var nameSection = false;
	public var legacyEh = false; // legacy exception handling (WasmGen): no exnref global
	var stackTop = 0;

	// WASI preview 1 (the functions the runtime imports): signatures
	public static var WASI:Map<String, String> = [
		"args_get" => "ii>i", "args_sizes_get" => "ii>i", "environ_get" => "ii>i", "environ_sizes_get" => "ii>i",
		"clock_time_get" => "ili>i", "clock_res_get" => "ii>i", "fd_write" => "iiii>i", "fd_read" => "iiii>i", "fd_close" => "i>i",
		"fd_seek" => "ilii>i", "fd_tell" => "ii>i", "fd_filestat_get" => "ii>i", "fd_fdstat_get" => "ii>i", "fd_prestat_get" => "ii>i",
		"fd_prestat_dir_name" => "iii>i", "fd_readdir" => "iiili>i", "fd_sync" => "i>i", "fd_filestat_set_size" => "il>i",
		"path_open" => "iiiiillii>i", "path_filestat_get" => "iiiii>i", "path_create_directory" => "iii>i",
		"path_remove_directory" => "iii>i", "path_unlink_file" => "iii>i", "path_rename" => "iiiiii>i", "proc_exit" => "i>v",
		"random_get" => "ii>i", "sched_yield" => ">i", "poll_oneoff" => "iiii>i",
	];

	// runtime variables the runtime's Haxe code exports on the native targets (DataGen's code refers to them)
	// (name => bytes, zeroed)
	static var CELLS:Map<String, Int> = [
		"rt_globals" => 8, "rt_young_start" => 8, "rt_young_end" => 8, "rt_argc" => 8, "rt_argv" => 8, "rt_nthreads" => 8,
		"rt_sp_limit" => 8, // the shadow stack's end (MirBuild.raiseHw)
	];

	public function new(objs:Array<Obj>, stackSize = 64 << 10) {
		this.objs = objs;
		this.stackSize = stackSize;
	}

	function resolve(o:Obj, s:Symbol):Null<Symbol> {
		if (s.section != null || s.abs) return s;
		return defs.get(s.name);
	}

	static function isCode(s:Section):Bool
		return s.name == WasmGen.SECTION;

	public function link():haxe.io.Bytes {
		for (o in objs)
			for (s in o.symbols)
				if ((s.section != null || s.abs) && s.global) {
					if (defs.exists(s.name)) throw 'hxmc: symbol ${s.name} defined twice';
					defs.set(s.name, s);
					defObj.set(s, o);
				}
		for (o in objs)
			for (s in o.symbols)
				if (s.section != null && !s.global) defObj.set(s, o);
		// reachability from _start: functions (by symbol) and data sections
		var liveFn = new Map<Symbol, Bool>();
		var liveSec = new Map<Section, Bool>();
		var undefinedFns = new Map<String, Bool>();
		var undefinedData = new Map<String, Bool>();
		var start = defs.get(START);
		if (start == null) throw "hxmc: no _start";
		var work:Array<Symbol> = [start];
		var secWork:Array<{o:Obj, s:Section}> = [];
		liveFn.set(start, true);
		var codeRelocs = new Map<Symbol, Array<Reloc>>();
		// relocations of each function (code sections: by offset)
		for (o in objs)
			for (sec in o.sections)
				if (isCode(sec)) {
					var fs = [for (s in o.symbols) if (s.section == sec) s];
					fs.sort((a, b) -> a.offset - b.offset);
					var rs = sec.relocs.copy();
					rs.sort((a, b) -> a.offset - b.offset);
					var k = 0;
					for (fsym in fs) {
						var list = [];
						while (k < rs.length && rs[k].offset < fsym.offset + fsym.size) {
							if (rs[k].offset >= fsym.offset) list.push(rs[k]);
							k++;
						}
						codeRelocs.set(fsym, list);
					}
				}
		function reach(o:Obj, r:Reloc, fromCode:Bool) {
			if (r.kind == RWasmType || r.kind == RWasmGlobal) return;
			var t = resolve(o, r.sym);
			if (t == null) {
				if (r.kind == RWasmFunc) {
					if (!undefinedFns.exists(r.sym.name))
						for (c in Builtins.calls(r.sym.name)) {
							var cs = defs.get(c);
							if (cs != null && !liveFn.exists(cs)) {
								liveFn.set(cs, true);
								work.push(cs);
							}
						}
					undefinedFns.set(r.sym.name, true);
				} else
					undefinedData.set(r.sym.name, true);
				return;
			}
			if (t.abs) return;
			if (isCode(t.section)) {
				if (!liveFn.exists(t)) {
					liveFn.set(t, true);
					work.push(t);
				}
			} else if (!liveSec.exists(t.section)) {
				liveSec.set(t.section, true);
				secWork.push({o: defObj.get(t), s: t.section});
			}
		}
		while (work.length > 0 || secWork.length > 0) {
			if (work.length > 0) {
				var f = work.pop();
				var o = defObj.get(f);
				for (r in codeRelocs.get(f))
					reach(o, r, true);
			} else {
				var x = secWork.pop();
				for (r in x.s.relocs)
					reach(x.o, r, false);
			}
		}
		// builtins and imports for the undefined functions
		var missing = [];
		var names = [for (n in undefinedFns.keys()) n];
		names.sort(cmpStr);
		for (n in names) {
			if (WASI.exists(n)) imports.push({name: n, sig: WASI.get(n), module: "wasi_snapshot_preview1"});
			else if (hxmc.ir.CInterop.USER.exists(n)) {
				// a C function the program declares (@:hxmc.c): an import of the
				// module its @:hxmc.lib names, "env" by default
				var lib = hxmc.ir.CInterop.LIBS.get(n);
				imports.push({name: n, sig: WasmGen.importSig(n), module: lib != null ? lib : "env"});
			} else if (!Builtins.has(n)) missing.push(n);
		}
		for (n in [for (n in undefinedData.keys()) n])
			if (!CELLS.exists(n) && n != HEAP_BASE && !undefinedFns.exists(n) && !Builtins.has(n)) missing.push(n);
		if (missing.length > 0) {
			missing.sort(cmpStr);
			throw "hxmc: wasm: undefined: " + missing.join(", ");
		}
		for (im in imports) {
			funcIndex.set(im.name, funcs.length);
			funcs.push({name: im.name, sym: null, sig: im.sig, builtin: false});
		}
		// defined functions in object order (stable), then the builtins
		for (o in objs)
			for (s in o.symbols)
				if (s.section != null && isCode(s.section) && liveFn.exists(s)) {
					funcIndex.set(s.name, funcs.length);
					funcs.push({name: s.name, sym: s, sig: sigAt(s), builtin: false});
				}
		for (n in names)
			if (!WASI.exists(n) && !hxmc.ir.CInterop.USER.exists(n)) {
				funcIndex.set(n, funcs.length);
				funcs.push({name: n, sym: null, sig: Builtins.sig(n), builtin: true});
			}
		// builtins may call functions of the program (rt_throw: hx_uncaught)
		for (f in funcs)
			if (f.builtin)
				for (n in Builtins.calls(f.name))
					if (!funcIndex.exists(n)) throw "hxmc: wasm: " + f.name + " needs " + n;
		// memory: data, bss, cells, the stack, the heap
		var at = DATA_BASE;
		var dataSecs:Array<Section> = [];
		for (pass in 0...2)
			for (o in objs)
				for (sec in o.sections) {
					if (isCode(sec) || !liveSec.exists(sec)) continue;
					var bss = sec.kind == Bss || sec.kind == Tbss;
					if (bss != (pass == 1)) continue;
					var al = sec.align < 8 ? 8 : sec.align;
					at = (at + al - 1) & ~(al - 1);
					addrOf.set(sec, at);
					at += sec.size();
					if (!bss) dataSecs.push(sec);
				}
		var cn = [for (n in CELLS.keys()) n];
		cn.sort(cmpStr);
		for (n in cn) {
			at = (at + 7) & ~7;
			cells.set(n, at);
			at += CELLS.get(n);
		}
		at = (at + 15) & ~15;
		at += stackSize;
		stackTop = at;
		heapBase = (at + 0xffff) & ~0xffff;
		// the table: functions whose address is taken (code and data)
		for (f in funcs)
			if (f.sym != null)
				for (r in codeRelocs.get(f.sym))
					if (r.kind == RWasmAddr || r.kind == RWasmAddr32) tableEntry(defObj.get(f.sym), r.sym);
		for (o in objs)
			for (sec in o.sections)
				if (!isCode(sec) && liveSec.exists(sec))
					for (r in sec.relocs)
						tableEntry(o, r.sym);
		// globals: the stack pointer, then the thread-local variables
		global(WasmGen.SP);
		for (f in funcs) {
			if (f.sym != null) {
				for (r in codeRelocs.get(f.sym))
					if (r.kind == RWasmGlobal) global(r.sym.name);
			} else if (f.builtin)
				for (g in Builtins.globals(f.name, legacyEh))
					global(g);
		}
		// types
		for (f in funcs)
			typeOf(f.sig);
		typeOf(">v"); // the exception tag
		for (f in funcs)
			if (f.sym != null)
				for (r in codeRelocs.get(f.sym))
					if (r.kind == RWasmType) typeOf(r.sym.name.substr(3));
		// the module
		var m = new Buf(1 << 16);
		m.u32(0x6d736100);
		m.u32(1);
		var s = new Buf(1024);
		// types
		Enc.uleb(s, types.length);
		for (t in types) {
			var gt = t.indexOf(">");
			s.u8(0x60);
			Enc.uleb(s, gt);
			for (k in 0...gt)
				s.u8(charTy(t.charAt(k)));
			var r = t.charAt(gt + 1);
			if (r == "v") s.u8(0) else {
				s.u8(1);
				s.u8(charTy(r));
			}
		}
		section(m, 1, s);
		// imports
		s = new Buf(256);
		Enc.uleb(s, imports.length);
		for (im in imports) {
			Enc.name(s, im.module);
			Enc.name(s, im.name);
			s.u8(0);
			Enc.uleb(s, typeIndex.get(im.sig));
		}
		section(m, 2, s);
		// functions
		s = new Buf(1024);
		Enc.uleb(s, funcs.length - imports.length);
		for (k in imports.length...funcs.length)
			Enc.uleb(s, typeIndex.get(funcs[k].sig));
		section(m, 3, s);
		// table
		s = new Buf(16);
		s.u8(1);
		s.u8(0x70); // funcref
		s.u8(0);
		Enc.uleb(s, table.length + 1);
		section(m, 4, s);
		// memory
		s = new Buf(16);
		s.u8(1);
		s.u8(0);
		Enc.uleb(s, (heapBase >> 16) + 1);
		section(m, 5, s);
		// tag
		s = new Buf(16);
		s.u8(1);
		s.u8(0);
		Enc.uleb(s, typeIndex.get(">v"));
		section(m, 13, s);
		// globals
		s = new Buf(256);
		Enc.uleb(s, globals.length);
		for (g in globals) {
			if (g == WasmGen.EXNREF) {
				// (mut exnref) (ref.null exn)
				s.u8(Enc.EXNREF);
				s.u8(1);
				s.u8(Op.RefNull);
				s.u8(Enc.EXNREF);
				s.u8(Op.End);
				continue;
			}
			s.u8(Enc.I64);
			s.u8(1);
			s.u8(Op.I64Const);
			Enc.sleb(s, g == WasmGen.SP ? stackTop : g == WasmGen.STACK_LO ? stackTop - stackSize : 0);
			s.u8(Op.End);
		}
		section(m, 6, s);
		// exports: the memory, _start and the table (the host calls a
		// @:hxmc.callback through the address it was given, also after _start
		// returned: docs/plans/lowlevel.md, "WebAssembly")
		s = new Buf(64);
		Enc.uleb(s, 3);
		Enc.name(s, "memory");
		s.u8(2);
		s.u8(0);
		Enc.name(s, START);
		s.u8(0);
		Enc.uleb(s, funcIndex.get(START));
		Enc.name(s, TABLE);
		s.u8(1);
		s.u8(0);
		section(m, 7, s);
		// elements: the table from index 1
		if (table.length > 0) {
			s = new Buf(1024);
			s.u8(1);
			s.u8(0);
			s.u8(Op.I32Const);
			Enc.sleb(s, 1);
			s.u8(Op.End);
			Enc.uleb(s, table.length);
			for (n in table)
				Enc.uleb(s, funcIndex.get(n));
			section(m, 9, s);
		}
		var segs = dataSegments(dataSecs);
		// data count
		s = new Buf(8);
		Enc.uleb(s, segs.length);
		section(m, 12, s);
		// code
		s = new Buf(1 << 20);
		Enc.uleb(s, funcs.length - imports.length);
		for (k in imports.length...funcs.length) {
			var f = funcs[k];
			if (f.builtin) {
				Enc.sized(s, Builtins.get(f.name, this));
				continue;
			}
			var sym = f.sym;
			var buf = sym.section.buf;
			var o = defObj.get(sym);
			var np = buf.get8(sym.offset);
			var sizeAt = sym.offset + np + 2;
			var bodyStart = sizeAt + 5;
			var bodyLen = readLeb5(buf, sizeAt);
			var out = new Buf(bodyLen + 16);
			var pos = bodyStart;
			for (r in codeRelocs.get(sym)) {
				out.bytes(buf.b, pos, r.offset - pos);
				switch r.kind {
					case RWasmFunc:
						Enc.uleb(out, funcOf(o, r.sym));
						pos = r.offset + 5;
					case RWasmType:
						Enc.uleb(out, typeIndex.get(r.sym.name.substr(3)));
						pos = r.offset + 5;
					case RWasmGlobal:
						Enc.uleb(out, globalIndex.get(r.sym.name));
						pos = r.offset + 5;
					case RWasmAddr:
						Enc.sleb(out, value(o, r.sym) + r.addend);
						pos = r.offset + 10;
					case RWasmAddr32:
						Enc.sleb(out, value(o, r.sym) + r.addend);
						pos = r.offset + 5;
					case _:
						throw "hxmc: wasm: relocation kind " + r.kind + " in code";
				}
			}
			out.bytes(buf.b, pos, bodyStart + bodyLen - pos);
			Enc.sized(s, out);
		}
		section(m, 10, s);
		// data
		s = new Buf(1 << 16);
		Enc.uleb(s, segs.length);
		for (g in segs) {
			s.u8(0);
			s.u8(Op.I32Const);
			Enc.sleb(s, g.at);
			s.u8(Op.End);
			Enc.uleb(s, g.len);
			s.bytes(g.img, g.pos, g.len);
		}
		section(m, 11, s);
		// the function names (a "name" section): HXMC_SYMBOLS=1 or -debug
		if (nameSection) {
			s = new Buf(1 << 16);
			Enc.name(s, "name");
			var sub = new Buf(1 << 16);
			Enc.uleb(sub, funcs.length);
			for (k in 0...funcs.length) {
				Enc.uleb(sub, k);
				Enc.name(sub, funcs[k].name);
			}
			s.u8(1);
			Enc.sized(s, sub);
			section(m, 0, s);
		}
		return m.toBytes();
	}

	static function cmpStr(a:String, b:String):Int
		return a < b ? -1 : a > b ? 1 : 0;

	static function readLeb5(b:Buf, at:Int):Int {
		var v = 0;
		for (k in 0...5)
			v |= (b.get8(at + k) & 0x7f) << (7 * k);
		return v;
	}

	static function sigAt(s:Symbol):String {
		var b = s.section.buf;
		var np = b.get8(s.offset);
		var r = new StringBuf();
		for (k in 0...np)
			r.add(codeChar(b.get8(s.offset + 1 + k)));
		r.add(">");
		var rt = b.get8(s.offset + 1 + np);
		r.add(rt == Enc.VOID ? "v" : codeChar(rt));
		return r.toString();
	}

	static function codeChar(c:Int):String
		return c == Enc.I32 ? "i" : c == Enc.I64 ? "l" : c == Enc.F64 ? "d" : c == Enc.F32 ? "f" : "?";

	static function charTy(c:String):Int
		return c == "i" ? Enc.I32 : c == "l" ? Enc.I64 : c == "d" ? Enc.F64 : c == "f" ? Enc.F32 : throw "hxmc: wasm: type " + c;

	public function typeOf(sig:String):Int {
		var t = typeIndex.get(sig);
		if (t == null) {
			t = types.length;
			types.push(sig);
			typeIndex.set(sig, t);
		}
		return t;
	}

	function global(n:String) {
		if (globalIndex.exists(n)) return;
		globalIndex.set(n, globals.length);
		globals.push(n);
	}

	public function globalOf(n:String):Int
		return globalIndex.get(n);

	public function funcIndexOf(n:String):Int
		return funcIndex.get(n);

	function tableEntry(o:Obj, s:Symbol) {
		var t = resolve(o, s);
		if (t == null) {
			if (!funcIndex.exists(s.name) || tableIndex.exists(s.name)) return;
		} else if (t.abs || !isCode(t.section) || tableIndex.exists(t.name)) return;
		var n = t == null ? s.name : t.name;
		if (tableIndex.exists(n)) return;
		tableIndex.set(n, table.length + 1);
		table.push(n);
	}

	function funcOf(o:Obj, s:Symbol):Int {
		var t = resolve(o, s);
		var n = t == null ? s.name : t.name;
		var i = funcIndex.get(n);
		if (i == null) throw "hxmc: wasm: no function " + n;
		return i;
	}

	// the initialized data as active segments: the sections' image in memory
	// (relocated), split at runs of ZERO_RUN zero bytes or more (padding, the
	// upper halves of 8-byte slots): memory starts zeroed. A segment's header
	// is about 8 bytes, but zeros compress well: on the playground's module 16
	// gives 855 KB less raw and 23 KB more gzipped than one segment per
	// section, 64 gives 757 KB less raw and 17 KB more gzipped, 256 203 KB and
	// 2 KB less
	static inline var ZERO_RUN = 64;

	function dataSegments(dataSecs:Array<Section>):Array<{img:haxe.io.Bytes, pos:Int, at:Int, len:Int}> {
		var segs = [];
		if (dataSecs.length == 0) return segs;
		var lo = addrOf.get(dataSecs[0]), hi = lo;
		for (sec in dataSecs) {
			var a = addrOf.get(sec);
			if (a < lo) lo = a;
			if (a + sec.size() > hi) hi = a + sec.size();
		}
		var img = haxe.io.Bytes.alloc(hi - lo);
		img.fill(0, hi - lo, 0);
		for (sec in dataSecs) {
			var o = null;
			for (x in objs)
				if (x.sections.indexOf(sec) >= 0) o = x;
			var base = addrOf.get(sec) - lo;
			var bytes = sec.buf.toBytes();
			img.blit(base, bytes, 0, bytes.length);
			for (r in sec.relocs) {
				if (r.kind != RAbs64) throw "hxmc: wasm: relocation kind " + r.kind + " in data";
				var v = value(o, r.sym) + r.addend;
				img.setInt32(base + r.offset, v);
				img.setInt32(base + r.offset + 4, v < 0 ? -1 : 0);
			}
		}
		var n = hi - lo, k = 0;
		while (k < n) {
			while (k < n && img.get(k) == 0)
				k++;
			if (k == n) break;
			var start = k, end = k, zeros = 0;
			while (k < n) {
				if (img.get(k) == 0) {
					if (++zeros >= ZERO_RUN) break;
				} else {
					zeros = 0;
					end = k + 1;
				}
				k++;
			}
			segs.push({img: img, pos: start, at: lo + start, len: end - start});
		}
		return segs;
	}

	// a relocation's value: a data address, a function's table index or an absolute value
	function value(o:Obj, s:Symbol):Int {
		var t = resolve(o, s);
		if (t == null) {
			if (s.name == HEAP_BASE) return heapBase;
			if (cells.exists(s.name)) return cells.get(s.name);
			if (tableIndex.exists(s.name)) return tableIndex.get(s.name);
			throw "hxmc: wasm: undefined " + s.name;
		}
		if (t.abs) return t.offset;
		if (isCode(t.section)) return tableIndex.get(t.name);
		return addrOf.get(t.section) + t.offset;
	}

	static function section(m:Buf, id:Int, s:Buf) {
		m.u8(id);
		Enc.sized(m, s);
	}
}

// Functions the linker writes: WebAssembly instructions for what the C
// library provides on the native targets.
class Builtins {
	static var SIGS:Map<String, String> = [
		"memcpy" => "lll>l", "memmove" => "lll>l", "memset" => "lil>l", "floor" => "d>d", "ceil" => "d>d", "trunc" => "d>d",
		"sqrt" => "d>d", "fabs" => "d>d", "rint" => "d>d", "nearbyint" => "d>d", "fmin" => "dd>d", "fmax" => "dd>d",
		"copysign" => "dd>d", "rt_throw" => "l>v", "wasm_memory_size" => ">i", "wasm_memory_grow" => "i>i", "wasm_unreachable" => ">v",
	];

	public static function has(n:String):Bool
		return SIGS.exists(n);

	static final THROW_CALLS:haxe.ds.Vector<String> = core.ds.VectorTools.vector("hx_uncaught");
	static final THROW_GLOBALS:haxe.ds.Vector<String> = core.ds.VectorTools.vector("rt_exn", WasmGen.HANDLER, WasmGen.EXNREF);
	static final THROW_GLOBALS_LEGACY:haxe.ds.Vector<String> = core.ds.VectorTools.vector("rt_exn", WasmGen.HANDLER);
	static final NONE:haxe.ds.Vector<String> = core.ds.VectorTools.vector();

	// the program's functions a builtin calls
	public static function calls(n:String):haxe.ds.Vector<String>
		return n == "rt_throw" ? THROW_CALLS : NONE;

	public static function globals(n:String, legacyEh:Bool):haxe.ds.Vector<String>
		return n == "rt_throw" ? (legacyEh ? THROW_GLOBALS_LEGACY : THROW_GLOBALS) : NONE;

	public static function sig(n:String):String
		return SIGS.get(n);

	public static function get(n:String, l:LinkWasm):Buf {
		var b = new Buf(32);
		b.u8(0); // no locals
		inline function o(x:Op)
			b.u8(x);
		inline function lget(k:Int) {
			o(Op.LocalGet);
			Enc.uleb(b, k);
		}
		switch n {
			case "memcpy" | "memmove":
				lget(0);
				o(Op.I32WrapI64);
				lget(1);
				o(Op.I32WrapI64);
				lget(2);
				o(Op.I32WrapI64);
				o(Op.Prefix);
				Enc.uleb(b, 10);
				b.u8(0);
				b.u8(0);
				lget(0);
			case "memset":
				lget(0);
				o(Op.I32WrapI64);
				lget(1);
				lget(2);
				o(Op.I32WrapI64);
				o(Op.Prefix);
				Enc.uleb(b, 11);
				b.u8(0);
				lget(0);
			case "floor" | "ceil" | "trunc" | "sqrt" | "fabs" | "rint" | "nearbyint":
				lget(0);
				o(switch n {
					case "floor": Op.F64Floor;
					case "ceil": Op.F64Ceil;
					case "trunc": Op.F64Trunc;
					case "sqrt": Op.F64Sqrt;
					case "fabs": Op.F64Abs;
					case _: Op.F64Nearest;
				});
			case "fmin" | "fmax" | "copysign":
				lget(0);
				lget(1);
				o(n == "fmin" ? Op.F64Min : n == "fmax" ? Op.F64Max : Op.F64Copysign);
			case "wasm_memory_size":
				o(Op.MemorySize);
				b.u8(0);
			case "wasm_memory_grow":
				lget(0);
				o(Op.MemoryGrow);
				b.u8(0);
			case "wasm_unreachable":
				o(Op.Unreachable);
			case "rt_throw":
				// rt_exn = v; no handler: the uncaught report (it exits)
				lget(0);
				o(Op.GlobalSet);
				Enc.uleb(b, l.globalOf("rt_exn"));
				o(Op.GlobalGet);
				Enc.uleb(b, l.globalOf(WasmGen.HANDLER));
				o(Op.I64Eqz);
				o(Op.If);
				b.u8(Enc.VOID);
				lget(0);
				o(Op.Call);
				Enc.uleb(b, l.funcIndexOf("hx_uncaught"));
				o(Op.End);
				if (l.legacyEh) {
					// (legacy exception handling: a new exception each time)
					o(Op.Throw);
					b.u8(0);
					o(Op.End);
					return b;
				}
				// an exception a pad caught before, thrown again (throw_ref):
				// the Haxe exception is rt_exn, the wasm one only carries it,
				// and engines that make an object with a stack trace for each
				// `throw` (SpiderMonkey: about 20 us) do nothing of the kind
				o(Op.GlobalGet);
				Enc.uleb(b, l.globalOf(WasmGen.EXNREF));
				o(Op.RefIsNull);
				o(Op.I32Eqz);
				o(Op.If);
				b.u8(Enc.VOID);
				o(Op.GlobalGet);
				Enc.uleb(b, l.globalOf(WasmGen.EXNREF));
				o(Op.ThrowRef);
				o(Op.End);
				o(Op.Throw);
				b.u8(0);
			case _:
				throw "hxmc: wasm: no builtin " + n;
		}
		o(Op.End);
		return b;
	}
}
