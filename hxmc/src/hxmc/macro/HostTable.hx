package hxmc.macro;

import hxmc.Obj;

// What code loaded into a Mir host (a compiler with Mir macros, Mem.mirHost) links against
// (macro.Loader), carried by the compiler itself as data: its symbols that
// such code can reach (functions, data, program-wide numbers, thread-local
// variables, imports) and its functions' fingerprints (interp.MirRun.
// hostFunctions: the std's functions it has alike) with what callers need
// to know of them (HostFps flags). Built when the compiler is linked (Driver, `build`):
// the addresses are offsets the linker computes from each value's own place
// (no relocation for the system's loader, no slide to apply), and nothing is
// read from files next to the executable.
//
// What it names (`named`): code loaded at run time is compiled from the std
// and the macro context's own code, so of the compiler's entities it reaches
// the std's and the runtime's functions, types and statics (BundleFacts.facts
// shares nothing else), the C functions, the runtime's tables and the
// signatures' and dispatch rows' symbols. Not named: the compiler's own
// classes, the field ids (the Loader takes them from the runtime's table of
// names, Dyn.fid, which numbers them alike), the allocation stubs and string
// literals (native code's, a bundle has its own).
//
// The encoding: each set (the symbols, the fingerprints) has a minimal
// perfect hash with a little slack (PTHash's scheme: a name's 64-bit hash,
// `hash`, picks a bucket by its high word; the bucket's 16-bit pilot, mixed
// with the low word, picks the slot), so a lookup reads three entries and
// stores no key. Each slot holds the high word as its check, which rejects
// a name the set lacks but for 1 in 2^32. The table (the symbol
// hxmc_host_table): 8 32-bit words (the symbols' slots ns and buckets nb,
// the fingerprints' slots ms and buckets mb, the table's bytes, the bound
// imports' count ng, 0, 0); the symbols' pilots (16 bits each, then to 4
// bytes), checks and values (32 bits each) and kinds (4 bits each: 0 an
// empty slot, 1 code, 2 data, 3 an absolute number, 4 a thread-local
// variable, 5 an import bound in place: its 64-bit slot), to 8 bytes; the
// bound imports' slots (64 bits each); the fingerprints' pilots, checks,
// keys (two 32-bit words) and flags (8 bits), to 8 bytes. A value is a
// number for kind 3, for code, data and a
// bound import's slot the 32-bit offset of the address from the value's own
// place, 0 for a thread-local variable (its accessors are the compiler's:
// InterpAbi.tlsAccessors).
class HostTable {
	public static inline var SYM = "hxmc_host_table";

	static inline var K_NONE = 0;
	static inline var K_CODE = 1;
	static inline var K_DATA = 2;
	static inline var K_ABS = 3;
	static inline var K_TLS = 4;
	static inline var K_BOUND = 5;

	// the key of a name (`lo`, `hi`: no allocation; murmur3's and FNV-1a's
	// mixing, as Fingerprint.hash)
	public static var lo = 0;
	public static var hi = 0;

	public static function hash(s:String) {
		var h1 = 0x811c9dc5, h2 = 0x2545f491;
		for (i in 0...s.length) {
			var c = StringTools.fastCodeAt(s, i);
			h1 = (h1 ^ c) * 0x01000193;
			h2 = (h2 ^ c) * 0x5bd1e995;
			h2 ^= h2 >>> 15;
		}
		h1 ^= s.length;
		h1 = (h1 ^ (h1 >>> 16)) * 0x85ebca6b;
		h2 = (h2 ^ (h2 >>> 13)) * 0xc2b2ae35;
		lo = h1 ^ (h2 >>> 7);
		hi = h2 ^ (h1 >>> 11);
	}

	// x mod n, x taken as unsigned
	static inline function umod(x:Int, n:Int):Int
		return (((x >>> 1) % n) * 2 + (x & 1)) % n;

	// murmur3's finalizer
	static inline function fmix(h:Int):Int {
		h ^= h >>> 16;
		h *= 0x85ebca6b;
		h ^= h >>> 13;
		h *= 0xc2b2ae35;
		return h ^ (h >>> 16);
	}

	// the slot of a key of a set of `slots` slots, with its bucket's pilot
	static inline function slotOf(lo:Int, pilot:Int, slots:Int):Int
		return umod(fmix(lo ^ (pilot * 0x9E3779B1)), slots);

	static function hex8(s:String, at:Int):Int {
		var v = 0;
		for (i in at...at + 8) {
			var c = StringTools.fastCodeAt(s, i);
			v = (v << 4) | (c >= "a".code ? c - "a".code + 10 : c >= "A".code ? c - "A".code + 10 : c - "0".code);
		}
		return v;
	}

