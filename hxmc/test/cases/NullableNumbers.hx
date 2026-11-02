// Null<Int> and Null<Float> as tagged words (docs/hxmc.md, "Values of type
// parameters"): null is 0, a number encoded, so storing one allocates
// nothing. The boundaries: from and to Dynamic (a box from Dynamic is a
// word as it is), == null and == a number, arithmetic and ordering with
// null (the static targets' rules), optional arguments and default values
// (direct calls, closures, dynamic calls, Reflect.callMethod), fields and
// statics read and written by reflection, JSON and haxe.Serializer,
// structures, arrays, maps, closures, enum arguments, Std.string,
// Std.isOfType, string interpolation, and allocation per store.
import haxe.Json;
import haxe.Serializer;
import haxe.Unserializer;

class Rec {
	public var i:Null<Int>;
	public var f:Null<Float>;
	public var b:Null<Bool>;

	public static var si:Null<Int> = 7;
	public static var sf:Null<Float>;

	public function new(?i:Int, ?f:Float) {
		this.i = i;
		this.f = f;
	}

	public function opt(?x:Int, y:Float = 2.5, ?z:Null<Float>):String
		return '$x $y $z ${x == null} ${z == null}';
}

enum E {
	A(n:Null<Int>);
	B(x:Null<Float>, y:Int);
}

class NullableNumbers {
	static function show(x:Null<Int>):String
		return x == null ? "null" : "" + x;

	static function addOpt(a:Int, ?b:Int):Int
		return b == null ? a : a + b;

	static function dflt(a:Int = 3, ?b:Float, c:Float = 0.5):String
		return '$a $b $c';

	static function sum(xs:Array<Null<Int>>):Int {
		var s = 0;
		for (x in xs)
			if (x != null) s += x;
		return s;
	}

