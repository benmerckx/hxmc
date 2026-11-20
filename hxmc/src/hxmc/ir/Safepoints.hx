package hxmc.ir;

import hxmc.ir.Ir;
import haxe.ds.Vector;
import core.ds.VectorTools.vector;

// Polls the compiler adds (in a program that starts threads, or -D
// hxmc.safepoints=1; =0 none: docs/interop.md "Safepoints"): a
// collection waits for every other thread to reach a safepoint, and a loop or a
// recursion that allocates nothing never does, holding every other thread
// until it ends. A poll is hxmc.Safepoint.poll's: rt_gc_requested read, and
// when it is set the runtime's rt_poll (a GC point). One at the head of each
// loop, and at the entry of each function on a cycle of direct calls (a
// recursion passes one: straight code without either ends soon). Not at every
// calling function's entry: the compiler compiling itself (-D disable-parallelism) 7% slower
// there, 3% faster here.
//
// Only in the functions that reach a GC point already (Facts.findNoGc, before
// this): a no-GC function stays one (a kernel calls it, holding loans no
// collection may move), and so goes without polls; nor in @:hxmc.unsafe code
// (a raw heap address may live across one), in the collector
// (@:hxmc.collects, @:hxmc.blocking), in safe code taking a raw heap address (Mem.addr:
// it may hold one across), or in the runtime's own modules.
class Safepoints {
	// -D hxmc.safepoints=1, or not defined and hxmc.rt.Threads.spawn live (one thread holds no other)
	public static function on(p:Program):Bool
		return p.safepoints == true || (p.safepoints == null && Lambda.exists(p.funcs, f -> f.display == "hxmc.rt.Threads.spawn" && p.isLive(f)));

	// (addr: the functions taking raw heap addresses, Mem.addr, which may hold one across a poll: none)
	public static function insert(p:Program, addr:Array<FuncInfo>) {
		var raw = [for (f in addr) f => true];
		var rec = recursive(p);
		for (f in p.funcs)
			if (!f.polled && p.isLive(f) && !raw.exists(f) && wants(f)) {
				f.polled = true;
				var body = loops(f.body);
				f.body = rec.exists(f) ? prepend(body) : body;
			}
	}

	static function wants(f:FuncInfo):Bool
		return !f.noGc && !f.declUnsafe && !f.declKernel && !f.declBlocking && !f.declNoGc && !f.collects && !f.hostCode
			&& f.cSymbol == null && !StringTools.startsWith(f.module, "hxmc.rt.") && !StringTools.startsWith(f.module, "hxmc.unsafe.")
			&& f.module != "hxmc.rt";

	// if (rt_gc_requested != 0) rt_poll()
	static function poll():Stmt {
		var flag = ECallHost("hxmc_unsafe_Mem_getI32", vector(ECallHost("hxmc_unsafe_Mem_sym", vector(EStr("rt_gc_requested")), TI64), EInt(0)), TI32);
		return SIf(EBin(Ne, flag, EInt(0)), vector(SExpr(ECallHost("rt_poll", vector(), TVoid))), vector());
	}

	static function prepend(b:Vector<Stmt>):Vector<Stmt> {
		var r = new Vector<Stmt>(b.length + 1);
		r[0] = poll();
		for (i in 0...b.length)
			r[i + 1] = b[i];
		return r;
	}

	// every loop's body with a poll first (a `continue` comes back to it too)
	static function loops(b:Vector<Stmt>):Vector<Stmt> {
		var r = new Vector<Stmt>(b.length);
		for (i in 0...b.length)
			r[i] = switch b[i] {
				case SLoop(body): SLoop(prepend(loops(body)));
				case SIf(c, x, y): SIf(c, loops(x), loops(y));
				case SSwitch(e, cases, def): SSwitch(e, Vector.fromArrayCopy([for (k in cases) {values: k.values, body: loops(k.body)}]), loops(def));
				case STry(body, catches): STry(loops(body), Vector.fromArrayCopy([for (k in catches) {test: k.test, l: k.l, body: loops(k.body)}]));
				case s: s;
			}
		return r;
	}

	// the functions on a cycle of direct calls (Tarjan's components, iteratively)
	static function recursive(p:Program):Map<FuncInfo, Bool> {
		var funcs = [for (f in p.funcs) if (p.isLive(f)) f];
		var id = new Map<FuncInfo, Int>();
		for (i in 0...funcs.length)
			id.set(funcs[i], i);
		var n = funcs.length;
		var succ = [for (f in funcs) callees(f.body, id)];
		var index = new Vector<Int>(n), low = new Vector<Int>(n), on = new Vector<Bool>(n);
		for (i in 0...n)
			index[i] = -1;
		var rec = new Map<FuncInfo, Bool>();
		var stack:Array<Int> = [], work:Array<Int> = [], next = 0;
		for (root in 0...n) {
			if (index[root] >= 0) continue;
			var pos:Array<Int> = [];
			work.push(root);
			pos.push(0);
			index[root] = low[root] = next++;
			stack.push(root);
			on[root] = true;
			while (work.length > 0) {
				var v = work[work.length - 1], k = pos[pos.length - 1];
				if (k < succ[v].length) {
					pos[pos.length - 1] = k + 1;
					var w = succ[v][k];
					if (index[w] < 0) {
						index[w] = low[w] = next++;
						stack.push(w);
						on[w] = true;
						work.push(w);
						pos.push(0);
					} else if (on[w] && index[w] < low[v]) low[v] = index[w];
					continue;
				}
				work.pop();
				pos.pop();
				if (work.length > 0) {
					var u = work[work.length - 1];
					if (low[v] < low[u]) low[u] = low[v];
				}
				if (low[v] != index[v]) continue;
				var w = stack.pop();
				on[w] = false;
				if (w != v) {
					rec.set(funcs[w], true);
					do {
						w = stack.pop();
						on[w] = false;
						rec.set(funcs[w], true);
					} while (w != v);
				} else if (succ[v].indexOf(v) >= 0) rec.set(funcs[v], true);
			}
		}
		return rec;
	}

	// the functions the body calls directly (a dispatch's, a closure's: unknown; recursion
	// through them in practice walks a structure, in a loop that polls)
	static function callees(b:Vector<Stmt>, id:Map<FuncInfo, Int>):Array<Int> {
		var r:Array<Int> = [];
		function ex(e:Ex) {
			switch e {
				case ECall(g, _):
					var i = id.get(g);
					if (i != null && r.indexOf(i) < 0) r.push(i);
				case _:
			}
			Facts.iterEx(ex, e);
		}
		function st(s:Stmt)
			Facts.iterStmt(st, ex, s);
		for (s in b)
			st(s);
		return r;
	}
}
