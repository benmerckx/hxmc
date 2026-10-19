package hxmc.macro;

#if hxmc.jit
import hxmc.I64;
import hxmc.Obj;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.rt.Gc;
import hxmc.rt.Dyn;
import hxmc.unsafe.Ptr;

@:hxmc.c @:hxmc.fast private extern class Vm {
	static function mmap(addr:Ptr, len:I64, prot:Int, flags:Int, fd:Int, off:I64):Ptr;
	static function mprotect(addr:Ptr, len:I64, prot:Int):Int;
}

// A loaded bundle: what the bridge and the engine use.
class Bundle {
	public var entries = new Map<String, Ptr>(); // entry name -> code
	public var typeObjs = new Map<String, Ptr>(); // type name (TK_CLASS, TK_ENUM) -> its type object
	public var shapes:Array<{tindex:Int, fields:Array<String>}> = []; // the anonymous structures (TK_ANON)
	public var singletons = new Map<Int, Int>(); // constructor type index -> its rt_globals index
	public var codeBytes = 0;

	public function new() {}
}

// Links a bundle (Guest) into the running compiler: the compiler's symbols
// come from <exe>.syms (Link, -D hxmc.jit); program-wide numbers the
// compiler has are its own (type indices after a layout check, field ids,
// signatures, globals), the others are new: types fill the spare entries of
// rt_types, signatures the spare entries of the signature tables, field
// names are added to the runtime's table (Names), reference globals grow
// rt_globals. The code, its data and the dispatch rows are mapped below 2 GB
// (code reaches the compiler with rel32 and dispatch rows are absolute
// 32-bit displacements), the code made read-only and executable once
// relocated. Prototype limits: a new class may not extend one of the
// compiler's, and nothing is ever unloaded.
@:access(hxmc.rt.Gc)
@:access(hxmc.rt.Dyn)
class Loader {
	static inline var PROT_READ = 1;
	static inline var PROT_WRITE = 2;
	static inline var PROT_EXEC = 4;
	static inline var MAP_PRIVATE = 2;
	static inline var MAP_ANONYMOUS = 0x20;
	static inline var TS = 112; // Abi.TYPE_SIZE

	static var host:Null<Map<String, {k:String, v:Int}>> = null;
	// what the bundles loaded so far define (their numbers, globals, type objects, functions)
	static var xb = new Map<String, {k:String, v:Int}>();
	static var hostNtypes = 0;
	static var hostNsigs = 0;
	static var nextType = 0;
	static var nextSig = 0;
	static var hint = 0x40000000;

	// whether o is an object of a type of a bundle
	public static function isBundleObject(o:Dynamic):Bool
		return host != null && Mem.getU16(Mem.addr(o), -4) >= hostNtypes;

	static function hostSyms():Map<String, {k:String, v:Int}> {
		if (host != null) return host;
		var exe = try sys.FileSystem.fullPath(Sys.programPath()) catch (_:Dynamic) Sys.programPath();
		var path = exe + ".syms";
		if (!sys.FileSystem.exists(path)) throw "no symbol map " + path + " (a compiler built with -D hxmc.jit writes it)";
		var m = new Map();
		for (l in sys.io.File.getContent(path).split("\n")) {
			var a = l.split(" ");
			if (a.length == 3) m.set(a[0], {k: a[1], v: Std.parseInt(a[2])});
		}
		host = m;
		hostNtypes = Mem.getI32(Mem.sym("rt_ntypes"), 0);
		hostNsigs = Mem.getI32(Mem.sym("rt_nsigs"), 0);
		nextType = hostNtypes;
		nextSig = hostNsigs;
		return m;
	}

	static var debug = Sys.getEnv("HXMC_MACRO_DEBUG") == "1";

	static function dbg(s:String)
		if (debug) Sys.stderr().writeString("hxmc.macros: load: " + s + "\n");

	static inline function ptr(v:Int):Ptr
		return Ptr.ofI64((v : I64));

