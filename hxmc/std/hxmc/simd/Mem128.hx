package hxmc.simd;

import haxe.io.Bytes;
import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.unsafe.UInt8;

// A vector's bytes in memory (the vector types' loads and stores):
// unaligned, little-endian; 16 bytes, or the low 8 or 4 (a load zeroes the
// rest). Bytes: OutsideBounds unless 0 <= pos <= length - n. Spans: checked
// as their accesses are (a kernel's failure ends the program).
@:noCompletion class Mem128 {
	public static inline function loadBytes(b:Bytes, pos:Int):V128 {
		if (pos < 0 || pos > b.length - 16) throw haxe.io.Error.OutsideBounds;
		#if (target.name == "hxmc" && !hxmc.interp)
		return Simd.load("v128.load", hxmc.unsafe.Mem.addr(@:privateAccess b.b), pos);
		#else
		return new V128(b.getInt32(pos), b.getInt32(pos + 4), b.getInt32(pos + 8), b.getInt32(pos + 12));
		#end
	}

	public static inline function loadBytes64(b:Bytes, pos:Int):V128 {
		if (pos < 0 || pos > b.length - 8) throw haxe.io.Error.OutsideBounds;
		#if (target.name == "hxmc" && !hxmc.interp)
		return Simd.load("v128.load64_zero", hxmc.unsafe.Mem.addr(@:privateAccess b.b), pos);
		#else
		return new V128(b.getInt32(pos), b.getInt32(pos + 4), 0, 0);
		#end
	}

	public static inline function loadBytes32(b:Bytes, pos:Int):V128 {
		if (pos < 0 || pos > b.length - 4) throw haxe.io.Error.OutsideBounds;
		#if (target.name == "hxmc" && !hxmc.interp)
		return Simd.load("v128.load32_zero", hxmc.unsafe.Mem.addr(@:privateAccess b.b), pos);
		#else
		return new V128(b.getInt32(pos), 0, 0, 0);
		#end
	}

	public static inline function storeBytes(b:Bytes, pos:Int, v:V128):Void {
		if (pos < 0 || pos > b.length - 16) throw haxe.io.Error.OutsideBounds;
		#if (target.name == "hxmc" && !hxmc.interp)
		Simd.store("v128.store", hxmc.unsafe.Mem.addr(@:privateAccess b.b), pos, v);
		#else
		b.setInt32(pos, v.w0);
		b.setInt32(pos + 4, v.w1);
		b.setInt32(pos + 8, v.w2);
		b.setInt32(pos + 12, v.w3);
		#end
	}

	public static inline function storeBytes64(b:Bytes, pos:Int, v:V128):Void {
		if (pos < 0 || pos > b.length - 8) throw haxe.io.Error.OutsideBounds;
		#if (target.name == "hxmc" && !hxmc.interp)
		Simd.store("v128.store64_lane", hxmc.unsafe.Mem.addr(@:privateAccess b.b), pos, v);
		#else
		b.setInt32(pos, v.w0);
		b.setInt32(pos + 4, v.w1);
		#end
	}

	public static inline function storeBytes32(b:Bytes, pos:Int, v:V128):Void {
		if (pos < 0 || pos > b.length - 4) throw haxe.io.Error.OutsideBounds;
		#if (target.name == "hxmc" && !hxmc.interp)
		Simd.store("v128.store32_lane", hxmc.unsafe.Mem.addr(@:privateAccess b.b), pos, v);
		#else
		b.setInt32(pos, v.w0);
		#end
	}

	#if !(target.name == "hxmc" && !hxmc.interp)
	static inline function word(s:ReadOnlySpan<UInt8>, p:Int):Int
		return (s[p] : Int) | ((s[p + 1] : Int) << 8) | ((s[p + 2] : Int) << 16) | ((s[p + 3] : Int) << 24);

	static inline function putWord(s:Span<UInt8>, p:Int, x:Int) {
		s[p] = x & 0xff;
		s[p + 1] = (x >> 8) & 0xff;
		s[p + 2] = (x >> 16) & 0xff;
		s[p + 3] = x >>> 24;
	}
	#end

	public static inline function loadSpan(s:ReadOnlySpan<UInt8>, pos:Int):V128 {
		#if (target.name == "hxmc" && !hxmc.interp)
		return s.vload("v128.load", pos);
		#else
		// (the last byte first: out of range, nothing read)
		var last:Int = s[pos + 15];
		return new V128(word(s, pos), word(s, pos + 4), word(s, pos + 8), word(s, pos + 12));
		#end
	}

	public static inline function loadSpan64(s:ReadOnlySpan<UInt8>, pos:Int):V128 {
		#if (target.name == "hxmc" && !hxmc.interp)
		return s.vload("v128.load64_zero", pos);
		#else
		var last:Int = s[pos + 7];
		return new V128(word(s, pos), word(s, pos + 4), 0, 0);
		#end
	}

	public static inline function loadSpan32(s:ReadOnlySpan<UInt8>, pos:Int):V128 {
		#if (target.name == "hxmc" && !hxmc.interp)
		return s.vload("v128.load32_zero", pos);
		#else
		var last:Int = s[pos + 3];
		return new V128(word(s, pos), 0, 0, 0);
		#end
	}

	public static inline function storeSpan(s:Span<UInt8>, pos:Int, v:V128):Void {
		#if (target.name == "hxmc" && !hxmc.interp)
		s.vstore("v128.store", pos, v);
		#else
		// (both ends first: out of range, nothing written)
		var first:Int = s[pos], last:Int = s[pos + 15];
		putWord(s, pos, v.w0);
		putWord(s, pos + 4, v.w1);
		putWord(s, pos + 8, v.w2);
		putWord(s, pos + 12, v.w3);
		#end
	}

	public static inline function storeSpan64(s:Span<UInt8>, pos:Int, v:V128):Void {
		#if (target.name == "hxmc" && !hxmc.interp)
		s.vstore("v128.store64_lane", pos, v);
		#else
		var first:Int = s[pos], last:Int = s[pos + 7];
		putWord(s, pos, v.w0);
		putWord(s, pos + 4, v.w1);
		#end
	}

	public static inline function storeSpan32(s:Span<UInt8>, pos:Int, v:V128):Void {
		#if (target.name == "hxmc" && !hxmc.interp)
		s.vstore("v128.store32_lane", pos, v);
		#else
		var first:Int = s[pos], last:Int = s[pos + 3];
		putWord(s, pos, v.w0);
		#end
	}
}
