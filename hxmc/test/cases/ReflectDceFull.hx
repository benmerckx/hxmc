// define: dce=full
// Classes by names built at run time under -dce full, as Haxe's other
// targets find them (hxmc.ir.Reach; docs/hxmc.md, "Reachability"): a class
// only a type of live code names (DCE keeps it), one @:keep keeps (and its
// methods), not one nothing names, by a literal either (DCE removed it). The
// output is JS's (-dce full).
class Saved {
	public var n:Int;

	public function new(n:Int) {
		this.n = n;
	}

	public function twice():Int
		return n * 2;
}

@:keep
class Kept {
	public function new() {}

	public function hello():String
		return "kept";
}

class Literal {
	public function new() {}
}

class Unnamed {
	public function new() {}
}

class ReflectDceFull {
	static function nameOf(codes:Array<Int>):String
		return [for (c in codes) String.fromCharCode(c)].join("");

	static function main() {
		// (only a type: what a program that reads saved data and never makes it has)
		var s:Null<Saved> = Std.random(2) > 5 ? null : null;
		trace(s == null);
		trace(Type.resolveClass("Literal") != null);
		for (n in [nameOf([83, 97, 118, 101, 100]), nameOf([75, 101, 112, 116]), nameOf([85, 110, 110, 97, 109, 101, 100])]) {
			var c = Type.resolveClass(n);
			trace(n + " " + (c != null));
			if (c == null) continue;
			var o:Dynamic = Type.createEmptyInstance(c);
			trace(Type.getClassName(c) + " " + Std.isOfType(o, c));
		}
		var k:Dynamic = Type.createInstance(Type.resolveClass(nameOf([75, 101, 112, 116])), []);
		trace(Reflect.callMethod(k, Reflect.field(k, nameOf([104, 101, 108, 108, 111])), []));
	}
}
