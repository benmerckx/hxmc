// hxmc.NativeArray.literal (the port's `vector(a, b, c)`): the elements in
// order, of every storage kind, boxed where the element type asks, the
// shared empty array, the wrapper of an erased type parameter. The elements
// are stored after the allocation (MirBuild, hxmc_narray_lit), so they are
// roots across it (GcPoints: 2): literals of young objects in a loop, which
// the small nurseries of the corpus collect between the allocation and the
// stores.
import hxmc.NativeArray;
import haxe.ds.Vector;

class Obj {
	public var n:Int;

	public function new(n)
		this.n = n;
}

class NativeArrayLiteral {
	static var count = 0;

	static function next(x:Int):Int {
		count++;
		return x * 10 + count;
	}

	static function gen<T>(a:T, b:T):Vector<T>
		return Vector.fromData(NativeArray.literal(([a, b] : Array<T>)));

	static function show<T>(v:Vector<T>):String
		return '${v.length}:[' + [for (i in 0...v.length) Std.string(v[i])].join(",") + "]";

	static function main() {
		var ints = Vector.fromData(NativeArray.literal(([next(1), next(2), next(3)] : Array<Int>)));
		Sys.println("ints " + show(ints) + " count=" + count);
		Sys.println("floats " + show(Vector.fromData(NativeArray.literal(([1.5, -2.25, 1e300] : Array<Float>)))));
		Sys.println("bools " + show(Vector.fromData(NativeArray.literal(([true, false, true, true, false, true, false, false, true] : Array<Bool>)))));
		Sys.println("longs " + show(Vector.fromData(NativeArray.literal(([haxe.Int64.make(1, 2), haxe.Int64.ofInt(-7)] : Array<haxe.Int64>)))));
		var objs = Vector.fromData(NativeArray.literal(([new Obj(1), null, new Obj(3)] : Array<Obj>)));
		Sys.println("objs " + objs.length + " " + objs[0].n + " " + (objs[1] == null) + " " + objs[2].n);
		Sys.println("strings " + show(Vector.fromData(NativeArray.literal((["a", "bb" + count, "ccc"] : Array<String>)))));
		Sys.println("nullable " + show(Vector.fromData(NativeArray.literal(([1, null, 3] : Array<Null<Int>>)))));
		Sys.println("dynamic " + show(Vector.fromData(NativeArray.literal(([1, "x", 2.5, null] : Array<Dynamic>)))));
		var empty1 = Vector.fromData(NativeArray.literal(([] : Array<Int>)));
		var empty2 = Vector.fromData(NativeArray.literal(([] : Array<Int>)));
		var emptyS = Vector.fromData(NativeArray.literal(([] : Array<String>)));
		Sys.println("empty " + empty1.length + " " + emptyS.length + " shared=" + (empty1 == empty2));
		var g = gen(new Obj(5), new Obj(6));
		Sys.println("generic " + g.length + " " + g[0].n + " " + g[1].n);
		Sys.println("generic ints " + show(gen(7, 8)));
		// (each checked as made, and some kept to the end)
		var kept:Array<Vector<Obj>> = [], boxed:Array<Vector<Dynamic>> = [];
		var sum = 0, bad = 0;
		inline function check(v:Vector<Obj>, d:Vector<Dynamic>, i:Int):Void {
			if (v[0].n != i || v[1].n != i + 1 || v[2].n != i + 2) bad++;
			var o:Obj = d[0], f:Float = d[1], s:String = d[2];
			if (o.n != i || f != i * 0.5 || s != "s" + i) bad++;
		}
		for (i in 0...100000) {
			var v = Vector.fromData(NativeArray.literal(([new Obj(i), new Obj(i + 1), new Obj(i + 2)] : Array<Obj>)));
			var d = Vector.fromData(NativeArray.literal(([new Obj(i), i * 0.5, "s" + i] : Array<Dynamic>)));
			check(v, d, i);
			if (i % 997 == 0) {
				kept.push(v);
				boxed.push(d);
			}
		}
		for (k in 0...kept.length) {
			var v = kept[k], d = boxed[k], i = k * 997;
			check(v, d, i);
			var s:String = d[2];
			sum += v[0].n + v[1].n + v[2].n + s.length;
		}
		Sys.println("young elements " + kept.length + " sum=" + sum + " bad=" + bad);
	}
}
