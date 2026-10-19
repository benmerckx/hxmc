package ml2hx.std;

import Array;
import String;
import StdTypes;
import ml2hx.rt.*;
import ml2hx.rt.MlList;

private typedef B = haxe.io.Bytes;

// Stdlib.Bytes over haxe.io.Bytes. The unsafe conversions to and from
// strings copy (a string is immutable units, bytes a mutable buffer).
class Bytes {
	static inline function bad(msg:String):Dynamic
		throw new InvalidArgument(msg);

	static inline function range(b:B, ofs:Int63, len:Int63):Bool
		return !(Int63.lt(ofs, Int63.zero) || Int63.lt(len, Int63.zero) || Int63.gt(ofs, Int63.sub(Int63.ofInt(b.length), len)));

	public static var empty(get, never):B;

	static inline function get_empty():B
		return B.alloc(0);

	public static inline function length(b:B):Int63
		return Int63.ofInt(b.length);

	public static function get(b:B, i:Int63):Int {
		var k = i.toInt();
		if (Int63.lt(i, Int63.zero) || k >= b.length) bad("index out of bounds");
		return b.get(k);
	}

	public static function set(b:B, i:Int63, c:Int):Unit {
		var k = i.toInt();
		if (Int63.lt(i, Int63.zero) || k >= b.length) bad("index out of bounds");
		b.set(k, c);
		return Unit.value;
	}

	public static inline function unsafeGet(b:B, i:Int63):Int
		return b.get(i.toInt());

	public static inline function unsafeSet(b:B, i:Int63, c:Int):Unit {
		b.set(i.toInt(), c);
		return Unit.value;
	}

	// uninitialized in OCaml; zeros here
	public static function create(n:Int63):B {
		if (Int63.lt(n, Int63.zero)) bad("Bytes.create");
		return B.alloc(n.toInt());
	}

	public static function make(n:Int63, c:Int):B {
		var b = create(n);
		b.fill(0, b.length, c);
		return b;
	}

	public static function init(n:Int63, f:Int63->Int):B {
		var b = create(n);
		for (i in 0...b.length) b.set(i, f(Int63.ofInt(i)));
		return b;
	}

	public static function fill(b:B, ofs:Int63, len:Int63, c:Int):Unit {
		if (!range(b, ofs, len)) bad("String.fill / Bytes.fill");
		b.fill(ofs.toInt(), len.toInt(), c);
		return Unit.value;
	}

	public static function copy(b:B):B {
		var r = B.alloc(b.length);
		r.blit(0, b, 0, b.length);
		return r;
	}

	public static inline function ofString(s:String):B
		return ByteString.toBytes(s);

	public static inline function toString(b:B):String
		return ByteString.ofBytes(b, 0, b.length);

	public static inline function unsafeOfString(s:String):B
		return ByteString.toBytes(s);

	public static inline function unsafeToString(b:B):String
		return ByteString.ofBytes(b, 0, b.length);

	public static function sub(b:B, ofs:Int63, len:Int63):B {
		if (!range(b, ofs, len)) bad("String.sub / Bytes.sub");
		return b.sub(ofs.toInt(), len.toInt());
	}

	public static function subString(b:B, ofs:Int63, len:Int63):String {
		if (!range(b, ofs, len)) bad("String.sub / Bytes.sub");
		return ByteString.ofBytes(b, ofs.toInt(), len.toInt());
	}

	public static function blit(src:B, srcOfs:Int63, dst:B, dstOfs:Int63, len:Int63):Unit {
		if (Int63.lt(len, Int63.zero) || !range(src, srcOfs, len) || !range(dst, dstOfs, len)) bad("Bytes.blit");
		dst.blit(dstOfs.toInt(), src, srcOfs.toInt(), len.toInt());
		return Unit.value;
	}

	public static inline function unsafeBlit(src:B, srcOfs:Int63, dst:B, dstOfs:Int63, len:Int63):Unit {
		dst.blit(dstOfs.toInt(), src, srcOfs.toInt(), len.toInt());
		return Unit.value;
	}

	public static function blitString(src:String, srcOfs:Int63, dst:B, dstOfs:Int63, len:Int63):Unit
		return ml2hx.std.String.blit(src, srcOfs, dst, dstOfs, len);

