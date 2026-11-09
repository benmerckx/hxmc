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
		MirCompactCheck.run();
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
		// Arguments needed after the same collecting call must not share
		// their cells, even when many other reference locals need no cells.
		var gc = new FuncInfo("gc", "Test");
		f.hasTry = false;
		f.args = [a, b];
		f.locals = [for (k in 4...68) new Local(k, "unused" + k, ref)];
		f.body = vector(SExpr(ECall(gc, vector())), SExpr(ECall(sink, vector(ELocal(a)))), SExpr(ECall(sink, vector(ELocal(b)))), SReturn(null));
		var all = f.args.concat(f.locals), graph = Roots.analyze(f), unset = Roots.maybeUnset(f);
		var cells = graph.assign(all, unset, unset);
		check(cells.nslots == 2 && cells.slotOf.get(a.id) != cells.slotOf.get(b.id), "live arguments shared a cell");
		// Disjoint definitions can share a cell.
		f.args = [];
		f.locals = [a, b].concat(f.locals);
		f.body = vector(SSet(a, ENewObj(cls)), SExpr(ECall(gc, vector())), SExpr(ECall(sink, vector(ELocal(a)))),
			SSet(b, ENewObj(cls)), SExpr(ECall(gc, vector())), SExpr(ECall(sink, vector(ELocal(b)))), SReturn(null));
		graph = Roots.analyze(f);
		unset = Roots.maybeUnset(f);
		cells = graph.assign(f.locals, unset, unset);
		check(cells.nslots == 1 && cells.slotOf.get(a.id) == cells.slotOf.get(b.id), "disjoint roots lost slot sharing");
		f.args = [a];
		f.locals = [];
		f.noGc = true;
		f.body = vector(SExpr(ECall(sink, vector(ELocal(a)))), SReturn(null));
		graph = Roots.analyze(f);
		unset = Roots.maybeUnset(f);
		check(graph.assign(f.args, unset, unset).nslots == 0, "GC-free function retained cells");
		// Returning from a safe region can observe a concurrent collection,
		// although the function's effect summary says it never allocates.
		f.body = vector(SExpr(ECallHost("rt_blocking_leave", vector(), TVoid)),
			SExpr(ECall(sink, vector(ELocal(a)))), SReturn(null));
		graph = Roots.analyze(f);
		check(graph.rooted.get(a.id), "no-allocation summary hid movement at a safe-region return");
		// A blocking call is a collection point even without allocating:
		// another thread can move references while this one is stopped.
		var blocking = new FuncInfo("blocking", "Test");
		blocking.noGc = blocking.blocks = true;
		f.blocks = true;
		f.body = vector(SExpr(ECall(blocking, vector())), SExpr(ECall(sink, vector(ELocal(a)))), SReturn(null));
		graph = Roots.analyze(f);
		check(graph.rooted.get(a.id), "GC-free summary hid a blocking collection point");
		f.noGc = f.blocks = false;
		f.args = [cond];
		f.locals = [a];
		var setA = SSet(a, ENewObj(cls));
		f.body = vector(SIf(ELocal(cond), vector(setA), vector()), SExpr(ECall(gc, vector())),
			SExpr(ECall(sink, vector(ELocal(a)))), SReturn(null));
		graph = Roots.analyze(f);
		check(Roots.maybeUnset(f).get(a.id), "one branch assigned the other branch's mask");
		f.body = vector(SIf(ELocal(cond), vector(setA), vector(setA)), SExpr(ECall(gc, vector())),
			SExpr(ECall(sink, vector(ELocal(a)))), SReturn(null));
		graph = Roots.analyze(f);
		check(!Roots.maybeUnset(f).get(a.id), "assignments in both branches were forgotten");
		f.hasTry = true;
		f.args = [];
		f.locals = [a, caught];
		var readsA:IrCatch = {l: caught, test: null, body: vector(SExpr(ECall(sink, vector(ELocal(a)))))};
		f.body = vector(STry(vector(setA), vector(readsA)), SReturn(null));
		graph = Roots.analyze(f);
		check(Roots.maybeUnset(f).get(a.id), "a try body's assignment initialized its handler's mask");
		Sys.println("root facts: sites, loops, handlers, coloring, initialization and input preservation; MIR compaction passed");
	}
}
