package hxmc.scoped;

import hxmc.I64;
import hxmc.rt.Abort;
import hxmc.unsafe.Mem;
import hxmc.unsafe.UInt8;

// Little-endian scalars of a byte view at a byte offset, checked: the
// structures C fills or reads (sockaddr, stat, timeval) in a Fixed or on the
// data stack. Linearly one range test and one access; on WasmGC byte by byte.
class LE {
	static inline function check(b:Slice<UInt8>, at:Int, n:Int)
		if (at < 0 || at > b.length - n) Abort.outOfRange();

	public static inline function u16(b:Slice<UInt8>, at:Int):Int {
		check(b, at, 2);
		return #if hxmc.wasm_gc b.unsafeGet(at) | (b.unsafeGet(at + 1) << 8) #else Mem.getU16(b.ptr(), at) #end;
	}

	public static inline function i32(b:Slice<UInt8>, at:Int):Int {
		check(b, at, 4);
		return #if hxmc.wasm_gc Slice.word(b, at) #else Mem.getI32(b.ptr(), at) #end;
	}

	public static inline function i64(b:Slice<UInt8>, at:Int):I64 {
		check(b, at, 8);
		return #if hxmc.wasm_gc ((Slice.word(b, at + 4) : I64) << 32) | (((Slice.word(b, at) : I64) << 32) >>> 32) #else Mem.getI64(b.ptr(), at) #end;
	}

	public static inline function put16(b:Slice<UInt8>, at:Int, v:Int) {
		check(b, at, 2);
		#if hxmc.wasm_gc
		b.unsafeSet(at, v);
		b.unsafeSet(at + 1, v >> 8);
		#else
		Mem.setI16(b.ptr(), at, v);
		#end
	}

	public static inline function put32(b:Slice<UInt8>, at:Int, v:Int) {
		check(b, at, 4);
		#if hxmc.wasm_gc
		for (k in 0...4)
			b.unsafeSet(at + k, v >> (8 * k));
		#else
		Mem.setI32(b.ptr(), at, v);
		#end
	}

	public static inline function put64(b:Slice<UInt8>, at:Int, v:I64) {
		check(b, at, 8);
		#if hxmc.wasm_gc
		put32(b, at, v.toInt());
		put32(b, at + 4, (v >> 32).toInt());
		#else
		Mem.setI64(b.ptr(), at, v);
		#end
	}
}
