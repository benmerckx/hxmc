package hxmc.macro;

import hxmc.I64;
import hxmc.Obj;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.rt.Gc;
import hxmc.rt.Dyn;
import hxmc.unsafe.Ptr;

// What the bundles of a generation share, as a function compiled after its
// bundle finds it (Loader.loadLate)
class Gen {
	public final xb:Map<String, {k:String, v:I64}>;
	public final entries:Map<String, Ptr>;
	public final rows:Map<String, I64>;

	public function new(xb, entries, rows) {
		this.xb = xb;
		this.entries = entries;
		this.rows = rows;
	}
}

// A loaded bundle: what the engines use.
class Bundle {
	public var entries = new Map<String, Ptr>(); // entry name -> its descriptor
	public var typeObjs = new Map<String, Ptr>(); // type name (TK_CLASS, TK_ENUM) -> its type object
	public var shapes:Array<{tindex:Int, fields:Array<String>}> = []; // the anonymous structures (TK_ANON)
	public var singletons = new Map<Int, Int>(); // constructor type index -> its rt_globals index
	public var inits:Array<Ptr> = []; // the static initializers' descriptors, run in order (Loader.run0)
	public var initKeys:Array<Null<Int>> = []; // their classes' path hashes (interp.MirMacros: the order a compilation resets them in)
	public var initPaths:Array<Null<String>> = []; // and their paths
	public var initMods:Array<Null<Int>> = []; // and their modules' ids
	public var codeBytes = 0; // (always 0: a bundle has no code)
	public var dataBytes = 0;

	public function new() {}
}

// Links a bundle compiled for the Mir interpreter (interp.MirMacros,
// interp.MirRun) into the running compiler: the compiler's symbols come
// from the table it carries (HostTable, made at its link as a Mir host's);
// program-wide numbers the compiler has are its own (type indices after a
// layout check, field ids, signatures, globals), the others are new: types
// fill the spare entries of rt_types, signatures the spare entries of the
// signature tables, field names are added to the runtime's table (Names),
// reference globals grow rt_globals. Prototype limits: a new class may not
// extend one of the compiler's, and nothing is ever unloaded.
//
// A bundle has no code: its functions are descriptors (InterpGen), its data
// and rows are in memory of malloc's, only 64-bit absolute relocations are
// applied, and nothing is made executable. An interpreted function's
// address, where native code calls it (dispatch rows, method tables,
// closures in data, makers, signature trampolines), is an entry of the
// interpreter's pools (interp.InterpAbi), given out the first time it is
// needed (`entry`).
@:access(hxmc.rt.Gc)
@:access(hxmc.rt.Dyn)
@:access(hxmc.rt.Interp)
class Loader {
	static inline var TS = 112; // Abi.TYPE_SIZE

	static var host:Null<HostTable.HostSyms> = null;
	// what the bundles loaded so far define (their numbers, globals, type objects, functions)
	static var xb = new Map<String, {k:String, v:I64}>();
	// the pool entries given out, by descriptor symbol (this generation's)
	static var entries = new Map<String, Ptr>();
	// the latest dispatch row of each selector (this generation's)
	static var rows = new Map<String, I64>();
	static var hostNtypes = 0;
	static var hostNsigs = 0;
	static var nextType = 0;
	static var nextSig = 0;
	// the types and signatures of this generation, and those of earlier ones no
	// bundle has taken again, by symbol, with their facts: a later generation's
	// of the same facts takes the entry again (takenAgain; spare entries are
	// finite, and every generation has the macro API's enums: 243 of the 254
	// types of a trivial macro's)
	static var genTypes = new Map<String, {idx:Int, key:String}>();
	static var oldTypes = new Map<String, {idx:Int, key:String}>();
	static var genSigs = new Map<String, {id:Int, key:String}>();
	static var oldSigs = new Map<String, {id:Int, key:String}>();
	// the slots of rt_globals likewise, by symbol (a static's, a constructor's
	// singleton): emptied when taken again, as a new generation's statics
	// start (Eval's code of a dropped prototype finds the new one's by its path)
	static var genGlobals = new Map<String, Int>();
	static var oldGlobals = new Map<String, Int>();
	// the scalar statics' addresses, alike (a kept class's value carried over: facts.globals' keep)
	static var genScalars = new Map<String, Ptr>();
	static var oldScalars = new Map<String, Ptr>();
	// the empty anonymous structure (one for every bundle)
	static var emptyAnon = -1;

