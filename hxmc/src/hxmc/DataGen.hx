package hxmc;

import hxmc.ir.Facts;
import hxmc.ir.Ir;
import hxmc.Mir;
import hxmc.Obj;
import haxe.ds.Vector;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

// The program's data, as sections of an Obj: the type table rt_types
// and its field/method/static/pointer-map arrays, dispatch rows, field
// names, string literals, scalar globals, the per-signature trampolines
// (DYN<s>, BT<s>) and main.
@:access(hxmc.ir.Facts)
@:access(hxmc.MirBuild)
class DataGen {
	// iOS: the app's main (packages/os), run by the generated main instead
	// of the program's body, which it calls itself (mainBody)
	public static inline var UI_MAIN = "hxmc_ui_main";

	var prep:Prep;
	var e:Facts;
	var p:Program;
	var obj:Obj;
	var data:Section;
	var rodata:Section;
	var bss:Section;
	var compile:MFunc->Void;
	var abi:Abi;
	var cstrs = new Map<String, Symbol>();
	var ncstr = 0;
	var nlocal = 0;
	// -D hxmc.jit: zeroed entries after rt_types and the signature tables, filled
	// at run time by the types and signatures of native macros (hxmc.macro.Loader)
	public var spareTypes = 0;
	public var spareSigs = 0;

	public function new(prep:Prep, abi:Abi, obj:Obj, compile:MFunc->Void) {
		this.prep = prep;
		this.abi = abi;
		e = prep.e;
		p = prep.p;
		this.obj = obj;
		this.compile = compile;
		data = obj.section(".data", Data, 16);
		rodata = obj.section(".rodata", RoData, 16);
		bss = obj.section(".bss", Bss, 16);
	}

	// ---- helpers

	function ptr(sec:Section, sym:String, addend = 0) {
		sec.relocs.push(new Reloc(sec.buf.len, RAbs64, obj.sym(sym), addend));
		sec.buf.u64(0, 0);
	}

	function ptrSym(sec:Section, sym:Symbol, addend = 0) {
		sec.relocs.push(new Reloc(sec.buf.len, RAbs64, sym, addend));
		sec.buf.u64(0, 0);
	}

	// a NUL-terminated UTF-8 string in .rodata
	function cstr(s:String):Symbol {
		var r = cstrs.get(s);
		if (r != null) return r;
		var off = rodata.buf.len;
		rodata.buf.str(s);
		rodata.buf.u8(0);
		r = obj.define(".Lstr" + ncstr++, rodata, off, 0, false);
		cstrs.set(s, r);
		return r;
	}

	function begin(sec:Section, name:String, align:Int, global:Bool):Symbol {
		sec.buf.align(align);
		return obj.define(name, sec, sec.buf.len, 0, global);
	}

	function local(sec:Section, prefix:String, align:Int):Symbol
		return begin(sec, ".L" + prefix + nlocal++, align, false);

	function int32Global(name:String, v:Int) {
		rodata.buf.align(4);
		obj.define(name, rodata, rodata.buf.len, 4, true);
		rodata.buf.u32(v);
	}

	// a @:hxmc.threadLocal static: 8 zero bytes per thread
	// (Mach-O: the symbol names a descriptor in __thread_vars, as C's do,
	// whose third word refers to the storage in __thread_bss)
	function tbssGlobal(name:String) {
		var macho = abi.os == "macos";
		// (PE: inside the C runtime's TLS template, which runs from _tls_start
		// in .tls to _tls_end in .tls$ZZZ: sections sort by name)
		var s = obj.section(macho ? "__DATA,__thread_bss" : abi.os == "windows" ? ".tls$HXMC" : ".tbss", Tbss, 8);
		s.bssSize = (s.bssSize + 7) & ~7;
		var storage = obj.define(macho ? name + "$tlv$init" : name, s, s.bssSize, 8, !macho);
		s.bssSize += 8;
		if (macho) {
			var d = obj.section("__DATA,__thread_vars", Data, 8);
			var at = d.buf.len;
			d.buf.zeros(24);
			d.relocs.push(new Reloc(at, RAbs64, obj.sym("_tlv_bootstrap"), 0));
			d.relocs.push(new Reloc(at + 16, RAbs64, storage, 0));
			obj.define(name, d, at, 24, true);
		}
	}

