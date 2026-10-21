package core.ds;

import haxe.ds.Vector;
#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
#end

// port: `vector(a, b, c)`, a Vector literal (upstream's `[|a; b; c|]`, or a list
// literal kept as a Vector): allocated at its size and filled in order, with no
// Array in between; `vector()` is the empty vector (on hxmc one static object per
// element kind: no allocation). The element type comes from the expected type
// where there is one, as an array literal's would, else from the elements (`set`
// rather than `[i] =`, which types its right side without one). On hxmc, of a
// known element type, it is `hxmc.NativeArray.literal([a, b, c])`, which the
// backend allocates and fills as it does an Array literal.
macro function vector(exprs:Array<Expr>):Expr {
	var p = Context.currentPos();
	var hint:Null<ComplexType> = null, elem:Null<ComplexType> = null;
	switch Context.getExpectedType() {
		case null:
		case t:
			switch Context.follow(t) {
				case vt = TAbstract(_.get() => {pack: ["haxe", "ds"], name: "Vector"}, [et]):
					try {
						hint = Context.toComplexType(vt);
						elem = Context.toComplexType(et);
					} catch (_:Dynamic) {}
				case _:
			}
	}
	if (hint != null && elem != null && Context.definedValue("target.name") == "hxmc")
		return macro @:pos(p) (haxe.ds.Vector.fromData(hxmc.NativeArray.literal(([$a{exprs}] : Array<$elem>))) : $hint);
	if (exprs.length == 0)
		return hint == null ? macro @:pos(p) new haxe.ds.Vector(0) : macro @:pos(p) (new haxe.ds.Vector(0) : $hint);
	var name = "__vector" + VectorTools.nextId++;
	var ref = macro @:pos(p) $i{name};
	var block = [{expr: EVars([{name: name, type: hint, expr: macro @:pos(p) new haxe.ds.Vector($v{exprs.length})}]), pos: p}];
	for (i in 0...exprs.length)
		block.push(macro @:pos(exprs[i].pos) $ref.set($v{i}, ${exprs[i]}));
	block.push(ref);
	return macro @:pos(p) $b{block};
}

// port: the list functions the port needs on Vectors (Lambda takes an Iterable,
// which a Vector is not; core.ds.ArrayTools has the same for Arrays). Inline:
// hxmc erases type parameters, and a Vector read or made in generic code has no
// known element type (dynamic accesses).
class VectorTools {
	#if macro
	public static var nextId = 0;
	#end

	public static inline function exists<T>(v:Vector<T>, f:T->Bool):Bool {
		var found = false;
		for (x in v) if (f(x)) {
			found = true;
			break;
		}
		return found;
	}

	public static inline function foreach<T>(v:Vector<T>, f:T->Bool):Bool {
		var all = true;
		for (x in v) if (!f(x)) {
			all = false;
			break;
		}
		return all;
	}

	public static inline function count<T>(v:Vector<T>, ?pred:T->Bool):Int {
		var n = 0;
		if (pred == null) n = v.length;
		else for (x in v) if (pred(x)) n++;
		return n;
	}

	public static inline function has<T>(v:Vector<T>, elt:T):Bool {
		var found = false;
		for (x in v) if (x == elt) {
			found = true;
			break;
		}
		return found;
	}

	public static inline function indexOf<T>(v:Vector<T>, elt:T):Int {
		var r = -1;
		for (i in 0...v.length) if (v[i] == elt) {
			r = i;
			break;
		}
		return r;
	}

	public static inline function find<T>(v:Vector<T>, f:T->Bool):Null<T> {
		var r:Null<T> = null;
		for (x in v) if (f(x)) {
			r = x;
			break;
		}
		return r;
	}

	public static inline function iter<T>(v:Vector<T>, f:T->Void):Void {
		for (x in v) f(x);
	}

	public static inline function empty<T>(v:Vector<T>):Bool
		return v.length == 0;

	public static inline function last<T>(v:Vector<T>):T
		return v[v.length - 1];

	// port: Array.init: `f` applied to the indices in order
	public static inline function init<T>(n:Int, f:Int->T):Vector<T> {
		var r = new Vector<T>(n);
		for (i in 0...n) r[i] = f(i);
		return r;
	}

