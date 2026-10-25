package hxmc.unsafe;

import hxmc.I64;

// C functions called directly with the target's C ABI (@:hxmc.c: the
// field's name, or its @:native name, is the C symbol; @:hxmc.fast: calls
// stay in the running state and are not GC points, docs/plans/lowlevel.md). Scalars and pointers only: Int is a C int (32 bits), I64 and Ptr
// 64 bits (size_t, pointers, long long), Float a double. Every function
// the runtime's Haxe code calls in the C library is listed in mkrt.sh's
// `libc` (the Linux runtime object links them from musl).
@:hxmc.c @:hxmc.fast extern class LibC {
	static function memcpy(dst:Ptr, src:Ptr, n:I64):Ptr;
	static function memmove(dst:Ptr, src:Ptr, n:I64):Ptr;
	static function memset(dst:Ptr, c:Int, n:I64):Ptr;
	static function memcmp(a:Ptr, b:Ptr, n:I64):Int;
	static function strlen(s:Ptr):I64;
	static function strcmp(a:Ptr, b:Ptr):Int;
	static function malloc(n:I64):Ptr;
	static function free(p:Ptr):Void;
	static function realloc(p:Ptr, n:I64):Ptr;
	static function strtod(s:Ptr, end:Ptr):Float;
	static function rand():Int;
}
