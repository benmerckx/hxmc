package ml2hx.prim;

import haxe.Int64;
import haxe.io.Bytes;
import ml2hx.rt.*;

// The compiler's own primitives (%name in `external` declarations) that are
// more than an expression: boxed integers, byte access, atomics, domain-local
// storage, Obj. The emitter inlines the simple ones.
class Builtin {
	static inline function divZero():Dynamic throw DivisionByZero.instance;

	// ---- int32 (haxe.Int32: wrapping 32-bit)
	public static inline function int32OfInt(x:Int63):haxe.Int32 return x.toInt64().low;
	public static inline function int32ToInt(x:haxe.Int32):Int63 return Int63.ofInt(x);
	public static function int32Div(a:haxe.Int32, b:haxe.Int32):haxe.Int32 {
		if (b == 0) divZero();
		if (b == -1) return -a;
		return Std.int((a : Int) / (b : Int));
	}
	public static function int32Mod(a:haxe.Int32, b:haxe.Int32):haxe.Int32 {
		if (b == 0) divZero();
		if (b == -1) return 0;
		return (a : Int) % (b : Int);
	}
	public static inline function int32Lsl(a:haxe.Int32, n:Int63):haxe.Int32 return a << (n.toInt() & 31);
	public static inline function int32Asr(a:haxe.Int32, n:Int63):haxe.Int32 return a >> (n.toInt() & 31);
	public static inline function int32Lsr(a:haxe.Int32, n:Int63):haxe.Int32 return a >>> (n.toInt() & 31);

	// ---- int64 and nativeint (haxe.Int64)
	public static inline function int64OfInt(x:Int63):Int64 return x.toInt64();
	public static inline function int64ToInt(x:Int64):Int63 return Int63.ofInt64(x);
	public static inline function int64OfInt32(x:haxe.Int32):Int64 return Int64.ofInt(x);
	public static inline function int64ToInt32(x:Int64):haxe.Int32 return x.low;
	static final minInt64 = Int64.make(0x80000000, 0);
	public static function int64Div(a:Int64, b:Int64):Int64 {
		if (b == 0) divZero();
		if (b == -1) return -a;
		return Int64.div(a, b);
	}
	public static function int64Mod(a:Int64, b:Int64):Int64 {
		if (b == 0) divZero();
		if (b == -1) return 0;
		return Int64.mod(a, b);
	}
	public static inline function int64Lsl(a:Int64, n:Int63):Int64 return Int64.shl(a, n.toInt() & 63);
	public static inline function int64Asr(a:Int64, n:Int63):Int64 return Int64.shr(a, n.toInt() & 63);
	public static inline function int64Lsr(a:Int64, n:Int63):Int64 return Int64.ushr(a, n.toInt() & 63);

	// ---- byte swaps
	public static inline function bswap16(x:Int63):Int63 {
		var v = x.toInt();
		return Int63.ofInt(((v & 0xFF) << 8) | ((v >> 8) & 0xFF));
	}
	public static inline function bswap32(v:haxe.Int32):haxe.Int32
		return ((v & 0xFF) << 24) | ((v & 0xFF00) << 8) | ((v >>> 8) & 0xFF00) | (v >>> 24);
	public static inline function bswap64(v:Int64):Int64 return Int64.make(bswap32(v.low), bswap32(v.high));

