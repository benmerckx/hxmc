// A program and its macros with types of the same name that differ (`#if
// macro`: Point has another field in the macro context, MacroOnly is there
// alone). With -D hxmc.macros=mir and --run on Mir (mir-check) both are
// bundles loaded into the compiler: the program's was linked against the
// macro context's, and failed with "type Point differs from the compiler's:
// slots 2 vs 1" (also for std types: haxe.iterators.ArrayKeyValueIterator).
// The program is now apart from them (macro.Loader.apart): its own types,
// and Type.resolveClass finds none of the macro context's.
// define: hxmc.macros=mir
class Point {
	public var x:Int;
	#if macro
	public var label:String;
	#end

	public function new(x) {
		this.x = x;
		#if macro
		label = "m" + x;
		#end
	}

	public function show():String
		return #if macro label + ":" + #end "p" + x;
}

#if macro
class MacroOnly {
	public function new() {}
}
#end

class MirRunMacros {
	macro static function fromMacro() {
		var p = new Point(7);
		var k = 0;
		for (i => v in [p.show(), Type.getClassName(Type.getClass(new MacroOnly()))])
			k += i * v.length;
		return macro $v{p.show() + " " + k};
	}

	static function main() {
		Sys.println(fromMacro());
		var p = new Point(3);
		Sys.println(p.show());
		Sys.println(Type.getClassName(Type.getClass(p)));
		var c = Type.resolveClass("Point");
		Sys.println(c == null ? "no Point" : (Type.createInstance(c, [5]) : Point).show());
		Sys.println(Type.resolveClass("MacroOnly") == null ? "no MacroOnly" : "MacroOnly found");
		var n = 0;
		for (i => s in ["a", "bb"])
			n += i * s.length;
		Sys.println(n);
	}
}
