package hxmc;

// The vector operations of hxmc.simd (docs/plans/simd.md), by their
// WebAssembly SIMD names and opcodes (the 0xFD prefix's): what the
// intrinsics name (hxmc.simd.Simd's `op` literals), what Mir's VOp carries
// (imm: the opcode), what every back end implements with the same results.
// Loads and stores are Mir's Load and Store of a V128 (16 bytes, or the
// low 8 or 4: SimdOps.memBytes).
class SimdOps {
	// operand shapes
	public static inline var UN = 0; // v -> v
	public static inline var BIN = 1; // v, v -> v
	public static inline var TER = 2; // v, v, v -> v (bitselect: a where c's bits are set, else b)
	public static inline var SHIFT = 3; // v, i32 -> v (the count modulo the lane's width)
	public static inline var SPLAT_I = 4; // i32 -> v
	public static inline var SPLAT_L = 5; // i64 -> v
	public static inline var SPLAT_F = 6; // f64 -> v (a float32 lane: rounded to nearest even)
	public static inline var EXTRACT_I = 7; // v -> i32 (imm2: the lane)
	public static inline var EXTRACT_L = 8; // v -> i64
	public static inline var EXTRACT_F = 9; // v -> f64 (a float32 lane: exactly)
	public static inline var REPLACE_I = 10; // v, i32 -> v (imm2: the lane)
	public static inline var REPLACE_L = 11; // v, i64 -> v
	public static inline var REPLACE_F = 12; // v, f64 -> v
	public static inline var TEST = 13; // v -> i32 (any_true, all_true: 0 or 1; bitmask)
	public static inline var SHUFFLE = 14; // v, v -> v (cases: 16 lane indices below 32)
	public static inline var LOAD = 15; // a load (Mir's Load)
	public static inline var STORE = 16; // a store (Mir's Store)

