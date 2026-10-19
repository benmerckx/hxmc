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
@:allow(ml2hx.prim.Obj) @:allow(ml2hx.prim.Runtime)
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
	static inline var K_ABSTRACT = 8;
	static inline var ABSTRACT_TAG = 251;

	static inline var STRING_TAG = 252;
	static inline var DOUBLE_TAG = 253;
	static inline var DOUBLE_ARRAY_TAG = 254;
	static inline var CLOSURE_TAG = 247;

	// ---- enum constructors' ranks: >= 0 a constant constructor's rank among
	// the constant ones, < 0 -(rank + 1) of a constructor with arguments

	// (by the enum itself: its name would be made and hashed at each lookup)
	static var enumRanks = new haxe.ds.ObjectMap<Dynamic, Array<Int>>();

	static function ranks(e:Enum<Dynamic>):Array<Int> {
		var r = enumRanks.get(e);
		if (r != null) return r;
		var names = Type.getEnumConstructs(e);
		var constant = [for (_ in names) false];
		for (v in Type.allEnums(e)) constant[Type.enumIndex(v)] = true;
		r = [];
		var c = 0, b = 0;
		for (i in 0...names.length) r.push(constant[i] ? c++ : -(++b));
		enumRanks.set(e, r);
		return r;
	}

	#if (target.name == "hxmc" && !hxmc.wasm_gc)
	// by the constructor's type index (each constructor has its own): the
	// rank + 1 of a constant one, the (negative) rank of another, 0 unknown
	static var rankByType = new Array<Int>();
	#end

	static function enumRank(v:Dynamic):Int {
		#if (target.name == "hxmc" && !hxmc.wasm_gc)
		var t = hxmc.rt.Types.tindex(v);
		if (t < rankByType.length) {
			var x = rankByType[t];
			if (x != 0) return x > 0 ? x - 1 : x;
		}
		var r = ranks(Type.getEnum(v))[Type.enumIndex(v)];
		while (rankByType.length <= t) rankByType.push(0);
		rankByType[t] = r >= 0 ? r + 1 : r;
		return r;
		#else
		return ranks(Type.getEnum(v))[Type.enumIndex(v)];
		#end
	}

	// Type.typeof as a number (0 null, 1 Int, 2 Float, 3 Bool, 4 object,
	// 5 function, 6 class instance, 7 enum value, 8 String, 9 Array, 11
	// other): hxmc's without the ValueType Type.typeof allocates
	static inline function typeKind(v:Dynamic):Int {
		#if (target.name == "hxmc" && !hxmc.wasm_gc)
		return hxmc.Native.typeKind(v);
		#else
		return switch Type.typeof(v) {
			case TNull: 0;
			case TInt: 1;
			case TFloat: 2;
			case TBool: 3;
			case TObject: 4;
			case TFunction: 5;
			case TClass(c): c == String ? 8 : c == Array ? 9 : 6;
			case TEnum(_): 7;
			case _: 11;
		}
		#end
	}

	// an enum value's arguments, read in place (no array per value on hxmc)
	static inline function paramCount(v:Dynamic):Int {
		#if (target.name == "hxmc" && !hxmc.wasm_gc)
		return hxmc.rt.Dyn.enumParamCount(v);
		#else
		return Type.enumParameters(v).length;
		#end
	}

	static inline function param(v:Dynamic, i:Int):Dynamic {
		#if (target.name == "hxmc" && !hxmc.wasm_gc)
		return hxmc.rt.Dyn.enumParam(v, i);
		#else
		return Type.enumParameters(v)[i];
		#end
	}

	#if (target.name == "hxmc" && !hxmc.wasm_gc)
	// per type index (each class and constructor has its own): a class's
	// kind + 1; for a constructor, 2 when its argument is an inline record, 1 not
	static var kindByType = new Array<Int>();

	static inline function typeCache(t:Int):Int
		return t < kindByType.length ? kindByType[t] : 0;

	static function setTypeCache(t:Int, x:Int) {
		while (kindByType.length <= t) kindByType.push(0);
		kindByType[t] = x;
	}
	#end

	// C of {...}: the record (its fields are the block's), else null
	static function inlineRecord(v:Dynamic):Dynamic {
		#if (target.name == "hxmc" && !hxmc.wasm_gc)
		var t = hxmc.rt.Types.tindex(v);
		var x = typeCache(t);
		if (x == 1) return null;
		if (x == 2) return param(v, 0);
		var r = paramCount(v) == 1 && Std.isOfType(param(v, 0), InlineRecord);
		setTypeCache(t, r ? 2 : 1);
		return r ? param(v, 0) : null;
		#else
		if (paramCount(v) != 1) return null;
		var p = param(v, 0);
		return Std.isOfType(p, InlineRecord) ? p : null;
		#end
	}

	// a class instance's kind
	static function classKind(v:Dynamic):Int {
		#if (target.name == "hxmc" && !hxmc.wasm_gc)
		var t = hxmc.rt.Types.tindex(v);
		var x = typeCache(t);
		if (x != 0) return x - 1;
		var k = Std.isOfType(v, Block) ? (Std.isOfType(v, Abstract) ? K_ABSTRACT : K_BLOCK) : instanceKind(v);
		setTypeCache(t, k + 1);
		return k;
		#else
		return Std.isOfType(v, Block) ? (Std.isOfType(v, Abstract) ? K_ABSTRACT : K_BLOCK) : instanceKind(v);
		#end
	}

	static function kind(v:Dynamic):Int {
		return switch typeKind(v) {
			case 0 | 1 | 3: K_IMM;
			case 2: K_DOUBLE;
			// (a constant constructor: one without arguments)
			case 7: paramCount(v) == 0 ? K_IMM : K_ENUM;
			case 5: K_FUNC;
			case 8: K_STRING;
			case 9: K_ARRAY;
			case 6: classKind(v);
			// (some hosts type Int64 or Bytes values otherwise)
			case _: instanceKind(v);
		}
	}

	static function instanceKind(v:Dynamic):Int {
		return if (Int64.isInt64(v)) K_IMM;
			else if (Std.isOfType(v, Abstract)) K_ABSTRACT;
			else if (Std.isOfType(v, PolyVariant)) K_IMM; // a constant polymorphic variant: its hash
			else if (Std.isOfType(v, haxe.io.Bytes)) K_BYTES;
			else if (Std.isOfType(v, Array)) K_ARRAY;
			else throw new InvalidArgument("ml2hx: no OCaml representation for " + Std.string(v));
	}

	// the OCaml integer of an immediate value, null for a block
	public static function immediateOf(v:Dynamic):Null<Int64>
		return kind(v) == K_IMM ? immediate(v) : null;

	// the immediate's OCaml integer
	static function immediate(v:Dynamic):Int64 {
		if (v == null) return 0;
		// (ints first: the most frequent)
		if (Int64.isInt64(v)) return (v : Int64);
		switch typeKind(v) {
			case 1: return Int64.ofInt((v : Int));
			case 3: return (v : Bool) ? 1 : 0;
			case 7: return enumRank(v);
			case _:
		}
		// unit is the Int 0 at run time
		if (Std.isOfType(v, PolyVariant)) return (v : PolyVariant).tag;
		return enumRank(v);
	}

	static function tag(v:Dynamic, k:Int):Int {
		return switch k {
			case K_STRING | K_BYTES: STRING_TAG;
			case K_DOUBLE: DOUBLE_TAG;
			case K_ENUM: -enumRank(v) - 1;
			case K_BLOCK: (v : Block).blockTag();
			case K_ARRAY: floatArray(v) ? DOUBLE_ARRAY_TAG : 0;
			case K_ABSTRACT: ABSTRACT_TAG;
			case _: CLOSURE_TAG;
		}
	}

	static function floatArray(a:Array<Dynamic>):Bool {
		if (a.length == 0) return false;
		for (x in a) if (typeKind(x) != 2) return false;
		return true;
	}

	static function size(v:Dynamic, k:Int):Int {
		return switch k {
			case K_ENUM:
				var r = inlineRecord(v);
				r != null ? (r : Block).blockSize() : paramCount(v);
			case K_BLOCK: (v : Block).blockSize();
			case K_ARRAY: (v : Array<Dynamic>).length;
			case K_ABSTRACT: (v : Abstract).abstractSize();
			case _: 0;
		}
	}

	// field i of a block of kind k, read in place (K_ENUM: of a constructor
	// without an inline record)
	static inline function field(v:Dynamic, k:Int, i:Int):Dynamic {
		return switch k {
			case K_ENUM: param(v, i);
			case K_ARRAY: (v : Array<Dynamic>)[i];
			case _: (v : Block).blockField(i);
		}
	}

	static function fields(v:Dynamic, k:Int):Array<Dynamic> {
		return switch k {
			case K_ENUM:
				var ps = Type.enumParameters(v);
				// (C of {...}: the record's fields are the block's)
				if (ps.length == 1 && Std.isOfType(ps[0], InlineRecord)) {
					var r:Block = ps[0];
					[for (i in 0...r.blockSize()) r.blockField(i)];
				} else ps;
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

	public static function compareFloats(a:Float, b:Float, total:Bool):Int {
		if (a < b) return -1;
		if (a > b) return 1;
		if (a != b) {
			if (!total) return UNORDERED;
			if (a == a) return 1; // b is nan
			if (b == b) return -1; // a is nan
		}
		return 0;
	}

	// (the typed compare functions the converter makes: emit.mjs cmpDecl)
	public static inline function compareInt63(a:Int63, b:Int63):Int
		return Int63.lt(a, b) ? -1 : Int63.eq(a, b) ? 0 : 1;

	// Stdlib.min and max (if x <= y then x else y; if x >= y then x else y)
	// and Hashtbl.hash at known types (emit.mjs typedPolyCall)
	public static inline function minInt63(a:Int63, b:Int63):Int63
		return Int63.le(a, b) ? a : b;

	public static inline function maxInt63(a:Int63, b:Int63):Int63
		return Int63.ge(a, b) ? a : b;

	public static inline function minInt(a:Int, b:Int):Int
		return a <= b ? a : b;

	public static inline function maxInt(a:Int, b:Int):Int
		return a >= b ? a : b;

	public static inline function minFloat(a:Float, b:Float):Float
		return a <= b ? a : b;

	public static inline function maxFloat(a:Float, b:Float):Float
		return a >= b ? a : b;

	public static inline function minString(a:String, b:String):String
		return compareStrings(a, b) <= 0 ? a : b;

	public static inline function maxString(a:String, b:String):String
		return compareStrings(a, b) >= 0 ? a : b;

	public static inline function hashString(s:String):Int
		return finalMix(mixString(0, s)) & 0x3FFFFFFF;

	public static inline function hashInt63(n:Int63):Int {
		var l = n.toInt64();
		return finalMix(mixIntnat(0, l + l + 1)) & 0x3FFFFFFF;
	}

	public static inline function hashInt(n:Int):Int
		return hashInt63(Int63.ofInt(n));

	// (a, b, total) forms of the simple types' orders, and List's walks by a
	// compare function (emit.mjs typedPolyCall)
	public static function compareInt63T(a:Int63, b:Int63, total:Bool):Int
		return compareInt63(a, b);

	public static function compareIntT(a:Int, b:Int, total:Bool):Int
		return a < b ? -1 : a > b ? 1 : 0;

	public static function compareBoolT(a:Bool, b:Bool, total:Bool):Int
		return (a ? 1 : 0) - (b ? 1 : 0);

	public static function compareStringsT(a:String, b:String, total:Bool):Int
		return compareStrings(a, b);

	public static function listMem<T>(x:T, l:MlList<T>, cmp:(T, T, Bool) -> Int):Bool {
		while (true) switch l {
			case Nil: return false;
			case Cons(a, r):
				if (cmp(a, x, true) == 0) return true;
				l = r;
		}
	}

	public static function listMemAssoc<K, V>(x:K, l:MlList<Tuple2<K, V>>, cmp:(K, K, Bool) -> Int):Bool {
		while (true) switch l {
			case Nil: return false;
			case Cons(p, r):
				if (cmp(p.v0, x, true) == 0) return true;
				l = r;
		}
	}

	public static function listAssoc<K, V>(x:K, l:MlList<Tuple2<K, V>>, cmp:(K, K, Bool) -> Int):V {
		while (true) switch l {
			case Nil: throw NotFound.instance;
			case Cons(p, r):
				if (cmp(p.v0, x, true) == 0) return p.v1;
				l = r;
		}
	}

	public static function listAssocOpt<K, V>(x:K, l:MlList<Tuple2<K, V>>, cmp:(K, K, Bool) -> Int):MlOption<V> {
		while (true) switch l {
			case Nil: return None;
			case Cons(p, r):
				if (cmp(p.v0, x, true) == 0) return Some(p.v1);
				l = r;
		}
	}

	public static inline function isLess(c:Int):Bool
		return c < 0 && c != UNORDERED;

	public static inline function isLessEqual(c:Int):Bool
		return c <= 0 && c != UNORDERED;

	// caml_compare's core: -1, 0, 1 or UNORDERED (only when !total)
	public static function compareValues(a:Dynamic, b:Dynamic, total:Bool):Int {
		while (true) {
			// (compare, not =, takes a value physically equal to itself as equal
			// without looking inside: closures included)
			if (total && a == b) return 0;
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
				case K_ABSTRACT:
					throw new InvalidArgument("compare: abstract value");
				case _:
					// (fields read in place: no array per block)
					if (ka == K_ENUM) {
						var r = inlineRecord(a);
						if (r != null) {
							a = r;
							ka = K_BLOCK;
						}
					}
					if (kb == K_ENUM) {
						var r = inlineRecord(b);
						if (r != null) {
							b = r;
							kb = K_BLOCK;
						}
					}
					var na = size(a, ka), nb = size(b, kb);
					if (na != nb) return na < nb ? -1 : 1;
					if (na == 0) return 0;
					if (ta == DOUBLE_ARRAY_TAG) {
						for (i in 0...na) {
							var c = compareFloats(field(a, ka, i), field(b, kb, i), total);
							if (c != 0) return c;
						}
						return 0;
					}
					for (i in 0...na - 1) {
						var c = compareValues(field(a, ka, i), field(b, kb, i), total);
						if (c != 0) return c;
					}
					// the last field in the loop: lists compare without recursion
					var last:Dynamic = field(a, ka, na - 1);
					b = field(b, kb, na - 1);
					a = last;
			}
		}
	}

	// Stdlib.compare
	public static function compare(a:Dynamic, b:Dynamic):Int {
		if (typeKind(a) == 8 && typeKind(b) == 8) return compareStrings(a, b);
		if (Int64.isInt64(a) && Int64.isInt64(b)) {
			var c = Int64.compare(a, b);
			return c < 0 ? -1 : c > 0 ? 1 : 0;
		}
		return compareValues(a, b, true);
	}

	// Stdlib.( = ), ( <> ), ( < ), ( <= ), ( > ), ( >= )
	public static function equal(a:Dynamic, b:Dynamic):Bool {
		if (Int64.isInt64(a) && Int64.isInt64(b)) return (a : Int64) == (b : Int64);
		if (typeKind(a) == 8 && typeKind(b) == 8) return (a : String) == (b : String);
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
		if (count > 0) {
			if (typeKind(v) == 8) return finalMix(mixString(seed, v)) & 0x3FFFFFFF;
			if (Int64.isInt64(v)) {
				var n:Int64 = v;
				return finalMix(mixIntnat(seed, n + n + 1)) & 0x3FFFFFFF;
			}
		}
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
				case K_ABSTRACT:
					// (skipped, as OCaml skips Abstract_tag)
				case K_FUNC:
					// OCaml mixes a closure's header and code pointers, which have no
					// counterpart here: the header of a closure alone (not counted)
					h = mix(h, header(0, 247));
				case _:
					var t = tag(v, k);
					var x:Dynamic = v, kx = k;
					if (k == K_ENUM) {
						var r = inlineRecord(v);
						if (r != null) {
							x = r;
							kx = K_BLOCK;
						}
					}
					var n = size(x, kx);
					if (t == DOUBLE_ARRAY_TAG) {
						for (i in 0...n) {
							h = mixDouble(h, field(x, kx, i));
							num--;
							if (num <= 0) break;
						}
					} else {
						h = mix(h, header(n, t));
						for (i in 0...n) {
							if (wr >= sz) break;
							q[wr++] = field(x, kx, i);
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
