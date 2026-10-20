// Type.createInstance in macro code: of a class value, of a class found by
// its name (one the code names: hxmc's program has the classes it refers
// to), of an instance's class; the arguments' default values, a constructor
// inherited and one calling super. (Native macros: the classes are the
// bundle's, their entries written by hxmc.macro.Loader, which counts them in
// for Type.resolveClass.)
class Make {
	public static macro function made():haxe.macro.Expr {
		var a = Type.createInstance(MacroThing, [2, "a"]);
		var b:MacroThing = Type.createInstance(Type.resolveClass("MacroThing"), [3]);
		var c = Type.createInstance(Type.getClass(a), [4, "c"]);
		var d:MacroThing = Type.createInstance(MacroSubThing, [5]);
		var e = Type.createInstance(MacroInherits, [6, "e"]);
		var s = [a, b, c, d, e].map(t -> t.describe()).join(" ") + " " + Std.isOfType(d, MacroThing) + " " + Type.getClassName(Type.getClass(e));
		return macro $v{s};
	}
}

class MacroThing {
	var n:Int;
	var s:String;
	var f:Float;

	public function new(n:Int, s = "dflt", f = 0.5) {
		this.n = n;
		this.s = s;
		this.f = f;
	}

	public function describe()
		return n + s + f;
}

class MacroSubThing extends MacroThing {
	public function new(n:Int)
		super(n * 10, "sub");

	override public function describe()
		return "<" + super.describe() + ">";
}

class MacroInherits extends MacroThing {}
