package ml2hx.std;

// The few library functions the emitter's own semantic tests print with.
// The OCaml library runtime (runtime/ml2hx/std, branch hv-rt) takes
// precedence on the class path when it provides this module.
class Stdlib {
	static function out(s:String) {
		#if js
		js.Syntax.code("process.stdout.write(Buffer.from({0}, 'latin1'))", s);
		#elseif sys
		var b = haxe.io.Bytes.alloc(s.length);
		for (i in 0...s.length) b.set(i, StringTools.fastCodeAt(s, i));
		Sys.stdout().write(b);
		#end
	}
	public static function printString(s:String):ml2hx.rt.Unit { out(s); return ml2hx.rt.Unit.value; }
	public static function printEndline(s:String):ml2hx.rt.Unit { out(s + "\n"); return ml2hx.rt.Unit.value; }
	public static function printNewline(u:ml2hx.rt.Unit):ml2hx.rt.Unit { out("\n"); return ml2hx.rt.Unit.value; }
	public static function printInt(i:Int):ml2hx.rt.Unit { out(Std.string(i)); return ml2hx.rt.Unit.value; }
	public static function stringOfInt(i:Int):String return Std.string(i);
	public static function stringOfBool(b:Bool):String return b ? "true" : "false";
}
