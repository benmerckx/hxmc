// A test of an inlined function's Null<Int> result that the optimizer
// threads (Opt.simplifyCfg): the edge from the copy's return of a value
// becomes a branch on that value, which is wider than the 32 bits a branch
// tests (a tagged Int whose low half is 0 is not null), so it is compared
// with zero first. In a condition of && and ||, as Isel.prepare's
// `(i.op == Const && immOf(i.id) != null) || ...`.
class V {
	public var op:Int;
	public var imm:Int;

	public function new(op, imm) {
		this.op = op;
		this.imm = imm;
	}
}

class NullIntThreading {
	static function immOf(v:V):Null<Int> {
		if (v.op == 1) return v.imm;
		return null;
	}

	static function main() {
		var vals = [new V(1, 7), new V(0, 7), new V(1, 0), new V(2, 0), new V(1, 3), new V(0, 3)];
		var r = [];
		for (v in vals)
			if ((v.op != 0 && immOf(v) != null) || v.imm == 3) r.push(v.op + ":" + v.imm);
		trace(r.join(" "));
		var n = 0;
		for (v in vals)
			if (immOf(v) == null && v.imm != 7) n++;
		trace(n);
	}
}
