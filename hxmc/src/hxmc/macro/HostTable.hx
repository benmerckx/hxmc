package hxmc.macro;

import hxmc.Obj;

// What code loaded into a compiler built with -D hxmc.jit links against
// (macro.Loader), carried by the compiler itself as data: its global
// symbols (functions, data, program-wide numbers, thread-local variables)
// and its functions' fingerprints (interp.MirRun.hostFunctions: the std's
// functions it has alike) with what callers need to know of them
// (HostFps flags), and the bodies its macro context need not parse
// (MacroCuts). Built when the compiler is linked (Driver, `build`): the
// values are relocations of the executable's own, so the system's loader
// moves them with the image (no slide to apply), and nothing is read from
// files next to the executable.
//
// The table (the symbol hxmc_host_table, 8-byte words): the number of
// symbols n, of fingerprints m, the bytes of the cuts, 0; then the symbols'
// keys (a 64-bit hash of the name, `hash`: its low, then high 32 bits),
// sorted, n words; their values, n words; their kinds (t code, d data, a an
// absolute number, l a thread-local variable: its thread-pointer offset on
// x86-64, else 0), n bytes; the fingerprints' keys, sorted, m words; per
// fingerprint its two 32-bit halves and its flags, m 12-byte rows; the cuts
// (MacroCuts' lines). A name's key is unique among the compiler's names
// (`build` checks); a name the compiler lacks matches one only by a hash
// collision, about 1 in 2^48 per lookup with the table's 70k names.
// String literals (S_*) are left out: code loaded at run time has its own.
class HostTable {
	public static inline var SYM = "hxmc_host_table";

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

	// unsigned order of keys (hi, lo)
	static inline function before(ahi:Int, alo:Int, bhi:Int, blo:Int):Bool
		return ahi != bhi ? (ahi ^ 0x80000000) < (bhi ^ 0x80000000) : (alo ^ 0x80000000) < (blo ^ 0x80000000);

	static function hex8(s:String, at:Int):Int {
		var v = 0;
		for (i in at...at + 8) {
			var c = StringTools.fastCodeAt(s, i);
			v = (v << 4) | (c >= "a".code ? c - "a".code + 10 : c >= "A".code ? c - "A".code + 10 : c - "0".code);
		}
		return v;
	}

	// ---- building (the compiler's link, -D hxmc.jit)