	function bssGlobal(name:String, size:Int, align:Int, global = true) {
		bss.bssSize = (bss.bssSize + align - 1) & ~(align - 1);
		obj.define(name, bss, bss.bssSize, size, global);
		bss.bssSize += size;
	}

	static function kindChar(t:Ty):Int
		return switch t {
			case TI32: "i".code;
			case TBool: "b".code;
			case TF64: "f".code;
			case TI64: "l".code;
			case _: "p".code;
		};

	static final TKS:Vector<String> = vector("TK_RUNTIME", "TK_CLASS", "TK_INTERFACE", "TK_ENUM", "TK_CTOR", "TK_ANON", "TK_CLOSURE", "TK_BOUND");

	static function tk(s:String):Int
		return TKS.indexOf(s);

	// ---- everything

	// the bytes of each part (HXMC_STATS)
	public var sizes:Array<{part:String, bytes:Int}> = [];

	public function run() {
		function part(name:String, f:() -> Void) {
			var at = data.buf.len + rodata.buf.len;
			f();
			sizes.push({part: name, bytes: data.buf.len + rodata.buf.len - at});
		}
		ids();
		part('${e.strOrder.length} strings', strings);
		part('${e.fieldNames.length} field names', fieldNames);
		part('${p.sigs.length} signatures', signatures);
		globals();
		part('${e.types.length} types', types);
		part('${p.selectors.length} dispatch rows', dispatch);
		if (prep.staticClosures) closures();
		mainBody();
	}

	// the program-wide numbers as absolute symbols (Prep.tySym...)
	function ids() {
		for (n in e.idOrder)
			obj.defineAbs(n, e.ids.get(n));
		for (g in 0...p.globals.length)
			if (Ir.isRef(p.globals[g].ty)) obj.defineAbs(prep.globalOffSym(g), 8 * g);
		for (c in p.classes)
			obj.defineAbs(prep.spanSym(c), c.lastDescendant - c.id);
		// the type objects: slots of rt_type_objs (bss, see types())
		bss.bssSize = (bss.bssSize + 15) & ~15;
		typeObjs = bss.bssSize;
		var n = e.types.length;
		obj.define("rt_type_objs", bss, typeObjs, 8 * 2 * (n + spareTypes), true);
		for (t in 0...n)
			obj.define(prep.typeObjSym(t), bss, typeObjs + 8 * (2 * t + 1), 8, true);
		bss.bssSize += 8 * 2 * (n + spareTypes);
	}

	var typeObjs = 0;

	function strings() {
		for (s in e.strOrder) {
			var n = e.strNames.get(s);
			var units = [for (i in 0...s.length) s.charCodeAt(i)];
			var nslots = Std.int((8 + 2 * units.length + 7) / 8);
			data.buf.align(8);
			obj.define(n, data, data.buf.len, 8 + 8 + 2 * (units.length + 1), true);
			// MKHDR(nslots, K_RAW, T_STRING)
			data.buf.u64(nslots | (Abi.K_RAW << 28), 1);
			data.buf.u32(s.length);
			data.buf.u32(0);
			for (u in units)
				data.buf.u16(u);
			data.buf.u16(0);
		}
	}

	function fieldNames() {
		var names = e.fieldNames;
		var syms = [for (n in names) cstr(n)];
		begin(data, "rt_field_names", 8, true);
		for (s in syms)
			ptrSym(data, s);
		int32Global("rt_nfield_names", names.length);
	}