	// (an address code reaches with 32 bits: below 2 GB)
	static function addrOf(p:Ptr):Int {
		var v = p.toI64();
		if (v < (0 : I64) || v >= (0x7fffffff : I64)) throw "address beyond 2 GB in a 32-bit relocation";
		return v.toInt();
	}

	// a C string outside the heap (never freed)
	static function cstr(s:String):Ptr {
		var b = haxe.io.Bytes.ofString(s);
		var p = LibC.malloc(((b.length + 1) : I64));
		for (i in 0...b.length)
			Mem.setI8(p, i, b.get(i));
		Mem.setI8(p, b.length, 0);
		return p;
	}

	static function zalloc(n:Int):Ptr {
		var p = LibC.malloc(((n < 8 ? 8 : n) : I64));
		LibC.memset(p, 0, ((n < 8 ? 8 : n) : I64));
		return p;
	}

	public static function load(base:String):Bundle {
		var h = hostSyms();
		var obj = ElfReader.read(sys.io.File.getBytes(base + ".o"));
		var facts:Dynamic = haxe.Json.parse(sys.io.File.getContent(base + ".json"));
		var b = new Bundle();
		// ---- program-wide numbers
		dbg("program-wide numbers");
		var num = new Map<String, Int>(); // absolute symbols
		var extra = new Map<String, Ptr>(); // data addresses (scalar globals, type objects, rows)
		// a number of the compiler's (only for what may be the compiler's own:
		// `share`), else of a bundle loaded before
		function abs(n:String, share:Bool):Null<Int> {
			var s = share ? h.get(n) : null;
			if (s == null) s = xb.get(n);
			return s != null && s.k == "a" ? s.v : null;
		}
		function dataAddr(n:String, share:Bool):Null<Int> {
			var s = share ? h.get(n) : null;
			if (s == null) s = xb.get(n);
			return s != null && s.k == "d" ? s.v : null;
		}
		// field ids: the compiler's, or added to the runtime's table
		var fids = new Map<String, Int>();
		var fields:Array<Dynamic> = facts.fields;
		for (f in fields) {
			var v = abs(f.sym, true);
			if (v == null) v = Dyn.fid(f.name);
			num.set(f.sym, v);
			fids.set(f.name, v);
		}
		// types: the compiler's (after a layout check) or a bundle's, else the next spare entry (in the guest's order)
		var types:Array<Dynamic> = facts.types;
		var isNew = new Map<String, Bool>();
		var shared = new Map<String, Bool>();
		for (t in types) {
			shared.set(t.sym, t.share);
			var v = abs(t.sym, t.share);
			if (v != null) {
				var why = sameLayout(v, t, fids);
				if (why != null) throw "type " + t.name + " differs from the compiler's: " + why;
				num.set(t.sym, v);
			} else {
				if (nextType >= hostNtypes + Jit.SPARE_TYPES) throw "out of spare type entries";
				num.set(t.sym, nextType++);
				isNew.set(t.sym, true);
			}
		}
		inline function tyNum(n:Dynamic):Int
			return n == null ? -1 : num.exists(n) ? num.get(n) : Std.parseInt(n);
		var classes:Array<Dynamic> = facts.classes;
		for (c in classes) {
			var span = "TYSPAN_" + (c.ty : String).substr(3);
			if (isNew.exists(c.ty)) {
				// (the root class of every class, Object, is the compiler's)
				if (c.sup != null && c.sup != "TY_Object" && !isNew.exists(c.sup)) throw "class " + c.ty + " extends a class of the compiler";
				num.set(span, c.span);
			} else {
				var v = abs(span, shared.get(c.ty));
				if (v == null) throw "no " + span;
				num.set(span, v);
			}
		}
		// signatures
		var sigs:Array<Dynamic> = facts.sigs;
		var newSigs = [];
		for (s in sigs) {
			var v = abs(s.sym, true);
			if (v == null) {
				if (nextSig >= hostNsigs + Jit.SPARE_SIGS) throw "out of spare signature entries";
				v = nextSig++;
				newSigs.push({id: v, s: s});
			}
			num.set(s.sym, v);
		}
		// globals: the compiler's (the std's statics, the runtime's) or a bundle's, else new
		// slots of rt_globals and new scalars
		var globals:Array<Dynamic> = facts.globals;
		var nglobals = Gc.nglobals;
		var newGlobals = [];
		var gindex = new Map<String, Int>();
		var newScalars:Array<String> = []; // (in the mapping, after the rows: code reaches them with rel32)
		for (g in globals) {
			if (g.ref) {
				var v = abs(g.sym, g.share);
				var idx = v == null ? nglobals++ : v >> 3;
				if (v == null) newGlobals.push({idx: idx, init: g.init});
				num.set(g.sym, 8 * idx);
				num.set(g.name, idx);
				gindex.set(g.name, idx);
			} else {
				var a = dataAddr(g.sym, g.share);
				if (a != null) extra.set(g.sym, ptr(a)) else newScalars.push(g.sym);
			}
		}
		// type objects (two words: the header, the type index): the new types' in
		// the spare part of rt_types_objs, where the runtime finds them
		for (t in types) {
			var n = "TYOBJ_" + (t.sym : String).substr(3);
			if (isNew.exists(t.sym)) {
				var o = Mem.sym("rt_type_objs").add(16 * num.get(t.sym));
				Mem.setI64(o, 0, ((14 : I64) << 32) | ((2 << 28) | 1)); // T_TYPEOBJ, K_RAW, one slot
				Mem.setI32(o, 8, num.get(t.sym));
				extra.set(n, o.add(8));
			} else {
				var a = dataAddr(n, t.share);
				if (a != null) extra.set(n, ptr(a));
			}
		}
		// ---- layout: code | read-only data, data, bss, then the dispatch rows
		dbg("layout: code | read-only data, data, bss, then the dispatch rows");
		var text = [], rest = [];
		for (s in obj.sections)
			if (s.kind == Text) text.push(s) else if (s.kind == RoData || s.kind == Data || s.kind == Bss) rest.push(s) else if (s.size() > 0) throw "section " + s.name + " (" + s.kind + ")";
		var addr = new Map<Section, Int>();
		var pos = 0;
		function place(list:Array<Section>) {
			for (s in list) {
				pos = (pos + s.align - 1) & ~(s.align - 1);
				addr.set(s, pos);
				pos += s.size();
			}
		}
		place(text);
		var textSize = (pos + 4095) & ~4095;
		pos = textSize;
		place(rest);
		var selectors:Array<Dynamic> = facts.selectors;
		var rowsAt = (pos + 15) & ~15;
		var maxT = nextType;
		var rowBytes = 8 * (maxT - Abi.T_FIRST);
		pos = rowsAt + rowBytes * selectors.length;
		var scalarsAt = (pos + 15) & ~15;
		pos = scalarsAt + 8 * newScalars.length;
		var size = (pos + 4095) & ~4095;
		var region = Vm.mmap(ptr(hint), (size : I64), PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		var ra = region.toI64();
		if (ra == (-1 : I64) || ra >= (0x7fff0000 : I64) || ra < (0 : I64)) throw "cannot map code below 2 GB";
		var base = addrOf(region);
		hint = base + size + 0x10000;
		for (s in addr.keys())
			addr.set(s, addr.get(s) + base);
		for (i in 0...newScalars.length)
			extra.set(newScalars[i], ptr(base + scalarsAt + 8 * i));
		for (k in 0...selectors.length)
			extra.set(selectors[k].sym, ptr(base + rowsAt + rowBytes * k)); // (indexed by type index - T_FIRST: MirBuild)
		// ---- symbols
		dbg("symbols");
		function value(s:Symbol):{v:Int, tls:Bool} {
			if (s.section != null) return {v: addr.get(s.section) + s.offset, tls: false};
			if (s.abs) return {v: s.offset, tls: false};
			var n = num.get(s.name);
			if (n != null) return {v: n, tls: false};
			var x = extra.get(s.name);
			if (x != null) return {v: addrOf(x), tls: false};
			var hs = h.get(s.name);
			if (hs == null) hs = xb.get(s.name);
			if (hs != null) return {v: hs.v, tls: hs.k == "l"};
			// (a definition in another object of the bundle: one object here)
			throw "undefined symbol " + s.name;
		}
		var defs = new Map<String, Symbol>();
		for (s in obj.symbols)
			if (s.section != null && s.global) defs.set(s.name, s);
		function resolve(s:Symbol):{v:Int, tls:Bool}
			return s.section == null && defs.exists(s.name) ? value(defs.get(s.name)) : value(s);
		// ---- relocation
		dbg("relocation");
		for (sec in obj.sections) {
			if (!addr.exists(sec) || sec.kind == Bss) continue;
			var at = addr.get(sec);
			var buf = sec.buf;
			for (r in sec.relocs) {
				var sv = resolve(r.sym);
				var S = sv.v, A = r.addend, P = at + r.offset;
				switch r.kind {
					case RAbs64:
						var v = S + A;
						buf.set64(r.offset, v, v < 0 ? -1 : 0);
					case RAbs32 | RAbs32S:
						buf.set32(r.offset, S + A);
					case RPc32 | RCall32:
						buf.set32(r.offset, S + A - P);
					case RTpOff32:
						if (!sv.tls) throw "TLS relocation against " + r.sym.name;
						buf.set32(r.offset, S + A);
					case _:
						throw "relocation " + r.kind + " against " + r.sym.name;
				}
			}
			var p = ptr(at);
			for (i in 0...buf.len)
				Mem.setI8(p, i, buf.b.get(i));
		}
		b.codeBytes = textSize;
		if (Vm.mprotect(region, (textSize : I64), PROT_READ | PROT_EXEC) != 0) throw "mprotect failed";
		inline function symAddr(n:String):Int {
			var d = defs.get(n);
			if (d != null) return value(d).v;
			var hs = h.get(n);
			if (hs == null) hs = xb.get(n);
			if (hs == null) throw "undefined symbol " + n;
			return hs.v;
		}
		// ---- dispatch rows
		dbg("dispatch rows");
		for (k in 0...selectors.length) {
			var row = ptr(base + rowsAt + rowBytes * k);
			var rows:Array<Dynamic> = selectors[k].rows;
			for (r in rows)
				Mem.setPtr(row, 8 * (num.get(r.ty) - Abi.T_FIRST), ptr(symAddr(r.fn)));
		}
		// ---- signatures: the spare entries of rt_dyncalls, rt_sig_keys, rt_bound_tramps, rt_bound_types
		dbg("signatures: the spare entries of rt_dyncalls, rt_sig_keys, rt_bound_tramps, rt_bound_types");
		for (x in newSigs) {
			Mem.setPtr(Mem.sym("rt_dyncalls"), 8 * x.id, ptr(symAddr(x.s.dyn)));
			Mem.setPtr(Mem.sym("rt_sig_keys"), 8 * x.id, cstr(x.s.key));
			Mem.setPtr(Mem.sym("rt_bound_tramps"), 8 * x.id, ptr(symAddr(x.s.bt)));
			Mem.setI32(Mem.sym("rt_bound_types"), 4 * x.id, tyNum(x.s.bound));
		}
		// ---- the new types' rt_types entries
		dbg("the new types' rt_types entries");
		for (t in types) {
			if (!isNew.exists(t.sym)) continue;
			var idx = num.get(t.sym);
			var e = Mem.sym("rt_types").add(idx * TS);
			Mem.setPtr(e, 0, cstr(t.name));
			Mem.setI32(e, 8, ["TK_RUNTIME", "TK_CLASS", "TK_INTERFACE", "TK_ENUM", "TK_CTOR", "TK_ANON", "TK_CLOSURE", "TK_BOUND"].indexOf(t.tk));
			Mem.setI32(e, 12, tyNum(t.sup));
			var slots:String = t.slots;
			Mem.setI32(e, 16, slots.length);
			if (slots.length > 0) {
				var nw = Std.int((slots.length + 63) / 64);
				var pm = zalloc(8 * nw);
				for (j in 0...slots.length)
					if (slots.charAt(j) == "p") Mem.setI32(pm, 4 * (j >> 5), Mem.getI32(pm, 4 * (j >> 5)) | (1 << (j & 31)));
				Mem.setPtr(e, 24, pm);
			}
			var fs:Array<Dynamic> = (t.fields : Array<Dynamic>).copy();
			fs.sort((a, b) -> fids.get(a.name) - fids.get(b.name));
			Mem.setI32(e, 32, fs.length);
			if (fs.length > 0) {
				var p = zalloc(12 * fs.length);
				for (i in 0...fs.length) {
					Mem.setI32(p, 12 * i, fids.get(fs[i].name));
					Mem.setI32(p, 12 * i + 4, fs[i].slot);
					Mem.setI32(p, 12 * i + 8, (fs[i].kind : String).charCodeAt(0));
				}
				Mem.setPtr(e, 40, p);
			}
			var ms:Array<Dynamic> = (t.methods : Array<Dynamic>).copy();
			ms.sort((a, b) -> fids.get(a.name) - fids.get(b.name));
			Mem.setI32(e, 48, ms.length);
			if (ms.length > 0) {
				var p = zalloc(24 * ms.length);
				for (i in 0...ms.length) {
					Mem.setI32(p, 24 * i, fids.get(ms[i].name));
					Mem.setPtr(p, 24 * i + 8, ptr(symAddr(ms[i].fn)));
					Mem.setI32(p, 24 * i + 16, num.get(ms[i].sig));
				}
				Mem.setPtr(e, 56, p);
			}
			var ifs:Array<Dynamic> = t.ifaces;
			Mem.setI32(e, 64, ifs.length);
			if (ifs.length > 0) {
				var p = zalloc(4 * ifs.length);
				for (i in 0...ifs.length)
					Mem.setI32(p, 4 * i, tyNum(ifs[i]));
				Mem.setPtr(e, 72, p);
			}
			Mem.setI32(e, 80, t.tag);
			var cs:Array<Dynamic> = t.ctors;
			if (cs.length > 0) {
				var p = zalloc(4 * cs.length);
				for (i in 0...cs.length)
					Mem.setI32(p, 4 * i, tyNum(cs[i]));
				Mem.setPtr(e, 88, p);
			}
		}
		// the new classes' statics (rt_static: fid, kind, index, address)
		for (c in classes) {
			var ss:Array<Dynamic> = c.statics;
			if (!isNew.exists(c.ty) || ss == null || ss.length == 0) continue;
			ss = ss.copy();
			ss.sort((a, b) -> fids.get(a.name) - fids.get(b.name));
			var p = zalloc(24 * ss.length);
			for (i in 0...ss.length) {
				var s = ss[i];
				var kind:String = s.kind;
				Mem.setI32(p, 24 * i, fids.get(s.name));
				Mem.setI32(p, 24 * i + 4, kind.charCodeAt(0));
				switch kind {
					case "c":
						Mem.setI32(p, 24 * i + 8, num.get(s.ty));
						Mem.setPtr(p, 24 * i + 16, ptr(symAddr(s.fn)));
					case "p":
						Mem.setI32(p, 24 * i + 8, gindex.get(s.global));
					case _:
						Mem.setI32(p, 24 * i + 8, -1);
						Mem.setPtr(p, 24 * i + 16, extra.get(s.sym));
				}
			}
			var e = Mem.sym("rt_types").add(num.get(c.ty) * TS);
			Mem.setI32(e, 96, ss.length);
			Mem.setPtr(e, 104, p);
		}
		// an empty anonymous structure (its fields overflow): the bridge's objects that
		// match no structure of the bundle
		if (nextType >= hostNtypes + Jit.SPARE_TYPES) throw "out of spare type entries";
		var empty = nextType++;
		var ee = Mem.sym("rt_types").add(empty * TS);
		Mem.setPtr(ee, 0, cstr("{}"));
		Mem.setI32(ee, 8, 5);
		Mem.setI32(ee, 12, -1);
		Mem.setI32(ee, 16, 1);
		var epm = zalloc(8);
		Mem.setI32(epm, 0, 1);
		Mem.setPtr(ee, 24, epm);
		b.shapes.push({tindex: empty, fields: []});
		// what the bridge needs
		for (t in types) {
			var tk:String = t.tk;
			if (tk == "TK_CLASS" || tk == "TK_ENUM") {
				var to = extra.get("TYOBJ_" + (t.sym : String).substr(3));
				if (to != null) b.typeObjs.set(t.name, to);
			} else if (tk == "TK_ANON") {
				var fs:Array<Dynamic> = t.fields;
				b.shapes.push({tindex: num.get(t.sym), fields: [for (f in fs) (f.name : String)]});
			}
		}
		// ---- rt_globals with the new slots (it is a root of the collector: no barrier)
		dbg("rt_globals with the new slots (it is a root of the collector: no barrier)");
		if (nglobals > Gc.nglobals) {
			var g = zalloc(8 * (nglobals + 1));
			LibC.memcpy(g, Gc.globals, ((8 * Gc.nglobals) : I64));
			Gc.globals = g;
			Gc.nglobals = nglobals;
		}
		for (g in newGlobals)
			if (g.init != null) Mem.setRef(Gc.globals, 8 * g.idx, Mem.alloc(1, num.get(g.init), 0));
		var singletons:Array<Dynamic> = facts.singletons;
		for (s in singletons)
			if (gindex.exists(s.global)) {
				b.singletons.set(num.get(s.ty), gindex.get(s.global));
				// (Type.createEnum finds it there: Types.single)
				Mem.setI32(Mem.sym("rt_types").add(num.get(s.ty) * TS), 84, gindex.get(s.global) + 1);
			}
		// ---- the static initializers of the new classes, in order
		dbg("the static initializers of the new classes, in order");
		var inits:Array<Dynamic> = facts.inits;
		for (i in inits)
			// (a class without a type entry: new unless a bundle loaded before, or for
			// the std the compiler, has its initializer)
			if (i.ty != null ? isNew.exists(i.ty) : !(xb.exists(i.fn) || (i.share && h.exists(i.fn)))) Mem.call0(ptr(symAddr(i.fn)));
		// what the next bundles share: the numbers, the globals and type objects, the functions
		for (n => v in num)
			xb.set(n, {k: "a", v: v});
		for (n => p in extra)
			if (!StringTools.startsWith(n, "DSP_")) xb.set(n, {k: "d", v: addrOf(p)});
		for (n => s in defs)
			if (s.section.kind == Text && StringTools.startsWith(n, "F_")) xb.set(n, {k: "t", v: value(s).v});
		var entries:Array<Dynamic> = facts.entries;
		for (en in entries)
			b.entries.set(en.name, ptr(symAddr(en.sym)));
		return b;
	}

	// null when the compiler's type `idx` has the guest's layout (slots, pointer map, fields)
	static function sameLayout(idx:Int, t:Dynamic, fids:Map<String, Int>):Null<String> {
		var e = Mem.sym("rt_types").add(idx * TS);
		var slots:String = t.slots;
		if (Mem.getI32(e, 16) != slots.length) return "slots " + Mem.getI32(e, 16) + " vs " + slots.length;
		var pm = Mem.getPtr(e, 24);
		for (j in 0...slots.length) {
			var bit = pm.isNull() ? 0 : (Mem.getI32(pm, 4 * (j >> 5)) >>> (j & 31)) & 1;
			if ((bit == 1) != (slots.charAt(j) == "p")) return "pointer map at slot " + j;
		}
		var fs:Array<Dynamic> = t.fields;
		if (Mem.getI32(e, 32) != fs.length) return "fields " + Mem.getI32(e, 32) + " vs " + fs.length;
		var hf = Mem.getPtr(e, 40);
		for (f in fs) {
			var fid = fids.get(f.name), found = false;
			for (i in 0...fs.length)
				if (Mem.getI32(hf, 12 * i) == fid) {
					found = Mem.getI32(hf, 12 * i + 4) == f.slot && Mem.getI32(hf, 12 * i + 8) & 255 == (f.kind : String).charCodeAt(0);
					break;
				}
			if (!found) return "field " + f.name;
		}
		return null;
	}
}
#end