	// a new generation of bundles (interp.MirMacros: a compilation whose macro
	// context was typed again): those loaded so far stay mapped, but the next
	// ones are not linked against them, and their types are no longer found by
	// name (Type.resolveClass: an empty name)
	public static function newGeneration() {
		for (t in hostNtypes...nextType) {
			if (t == emptyAnon) continue;
			var e = Mem.sym("rt_types").add(t * TS);
			var n = Mem.getPtr(e, 0);
			if (!n.isNull()) Mem.setPtr(e, 0, n.add(LibC.strlen(n)));
		}
		xb = new Map();
		entries = new Map();
		rows = new Map();
		for (k => v in genTypes)
			oldTypes.set(k, v);
		for (k => v in genSigs)
			oldSigs.set(k, v);
		for (k => v in genGlobals)
			oldGlobals.set(k, v);
		for (k => v in genScalars)
			oldScalars.set(k, v);
		genScalars = new Map();
		genTypes = new Map();
		genSigs = new Map();
		genGlobals = new Map();
	}

	// the facts of a type that decide whether an entry of an earlier generation
	// is its (a class's: with the span of its descendants' type indices)
	static function typeKey(t:Dynamic, spans:Map<String, Int>):String {
		var k = haxe.Json.stringify(t);
		return t.tk == "TK_CLASS" ? k + " " + spans.get(t.sym) : k;
	}

	// the types of a bundle that take entries of earlier generations again
	// (fresh: those neither the compiler's nor of a bundle of this generation):
	// an enum with all its constructors, at type indices less their tags that
	// agree (code subtracts them, MirBuild's EEnumTag); a structure, a
	// closure's type, an interface; the classes, all of them or none, at
	// type indices that follow each other in their order (a class's
	// instances are the span of type indices from its own, MirBuild.instOf;
	// every class is below Object)
	static function takenAgain(types:Array<Dynamic>, spans:Map<String, Int>, fresh:Dynamic->Bool):Map<String, Int> {
		var r = new Map<String, Int>();
		var bySym = new Map<String, Dynamic>();
		for (t in types)
			bySym.set(t.sym, t);
		function old(t:Dynamic):Null<Int> {
			if (t == null || !fresh(t)) return null;
			var o = oldTypes.get(t.sym);
			return o != null && o.key == typeKey(t, spans) ? o.idx : null;
		}
		var classes = [];
		for (t in types)
			switch (t.tk : String) {
				case "TK_ANON" | "TK_CLOSURE" | "TK_BOUND" | "TK_INTERFACE":
					var i = old(t);
					if (i != null) r.set(t.sym, i);
				case "TK_CLASS" if (fresh(t)):
					classes.push(t);
				case "TK_ENUM":
					var i = old(t);
					if (i == null) continue;
					var cs:Array<String> = t.ctors;
					var base:Null<Int> = null, ok = true;
					for (c in cs) {
						var ct = bySym.get(c);
						var ci = old(ct);
						if (ci == null || (base != null && ci - (ct.tag : Int) != base)) {
							ok = false;
							break;
						}
						base = ci - (ct.tag : Int);
					}
					if (!ok) continue;
					r.set(t.sym, i);
					for (c in cs)
						r.set(c, oldTypes.get(c).idx);
				case _:
			}
		var base:Null<Int> = null;
		for (k in 0...classes.length) {
			var i = old(classes[k]);
			if (i == null || (k > 0 && i != base + k)) {
				base = null;
				break;
			}
			if (k == 0) base = i;
		}
		if (base != null)
			for (k in 0...classes.length)
				r.set(classes[k].sym, base + k);
		return r;
	}

