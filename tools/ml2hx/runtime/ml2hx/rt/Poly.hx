package ml2hx.rt;

import haxe.Int64;

// OCaml's polymorphic compare, equality and hash (runtime/compare.c,
// runtime/hash.c) over the converted program's values:
//
//   OCaml                      Haxe at run time          OCaml representation
//   int, char, bool, unit      Int63 (Int64), Int, Bool, Unit   immediate
//   constant constructor       enum value without arguments    immediate (its rank among the constant ones)
//   constructor with args      enum value with arguments       block, tag = rank among the non-constant ones
//   record, tuple, ref         ml2hx.rt.Block                  block (Block.blockTag)
//   array                      Array                           block tag 0 (254 when every element is a float)
//   string, bytes              String (a unit per byte), haxe.io.Bytes   String_tag
//   float                      Float                           Double_tag
//   empty tree of the runtime  null                            immediate 0
//   function                   function                        compare raises Invalid_argument
//
// Int32 values are Haxe Ints at run time, indistinguishable from chars: they
// compare alike but hash as immediates (OCaml hashes an int32 as a custom
// block: Hashtbl.hash on an int32 differs). Int64 and int are both Int64 at
// run time: an int64 hashes as an int (OCaml: as a custom block).
class Poly {
	public static inline var UNORDERED = 0x80000000;

	static inline var K_IMM = 0;
	static inline var K_STRING = 1;
	static inline var K_BYTES = 2;
	static inline var K_DOUBLE = 3;
	static inline var K_ENUM = 4; // an enum value with arguments
	static inline var K_BLOCK = 5;
	static inline var K_ARRAY = 6;
	static inline var K_FUNC = 7;

	static inline var STRING_TAG = 252;
	static inline var DOUBLE_TAG = 253;
	static inline var DOUBLE_ARRAY_TAG = 254;
	static inline var CLOSURE_TAG = 247;

	// ---- enum constructors' ranks: >= 0 a constant constructor's rank among
	// the constant ones, < 0 -(rank + 1) of a constructor with arguments

	static var enumRanks = new haxe.ds.StringMap<Array<Int>>();

	static function ranks(e:Enum<Dynamic>):Array<Int> {
		var name = Type.getEnumName(e);
		var r = enumRanks.get(name);
		if (r != null) return r;
		var names = Type.getEnumConstructs(e);
		var constant = [for (_ in names) false];
		for (v in Type.allEnums(e)) constant[Type.enumIndex(v)] = true;
		r = [];
		var c = 0, b = 0;
		for (i in 0...names.length) r.push(constant[i] ? c++ : -(++b));
		enumRanks.set(name, r);
		return r;
	}

	static inline function enumRank(v:EnumValue):Int
		return ranks(Type.getEnum(v))[Type.enumIndex(v)];

	static function kind(v:Dynamic):Int {
		if (v == null) return K_IMM;
		if (Std.isOfType(v, String)) return K_STRING;
		if (Std.isOfType(v, Int) || Std.isOfType(v, Bool) || Int64.isInt64(v)) return K_IMM;
		if (Std.isOfType(v, Float)) return K_DOUBLE;
		if (Std.isOfType(v, Block)) return K_BLOCK;
		if (Reflect.isEnumValue(v)) return enumRank(v) >= 0 ? K_IMM : K_ENUM;
		if (Std.isOfType(v, Array)) return K_ARRAY;
		if (Std.isOfType(v, haxe.io.Bytes)) return K_BYTES;
		if (Reflect.isFunction(v)) return K_FUNC;
		throw new InvalidArgument("ml2hx: no OCaml representation for " + Std.string(v));
	}

	// the OCaml integer of an immediate value, null for a block
	public static function immediateOf(v:Dynamic):Null<Int64>
		return kind(v) == K_IMM ? immediate(v) : null;

	// the immediate's OCaml integer
	static function immediate(v:Dynamic):Int64 {
		if (v == null) return 0;
		if (Std.isOfType(v, Int)) return Int64.ofInt((v : Int));
		if (Std.isOfType(v, Bool)) return (v : Bool) ? 1 : 0;
		if (Int64.isInt64(v)) return (v : Int64);
		// unit is the Int 0 at run time
		return enumRank(v);
	}

	static function tag(v:Dynamic, k:Int):Int {
		return switch k {
			case K_STRING | K_BYTES: STRING_TAG;
			case K_DOUBLE: DOUBLE_TAG;
			case K_ENUM: -enumRank(v) - 1;
			case K_BLOCK: (v : Block).blockTag();
			case K_ARRAY: floatArray(v) ? DOUBLE_ARRAY_TAG : 0;
			case _: CLOSURE_TAG;
		}
	}

	static function floatArray(a:Array<Dynamic>):Bool {
		if (a.length == 0) return false;
		for (x in a) if (!Std.isOfType(x, Float) || Std.isOfType(x, Int)) return false;
		return true;
	}

