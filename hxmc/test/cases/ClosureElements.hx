import haxe.Int64;
import haxe.ds.Vector;

// Closures stored in containers and read back where a type parameter makes
// their arguments or results Dynamic (boxed). An Array's and a Vector's
// element type is the instantiated one, so the same array is an
// Array<(Int) -> Bool> where it is filled and an Array<(T) -> Bool> in a
// generic function or a rest argument (tsc-haxe's Core.Or): the closures
// read there were called with the other representation (a wrong result, a
// crash; a signature mismatch trap on WebAssembly), as were those of a
// generic function's array read where T is Int. The other containers (Map,
// haxe.ds.List, structures, enum arguments, closures' arguments and
// results, iterators) worked and are checked alongside.
private class Holder {
	public var n:Int;

	public function new(n)
		this.n = n;

	public function isN(x:Int):Bool
		return x == n;
}

private class Preds<T> {
	public var fs:Array<T->Bool> = [];
	public var vs:Vector<T->Bool>;

	public function new()
		vs = new Vector(1);

	public function any(x:T):Bool {
		for (f in fs)
			if (f(x)) return true;
		return vs[0] != null && vs[0](x);
	}
}

private enum Pred<T> {
	P(f:T->Bool);
	Ps(fs:Array<T->Bool>);
}

class ClosureElements {
	static function or<T>(...funcs:(T) -> Bool):(T) -> Bool {
		final funcs = funcs.toArray();
		return function(input:T):Bool {
			for (f in funcs)
				if (f(input)) return true;
			return false;
		};
	}

	static function anyOf<T>(fs:Array<(T) -> Bool>, x:T):Bool {
		for (f in fs)
			if (f(x)) return true;
		return false;
	}

	static function anyRest<T>(x:T, ...fs:(T) -> Bool):Bool {
		for (f in fs)
			if (f(x)) return true;
		return false;
	}

	static function anyRestIdx<T>(x:T, ...fs:(T) -> Bool):Bool {
		for (i in 0...fs.length)
			if (fs[i](x)) return true;
		return false;
	}

	static function mapAll<T, R>(fs:Array<(T) -> R>, x:T):Array<R>
		return [for (f in fs) f(x)];

	static function makeEq<T>(xs:Array<T>):Array<(T) -> Bool>
		return [for (x in xs) (y:T) -> y == x];

	static function consts<T>(xs:Array<T>):Array<() -> T>
		return [for (x in xs) () -> x];

	static function constVec<T>(x:T):Vector<() -> T> {
		var v = new Vector(1);
		v[0] = () -> x;
		return v;
	}

	static function callAll<T>(fs:Array<() -> T>):Array<T>
		return [for (f in fs) f()];

	static function vecAny<T>(fs:Vector<(T) -> Bool>, x:T):Bool {
		for (f in fs)
			if (f(x)) return true;
		return false;
	}

	static function vecIdx<T>(fs:Vector<(T) -> Bool>, x:T):Bool {
		for (i in 0...fs.length)
			if (fs[i](x)) return true;
		return false;
	}

	static function mapAny<K, T>(fs:Map<K, (T) -> Bool>, x:T):Bool {
		for (f in fs)
			if (f(x)) return true;
		return false;
	}

	static function anonAny<T>(o:{f:(T) -> Bool, g:(T) -> Bool}, x:T):Bool
		return o.f(x) || o.g(x);

	static function enumAny<T>(p:Pred<T>, x:T):Bool
		return switch p {
			case P(f): f(x);
			case Ps(fs): anyOf(fs, x);
		}

	static function listAny<T>(fs:haxe.ds.List<(T) -> Bool>, x:T):Bool {
		for (f in fs)
			if (f(x)) return true;
		return false;
	}

	static function nestedAny<T>(fss:Array<Array<(T) -> Bool>>, x:T):Bool {
		for (fs in fss)
			for (f in fs)
				if (f(x)) return true;
		return false;
	}

	static function iterAny<T>(it:Iterator<(T) -> Bool>, x:T):Bool {
		for (f in it)
			if (f(x)) return true;
		return false;
	}

	static function wrap<T>(f:(T) -> Bool):() -> ((T) -> Bool)
		return () -> f;

	static function applyTo<T>(x:T):((T) -> Bool) -> Bool
		return f -> f(x);

	static function isOne(x:Int):Bool
		return x == 1;

