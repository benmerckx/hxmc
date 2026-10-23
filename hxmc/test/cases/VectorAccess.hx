import haxe.ds.Vector;
import hxmc.NativeGc;
import hxmc.NativeArray;
import hxmc.unsafe.Mem;

class VectorItem {
	public var value:Int;
	public function new(value:Int) this.value = value;
}

// Native-backed Vector: specialization, aliasing, the public API, erased
// generic access/copying, and old-to-young reference barriers.
@:build(macros.VectorBacking.build())
class VectorAccess {
	static var calls = 0;
	static function index():Int return calls++;
	static function put<T>(v:Vector<T>, i:Int, x:T):T return v[i] = x;
	static function first<T>(v:Vector<T>):T return v[0];
	static function clone<T>(v:Vector<T>):Vector<T> return v.copy();
	static function sorted<T>(v:Vector<T>, cmp:T->T->Int):Void v.sort(cmp);
	@:generic static function filled<T>(n:Int, value:T):Vector<T> return new Vector<T>(n, value);
	@:hxmc.noGc static function slots<T>(v:Vector<T>):Int return hxmc.rt.Types.nslots(v.toData());

	static function main() {
		var ints = new Vector<Int>(5);
		ints[0] = 10;
		var post = ints[index()]++;
		var pre = ++ints[index()];
		ints[index()] += 7;
		ints[index()] = put(ints, 4, 19);
		Sys.println('int ${ints.join(",")} post=$post pre=$pre calls=$calls');

		var floats = new Vector<Float>(3, 1.5);
		floats[1] += 0.25;
		floats[2] *= 2;
		Sys.println('float ${floats.join(",")}');
		var bools = new Vector<Bool>(3);
		bools[1] = true;
		put(bools, 2, true);
		Sys.println('bool ${bools.join(",")}');
		var nullable = new Vector<Null<Int>>(3);
		nullable[0] = 4;
		put(nullable, 1, 5);
		nullable[0] = null;
		Sys.println('nullable ${nullable.join(",")}');

		// toData/fromData share the NativeArray; Array conversions copy instead.
		var alias:NativeArray<Int> = ints.toData();
		alias[0] = 31;
		ints[1] += 40;
		Sys.println('native ${ints.join(",")} alias=${alias[0]}');
		Vector.fromData(floats.toData())[0] = 2.5;
		floats[1] += 0.5;
		Sys.println('native float ${floats.join(",")}');

		// fromData shares; the copy and blit paths must keep their usual meaning.
		var a = NativeArray.fromArray([2, 4, 6, 8]);
		var v = Vector.fromData(a);
		v[1] += 3;
		var copy = v.copy();
		Vector.blit(v, 0, v, 1, 3);
		Sys.println('shared ${a.toArray().join(",")} copy=${copy.join(",")}');
		Vector.blit(v, 1, v, 0, 3);
		Vector.blit(copy, 0, v, 0, 4);
		Vector.blit(v, 0, v, 0, v.length);
		var array = [8, 3, 1, 5];
		var fromArray = Vector.fromArrayCopy(array);
		array[0] = 99;
		var toArray = fromArray.toArray();
		toArray[1] = 99;
		var sortAlias = fromArray.toData();
		sorted(fromArray, (a, b) -> a - b);
		var mapped = fromArray.map(x -> x * 0.5);
		var copiedInts = clone(ints), copiedFloats = clone(floats), copiedBools = clone(bools);
		Sys.println('api ${v.join(",")} sorted=${fromArray.join(",")} alias=${sortAlias[0]} map=${mapped.join(",")}');
		Sys.println('generic ${first(copiedInts)} ${first(copiedFloats)} ${copiedBools.join(",")} filled=${filled(3, 6).join(",")}');
		var empty = new Vector<Int>(0);
		var nullData:NativeArray<Int> = null;
		Sys.println('layout ${slots(ints)} ${slots(floats)} ${slots(bools)} ${slots(nullable)} native=${Std.isOfType(ints.toData(), NativeArray)}');
		Sys.println('empty ${empty.length} ${empty.copy().length} ${empty.map(x -> x + 1).length} join="${empty.join(",")}" null=${Vector.fromData(nullData) == null}');

		var objects = new Vector<VectorItem>(20000);
		var strings = new Vector<String>(20000);
		var dynValues = new Vector<Dynamic>(20000);
		NativeGc.collect(true);
		for (i in 0...1000) {
			objects[i * 19] = new VectorItem(i);
			strings[i * 19] = "item" + i;
			dynValues[i * 19] = {value: i};
			if (i % 13 == 0) NativeGc.collect(false);
		}
		NativeGc.collect(true);
		var sum = 0;
		for (i in 0...1000)
			sum += objects[i * 19].value + strings[i * 19].length + (dynValues[i * 19].value : Int);
		Sys.println('gc $sum ${objects[19999] == null} ${strings[19999] == null} ${dynValues[19999] == null}');
		var objectsCopy = clone(objects);
		objects[0] = new VectorItem(234);
		objectsCopy[19].value = 345;
		NativeGc.collect(true);
		Sys.println('copy refs ${objectsCopy.toData() != objects.toData()} ${objects[0].value} ${objectsCopy[0].value} ${objects[19].value}');
		var big = new Vector<VectorItem>(20000);
		for (i in 0...big.length) big[i] = new VectorItem(i);
		var bigCopy = clone(big);
		NativeGc.collect(false);
		NativeGc.collect(true);
		Sys.println('large copy ${bigCopy[0].value} ${bigCopy[19999].value}');
	}
}
