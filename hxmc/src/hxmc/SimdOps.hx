package hxmc;

// The vector operations of hxmc.simd (docs/plans/simd.md), by their
// WebAssembly SIMD names and opcodes (the 0xFD prefix's): what the
// intrinsics name (hxmc.simd.Simd's `op` literals), what Mir's VOp carries
// (imm: the opcode), what every back end implements with the same results.
// Loads and stores are Mir's Load and Store of a V128 (16 bytes, or the
// low 8 or 4: SimdOps.memBytes).
class SimdOps {
	// operand shapes (hxmc.simd.OpList's)
	public static inline var UN = hxmc.simd.OpList.UN;
	public static inline var BIN = hxmc.simd.OpList.BIN;
	public static inline var TER = hxmc.simd.OpList.TER;
	public static inline var SHIFT = hxmc.simd.OpList.SHIFT;
	public static inline var SPLAT_I = hxmc.simd.OpList.SPLAT_I;
	public static inline var SPLAT_L = hxmc.simd.OpList.SPLAT_L;
	public static inline var SPLAT_F = hxmc.simd.OpList.SPLAT_F;
	public static inline var EXTRACT_I = hxmc.simd.OpList.EXTRACT_I;
	public static inline var EXTRACT_L = hxmc.simd.OpList.EXTRACT_L;
	public static inline var EXTRACT_F = hxmc.simd.OpList.EXTRACT_F;
	public static inline var REPLACE_I = hxmc.simd.OpList.REPLACE_I;
	public static inline var REPLACE_L = hxmc.simd.OpList.REPLACE_L;
	public static inline var REPLACE_F = hxmc.simd.OpList.REPLACE_F;
	public static inline var TEST = hxmc.simd.OpList.TEST;
	public static inline var SHUFFLE = hxmc.simd.OpList.SHUFFLE;
	public static inline var LOAD = hxmc.simd.OpList.LOAD;
	public static inline var STORE = hxmc.simd.OpList.STORE;

	// (the table, shared with the std's macro: hxmc/std/hxmc/simd/OpList.hx)
	public static final LIST:Array<{name:String, code:Int, kind:Int}> = hxmc.simd.OpList.LIST;

	// (made once, before any thread reads them)
	static final byName:Map<String, Int> = [for (x in LIST) x.name => x.code];
	static final names:haxe.ds.Vector<String> = {
		var n = new haxe.ds.Vector<String>(256);
		for (x in LIST)
			n[x.code] = x.name;
		n;
	};
	static final kinds:haxe.ds.Vector<Int> = {
		var k = new haxe.ds.Vector<Int>(256);
		for (x in LIST)
			k[x.code] = x.kind;
		k;
	};

	// the opcode of an operation, or -1
	public static function code(name:String):Int {
		var c = byName.get(name);
		return c == null ? -1 : c;
	}

	public static function name(code:Int):String {
		var n = names[code];
		return n == null ? "v?" + code : n;
	}

	public static function kind(code:Int):Int {
		return kinds[code];
	}

	public static function hasLane(code:Int):Bool {
		var k = kind(code);
		return k >= EXTRACT_I && k <= REPLACE_F;
	}

	// the lanes of an operation's shape (its name's prefix)
	public static function lanes(code:Int):Int {
		var n = name(code);
		return n.indexOf("x16") > 0 ? 16 : n.indexOf("x8") > 0 ? 8 : n.indexOf("x4") > 0 ? 4 : n.indexOf("x2") > 0 ? 2 : 1;
	}

	// the bytes of a lane of an operation's shape (its name's prefix; 4 for
	// v128's)
	public static function width(code:Int):Int {
		var n = name(code);
		return StringTools.startsWith(n, "i8x16") ? 1 : StringTools.startsWith(n, "i16x8") ? 2 : StringTools.startsWith(n, "i64x2") || StringTools.startsWith(n, "f64x2") ? 8 : 4;
	}

	// the bytes a load or store reads or writes
	public static inline function memBytes(code:Int):Int
		return hxmc.simd.OpList.memBytes(code);
}