	static function main() {
		// from and to Dynamic
		var d:Dynamic = 5;
		var dn:Dynamic = null;
		var df:Dynamic = 2.5;
		var a:Null<Int> = d, b:Null<Int> = dn, c:Null<Float> = df, e:Null<Float> = d;
		Sys.println([show(a), show(b), "" + c, "" + e, "" + (a + 1), "" + (c * 2)].join(" "));
		var back:Dynamic = a, backf:Dynamic = c, backn:Dynamic = b;
		Sys.println([Std.string(back), Std.string(backf), Std.string(backn), "" + (back == 5), "" + (backn == null), Type.typeof(back).getName(), Type.typeof(backf).getName()].join(" "));

		// == null, == numbers, NaN, -0
		var n:Null<Int> = null, z:Null<Int> = 0, m:Null<Float> = Math.NaN, nz:Null<Float> = -0.0;
		Sys.println([n == null, z == null, z == 0, n == 0, a == 5, a == 5.0, c == 2.5, m == m, nz == 0, nz == z, n == n, a != b].join(" "));

		// arithmetic and ordering with null
		var x:Null<Int> = 4, y:Null<Float> = 1.5;
		Sys.println([x + 1, x * y, x / 8, -x, x % 3, x >> 1].join(" "));
		Sys.println([n < 1, n > -1, n <= n, n >= n, x > y, y < x, n < x, x < n].join(" "));
		x++;
		x += 2;
		var w:Null<Int> = null;
		Sys.println(x + " " + (w == null ? "w null" : "w " + w));

		// optional arguments and default values
		var r = new Rec();
		Sys.println([r.opt(), r.opt(1), r.opt(1, 3), r.opt(null, 2.5, 4.5), r.opt(0, 0, 0)].join(" | "));
		Sys.println([addOpt(1), addOpt(1, 2), addOpt(1, null), addOpt(1, 0)].join(" "));
		Sys.println([dflt(), dflt(1), dflt(1, 2), dflt(1, null, 3)].join(" | "));
		var f = addOpt, g:Dynamic = addOpt, h = dflt;
		Sys.println([f(10), f(10, 5), g(20), g(20, 1), Reflect.callMethod(null, g, [30]), Reflect.callMethod(null, g, [30, 3])].join(" "));
		Sys.println([h(), h(7, 1.25)].join(" | "));
		var ro:Dynamic = r;
		Sys.println([ro.opt(), ro.opt(9), Reflect.callMethod(r, Reflect.field(r, "opt"), [1, 2, 3])].join(" | "));

		// fields and statics, by reflection
		var rec = new Rec(3, 0.25);
		rec.b = true;
		Sys.println([show(rec.i), "" + rec.f, "" + Reflect.field(rec, "i"), "" + Reflect.field(rec, "f"), "" + Reflect.getProperty(rec, "b")].join(" "));
		Reflect.setField(rec, "i", 11);
		Reflect.setField(rec, "f", null);
		Sys.println([show(rec.i), "" + rec.f, "" + (rec.f == null), "" + Reflect.fields(rec).length].join(" "));
		Rec.sf = 1.75;
		Sys.println([show(Rec.si), "" + Rec.sf, "" + Reflect.field(Rec, "si"), "" + Reflect.field(Rec, "sf")].join(" "));
		Reflect.setField(Rec, "si", null);
		Reflect.setField(Rec, "sf", 8);
		Sys.println([show(Rec.si), "" + Rec.sf].join(" "));
		var rd:Dynamic = rec;
		rd.i = 42;
		rd.f = 0.5;
		Sys.println(rec.i + rec.f + " " + rd.i);

		// JSON and serialization
		var o = {i: (3 : Null<Int>), f: (null : Null<Float>), g: (1.5 : Null<Float>)};
		Sys.println(Json.stringify(o.f) + " " + Json.stringify(o.i) + " " + Json.stringify(o.g));
		var rj = new Rec(5, null);
		var j = Json.stringify(rj);
		var parsed:Dynamic = Json.parse('{"i": 6, "f": 2.25, "k": null}');
		var pi:Null<Int> = parsed.i, pf:Null<Float> = parsed.f, pk:Null<Int> = parsed.k;
		Sys.println(j.length + " " + (j.indexOf('"i":5') >= 0) + " " + show(pi) + " " + pf + " " + show(pk));
		var s = Serializer.run(rj);
		var u:Rec = Unserializer.run(s);
		Sys.println(show(u.i) + " " + u.f + " " + (u.f == null));
		var arr:Array<Null<Int>> = [1, null, 3];
		Sys.println(Serializer.run(arr) + " " + Json.stringify(arr));

		// structures, arrays, maps, closures, enums
		var st:{v:Null<Int>, w:Null<Float>} = {v: null, w: 2.0};
		st.v = 9;
		Sys.println(show(st.v) + " " + st.w + " " + Std.string(st));
		Sys.println(sum(arr) + " " + arr + " " + arr.indexOf(null) + " " + arr.indexOf(3));
		var mp = new Map<String, Null<Float>>();
		mp.set("a", 1.5);
		mp.set("b", null);
		Sys.println(mp.get("a") + " " + mp.get("b") + " " + mp.get("c") + " " + mp.exists("b"));
		var cl = (q:Null<Int>) -> q == null ? -1 : q * 2;
		var cd:Dynamic = cl;
		Sys.println([cl(null), cl(4), cd(5), cd(null)].join(" "));
		var en = [A(null), A(3), B(null, 1), B(2.5, 2)];
		Sys.println(en.map(v -> switch v {
			case A(null): "A-null";
			case A(k): "A" + k;
			case B(p, q): "B" + p + "," + q;
		}).join(" ") + " " + Type.enumParameters(en[1]) + " " + Type.enumEq(A(3), A(3)) + " " + Type.enumEq(A(null), A(0)));

		// Std.string, isOfType, interpolation
		Sys.println([Std.string(n), Std.string(a), Std.string(c), '$n/$a/$c/$m', "" + Std.isOfType(a, Int), "" + Std.isOfType(c, Float), "" + Std.isOfType(n, Int), "" + Std.isOfType(e, Int)].join(" "));

		// no allocation per store
		var cell = new Rec();
		var b0 = hxmc.GcStats.bytesAllocated();
		for (k in 0...100000) {
			cell.i = k * 3;
			cell.f = k * 0.5;
		}
		Sys.println("bytes per store: " + Std.int((hxmc.GcStats.bytesAllocated() - b0) / 200000) + " " + cell.i + " " + cell.f);
	}
}
