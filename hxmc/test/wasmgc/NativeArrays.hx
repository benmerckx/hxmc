// hxmc.NativeArray and haxe.ds.Vector (hxmc/test/cases/NativeArrays.hx and
// VectorAccess.hx without the collector's API and raw memory): every element
// kind's defaults, reads, writes and compound assignments, generic access,
// copy, blit (overlapping too), fill, Array conversions, iteration, Dynamic
// indexing and its errors, invalid lengths, many elements, Vector's API and
// aliasing of its storage.
import haxe.ds.Vector;
import haxe.Int64;
import hxmc.NativeArray;

class NativeItem {
	public var value:Int;

	public function new(value:Int)
		this.value = value;
}

class NativeArrays {
	static var calls = 0;

	static function index():Int
		return calls++;

	static function put<T>(a:NativeArray<T>, i:Int, v:T):T
		return a[i] = v;

	static function first<T>(a:NativeArray<T>):T
		return a[0];

	static function identity<T>(a:NativeArray<T>):NativeArray<T>
		return a;

	@:generic static function filled<T>(n:Int, value:T):NativeArray<T> {
		var a = new NativeArray<T>(n);
		a.fill(value);
		return a;
	}

	static function vput<T>(v:Vector<T>, i:Int, x:T):T
		return v[i] = x;

	static function vfirst<T>(v:Vector<T>):T
		return v[0];

	static function clone<T>(v:Vector<T>):Vector<T>
		return v.copy();

	static function sorted<T>(v:Vector<T>, cmp:T->T->Int):Void
		v.sort(cmp);

	// (generic code: copies and blits of storage of any kind)
	static function blitAll<T>(src:Vector<T>, dst:Vector<T>):Void
		Vector.blit(src, 0, dst, 0, src.length);

	@:generic static function vfilled<T>(n:Int, value:T):Vector<T>
		return new Vector<T>(n, value);

	static function addFirst(a:NativeArray<Int>):Void
		a[0] += a[1];

