// Vectors (NativeArrays) seen with another element type than they were made
// with, as Haxe allows without a cast: as Vector<Dynamic> or Vector<Any> (any
// storage kind, through the runtime: these read Int storage as references, or
// stopped the compiler), from a Dynamic or from generic code into a typed view
// (checked once there), Vector<Int> and Vector<Null<Int>> (different
// storage: an error, as on HL and the JVM). And vectors made in generic code,
// whose element type is erased (rejected, before): a wrapper of reference
// storage, which the first typed view converts to its kind, the generic code
// and the typed code sharing it from then on.
import haxe.ds.Vector;
import haxe.Int64;
import hxmc.NativeGc;

class ViewItem {
	public var value:Int;

	public function new(value:Int)
		this.value = value;
}

enum ViewTag {
	Small;
	Large(n:Int);
}

abstract Loose(Dynamic) from Dynamic to Dynamic {}

class Ring<T> {
	public final data:Vector<T>;

	var next = 0;

	public function new(n:Int)
		data = new Vector(n);

	public function add(x:T):Void {
		data[next] = x;
		next = (next + 1) % data.length;
	}

	public function get(i:Int):T
		return data[i];

	public function copy():Vector<T>
		return data.copy();
}

class NativeArrayViews {
	static function make<T>(n:Int):Vector<T>
		return new Vector<T>(n);

	static function filled<T>(n:Int, x:T):Vector<T> {
		var v = new Vector<T>(n);
		for (i in 0...n) v[i] = x;
		return v;
	}

	// (the copy as it is: still open)
	static function copyOf<T>(r:Ring<T>):Dynamic
		return r.copy();

	// (typed parameters: the conversion stays where the analyzer would fold a local)
	static function intAt(v:Vector<Int>, i:Int):Int
		return v[i];

	static function floatAt(v:Vector<Float>, i:Int):Float
		return v[i];

	static function nullableAt(v:Vector<Null<Int>>, i:Int):Null<Int>
		return v[i];

	static function sum(v:Vector<Dynamic>):Float {
		var s = 0.0;
		for (i in 0...v.length) s += v[i];
		return s;
	}

	static function attempt(what:String, f:Void->Dynamic):Void {
		var r = try Std.string(f()) catch (e:Dynamic) "error: " + e;
		Sys.println('$what: $r');
	}

