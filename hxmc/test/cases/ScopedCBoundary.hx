import hxmc.I64;
import hxmc.scoped.*;
import hxmc.unsafe.UInt8;

// The scoped C boundary (docs/plans/lowlevel.md, "The scoped C boundary"):
// a C function declared with a view parameter (Slice, Str) takes its address
// and its length, a size_t, so scoped code passes data-stack, Fixed and
// literal memory to C without an address of its own; in a safe region too
// (a call not declared @:hxmc.fast), as that memory never moves. Natively
// (WasmViews: wasm32).
@:hxmc.c extern class LibCViews {
	static function strnlen(s:Slice<UInt8>):I64;
	@:native("strnlen") static function bytesBeforeZero(s:Str):I64;
}

@:hxmc.scoped class Calls {
	// data-stack memory: the bytes of s, a 0 after the first k
	public static function cut(s:Str, k:Int):Int {
		var b:Slice<UInt8> = Scope.slice(s.length);
		for (i in 0...s.length)
			b[i] = i == k ? 0 : s[i];
		return LibCViews.strnlen(b).toInt();
	}

	// a Fixed's memory, through its view
	public static function fixed():Int {
		var f = new Fixed<UInt8, 12>();
		for (i in 0...7)
			f[i] = 65 + i;
		return LibCViews.strnlen(f.view()).toInt() * 100 + LibCViews.strnlen(f.view().sub(2, 3)).toInt();
	}

	// a literal Slice, and a Str (UTF-16: 'A', then a 0 byte)
	public static function literals():Int {
		var b:Slice<UInt8> = [104, 105, 0, 33];
		return LibCViews.strnlen(b).toInt() * 100 + LibCViews.strnlen(b.sub(0, 1)).toInt() * 10 + LibCViews.bytesBeforeZero('AB').toInt();
	}
}

class ScopedCBoundary {
	static function main() {
		Sys.println(Calls.cut(Str.copyOf("hello from a Slice"), 5));
		Sys.println(Calls.cut(Str.copyOf("no zero"), 99));
		Sys.println(Calls.fixed());
		Sys.println(Calls.literals());
		// GC code passes views too
		var s = Str.copyOf("GC code");
		Sys.println(LibCViews.bytesBeforeZero(s).toInt());
	}
}
