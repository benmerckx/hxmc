// define: hxmc.native-array-outofbounds=throws
// (hxmc/test/cases/NativeArrayBoundsThrows.hx without the collector's API, which WasmGC lacks)
// With -D hxmc.native-array-outofbounds=throws, every access of a Vector
// (NativeArray) out of bounds throws haxe.exceptions.ArgumentException, with
// the position of the access: reads, writes and compound assignments of every
// storage kind, negative and too large indices, Vector<Dynamic> views, vectors
// made in generic code, Dynamic indexing, the empty arrays (static data), blit
// out of bounds. The references a handler reads survive the exception's
// allocation; accesses in bounds are unchanged. (A read whose value is not
// used is no access: Haxe drops it, hence sink.)
import haxe.ds.Vector;
import haxe.Int64;
import haxe.exceptions.ArgumentException;

class BoundsItem {
	public var value:Int;

	public function new(value:Int)
		this.value = value;
}

class BoundsRing<T> {
	public final data:Vector<T>;

	public function new(n:Int)
		data = new Vector(n);

	public function get(i:Int):T
		return data[i];

	public function set(i:Int, x:T):Void
		data[i] = x;
}

class NativeArrayBoundsThrows {
	static var sink:Dynamic;
	static var indices = 0;
	static var rhsCalls = 0;

	static function index(i:Int):Int {
		indices++;
		return i;
	}

	static function rhs():Float {
		rhsCalls++;
		return 2;
	}

	static function rejects(f:Void->Void):Bool {
		try f() catch (e:ArgumentException) {
			if (e.argument != "index") throw e;
			return true;
		}
		return false;
	}

	static function probe<T>(name:String, v:Vector<T>, value:T):Void {
		v[0] = value;
		var all = true;
		for (i in [-1, v.length, 0x7FFFFFFF, 0x80000000]) {
			if (!rejects(() -> sink = v[i])) all = false;
			if (!rejects(() -> v[i] = value)) all = false;
		}
		Sys.println('$name ${v.length} ${v[0] == value} rejected=$all');
	}

	static function main() {
		probe("int", new Vector<Int>(2), 17);
		probe("float", new Vector<Float>(2), 1.25);
		probe("bool", new Vector<Bool>(2), true);
		probe("int64", new Vector<Int64>(2), Int64.make(2, 17));
		probe("string", new Vector<String>(2), "hello");
		probe("object", new Vector<BoundsItem>(2), new BoundsItem(23));
		probe("nullable", new Vector<Null<Int>>(2), 10000);
		probe("dynamic", new Vector<Dynamic>(2), {value: 31});

		// the error: its message and the position of the access
		var v = Vector.fromArrayCopy([1, 2, 3]);
		try {
			v[5] = 1;
		} catch (e:ArgumentException) {
			Sys.println('error "${e.message}" ${e.argument} in ${e.posInfos.className}.${e.posInfos.methodName} at ${haxe.io.Path.withoutDirectory(e.posInfos.fileName)}:${e.posInfos.lineNumber}');
		}

		// compound assignments: the index once, the read before the right side
		var f = new Vector<Float>(2, 1.5);
		Sys.println('compound ${rejects(() -> f[index(2)] *= rhs())} indices=$indices rhs=$rhsCalls');
		f[index(0)] *= rhs();
		var post = v[index(0)]++;
		var pre = ++v[index(1)];
		Sys.println('in bounds ${f[0]} ${v.join(",")} post=$post pre=$pre indices=$indices rhs=$rhsCalls');
		Sys.println('increments ${rejects(() -> v[3]++)} ${rejects(() -> --v[-1])} ${v.join(",")}');

		// other views and storage
		var d:Vector<Dynamic> = v;
		Sys.println('dynamic view ${rejects(() -> sink = d[3])} ${rejects(() -> d[3] = 1)} ${d[2]}');
		var ring = new BoundsRing<Int>(2);
		ring.set(1, 4);
		Sys.println('generic ${rejects(() -> ring.get(2))} ${rejects(() -> ring.set(-1, 1))} ${ring.get(1)}');
		var dyn:Dynamic = v;
		Sys.println('dynamic index ${rejects(() -> sink = dyn[3])} ${rejects(() -> dyn[3] = 0)} ${dyn[1]}');
		var empty = new Vector<Int>(0);
		Sys.println('empty ${rejects(() -> sink = empty[0])} ${rejects(() -> empty[0] = 1)} ${new Vector<Int>(0).length}');

		// blit: in bounds as before; out of bounds, the first access out of
		// bounds throws (the elements before it are copied)
		var a = Vector.fromArrayCopy([1, 2, 3, 4]);
		var b = new Vector<Int>(3);
		Vector.blit(a, 1, b, 0, 3);
		Sys.println('blit ${b.join(",")} ${rejects(() -> Vector.blit(a, 2, b, 0, 3))} ${b.join(",")} ${rejects(() -> Vector.blit(a, -1, b, 0, 1))}');
		Vector.blit(a, 0, a, 1, 3);
		Sys.println('overlap ${a.join(",")}');

		// a handler's references, across the exception's allocation
		var keep = new BoundsItem(42);
		var items = [for (i in 0...100) new BoundsItem(i)];
		var caught = 0;
		for (i in 0...2000) {
			try {
				sink = v[i % 7];
			} catch (e:ArgumentException) {
				caught += keep.value + items[i % 100].value - i % 100;
			}
		}
		Sys.println('handlers $caught');
	}
}
