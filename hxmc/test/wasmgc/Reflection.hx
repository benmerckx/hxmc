// Type, Reflect, anonymous structures, enums as values, statics through a
// class value: compared with the native build (GcCheck)
enum Color {
	Red;
	Green;
	Rgb(r:Int, g:Int, b:Int);
	Named(name:String, alpha:Float);
}

class Point {
	public var x:Int;
	public var y:Float;
	public var label:String;

	public function new(x, y, label) {
		this.x = x;
		this.y = y;
		this.label = label;
	}
}

typedef Person = {name:String, ?age:Int};

// (as hxmc/test/cases/StaticReflection: its variables read before live code
// reads them otherwise, its functions as closures, Type.getClassFields in the
// reference's order, without dropped, the __meta__ static)
@RuntimeMeta([42, 0])
class Statics {
	static var x = 5;
	static var ratio = 1.5;
	static var flag = true;
	static var name:String;
	static inline var INLINED = 9;

	static function twice(n:Int)
		return n * 2;

	static function opt(n:Int = 4)
		return n + 1;

	static function dropped()
		return 0;

	public static function run() {
		var c:Dynamic = Statics;
		Sys.println(Reflect.field(Statics, "x") + " " + c.x + " " + c.ratio + " " + c.flag + " " + c.name + " " + c.INLINED);
		Reflect.setField(Statics, "x", 6);
		c.ratio = 2.5;
		Sys.println(x + " " + ratio + " " + Reflect.hasField(Statics, "x") + " " + Reflect.hasField(Statics, "nope"));
		var f = Reflect.field(Statics, "twice");
		Sys.println(f(21) + " " + c.opt() + " " + c.opt(1) + " " + Reflect.field(Statics, "nope"));
		Sys.println(Type.getClassFields(Statics).join(",") + " " + Reflect.fields(Statics).length);
		Sys.println(haxe.rtti.Meta.getType(Statics).RuntimeMeta[0][0]);
	}
}

class Reflection {
	static function describe(n:Person):String
		return n.name + (n.age == null ? "" : " " + n.age);

	static function main() {
		var p = new Point(3, 4.5, "p");
		Sys.println(Type.getClassName(Type.getClass(p)) + " " + (Type.getClass(p) == Point));
		Sys.println(Reflect.field(p, "x") + " " + Reflect.field(p, "y") + " " + Reflect.field(p, "label") + " " + Reflect.field(p, "nope"));
		Reflect.setField(p, "x", 10);
		Reflect.setField(p, "label", "q");
		Sys.println(p.x + " " + p.label + " " + Reflect.hasField(p, "y"));
		var e:Point = Type.createEmptyInstance(Point);
		Sys.println(e.x + " " + e.label);
		// anonymous structures
		var o = {name: "ann", age: 30};
		Sys.println(describe(o) + " " + describe({name: "bob"}));
		var d:Dynamic = {};
		Reflect.setField(d, "a", 1);
		Reflect.setField(d, "b", "two");
		Sys.println(Reflect.field(d, "a") + " " + Reflect.field(d, "b") + " " + Reflect.fields(d).length + " " + d.b);
		d.c = 3.5;
		Sys.println(d.c + " " + Reflect.hasField(d, "c") + " " + Reflect.hasField(d, "z"));
		var f = Reflect.fields(o);
		f.sort(Reflect.compare);
		Sys.println(f.join(","));
		// enums
		var cs = [Red, Rgb(1, 2, 3), Named("sky", 0.5), Green];
		for (c in cs)
			Sys.println(Type.enumConstructor(c) + " " + Type.enumIndex(c) + " " + Type.enumParameters(c).length);
		Sys.println(Type.getEnumConstructs(Color).join(","));
		var made = Type.createEnum(Color, "Rgb", [4, 5, 6]);
		switch made {
			case Rgb(r, g, b): Sys.println("made " + r + g + b);
			case _:
		}
		Sys.println(Type.enumEq(Rgb(1, 2, 3), Rgb(1, 2, 3)) + " " + Type.enumEq(Rgb(1, 2, 3), Rgb(1, 2, 4)) + " " + (Red == Red));
		Sys.println(Type.getEnumName(Type.getEnum(Green)) + " " + (Type.resolveClass("Point") == Point));
		// enums, Int64 and arithmetic as Dynamic
		var ds:Array<Dynamic> = [Red, Rgb(1, 2, 3), Named("sky", 0.5)];
		Sys.println(ds.join(",") + " " + Std.string(ds[1]) + " " + cs);
		var x:Dynamic = 7, y:Dynamic = 2, z:Dynamic = 0.5, s:Dynamic = "s";
		Sys.println([x + y, x - y, x * y, x / y, x % y, x & y, x | y, x ^ y, x << y, x >> y, x >>> y, x + z, z * y].join(",") + " " + (s + x) + " " + (x + s));
		var l1:Dynamic = haxe.Int64.make(1, 2), l2:Dynamic = haxe.Int64.make(1, 2), small:Dynamic = haxe.Int64.ofInt(7);
		Sys.println((l1 == l2) + " " + (l1 == small) + " " + (small == x) + " " + (x == small));
		Statics.run();
		Sys.println("done");
	}
}
