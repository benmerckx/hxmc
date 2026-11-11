// Proofs (docs/interop.md, "Kernels"): a @:hxmc.proof abstract is made only
// by @:hxmc.unsafe code, its view, so a safe kernel trusts one it holds: a
// slot index masked below a table's length reads the table unchecked. Safe
// kernels hold, pass, compare and return proofs (reject/KernelProof* the
// rules).
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

	static function main()
		trace(walk(5, 10), larger(3, 12), same(1, 9), same(1, 2));
}
