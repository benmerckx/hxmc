// Native Vector initialization, plus `untyped a.length = n` on an Array
// lowered to Array.resize, and resize's growth past the capacity (the data
// allocated once at the new length): the new elements zero or null, the old
// ones kept, the element kind kept, the value of the assignment, shrinking,
// growth within the capacity, vectors large enough for the old space, and
// the contents across collections.
import haxe.ds.Vector;

class VectorLength {
	static function setLength<T>(a:Array<T>, n:Int):Int
		return untyped a.length = n;

	static function sum(a:Array<Int>):Int {
		var s = 0;
		for (x in a)
			s += x;
		return s;
	}

	static function main() {
		var vi = new Vector<Int>(5);
		var vf = new Vector<Float>(3);
		var vs = new Vector<String>(4);
		var vd = new Vector<Dynamic>(2);
		Sys.println([vi.length, vf.length, vs.length, vd.length].join(","));
		Sys.println(vi.toArray().join(",") + " " + vf.toArray().join(",") + " " + vs.toArray().join(",") + " " + vd.toArray().join(","));
		vi[4] = 7;
		vs[0] = "a";
		Sys.println(vi.toArray().join(",") + " " + vs.toArray().join(","));

		// growth from a non-empty array keeps the elements
		var a = [1, 2, 3];
		Sys.println(setLength(a, 6) + " " + a.join(",") + " " + a.length);
		a.push(9);
		Sys.println(a.join(","));
		// shrinking, then growth within the capacity
		Sys.println(setLength(a, 2) + " " + a.join(","));
		Sys.println(setLength(a, 4) + " " + a.join(","));
		Sys.println(setLength(a, 4) + " " + a.join(","));

		var f = [1.5, 2.5];
		setLength(f, 4);
		Sys.println(f.join(","));
		var s = ["x"];
		setLength(s, 3);
		Sys.println(s.join(",") + " " + (s[2] == null));
		var e:Array<String> = [];
		setLength(e, 2);
		e[1] = "y";
		Sys.println(e.join(","));

		// large vectors, and their contents across collections
		var big = new Vector<String>(200000);
		big[0] = "first";
		big[199999] = "last";
		var keep = [];
		for (i in 0...100) {
			var v = new Vector<Int>(1000 + i);
			v[i] = i;
			var w = new Vector<String>(8);
			w[3] = "s" + i;
			keep.push({v: v, w: w});
			for (j in 0...200)
				[j, j + 1];
		}
		var t = 0;
		for (k in keep)
			t += sum(k.v.toArray()) + k.w[3].length + k.v.length;
		Sys.println(big[0] + " " + big[1] + " " + big[199999] + " " + big.length + " " + t);
	}
}