	static function main() {
		// typed storage seen as Dynamic: every kind, read, written, compound
		var ints = Vector.fromArrayCopy([1, 2, 3]);
		var floats = Vector.fromArrayCopy([0.5, 1.5]);
		var bools = Vector.fromArrayCopy([true, false]);
		var longs = Vector.fromArrayCopy([Int64.make(1, 2), Int64.make(-1, -2)]);
		var strings = Vector.fromArrayCopy(["a", "b"]);
		var d:Vector<Dynamic> = ints;
		d[0] = 10;
		d[1] += 5;
		Sys.println('dynamic ints ${d[0]} ${d[1]} ${d[2]} ${ints.join(",")} sum=${sum(ints)}');
		var d:Vector<Dynamic> = floats;
		d[1] *= 2;
		Sys.println('dynamic floats ${d[0]} ${d[1]} ${floats.join(",")} sum=${sum(floats)}');
		var any:Vector<Any> = bools;
		any[1] = true;
		Sys.println('any bools ${any[0]} ${any[1]} ${bools.join(",")}');
		var loose:Vector<Loose> = cast longs;
		Sys.println('loose int64 ${loose[0]} ${loose[1]}');
		var d:Vector<Dynamic> = strings;
		d[1] = "c";
		Sys.println('dynamic strings ${d[0]} ${d[1]} ${strings.join(",")}');
		var d:Vector<Dynamic> = ints;
		attempt("string into ints", () -> d[0] = "x");
		var mixed = new Vector<Dynamic>(3);
		mixed[0] = 1;
		mixed[1] = "two";
		mixed[2] = {three: 3};
		Sys.println('mixed ${mixed[0]} ${mixed[1]} ${mixed[2].three} ${mixed.length}');

		// into a typed view: checked
		var dyn:Dynamic = ints;
		attempt("Dynamic as ints", () -> intAt(dyn, 2));
		attempt("Dynamic as floats", () -> floatAt(dyn, 0));
		var notVector:Dynamic = [1, 2];
		attempt("an Array as ints", () -> intAt(notVector, 0));
		attempt("ints as Null<Int>", () -> nullableAt(ints, 0));
		var nullable = new Vector<Null<Int>>(2);
		nullable[0] = 4;
		attempt("Null<Int> as ints", () -> intAt(nullable, 0));
		var none:Dynamic = null;
		var nv:Vector<Int> = none;
		Sys.println('null view ${nv == null}');

		// made in generic code
		var ir = new Ring<Int>(3);
		ir.add(1);
		ir.add(2);
		var typed:Vector<Int> = ir.data;
		typed[2] = 30;
		ir.add(3);
		ir.add(4);
		Sys.println('ring ints ${typed.join(",")} ${ir.get(0)} ${ir.get(2)} again=${(ir.data : Vector<Int>) == typed}');
		var fr = new Ring<Float>(2);
		fr.add(1.5);
		var ftyped:Vector<Float> = fr.data;
		fr.add(2.25);
		Sys.println('ring floats ${ftyped.join(",")} ${fr.get(1)}');
		var br = new Ring<Bool>(3);
		br.add(true);
		var btyped:Vector<Bool> = br.data;
		btyped[2] = true;
		Sys.println('ring bools ${btyped.join(",")} ${br.get(1)} ${br.get(2)}');
		var lr = new Ring<Int64>(2);
		lr.add(Int64.make(3, 4));
		var ltyped:Vector<Int64> = lr.data;
		Sys.println('ring int64 ${ltyped[0]} ${ltyped[1]} ${lr.get(0)}');
		var sr = new Ring<String>(2);
		sr.add("x");
		var styped:Vector<String> = sr.data;
		sr.add("y");
		Sys.println('ring strings ${styped.join(",")}');
		var er = new Ring<ViewTag>(2);
		er.add(Large(5));
		var etyped:Vector<ViewTag> = er.data;
		er.add(Small);
		Sys.println('ring enums ${etyped.join(",")}');
		var asDyn:Dynamic = ir.data;
		Sys.println('ring as Dynamic ${asDyn.length} ${asDyn[1]}');
		attempt("ring ints as floats", () -> {
			var v:Vector<Float> = (ir.data : Dynamic);
			v[0];
		});
		var nr = new Ring<Null<Int>>(2);
		nr.add(7);
		var ntyped:Vector<Null<Int>> = nr.data;
		Sys.println('ring nullable ${ntyped[0]} ${ntyped[1]}');

		// generic factories, copies
		var mi:Vector<Int> = make(3);
		mi[1] = 5;
		var mf:Vector<Float> = filled(2, 0.25);
		var mb:Vector<Bool> = filled(2, true);
		var ms:Vector<String> = filled(2, "s");
		Sys.println('factories ${mi.join(",")} ${mf.join(",")} ${mb.join(",")} ${ms.join(",")}');
		var cr = new Ring<Int>(2);
		cr.add(8);
		var c1:Vector<Int> = cr.copy();
		c1[1] = 9;
		var c2:Vector<Float> = copyOf(cr);
		Sys.println('copies ${c1.join(",")} ${cr.get(1)} ${c2.join(",")}');
		attempt("a typed copy as floats", () -> {
			var v:Vector<Float> = (cr.copy() : Dynamic);
			v[0];
		});

		// the collector: wrappers and their storage, converted after collections
		var rings = [for (i in 0...300) new Ring<ViewItem>(4)];
		for (i in 0...300) {
			rings[i].add(new ViewItem(i));
			if (i % 50 == 0) NativeGc.collect(false);
		}
		NativeGc.collect(true);
		var total = 0;
		for (r in rings) {
			r.add(new ViewItem(1));
			var v:Vector<ViewItem> = r.data;
			total += v[0].value + v[1].value;
		}
		var numbers = [for (i in 0...300) new Ring<Int>(3)];
		for (i in 0...300) numbers[i].add(i);
		NativeGc.collect(true);
		for (r in numbers) {
			var v:Vector<Int> = r.data;
			total += v[0];
		}
		NativeGc.collect(false);
		Sys.println('gc $total');
	}
}