	static function size(v:Dynamic, k:Int):Int {
		return switch k {
			case K_ENUM: Type.enumParameters(v).length;
			case K_BLOCK: (v : Block).blockSize();
			case K_ARRAY: (v : Array<Dynamic>).length;
			case _: 0;
		}
	}

	static function fields(v:Dynamic, k:Int):Array<Dynamic> {
		return switch k {
			case K_ENUM: Type.enumParameters(v);
			case K_ARRAY: v;
			case _:
				var b:Block = v;
				[for (i in 0...b.blockSize()) b.blockField(i)];
		}
	}

	public static function compareStrings(a:String, b:String):Int {
		if (a == b) return 0;
		var n = a.length < b.length ? a.length : b.length;
		for (i in 0...n) {
			var x = StringTools.fastCodeAt(a, i), y = StringTools.fastCodeAt(b, i);
			if (x != y) return x < y ? -1 : 1;
		}
		return a.length < b.length ? -1 : (a.length > b.length ? 1 : 0);
	}

	static function compareBytes(a:haxe.io.Bytes, b:haxe.io.Bytes):Int {
		var n = a.length < b.length ? a.length : b.length;
		for (i in 0...n) {
			var x = a.get(i), y = b.get(i);
			if (x != y) return x < y ? -1 : 1;
		}
		return a.length < b.length ? -1 : (a.length > b.length ? 1 : 0);
	}

	static function compareFloats(a:Float, b:Float, total:Bool):Int {
		if (a < b) return -1;
		if (a > b) return 1;
		if (a != b) {
			if (!total) return UNORDERED;
			if (a == a) return 1; // b is nan
			if (b == b) return -1; // a is nan
		}
		return 0;
	}

	// caml_compare's core: -1, 0, 1 or UNORDERED (only when !total)
	public static function compareValues(a:Dynamic, b:Dynamic, total:Bool):Int {
		while (true) {
			var ka = kind(a), kb = kind(b);
			if (ka == K_IMM) {
				if (kb != K_IMM) return -1;
				var c = Int64.compare(immediate(a), immediate(b));
				return c < 0 ? -1 : (c > 0 ? 1 : 0);
			}
			if (kb == K_IMM) return 1;
			var ta = tag(a, ka), tb = tag(b, kb);
			if (ta != tb) return ta < tb ? -1 : 1;
			switch ka {
				case K_STRING:
					return Std.isOfType(b, String) ? compareStrings(a, b) : -compareBytes(b, haxe.io.Bytes.ofString(a));
				case K_BYTES:
					return Std.isOfType(b, String) ? compareBytes(a, haxe.io.Bytes.ofString(b)) : compareBytes(a, b);
				case K_DOUBLE:
					return compareFloats(a, b, total);
				case K_FUNC:
					throw new InvalidArgument("compare: functional value");
				case _:
					var fa = fields(a, ka), fb = fields(b, kb);
					if (fa.length != fb.length) return fa.length < fb.length ? -1 : 1;
					if (fa.length == 0) return 0;
					if (ta == DOUBLE_ARRAY_TAG) {
						for (i in 0...fa.length) {
							var c = compareFloats(fa[i], fb[i], total);
							if (c != 0) return c;
						}
						return 0;
					}
					for (i in 0...fa.length - 1) {
						var c = compareValues(fa[i], fb[i], total);
						if (c != 0) return c;
					}
					// the last field in the loop: lists compare without recursion
					a = fa[fa.length - 1];
					b = fb[fb.length - 1];
			}
		}
	}

	// Stdlib.compare
	public static function compare(a:Dynamic, b:Dynamic):Int {
		if (Std.isOfType(a, String) && Std.isOfType(b, String)) return compareStrings(a, b);
		return compareValues(a, b, true);
	}

	// Stdlib.( = ), ( <> ), ( < ), ( <= ), ( > ), ( >= )
	public static function equal(a:Dynamic, b:Dynamic):Bool {
		if (Std.isOfType(a, String) && Std.isOfType(b, String)) return (a : String) == (b : String);
		return compareValues(a, b, false) == 0;
	}

	public static inline function notEqual(a:Dynamic, b:Dynamic):Bool
		return !equal(a, b);

	public static function lessThan(a:Dynamic, b:Dynamic):Bool {
		var c = compareValues(a, b, false);
		return c < 0 && c != UNORDERED;
	}

	public static function lessEqual(a:Dynamic, b:Dynamic):Bool {
		var c = compareValues(a, b, false);
		return c <= 0 && c != UNORDERED;
	}

	public static function greaterThan(a:Dynamic, b:Dynamic):Bool {
		var c = compareValues(a, b, false);
		return c > 0;
	}

	public static function greaterEqual(a:Dynamic, b:Dynamic):Bool {
		var c = compareValues(a, b, false);
		return c >= 0;
	}

	// ---- hash (runtime/hash.c: MurmurHash3's mixing, breadth first)

	static inline function rotl(x:Int, n:Int):Int
		return (x << n) | (x >>> (32 - n));

