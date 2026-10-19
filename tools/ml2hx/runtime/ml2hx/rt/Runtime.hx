package ml2hx.rt;

import haxe.ds.Map;

// Primitives the emitter calls: OCaml's structural equality, comparison and
// hashing over the representations of the README, checked accesses, and the
// matching helpers for extensible types.
class Runtime {
	// ---------------------------------------------------------------- ints
	public static function div(a:Int, b:Int):Int {
		if (b == 0) throw new DivisionByZeroExn();
		var q = a / b;
		return Std.int(q);
	}
	public static function mod(a:Int, b:Int):Int {
		if (b == 0) throw new DivisionByZeroExn();
		return a % b;
	}
	public static inline function compareInt(a:Int, b:Int):Int return a < b ? -1 : a > b ? 1 : 0;
	public static inline function compareBool(a:Bool, b:Bool):Int return (a ? 1 : 0) - (b ? 1 : 0);
	public static function compareString(a:String, b:String):Int return a < b ? -1 : a > b ? 1 : 0;

	// ---------------------------------------------------------------- checked accesses
	public static function stringGet(s:String, i:Int):Int {
		if (i < 0 || i >= s.length) throw new InvalidArgumentExn("index out of bounds");
		return StringTools.fastCodeAt(s, i);
	}
	public static function bytesGet(b:haxe.io.Bytes, i:Int):Int {
		if (i < 0 || i >= b.length) throw new InvalidArgumentExn("index out of bounds");
		return b.get(i);
	}
	public static function bytesSet(b:haxe.io.Bytes, i:Int, c:Int):Unit {
		if (i < 0 || i >= b.length) throw new InvalidArgumentExn("index out of bounds");
		b.set(i, c);
		return Unit.value;
	}
	public static function arrayGet<T>(a:Array<T>, i:Int):T {
		if (i < 0 || i >= a.length) throw new InvalidArgumentExn("index out of bounds");
		return a[i];
	}
	public static function arraySet<T>(a:Array<T>, i:Int, v:T):Unit {
		if (i < 0 || i >= a.length) throw new InvalidArgumentExn("index out of bounds");
		a[i] = v;
		return Unit.value;
	}

	// ---------------------------------------------------------------- extensible types
	public static inline function isInstance<T>(v:Any, c:Class<T>):Bool return Std.isOfType(v, c);
	public static function downcast<T>(v:Any, c:Class<T>):MlOption<T> return Std.isOfType(v, c) ? Some(cast v) : None;

	// ---------------------------------------------------------------- structural operations
	public static function equal(a:Any, b:Any):Bool return cmp(a, b, false) == 0;
	public static function compare(a:Any, b:Any):Int return cmp(a, b, true);