	// (the trampolines of the signatures closures have: Facts.closureSigs,
	// boundTypes; -D hxmc.jit: every signature's, for the native macros')
	function signatures() {
		var all = spareSigs > 0;
		for (s in p.sigs) {
			if (all || e.closureSigs.exists(s.id)) compile(dynTrampoline(s));
			if (all || e.boundTypes.exists(s.id)) compile(boundTrampoline(s));
		}
		begin(data, "rt_dyncalls", 8, true);
		for (s in p.sigs)
			if (all || e.closureSigs.exists(s.id)) ptr(data, "DYN" + s.id) else data.buf.u64(0, 0);
		data.buf.zeros(8 * spareSigs);
		var keys = [for (s in p.sigs) cstr(s.key)];
		begin(data, "rt_sig_keys", 8, true);
		for (k in keys)
			ptrSym(data, k);
		data.buf.zeros(8 * spareSigs);
		int32Global("rt_nsigs", p.sigs.length);
		begin(data, "rt_bound_tramps", 8, true);
		for (s in p.sigs)
			if (all || e.boundTypes.exists(s.id)) ptr(data, "BT" + s.id) else data.buf.u64(0, 0);
		data.buf.zeros(8 * spareSigs);
		var bt = spareSigs > 0 ? data : rodata;
		bt.buf.align(4);
		obj.define("rt_bound_types", bt, bt.buf.len, 4 * (p.sigs.length + spareSigs), true);
		for (s in p.sigs)
			bt.buf.u32(e.boundTypes.exists(s.id) ? e.boundTypes.get(s.id) : 0);
		bt.buf.zeros(4 * spareSigs);
	}

	// DYN<s>(c, args): calls closure c with the boxed arguments args[i], boxes the result
	function dynTrampoline(s:SigInfo):MFunc {
		return MirBuild.synthetic(prep, abi, "DYN" + s.id, vector(I64, I64), I64, (b, ps) -> {
			var c = ps[0], args = ps[1];
			var xs = new Vector<Int>(s.args.length + 1);
			xs[0] = c;
			for (i in 0...s.args.length)
				xs[i + 1] = b.unboxTo(s.args[i], b.load(I64, 8, args, 8 * i));
			var fp = b.load(I64, 8, c, 0);
			var r = b.callInd(fp, xs, MirBuild.mty(s.ret), sigParams(s));
			b.ret(s.ret == TVoid ? b.lconst(0, 0) : b.boxFrom(s.ret, r));
		});
	}

	// BT<s>(c, args...): the code of bound-method closures: FP(c, 2)(FP(c, 1), args...)
	function boundTrampoline(s:SigInfo):MFunc {
		var params = sigParams(s);
		return MirBuild.synthetic(prep, abi, "BT" + s.id, params, MirBuild.mty(s.ret), (b, ps) -> {
			var c = ps[0];
			var fp = b.load(I64, 8, c, 16);
			var self = b.load(I64, 8, c, 8);
			var r = b.callInd(fp, ps.withFirst(self), MirBuild.mty(s.ret), params);
			b.ret(s.ret == TVoid ? -1 : r);
		});
	}

	// the parameter types of a closure's code: the closure, then the signature's
	static function sigParams(s:SigInfo):Vector<MTy> {
		var tys = new Vector<MTy>(s.args.length + 1);
		tys[0] = I64;
		for (k in 0...s.args.length)
			tys[k + 1] = MirBuild.mty(s.args[k]);
		return tys;
	}

	function globals() {
		for (i in 0...p.globals.length) {
			var t = p.globals[i].ty;
			if (p.globals[i].bss != null) bssGlobal(p.globals[i].sym, p.globals[i].bss, 64) else if (p.globals[i].tls != null && !abi.wasm) tbssGlobal(p.globals[i].tls) else if (!Ir.isRef(t)) bssGlobal(e.scalarGlobal(i), t == TI32 || t == TBool ? 4 : 8, 8);
		}
	}

