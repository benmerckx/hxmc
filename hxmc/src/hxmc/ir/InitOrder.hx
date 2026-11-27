package hxmc.ir;

import core.TType.TClass;
import hxmc.ir.Ir;
import haxe.ds.ObjectMap;

private typedef InitDispatch = {
	var receiver:ClassInfo;
	var selector:Int;
	var targets:Array<FuncInfo>;
	var scanned:Int;
}

private typedef InitUses = {
	var calls:Array<FuncInfo>;
	var reads:Array<FuncInfo>;
	var allocations:Array<ClassInfo>;
	var dispatches:Array<InitDispatch>;
}

// Refines the compiler's type order using reads of initialized globals in
// lowered code. Native and WASI still run one eager initializer per class.
class InitOrder {
	final p:Program;
	public final initializers = new Map<Int, FuncInfo>();
	final receivers = new ObjectMap<{}, TClass>();
	final uses = new Map<FuncInfo, InitUses>();
	final byReceiver = new Map<ClassInfo, Map<Int, InitDispatch>>();
	final dispatches:Array<InitDispatch> = [];

	public function new(p:Program) {
		this.p = p;
	}

	public function setReceiver(call:Ex, c:TClass)
		receivers.set(cast call, c);

	public function copyReceiver(from:Ex, to:Ex) {
		var c = receivers.get(cast from);
		if (c != null) setReceiver(to, c);
	}

	public function run(classInfo:TClass->Null<ClassInfo>, initOf:Map<FuncInfo, TClass>, typeDeps:Null<Map<TClass, Array<TClass>>>) {
		var inits = p.inits;
		if (inits.length < 2) return;
		discoverCalls(classInfo);
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
				for (init in u.reads) {
					var j = ids.get(init);
					if (j != null && j != i) {
						needed.set(j, true);
						if (j > i) needsSort = true;
					}
				}
				for (g in u.calls)
					if (!seen.exists(g)) work.push(g);
				for (d in u.dispatches)
					for (g in d.targets)
						if (!seen.exists(g)) work.push(g);
			}
			deps.push([for (j in needed.keys()) j]);
		}
		if (!needsSort) return;
		if (typeDeps != null) addTypeDependencies(deps, initOf, typeDeps);
		for (ds in deps)
			ds.sort((a, b) -> a - b);

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

	function addTypeDependencies(deps:Array<Array<Int>>, initOf:Map<FuncInfo, TClass>, typeDeps:Map<TClass, Array<TClass>>) {
		var owners = [for (f in p.inits) initOf.get(f)];
		var ids = [for (i in 0...owners.length) if (owners[i] != null) owners[i] => i];
		for (i in 0...owners.length) {
			var owner = owners[i];
			if (owner == null) continue;
			var classes = [owner];
			var seen = new Map<TClass, Bool>();
			while (classes.length > 0) {
				var c = classes.pop();
				if (seen.exists(c)) continue;
				seen.set(c, true);
				var prereqs = typeDeps.get(c);
				if (prereqs == null) continue;
				for (prereq in prereqs) {
					var j = ids.get(prereq);
					// Walk through classes with no initializer of their own.
					if (j == null) classes.push(prereq) else if (j < i && deps[i].indexOf(j) < 0) deps[i].push(j);
				}
			}
		}
	}

	// A dispatch can reach methods on classes allocated by another initializer,
	// a direct helper or an earlier dispatch. Grow this set from the startup roots.
	function discoverCalls(classInfo:TClass->Null<ClassInfo>) {
		var work = p.inits.copy();
		var allocated = new Map<ClassInfo, Bool>();
		var classes:Array<ClassInfo> = [];
		function allocate(c:ClassInfo) {
			if (allocated.exists(c)) return;
			allocated.set(c, true);
			classes.push(c);
		}
		while (work.length > 0) {
			while (work.length > 0) {
				var f = work.pop();
				if (uses.exists(f)) continue;
				var u = findUses(f, classInfo);
				uses.set(f, u);
				for (g in u.calls)
					if (!uses.exists(g)) work.push(g);
				for (c in u.allocations)
					allocate(c);
			}
			for (d in dispatches) {
				var c = d.receiver, sel = d.selector;
				for (i in d.scanned...classes.length) {
					var cls = classes[i];
					if (c.isInterface ? cls.ifaces.indexOf(c) < 0 : cls.id < c.id || cls.id > c.lastDescendant) continue;
					var m = cls.findMethod(p.selectors[sel].name);
					if (m != null && m.dispatchSel == sel && d.targets.indexOf(m) < 0) {
						d.targets.push(m);
						if (!uses.exists(m)) work.push(m);
					}
				}
				d.scanned = classes.length;
			}
		}
	}

	function findUses(f:FuncInfo, classInfo:TClass->Null<ClassInfo>):InitUses {
		var calls = [], reads = [], allocations = [], dispatched = [];
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
				case ENewObj(c):
					if (allocations.indexOf(c) < 0) allocations.push(c);
				case ECallDispatch(sel, _, args):
					switch origin(args[0]) {
						case ENewObj(cls):
							var g = cls.findMethod(p.selectors[sel].name);
							if (g != null && g.dispatchSel == sel && calls.indexOf(g) < 0) calls.push(g);
						case _:
							var receiver = receivers.get(cast e);
							var c = receiver == null ? null : classInfo(receiver);
							if (c != null) {
								var d = useDispatch(c, sel);
								if (dispatched.indexOf(d) < 0) dispatched.push(d);
							}
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
		return {calls: calls, reads: reads, allocations: allocations, dispatches: dispatched};
	}

	function useDispatch(c:ClassInfo, sel:Int):InitDispatch {
		var bySelector = byReceiver.get(c);
		if (bySelector == null) byReceiver.set(c, bySelector = []);
		var d = bySelector.get(sel);
		if (d == null) {
			d = {receiver: c, selector: sel, targets: [], scanned: 0};
			bySelector.set(sel, d);
			dispatches.push(d);
		}
		return d;
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
