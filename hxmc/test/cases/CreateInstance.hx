// Type.createInstance: the constructor a class's entry names
// (hxmc.ir.ClassInfo.maker, made by hxmc.ir.Lower once the program can call
// it, kept by hxmc.ir.Reach where live code can have the class value) called
// on a new instance with the arguments (hxmc.rt.Dyn.createInstance). The
// output is the reference's (--interp).
class CreateInstance {
	static function main() {
		// none, then several arguments of every representation
		var z = Type.createInstance(Zero, []);
		trace(z.tag + " " + Zero.made);
		var t = Type.createInstance(Two, [3, "x"]);
		trace(t.n + " " + t.s + " " + Std.isOfType(t, Two));
		var a = Type.createInstance(All, [1, 2.5, true, "s", [1, 2], {k: 1}]);
		trace(a.toString());
		// the missing trailing arguments are null: those with default values take
		// them (an Int's, a Float's, a Bool's given by the constructor's entry for
		// dynamic calls, a String's by the constructor), as do those given as null
		trace(Type.createInstance(Opt, [1]).toString());
		trace(Type.createInstance(Opt, [1, "b"]).toString());
		trace(Type.createInstance(Opt, [1, "b", 7, 2.5, false, "t"]).toString());
		trace(Type.createInstance(Opt, [1, null, null, null, null, null]).toString());
		trace(Type.createInstance(NullableOpt, []).c + " " + Type.createInstance(NullableOpt, [3]).c);
		// a constructor inherited (a subclass without one), one of a subclass
		// calling super
		var s = Type.createInstance(Sub, [5, "y"]);
		trace(s.n + " " + s.s + " " + Std.isOfType(s, Two) + " " + Std.isOfType(s, Sub) + " " + s.who());
		var s2 = Type.createInstance(SubOwn, [6]);
		trace(s2.n + " " + s2.s + " " + s2.extra + " " + s2.who());
		// a type parameter's arguments (Dynamic), an abstract class, a private constructor
		var b:Box<String> = Type.createInstance(Box, ["boxed"]);
		trace(b.value + " " + Type.createInstance(Box, [42]).value);
		trace(Type.createInstance(Shape, [4]).area());
		trace(Type.createInstance(Hidden, [9]).v);
		// a function argument, called by the constructor
		trace(Type.createInstance(Handler, [(x:Int) -> x * 2]).result);
		// the class from Type.resolveClass, from Type.getClass of an instance
		var r = Type.createInstance(Type.resolveClass("Two"), [7, "r"]);
		trace(r.n + " " + r.s + " " + Type.getClassName(Type.getClass(r)));
		var g = Type.createInstance(Type.getClass(s), [8, "g"]);
		trace(Type.getClassName(Type.getClass(g)) + " " + g.n);
		var m:haxe.ds.StringMap<Int> = Type.createInstance(Type.resolveClass("haxe.ds.StringMap"), []);
		m.set("k", 1);
		trace(m.get("k"));
		// a class no code names, only made by `new`
		var only = Type.createInstance(Type.getClass(new OnlyNew(1)), [2]);
		trace(only.v + " " + Type.getClassName(Type.getClass(only)) + " " + Std.isOfType(only, Zero));
		// what the constructor throws, what is thrown made by it
		try {
			Type.createInstance(Throws, ["no"]);
		} catch (x:String) {
			trace("caught " + x);
		}
		try {
			throw Type.createInstance(Failure, ["failed", 12]);
		} catch (f:Failure) {
			trace(f.message + " " + f.code + " " + Std.isOfType(f, haxe.Exception));
		}
		try {
			throw Type.createInstance(haxe.Exception, ["plain"]);
		} catch (x:haxe.Exception) {
			trace(x.message);
		}
		// a String's constructor, an Array's, a null class
		trace(Type.createInstance(String, ["str"]).length);
		var arr:Array<Int> = Type.createInstance(Array, []);
		arr.push(3);
		trace(arr);
		try {
			Type.createInstance(null, []);
		} catch (x:Dynamic) {
			trace(x);
		}
		// made many times, collected meanwhile
		var sum = 0;
		var c:Class<Two> = Two;
		for (i in 0...2000)
			sum += Type.createInstance(c, [i, "" + i]).s.length;
		trace(sum);
		// a class without a constructor: the call fails (the line differs: Eval
		// fails with this message, a failure of the compiler, which ends the run;
		// hxmc throws it)
		try {
			Type.createInstance(NoCtor, []);
		} catch (x:String) {
			trace(x);
		}
	}
}

class Zero {
	public static var made = 0;

	public var tag = "zero";

	public function new() {
		made++;
	}
}

class Two {
	public var n:Int;
	public var s:String;

	public function new(n:Int, s:String) {
		this.n = n;
		this.s = s;
	}

	public function who()
		return "two";
}

class Sub extends Two {
	override public function who()
		return "sub";
}

class SubOwn extends Two {
	public var extra:Float;

	public function new(n:Int) {
		super(n * 10, "own");
		extra = n / 4;
	}

	override public function who()
		return "subown";
}

class All {
	var i:Int;
	var f:Float;
	var b:Bool;
	var s:String;
	var a:Array<Int>;
	var o:Dynamic;

	public function new(i:Int, f:Float, b:Bool, s:String, a:Array<Int>, o:Dynamic) {
		this.i = i;
		this.f = f;
		this.b = b;
		this.s = s;
		this.a = a;
		this.o = o;
	}

	public function toString()
		return i + " " + f + " " + b + " " + s + " " + a + " " + o.k;
}

class Opt {
	var a:Int;
	var b:String;
	var c:Int;
	var d:Float;
	var e:Bool;
	var f:String;

	public function new(a:Int, ?b:String, c = 5, d = 1.5, e = true, f = "dflt") {
		this.a = a;
		this.b = b;
		this.c = c;
		this.d = d;
		this.e = e;
		this.f = f;
	}

	public function toString()
		return a + " " + b + " " + c + " " + d + " " + e + " " + f;
}

class NullableOpt {
	public var c:Null<Int>;

	public function new(?c:Int = 7)
		this.c = c;
}

class NoCtor {
	public function hi()
		return "hi";
}

class Box<T> {
	public var value:T;

	public function new(v:T)
		value = v;
}

abstract class Shape {
	var side:Int;

	public function new(side:Int)
		this.side = side;

	public function area()
		return side * side;
}

class Hidden {
	public var v:Int;

	function new(v:Int)
		this.v = v;
}

class Handler {
	public var result:Int;

	public function new(f:Int->Int)
		result = f(21);
}

class Throws {
	public function new(why:String)
		throw why;
}

class Failure extends haxe.Exception {
	public var code:Int;

	public function new(message:String, code:Int) {
		super(message);
		this.code = code;
	}
}

class OnlyNew extends Zero {
	public var v:Int;

	public function new(v:Int) {
		super();
		this.v = v * 100;
	}
}