	// the table of the global symbols the objects define (they and the
	// table's own object are linked together), with the fingerprints
	// (symbol, Fingerprint.key, HostFps flags) and the cuts
	// and the imports (`imports`: their values bound by the system's loader)
	public static function build(objs:Array<Obj>, abi:Abi, fps:Array<{sym:String, key:String, flags:Int}>, cuts:String, imports:Array<String>):Obj {
		var obj = new Obj();
		var defs = new Map<String, Symbol>();
		var names = [];
		for (o in objs)
			for (s in o.symbols)
				if (s.global && (s.section != null || s.abs) && !defs.exists(s.name) && !StringTools.startsWith(s.name, "S_")
					&& !StringTools.startsWith(s.name, "hxmc_interp_pe$")) {
					defs.set(s.name, s);
					names.push(s.name);
				}
		for (n in imports)
			if (!defs.exists(n)) names.push(n);
		var rows = [];
		var seen = new Map<String, String>();
		for (n in names) {
			var s = defs.get(n);
			var kind = s == null ? "t".code : s.abs ? "a".code : switch s.section.kind {
				case Text: "t".code;
				case Tdata | Tbss: "l".code;
				case _: "d".code;
			};
			hash(n);
			var k = hi + ":" + lo;
			if (seen.exists(k)) throw 'hxmc: the host table: ${seen.get(k)} and $n have the same key (HostTable.hash)';
			seen.set(k, n);
			rows.push({name: n, lo: lo, hi: hi, kind: kind});
		}
		rows.sort((a, b) -> before(a.hi, a.lo, b.hi, b.lo) ? -1 : before(b.hi, b.lo, a.hi, a.lo) ? 1 : 0);
		var frows = [];
		for (f in fps) {
			hash(f.sym);
			frows.push({lo: lo, hi: hi, d1: hex8(f.key, 0), d2: hex8(f.key, 8), flags: f.flags});
		}
		frows.sort((a, b) -> before(a.hi, a.lo, b.hi, b.lo) ? -1 : before(b.hi, b.lo, a.hi, a.lo) ? 1 : 0);
		var cutBytes = haxe.io.Bytes.ofString(cuts);
		var sec = obj.section(".data", SecKind.Data, 16);
		var b = sec.buf;
		var start = b.len;
		b.u64(rows.length, 0);
		b.u64(frows.length, 0);
		b.u64(cutBytes.length, 0);
		b.u64(0, 0);
		for (r in rows) {
			b.u32(r.lo);
			b.u32(r.hi);
		}
		for (r in rows) {
			if (r.kind == "l".code) {
				// (x86-64's local-exec offset: the native macros' code reaches it so)
				if (abi.os == "linux" && !abi.arm) sec.relocs.push(new Reloc(b.len, RelKind.RTpOff32, obj.sym(r.name), 0));
			} else
				sec.relocs.push(new Reloc(b.len, RelKind.RAbs64, obj.sym(r.name), 0));
			b.u64(0, 0);
		}
		for (r in rows)
			b.u8(r.kind);
		b.align(8);
		for (r in frows) {
			b.u32(r.lo);
			b.u32(r.hi);
		}
		for (r in frows) {
			b.u32(r.d1);
			b.u32(r.d2);
			b.u32(r.flags);
		}
		b.bytes(cutBytes);
		obj.define(SYM, sec, start, b.len - start, true);
		return obj;
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

	// the thread-local variables the objects define (their accessors: InterpAbi.tlsAccessors)
	public static function tlsNames(objs:Array<Obj>):Array<String> {
		var r = [], seen = new Map<String, Bool>();
		for (o in objs)
			for (s in o.symbols)
				if (s.global && s.section != null && (s.section.kind == Tdata || s.section.kind == Tbss) && !seen.exists(s.name)) {
					seen.set(s.name, true);
					r.push(s.name);
				}
		r.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		return r;
	}

	#if hxmc.jit
	// ---- reading (the running compiler)

	static var base:Null<hxmc.unsafe.Ptr> = null;
	static var n = 0;
	static var m = 0;

	static function init() {
		if (base != null) return;
		var t = hxmc.unsafe.Mem.sym(SYM);
		base = t;
		n = hxmc.unsafe.Mem.getI64(t, 0).toInt();
		m = hxmc.unsafe.Mem.getI64(t, 8).toInt();
	}

	// (HXMC_MACRO_STATS=1: the lookups and their time)
	static final timed = Sys.getEnv("HXMC_MACRO_STATS") == "1";
	public static var lookups = 0;
	public static var lookupTime = 0.0;

	// the row of the key of name in a sorted run of count keys at keys, -1 when none
	static function find(keys:hxmc.unsafe.Ptr, count:Int, name:String):Int {
		lookups++;
		if (timed) {
			var t = haxe.Timer.stamp();
			var r = search(keys, count, name);
			lookupTime += haxe.Timer.stamp() - t;
			return r;
		}
		return search(keys, count, name);
	}

	static function search(keys:hxmc.unsafe.Ptr, count:Int, name:String):Int {
		hash(name);
		var a = 0, z = count;
		while (a < z) {
			var mid = (a + z) >> 1;
			var klo = hxmc.unsafe.Mem.getI32(keys, 8 * mid), khi = hxmc.unsafe.Mem.getI32(keys, 8 * mid + 4);
			if (klo == lo && khi == hi) return mid;
			if (before(khi, klo, hi, lo)) a = mid + 1 else z = mid;
		}
		return -1;
	}

	static inline function keys():hxmc.unsafe.Ptr
		return base.add(32);

	static inline function values():hxmc.unsafe.Ptr
		return base.add(32 + 8 * n);

	static inline function kinds():hxmc.unsafe.Ptr
		return base.add(32 + 16 * n);

	static inline function fpKeys():hxmc.unsafe.Ptr
		return base.add(32 + ((17 * n + 7) & ~7));

	// the symbol named name: its kind and value, or -1
	public static function symbol(name:String):Int {
		init();
		return find(keys(), n, name);
	}

	public static inline function kind(row:Int):Int
		return hxmc.unsafe.Mem.getU8(kinds(), row);

	public static function value(row:Int):hxmc.I64 {
		var v = hxmc.unsafe.Mem.getI64(values(), 8 * row);
		// (a thread-pointer offset: 32 bits, signed)
		return kind(row) == "l".code ? (v.toInt() : hxmc.I64) : v;
	}

	// the fingerprint row of a function's symbol, or -1
	public static function fingerprint(name:String):Int {
		init();
		return find(fpKeys(), m, name);
	}

	static inline function fpRows():hxmc.unsafe.Ptr
		return fpKeys().add(8 * m);

	public static function fpKey(row:Int):String
		return StringTools.hex(hxmc.unsafe.Mem.getI32(fpRows(), 12 * row), 8) + StringTools.hex(hxmc.unsafe.Mem.getI32(fpRows(), 12 * row + 4), 8);

	public static function fpFlags(row:Int):Int
		return hxmc.unsafe.Mem.getI32(fpRows(), 12 * row + 8);

	// MacroCuts' lines
	public static function cuts():String {
		init();
		var len = hxmc.unsafe.Mem.getI64(base, 16).toInt();
		var p = fpRows().add(12 * m);
		var bs = haxe.io.Bytes.alloc(len);
		for (i in 0...len)
			bs.set(i, hxmc.unsafe.Mem.getU8(p, i));
		return bs.toString();
	}

	// the table's bytes (HXMC_MACRO_STATS)
	public static function bytes():Int {
		init();
		return 32 + ((17 * n + 7) & ~7) + 8 * m + 12 * m + hxmc.unsafe.Mem.getI64(base, 16).toInt();
	}

	public static function count():Int {
		init();
		return n;
	}
	#end
}

#if hxmc.jit
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
#end

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
		#if hxmc.jit
		var r = HostTable.fingerprint(name);
		return r < 0 ? null : HostTable.fpKey(r);
		#else
		return null;
		#end
	}

	// the flags of the compiler's function of that symbol, -1 when it has none
	public function flags(name:String):Int {
		if (map != null) {
			var x = map.get(name);
			return x == null ? -1 : x.flags;
		}
		#if hxmc.jit
		var r = HostTable.fingerprint(name);
		return r < 0 ? -1 : HostTable.fpFlags(r);
		#else
		return -1;
		#end
	}
}
