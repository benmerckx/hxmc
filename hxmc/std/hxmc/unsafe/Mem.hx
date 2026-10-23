package hxmc.unsafe;

import hxmc.I64;

// Raw memory intrinsics for the runtime's Haxe code (docs/hxmc.md,
// "Runtime in Haxe"), expanded inline by the code generator (MirBuild):
// none is a function call and none but the allocations is a GC point.
// Offsets are bytes; an object's address is its payload (the header word is
// at -8, rt.h). `name` arguments must be string literals. Internal to the
// runtime's std, not a user API.
extern class Mem {
	// the payload address of a reference, and back (no conversion)
	static function addr(o:Dynamic):Ptr;
	static function obj(p:Ptr):Dynamic;
	// the address of a symbol of the program or the runtime object (data or code)
	static function sym(name:String):Ptr;
	// the address of a C string literal: its UTF-8 bytes and a NUL, read-only,
	// outside the heap (one copy per program)
	static function cstr(literal:String):Ptr;
	// the address of read-only data (one copy per program, 8-byte aligned):
	// 8-byte little-endian words, each written as `digits` (a constant)
	// hexadecimal digits of the literal, the most significant first (tables)
	static function words(literal:String, digits:Int):Ptr;
	// the runtime's pointer-sized thread-local variables (rt_sp, rt_young_ptr, ...)
	static function tlsGet(name:String):Ptr;
	static function tlsSet(name:String, v:Ptr):Void;
	// a constant of the code generator's Abi (TYPE_SIZE, IC_SLOT, ...)
	static function abi(name:String):Int;
	// the type index of a class (its instances' header: hxmc.rt.Types), named
	// as a literal: to allocate an instance with something else in the same
	// allocation (haxe.io.Bytes)
	static function typeIndexOf(c:Class<Dynamic>):Int;
	// the target: os() 0 Linux, 1 macOS, 2 Windows, 3 WASI (WebAssembly); arm() true on arm64
	static function os():Int;
	static function arm():Bool;
	// the target as one number (one comparison folds: write platform tests
	// as a single comparison of os(), arm() or target(), not a && b):
	// 0 linux-x86_64, 1 linux-arm64, 2 macos-x86_64, 3 macos-arm64,
	// 4 windows-x86_64, 5 windows-arm64, 6 wasm32-wasi, 7 linux-x86_64 and
	// 8 linux-arm64 with glibc (-D hxmc.libc=glibc), 9 android-x86_64, 10
	// android-arm64 (Bionic, os() Linux's: `Mem.target() >= 9` is Android)
	static function target():Int;
	// the Apple platform where os() is 1: 0 macOS, 1 iOS, 2 the iOS simulator
	// (target() 3 for both: macos-arm64's libSystem and layouts; packages
	// only, not the runtime: the committed stage0 does not know it)
	static function platform():Int;
	// a frame area of `bytes` (a constant), 16-byte aligned, valid while the function runs
	static function stack(bytes:Int):Ptr;
	// unsigned comparison
	static function ult(a:I64, b:I64):Bool;
	// the bits of a double, and the double of bits (a register move)
	static function f64Bits(v:Float):I64;
	static function bitsF64(b:I64):Float;
	// calls code at fn with the C ABI (GC points: the callee may collect):
	// fn(a) and fn(a, b) returning a reference
	static function callRef1(fn:Ptr, a:Dynamic):Dynamic;
	static function callRef2(fn:Ptr, a:Dynamic, b:Ptr):Dynamic;
	// fn() (no arguments, no result)
	static function call0(fn:Ptr):Void;
	// fn() on another stack: the stack pointer is `top` (16-byte aligned,
	// the end of a reserved range) for the call, the caller's again after it
	// (a few instructions per target, the stub hxmc_call_on_stack; not on
	// WebAssembly)
	static function callOnStack(top:Ptr, fn:Ptr):Void;
	// `bytes` zero bytes at p (x86-64: rep stosb, which writes whole cache
	// lines without reading them first; elsewhere the C library's memset;
	// not on WebAssembly). Not a GC point.
	static function zero(p:Ptr, bytes:I64):Void;
	// the calling function's frame record (Abi.framePointers): [frame] is the
	// caller's record, [frame + 8] the return address; null where functions
	// keep none (x86-64 with -D hxmc.no-frame-pointers, WebAssembly). A call
	// of the stub hxmc_frame. Not a GC point.
	static function frame():Ptr;

	// loads at p + off (8/16-bit and f32 loads widen; getI32 of 4 bytes)
	static function getI8(p:Ptr, off:Int):Int;
	static function getU8(p:Ptr, off:Int):Int;
	static function getI16(p:Ptr, off:Int):Int;
	static function getU16(p:Ptr, off:Int):Int;
	static function getI32(p:Ptr, off:Int):Int;
	static function getI64(p:Ptr, off:Int):I64;
	static function getF32(p:Ptr, off:Int):Float;
	static function getF64(p:Ptr, off:Int):Float;
	static function getPtr(p:Ptr, off:Int):Ptr;
	static function getRef(p:Ptr, off:Int):Dynamic;
	// stores at p + off (narrowing); setRef has no write barrier (young
	// objects, or the runtime's own roots), setRefBarrier stores into heap
	// object `o` at payload offset `off` through the write barrier
	static function setI8(p:Ptr, off:Int, v:Int):Void;
	static function setI16(p:Ptr, off:Int, v:Int):Void;
	static function setI32(p:Ptr, off:Int, v:Int):Void;
	static function setI64(p:Ptr, off:Int, v:I64):Void;
	static function setF32(p:Ptr, off:Int, v:Float):Void;
	static function setF64(p:Ptr, off:Int, v:Float):Void;
	static function setPtr(p:Ptr, off:Int, v:Ptr):Void;
	static function setRef(p:Ptr, off:Int, v:Dynamic):Void;
	static function setRefBarrier(o:Dynamic, off:Int, v:Dynamic):Void;
	// indexed: at p + off + i * (element size)
	static function getU8At(p:Ptr, off:Int, i:Int):Int;
	static function getU16At(p:Ptr, off:Int, i:Int):Int;
	static function getI32At(p:Ptr, off:Int, i:Int):Int;
	static function getI64At(p:Ptr, off:Int, i:Int):I64;
	static function getF64At(p:Ptr, off:Int, i:Int):Float;
	static function getRefAt(p:Ptr, off:Int, i:Int):Dynamic;
	static function setU8At(p:Ptr, off:Int, i:Int, v:Int):Void;
	static function setU16At(p:Ptr, off:Int, i:Int, v:Int):Void;
	static function setI32At(p:Ptr, off:Int, i:Int, v:Int):Void;
	static function setI64At(p:Ptr, off:Int, i:Int, v:I64):Void;
	static function setF64At(p:Ptr, off:Int, i:Int, v:Float):Void;

	// a new heap object of `nslots` 8-byte slots with this type index and
	// kind (hxmc.rt.Types K_*: K_OBJ a record, else an array of slots, its
	// length nslots): zeroed (alloc), or not (allocRaw: objects without
	// references only, which the collector does not scan). GC points.
	static function alloc(nslots:Int, tindex:Int, kind:Int):Dynamic;
	static function allocRaw(nslots:Int, tindex:Int, kind:Int):Dynamic;
	// a new array (hxmc.rt.Types: its type index; `words` 8-byte words of
	// elements, which its header counts; its length; a string, its type a
	// literal, its hash 0 instead): zeroed (allocArray), or not
	// (allocArrayRaw: without references only). GC points.
	static function allocArray(tindex:Int, length:Int, words:Int):Dynamic;
	static function allocArrayRaw(tindex:Int, length:Int, words:Int):Dynamic;
}
