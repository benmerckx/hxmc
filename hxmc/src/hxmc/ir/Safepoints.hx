package hxmc.ir;

import hxmc.ir.Ir;
import haxe.ds.Vector;
import core.ds.VectorTools.vector;

// Polls the compiler adds (-D hxmc.safepoints, docs/interop.md "Safepoints"): a
// collection waits for every other thread to reach a safepoint, and a loop or a
// recursion that allocates nothing never does, holding every other thread
// until it ends. A poll is hxmc.Safepoint.poll's: rt_gc_requested read, and
// when it is set the runtime's rt_poll (a GC point). One at the head of each
// loop, and at the entry of each function that calls another (a recursion
// passes one: straight code without either ends soon).
//
// Only in the functions that reach a GC point already (Facts.findNoGc, before
// this): a no-GC function stays one (a kernel calls it, holding loans no
// collection may move), and so goes without polls; nor in @:hxmc.unsafe code
// (a raw heap address may live across one), in the collector
// (@:hxmc.collects, @:hxmc.blocking), in safe code taking a raw heap address (Mem.addr:
// it may hold one across), or in the runtime's own modules.
class Safepoints {
	// (addr: the functions taking raw heap addresses, Mem.addr, which may hold one across a poll: none)
	public static function insert(p:Program, addr:Array<FuncInfo>) {
		var raw = [for (f in addr) f => true];
		for (f in p.funcs)
			if (!f.polled && p.isLive(f) && !raw.exists(f) && wants(f)) {
				f.polled = true;
				var body = loops(f.body);
				f.body = calls(body) ? prepend(body) : body;
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

	// whether the body calls a function (not one of the runtime's by name: the intrinsics, allocation)
	static function calls(b:Vector<Stmt>):Bool {
		var found = false;
		function ex(e:Ex) {
			if (found) return;
			switch e {
				case ECall(_, _) | ECallDispatch(_, _, _) | ECallClos(_, _, _) | ECallAnon(_, _, _, _): found = true;
				case _: Facts.iterEx(ex, e);
			}
		}
		function st(s:Stmt) {
			if (!found) Facts.iterStmt(st, ex, s);
		}
		for (s in b)
			st(s);
		return found;
	}
}