	// ---- building (the compiler's link, a Mir host)

	// the perfect hash of a set of keys: each key's slot, the buckets' pilots
	// and the number of slots (n and a 1/32nd of slack; more when no pilot fits)
	static function perfect(keys:Array<{lo:Int, hi:Int}>):{slot:Array<Int>, pilots:Array<Int>, slots:Int} {
		var n = keys.length;
		var slack = 32;
		while (true) {
			var slots = n + Std.int(n / slack) + 1;
			var nb = Std.int(n / 4) + 1;
			var buckets:Array<Array<Int>> = [for (_ in 0...nb) []];
			for (k in 0...n)
				buckets[umod(keys[k].hi, nb)].push(k);
			var order = [for (b in 0...nb) b];
			order.sort((a, b) -> buckets[b].length - buckets[a].length);
			var taken = [for (_ in 0...slots) false];
			var slot = [for (_ in 0...n) -1];
			var pilots = [for (_ in 0...nb) 0];
			var ok = true;
			for (b in order) {
				var ks = buckets[b];
				if (ks.length == 0) continue;
				var found = false;
				for (p in 0...65536) {
					var fits = true;
					var mine = [];
					for (k in ks) {
						var s = slotOf(keys[k].lo, p, slots);
						if (taken[s] || mine.indexOf(s) >= 0) {
							fits = false;
							break;
						}
						mine.push(s);
					}
					if (!fits) continue;
					for (i in 0...ks.length) {
						taken[mine[i]] = true;
						slot[ks[i]] = mine[i];
					}
					pilots[b] = p;
					found = true;
					break;
				}
				if (!found) {
					ok = false;
					break;
				}
			}
			if (ok) return {slot: slot, pilots: pilots, slots: slots};
			slack = slack >> 1;
			if (slack == 0) throw "hxmc: the host table: no perfect hash";
		}
	}

	// the table of the symbols the objects define that `named` keeps (they and
	// the table's own object are linked together) and the imports
	// (`imports`: bound by the system's loader), with the fingerprints
	// (symbol, Fingerprint.key, HostFps flags)
	public static function build(objs:Array<Obj>, abi:Abi, fps:Array<{sym:String, key:String, flags:Int}>, imports:Array<String>,
			named:String->Bool, ?stats:Bool):Obj {
		var obj = new Obj();
		var defs = new Map<String, Symbol>();
		var names = [];
		for (o in objs)
			for (s in o.symbols)
				if (s.global && (s.section != null || s.abs) && !defs.exists(s.name) && named(s.name)) {
					defs.set(s.name, s);
					names.push(s.name);
				}
		// (macOS binds the imports in place, in 64-bit slots; Windows calls them through thunks in the image)
		var bound = abi.os == "macos";
		var boundOf = new Map<String, Int>();
		for (n in imports)
			if (!defs.exists(n)) {
				if (bound) boundOf.set(n, Lambda.count(boundOf));
				names.push(n);
			}
		var rows = [];
		var seen = new Map<String, String>();
		for (n in names) {
			var s = defs.get(n);
			var kind = s == null ? (bound ? K_BOUND : K_CODE) : s.abs ? K_ABS : threadLocal(s) ? K_TLS : switch s.section.kind {
				case Text: K_CODE;
				case _: K_DATA;
			};
			hash(n);
			var k = hi + ":" + lo;
			if (seen.exists(k)) throw 'hxmc: the host table: ${seen.get(k)} and $n have the same key (HostTable.hash)';
			seen.set(k, n);
			rows.push({name: n, lo: lo, hi: hi, kind: kind, sym: s});
		}
		var ph = perfect(rows);
		var frows = [];
		for (f in fps) {
			hash(f.sym);
			frows.push({lo: lo, hi: hi, d1: hex8(f.key, 0), d2: hex8(f.key, 8), flags: f.flags});
		}
		var fh = perfect(frows);
		var sec = obj.section(".data", SecKind.Data, 16);
		var b = sec.buf;
		var start = b.len;
		var ns = ph.slots, ms = fh.slots, ng = Lambda.count(boundOf);
		for (v in [ns, ph.pilots.length, ms, fh.pilots.length, 0, ng, 0, 0])
			b.u32(v);
		var tsym = obj.sym(SYM);
		// the symbols
		for (p in ph.pilots)
			b.u16(p);
		b.align(4);
		var byslot = [for (_ in 0...ns) -1];
		for (r in 0...rows.length)
			byslot[ph.slot[r]] = r;
		for (s in 0...ns)
			b.u32(byslot[s] < 0 ? 0 : rows[byslot[s]].hi);
		var valuesAt = b.len;
		for (s in 0...ns)
			b.u32(0);
		var kindsAt = b.len;
		b.zeros((ns + 1) >> 1);
		b.align(8);
		var boundAt = b.len;
		for (_ in 0...ng)
			b.u64(0, 0);
		for (s in 0...ns) {
			var ri = byslot[s];
			if (ri < 0) continue;
			var r = rows[ri];
			b.set8(kindsAt + (s >> 1), b.get8(kindsAt + (s >> 1)) | (r.kind << ((s & 1) * 4)));
			var at = valuesAt + 4 * s;
			switch r.kind {
				case K_ABS:
					b.set32(at, r.sym.offset);
				case K_TLS:
				case K_BOUND:
					var g = boundAt + 8 * boundOf.get(r.name);
					sec.relocs.push(new Reloc(g, RelKind.RAbs64, obj.sym(r.name), 0));
					sec.relocs.push(new Reloc(at, RelKind.RPc32, tsym, g - start));
				case _:
					sec.relocs.push(new Reloc(at, RelKind.RPc32, obj.sym(r.name), 0));
			}
		}
		// the fingerprints
		for (p in fh.pilots)
			b.u16(p);
		b.align(4);
		var fslot = [for (_ in 0...ms) -1];
		for (r in 0...frows.length)
			fslot[fh.slot[r]] = r;
		for (s in 0...ms)
			b.u32(fslot[s] < 0 ? 0 : frows[fslot[s]].hi);
		for (s in 0...ms) {
			var r = fslot[s] < 0 ? null : frows[fslot[s]];
			b.u32(r == null ? 0 : r.d1);
			b.u32(r == null ? 0 : r.d2);
		}
		for (s in 0...ms)
			b.u8(fslot[s] < 0 ? 0xff : frows[fslot[s]].flags);
		b.align(8);
		b.set32(start + 16, b.len - start);
		obj.define(SYM, sec, start, b.len - start, true);
		if (stats)
			Sys.println('hxmc: host table: ${rows.length} symbols in $ns slots (${ng} bound imports), ${frows.length} fingerprints in $ms slots; ${b.len - start} bytes');
		return obj;
	}

