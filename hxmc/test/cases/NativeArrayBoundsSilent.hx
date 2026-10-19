// define: hxmc.native-array-outofbounds=silent
// With -D hxmc.native-array-outofbounds=silent, a read of a Vector
// (NativeArray) out of bounds gives the element type's default (0, false,
// null) and a write does nothing: every storage kind, negative and too large
// indices, compound assignments (the right side evaluated still),
// Vector<Dynamic> views, vectors made in generic code, Dynamic indexing, the
// empty arrays (static data, unchanged), blit out of bounds (element by
// element: the elements in bounds copied). Accesses in bounds are unchanged.
import haxe.ds.Vector;
import haxe.Int64;

class SilentItem {
	public var value:Int;

	public function new(value:Int)
		this.value = value;
}

class SilentRing<T> {
	public final data:Vector<T>;

	public function new(n:Int)
		data = new Vector(n);

	public function get(i:Int):T
		return data[i];

	public function set(i:Int, x:T):Void
		data[i] = x;
}

class NativeArrayBoundsSilent {
	static var rhsCalls = 0;

	static function rhs():Int {
		rhsCalls++;
		return 5;
	}

	static function probe<T>(name:String, v:Vector<T>, value:T):Void {
		v[0] = value;
		var reads = [];
		for (i in [-1, v.length, 0x7FFFFFFF, 0x80000000]) {
			reads.push(Std.string(v[i]));
			v[i] = value;
		}
		Sys.println('$name ${reads.join(",")} ${v.length} ${v[0] == value} ${v[1] == value}');
	}

	static function main() {
		probe("int", new Vector<Int>(2), 17);
		probe("float", new Vector<Float>(2), 1.25);
		probe("bool", new Vector<Bool>(2), true);
		probe("int64", new Vector<Int64>(2), Int64.make(2, 17));
		probe("string", new Vector<String>(2), "hello");
		probe("object", new Vector<SilentItem>(2), new SilentItem(23));
		probe("nullable", new Vector<Null<Int>>(2), 10000);
		probe("dynamic", new Vector<Dynamic>(2), {value: 31});

		var v = Vector.fromArrayCopy([1, 2, 3]);
		var sum = v[3] + v[-1] + v[2];
		var compound = v[7] += rhs();
		var post = v[3]++;
		var pre = ++v[3];
		Sys.println('compound $sum $compound post=$post pre=$pre rhs=$rhsCalls ${v.join(",")}');

		var d:Vector<Dynamic> = v;
		d[3] = 9;
		Sys.println('dynamic view ${d[3]} ${d[2]} ${v.join(",")}');
		var ring = new SilentRing<Int>(2);
		ring.set(2, 4);
		ring.set(1, 6);
		var typed:Vector<Int> = ring.data;
		Sys.println('generic ${ring.get(2)} ${ring.get(1)} ${typed.join(",")} ${typed[5]}');
		var dyn:Dynamic = v;
		dyn[5] = 1;
		Sys.println('dynamic index ${dyn[5]} ${dyn.length}');
		var empty = new Vector<Int>(0);
		empty[0] = 12;
		Sys.println('empty ${empty[0]} ${empty.length} ${new Vector<Int>(0)[0]}');

		// blit: element by element when out of bounds
		var a = Vector.fromArrayCopy([1, 2, 3]);
		var b = new Vector<Int>(5);
		Vector.blit(a, 1, b, 3, 4);
		Vector.blit(a, -2, b, 0, 3);
		Sys.println('blit ${b.join(",")}');
	}
}