	function types() {
		var types:Array<hxmc.ir.Facts.TypeEntry> = e.types;
		// (the statics Reach kept, in the order Type.getClassFields lists them: each entry's rank)
		var staticsOf = new Map<Int, Array<StaticEntry>>();
		for (cs in [p.classes, p.interfaces])
			for (c in cs)
				if (c.statics != null && c.statics.length > 0) staticsOf.set(c.tindex, c.statics);
		// the arrays each entry points to, then the table
		var entries = [];
		for (i in 0...types.length) {
			var t = types[i];
			var ss = staticsOf.get(i);
			var ssSym = null, pmSym = null, fsSym = null, msSym = null, ifSym = null, ctSym = null;
			if (ss != null) {
				var rank = [for (k in 0...ss.length) ss[k].name => k];
				ss = ss.copy();
				ss.sort((a, b) -> e.fid(a.name) - e.fid(b.name));
				ssSym = local(data, "ss", 8);
				for (x in ss) {
					data.buf.u32(e.fid(x.name));
					if (x.clos != null) {
						data.buf.u32("c".code);
						data.buf.u32(x.clos.tindex);
						data.buf.u32(rank[x.name]);
						ptr(data, e.symbol(x.clos.fn));
					} else {
						var gt = p.globals[x.global].ty;
						if (Ir.isRef(gt)) {
							data.buf.u32("p".code);
							data.buf.u32(x.global);
							data.buf.u32(rank[x.name]);
							data.buf.u64(0, 0);
						} else {
							data.buf.u32(kindChar(gt));
							data.buf.u32(-1);
							data.buf.u32(rank[x.name]);
							ptr(data, e.scalarGlobal(x.global));
						}
					}
				}
			}
			var n = t.slots.length;
			var nwords = Std.int((n + 63) / 64);
			if (nwords > 0) {
				pmSym = local(rodata, "pm", 8);
				for (w in 0...nwords) {
					var lo = 0, hi = 0;
					for (j in w * 64...Std.int(Math.min(n, w * 64 + 64))) {
						var s = t.slots[j];
						if (s != null && Ir.isRef(s)) {
							var k = j - w * 64;
							if (k < 32) lo |= 1 << k else hi |= 1 << (k - 32);
						}
					}
					rodata.buf.u64(lo, hi);
				}
			}
			var fs = t.fields.copy();
			fs.sort((a, b) -> e.fid(a.name) - e.fid(b.name));
			if (fs.length > 0) {
				fsSym = local(rodata, "fs", 4);
				for (f in fs) {
					rodata.buf.u32(e.fid(f.name));
					rodata.buf.u32(f.slot);
					rodata.buf.u32(kindChar(f.ty));
				}
			}
			var ms = t.methods.copy();
			ms.sort((a, b) -> e.fid(a.name) - e.fid(b.name));
			if (ms.length > 0) {
				msSym = local(data, "ms", 8);
				for (m in ms) {
					data.buf.u32(e.fid(m.name));
					data.buf.u32(0);
					// (a method with default values for numbers or Bools: its entry
					// taking them nullable, FuncInfo.dfltEntry)
					ptr(data, m.dfn != null ? m.dfn : m.fn);
					data.buf.u32(m.dfn != null ? m.dsig : m.sig);
					data.buf.u32(0);
				}
			}
			if (t.ifaces.length > 0) {
				ifSym = local(rodata, "if", 4);
				for (x in t.ifaces)
					rodata.buf.u32(x);
			}
			if (t.ctors.length > 0) {
				ctSym = local(rodata, "ct", 4);
				for (x in t.ctors)
					rodata.buf.u32(x);
			}
			entries.push({
				t: t,
				ss: ss,
				ssSym: ssSym,
				pmSym: pmSym,
				fs: fs.length,
				fsSym: fsSym,
				ms: ms.length,
				msSym: msSym,
				ifSym: ifSym,
				ctSym: ctSym
			});
		}
		var nameSyms = [for (x in entries) cstr(x.t.name)];
		begin(data, "rt_types", 16, true);
		for (k in 0...entries.length) {
			var x = entries[k];
			var t = x.t;
			var at = data.buf.len;
			ptrSym(data, nameSyms[k]); // 0 name
			data.buf.u32(tk(t.tk)); // 8 tk (u8)
			data.buf.u32(t.sup); // 12 super
			data.buf.u32(t.slots.length); // 16 nslots
			data.buf.u32(0);
			if (x.pmSym != null) ptrSym(data, x.pmSym) else data.buf.u64(0, 0); // 24 ptrmap
			data.buf.u32(x.fs); // 32 nfields
			data.buf.u32(0);
			if (x.fsSym != null) ptrSym(data, x.fsSym) else data.buf.u64(0, 0); // 40 fields
			data.buf.u32(x.ms); // 48 nmethods
			data.buf.u32(0);
			if (x.msSym != null) ptrSym(data, x.msSym) else data.buf.u64(0, 0); // 56 methods
			data.buf.u32(t.ifaces.length); // 64 nifaces
			data.buf.u32(0);
			if (x.ifSym != null) ptrSym(data, x.ifSym) else data.buf.u64(0, 0); // 72 ifaces
			data.buf.u32(t.tag); // 80 tag
			// 84 a constructor's singleton: its rt_globals index + 1; a class's
			// entry for Type.createInstance (Types.maker): 0 none, 1 no
			// constructor, 2 + its signature: the function at 88
			var mk = t.maker;
			data.buf.u32(t.single != null ? t.single + 1 : mk != null ? (mk.fn != null ? 2 + mk.sig : 1) : 0);
			// 88 an enum's constructors; a class's entry for Type.createInstance
			if (x.ctSym != null) ptrSym(data, x.ctSym) else if (mk != null && mk.fn != null) ptr(data, mk.fn) else data.buf.u64(0, 0);
			data.buf.u32(x.ss != null ? x.ss.length : 0); // 96 nstatics
			data.buf.u32(0);
			if (x.ssSym != null) ptrSym(data, x.ssSym) else data.buf.u64(0, 0); // 104 statics
			if (data.buf.len - at != Abi.TYPE_SIZE) throw "hxmc: rt_type layout";
		}
		data.buf.zeros(Abi.TYPE_SIZE * spareTypes);
		if (spareTypes > 0) {
			// (written by the loader of code at run time: hxmc.macro.Loader)
			data.buf.align(4);
			obj.define("rt_ntypes", data, data.buf.len, 4, true);
			data.buf.u32(types.length);
		} else
			int32Global("rt_ntypes", types.length);
	}

