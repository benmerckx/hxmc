// Calls through structures and Dynamic. A structure's method of another
// signature than the call's: a method returning a number where the call takes
// Dynamic or a type parameter's word (IntIterator's next as Iterator<Dynamic>'s
// was a slow call each time), its result boxed or encoded. Calls of a Dynamic
// receiver's field: a class's methods (numbers in and out), a closure in a
// structure's field, a dynamic method, a static of a class read as Dynamic,
// String's and Array's methods, an enum's constructor by name, a
// Reflect.makeVarArgs function, a missing method, null. Reflect.getProperty
// and setProperty (a property's accessors, a plain field, a structure's, a
// name no field has), Reflect.callMethod (its array left as it was).
enum Shape {
	Circle(r:Float);
	Square(s:Int);
}

class Counter {
	public var n = 0;

	public function new() {}

	public function add(k:Int):Int
		return n += k;

	public function half():Float
		return n / 2;

	public function even():Bool
		return n % 2 == 0;

	public function name(prefix:String):String
		return prefix + n;

	public dynamic function hook(x:Int):Int
		return x * 10;

	public static function twice(x:Int):Int
		return x * 2;
}

class Temp {
	public var celsius:Float = 20;
	public var fahrenheit(get, set):Float;
	public var plain = 1;

	public function new() {}

	function get_fahrenheit()
		return celsius * 9 / 5 + 32;

	function set_fahrenheit(v:Float)
		return celsius = (v - 32) * 5 / 9;
}

typedef Num = {
	function half():Float;
	function even():Bool;
}

typedef DynNum = {
	function half():Dynamic;
	function even():Dynamic;
	function add(k:Int):Dynamic;
}

class DynCalls {
	static function sum(it:Iterator<Dynamic>):Float {
		var s = 0.0;
		while (it.hasNext())
			s += it.next();
		return s;
	}

	static function first<T>(it:Iterator<T>):T
		return it.next();

	static function main() {
		// structural calls, a method's result converted
		trace(sum(new IntIterator(0, 5)), sum([1.5, 2.5].iterator()));
		trace(first(new IntIterator(7, 9)) + 1);
		var c = new Counter();
		c.add(5);
		var d:DynNum = cast c;
		trace(d.half(), d.even(), d.add(2), Std.isOfType(d.half(), Float), Std.isOfType(d.add(0), Int));
		var nm:Num = c;
		trace(nm.half(), nm.even());
		// Dynamic receivers
		var o:Dynamic = c;
		trace(o.add(3), o.half(), o.even(), o.name("n="), o.hook(4));
		c.hook = x -> x + 1;
		trace(o.hook(4));
		var cls:Dynamic = Counter;
		trace(cls.twice(21));
		var s:Dynamic = "hello";
		trace(s.charAt(1), s.indexOf("l"), s.toUpperCase(), s.substr(1, 3), s.split("l"));
		var a:Dynamic = [3, 1, 2];
		a.push(4);
		a.sort((x, y) -> x - y);
		trace(a.join("-"), a.indexOf(2), a.length);
		var anon:Dynamic = {f: (x:Int) -> x + 100, g: (x:String, y:Int) -> x + y, v: 3};
		trace(anon.f(1), anon.g("a", 2));
		var va:Dynamic = {all: Reflect.makeVarArgs(args -> args.length + ":" + args.join(","))};
		trace(va.all(), va.all(1), va.all(1, "x", 2.5));
		var e:Dynamic = Shape;
		trace(e.Circle(1.5), e.Square(2));
		var it:Dynamic = new IntIterator(0, 3);
		var n = 0;
		while (it.hasNext())
			n += it.next();
		trace(n);
		var tp = new Temp();
		trace(Reflect.getProperty(tp, "fahrenheit"), Reflect.getProperty(tp, "plain"), Reflect.getProperty(tp, "nothing"));
		Reflect.setProperty(tp, "fahrenheit", 212);
		Reflect.setProperty(tp, "plain", 5);
		trace(tp.celsius, tp.plain, Reflect.getProperty({a: 1}, "a"), Reflect.getProperty(null, "a"));
		var args:Array<Dynamic> = [4];
		trace(Reflect.callMethod(null, Reflect.field(anon, "g"), ["b", 3]), Reflect.callMethod(c, Reflect.field(c, "add"), args), args);
		var grab = Reflect.makeVarArgs(a -> {
			a.push("more");
			return a.length;
		});
		trace(Reflect.callMethod(null, grab, args), args, Reflect.callMethod(null, grab, []));
		try {
			anon.missing(1);
			trace("no error");
		} catch (e:Dynamic) {
			trace("missing: " + e);
		}
		try {
			var z:Dynamic = null;
			z.f();
			trace("no error");
		} catch (e:Dynamic) {
			trace("null: " + e);
		}
	}
}
