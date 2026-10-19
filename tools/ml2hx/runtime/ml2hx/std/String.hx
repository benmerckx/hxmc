package ml2hx.std;

import Array;
import StdTypes;
import Array as HArray;
import ml2hx.rt.*;
import ml2hx.rt.MlList;
import ml2hx.rt.MlOption;

private typedef S = std.String;

// Stdlib.String over byte strings (one unit per byte, ml2hx.rt.ByteString)
class String {
	static inline function at(s:S, i:Int):Int
		return StringTools.fastCodeAt(s, i);

	static inline function ofCode(c:Int):S
		return S.fromCharCode(c);

	public static var empty(get, never):S;

	static inline function get_empty():S
		return "";

	public static inline function length(s:S):Int63
		return Int63.ofInt(s.length);

	public static function get(s:S, i:Int63):Int {
		var n = i.toInt();
		if (!i.isInt() || n < 0 || n >= s.length) throw new InvalidArgument("index out of bounds");
		return at(s, n);
	}

	public static inline function unsafeGet(s:S, i:Int63):Int
		return at(s, i.toInt());

	public static function make(n:Int63, c:Int):S {
		if (Int63.lt(n, Int63.zero)) throw new InvalidArgument("String.make");
		var k = n.toInt();
		if (k == 0) return "";
		var b = new StringBuf();
		for (_ in 0...k) b.addChar(c);
		return b.toString();
	}

	public static function init(n:Int63, f:Int63->Int):S {
		if (Int63.lt(n, Int63.zero)) throw new InvalidArgument("String.init");
		var b = new StringBuf();
		for (i in 0...n.toInt()) b.addChar(f(Int63.ofInt(i)));
		return b.toString();
	}

	public static function sub(s:S, ofs:Int63, len:Int63):S {
		var o = ofs.toInt(), l = len.toInt();
		if (!ofs.isInt() || !len.isInt() || o < 0 || l < 0 || o > s.length - l) throw new InvalidArgument("String.sub / Bytes.sub");
		return s.substr(o, l);
	}

	public static inline function unsafeBlit(src:S, srcOfs:Int63, dst:haxe.io.Bytes, dstOfs:Int63, len:Int63):Unit
		return blit(src, srcOfs, dst, dstOfs, len);

	public static function blit(src:S, srcOfs:Int63, dst:haxe.io.Bytes, dstOfs:Int63, len:Int63):Unit {
		var so = srcOfs.toInt(), d = dstOfs.toInt(), l = len.toInt();
		if (l < 0 || so < 0 || so > src.length - l || d < 0 || d > dst.length - l) throw new InvalidArgument("String.blit / Bytes.blit_string");
		for (i in 0...l) dst.set(d + i, at(src, so + i));
		return Unit.value;
	}

	public static function concat(sep:S, l:MlList<S>):S {
		var b = new StringBuf();
		var first = true;
		while (true) switch l {
			case Nil: return b.toString();
			case Cons(x, t):
				if (!first) b.add(sep);
				first = false;
				b.add(x);
				l = t;
		}
	}

	public static inline function cat(a:S, b:S):S
		return a + b;

	public static function iter(f:Int->Unit, s:S):Unit {
		for (i in 0...s.length) f(at(s, i));
		return Unit.value;
	}

	public static function iteri(f:(Int63, Int) -> Unit, s:S):Unit {
		for (i in 0...s.length) f(Int63.ofInt(i), at(s, i));
		return Unit.value;
	}

	public static function map(f:Int->Int, s:S):S {
		var b = new StringBuf();
		for (i in 0...s.length) b.addChar(f(at(s, i)));
		return b.toString();
	}

	public static function mapi(f:(Int63, Int) -> Int, s:S):S {
		var b = new StringBuf();
		for (i in 0...s.length) b.addChar(f(Int63.ofInt(i), at(s, i)));
		return b.toString();
	}

	public static function foldLeft<A>(f:(A, Int) -> A, acc:A, s:S):A {
		for (i in 0...s.length) acc = f(acc, at(s, i));
		return acc;
	}

	public static function foldRight<A>(f:(Int, A) -> A, s:S, acc:A):A {
		var i = s.length;
		while (i > 0) acc = f(at(s, --i), acc);
		return acc;
	}

	public static function exists(p:Int->Bool, s:S):Bool {
		for (i in 0...s.length) if (p(at(s, i))) return true;
		return false;
	}

	public static function forAll(p:Int->Bool, s:S):Bool {
		for (i in 0...s.length) if (!p(at(s, i))) return false;
		return true;
	}

	static inline function isSpace(c:Int):Bool
		return c == 32 || c == 12 || c == 10 || c == 13 || c == 9;

	public static function trim(s:S):S {
		if (s == "") return s;
		if (!isSpace(at(s, 0)) && !isSpace(at(s, s.length - 1))) return s;
		var i = 0, j = s.length - 1;
		while (i <= j && isSpace(at(s, i))) i++;
		while (j >= i && isSpace(at(s, j))) j--;
		return s.substr(i, j - i + 1);
	}