	static inline function imul(a:Int, b:Int):Int
		return ((a : haxe.Int32) * (b : haxe.Int32) : Int);

	public static inline function mix(h:Int, d:Int):Int {
		d = imul(d, 0xcc9e2d51);
		d = rotl(d, 15);
		d = imul(d, 0x1b873593);
		h ^= d;
		h = rotl(h, 13);
		return imul(h, 5) + 0xe6546b64;
	}

	public static inline function finalMix(h:Int):Int {
		h ^= h >>> 16;
		h = imul(h, 0x85ebca6b);
		h ^= h >>> 13;
		h = imul(h, 0xc2b2ae35);
		h ^= h >>> 16;
		return h;
	}

	// an OCaml value word d (an immediate n is 2n + 1)
	public static inline function mixIntnat(h:Int, d:Int64):Int
		return mix(h, (d >> 32).low ^ (d >> 63).low ^ d.low);

	public static function mixDouble(hash:Int, d:Float):Int {
		var b = Float64.bits(d);
		var h = b.high, l = b.low;
		if ((h & 0x7FF00000) == 0x7FF00000 && (l | (h & 0xFFFFF)) != 0) {
			h = 0x7FF00000;
			l = 0x00000001;
		} else if (h == 0x80000000 && l == 0) {
			h = 0;
		}
		hash = mix(hash, l);
		return mix(hash, h);
	}

	public static function mixString(h:Int, s:String):Int {
		var len = s.length;
		var i = 0;
		while (i + 4 <= len) {
			var w = StringTools.fastCodeAt(s, i) | (StringTools.fastCodeAt(s, i + 1) << 8) | (StringTools.fastCodeAt(s, i + 2) << 16)
				| (StringTools.fastCodeAt(s, i + 3) << 24);
			h = mix(h, w);
			i += 4;
		}
		var w = 0;
		switch len & 3 {
			case 3:
				w = (StringTools.fastCodeAt(s, i + 2) << 16) | (StringTools.fastCodeAt(s, i + 1) << 8) | StringTools.fastCodeAt(s, i);
				h = mix(h, w);
			case 2:
				w = (StringTools.fastCodeAt(s, i + 1) << 8) | StringTools.fastCodeAt(s, i);
				h = mix(h, w);
			case 1:
				w = StringTools.fastCodeAt(s, i);
				h = mix(h, w);
			case _:
		}
		return h ^ len;
	}

	static function mixBytes(h:Int, s:haxe.io.Bytes):Int {
		var len = s.length;
		var i = 0;
		while (i + 4 <= len) {
			h = mix(h, s.getInt32(i));
			i += 4;
		}
		var w = 0;
		switch len & 3 {
			case 3:
				w = (s.get(i + 2) << 16) | (s.get(i + 1) << 8) | s.get(i);
				h = mix(h, w);
			case 2:
				w = (s.get(i + 1) << 8) | s.get(i);
				h = mix(h, w);
			case 1:
				h = mix(h, s.get(i));
			case _:
		}
		return h ^ len;
	}

	static inline function header(size:Int, tag:Int):Int
		return (size << 10) | tag;

	static var queue = new haxe.ds.Vector<Dynamic>(256);

	// Hashtbl.seeded_hash_param meaningful total seed v
	public static function hashParam(count:Int, limit:Int, seed:Int, v:Dynamic):Int {
		// the most frequent keys first
		if (Std.isOfType(v, String)) return finalMix(mixString(seed, v)) & 0x3FFFFFFF;
		var sz = limit;
		if (sz < 0 || sz > 256) sz = 256;
		var num = count;
		var h = seed;
		var q = queue;
		var reentrant = q[0] != null;
		if (reentrant) q = new haxe.ds.Vector<Dynamic>(256);
		q[0] = v;
		var rd = 0, wr = 1;
		while (rd < wr && num > 0) {
			var v:Dynamic = q[rd++];
			var k = kind(v);
			switch k {
				case K_IMM:
					var n = immediate(v);
					h = mixIntnat(h, n + n + 1);
					num--;
				case K_STRING:
					h = mixString(h, v);
					num--;
				case K_BYTES:
					h = mixBytes(h, v);
					num--;
				case K_DOUBLE:
					h = mixDouble(h, v);
					num--;
				case K_FUNC:
					throw new InvalidArgument("hash: functional value");
				case _:
					var t = tag(v, k);
					var f = fields(v, k);
					if (t == DOUBLE_ARRAY_TAG) {
						for (x in f) {
							h = mixDouble(h, x);
							num--;
							if (num <= 0) break;
						}
					} else {
						h = mix(h, header(f.length, t));
						for (x in f) {
							if (wr >= sz) break;
							q[wr++] = x;
						}
					}
			}
		}
		for (i in 0...wr) q[i] = null;
		return finalMix(h) & 0x3FFFFFFF;
	}

	// Hashtbl.hash
	public static inline function hash(v:Dynamic):Int
		return hashParam(10, 100, 0, v);
}