	static inline var UNORDERED = 0x7fffffff;
	// OCaml's compare_val: immediates before blocks; blocks by tag, then
	// size, then fields left to right. total: compare (nan = nan) or
	// equality (nan <> nan).
	static function cmp(a:Any, b:Any, total:Bool):Int {
		var r = cmpVal(a, b, total);
		if (r == UNORDERED) return total ? 0 : 1;
		return r;
	}
	static function cmpVal(a:Any, b:Any, total:Bool):Int {
		switch Type.typeof(a) {
			case TInt | TFloat:
				var x:Float = cast a, y:Float = cast b;
				if (x < y) return -1;
				if (x > y) return 1;
				if (x == y) return 0;
				// At least one nan.
				if (!total) return UNORDERED;
				if (x == x) return 1; // y is nan
				if (y == y) return -1; // x is nan
				return 0;
			case TBool:
				return compareBool(cast a, cast b);
			case TNull:
				return b == null ? 0 : -1;
			case TEnum(e):
				return cmpEnum(cast a, cast b, e, total);
			case TClass(c):
				if (c == String) return compareString(cast a, cast b);
				if (c == Array) {
					var x:Array<Any> = cast a, y:Array<Any> = cast b;
					if (x.length != y.length) return x.length < y.length ? -1 : 1;
					for (i in 0...x.length) {
						var r = cmpVal(x[i], y[i], total);
						if (r != 0) return r;
					}
					return 0;
				}
				if (Std.isOfType(a, PolyVariant)) {
					var x:PolyVariant = cast a, y:PolyVariant = cast b;
					var ax = !Std.isOfType(x, PolyVariant1), ay = !Std.isOfType(y, PolyVariant1);
					if (ax && ay) return compareInt(x.tag, y.tag);
					if (ax) return -1;
					if (ay) return 1;
					if (x.tag != y.tag) return compareInt(x.tag, y.tag);
					return cmpVal((cast x : PolyVariant1<Any>).arg, (cast y : PolyVariant1<Any>).arg, total);
				}
				if (Std.isOfType(a, haxe.io.Bytes)) {
					var r = (cast a : haxe.io.Bytes).compare(cast b);
					return r < 0 ? -1 : r > 0 ? 1 : 0;
				}
				if (Std.isOfType(a, Structural)) {
					if (a == b) return 0;
					var x = (cast a : Structural).structuralFields(), y = (cast b : Structural).structuralFields();
					if (x.length != y.length) return x.length < y.length ? -1 : 1;
					for (i in 0...x.length) {
						var r = cmpVal(x[i], y[i], total);
						if (r != 0) return r;
					}
					return 0;
				}
				if (Std.isOfType(a, Lazy)) throw new InvalidArgumentExn("compare: abstract value");
				throw new InvalidArgumentExn("compare: abstract value");
			case TFunction:
				throw new InvalidArgumentExn("compare: functional value");
			case _:
				throw new InvalidArgumentExn("compare: abstract value");
		}
	}
	// Constant constructors are immediates numbered among themselves; the
	// others are blocks tagged by their rank among non-constant ones.
	static var ranks = new Map<String, Array<Int>>();
	static function rankTable(e:Enum<Dynamic>):Array<Int> {
		var name = Type.getEnumName(e);
		var r = ranks.get(name);
		if (r != null) return r;
		var constants = [for (v in Type.allEnums(e)) Type.enumConstructor(v)];
		var c = 0, b = 0;
		r = [for (n in Type.getEnumConstructs(e)) constants.indexOf(n) >= 0 ? c++ : b++];
		ranks.set(name, r);
		return r;
	}
	static function cmpEnum(a:EnumValue, b:EnumValue, e:Enum<Dynamic>, total:Bool):Int {
		var pa = Type.enumParameters(a), pb = Type.enumParameters(b);
		var ia = Type.enumIndex(a), ib = Type.enumIndex(b);
		var ca = pa.length == 0, cb = pb.length == 0;
		if (ca != cb) return ca ? -1 : 1;
		if (ia != ib) {
			var t = rankTable(e);
			return compareInt(t[ia], t[ib]);
		}
		for (i in 0...pa.length) {
			var r = cmpVal(pa[i], pb[i], total);
			if (r != 0) return r;
		}
		return 0;
	}