	// port: Array.of_list (of the elements from `pos` on)
	public static inline function ofArray<T>(a:Array<T>, pos = 0):Vector<T> {
		var r = new Vector<T>(a.length - pos);
		for (i in pos...a.length) r[i - pos] = a[i];
		return r;
	}

	// port: List.rev of an accumulator, as a Vector
	public static inline function ofArrayReversed<T>(a:Array<T>):Vector<T> {
		var n = a.length;
		var r = new Vector<T>(n);
		for (i in 0...n) r[i] = a[n - 1 - i];
		return r;
	}

	public static inline function mapi<T, S>(v:Vector<T>, f:Int->T->S):Vector<S> {
		var r = new Vector<S>(v.length);
		for (i in 0...v.length) r[i] = f(i, v[i]);
		return r;
	}

	// port: the mapped elements as an Array (a list built from a vector)
	public static inline function mapToArray<T, S>(v:Vector<T>, f:T->S):Array<S>
		return [for (x in v) f(x)];

	// port: the mapped elements of an Array as a Vector, allocated at its size
	public static inline function mapToVector<T, S>(a:Array<T>, f:T->S):Vector<S> {
		var r = new Vector<S>(a.length);
		for (i in 0...a.length) r[i] = f(a[i]);
		return r;
	}

	public static inline function filter<T>(v:Vector<T>, f:T->Bool):Vector<T> {
		var r = [];
		for (x in v) if (f(x)) r.push(x);
		return Vector.fromArrayCopy(r);
	}

	public static inline function concat<T>(a:Vector<T>, b:Vector<T>):Vector<T> {
		var r = new Vector<T>(a.length + b.length);
		Vector.blit(a, 0, r, 0, a.length);
		Vector.blit(b, 0, r, a.length, b.length);
		return r;
	}

	// port: the elements from `pos` on (`end` excluded), as Array.slice
	public static inline function slice<T>(v:Vector<T>, pos:Int, ?end:Int):Vector<T> {
		var e = end == null || end > v.length ? v.length : end;
		var n = e - pos;
		if (n < 0) n = 0;
		var r = new Vector<T>(n);
		Vector.blit(v, pos, r, 0, n);
		return r;
	}

	// port: a @ v (the elements of an Array, then those of `v`)
	public static inline function prependArray<T>(v:Vector<T>, a:Array<T>):Vector<T> {
		var r = new Vector<T>(a.length + v.length);
		for (i in 0...a.length) r[i] = a[i];
		Vector.blit(v, 0, r, a.length, v.length);
		return r;
	}

	// port: v @ a
	public static inline function appendArray<T>(v:Vector<T>, a:Array<T>):Vector<T> {
		var r = new Vector<T>(v.length + a.length);
		Vector.blit(v, 0, r, 0, v.length);
		for (i in 0...a.length) r[v.length + i] = a[i];
		return r;
	}

	// port: x :: l
	public static inline function cons<T>(x:T, v:Vector<T>):Vector<T> {
		var r = new Vector<T>(v.length + 1);
		r[0] = x;
		Vector.blit(v, 0, r, 1, v.length);
		return r;
	}

	// port: l @ [x]
	public static inline function snoc<T>(v:Vector<T>, x:T):Vector<T> {
		var r = new Vector<T>(v.length + 1);
		Vector.blit(v, 0, r, 0, v.length);
		r[v.length] = x;
		return r;
	}

	// port: a copy with the last element replaced (`List.rev (x :: List.tl (List.rev l))`)
	public static inline function withLast<T>(v:Vector<T>, x:T):Vector<T> {
		var r = v.copy();
		r[r.length - 1] = x;
		return r;
	}

	// port: a copy with the first element replaced (`x :: List.tl l`)
	public static inline function withFirst<T>(v:Vector<T>, x:T):Vector<T> {
		var r = v.copy();
		r[0] = x;
		return r;
	}

	// port: Array.reverse: the elements reversed in place
	public static inline function reverse<T>(v:Vector<T>):Void {
		var i = 0, j = v.length - 1;
		while (i < j) {
			var x = v[i];
			v[i++] = v[j];
			v[j--] = x;
		}
	}

	// port: List.rev
	public static inline function rev<T>(v:Vector<T>):Vector<T> {
		var n = v.length;
		var r = new Vector<T>(n);
		for (i in 0...n) r[i] = v[n - 1 - i];
		return r;
	}
}