	public static function unsafeBlitString(src:String, srcOfs:Int63, dst:B, dstOfs:Int63, len:Int63):Unit {
		var so = srcOfs.toInt(), d = dstOfs.toInt();
		for (i in 0...len.toInt()) dst.set(d + i, StringTools.fastCodeAt(src, so + i));
		return Unit.value;
	}

	public static function cat(a:B, b:B):B {
		var r = B.alloc(a.length + b.length);
		r.blit(0, a, 0, a.length);
		r.blit(a.length, b, 0, b.length);
		return r;
	}

	public static function extend(b:B, left:Int63, right:Int63):B {
		var l = left.toInt(), r = right.toInt();
		var len = b.length + l + r;
		if (len < 0) bad("String.extend / Bytes.extend");
		var res = B.alloc(len);
		var srcoff = l < 0 ? -l : 0, dstoff = l < 0 ? 0 : l;
		var cpylen = b.length - srcoff;
		if (len - dstoff < cpylen) cpylen = len - dstoff;
		if (cpylen > 0) res.blit(dstoff, b, srcoff, cpylen);
		return res;
	}

	public static function iter(f:Int->Unit, b:B):Unit {
		for (i in 0...b.length) f(b.get(i));
		return Unit.value;
	}

	public static function iteri(f:(Int63, Int) -> Unit, b:B):Unit {
		for (i in 0...b.length) f(Int63.ofInt(i), b.get(i));
		return Unit.value;
	}

	public static function map(f:Int->Int, b:B):B {
		var r = B.alloc(b.length);
		for (i in 0...b.length) r.set(i, f(b.get(i)));
		return r;
	}

	public static function escaped(b:B):B
		return ofString(ml2hx.std.String.escaped(toString(b)));

	public static function index(b:B, c:Int):Int63 {
		for (i in 0...b.length) if (b.get(i) == c) return Int63.ofInt(i);
		throw NotFound.instance;
	}

	public static function equal(a:B, b:B):Bool
		return a.compare(b) == 0 && a.length == b.length;

	public static function compare(a:B, b:B):Int63
		return Int63.ofInt(Poly.compare(a, b));

	public static function concat(sep:B, l:MlList<B>):B {
		var out = new haxe.io.BytesBuffer();
		var first = true;
		while (true) switch l {
			case Nil: return out.getBytes();
			case Cons(x, t):
				if (!first) out.add(sep);
				first = false;
				out.add(x);
				l = t;
		}
	}

	public static function getUint8(b:B, i:Int63):Int63
		return Int63.ofInt(get(b, i));

	public static function setUint8(b:B, i:Int63, v:Int63):Unit
		return set(b, i, v.toInt() & 0xFF);

	static inline function check(b:B, i:Int63, n:Int) {
		if (Int63.lt(i, Int63.zero) || i.toInt() > b.length - n) bad("index out of bounds");
	}

	public static function getUint16Le(b:B, i:Int63):Int63 {
		check(b, i, 2);
		return Int63.ofInt(b.getUInt16(i.toInt()));
	}

	public static function getUint16Be(b:B, i:Int63):Int63 {
		check(b, i, 2);
		var k = i.toInt();
		return Int63.ofInt((b.get(k) << 8) | b.get(k + 1));
	}

	public static function getInt32Le(b:B, i:Int63):Int {
		check(b, i, 4);
		return b.getInt32(i.toInt());
	}

	public static function getInt32Be(b:B, i:Int63):Int {
		check(b, i, 4);
		var k = i.toInt();
		return (b.get(k) << 24) | (b.get(k + 1) << 16) | (b.get(k + 2) << 8) | b.get(k + 3);
	}

	public static function getInt64Le(b:B, i:Int63):haxe.Int64 {
		check(b, i, 8);
		return b.getInt64(i.toInt());
	}

	public static function setUint16Le(b:B, i:Int63, v:Int63):Unit {
		check(b, i, 2);
		b.setUInt16(i.toInt(), v.toInt() & 0xFFFF);
		return Unit.value;
	}

	public static function setInt32Le(b:B, i:Int63, v:Int):Unit {
		check(b, i, 4);
		b.setInt32(i.toInt(), v);
		return Unit.value;
	}

	public static function setInt64Le(b:B, i:Int63, v:haxe.Int64):Unit {
		check(b, i, 8);
		b.setInt64(i.toInt(), v);
		return Unit.value;
	}
}
