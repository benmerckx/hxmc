// Std and Type at their edges (upstream's unit tests TestStd, TestString,
// TestType, TestReflect, Issue5271): parseInt skips \v and \f too; indexOf("")
// past the end is the length, lastIndexOf("") before the start 0; Type.typeof
// of an Int64 is TInt64; createEnum checks the number of arguments;
// resolveClass("Array") is Array.
enum E {
	A;
	C(i:Int, s:String);
}

class StdEdges {
	static function main() {
		Sys.println(Std.parseInt(" \t\n\x0b\x0c\r16") + " " + Std.parseInt("\x0b0xa") + " " + Std.parseInt("\x0c-7"));
		var s = "foo1bar";
		Sys.println(s.indexOf("", 8) + " " + s.indexOf("", 200) + " " + s.indexOf("", 3) + " " + "".indexOf("", 1));
		Sys.println(s.lastIndexOf("", -1) + " " + "".lastIndexOf("", -1) + " " + s.lastIndexOf("f", -1) + " " + s.lastIndexOf("", 3) + " " + s.lastIndexOf("", 50));
		Sys.println(Type.typeof(haxe.Int64.make(1, 0)) + " " + Type.typeof(haxe.Int64.ofInt(256)) + " " + Type.typeof(1.5) + " " + Type.typeof(3));
		// (Eval also takes fewer arguments than C has, as nulls: not here)
		var all:Array<{c:String, args:Array<Dynamic>}> = [
			{c: "A", args: null}, {c: "A", args: []}, {c: "A", args: [0]}, {c: "C", args: null}, {c: "C", args: [1, "a"]}, {c: "A", args: [1, "a"]}
		];
		for (x in all) {
			var c = x.c, args = x.args;
			try {
				var v = Type.createEnum(E, c, args);
				Sys.println(c + " " + args + ": " + v);
			} catch (e:Dynamic) {
				Sys.println(c + " " + args + ": exception");
			}
		}
		Sys.println(Type.resolveClass("Array") == Array);
		Sys.println(Type.getClassName(Type.resolveClass("Array")));
		Sys.println(Type.resolveClass("String") == String);
	}
}