	// whether the table names the symbol n (code loaded at run time can reach
	// it, above): not the compiler's own classes' and enums' entities (the
	// symbols of a class's ident, then _ or the end: `idents`, true for the
	// std's), the field ids, the allocation stubs, the pools' entries and the
	// string literals; everything else
	public static function named(n:String, idents:Map<String, Bool>):Bool {
		if (StringTools.startsWith(n, "S_") || StringTools.startsWith(n, "hxmc_new")
			|| StringTools.startsWith(n, "hxmc_interp_pe$")) return false;
		var u = n.indexOf("_");
		if (u < 0) return true;
		switch n.substr(0, u) {
			case "F" | "TY" | "TYOBJ" | "TYSPAN" | "G" | "GI" | "GIOFF":
				// (the longest ident it starts with decides)
				var rest = n.substr(u + 1);
				var std = idents.get(rest);
				if (std != null) return std;
				var at = rest.lastIndexOf("_");
				while (at > 0) {
					std = idents.get(rest.substr(0, at));
					if (std != null) return std;
					at = rest.lastIndexOf("_", at - 1);
				}
				return true;
			case _:
				return true;
		}
	}

	// the program's types by their idents (`named`: the prefix of their
	// symbols, Lower.ident): true for the std's (from the files of hxmc's std,
	// with the runtime, and of the std's class paths: BundleFacts.facts shares
	// the same), false for the compiler's own
	public static function idents(com:context.Common.CommonContext):Map<String, Bool> {
		var roots = [];
		for (cp in com.classPaths.asList())
			if (cp.path != "" && (cp.scope == Std || sys.FileSystem.exists(haxe.io.Path.addTrailingSlash(cp.path) + "hxmc/rt/Runtime.hx")))
				roots.push(cp.path);
		var r = new Map<String, Bool>();
		for (t in com.types) {
			var info = core.TFunctions.tInfos(t);
			var std = false;
			for (root in roots)
				if (StringTools.startsWith(info.mtPos.pfile, root)) std = true;
			r.set(hxmc.ir.Lower.ident(info.mtPath.pack, info.mtPath.name), std);
		}
		return r;
	}