	static function main() {
		final o = or((x:Int) -> x == 1, (x:Int) -> x == 3);
		Sys.println("or: " + [o(1), o(2), o(3), or()(1)]);
		final of = or((x:Float) -> x > 1.5);
		Sys.println("or float: " + [of(2.0), of(1.0)]);
		var ints:Array<Int->Bool> = [x -> x == 1, x -> x == 3];
		Sys.println("array int: " + [anyOf(ints, 1), anyOf(ints, 2), anyOf(ints, 3)]);
		var floats:Array<Float->Bool> = [x -> x > 2.5, x -> x < -1.5];
		Sys.println("array float: " + [anyOf(floats, 3.0), anyOf(floats, 0.5), anyOf(floats, -2.0)]);
		var bools:Array<Bool->Bool> = [x -> x];
		Sys.println("array bool: " + [anyOf(bools, true), anyOf(bools, false)]);
		var strs:Array<String->Bool> = [x -> x == "a"];
		Sys.println("array string: " + [anyOf(strs, "a"), anyOf(strs, "b")]);
		var longs:Array<Int64->Bool> = [x -> x == Int64.make(1, 2)];
		Sys.println("array int64: " + [anyOf(longs, Int64.make(1, 2)), anyOf(longs, Int64.make(2, 1))]);
		Sys.println("rest int: " + [anyRest(1, x -> x == 1, x -> x == 3), anyRest(2, x -> x == 1, x -> x == 3)]);
		Sys.println("rest float: " + [anyRest(1.5, x -> x == 1.5), anyRest(2.5, x -> x == 1.5)]);
		Sys.println("rest index: " + [anyRestIdx(3, x -> x == 1, x -> x == 3), anyRestIdx(4, x -> x == 1)]);
		Sys.println("rest spread: " + [anyRest(3, ...ints), anyRest(4, ...ints)]);
		Sys.println("float to int: " + mapAll([(x:Float) -> Std.int(x * 2), (x:Float) -> Std.int(x * 3)], 1.5));
		Sys.println("int to float: " + mapAll([(x:Int) -> x / 2, (x:Int) -> x * 1.5], 3));
		var eqs = makeEq([1, 2]);
		Sys.println("from generic: " + [eqs[0](1), eqs[0](2), eqs[1](2)]);
		var cs = consts([4, 5]);
		Sys.println("results: " + [cs[0](), cs[1]()]);
		var cf = consts([1.25]);
		Sys.println("float result: " + (cf[0]() + 1));
		Sys.println("vector result: " + (constVec(2.5)[0]() * 2) + " " + (constVec(true)[0]() ? "yes" : "no"));
		Sys.println("call all: " + callAll([() -> 7, () -> 8]) + " " + callAll([() -> 0.5]));
		var h = new Holder(3);
		var meths:Array<Int->Bool> = [h.isN, isOne];
		Sys.println("methods: " + [anyOf(meths, 3), anyOf(meths, 1), anyOf(meths, 2)]);
		function local(x:Int):Bool
			return x == 9;
		Sys.println("local: " + [anyOf([local], 9), anyRest(9, local), anyRest(8, local)]);
		var r:Int->Bool = Reflect.field(ClosureElements, "isOne");
		Sys.println("reflect: " + [anyOf([r], 1), anyOf([r], 4)]);
		var dyns:Array<Dynamic> = [x -> x == 1, (x:Float) -> x > 1.5];
		Sys.println("dynamic: " + [dyns[0](1), dyns[1](2.0), dyns[1](1.0)]);
		var asDyn:Dynamic = ints;
		Sys.println("dynamic array: " + [asDyn[1](3), asDyn[1](1)]);
		var p = new Preds<Int>();
		p.fs.push(x -> x == 5);
		p.fs.push(h.isN);
		p.vs[0] = x -> x == 7;
		Sys.println("generic class: " + [p.any(5), p.any(3), p.any(7), p.any(4)]);
		var v = new Vector<Int->Bool>(2);
		v[0] = x -> x == 1;
		v[1] = x -> x == 2;
		Sys.println("vector: " + [vecAny(v, 2), vecAny(v, 3), vecIdx(v, 1), vecIdx(v, 3)]);
		var m:Map<String, Int->Bool> = ["a" => x -> x == 1];
		var im:Map<Int, Float->Bool> = [1 => x -> x == 0.5];
		Sys.println("map: " + [mapAny(m, 1), mapAny(m, 2), mapAny(im, 0.5), mapAny(im, 1.5)]);
		Sys.println("anon: " + [anonAny({f: x -> x == 1, g: x -> x == 2}, 2), anonAny({f: (x:Int) -> x == 1, g: x -> x == 2}, 3)]);
		Sys.println("enum: " + [enumAny(P(x -> x == 1), 1), enumAny(Ps([x -> x == 2]), 2), enumAny(Ps(ints), 4)]);
		var l = new haxe.ds.List<Int->Bool>();
		l.add(x -> x == 6);
		Sys.println("list: " + [listAny(l, 6), listAny(l, 7)]);
		Sys.println("nested: " + [nestedAny([ints, [x -> x == 8]], 8), nestedAny([ints], 8)]);
		Sys.println("iterator: " + [iterAny(ints.iterator(), 3), iterAny(ints.iterator(), 4)]);
		var g = wrap((x:Int) -> x == 1);
		Sys.println("closure result: " + [g()(1), g()(2)]);
		var a = applyTo(4);
		Sys.println("closure argument: " + [a(x -> x == 4), a(x -> x == 5)]);
	}
}
