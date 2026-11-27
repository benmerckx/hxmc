package hxmc.ir;

import core.TType.TClass;
import hxmc.ir.Ir;
import haxe.ds.ObjectMap;

// Refines the compiler's type order using reads of initialized globals in
// lowered code. Native and WASI still run one eager initializer per class.
class InitOrder {
	final p:Program;
	public final initializers = new Map<Int, FuncInfo>();
	final receivers = new ObjectMap<{}, TClass>();
	final uses = new Map<FuncInfo, {calls:Array<FuncInfo>, reads:Array<FuncInfo>}>();
	final dispatches = new Map<ClassInfo, Map<Int, Array<FuncInfo>>>();

	public function new(p:Program) {
		this.p = p;
	}

	public function setReceiver(call:Ex, c:TClass)
		receivers.set(cast call, c);

	public function copyReceiver(from:Ex, to:Ex) {
		var c = receivers.get(cast from);
		if (c != null) setReceiver(to, c);
	}

	public function run(classInfo:TClass->Null<ClassInfo>) {
		var inits = p.inits;
		var ids = [for (i in 0...inits.length) inits[i] => i];
		var deps:Array<Array<Int>> = [];
		var needsSort = false;
		for (i in 0...inits.length) {
			var seen = new Map<FuncInfo, Bool>();
			var needed = new Map<Int, Bool>();
			var work = [inits[i]];
			while (work.length > 0) {
				var f = work.pop();
				if (seen.exists(f)) continue;
				seen.set(f, true);
				var u = uses.get(f);
				if (u == null) {
					u = findUses(f, classInfo);
					uses.set(f, u);
				}
				for (init in u.reads) {
					var j = ids.get(init);
					if (j != null && j != i) {
						needed.set(j, true);
						if (j > i) needsSort = true;
					}
				}
				for (g in u.calls)
					if (!seen.exists(g)) work.push(g);
			}
			var ds = [for (j in needed.keys()) j];
			ds.sort((a, b) -> a - b);
			deps.push(ds);
		}
		if (!needsSort) return;

		// A dependency cycle has no valid order. Keep its members in their
		// original relative order, while still satisfying edges between cycles.
		var components = stronglyConnected(deps);
		var last = new Map<Int, Int>();
		var previous:Array<Null<Int>> = [];
		for (i in 0...components.length) {
			var c = components[i];
			previous.push(last.get(c));
			last.set(c, i);
		}
		var emitted = [for (_ in inits) false];
		var ordered = [];
		function emit(i:Int) {
			if (emitted[i]) return;
			emitted[i] = true;
			var prev = previous[i];
			if (prev != null) emit(prev);
			for (j in deps[i])
				if (components[i] != components[j]) emit(j);
			ordered.push(inits[i]);
		}
		for (i in 0...inits.length)
			emit(i);
		p.inits = ordered;
	}

	function findUses(f:FuncInfo, classInfo:TClass->Null<ClassInfo>):{calls:Array<FuncInfo>, reads:Array<FuncInfo>} {
		var calls = [], reads = [];
		// Single assignments let us resolve fresh objects and local closures
		// through the temporaries introduced by lowering.
		var values = new Map<Local, Null<Ex>>();
		for (a in f.args)
			values.set(a, null);
		function gather(s:Stmt) {
			switch s {
				case SSet(l, e): values.set(l, values.exists(l) ? null : e);
				case STry(_, catches):
					for (c in catches)
						values.set(c.l, null);
				case _:
			}
			Facts.iterStmt(gather, _ -> {}, s);
		}
		for (s in f.body)
			gather(s);

		function origin(e:Null<Ex>):Null<Ex> {
			var remaining = f.locals.length + f.args.length + 1;
			while (remaining-- > 0)
				switch e {
					case ELocal(l): e = values.get(l);
					case ECast(_, x): e = x;
					case _: return e;
				}
			return null;
		}
		function visit(e:Ex) {
			switch e {
				case EGlobal(g, _):
					var init = initializers.get(g);
					if (init != null && reads.indexOf(init) < 0) reads.push(init);
				case ECall(g, _):
					if (calls.indexOf(g) < 0) calls.push(g);
				case ECallDispatch(sel, _, args):
					switch origin(args[0]) {
						case ENewObj(cls):
							var g = cls.findMethod(p.selectors[sel].name);
							if (g != null && g.dispatchSel == sel && calls.indexOf(g) < 0) calls.push(g);
						case _:
							var receiver = receivers.get(cast e);
							var c = receiver == null ? null : classInfo(receiver);
							if (c != null)
								for (g in targets(c, sel))
									if (calls.indexOf(g) < 0) calls.push(g);
					}
				case ECallClos(_, clos, _):
					switch origin(clos) {
						case ENewClos(l, _) if (calls.indexOf(l.fn) < 0): calls.push(l.fn);
						case _:
					}
				case _:
			}
			Facts.iterEx(visit, e);
		}
		function stmt(s:Stmt)
			Facts.iterStmt(stmt, visit, s);
		for (s in f.body)
			stmt(s);
		return {calls: calls, reads: reads};
	}

	function targets(c:ClassInfo, sel:Int):Array<FuncInfo> {
		var bySelector = dispatches.get(c);
		if (bySelector == null) dispatches.set(c, bySelector = []);
		var methods = bySelector.get(sel);
		if (methods != null) return methods;
		methods = [];
		var name = p.selectors[sel].name;
		for (cls in p.classes) {
			if (c.isInterface ? cls.ifaces.indexOf(c) < 0 : cls.id < c.id || cls.id > c.lastDescendant) continue;
			var m = cls.findMethod(name);
			if (m != null && m.dispatchSel == sel && methods.indexOf(m) < 0) methods.push(m);
		}
		bySelector.set(sel, methods);
		return methods;
	}

	// Tarjan's algorithm on the initializer graph.
	static function stronglyConnected(deps:Array<Array<Int>>):Array<Int> {
		var index = [for (_ in deps) -1], component = index.copy(), low = index.copy();
		var stack:Array<Int> = [];
		var next = 0;
		function connect(v:Int) {
			index[v] = low[v] = next++;
			stack.push(v);
			for (w in deps[v]) {
				if (index[w] < 0) {
					connect(w);
					if (low[w] < low[v]) low[v] = low[w];
				} else if (component[w] < 0 && index[w] < low[v]) low[v] = index[w];
			}
			if (low[v] == index[v]) {
				var w;
				do {
					w = stack.pop();
					component[w] = v;
				} while (w != v);
			}
		}
		for (v in 0...deps.length)
			if (index[v] < 0) connect(v);
		return component;
	}
}
