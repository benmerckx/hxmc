// Values of type parameters as tagged words (docs/hxmc.md, "Values of type
// parameters"; hxmc.ir.TagCheck): an Int or a Float in a slot of type T is
// encoded, not boxed. The boundaries where a word becomes Dynamic, a
// number or a reference again: fields, locals, arguments and results of
// type T; == on T (NaN, -0, an Int against a box from Dynamic); interface
// and override signatures; closures of T (adapters, to and from Dynamic);
// enum arguments (switch, Type.enumParameters, Type.enumEq, Std.string);
// reflection and Dynamic access of T fields; structures (literals,
// fields read and written through a typedef); Array<T>, Map<String, T>,
// Null<T> and optional arguments; Std.isOfType, Std.string and string
// interpolation of T; Int64 and Bool values; exceptions; many objects
// holding words through collections. Also the corpus's verify lanes
// (-D hxmc.verify-tags), where any missed conversion ends the program.
import haxe.Int64;

class Cell<T> {
	public var value:T;
	public var writes = 0;

	public function new(v:T)
		value = v;

	public function set(v:T):Bool {
		if (v == value) return false;
		value = v;
		writes++;
		return true;
	}

	public function get():T
		return value;

	public function toString():String
		return 'Cell($value)';
}

class IntCell extends Cell<Int> {
	override public function set(v:Int):Bool
		return super.set(v * 2);

	override public function get():Int
		return value + 1;
}

interface Source<T> {
	function next():T;
}

class Counter implements Source<Float> {
	var n = 0.0;

	public function new() {}

	public function next():Float
		return n += 0.5;
}

class Pair<A, B> {
	public var a:A;
	public var b:B;

	public function new(a, b) {
		this.a = a;
		this.b = b;
	}

	public function swap():Pair<B, A>
		return new Pair(b, a);
}

class Range<T> {
	var xs:Array<T>;
	var i = 0;

	public function new(xs)
		this.xs = xs;

	public function hasNext():Bool
		return i < xs.length;

	public function next():T
		return xs[i++];
}

enum Opt<T> {
	Some(v:T);
	None;
}

typedef HasValue<T> = {var value:T;}

// (a structure of closures of concrete types called where it is generic: the
// signatures differ, so the call takes the runtime's slow path, which
// allocates while the references passed are live: MemLower.callAnon roots them)
typedef Api<A> = {var combine:Obj->A->Obj->Int;}

abstract Wrap<T>(T) {
	public inline function new(v:T)
		this = v;

	public inline function unwrap():T
		return this;
}

class Obj {
	public var n:Int;

	public function new(n)
		this.n = n;

	public function toString()
		return 'Obj($n)';
}

class TypeParamValues {
	static function id<T>(x:T):T
		return x;

	static function eq<T>(a:T, b:T):Bool
		return a == b;

	static function ne<T>(a:T, b:T):Bool
		return a != b;

	static function isNull<T>(?x:T):Bool
		return x == null;

	static function str<T>(x:T):String
		return 'v=$x ' + Std.string(x);

	static function kind<T>(x:T):String
		return Std.isOfType(x, Int) ? "Int" : Std.isOfType(x, Float) ? "Float" : Std.isOfType(x, String) ? "String" : Std.isOfType(x, Bool) ? "Bool" : x == null ? "null" : "other";

	static function apply<T, R>(f:T->R, x:T):R
		return f(x);

	static function twice<T>(f:T->T):T->T
		return x -> f(f(x));

	static function fill<T>(n:Int, v:T):Array<T>
		return [for (_ in 0...n) v];

	static function first<T>(a:Array<T>):T
		return a[0];

	static function sum<T:Float>(a:Array<T>):Float {
		var s = 0.0;
		for (x in a)
			s += x;
		return s;
	}

	static function unwrapOr<T>(o:Opt<T>, d:T):T
		return switch o {
			case Some(v): v;
			case None: d;
		}

	static function readValue<T>(h:HasValue<T>):T
		return h.value;

	static function writeValue<T>(h:HasValue<T>, v:T)
		h.value = v;

	static function collect<T>(it:Iterator<T>):Array<T>
		return [for (x in it) x];

	static function throwIt<T>(x:T):Void
		throw x;

