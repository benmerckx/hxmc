package hxmc.scoped;

import hxmc.I64;
import hxmc.rt.Repr;
import hxmc.unsafe.LibC;
import hxmc.unsafe.UInt8;

// A Grow's elements as bytes and back (docs/plans/lowlevel.md,
// "Serialization: relative references"): the elements' bytes in linear
// memory's layout, little-endian, the same on every target; T's fields
// scalars, Rels (indexes: the bytes mean the same wherever they are),
// scoped classes and Fixed of those, no references. Linear memory: the image
// is the elements' memory itself (a view, rooted at the Grow), loading one a
// copy after its check; WasmGC: written and read field by field. What T
// needs (its size, the checks of its Bools and Rels, its fields one by one)
// is made by the lowering for each T (hxmc.ir.Images: ImageParts).
@:hxmc.scoped class Image {
	// the image of g's elements: linearly their memory (a view, rooted at g),
	// on WasmGC a copy (fresh memory)
	public static inline function of<T>(g:Grow<T>):Slice<UInt8> {
		var size = ImageParts.size(g);
		#if hxmc.wasm_gc
		var n = g.length;
		var out:Slice<UInt8> = Scope.slice(n * size);
		for (i in 0...n)
			ImageParts.encode(g[i], out, i * size);
		return out;
		#else
		var s = g.slice();
		return new Slice<UInt8>(cast s.ptr(), s.length * size);
		#end
	}

	// the elements of image b appended to into, which is empty (a Rel counts
	// from b's first element); false, into left empty, when b is no image of
	// T's: a length not a multiple of T's size, a Bool not 0 or 1, a Rel past
	// the image
	public static inline function load<T>(b:Slice<UInt8>, into:Grow<T>):Bool {
		var size = ImageParts.size(into);
		var n = Std.int(b.length / size);
		var ok = into.length == 0 && n * size == b.length && ImageParts.check(b, n, into);
		if (ok) {
			#if hxmc.wasm_gc
			for (i in 0...n)
				into.push(ImageParts.decode(b, i * size, into));
			#else
			for (_ in 0...n)
				into.push(ImageParts.zero(into));
			if (n > 0) LibC.memcpy(cast into.slice().ptr(), cast b.ptr(), ((n * size) : I64));
			#end
		}
		return ok;
	}
}

// the lowering's, for the T of g (hxmc.ir.Images: no call is compiled as written)
@:noCompletion extern class ImageParts {
	// T's size in an image
	static function size<T>(g:Grow<T>):Int;

	// whether the n elements of b are T's (its Bools, its Rels)
	static function check<T>(b:Slice<UInt8>, n:Int, g:Grow<T>):Bool;

	// a zero T
	static function zero<T>(g:Grow<T>):T;

	// the T at b[at] (WasmGC)
	static function decode<T>(b:Slice<UInt8>, at:Int, g:Grow<T>):T;

	// v's bytes into out at at (WasmGC)
	static function encode<T>(v:T, out:Slice<UInt8>, at:Int):Void;
}

// little-endian reads and writes of an image's scalars, checked (the code the
// lowering makes for each T calls them)
@:hxmc.scoped @:noCompletion class ImageIO {
	public static function u8(b:Slice<UInt8>, at:Int):Int
		return b[at];

	public static function i8(b:Slice<UInt8>, at:Int):Int
		return (b[at] << 24) >> 24;

	public static function u16(b:Slice<UInt8>, at:Int):Int
		return b[at] | (b[at + 1] << 8);

	public static function i16(b:Slice<UInt8>, at:Int):Int
		return (u16(b, at) << 16) >> 16;

	public static function i32(b:Slice<UInt8>, at:Int):Int
		return b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24);

	public static function i64(b:Slice<UInt8>, at:Int):I64
		return ((i32(b, at + 4) : I64) << 32) | (((i32(b, at) : I64) << 32) >>> 32);

	public static function f32(b:Slice<UInt8>, at:Int):Float
		return Repr.i32ToFloat(i32(b, at));

	public static function f64(b:Slice<UInt8>, at:Int):Float
		return Repr.bitsDouble(i64(b, at));

	public static function bool(b:Slice<UInt8>, at:Int):Bool
		return b[at] != 0;

	public static function put8(b:Slice<UInt8>, at:Int, v:Int)
		b[at] = v;

	public static function put16(b:Slice<UInt8>, at:Int, v:Int) {
		b[at] = v;
		b[at + 1] = v >> 8;
	}

	public static function put32(b:Slice<UInt8>, at:Int, v:Int) {
		b[at] = v;
		b[at + 1] = v >> 8;
		b[at + 2] = v >> 16;
		b[at + 3] = v >>> 24;
	}

	public static function put64(b:Slice<UInt8>, at:Int, v:I64) {
		put32(b, at, v.toInt());
		put32(b, at + 4, (v >> 32).toInt());
	}

	public static function putF32(b:Slice<UInt8>, at:Int, v:Float)
		put32(b, at, Repr.floatToI32(v));

	public static function putF64(b:Slice<UInt8>, at:Int, v:Float)
		put64(b, at, Repr.doubleBits(v));

	public static function putBool(b:Slice<UInt8>, at:Int, v:Bool)
		b[at] = v ? 1 : 0;

	// (the checks: a Bool's byte not 0 or 1; a Rel not none and not one of the n elements)
	public static function badBool(b:Slice<UInt8>, at:Int):Bool
		return b[at] > 1;

	public static function badRel(b:Slice<UInt8>, at:Int, n:Int):Bool {
		var r = i32(b, at);
		return r < 0 || r > n;
	}
}