	// Bytes.escaped: \" \\ \n \t \r \b, printable ASCII as is, others \ddd
	public static function escaped(s:S):S {
		var needed = false;
		for (i in 0...s.length) {
			var c = at(s, i);
			if (c == 34 || c == 92 || c < 32 || c > 126) {
				needed = true;
				break;
			}
		}
		if (!needed) return s;
		var b = new StringBuf();
		for (i in 0...s.length) {
			var c = at(s, i);
			switch c {
				case 34: b.add("\\\"");
				case 92: b.add("\\\\");
				case 10: b.add("\\n");
				case 9: b.add("\\t");
				case 13: b.add("\\r");
				case 8: b.add("\\b");
				case c if (c >= 32 && c <= 126): b.addChar(c);
				case c:
					b.addChar(92);
					b.addChar(48 + Std.int(c / 100));
					b.addChar(48 + Std.int(c / 10) % 10);
					b.addChar(48 + c % 10);
			}
		}
		return b.toString();
	}

	public static function index(s:S, c:Int):Int63 {
		for (i in 0...s.length) if (at(s, i) == c) return Int63.ofInt(i);
		throw NotFound.instance;
	}

	public static function indexOpt(s:S, c:Int):MlOption<Int63> {
		for (i in 0...s.length) if (at(s, i) == c) return Some(Int63.ofInt(i));
		return None;
	}

	public static function indexFrom(s:S, i:Int63, c:Int):Int63 {
		var k = i.toInt();
		if (Int63.lt(i, Int63.zero) || k > s.length) throw new InvalidArgument("String.index_from / Bytes.index_from");
		for (j in k...s.length) if (at(s, j) == c) return Int63.ofInt(j);
		throw NotFound.instance;
	}

	public static function indexFromOpt(s:S, i:Int63, c:Int):MlOption<Int63> {
		var k = i.toInt();
		if (Int63.lt(i, Int63.zero) || k > s.length) throw new InvalidArgument("String.index_from_opt / Bytes.index_from_opt");
		for (j in k...s.length) if (at(s, j) == c) return Some(Int63.ofInt(j));
		return None;
	}

	public static function rindex(s:S, c:Int):Int63 {
		var i = s.length;
		while (--i >= 0) if (at(s, i) == c) return Int63.ofInt(i);
		throw NotFound.instance;
	}

	public static function rindexOpt(s:S, c:Int):MlOption<Int63> {
		var i = s.length;
		while (--i >= 0) if (at(s, i) == c) return Some(Int63.ofInt(i));
		return None;
	}

	public static function rindexFrom(s:S, i:Int63, c:Int):Int63 {
		var k = i.toInt();
		if (Int63.lt(i, Int63.minusOne) || k >= s.length) throw new InvalidArgument("String.rindex_from / Bytes.rindex_from");
		while (k >= 0) {
			if (at(s, k) == c) return Int63.ofInt(k);
			k--;
		}
		throw NotFound.instance;
	}

	public static function rindexFromOpt(s:S, i:Int63, c:Int):MlOption<Int63> {
		var k = i.toInt();
		if (Int63.lt(i, Int63.minusOne) || k >= s.length) throw new InvalidArgument("String.rindex_from_opt / Bytes.rindex_from_opt");
		while (k >= 0) {
			if (at(s, k) == c) return Some(Int63.ofInt(k));
			k--;
		}
		return None;
	}

	public static function contains(s:S, c:Int):Bool {
		for (i in 0...s.length) if (at(s, i) == c) return true;
		return false;
	}

	public static function containsFrom(s:S, i:Int63, c:Int):Bool {
		var k = i.toInt();
		if (Int63.lt(i, Int63.zero) || k > s.length) throw new InvalidArgument("String.contains_from / Bytes.contains_from");
		for (j in k...s.length) if (at(s, j) == c) return true;
		return false;
	}

	public static function rcontainsFrom(s:S, i:Int63, c:Int):Bool {
		var k = i.toInt();
		if (Int63.lt(i, Int63.zero) || k >= s.length) throw new InvalidArgument("String.rcontains_from / Bytes.rcontains_from");
		while (k >= 0) {
			if (at(s, k) == c) return true;
			k--;
		}
		return false;
	}

	static function mapChars(s:S, f:Int->Int):S {
		var changed = false;
		for (i in 0...s.length) if (f(at(s, i)) != at(s, i)) {
			changed = true;
			break;
		}
		if (!changed) return s;
		var b = new StringBuf();
		for (i in 0...s.length) b.addChar(f(at(s, i)));
		return b.toString();
	}

	public static function uppercaseAscii(s:S):S
		return mapChars(s, Char.uppercaseAscii);