	// ---- multi-byte access (little-endian, as on OCaml's 64-bit targets)
	static function check(len:Int, i:Int63, n:Int):Int {
		if (Int63.lt(i, Int63.zero) || Int63.gt(Int63.add(i, Int63.ofInt(n)), Int63.ofInt(len))) throw new InvalidArgument("index out of bounds");
		return i.toInt();
	}
	public static function bytesGet16(b:Bytes, i:Int63):Int63 {
		var k = check(b.length, i, 2);
		return Int63.ofInt(b.get(k) | (b.get(k + 1) << 8));
	}
	public static function bytesGet32(b:Bytes, i:Int63):haxe.Int32 {
		var k = check(b.length, i, 4);
		return b.getInt32(k);
	}
	public static function bytesGet64(b:Bytes, i:Int63):Int64 {
		var k = check(b.length, i, 8);
		return b.getInt64(k);
	}
	public static function bytesSet16(b:Bytes, i:Int63, v:Int63):Unit {
		var k = check(b.length, i, 2), x = v.toInt64().low;
		b.set(k, x & 0xFF);
		b.set(k + 1, (x >> 8) & 0xFF);
		return Unit.value;
	}
	public static function bytesSet32(b:Bytes, i:Int63, v:haxe.Int32):Unit {
		b.setInt32(check(b.length, i, 4), v);
		return Unit.value;
	}
	public static function bytesSet64(b:Bytes, i:Int63, v:Int64):Unit {
		b.setInt64(check(b.length, i, 8), v);
		return Unit.value;
	}
	static function strCode(s:String, k:Int) return StringTools.fastCodeAt(s, k);
	public static function stringGet16(s:String, i:Int63):Int63 {
		var k = check(s.length, i, 2);
		return Int63.ofInt(strCode(s, k) | (strCode(s, k + 1) << 8));
	}
	public static function stringGet32(s:String, i:Int63):haxe.Int32 {
		var k = check(s.length, i, 4);
		return strCode(s, k) | (strCode(s, k + 1) << 8) | (strCode(s, k + 2) << 16) | (strCode(s, k + 3) << 24);
	}
	public static function stringGet64(s:String, i:Int63):Int64 {
		var k = check(s.length, i, 8);
		inline function w(o:Int):Int return strCode(s, k + o) | (strCode(s, k + o + 1) << 8) | (strCode(s, k + o + 2) << 16) | (strCode(s, k + o + 3) << 24);
		return Int64.make(w(4), w(0));
	}

	// ---- strings and bytes (strings are immutable here: conversions copy)
	// Bytes.unsafe_to_string then Bytes.unsafe_of_string gives the same bytes
	// back in OCaml (one block): the eval interpreter reads a process's output
	// into a buffer that way. A string a recent bytes_to_string made (that
	// String object: hxmc) converts back to its bytes; any other is copied.
	static final recentStrings = new haxe.ds.Vector<String>(4);
	static final recentBytes = new haxe.ds.Vector<Bytes>(4);
	static var recentNext = 0;
	public static function bytesToString(b:Bytes):String {
		var s = ByteString.ofBytes(b, 0, b.length);
		#if (target.name == "hxmc")
		// (not the short strings the runtime may share)
		if (b.length < 2) return s;
		recentStrings[recentNext] = s;
		recentBytes[recentNext] = b;
		recentNext = (recentNext + 1) & 3;
		#end
		return s;
	}
	public static function bytesOfString(s:String):Bytes {
		#if (target.name == "hxmc")
		for (i in 0...4) if (hxmc.Native.refEq(recentStrings[i], s)) return recentBytes[i];
		#end
		return ByteString.toBytes(s);
	}

	// ---- atomics (one domain)
	public static inline function atomicLoad<T>(r:Ref<T>):T return r.value;
	public static inline function atomicExchange<T>(r:Ref<T>, v:T):T {
		var old = r.value;
		r.value = v;
		return old;
	}
	public static function atomicCas<T>(r:Ref<T>, seen:T, v:T):Bool {
		if (r.value != seen) return false;
		r.value = v;
		return true;
	}
	public static inline function atomicFetchAdd(r:Ref<Int63>, n:Int63):Int63 {
		var old = r.value;
		r.value = Int63.add(old, n);
		return old;
	}

	// ---- domain-local storage: one domain, one state array
	// the current domain's local state (ml2hx.std.Thread: per domain)
	public static var dls(get, set):Array<Dynamic>;
	static inline function get_dls():Array<Dynamic> return ml2hx.std.Thread.current.domain.dls;
	static inline function set_dls(s:Array<Dynamic>):Array<Dynamic> return ml2hx.std.Thread.current.domain.dls = s;
	public static inline function dlsGet(_:Unit):Array<Dynamic> return dls;
}
