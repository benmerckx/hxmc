import hxmc.Span;
import hxmc.unsafe.*;

// C strings at typed bindings (docs/interop.md, "Typed bindings"): a String
// argument is a NUL-terminated UTF-8 copy for the call (NULL for null), a
// String result C's string copied (null for NULL), borrowed or freed by the
// function @:hxmc.free names; make header-check checks them as char *.
@:hxmc.c @:hxmc.fast @:hxmc.safe @:hxmc.header("CBindingsStrings.h") extern class S {
	static function cs_len(s:String):Int;
	static function cs_greet():String;
	@:hxmc.free(cs_free) static function cs_upper(s:String):String;
	static function cs_free(p:Ptr):Void;
	static function cs_none():String;
	@:hxmc.len(out, n) static function cs_join(a:String, b:String, out:Span<UInt8>, n:USize):Int;
}

class CBindingsStrings {
	static function main() {
		trace(S.cs_len("héllo"), S.cs_len(""), S.cs_len(null));
		trace(S.cs_greet());
		trace(S.cs_upper("abc, é!"));
		trace(S.cs_none() == null);
		var b = haxe.io.Bytes.alloc(16);
		var n = S.cs_join("ab", "cd", Span.ofBytes(b), 16);
		trace(n, b.getString(0, n), S.cs_join("long", "er than sixteen bytes", Span.ofBytes(b), 16));
		var total = 0;
		for (i in 0...100000)
			total += S.cs_upper("x" + i).length;
		trace(total);
	}
}