	// the closures capturing nothing (Prep.staticClosures), each an object
	// as the heap has one, outside it: header (one slot, its type), code
	function closures() {
		for (l in p.lambdas)
			if (l.captures.length == 0) {
				data.buf.align(8);
				data.buf.u32(1 | (Abi.K_OBJ << 28));
				data.buf.u32(l.tindex);
				obj.define(prep.closureSym(l), data, data.buf.len, 8, true);
				ptr(data, e.symbol(l.fn));
			}
	}

	// A dispatch row per selector, indexed by a class's type index - T_FIRST
	// (MirBuild's ECallDispatch): the implementation the class runs. A call
	// reads only the entries of the classes implementing the selector, so the
	// rows are laid over each other, each where its entries find free slots
	// (or the same function), its symbol at its first slot (the slots before
	// another row's): a fraction of the classes times the selectors. -D
	// hxmc.jit: whole rows (the native macros' types come after).
	function dispatch() {
		var rows = [];
		for (s in 0...p.selectors.length) {
			// (a selector no live code dispatches on: no row, Reach)
			if (p.liveSelectors != null && !p.liveSelectors[s]) continue;
			var row = [];
			for (k in 0...p.classes.length) {
				var m = p.classes[k].findMethod(p.selectors[s].name);
				if (m != null && m.dispatchSel == s && p.isLive(m)) row.push({k: k, sym: e.symbol(m)});
			}
			rows.push({s: s, row: row});
		}
		if (spareTypes > 0) {
			for (r in rows) {
				begin(data, e.selNames[r.s], 8, true);
				var k = 0;
				for (x in r.row) {
					data.buf.zeros(8 * (x.k - k));
					ptr(data, x.sym);
					k = x.k + 1;
				}
				data.buf.zeros(8 * (p.classes.length - k));
			}
			return;
		}
		// (the largest rows first, each at the first place it fits)
		var order = [for (i in 0...rows.length) i];
		order.sort((a, b) -> rows[b].row.length - rows[a].row.length != 0 ? rows[b].row.length - rows[a].row.length : a - b);
		var slots:Array<Null<String>> = [];
		var at = [for (_ in rows) 0];
		for (i in order) {
			var row = rows[i].row;
			var d = 0;
			while (Lambda.exists(row, x -> d + x.k < slots.length && slots[d + x.k] != null && slots[d + x.k] != x.sym))
				d++;
			for (x in row) {
				while (slots.length <= d + x.k)
					slots.push(null);
				slots[d + x.k] = x.sym;
			}
			at[i] = d;
		}
		data.buf.align(8);
		var base = data.buf.len;
		for (x in slots)
			if (x != null) ptr(data, x) else data.buf.u64(0, 0);
		for (i in 0...rows.length)
			obj.define(e.selNames[rows[i].s], data, base + 8 * at[i], 0, true);
	}

