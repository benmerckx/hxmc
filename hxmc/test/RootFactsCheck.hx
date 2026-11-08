import hxmc.Roots;
import hxmc.ir.Ir;
import core.ds.VectorTools.vector;

// Root analysis must keep its facts outside the frontend's bodies. A
// single statement may occur at several list positions; those occurrences
// can have different live references and must not share a spill set.
class RootFactsCheck {
	static function check(ok:Bool, what:String) {
		if (!ok) throw "root facts: " + what;
	}

	static function main() {
		var ref = TRef(RAny);
		var cond = new Local(0, "cond", TI32);
		var a = new Local(1, "a", ref), b = new Local(2, "b", ref);
		var tmp = new Local(3, "tmp", ref);
		var cls = new ClassInfo("C", "C", null);
		var sink = new FuncInfo("sink", "Test");
		sink.noGc = true;
		sink.args = [new Local(0, "value", ref)];
		var shared = SSet(tmp, ENewObj(cls));
		var yes = vector(shared, SExpr(ECall(sink, vector(ELocal(a)))));
		var no = vector(shared, SExpr(ECall(sink, vector(ELocal(b)))));
		var f = new FuncInfo("test", "Test");
		f.args = [cond, a, b];
		f.locals = [tmp];
		f.body = vector(SIf(ELocal(cond), yes, no), SReturn(null));
		var body = f.body;
		var r = Roots.analyze(f);
		check(f.body == body && yes[0] == shared && no[0] == shared, "analysis changed the input");
		var ys = r.coldAt(yes, 0), ns = r.coldAt(no, 0);
		check(ys != null && ys.length == 1 && ys[0] == a, "first occurrence lost its live reference");
		check(ns != null && ns.length == 1 && ns[0] == b, "second occurrence reused the first's facts");
		check(r.coldAt(yes, 1) == null, "a GC-free call was treated as a cold site");
		// A second analysis cannot depend on mutations made by the first.
		var again = Roots.analyze(f);
		check(again.coldAt(yes, 0)[0] == a && again.coldAt(no, 0)[0] == b, "analysis is not repeatable");
		// A continue needs the next iteration's references; a break needs
		// the references used after the loop. Neither target may be changed
		// while walking backwards through the other path.
		var loop = vector(shared, SIf(ELocal(cond), vector(SBreak), vector(SExpr(ECall(sink, vector(ELocal(b)))), SContinue)));
		f.body = vector(SLoop(loop), SExpr(ECall(sink, vector(ELocal(a)))), SReturn(null));
		var lr = Roots.analyze(f).coldAt(loop, 0);
		check(lr != null && lr.length == 2 && lr[0] == a && lr[1] == b, "loop targets lost live references");
		// What a handler and the continuation need stays live throughout
		// the try body, even when a nested walk changes its working mask.
		var caught = new Local(4, "caught", ref);
		var handler:IrCatch = {l: caught, test: null, body: vector(SExpr(ECall(sink, vector(ELocal(a)))))};
		f.locals = [tmp, caught];
		f.hasTry = true;
		f.body = vector(STry(vector(shared), vector(handler)), SExpr(ECall(sink, vector(ELocal(b)))), SReturn(null));
		var tr = Roots.analyze(f);
		check(tr.rooted.get(a.id) && tr.rooted.get(b.id) && tr.rooted.get(caught.id), "handler requirements lost live references");
		Sys.println("root facts: shared sites, loops, handlers, repeatability and input preservation passed");
	}
}
