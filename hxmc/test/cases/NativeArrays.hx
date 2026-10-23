import hxmc.NativeArray;
import hxmc.NativeGc;
import hxmc.unsafe.Mem;
import haxe.Int64;

class NativeItem {
	public var value:Int;
	public function new(value:Int) this.value = value;
}

class NativeArrays {
	static var calls = 0;
	static function index():Int return calls++;
	static function put<T>(a:NativeArray<T>, i:Int, v:T):T return a[i] = v;
	static function first<T>(a:NativeArray<T>):T return a[0];
	static function identity<T>(a:NativeArray<T>):NativeArray<T> return a;
	@:generic static function filled<T>(n:Int, value:T):NativeArray<T> {
		var a = new NativeArray<T>(n);
		a.fill(value);
		return a;
	}
	@:hxmc.noGc static function words<T>(a:NativeArray<T>):Int return hxmc.rt.Types.nslots(a);
	@:hxmc.noGc static function addFirst(a:NativeArray<Int>):Void a[0] += a[1];
	@:hxmc.noGc static function setItem(a:NativeArray<NativeItem>, i:Int, v:NativeItem):Void a[i] = v;
	static function main() {
		var a = new NativeArray<Int>(5);
		var f = new NativeArray<Float>(3);
		var b = new NativeArray<Bool>(3);
		var s = new NativeArray<String>(3);
		var nullable = new NativeArray<Null<Int>>(3);
		Sys.println('defaults ${a.toArray()} ${f.toArray()} ${b.toArray()} ${s.toArray()} ${nullable.toArray()}');
		Sys.println('layout ${words(a)} ${words(f)} ${words(b)} ${words(s)} ${new NativeArray<Int>(0).length}');
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
		Sys.println('generic ${put(a, 3, 23)} ${first(a)} ${identity(f)[0]} ${put(longs, 2, Int64.make(2, 7))}');
		nullable[0] = 10000;
		put(nullable, 1, 20000);
		Sys.println('nullable ${nullable.toArray()} filled=${filled(3, 6).toArray()}');
		var copy = a.copy();
		var from = NativeArray.fromArray([3, 4, 5]);
		NativeArray.blit(a, 0, a, 1, 4);
		NativeArray.blit(a, 1, a, 0, 4);
		Sys.println('copy ${copy.toArray()} blit=${a.toArray()} from=${from.toArray()}');
		var sum = 0;
		for (v in from) sum += v;
		Sys.println('iterator $sum');
		var dyn:Dynamic = f;
		dyn[1] = 8.5;
		Sys.println('dynamic ${dyn.length} ${dyn[0]} ${f[1]} type=${Std.isOfType(dyn, NativeArray)} missing=${Reflect.field(dyn, "missing") == null}');
		try { dyn[0] = "wrong"; } catch (_:Dynamic) Sys.println("kind kept");
		try { dyn[3] = 2; } catch (_:Dynamic) Sys.println("length kept");
		try { new NativeArray<Int>(-1); } catch (_:Dynamic) Sys.println("negative rejected");
		try { new NativeArray<Float>(0x7FFFFFFF); } catch (_:Dynamic) Sys.println("overflow rejected");
		var objects = new NativeArray<NativeItem>(20000);
		var strings = new NativeArray<String>(20000);
		var values = new NativeArray<Dynamic>(20000);
		NativeGc.collect(true);
		for (i in 0...1000) {
			objects[i * 19] = new NativeItem(i);
			strings[i * 19] = "item" + i;
			values[i * 19] = {value: i};
			if (i % 13 == 0) NativeGc.collect(false);
		}
		NativeGc.collect(true);
		sum = 0;
		for (i in 0...1000) sum += objects[i * 19].value + strings[i * 19].length + (values[i * 19].value : Int);
		Sys.println('gc $sum ${objects[19999] == null} ${strings[19999] == null} ${values[19999] == null}');
		var small = [];
		for (i in 0...1000) small.push(filled(5, new NativeItem(i)));
		NativeGc.collect(true);
		sum = 0;
		for (v in small) sum += v[4].value;
		Sys.println('small gc $sum');
		addFirst(from);
		setItem(objects, 19999, new NativeItem(10000));
		NativeGc.collect(false);
		Sys.println('no gc helpers ${from[0]} ${objects[19999].value} bool=${b[1] && b[2] && !b[0]}');
		var nf = new NativeArray<Null<Float>>(2);
		var nb = new NativeArray<Null<Bool>>(2);
		nf[0] = 1.25;
		nb[0] = true;
		Sys.println('nullable types ${nf[0]} ${nf[1] == null} ${nb[0]} ${nb[1] == null}');
		var copied = objects.copy();
		var same = copied[0] == objects[0];
		copied[0] = new NativeItem(234);
		NativeGc.collect(true);
		Sys.println('reference copy $same ${copied[0].value} ${objects[0].value} ${copied[19999].value}');
		var packed = new NativeArray<Bool>(37);
		for (i in 0...packed.length) packed[i] = (i & 1) != 0;
		put(packed, 36, true);
		var count = 0;
		for (i in 0...packed.length) if (packed[i]) count++;
		var packedDynamic:Dynamic = packed;
		Sys.println('packed bool ${words(packed)} $count ${packedDynamic[0]} ${packedDynamic[1]}');
	}
}
