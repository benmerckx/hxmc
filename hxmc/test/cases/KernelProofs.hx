import hxmc.rt.TypeView;

// Proofs (docs/interop.md, "Kernels"): a @:hxmc.proof abstract is made only
// by @:hxmc.unsafe code, its view, so a safe kernel trusts one it holds: a
// slot index masked below a table's length reads the table unchecked. Safe
// kernels hold, pass, compare and return proofs; hxmc.rt.TypeView's
// TypeIndex reads the type table so (reject/KernelProof* the rules).
@:hxmc.proof abstract Slot(Int) to Int {
	@:op(A < B) static function lt(a:Slot, b:Int):Bool;
}

@:hxmc.kernel @:hxmc.unsafe class Slots {
	// (8 slots: an index masked is always one)
	public static function of(i:Int):Slot
		return cast(i & 7);

	public static function next(s:Slot):Slot
		return cast((s + 1) & 7);
}

class A {
	public function new() {}
}

class B extends A {}

enum E {
	X;
	Y(v:Int);
}

class KernelProofs {
	@:hxmc.kernel static function walk(from:Int, steps:Int):Int {
		var s = Slots.of(from), sum = 0;
		for (_ in 0...steps) {
			sum += s;
			s = Slots.next(s);
		}
		return sum;
	}

	@:hxmc.kernel static function pick(a:Slot, b:Slot):Slot
		return a < b ? b : a;

	// (GC code passes no proof: it could make one from anything)
	@:hxmc.kernel static function larger(a:Int, b:Int):Int
		return pick(Slots.of(a), Slots.of(b));

	@:hxmc.kernel static function same(a:Int, b:Int):Bool
		return Slots.of(a) == Slots.of(b);

	// a value's class and its super classes, by type index
	@:hxmc.kernel static function depth(v:Dynamic):Int {
		var t = TypeView.of(v), n = 0;
		while (t != 0) {
			n++;
			t = TypeView.sup(t);
		}
		return n;
	}

	@:hxmc.kernel static function kind(v:Dynamic):Int
		return TypeView.kind(TypeView.of(v));

	@:hxmc.kernel static function boxed(v:Dynamic):Float
		return TypeView.int(v) + TypeView.float(v);

	static function main() {
		trace(walk(5, 10), larger(3, 12), same(1, 9), same(1, 2));
		trace(depth(new B()) - depth(new A()), depth(null));
		trace(kind(new A()), kind(Y(1)), kind(null));
		trace(boxed(7), boxed(2.5), boxed("s"), boxed(null));
		trace(Std.isOfType(new B(), A), Std.isOfType(new A(), B), Std.isOfType(Y(1), E), Std.isOfType(1.0, Int), Std.isOfType(1.5, Int));
		var d:Dynamic = 3;
		trace(d == 3.0, Reflect.compare(d, 2.5), Type.enumIndex(Y(2)), (d : Int) + 1);
	}
}