	// the methods the compiler's own classes override, under every class above
	// the overriding one ("pack.C.name"): code loaded into the compiler is handed
	// its objects (a compilation's streams), so its calls of those methods
	// dispatch (Lower.hostOverrides), though no class it knows overrides them
	public static function hostOverrides():Map<String, Bool> {
		hostSyms();
		var r = new Map<String, Bool>();
		var types = Mem.sym("rt_types");
		inline function entry(t:Int):Ptr
			return types.add(t * TS);
		for (t in Abi.T_FIRST...hostNtypes) {
			var e = entry(t);
			var s = hxmc.rt.Types.sup(e);
			if (hxmc.rt.Types.tk(e) != hxmc.rt.Types.TK_CLASS || s < Abi.T_FIRST) continue;
			for (i in 0...hxmc.rt.Types.nmethods(e)) {
				var m = hxmc.rt.Types.method(e, i);
				var above = @:privateAccess Dyn.findMethod(entry(s), hxmc.rt.Types.mFid(m));
				if (above.isNull() || hxmc.rt.Types.mFn(above) == hxmc.rt.Types.mFn(m)) continue;
				var n = @:privateAccess hxmc.rt.Names.fidStr(hxmc.rt.Types.mFid(m));
				var k = s;
				while (k >= Abi.T_FIRST && hxmc.rt.Types.tk(entry(k)) == hxmc.rt.Types.TK_CLASS) {
					r.set(@:privateAccess hxmc.rt.Str.ofAscii(hxmc.rt.Types.name(entry(k))) + "." + n, true);
					k = hxmc.rt.Types.sup(entry(k));
				}
			}
		}
		return r;
	}

	// the spare entries taken: types, signatures
	public static function used():{types:Int, sigs:Int}
		return {types: nextType - hostNtypes, sigs: nextSig - hostNsigs};

	// whether o is an object of a type of a bundle
	public static function isBundleObject(o:Dynamic):Bool
		return host != null && Mem.getU16(Mem.addr(o), hxmc.Abi.HDR_TINDEX) >= hostNtypes; // (the type index: hxmc.rt.Types)

	static function hostSyms():HostTable.HostSyms {
		if (host != null) return host;
		host = new HostTable.HostSyms();
		hostNtypes = Mem.getI32(Mem.sym("rt_ntypes"), 0);
		hostNsigs = Mem.getI32(Mem.sym("rt_nsigs"), 0);
		nextType = hostNtypes;
		nextSig = hostNsigs;
		return host;
	}

	static var debug = Sys.getEnv("HXMC_MACRO_DEBUG") == "1";

	static function dbg(s:String)
		if (debug) Sys.stderr().writeString("hxmc.macros: load: " + s + "\n");

	static inline function ptr(v:I64):Ptr
		return Ptr.ofI64(v);

	// a function of no arguments of a bundle run by the interpreter (its
	// descriptor: the static initializers, MirRun's main)
	public static function run0(p:Ptr) {
		var buf = LibC.malloc(8);
		try
			hxmc.rt.Interp.enter(p, buf)
		catch (e:Dynamic) {
			LibC.free(buf);
			throw e;
		}
		LibC.free(buf);
	}

	// the address native code calls the function of descriptor
	// symbol d at, given out once (hxmc.rt.Interp.poolEntry; flags: the
	// descriptor's, which may not be in memory yet)
	static function entry(d:String, desc:Ptr, flags:Int):Ptr
		return entryOf(entries, d, desc, flags);

	static function entryOf(entries:Map<String, Ptr>, d:String, desc:Ptr, flags:Int):Ptr {
		var e = entries.get(d);
		if (e == null) {
			e = hxmc.rt.Interp.poolEntry(desc, flags);
			entries.set(d, e);
		}
		return e;
	}

	// this generation's shared symbols, entries and rows (loadLate)
	public static function gen():Gen
		return new Gen(xb, entries, rows);