	// ---------------------------------------------------------------- hashing
	// OCaml's caml_hash (runtime/hash.c): MurmurHash3 mixing over a
	// breadth-first walk of at most `count` meaningful values and `limit`
	// queued values. Hashtbl.hash is hashParam(10, 100, 0, v).
	public static function hash(v:Any):Int return hashParam(10, 100, 0, v);
	public static function hashParam(count:Int, limit:Int, seed:Int, v:Any):Int {
		var h = seed;
		var queue:Array<Any> = [v];
		var rd = 0, num = count;
		while (rd < queue.length && num > 0) {
			var x = queue[rd++];
			switch Type.typeof(x) {
				case TInt:
					h = mixInt(h, cast x);
					num--;
				case TBool:
					h = mixInt(h, (cast x : Bool) ? 1 : 0);
					num--;
				case TNull:
					h = mixInt(h, 0);
					num--;
				case TFloat:
					var f:Float = cast x;
					if (Math.isFinite(f) && Math.ffloor(f) == f && Math.abs(f) < 2147483648.0) {
						// An integer the target stores as a float (JS): still an OCaml int.
						h = mixInt(h, Std.int(f));
					} else h = mixDouble(h, f);
					num--;
				case TEnum(e):
					var ev:EnumValue = cast x;
					var ps = Type.enumParameters(ev);
					var rank = rankTable(e)[Type.enumIndex(ev)];
					if (ps.length == 0) {
						h = mixInt(h, rank);
						num--;
					} else {
						h = mix(h, (ps.length << 10) | rank);
						for (p in ps) if (queue.length < limit) queue.push(p);
					}
				case TClass(c):
					if (c == String) {
						h = mixString(h, cast x);
						num--;
					} else if (Std.isOfType(x, PolyVariant)) {
						var pv:PolyVariant = cast x;
						if (Std.isOfType(pv, PolyVariant1)) {
							h = mix(h, (2 << 10) | 0);
							if (queue.length < limit) queue.push(pv.tag);
							if (queue.length < limit) queue.push((cast pv : PolyVariant1<Any>).arg);
						} else {
							h = mixInt(h, pv.tag);
							num--;
						}
					} else if (c == Array) {
						var a:Array<Any> = cast x;
						h = mix(h, (a.length << 10) | 0);
						for (p in a) if (queue.length < limit) queue.push(p);
					} else if (Std.isOfType(x, Structural)) {
						var fs = (cast x : Structural).structuralFields();
						h = mix(h, (fs.length << 10) | 0);
						for (p in fs) if (queue.length < limit) queue.push(p);
					}
				case _:
			}
		}
		h = finalMix(h);
		return h & 0x3FFFFFFF;
	}
	static inline function rotl(x:Int, n:Int):Int return (x << n) | (x >>> (32 - n));
	static function mix(h:Int, d:Int):Int {
		d = d * 0xcc9e2d51;
		d = rotl(d, 15);
		d = d * 0x1b873593;
		h ^= d;
		h = rotl(h, 13);
		return h * 5 + 0xe6546b64;
	}
	// An OCaml int is hashed as its tagged 64-bit value folded to 32 bits.
	static inline function mixInt(h:Int, n:Int):Int return mix(h, (n << 1) | 1);
	static function finalMix(h:Int):Int {
		h ^= h >>> 16;
		h = h * 0x85ebca6b;
		h ^= h >>> 13;
		h = h * 0xc2b2ae35;
		h ^= h >>> 16;
		return h;
	}
	static function mixString(h:Int, s:String):Int {
		var len = s.length, i = 0;
		while (i + 4 <= len) {
			var w = StringTools.fastCodeAt(s, i) | (StringTools.fastCodeAt(s, i + 1) << 8) | (StringTools.fastCodeAt(s, i + 2) << 16) | (StringTools.fastCodeAt(s, i + 3) << 24);
			h = mix(h, w);
			i += 4;
		}
		var w = 0;
		switch (len & 3) {
			case 3:
				w = StringTools.fastCodeAt(s, i + 2) << 16;
				w |= StringTools.fastCodeAt(s, i + 1) << 8;
				w |= StringTools.fastCodeAt(s, i);
				h = mix(h, w);
			case 2:
				w = StringTools.fastCodeAt(s, i + 1) << 8;
				w |= StringTools.fastCodeAt(s, i);
				h = mix(h, w);
			case 1:
				w = StringTools.fastCodeAt(s, i);
				h = mix(h, w);
			case _:
		}
		return h ^ len;
	}
	static function mixDouble(h:Int, d:Float):Int {
		var bits = haxe.io.FPHelper.doubleToI64(d);
		var hi = bits.high, lo = bits.low;
		// Normalize NaNs and -0.0.
		if ((hi & 0x7FF00000) == 0x7FF00000 && ((hi & 0xFFFFF) | lo) != 0) {
			hi = 0x7FF00000;
			lo = 0x00000001;
		} else if (hi == 0x80000000 && lo == 0) {
			hi = 0;
		}
		h = mix(h, lo);
		return mix(h, hi);
	}
}