	// (a constrained type parameter's value as the receiver of what the runtime implements)
	static function len<T:String>(s:T):String
		return s.length + s.charAt(1) + s.toUpperCase() + [s].length;

	static function callApi<A>(api:Api<A>, x:A, n:Int):Int {
		var s = 0;
		for (i in 0...n)
			s += api.combine(new Obj(i), x, new Obj(1));
		return s;
	}

	static function main() {
		// fields, == and its NaN and -0
		var ci = new Cell(1), cf = new Cell(1.5), cs = new Cell("a"), cb = new Cell(true);
		Sys.println([ci.set(1), ci.set(2), ci.set(2), ci.set(-7)].join(",") + " " + ci.value + " " + ci.writes);
		Sys.println([cf.set(1.5), cf.set(0.0), cf.set(-0.0), cf.set(Math.NaN), cf.set(Math.NaN)].join(",") + " " + cf.writes);
		Sys.println([cs.set("a"), cs.set("a" + ""), cs.set("b")].join(",") + " " + cs.value);
		Sys.println([cb.set(true), cb.set(false)].join(",") + " " + cb.value);
		var big = new Cell(2147483647);
		big.set(-2147483648);
		Sys.println(big.get() + " " + (big.get() - 1));
		var co = new Cell(new Obj(1));
		var o2 = new Obj(1);
		Sys.println(co.set(o2) + " " + co.set(o2) + " " + co.value.n);
		Sys.println(ci + " " + cf + " " + cs + " " + co);

		// generic functions, Dynamic against words
		var d:Dynamic = 3;
		var df:Dynamic = 2.5;
		Sys.println(id(5) + id(1.25) + " " + id("s") + " " + id(null));
		Sys.println(eq(1, 1) + " " + eq(1, 2) + " " + eq(0.0, -0.0) + " " + eq(Math.NaN, Math.NaN) + " " + ne(Math.NaN, Math.NaN));
		Sys.println(eq(d, 3) + " " + eq(3, d) + " " + eq(df, 2.5) + " " + eq(d, 3.0) + " " + eq(d, "3") + " " + eq(null, 0) + " " + eq(null, null));
		Sys.println(isNull() + " " + isNull(0) + " " + isNull(0.0) + " " + isNull(null) + " " + isNull(false));
		Sys.println(str(1) + " " + str(1.5) + " " + str(-0.0) + " " + str(Math.NaN) + " " + str("x") + " " + str(true) + " " + str(null) + " " + str([1, 2]));
		Sys.println([kind(1), kind(1.5), kind("a"), kind(true), kind(null), kind(new Obj(0)), kind(d), kind(df)].join(" "));
		var i64 = id(Int64.make(1, 2));
		Sys.println(Int64.toStr(i64) + " " + eq(Int64.make(0, 5), Int64.ofInt(5)));

		// overrides and interfaces
		var ic = new IntCell(3);
		var asCell:Cell<Int> = ic;
		asCell.set(5);
		Sys.println(ic.value + " " + ic.get() + " " + asCell.get());
		var src:Source<Float> = new Counter();
		src.next();
		Sys.println(src.next() + " " + (cast src : Counter).next());
		var p = new Pair(1, 2.5).swap();
		Sys.println(p.a + p.b + " " + p.a / 2);

		// closures
		var inc = (x:Int) -> x + 1;
		Sys.println(apply(inc, 4) + " " + apply((x:Float) -> x * 2, 1.25) + " " + twice(inc)(1) + " " + twice((s:String) -> s + "!")("hi"));
		var dyn:Dynamic = twice;
		var tw:Dynamic = dyn((x:Float) -> x / 2);
		Sys.println(tw(10) + " " + Reflect.callMethod(null, tw, [3]));
		var anyF:Dynamic->Dynamic = x -> x;
		Sys.println(apply(anyF, 7) + " " + apply(anyF, 0.5));
		var captured = 0.25;
		var add = (x:Float) -> captured += x;
		apply(add, 1.0);
		Sys.println(captured);
		var cells = [new Cell(1), new Cell(2)];
		Sys.println(cells.map(c -> c.get() * 10).join(",") + " " + Lambda.fold([1.5, 2.5], (x, acc) -> x + acc, 0.0));

		// enums
		var some = Some(2.5), none:Opt<Float> = None;
		Sys.println(unwrapOr(some, 0.0) + " " + unwrapOr(none, -1.0) + " " + unwrapOr(Some("s"), "d"));
		Sys.println(Std.string(some) + " " + Std.string(Some(3)) + " " + Type.enumParameters(Some(7)) + " " + Type.enumParameters(Some(1.5)));
		Sys.println(Type.enumEq(Some(1), Some(1)) + " " + Type.enumEq(Some(1), Some(2)) + " " + Type.enumEq(Some(0.0), Some(-0.0)) + " " + Type.enumEq(Some(Math.NaN), Some(Math.NaN))
			+ " " + Type.enumEq(Some(Some(1)), Some(Some(1))) + " " + Type.enumEq(Some("a"), Some("a")));
		var made:Opt<Int> = Type.createEnum(Opt, "Some", [41]);
		Sys.println(unwrapOr(made, 0) + 1);
		switch Some(5) {
			case Some(v) if (v > 3): Sys.println("big " + v);
			case _: Sys.println("other");
		}

		// reflection and Dynamic access
		var rc = new Cell(1.5);
		var rd:Dynamic = rc;
		Sys.println(Reflect.field(rc, "value") + " " + rd.value + " " + rd.get() + " " + Reflect.callMethod(rc, Reflect.field(rc, "get"), []));
		Reflect.setField(rc, "value", 4);
		rd.set(2.25);
		Sys.println(rc.value + " " + rc.writes + " " + Reflect.fields(rc).length);
		var ri:Cell<Int> = Type.createInstance(Cell, [9]);
		Sys.println(ri.get() + 1 + " " + Reflect.field(ri, "value"));
		Sys.println(Std.string(Reflect.copy({a: 1, b: 2.5})));

		// structures
		var h:HasValue<Float> = rc;
		Sys.println(readValue(h) + " " + readValue({value: 3}) + " " + readValue({value: "s"}));
		writeValue(h, 0.75);
		var lit = {value: 1};
		writeValue(lit, 8);
		Sys.println(rc.value + " " + lit.value + " " + Std.string({x: id(1.5), y: id("z")}));
		Sys.println(collect(new Range([1, 2, 3])).join(",") + " " + collect(new Range([0.5])).join(",") + " " + collect([4.5, 5.5].iterator()).join(","));
		var w = new Wrap(2.5);
		Sys.println(w.unwrap() * 2);

		// arrays, maps, Null<T>
		var ai:Array<Int> = fill(3, 7), af:Array<Float> = fill(2, 0.5);
		ai.push(first(ai) + 1);
		Sys.println(ai.join(",") + " " + af.join(",") + " " + sum(ai) + " " + sum(af) + " " + first(["q"]) + " " + ai.indexOf(id(8)));
		var m = new Map<String, Float>();
		function put<T>(mm:Map<String, T>, k:String, v:T)
			mm.set(k, v);
		put(m, "a", 1.5);
		put(m, "b", id(-2.0));
		Sys.println(m.get("a") + m.get("b") + " " + m.exists("c"));
		var n:Null<Float> = id(null);
		Sys.println(n == null);

		// exceptions
		try
			throwIt(1.5)
		catch (e:Dynamic)
			Sys.println("caught " + e);
		try
			throwIt(42)
		catch (e:Int)
			Sys.println("caught Int " + (e + 1));

		// many words in objects through collections
		var keep = [];
		var total = 0.0;
		for (i in 0...200000) {
			var c = new Cell(i % 2 == 0 ? (i : Float) * 0.5 : -1.0 * i);
			if (i % 1000 == 0) keep.push(c);
			total += c.get();
		}
		var kept = 0.0;
		for (c in keep)
			kept += c.get();
		var ints = [for (i in 0...1000) new Cell(i)];
		for (i in 0...100000)
			new Cell(new Obj(i));
		var isum = 0;
		for (c in ints)
			isum += c.get();
		Sys.println(total + " " + kept + " " + keep.length + " " + isum);
		var api:Api<String> = {combine: (a:Obj, s:String, b:Obj) -> (a.n & 7) + s.length + b.n};
		var apf:Api<Float> = {combine: (a:Obj, f:Float, b:Obj) -> (a.n & 7) + Std.int(f) + b.n};
		Sys.println(callApi(api, "abc", 200000) + " " + callApi(apf, 2.5, 200000));
		Sys.println(len("abc"));
	}
}