	// a C function of the system's libraries the compiler imports nothing of
	// (its imports are in the host table: HostTable.imports), looked up as
	// the system's loader would bind it, or null: macOS: libSystem and the
	// images loaded (dlsym, RTLD_DEFAULT); Windows: the DLL of its
	// @:hxmc.lib, else the C library's and the system's DLLs the process has
	// loaded. (Linux: the executable is static, there is nothing else.)
	static function systemSymbol(n:String):Ptr {
		if (Mem.os() == 1) return SysDl.dlsym(Ptr.ofI64(-2), cstr(n));
		if (Mem.os() == 2) {
			var lib = hxmc.ir.CInterop.LIBS.get(n);
			// (LinkInputs.libFile's names)
			var dlls = lib != null ? [lib.indexOf(".") < 0 && lib.indexOf("/") < 0 ? lib + ".dll" : lib] : [];
			for (d in ["ucrtbase.dll", "msvcrt.dll", "kernel32.dll", "ntdll.dll"])
				dlls.push(d);
			for (d in dlls) {
				var h = SysDll.GetModuleHandleA(cstr(d));
				if (h.isNull()) h = lib != null && d == dlls[0] ? SysDll.LoadLibraryA(cstr(d)) : Ptr.nil();
				if (h.isNull()) continue;
				var p = SysDll.GetProcAddress(h, cstr(n));
				if (!p.isNull()) return p;
			}
		}
		return Ptr.nil();
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

	// a bundle: its object (no code: InterpGen.InterpSet.loaded) and its facts (BundleFacts.facts)
	public static function loadObj(obj:Obj, facts:Dynamic):Bundle {
		var h = hostSyms();
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
			return s != null && s.k == "a" ? s.v.toInt() : null;
		}
		function dataAddr(n:String, share:Bool):Null<I64> {
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
		// types: the compiler's (after a layout check) or a bundle's, else the next spare entry (in the bundle's order)
		var types:Array<Dynamic> = facts.types;
		var isNew = new Map<String, Bool>();
		var shared = new Map<String, Bool>();
		var spans = new Map<String, Int>();
		for (c in (facts.classes : Array<Dynamic>))
			spans.set(c.ty, c.span);
		var again = takenAgain(types, spans, t -> abs(t.sym, t.share) == null);
		for (t in types) {
			shared.set(t.sym, t.share);
			var v = abs(t.sym, t.share);
			if (v != null) {
				var why = sameLayout(v, t, fids);
				if (why != null) throw "type " + t.name + " differs from the compiler's: " + why;
				num.set(t.sym, v);
			} else {
				var i = again.get(t.sym);
				if (i != null)
					oldTypes.remove(t.sym)
				else {
					if (nextType >= hostNtypes + MirHost.SPARE_TYPES) throw "out of spare type entries: the bundles loaded have " + MirHost.SPARE_TYPES + " types the compiler lacks (hxmc.macro.MirHost.SPARE_TYPES)";
					i = nextType++;
				}
				num.set(t.sym, i);
				isNew.set(t.sym, true);
				genTypes.set(t.sym, {idx: i, key: typeKey(t, spans)});
			}
		}
		inline function tyNum(n:Dynamic):Int
			return n == null ? -1 : num.exists(n) ? num.get(n) : Std.parseInt(n);
		var classes:Array<Dynamic> = facts.classes;
		for (c in classes) {
			var span = "TYSPAN_" + (c.ty : String).substr(3);
			if (isNew.exists(c.ty)) {
				// (the root class of every class, Object, is the compiler's)
				// (a class of a bundle loaded before: its span does not cover the new class, an instance test of it misses it)
				if (c.sup != null && c.sup != "TY_Object" && !isNew.exists(c.sup) && !xb.exists(c.sup)) throw "class " + c.ty + " extends a class of the compiler";
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
				var o = oldSigs.get(s.sym);
				if (o != null && o.key == s.key) {
					v = o.id;
					oldSigs.remove(s.sym);
				} else {
					if (nextSig >= hostNsigs + MirHost.SPARE_SIGS) throw "out of spare signature entries: the bundles loaded have " + MirHost.SPARE_SIGS + " signatures the compiler lacks (hxmc.macro.MirHost.SPARE_SIGS)";
					v = nextSig++;
				}
				newSigs.push({id: v, s: s});
				genSigs.set(s.sym, {id: v, key: s.key});
			}
			num.set(s.sym, v);
		}
		// globals: the compiler's (the std's statics, the runtime's) or a bundle's, else new
		// slots of rt_globals and new scalars
		var globals:Array<Dynamic> = facts.globals;
		var nglobals = Gc.nglobals;
		var newGlobals = [];
		var gindex = new Map<String, Int>();
		var newScalars:Array<String> = []; // (in the bundle's memory, after the rows)
		var keptScalars = new Map<String, Bool>();
		for (g in globals) {
			if (g.ref) {
				var v = abs(g.sym, g.share);
				var idx = v == null ? oldGlobals.get(g.sym) : v >> 3;
				if (v == null) {
					if (idx != null) {
						oldGlobals.remove(g.sym);
						// (a kept class's: its value stays, as Eval keeps an unchanged type's prototype)
						if (g.keep != true) Mem.setRef(Gc.globals, 8 * idx, null);
					} else
						idx = nglobals++;
					newGlobals.push({idx: idx, init: g.init});
					genGlobals.set(g.sym, idx);
				}
				num.set(g.sym, 8 * idx);
				num.set(g.name, idx);
				gindex.set(g.name, idx);
			} else {
				var a = dataAddr(g.sym, g.share);
				if (a != null) extra.set(g.sym, ptr(a)) else {
					newScalars.push(g.sym);
					if (g.keep == true) keptScalars.set(g.sym, true);
				}
			}
		}
		// @:hxmc.bss blocks: the compiler's, else new (in the bundle's memory, zeroed: after the scalars)
		var bssList:Array<Dynamic> = facts.bss != null ? facts.bss : [];
		var newBss:Array<{sym:String, size:Int, at:Int}> = [];
		for (x in bssList) {
			var a = dataAddr(x.sym, true);
			if (a != null) extra.set(x.sym, ptr(a)) else newBss.push({sym: x.sym, size: x.size, at: 0});
		}
		// type objects (two words: the header, the type index): the new types' in
		// the spare part of rt_types_objs, where the runtime finds them
		for (t in types) {
			var n = "TYOBJ_" + (t.sym : String).substr(3);
			if (isNew.exists(t.sym)) {
				var o = Mem.sym("rt_type_objs").add(16 * num.get(t.sym));
				Mem.setI64(o, 0, ((1 << 16) | 14 : I64)); // a record (hxmc.rt.Types): T_TYPEOBJ, one slot, hash 0
				Mem.setI32(o, 8, num.get(t.sym));
				extra.set(n, o.add(8));
			} else {
				var a = dataAddr(n, t.share);
				if (a != null) extra.set(n, ptr(a));
			}
		}
		// ---- layout: read-only data, data, bss, then the dispatch rows
		dbg("layout: read-only data, data, bss, then the dispatch rows");
		var text = [], rest = [];
		for (s in obj.sections)
			if (s.kind == Text) text.push(s) else if (s.kind == RoData || s.kind == Data || s.kind == Bss) rest.push(s) else if (s.size() > 0) throw "section " + s.name + " (" + s.kind + ")";
		// (a bundle has no code: interp.InterpAbi)
		for (s in text)
			if (s.size() > 0) throw "code in a bundle for the Mir interpreter: section " + s.name + " (" + s.size() + " bytes)";
		var addr = new Map<Section, I64>();
		var pos = 0;
		function place(list:Array<Section>) {
			for (s in list) {
				pos = (pos + s.align - 1) & ~(s.align - 1);
				addr.set(s, pos);
				pos += s.size();
			}
		}
		place(rest);
		var selectors:Array<Dynamic> = facts.selectors;
		var rowsAt = (pos + 15) & ~15;
		var maxT = nextType;
		var rowBytes = 8 * (maxT - Abi.T_FIRST);
		pos = rowsAt + rowBytes * selectors.length;
		var scalarsAt = (pos + 15) & ~15;
		pos = scalarsAt + 8 * newScalars.length;
		for (x in newBss) {
			pos = (pos + 63) & ~63;
			x.at = pos;
			pos += x.size;
		}
		var size = (pos + 4095) & ~4095;
		// (ordinary memory, never executable; zeroed: bss, rows, scalars; never freed, as nothing is unloaded)
		var region = LibC.malloc((size : I64));
		if (region.isNull()) throw "no memory for a bundle";
		LibC.memset(region, 0, (size : I64));
		var base = region.toI64();
		for (s in addr.keys())
			addr.set(s, addr.get(s) + base);
		for (i in 0...newScalars.length) {
			var a = region.add(scalarsAt + 8 * i);
			extra.set(newScalars[i], a);
			var old = oldScalars.get(newScalars[i]);
			if (old != null) {
				oldScalars.remove(newScalars[i]);
				if (keptScalars.exists(newScalars[i])) Mem.setI64(a, 0, Mem.getI64(old, 0));
			}
			genScalars.set(newScalars[i], a);
		}
		for (x in newBss)
			extra.set(x.sym, region.add(x.at));
		for (k in 0...selectors.length)
			extra.set(selectors[k].sym, region.add(rowsAt + rowBytes * k)); // (indexed by type index - T_FIRST: MirBuild)
		// ---- symbols
		dbg("symbols");
		var defs = new Map<String, Symbol>();
		for (s in obj.symbols)
			if (s.section != null && s.global) defs.set(s.name, s);
		// a symbol the bundle does not define: a number, an address of the
		// bundle's (rows, scalars, type objects), an interpreted function's
		// entry (the function of this bundle's or an earlier one's descriptor),
		// the compiler's or an earlier bundle's
		function outside(n:String):{v:I64, tls:Bool} {
			var nv = num.get(n);
			if (nv != null) return {v: nv, tls: false};
			var x = extra.get(n);
			if (x != null) return {v: x.toI64(), tls: false};
			var dn = hxmc.interp.InterpGen.DESC + n;
			var d = defs.get(dn);
			// (the descriptor's flags from the bundle's bytes: its memory is written after the relocations)
			if (d != null) return {v: entry(dn, ptr(addr.get(d.section) + d.offset), d.section.buf.b.getInt32(d.offset + hxmc.interp.InterpGen.H_FLAGS)).toI64(), tls: false};
			var xd = xb.get(dn);
			if (xd != null) return {v: entry(dn, ptr(xd.v), Mem.getI32(ptr(xd.v), hxmc.interp.InterpGen.H_FLAGS)).toI64(), tls: false};
			var hs = h.get(n);
			if (hs == null) hs = xb.get(n);
			if (hs != null) return {v: hs.v, tls: hs.k == "l"};
			var dyn = systemSymbol(n);
			if (!dyn.isNull()) return {v: dyn.toI64(), tls: false};
			// (a definition in another object of the bundle: one object here)
			throw "undefined symbol " + n;
		}
		function value(s:Symbol):{v:I64, tls:Bool} {
			if (s.section != null) return {v: addr.get(s.section) + s.offset, tls: false};
			if (s.abs) return {v: s.offset, tls: false};
			return outside(s.name);
		}
		function resolve(s:Symbol):{v:I64, tls:Bool}
			return s.section == null && defs.exists(s.name) ? value(defs.get(s.name)) : value(s);
		// ---- relocation
		dbg("relocation");
		for (sec in obj.sections) {
			if (!addr.exists(sec) || sec.kind == Bss) continue;
			var at = addr.get(sec);
			var buf = sec.buf;
			for (r in sec.relocs) {
				var sv = resolve(r.sym);
				var v = sv.v + r.addend;
				switch r.kind {
					case RAbs64:
						buf.set64(r.offset, v.toInt(), (v >> 32).toInt());
					case RAbs32 | RAbs32S:
						// (a number)
						if (v >> 31 != (0 : I64) && v >> 31 != (-1 : I64)) throw "a 32-bit relocation against " + r.sym.name + " beyond 32 bits";
						buf.set32(r.offset, v.toInt());
					case _:
						throw "relocation " + r.kind + " against " + r.sym.name + " in a bundle for the Mir interpreter";
				}
			}
			var p = ptr(at);
			for (i in 0...buf.len)
				Mem.setI8(p, i, buf.b.get(i));
		}
		b.codeBytes = 0;
		b.dataBytes = size;
		function symAddr(n:String):I64 {
			var d = defs.get(n);
			return d != null ? value(d).v : outside(n).v;
		}
		// a function to run: its descriptor
		function runnable(n:String):Ptr {
			var d = defs.get(hxmc.interp.InterpGen.DESC + n);
			if (d != null) return ptr(value(d).v);
			var xd = xb.get(hxmc.interp.InterpGen.DESC + n);
			if (xd == null) throw "no descriptor of " + n;
			return ptr(xd.v);
		}
		// ---- dispatch rows
		dbg("dispatch rows");
		for (k in 0...selectors.length) {
			var row = ptr(base + rowsAt + rowBytes * k);
			// (the compiler's rows of the same selector first: the bundle's code is handed
			// objects of the compiler's own classes, which only it implements: hostOverrides)
			var hs = h.get(selectors[k].sym);
			if (hs != null && hs.k == "d") LibC.memcpy(row, ptr(hs.v), (8 * (hostNtypes - Abi.T_FIRST) : I64));
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
			// a class's entry for Type.createInstance (DataGen, Types.maker: 1 no
			// constructor, 2 + its signature the function at 88)
			var mk:Dynamic = t.maker;
			if (mk != null && mk.fn == null) Mem.setI32(e, 84, 1);
			if (mk != null && mk.fn != null) {
				Mem.setI32(e, 84, 2 + num.get(mk.sig));
				Mem.setPtr(e, 88, ptr(symAddr(mk.fn)));
			}
		}
		// the new classes', interfaces' and enums' statics (rt_static: fid, kind, index, rank,
		// address; the bundle has them in the order Type.getClassFields lists them)
		var interfaces:Array<Dynamic> = facts.interfaces, enumStatics:Array<Dynamic> = facts.enumStatics;
		for (c in classes.concat(interfaces == null ? [] : interfaces).concat(enumStatics == null ? [] : enumStatics)) {
			var ss:Array<Dynamic> = c.statics;
			if (!isNew.exists(c.ty) || ss == null || ss.length == 0) continue;
			var order = [for (i in 0...ss.length) i];
			order.sort((a, b) -> fids.get(ss[a].name) - fids.get(ss[b].name));
			var p = zalloc(24 * ss.length);
			for (i in 0...ss.length) {
				var s = ss[order[i]];
				var kind:String = s.kind;
				Mem.setI32(p, 24 * i, fids.get(s.name));
				Mem.setI32(p, 24 * i + 4, kind.charCodeAt(0));
				Mem.setI32(p, 24 * i + 12, order[i]);
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
		if (emptyAnon < 0) {
			if (nextType >= hostNtypes + MirHost.SPARE_TYPES) throw "out of spare type entries: the bundles loaded have " + MirHost.SPARE_TYPES + " types the compiler lacks (hxmc.macro.MirHost.SPARE_TYPES)";
			emptyAnon = nextType++;
			var ee = Mem.sym("rt_types").add(emptyAnon * TS);
			Mem.setPtr(ee, 0, cstr("{}"));
			Mem.setI32(ee, 8, 5);
			Mem.setI32(ee, 12, -1);
			Mem.setI32(ee, 16, 1);
			var epm = zalloc(8);
			Mem.setI32(epm, 0, 1);
			Mem.setPtr(ee, 24, epm);
		}
		b.shapes.push({tindex: emptyAnon, fields: []});
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
		// (in its spare slots, never moved: compiled code, the frames running now
		// included, keeps the table's address across calls, Opt.MConst)
		if (nglobals > Gc.globalsCap) throw "out of spare global slots";
		if (nglobals > Gc.nglobals) Gc.nglobals = nglobals;
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
		var run = [];
		for (i in inits)
			// (a class without a type entry: new unless a bundle loaded before, or for
			// the std the compiler, has its initializer)
			if (i.ty != null ? isNew.exists(i.ty) : !(xb.exists(i.fn) || xb.exists(hxmc.interp.InterpGen.DESC + i.fn) || (i.share && h.exists(i.fn)))) {
				var p = runnable(i.fn);
				b.inits.push(p);
				b.initKeys.push(i.key);
				b.initPaths.push(i.cls);
				b.initMods.push(i.mod);
				// (a kept class's statics have their values: it runs when a compilation resets them)
				if (i.keep != true) run.push(p);
			}
		// what the next bundles share: the numbers, the globals and type objects, the functions
		for (n => v in num)
			xb.set(n, {k: "a", v: v});
		for (n => p in extra)
			if (!StringTools.startsWith(n, "DSP_")) xb.set(n, {k: "d", v: p.toI64()}) else rows.set(n, p.toI64());
		for (n => s in defs)
			if (StringTools.startsWith(n, hxmc.interp.InterpGen.DESC)) xb.set(n, {k: "d", v: value(s).v});
		// (the runtime's walks of the types, Type.resolveClass, reach the new ones)
		Mem.setI32(Mem.sym("rt_ntypes"), 0, nextType);
		// (run once the bundle is shared: a function they call may be compiled
		// then, against it, interp.MirMacros)
		for (p in run)
			run0(p);
		var ens:Array<Dynamic> = facts.entries;
		for (en in ens)
			b.entries.set(en.name, runnable(en.sym));
		return b;
	}

	// a function compiled after its bundle (interp.MirMacros: on its first
	// call), its object alone (its descriptor, its literals): linked against
	// the bundles of its generation (gen: xb, entries and rows as they were
	// then, which have every number it uses), then the compiler; its
	// descriptor's address. Dispatch rows: the selector's latest, which has
	// the types of every bundle loaded since.
	public static function loadLate(obj:Obj, desc:String, gen:Gen):Ptr {
		var h = hostSyms();
		var defs = new Map<String, Symbol>();
		for (s in obj.symbols)
			if (s.section != null && s.global) defs.set(s.name, s);
		var addr = new Map<Section, I64>();
		var pos = 0;
		for (s in obj.sections) {
			if (s.kind == Text && s.size() > 0) throw "code in a bundle for the Mir interpreter: section " + s.name + " (" + s.size() + " bytes)";
			if (s.kind != RoData && s.kind != Data && s.kind != Bss) continue;
			pos = (pos + s.align - 1) & ~(s.align - 1);
			addr.set(s, pos);
			pos += s.size();
		}
		var region = LibC.malloc(((pos < 8 ? 8 : pos) : I64));
		if (region.isNull()) throw "no memory for a bundle";
		LibC.memset(region, 0, ((pos < 8 ? 8 : pos) : I64));
		for (s in addr.keys())
			addr.set(s, addr.get(s) + region.toI64());
		function value(s:Symbol):I64 {
			if (s.section != null) return addr.get(s.section) + s.offset;
			if (s.abs) return s.offset;
			var d = defs.get(s.name);
			if (d != null) return value(d);
			var n = s.name;
			var x = gen.xb.get(n);
			if (x != null) return x.v;
			if (StringTools.startsWith(n, "DSP_") && gen.rows.exists(n)) return gen.rows.get(n);
			var dn = hxmc.interp.InterpGen.DESC + n;
			var dd = defs.get(dn);
			if (dd != null) return entryOf(gen.entries, dn, ptr(value(dd)), dd.section.buf.b.getInt32(dd.offset + hxmc.interp.InterpGen.H_FLAGS)).toI64();
			var xd = gen.xb.get(dn);
			if (xd != null) return entryOf(gen.entries, dn, ptr(xd.v), Mem.getI32(ptr(xd.v), hxmc.interp.InterpGen.H_FLAGS)).toI64();
			var hs = h.get(n);
			if (hs != null) return hs.v;
			var sys = systemSymbol(n);
			if (!sys.isNull()) return sys.toI64();
			throw "undefined symbol " + n;
		}
		for (sec in obj.sections) {
			if (!addr.exists(sec) || sec.kind == Bss) continue;
			var buf = sec.buf;
			for (r in sec.relocs) {
				var v = value(r.sym) + r.addend;
				switch r.kind {
					case RAbs64:
						buf.set64(r.offset, v.toInt(), (v >> 32).toInt());
					case RAbs32 | RAbs32S:
						if (v >> 31 != (0 : I64) && v >> 31 != (-1 : I64)) throw "a 32-bit relocation against " + r.sym.name + " beyond 32 bits";
						buf.set32(r.offset, v.toInt());
					case _:
						throw "relocation " + r.kind + " against " + r.sym.name + " in a bundle for the Mir interpreter";
				}
			}
			var p = ptr(addr.get(sec));
			for (i in 0...buf.len)
				Mem.setI8(p, i, buf.b.get(i));
		}
		lateBytes += pos;
		var d = defs.get(desc);
		if (d == null) throw "no descriptor " + desc;
		return ptr(value(d));
	}

	// the bytes of the functions loaded after their bundles (HXMC_MACRO_STATS)
	public static var lateBytes = 0;

	// null when the compiler's type `idx` has the bundle's layout (slots, pointer map, fields)
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

// (Loader.systemSymbol: each used only on its system, the others fold its calls away, Mem.os)
@:hxmc.c @:hxmc.fast private extern class SysDl {
	static function dlsym(handle:Ptr, name:Ptr):Ptr;
}

@:hxmc.c @:hxmc.fast @:hxmc.lib("kernel32") private extern class SysDll {
	static function GetModuleHandleA(name:Ptr):Ptr;
	static function LoadLibraryA(name:Ptr):Ptr;
	static function GetProcAddress(module:Ptr, name:Ptr):Ptr;
}
