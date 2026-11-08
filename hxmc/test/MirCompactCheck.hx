import hxmc.Mir;
import core.ds.VectorTools.vector;

class MirCompactCheck {
	static function check(ok:Bool, what:String) {
		if (!ok) throw "MIR compaction: " + what;
	}

	public static function run() {
		var f = new MFunc("compact");
		var entry = f.newBlock(), left = f.newBlock(), right = f.newBlock(), join = f.newBlock();
		f.entry = entry;
		function ins(b:MBlock, op:Op, ty:MTy):MIns {
			var i = new MIns(op, ty);
			i.id = f.vals.length;
			i.block = b;
			f.vals.push(i);
			if (b != null) b.ins.push(i);
			return i;
		}
		var cond = ins(entry, Param, I32);
		for (_ in 0...16) ins(null, Const, I64);
		var value = ins(entry, Const, I64);
		value.imm = 42;
		// Phi operands can name instructions allocated after the phi.
		var phi = ins(join, Phi, I64);
		var a = ins(left, Call, I64), b = ins(right, Call, I64);
		var shared = vector(value.id);
		a.args = b.args = shared;
		phi.args = vector(a.id, b.id);
		var branch = ins(entry, Br, Void);
		branch.a = cond.id;
		branch.targets = vector(left, right);
		entry.succs = [left, right];
		left.preds = right.preds = [entry];
		for (block in [left, right]) {
			ins(block, Jmp, Void).targets = vector(join);
			block.succs = [join];
		}
		join.preds = [left, right];
		ins(join, Ret, Void).a = phi.id;
		var original = value.id;
		check(f.compact() == 16, "removed count was incorrect");
		check(f.vals.length == 9, "obsolete instructions were retained");
		for (k in 0...f.vals.length) check(f.vals[k].id == k, "value table and ids disagree");
		check(value.id < original && a.args[0] == value.id && b.args[0] == value.id, "shared operands were renamed twice");
		check(shared[0] == original, "a borrowed operand vector was changed");
		check(phi.args[0] == a.id && phi.args[1] == b.id, "forward phi operands were lost");
		check(branch.a == cond.id && join.term().a == phi.id && branch.b == -1, "scalar operands were renamed incorrectly");
		var before = f.dump();
		f.compact();
		check(f.dump() == before, "a second compaction changed the function");
	}
}