	public static function lowercaseAscii(s:S):S
		return mapChars(s, Char.lowercaseAscii);

	public static function capitalizeAscii(s:S):S
		return s == "" ? s : ofCode(Char.uppercaseAscii(at(s, 0))) + s.substr(1);

	public static function uncapitalizeAscii(s:S):S
		return s == "" ? s : ofCode(Char.lowercaseAscii(at(s, 0))) + s.substr(1);

	public static function startsWith(prefix:S, s:S):Bool
		return StringTools.startsWith(s, prefix);

	public static function endsWith(suffix:S, s:S):Bool
		return StringTools.endsWith(s, suffix);

	public static inline function compare(a:S, b:S):Int63
		return Int63.ofInt(Poly.compareStrings(a, b));

	public static inline function equal(a:S, b:S):Bool
		return a == b;

	public static function splitOnChar(sep:Int, s:S):MlList<S> {
		var r:MlList<S> = Nil;
		var j = s.length;
		var i = s.length - 1;
		while (i >= 0) {
			if (at(s, i) == sep) {
				r = Cons(s.substr(i + 1, j - i - 1), r);
				j = i;
			}
			i--;
		}
		return Cons(s.substr(0, j), r);
	}

	public static function toSeq(s:S):Seq.SeqT<Int> {
		function aux(i:Int):Seq.SeqT<Int>
			return _ -> i >= s.length ? Seq.SeqNode.Nil : Seq.SeqNode.Cons(at(s, i), aux(i + 1));
		return aux(0);
	}

	public static function ofSeq(q:Seq.SeqT<Int>):S {
		var b = new StringBuf();
		Seq.iter(c -> {
			b.addChar(c);
			Unit.value;
		}, q);
		return b.toString();
	}

	public static function getUtf_8Uchar(s:S, i:Int63):Int63 {
		var k = i.toInt();
		if (Int63.lt(i, Int63.zero) || k >= s.length) throw new InvalidArgument("index out of bounds");
		return Int63.ofInt(StringUtf8.decode(at, s, k, s.length - 1));
	}

	public static function isValidUtf_8(s:S):Bool {
		var i = 0;
		while (i < s.length) {
			var d = StringUtf8.decode(at, s, i, s.length - 1);
			if ((d >>> 27) != 1) return false;
			i += (d >>> 24) & 7;
		}
		return true;
	}

	public static inline function ofBytes(b:haxe.io.Bytes):S
		return ByteString.ofBytes(b, 0, -1);

	public static inline function toBytes(s:S):haxe.io.Bytes
		return ByteString.toBytes(s);

	public static inline function hash(s:S):Int63
		return Int63.ofInt(Poly.hash(s));
}

// bytes.ml's get_utf_8_uchar over any byte getter: the utf_decode value
class StringUtf8 {
	static inline function dec(n:Int, u:Int):Int
		return ((8 | n) << 24) | u;

	static inline function invalid(n:Int):Int
		return (n << 24) | 0xFFFD;

	public static inline function decode<T>(get:(T, Int) -> Int, b:T, i:Int, max:Int):Int {
		var b0 = get(b, i);
		inline function cont(x:Int):Bool
			return x >> 6 == 2;
		return if (b0 <= 0x7F) dec(1, b0) else if (b0 >= 0xC2 && b0 <= 0xDF) {
			if (i + 1 > max) invalid(1) else {
				var b1 = get(b, i + 1);
				if (!cont(b1)) invalid(1) else dec(2, ((b0 & 0x1F) << 6) | (b1 & 0x3F));
			}
		} else if (b0 >= 0xE0 && b0 <= 0xEF) {
			if (i + 1 > max) invalid(1) else {
				var b1 = get(b, i + 1);
				var ok1 = b0 == 0xE0 ? (b1 >> 5 == 5) : (b0 == 0xED ? (b1 >> 5 == 4) : cont(b1));
				if (!ok1) invalid(1) else if (i + 2 > max) invalid(2) else {
					var b2 = get(b, i + 2);
					if (!cont(b2)) invalid(2) else dec(3, ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F));
				}
			}
		} else if (b0 >= 0xF0 && b0 <= 0xF4) {
			if (i + 1 > max) invalid(1) else {
				var b1 = get(b, i + 1);
				var ok1 = b0 == 0xF0 ? (b1 >= 0x90 && b1 <= 0xBF) : (b0 == 0xF4 ? (b1 >> 4 == 8) : cont(b1));
				if (!ok1) invalid(1) else if (i + 2 > max) invalid(2) else {
					var b2 = get(b, i + 2);
					if (!cont(b2)) invalid(2) else if (i + 3 > max) invalid(3) else {
						var b3 = get(b, i + 3);
						if (!cont(b3)) invalid(3) else dec(4, ((b0 & 0x07) << 18) | ((b1 & 0x3F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F));
					}
				}
			}
		} else invalid(1);
	}
}