	// the allocation stubs the program's code calls (MirBuild.ALLOC_STUB):
	// each passes its header words and size to hxmc_alloc_slow, so an
	// allocation site's slow path is one call (after run: hx_main_body allocates)
	public function allocStubs(objs:Array<Obj>, emit:Target.Emitter) {
		var names = new Map<String, Bool>();
		for (o in objs.concat([obj]))
			for (s in o.symbols)
				if (s.section == null && !s.abs && StringTools.startsWith(s.name, MirBuild.ALLOC_STUB)) names.set(s.name, true);
		var list = [for (n in names.keys()) n];
		list.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		for (n in list) {
			var parts = n.substr(MirBuild.ALLOC_STUB.length).split("$");
			var lo = Std.parseInt(parts[0]), bytes = Std.parseInt(parts[2]);
			var ty = parts[1];
			var sym = StringTools.startsWith(ty, "#") ? null : ty;
			if (emit.allocStub(n, lo, sym, sym == null ? Std.parseInt(ty.substr(1)) : 0, bytes)) continue;
			compile(MirBuild.synthetic(prep, abi, n, vector(), I64, (b, _) -> {
				var t = StringTools.startsWith(ty, "#") ? b.iconst(Std.parseInt(ty.substr(1))) : b.idConst(ty, 0);
				b.ret(b.call("hxmc_alloc_slow", vector(b.iconst(lo), t, b.iconst(bytes)), I64));
			}));
		}
	}

	// the C string literals the program refers to (Mem.cstr: MirBuild.CSTR),
	// NUL-terminated in .rodata, and its words (Mem.words: MirBuild.WORDS)
	public function cstrLiterals(objs:Array<Obj>) {
		var names = new Map<String, Bool>();
		for (o in objs.concat([obj]))
			for (s in o.symbols)
				if (s.section == null && !s.abs && (StringTools.startsWith(s.name, MirBuild.CSTR) || StringTools.startsWith(s.name, MirBuild.WORDS))) names.set(s.name, true);
		var list = [for (n in names.keys()) n];
		list.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		for (n in list) {
			// (Mem.words: 8-byte aligned words, no NUL)
			var words = StringTools.startsWith(n, MirBuild.WORDS);
			var b = haxe.io.Bytes.ofHex(n.substr(words ? MirBuild.WORDS.length : MirBuild.CSTR.length));
			if (words) rodata.buf.align(8);
			var off = rodata.buf.len;
			for (i in 0...b.length)
				rodata.buf.u8(b.get(i));
			if (!words) rodata.buf.u8(0);
			obj.define(n, rodata, off, b.length + (words ? 0 : 1), true);
		}
	}