	public static final LIST:Array<{name:String, code:Int, kind:Int}> = [
		{name: "v128.load", code: 0x00, kind: LOAD},
		{name: "v128.store", code: 0x0b, kind: STORE},
		{name: "i8x16.shuffle", code: 0x0d, kind: SHUFFLE},
		{name: "i8x16.swizzle", code: 0x0e, kind: BIN},
		{name: "i8x16.splat", code: 0x0f, kind: SPLAT_I},
		{name: "i16x8.splat", code: 0x10, kind: SPLAT_I},
		{name: "i32x4.splat", code: 0x11, kind: SPLAT_I},
		{name: "i64x2.splat", code: 0x12, kind: SPLAT_L},
		{name: "f32x4.splat", code: 0x13, kind: SPLAT_F},
		{name: "f64x2.splat", code: 0x14, kind: SPLAT_F},
		{name: "i8x16.extract_lane_s", code: 0x15, kind: EXTRACT_I},
		{name: "i8x16.extract_lane_u", code: 0x16, kind: EXTRACT_I},
		{name: "i8x16.replace_lane", code: 0x17, kind: REPLACE_I},
		{name: "i16x8.extract_lane_s", code: 0x18, kind: EXTRACT_I},
		{name: "i16x8.extract_lane_u", code: 0x19, kind: EXTRACT_I},
		{name: "i16x8.replace_lane", code: 0x1a, kind: REPLACE_I},
		{name: "i32x4.extract_lane", code: 0x1b, kind: EXTRACT_I},
		{name: "i32x4.replace_lane", code: 0x1c, kind: REPLACE_I},
		{name: "i64x2.extract_lane", code: 0x1d, kind: EXTRACT_L},
		{name: "i64x2.replace_lane", code: 0x1e, kind: REPLACE_L},
		{name: "f32x4.extract_lane", code: 0x1f, kind: EXTRACT_F},
		{name: "f32x4.replace_lane", code: 0x20, kind: REPLACE_F},
		{name: "f64x2.extract_lane", code: 0x21, kind: EXTRACT_F},
		{name: "f64x2.replace_lane", code: 0x22, kind: REPLACE_F},
		{name: "i8x16.eq", code: 0x23, kind: BIN},
		{name: "i8x16.ne", code: 0x24, kind: BIN},
		{name: "i8x16.lt_s", code: 0x25, kind: BIN},
		{name: "i8x16.lt_u", code: 0x26, kind: BIN},
		{name: "i8x16.gt_s", code: 0x27, kind: BIN},
		{name: "i8x16.gt_u", code: 0x28, kind: BIN},
		{name: "i8x16.le_s", code: 0x29, kind: BIN},
		{name: "i8x16.le_u", code: 0x2a, kind: BIN},
		{name: "i8x16.ge_s", code: 0x2b, kind: BIN},
		{name: "i8x16.ge_u", code: 0x2c, kind: BIN},
		{name: "i16x8.eq", code: 0x2d, kind: BIN},
		{name: "i16x8.ne", code: 0x2e, kind: BIN},
		{name: "i16x8.lt_s", code: 0x2f, kind: BIN},
		{name: "i16x8.lt_u", code: 0x30, kind: BIN},
		{name: "i16x8.gt_s", code: 0x31, kind: BIN},
		{name: "i16x8.gt_u", code: 0x32, kind: BIN},
		{name: "i16x8.le_s", code: 0x33, kind: BIN},
		{name: "i16x8.le_u", code: 0x34, kind: BIN},
		{name: "i16x8.ge_s", code: 0x35, kind: BIN},
		{name: "i16x8.ge_u", code: 0x36, kind: BIN},
		{name: "i32x4.eq", code: 0x37, kind: BIN},
		{name: "i32x4.ne", code: 0x38, kind: BIN},
		{name: "i32x4.lt_s", code: 0x39, kind: BIN},
		{name: "i32x4.lt_u", code: 0x3a, kind: BIN},
		{name: "i32x4.gt_s", code: 0x3b, kind: BIN},
		{name: "i32x4.gt_u", code: 0x3c, kind: BIN},
		{name: "i32x4.le_s", code: 0x3d, kind: BIN},
		{name: "i32x4.le_u", code: 0x3e, kind: BIN},
		{name: "i32x4.ge_s", code: 0x3f, kind: BIN},
		{name: "i32x4.ge_u", code: 0x40, kind: BIN},
		{name: "f32x4.eq", code: 0x41, kind: BIN},
		{name: "f32x4.ne", code: 0x42, kind: BIN},
		{name: "f32x4.lt", code: 0x43, kind: BIN},
		{name: "f32x4.gt", code: 0x44, kind: BIN},
		{name: "f32x4.le", code: 0x45, kind: BIN},
		{name: "f32x4.ge", code: 0x46, kind: BIN},
		{name: "f64x2.eq", code: 0x47, kind: BIN},
		{name: "f64x2.ne", code: 0x48, kind: BIN},
		{name: "f64x2.lt", code: 0x49, kind: BIN},
		{name: "f64x2.gt", code: 0x4a, kind: BIN},
		{name: "f64x2.le", code: 0x4b, kind: BIN},
		{name: "f64x2.ge", code: 0x4c, kind: BIN},
		{name: "v128.not", code: 0x4d, kind: UN},
		{name: "v128.and", code: 0x4e, kind: BIN},
		{name: "v128.andnot", code: 0x4f, kind: BIN},
		{name: "v128.or", code: 0x50, kind: BIN},
		{name: "v128.xor", code: 0x51, kind: BIN},
		{name: "v128.bitselect", code: 0x52, kind: TER},
		{name: "v128.any_true", code: 0x53, kind: TEST},
		{name: "v128.store32_lane", code: 0x5a, kind: STORE},
		{name: "v128.store64_lane", code: 0x5b, kind: STORE},
		{name: "v128.load32_zero", code: 0x5c, kind: LOAD},
		{name: "v128.load64_zero", code: 0x5d, kind: LOAD},
		{name: "f32x4.demote_f64x2_zero", code: 0x5e, kind: UN},
		{name: "f64x2.promote_low_f32x4", code: 0x5f, kind: UN},
		{name: "i8x16.abs", code: 0x60, kind: UN},
		{name: "i8x16.neg", code: 0x61, kind: UN},
		{name: "i8x16.all_true", code: 0x63, kind: TEST},
		{name: "i8x16.bitmask", code: 0x64, kind: TEST},
		{name: "i8x16.narrow_i16x8_s", code: 0x65, kind: BIN},
		{name: "i8x16.narrow_i16x8_u", code: 0x66, kind: BIN},
		{name: "f32x4.ceil", code: 0x67, kind: UN},
		{name: "f32x4.floor", code: 0x68, kind: UN},
		{name: "f32x4.trunc", code: 0x69, kind: UN},
		{name: "f32x4.nearest", code: 0x6a, kind: UN},
		{name: "i8x16.shl", code: 0x6b, kind: SHIFT},
		{name: "i8x16.shr_s", code: 0x6c, kind: SHIFT},
		{name: "i8x16.shr_u", code: 0x6d, kind: SHIFT},
		{name: "i8x16.add", code: 0x6e, kind: BIN},
		{name: "i8x16.add_sat_s", code: 0x6f, kind: BIN},
		{name: "i8x16.add_sat_u", code: 0x70, kind: BIN},
		{name: "i8x16.sub", code: 0x71, kind: BIN},
		{name: "i8x16.sub_sat_s", code: 0x72, kind: BIN},
		{name: "i8x16.sub_sat_u", code: 0x73, kind: BIN},
		{name: "f64x2.ceil", code: 0x74, kind: UN},
		{name: "f64x2.floor", code: 0x75, kind: UN},
		{name: "i8x16.min_s", code: 0x76, kind: BIN},
		{name: "i8x16.min_u", code: 0x77, kind: BIN},
		{name: "i8x16.max_s", code: 0x78, kind: BIN},
		{name: "i8x16.max_u", code: 0x79, kind: BIN},
		{name: "f64x2.trunc", code: 0x7a, kind: UN},
		{name: "i8x16.avgr_u", code: 0x7b, kind: BIN},
		{name: "i16x8.abs", code: 0x80, kind: UN},
		{name: "i16x8.neg", code: 0x81, kind: UN},
		{name: "i16x8.q15mulr_sat_s", code: 0x82, kind: BIN},
		{name: "i16x8.all_true", code: 0x83, kind: TEST},
		{name: "i16x8.bitmask", code: 0x84, kind: TEST},
		{name: "i16x8.narrow_i32x4_s", code: 0x85, kind: BIN},
		{name: "i16x8.narrow_i32x4_u", code: 0x86, kind: BIN},
		{name: "i16x8.extend_low_i8x16_s", code: 0x87, kind: UN},
		{name: "i16x8.extend_high_i8x16_s", code: 0x88, kind: UN},
		{name: "i16x8.extend_low_i8x16_u", code: 0x89, kind: UN},
		{name: "i16x8.extend_high_i8x16_u", code: 0x8a, kind: UN},
		{name: "i16x8.shl", code: 0x8b, kind: SHIFT},
		{name: "i16x8.shr_s", code: 0x8c, kind: SHIFT},
		{name: "i16x8.shr_u", code: 0x8d, kind: SHIFT},
		{name: "i16x8.add", code: 0x8e, kind: BIN},
		{name: "i16x8.add_sat_s", code: 0x8f, kind: BIN},
		{name: "i16x8.add_sat_u", code: 0x90, kind: BIN},
		{name: "i16x8.sub", code: 0x91, kind: BIN},
		{name: "i16x8.sub_sat_s", code: 0x92, kind: BIN},
		{name: "i16x8.sub_sat_u", code: 0x93, kind: BIN},
		{name: "f64x2.nearest", code: 0x94, kind: UN},
		{name: "i16x8.mul", code: 0x95, kind: BIN},
		{name: "i16x8.min_s", code: 0x96, kind: BIN},
		{name: "i16x8.min_u", code: 0x97, kind: BIN},
		{name: "i16x8.max_s", code: 0x98, kind: BIN},
		{name: "i16x8.max_u", code: 0x99, kind: BIN},
		{name: "i16x8.avgr_u", code: 0x9b, kind: BIN},
		{name: "i32x4.abs", code: 0xa0, kind: UN},
		{name: "i32x4.neg", code: 0xa1, kind: UN},
		{name: "i32x4.all_true", code: 0xa3, kind: TEST},
		{name: "i32x4.bitmask", code: 0xa4, kind: TEST},
		{name: "i32x4.extend_low_i16x8_s", code: 0xa7, kind: UN},
		{name: "i32x4.extend_high_i16x8_s", code: 0xa8, kind: UN},
		{name: "i32x4.extend_low_i16x8_u", code: 0xa9, kind: UN},
		{name: "i32x4.extend_high_i16x8_u", code: 0xaa, kind: UN},
		{name: "i32x4.shl", code: 0xab, kind: SHIFT},
		{name: "i32x4.shr_s", code: 0xac, kind: SHIFT},
		{name: "i32x4.shr_u", code: 0xad, kind: SHIFT},
		{name: "i32x4.add", code: 0xae, kind: BIN},
		{name: "i32x4.sub", code: 0xb1, kind: BIN},
		{name: "i32x4.mul", code: 0xb5, kind: BIN},
		{name: "i32x4.min_s", code: 0xb6, kind: BIN},
		{name: "i32x4.min_u", code: 0xb7, kind: BIN},
		{name: "i32x4.max_s", code: 0xb8, kind: BIN},
		{name: "i32x4.max_u", code: 0xb9, kind: BIN},
		{name: "i32x4.dot_i16x8_s", code: 0xba, kind: BIN},
		{name: "i64x2.neg", code: 0xc1, kind: UN},
		{name: "i64x2.all_true", code: 0xc3, kind: TEST},
		{name: "i64x2.bitmask", code: 0xc4, kind: TEST},
		{name: "i64x2.extend_low_i32x4_s", code: 0xc7, kind: UN},
		{name: "i64x2.extend_high_i32x4_s", code: 0xc8, kind: UN},
		{name: "i64x2.extend_low_i32x4_u", code: 0xc9, kind: UN},
		{name: "i64x2.extend_high_i32x4_u", code: 0xca, kind: UN},
		{name: "i64x2.shl", code: 0xcb, kind: SHIFT},
		{name: "i64x2.shr_s", code: 0xcc, kind: SHIFT},
		{name: "i64x2.shr_u", code: 0xcd, kind: SHIFT},
		{name: "i64x2.add", code: 0xce, kind: BIN},
		{name: "i64x2.sub", code: 0xd1, kind: BIN},
		{name: "i64x2.eq", code: 0xd6, kind: BIN},
		{name: "i64x2.ne", code: 0xd7, kind: BIN},
		{name: "f32x4.abs", code: 0xe0, kind: UN},
		{name: "f32x4.neg", code: 0xe1, kind: UN},
		{name: "f32x4.sqrt", code: 0xe3, kind: UN},
		{name: "f32x4.add", code: 0xe4, kind: BIN},
		{name: "f32x4.sub", code: 0xe5, kind: BIN},
		{name: "f32x4.mul", code: 0xe6, kind: BIN},
		{name: "f32x4.div", code: 0xe7, kind: BIN},
		{name: "f32x4.min", code: 0xe8, kind: BIN},
		{name: "f32x4.max", code: 0xe9, kind: BIN},
		{name: "f32x4.pmin", code: 0xea, kind: BIN},
		{name: "f32x4.pmax", code: 0xeb, kind: BIN},
		{name: "f64x2.abs", code: 0xec, kind: UN},
		{name: "f64x2.neg", code: 0xed, kind: UN},
		{name: "f64x2.sqrt", code: 0xef, kind: UN},
		{name: "f64x2.add", code: 0xf0, kind: BIN},
		{name: "f64x2.sub", code: 0xf1, kind: BIN},
		{name: "f64x2.mul", code: 0xf2, kind: BIN},
		{name: "f64x2.div", code: 0xf3, kind: BIN},
		{name: "f64x2.min", code: 0xf4, kind: BIN},
		{name: "f64x2.max", code: 0xf5, kind: BIN},
		{name: "f64x2.pmin", code: 0xf6, kind: BIN},
		{name: "f64x2.pmax", code: 0xf7, kind: BIN},
		{name: "i32x4.trunc_sat_f32x4_s", code: 0xf8, kind: UN},
		{name: "f32x4.convert_i32x4_s", code: 0xfa, kind: UN},
		{name: "f32x4.convert_i32x4_u", code: 0xfb, kind: UN},
		{name: "i32x4.trunc_sat_f64x2_s_zero", code: 0xfc, kind: UN},
		{name: "f64x2.convert_low_i32x4_s", code: 0xfe, kind: UN},
	];

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

	// the bytes a load or store reads or writes
	public static function memBytes(code:Int):Int
		return switch code {
			case 0x5a | 0x5c: 4;
			case 0x5b | 0x5d: 8;
			case _: 16;
		}
}