	static function main() {
		var a = new NativeArray<Int>(5);
		var f = new NativeArray<Float>(3);
		var b = new NativeArray<Bool>(3);
		var s = new NativeArray<String>(3);
		var nullable = new NativeArray<Null<Int>>(3);
		Sys.println('defaults ${a.toArray()} ${f.toArray()} ${b.toArray()} ${s.toArray()} ${nullable.toArray()} ${new NativeArray<Int>(0).length}');
		a[0] = -17;
		a[4] = 0x7FFFFFFF;
		var post = a[index()]++;
		var pre = ++a[index()];
		a[index()] += 9;
		Sys.println('int ${a.toArray()} post=$post pre=$pre calls=$calls');
		f[0] = 1.25;
		f[1] = -2.5;
		f[2] = 3;
		f[0] += 0.5;
		b[1] = true;
		put(b, 2, true);
		Sys.println('float ${f.toArray()} bool ${b.toArray()}');
		var longs = new NativeArray<Int64>(3);
		longs[0] = Int64.make(1, -1);
		longs[1] = Int64.make(-1, 1);
		longs[2] = longs[0] + longs[1];
		Sys.println('int64 ${longs[0]} ${longs[1]} ${longs[2]}');
		Sys.println('generic ${put(a, 3, 23)} ${first(a)} ${identity(f)[0]} ${put(longs, 2, Int64.make(2, 7))} ${first(b)} ${first(longs)}');
		nullable[0] = 10000;
		put(nullable, 1, 20000);
		Sys.println('nullable ${nullable.toArray()} filled=${filled(3, 6).toArray()} ${filled(2, 0.5).toArray()} ${filled(2, "x").toArray()}');
		var copy = a.copy();
		var from = NativeArray.fromArray([3, 4, 5]);
		NativeArray.blit(a, 0, a, 1, 4);
		NativeArray.blit(a, 1, a, 0, 4);
		Sys.println('copy ${copy.toArray()} blit=${a.toArray()} from=${from.toArray()}');
		var sum = 0;
		for (v in from)
			sum += v;
		Sys.println('iterator $sum');
		var dyn:Dynamic = f;
		dyn[1] = 8.5;
		Sys.println('dynamic ${dyn.length} ${dyn[0]} ${f[1]} type=${Std.isOfType(dyn, NativeArray)} ${Std.isOfType([1], NativeArray)} ${Std.isOfType(f, Array)} missing=${Reflect.field(dyn, "missing") == null}');
		Sys.println('reflection ${Std.string(dyn)} ${Type.typeof(dyn)} ${Type.getClass(dyn) == null} ${dyn == f} ${(f : Dynamic) == (a : Dynamic)}');
		try {
			dyn[0] = "wrong";
		} catch (_:Dynamic)
			Sys.println("kind kept");
		try {
			dyn[3] = 2;
		} catch (_:Dynamic)
			Sys.println("length kept");
		try {
			new NativeArray<Int>(-1);
		} catch (_:Dynamic)
			Sys.println("negative rejected");
		try {
			new NativeArray<Float>(0x7FFFFFFF);
		} catch (_:Dynamic)
			Sys.println("overflow rejected");
		var dynInts:Dynamic = a, dynBools:Dynamic = b, dynLongs:Dynamic = longs, dynStrings:Dynamic = s;
		dynInts[1] = 7;
		dynBools[0] = true;
		dynLongs[0] = Int64.make(0, 9);
		dynStrings[2] = "z";
		Sys.println('dynamic kinds ${dynInts[1]} ${a[1]} ${dynBools[0]} ${b[0]} ${dynLongs[0]} ${longs[0]} ${dynStrings[2]} ${s[2]} ${dynInts.length} ${dynStrings.length}');
		var objects = new NativeArray<NativeItem>(20000);
		var strings = new NativeArray<String>(20000);
		var values = new NativeArray<Dynamic>(20000);
		for (i in 0...1000) {
			objects[i * 19] = new NativeItem(i);
			strings[i * 19] = "item" + i;
			values[i * 19] = {value: i};
		}
		sum = 0;
		for (i in 0...1000)
			sum += objects[i * 19].value + strings[i * 19].length + (values[i * 19].value : Int);
		Sys.println('many $sum ${objects[19999] == null} ${strings[19999] == null} ${values[19999] == null}');
		var small = [];
		for (i in 0...1000)
			small.push(filled(5, new NativeItem(i)));
		sum = 0;
		for (v in small)
			sum += v[4].value;
		Sys.println('small $sum');
		addFirst(from);
		Sys.println('helpers ${from[0]} bool=${b[1] && b[2] && b[0]}');
		var nf = new NativeArray<Null<Float>>(2);
		var nb = new NativeArray<Null<Bool>>(2);
		nf[0] = 1.25;
		nb[0] = true;
		Sys.println('nullable types ${nf[0]} ${nf[1] == null} ${nb[0]} ${nb[1] == null}');
		var copied = objects.copy();
		var same = copied[0] == objects[0];
		copied[0] = new NativeItem(234);
		Sys.println('reference copy $same ${copied[0].value} ${objects[0].value} ${copied[19].value}');
		var packed = new NativeArray<Bool>(37);
		for (i in 0...packed.length)
			packed[i] = (i & 1) != 0;
		put(packed, 36, true);
		var count = 0;
		for (i in 0...packed.length)
			if (packed[i]) count++;
		var packedDynamic:Dynamic = packed;
		Sys.println('packed bool $count ${packedDynamic[0]} ${packedDynamic[1]}');

		// Vector
		var ints = new Vector<Int>(5);
		ints[0] = 10;
		calls = 0;
		var post = ints[index()]++;
		var pre = ++ints[index()];
		ints[index()] += 7;
		ints[index()] = vput(ints, 4, 19);
		Sys.println('vector int ${ints.join(",")} post=$post pre=$pre calls=$calls');
		var floats = new Vector<Float>(3, 1.5);
		floats[1] += 0.25;
		floats[2] *= 2;
		Sys.println('vector float ${floats.join(",")}');
		var bools = new Vector<Bool>(3);
		bools[1] = true;
		vput(bools, 2, true);
		Sys.println('vector bool ${bools.join(",")}');
		var vnullable = new Vector<Null<Int>>(3);
		vnullable[0] = 4;
		vput(vnullable, 1, 5);
		vnullable[0] = null;
		Sys.println('vector nullable ${vnullable.join(",")}');
		// toData/fromData share the NativeArray; Array conversions copy instead
		var alias:NativeArray<Int> = ints.toData();
		alias[0] = 31;
		ints[1] += 40;
		Sys.println('native ${ints.join(",")} alias=${alias[0]}');
		Vector.fromData(floats.toData())[0] = 2.5;
		floats[1] += 0.5;
		Sys.println('native float ${floats.join(",")}');
		var na = NativeArray.fromArray([2, 4, 6, 8]);
		var v = Vector.fromData(na);
		v[1] += 3;
		var vcopy = v.copy();
		Vector.blit(v, 0, v, 1, 3);
		Sys.println('shared ${na.toArray().join(",")} copy=${vcopy.join(",")}');
		Vector.blit(v, 1, v, 0, 3);
		Vector.blit(vcopy, 0, v, 0, 4);
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
		Sys.println('api ${v.join(",")} sorted=${fromArray.join(",")} alias=${sortAlias[0]} map=${mapped.join(",")} ${toArray.join(",")}');
		Sys.println('vector generic ${vfirst(copiedInts)} ${vfirst(copiedFloats)} ${copiedBools.join(",")} filled=${vfilled(3, 6).join(",")}');
		var gi = new Vector<Int>(5), gs = new Vector<String>(2), gb = new Vector<Bool>(3);
		blitAll(ints, gi);
		blitAll(Vector.fromArrayCopy(["p", "q"]), gs);
		blitAll(bools, gb);
		Sys.println('generic blit ${gi.join(",")} ${gs.join(",")} ${gb.join(",")}');
		var empty = new Vector<Int>(0);
		var nullData:NativeArray<Int> = null;
		Sys.println('empty ${empty.length} ${empty.copy().length} ${empty.map(x -> x + 1).length} join="${empty.join(",")}" null=${Vector.fromData(nullData) == null} native=${Std.isOfType(ints.toData(), NativeArray)}');
		var vobjects = new Vector<NativeItem>(20000);
		for (i in 0...vobjects.length)
			vobjects[i] = new NativeItem(i);
		var objectsCopy = clone(vobjects);
		vobjects[0] = new NativeItem(234);
		objectsCopy[19].value = 345;
		Sys.println('copy refs ${objectsCopy.toData() != vobjects.toData()} ${vobjects[0].value} ${objectsCopy[0].value} ${vobjects[19].value} ${objectsCopy[19999].value}');
	}
}
