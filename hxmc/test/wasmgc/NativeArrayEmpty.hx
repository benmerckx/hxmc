// (hxmc/test/cases/NativeArrayEmpty.hx without the collector's API, which WasmGC lacks)
// Arrays of no elements cannot change: every one made by typed code is the
// empty array of its element kind (static data, one per program), whichever
// way it is made (new, fromArrayCopy, copy, map, a generic function made
// @:generic); a copy of one is itself; views of another kind take an empty
// array. Heap objects and collections keep referring to them.
import haxe.ds.Vector;
import haxe.Int64;
import hxmc.NativeArray;

class Holder {
	public var ints:Vector<Int>;
	public var strings:Vector<String>;

	public function new() {
		ints = new Vector(0);
		strings = new Vector(0);
	}
}

class NativeArrayEmpty {
	@:generic static function made<T>(n:Int):Vector<T>
		return new Vector<T>(n);

	static function erased<T>(n:Int):Vector<T>
		return new Vector<T>(n);

	static function count(n:Int):Int
		return n;

	static function main() {
		var i1 = new Vector<Int>(0), i2 = new Vector<Int>(count(0));
		var f1 = new Vector<Float>(0), f2 = Vector.fromArrayCopy(([] : Array<Float>));
		var b1 = new Vector<Bool>(0), b2:Vector<Bool> = made(0);
		var l1 = new Vector<Int64>(0), l2 = new NativeArray<Int64>(0);
		var s1 = new Vector<String>(0), s2 = s1.map(s -> s + "!");
		var d1 = new Vector<Dynamic>(0), d2 = new Vector<Null<Int>>(0);
		Sys.println('same ${i1 == i2} ${f1 == f2} ${b1 == b2} ${l1.toData() == l2} ${s1 == s2} ${s1.toData() == (cast d1.toData())} ${(cast d1.toData()) == d2.toData()}');
		Sys.println('kinds ${(cast i1.toData()) == f1.toData()} ${(cast i1.toData()) == b1.toData()} ${(cast i1.toData()) == s1.toData()}');
		Sys.println('copies ${i1.copy() == i1} ${s1.copy() == s1} ${i1.map(x -> x * 2.0) == f1}');
		Sys.println('empty ${i1.length} ${f1.join(",")} ${s1.toArray().length} ${[for (x in b1) x].length}');
		Vector.blit(i1, 0, i2, 0, 0);
		i1.fill(3);
		Sys.println('unchanged ${i1.length} ${i2.length}');

		// views of another kind: an empty array
		var asDynamic:Vector<Dynamic> = i1;
		var nullable:Vector<Null<Int>> = i1;
		var back:Vector<Int> = (asDynamic : Dynamic);
		Sys.println('views ${asDynamic.length} ${nullable.length} ${back == i1}');
		var e:Vector<Float> = erased(0);
		var e2:Vector<String> = erased(0);
		Sys.println('erased ${e.length} ${e2.length}');

		// referred to from the heap, across collections
		var holders = [for (i in 0...2000) new Holder()];
		for (i in 0...2000) if (i % 2 == 0) holders[i].ints = Vector.fromArrayCopy([i]);
		var sum = 0, empties = 0;
		for (h in holders) {
			if (h.ints.length == 0) {
				empties++;
				if (h.ints != i1 || h.strings != s1) Sys.println("not shared");
			} else sum += h.ints[0];
		}
		Sys.println('gc $empties $sum');
	}
}