	// the functions the system's loader binds the compiler to, by name
	// (Windows: its DLL imports, LinkInputs.peImports, through their thunks;
	// macOS: what libSystem and the dylibs define, bound in place): code
	// loaded at run time finds them in the table as the compiler's own (on
	// Linux the static executable has them). Weak references are left out
	// (a missing one is null), and so are the names the Mach-O linker defines.
	public static function imports(objs:Array<Obj>, abi:Abi):Array<String> {
		if (abi.os != "windows" && abi.os != "macos") return [];
		var defined = new Map<String, Bool>(), weak = new Map<String, Bool>();
		for (o in objs)
			for (s in o.symbols)
				if (s.global && (s.section != null || s.abs)) defined.set(s.name, true);
		var r = [], seen = new Map<String, Bool>();
		for (o in objs)
			for (s in o.symbols)
				if (s.global && s.section == null && !s.abs && !defined.exists(s.name)) {
					if (s.weak) weak.set(s.name, true);
					if (!seen.exists(s.name)) {
						seen.set(s.name, true);
						r.push(s.name);
					}
				}
		r.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		// (Windows: the code the objects' import lists name, the runtime
		// object's and LinkInputs.peImports': DLL, symbol, name, kind)
		var code = new Map<String, Bool>();
		if (abi.os == "windows")
			for (o in objs)
				for (s in o.sections)
					if (s.name == ".hxmc.imports")
						for (l in s.buf.toBytes().toString().split("\n")) {
							var f = l.split("\t");
							if (f.length >= 4 && f[3] == "code") code.set(f[1], true);
						}
		return [for (n in r) if (!weak.exists(n) && (abi.os == "windows" ? code.exists(n) : !MACHO_LINKER.contains(n))) n];
	}

	static final MACHO_LINKER = ["__dso_handle", "hxmc_tls_start", "hxmc_tls_base"];

	// a thread-local variable (Mach-O: its symbol names its descriptor in
	// __thread_vars, DataGen.tbssGlobal)
	static function threadLocal(s:Symbol):Bool
		return s.section.kind == Tdata || s.section.kind == Tbss || StringTools.endsWith(s.section.name, "__thread_vars");

	// the thread-local variables the objects define (their accessors: InterpAbi.tlsAccessors)
	public static function tlsNames(objs:Array<Obj>):Array<String> {
		var r = [], seen = new Map<String, Bool>();
		for (o in objs)
			for (s in o.symbols)
				if (s.global && s.section != null && threadLocal(s) && !seen.exists(s.name)) {
					seen.set(s.name, true);
					r.push(s.name);
				}
		r.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		return r;
	}

	// ---- reading (the running compiler, a Mir host: Mem.mirHost)

	static var base:Null<hxmc.unsafe.Ptr> = null;
	static var ns = 0;
	static var nb = 0;
	static var ms = 0;
	static var mb = 0;
	static var pilots:hxmc.unsafe.Ptr;
	static var checks:hxmc.unsafe.Ptr;
	static var values:hxmc.unsafe.Ptr;
	static var kinds:hxmc.unsafe.Ptr;
	static var fpilots:hxmc.unsafe.Ptr;
	static var fchecks:hxmc.unsafe.Ptr;
	static var fkeys:hxmc.unsafe.Ptr;
	static var fflags:hxmc.unsafe.Ptr;

	static function init() {
		if (base != null) return;
		var t = hxmc.unsafe.Mem.sym(SYM);
		ns = hxmc.unsafe.Mem.getI32(t, 0);
		nb = hxmc.unsafe.Mem.getI32(t, 4);
		ms = hxmc.unsafe.Mem.getI32(t, 8);
		mb = hxmc.unsafe.Mem.getI32(t, 12);
		var ng = hxmc.unsafe.Mem.getI32(t, 20);
		var at = 32;
		pilots = t.add(at);
		at = (at + 2 * nb + 3) & ~3;
		checks = t.add(at);
		at += 4 * ns;
		values = t.add(at);
		at += 4 * ns;
		kinds = t.add(at);
		at = (at + ((ns + 1) >> 1) + 7) & ~7;
		at += 8 * ng;
		fpilots = t.add(at);
		at = (at + 2 * mb + 3) & ~3;
		fchecks = t.add(at);
		at += 4 * ms;
		fkeys = t.add(at);
		at += 8 * ms;
		fflags = t.add(at);
		base = t;
	}

	// (HXMC_MACRO_STATS=1: the lookups and their time)
	static final timed = Sys.getEnv("HXMC_MACRO_STATS") == "1";
	public static var lookups = 0;
	public static var lookupTime = 0.0;

