// Array's searches (indexOf, lastIndexOf, contains, remove) over reference
// arrays: by identity when the needle's == is identity (objects, enums,
// null), by value for boxes, Strings of either width, type objects and
// closures.
class P {
	public var v:Int;

	public function new(v:Int)
		this.v = v;

	public function get():Int
		return v;
}

enum E {
	A;
	B(i:Int);
}

class ArraySearch {
	static function main() {
		var ps = [for (i in 0...5) new P(i)];
		var other = new P(2);
		Sys.println(ps.indexOf(ps[3]) + " " + ps.indexOf(other) + " " + ps.lastIndexOf(ps[1]) + " " + ps.contains(ps[4]) + " " + ps.contains(other));
		Sys.println(ps.indexOf(ps[3], 4) + " " + ps.lastIndexOf(ps[3], 2) + " " + ps.indexOf(ps[0], -5) + " " + ps.lastIndexOf(ps[4], -1));
		var withNull:Array<P> = [ps[0], null, ps[1], null];
		Sys.println(withNull.indexOf(null) + " " + withNull.lastIndexOf(null) + " " + withNull.remove(null) + " " + withNull.length);
		Sys.println(ps.remove(ps[2]) + " " + ps.remove(other) + " " + ps.length + " " + ps.map(p -> p.v));
		// Strings: one-byte and two-byte, made at run time (not the literal's object)
		var ss = ["alpha", "béta", "γamma", "alpha"];
		var a = "al" + Std.string(ps.length == 4 ? "pha" : "");
		var g = "γ" + "amma".substr(0);
		Sys.println(ss.indexOf(a) + " " + ss.lastIndexOf(a) + " " + ss.indexOf(g) + " " + ss.contains("bé" + "ta") + " " + ss.indexOf("delta"));
		var ds:Array<Dynamic> = ["x", 1, 2.5, true, ps[0], E.A, P];
		Sys.println(ds.indexOf("x".substr(0)) + " " + ds.indexOf(1.0) + " " + ds.indexOf(2.5) + " " + ds.indexOf(true) + " " + ds.indexOf(ps[0]) + " " + ds.indexOf(E.A) + " " + ds.indexOf(P));
		Sys.println(ds.lastIndexOf(1) + " " + ds.lastIndexOf(ps[0]) + " " + ds.contains(other) + " " + ds.remove(E.A) + " " + ds.length);
		// enums: constructors without arguments are one value; with arguments, each its own
		var es = [A, B(1), B(2)];
		Sys.println(es.indexOf(A) + " " + es.indexOf(es[2]) + " " + es.indexOf(B(1)));
		// closures: two of one method of one object are equal
		var p = ps[1];
		var fs:Array<Void->Int> = [ps[0].get, p.get];
		Sys.println(fs.indexOf(p.get) + " " + fs.lastIndexOf(p.get) + " " + fs.contains(ps[3].get));
	}
}