	// the empty NativeArrays the program refers to (MirBuild.EMPTY_ARRAY), in
	// .data as string literals are: MKHDR(1, K_RAW, T_NATIVE_ARRAY), length 0,
	// the kind
	public function emptyArrays(objs:Array<Obj>) {
		var names = new Map<String, Bool>();
		for (o in objs.concat([obj]))
			for (s in o.symbols)
				if (s.section == null && !s.abs && StringTools.startsWith(s.name, MirBuild.EMPTY_ARRAY)) names.set(s.name, true);
		var list = [for (n in names.keys()) n];
		list.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		for (n in list) {
			data.buf.align(8);
			obj.define(n, data, data.buf.len, 16, true);
			data.buf.u64(1 | (Abi.K_RAW << 28), Abi.T_NATIVE_ARRAY);
			data.buf.u32(0);
			data.buf.u32(Std.parseInt(n.substr(MirBuild.EMPTY_ARRAY.length)));
		}
	}

	// the runtime's machine-code stubs the program refers to (MirBuild.STUB_*)
	public function stubs(objs:Array<Obj>, emit:Target.Emitter) {
		for (n in [MirBuild.STUB_CALL_ON_STACK, MirBuild.STUB_ZERO, MirBuild.STUB_FRAME]) {
			var used = false;
			for (o in objs.concat([obj]))
				for (s in o.symbols)
					if (s.section == null && !s.abs && s.name == n) used = true;
			if (used) emit.stub(n);
		}
	}

	function mainBody() {
		compile(MirBuild.synthetic(prep, abi, "hx_main_body", vector(), Void, (b, _) -> {
			for (i in 0...p.globals.length) {
				var c = p.globals[i].init;
				if (c != null) {
					var o = b.alloc(1, c.tindex, Abi.K_OBJ, true);
					b.store(8, b.load(I64, 8, b.symAddr("rt_globals"), 0), 8 * i, o);
				}
			}
			for (f in p.inits)
				b.call(e.symbol(f), vector(), Void);
			b.call(e.symbol(p.main), vector(), Void);
			b.ret(-1);
		}));
		// WebAssembly (WASI): _start; the runtime reads the arguments itself and exits
		if (abi.wasm) {
			compile(MirBuild.synthetic(prep, abi, "_start", vector(), Void, (b, ps) -> {
				b.call("rt_init", vector(b.iconst(p.globals.length), b.iconst(0), b.lconst(0, 0)), Void);
				// the stack of frame slots: the runtime's from here on (wasm/Gc.hx;
				// set here, in a function without a frame of its own, whose
				// return would restore the linker's stack pointer)
				var lo = b.call("rt_cstack_lo", vector(), I64);
				var top = b.call("rt_cstack_top", vector(), I64);
				b.tlsStore(hxmc.wasm.WasmGen.SP, top);
				b.tlsStore(hxmc.wasm.WasmGen.STACK_LO, lo);
				b.call("hx_main_body", vector(), Void);
				b.call("rt_main_done", vector(), Void);
				b.ret(-1);
			}));
			return;
		}
		// iOS with an app (packages/os: hxmc.os.uikit.UIKitApp exports
		// UI_MAIN): UIApplicationMain runs on the big stack, and the program's
		// body from its delegate once the app has launched
		// (iOS: UIKit's start, unless a dylib's: a build hxmc dev's host loads into the running app)
		var body = abi.ios() && abi.output != SharedLibrary && Lambda.exists(p.funcs, f -> f.cSymbol == UI_MAIN) ? UI_MAIN : "hx_main_body";
		compile(MirBuild.synthetic(prep, abi, "main", vector(I32, I64), I32, (b, ps) -> {
			b.call("rt_init", vector(b.iconst(p.globals.length), ps[0], ps[1]), Void);
			b.call("rt_run_main", vector(b.symAddr(body)), Void);
			b.ret(b.iconst(0));
		}));
	}
}