	// the slot of name in a set (its pilots and checks, nb buckets, `slots` slots), -1 when the set lacks it
	static function find(pilots:hxmc.unsafe.Ptr, checks:hxmc.unsafe.Ptr, nb:Int, slots:Int, name:String):Int {
		lookups++;
		var t = timed ? haxe.Timer.stamp() : 0.0;
		hash(name);
		var r = -1;
		if (slots > 0) {
			var s = slotOf(lo, hxmc.unsafe.Mem.getU16(pilots, 2 * umod(hi, nb)), slots);
			if (hxmc.unsafe.Mem.getI32(checks, 4 * s) == hi) r = s;
		}
		if (timed) lookupTime += haxe.Timer.stamp() - t;
		return r;
	}

	// the symbol named name: its slot (kind, value), or -1
	public static function symbol(name:String):Int {
		init();
		var s = find(pilots, checks, nb, ns, name);
		return s >= 0 && kindOf(s) != K_NONE ? s : -1;
	}

	static inline function kindOf(s:Int):Int
		return (hxmc.unsafe.Mem.getU8(kinds, s >> 1) >> ((s & 1) * 4)) & 15;

	// the kind of a symbol: t code (an import too), d data, a an absolute number, l a thread-local variable
	public static function kind(s:Int):Int
		return switch kindOf(s) {
			case K_DATA: "d".code;
			case K_ABS: "a".code;
			case K_TLS: "l".code;
			case _: "t".code;
		};

	public static function value(s:Int):hxmc.I64 {
		var v = hxmc.unsafe.Mem.getI32(values, 4 * s);
		var place = values.add(4 * s);
		return switch kindOf(s) {
			case K_ABS: (v : hxmc.I64);
			case K_TLS: (0 : hxmc.I64);
			case K_BOUND: hxmc.unsafe.Mem.getI64(place.add(v), 0);
			case _: place.add(v).toI64();
		};
	}

	// the fingerprint slot of a function's symbol, or -1
	public static function fingerprint(name:String):Int {
		init();
		var s = find(fpilots, fchecks, mb, ms, name);
		return s >= 0 && hxmc.unsafe.Mem.getU8(fflags, s) != 0xff ? s : -1;
	}

	public static function fpKey(s:Int):String
		return StringTools.hex(hxmc.unsafe.Mem.getI32(fkeys, 8 * s), 8) + StringTools.hex(hxmc.unsafe.Mem.getI32(fkeys, 8 * s + 4), 8);

	public static function fpFlags(s:Int):Int
		return hxmc.unsafe.Mem.getU8(fflags, s);

	// the table's bytes (HXMC_MACRO_STATS)
	public static function bytes():Int {
		init();
		return hxmc.unsafe.Mem.getI32(base, 16);
	}

	// its symbols' slots
	public static function count():Int {
		init();
		return ns;
	}
}

// The compiler's symbols (HostTable): kind (t, d, a, l) and value, by name
class HostSyms {
	public function new() {}

	inline function row(name:String):Int
		return HostTable.symbol(name);

	public function get(name:String):Null<{k:String, v:hxmc.I64}> {
		var r = row(name);
		return r < 0 ? null : {k: String.fromCharCode(HostTable.kind(r)), v: HostTable.value(r)};
	}

	public function exists(name:String):Bool
		return row(name) >= 0;
}

// The compiler's functions' fingerprints and flags (HostTable; at the
// compiler's link: the map being written)
class HostFps {
	// the flags: what Facts found of the function (FuncInfo.noGc, blocks),
	// and whether it may be inlined (Inline.candidate)
	public static inline var NO_GC = 1;
	public static inline var BLOCKS = 2;
	public static inline var INLINE = 4;

	final map:Null<Map<String, {key:String, flags:Int}>>;

	// (map: the compiler being linked's own; none: the running compiler's, HostTable)
	public function new(?map:Map<String, {key:String, flags:Int}>)
		this.map = map;

	public function get(name:String):Null<String> {
		if (map != null) {
			var x = map.get(name);
			return x == null ? null : x.key;
		}
		if (hxmc.unsafe.Mem.mirHost() == 1) {
			var r = HostTable.fingerprint(name);
			return r < 0 ? null : HostTable.fpKey(r);
		}
		return null;
	}

	// the flags of the compiler's function of that symbol, -1 when it has none
	public function flags(name:String):Int {
		if (map != null) {
			var x = map.get(name);
			return x == null ? -1 : x.flags;
		}
		if (hxmc.unsafe.Mem.mirHost() == 1) {
			var r = HostTable.fingerprint(name);
			return r < 0 ? -1 : HostTable.fpFlags(r);
		}
		return -1;
	}
}
