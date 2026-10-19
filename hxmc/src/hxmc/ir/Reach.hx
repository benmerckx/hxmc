package hxmc.ir;

import hxmc.ir.Ir;

// The functions the program can run, from what the lowering made (Lower
// lowers every method of every class it sees: Haxe's default DCE keeps the
// fields of user classes, and the method tables reach them all): a rapid
// type analysis over the IR (docs/hxmc.md, "Reachability"). The roots: main,
// the exported functions, @:keep methods (Program.roots) and the static
// initializers that set no static. A function is live when live code calls
// it directly or makes a closure of it; a static initializer when live code
// uses a static it sets; a method also when it can be called on an
// instance: its class or a subclass is instantiated by live code and either
// live code dispatches on its selector (virtual and interface calls) or its
// name can reach a lookup that finds methods (structural and Dynamic access,
// Reflect.field, the runtime's own lookups such as toString's). A static
// function is reached by name through its class value likewise.
//
// Names: those of structural and Dynamic access, the literals passed to the
// runtime's lookups of a name or to a function passing its parameter on to
// one (Reflect.field, Reflect.getProperty's "get_" + field, ...), and names
// the runtime's own tables give (Reflect.fields, Type.getInstanceFields: they
// name only what the tables have, so a dropped method is not among them). A
// name computed any other way can be any name: every method of the
// instantiated classes stays then. Type.createEmptyInstance instantiates the
// classes whose class value live code has, every class when it can also
// resolve a class by its name (Type.resolveClass).
//
// A target that transforms the bodies first (WasmGC's IrOpt inlines) runs it
// again over them: what was inlined everywhere is dropped.
//
// A target whose code calls the runtime's exported functions only for some
// constructs (WasmGC: GcGen.runtimeCalls) names them per construct: the
// runtime's exports are then live where live code has such a construct, not
// roots.
//
// The program keeps its classes, enums and globals (type indices, layouts);
// what the analysis drops: the functions no live code can reach (Program.funcs
// keeps the live ones, Program.live tells), the closure types of dead
// closures, the layouts of object literals live code neither makes nor
// reads, the method-table entries and dispatch rows of dead methods (Facts,
// DataGen) and the rows of selectors no live code dispatches on.
class Reach {
	var p:Program;
	var live = new Map<FuncInfo, Bool>();
	var work:Array<FuncInfo> = [];
	var inst:Array<Bool>; // by class id
	var valueClasses = new Map<ClassInfo, Bool>(); // class values (EType) in live code
	var shapes = new Map<ShapeInfo, Bool>(); // the object literals' layouts live code makes or reads
	var selLive:Array<Bool>;
	var names = new Map<String, Bool>();
	var anyName:Null<String> = null; // the function passing a computed name, once one does
	var setters = new Map<Int, Array<FuncInfo>>(); // global -> the static initializers setting it
	// (f, i): f passes its parameter i on to a lookup by name (findSinks)
	var sinks = new Map<FuncInfo, Array<Int>>();
	var methodSinks = new Map<FuncInfo, Array<{j:Int, pre:String}>>(); // (the name looked up: pre + the argument)
	var arraySinks = new Map<FuncInfo, Array<Int>>();
	var stats:Bool;
	var pending:Array<{name:String, m:FuncInfo}> = []; // methods not live yet
	var emptyInstance = false; // Type.createEmptyInstance (Dyn.createEmpty) is live
	var resolveType = false; // Type.resolveClass (Dyn.resolveType) is live
	var typeOfValue = false; // Type.getClass (Dyn.getClass) is live: statics through it
	// HXMC_REACH_WHY=<function name>: why it is live (what reached it, and so on back to a root)
	var whyName = Sys.getEnv("HXMC_REACH_WHY");
	var cur:Null<FuncInfo> = null; // the function being scanned
	var why = new Map<FuncInfo, {from:Null<FuncInfo>, how:String}>();
	var instBy = new Map<Int, Null<FuncInfo>>();

	// the runtime functions the target's code for an expression or statement calls (by symbol), or null
	var calls:Null<RuntimeCalls>;
	var bySymbol = new Map<String, FuncInfo>();

	// the body analyzed (a target's own form of it: WasmGC's after IrOpt), else the function's
	var bodyOf:Null<FuncInfo->Array<Stmt>>;

	function new(p:Program, stats:Bool, calls:Null<RuntimeCalls>, bodyOf:Null<FuncInfo->Array<Stmt>>) {
		this.p = p;
		this.stats = stats;
		this.calls = calls;
		this.bodyOf = bodyOf;
	}

	inline function body(f:FuncInfo):Array<Stmt>
		return bodyOf == null ? f.body : bodyOf(f);

	// (HXMC_REACH=0: every function stays, as the lowering made them)
	public static function run(p:Program, stats:Bool, ?calls:RuntimeCalls, ?bodyOf:FuncInfo->Array<Stmt>) {
		var r = new Reach(p, stats, calls, bodyOf);
		r.analyze();
		if (r.whyName != null) r.explain();
		if (Sys.getEnv("HXMC_REACH") == "0") return;
		r.apply();
	}

	// the runtime functions the analysis knows (FuncInfo.name)
	static inline var NAMES_FID_SLOW = "hxmc_rt_Names_fidSlow";
	static inline var NAMES_FID_FIND = "hxmc_rt_Names_fidFind";
	static inline var NAMES_FID_STR = "hxmc_rt_Names_fidStr";
	static inline var DYN_GET = "hxmc_rt_Dyn_dynGet";
	static inline var DYN_CALL_FIELD = "hxmc_rt_Dyn_dynCallField";
	// (-D hxmc.wasm-gc: its runtime's lookup of a field, static or method by name)
	static inline var GC_FIND = "hxmc_rt_gc_GcNative_find";
	static inline var STR_CONCAT = "hxmc_rt_Str_concat";
	static inline var STR_OR_NULL = "hxmc_rt_Str_orNull";
	// the functions returning names from the tables: those of the fields,
	// methods or statics of a type or object, of an enum's constructors
	static var TABLE_ARRAYS = [
		"hxmc_rt_Dyn_namesArray", "hxmc_rt_Dyn_instanceFields", "hxmc_rt_Dyn_fields", "hxmc_rt_Dyn_enumCtorNames", "Reflect_fields",
		"Type_getInstanceFields", "Type_getClassFields", "Type_getEnumConstructs"
	];

	function analyze() {
		inst = [for (_ in p.classes) false];
		selLive = [for (_ in p.selectors) false];
		for (i in 0...p.classes.length)
			if (p.classes[i].id != i) throw "hxmc: reach: classes out of order";
		findSinks();
		for (f in p.inits) {
			var gs = globalsOf(f);
			for (g in gs) {
				var a = setters.get(g);
				if (a == null) setters.set(g, a = []);
				if (a.indexOf(f) < 0) a.push(f);
			}
			// (an initializer setting no static: there for what else it does)
			if (gs.length == 0) mark(f);
		}
		mark(p.main);
		for (f in p.roots)
			mark(f);
		for (f in p.funcs)
			if (f.cSymbol != null) {
				// (the runtime's, with RuntimeCalls: where live code needs them)
				if (calls != null && StringTools.startsWith(f.module, "hxmc.rt.")) bySymbol.set(f.cSymbol, f) else mark(f);
			}
		for (c in p.classes)
			for (name => m in c.methods)
				if (!live.exists(m)) pending.push({name: name, m: m});
		while (true) {
			while (work.length > 0)
				scan(work.pop());
			if (emptyInstance)
				for (c in p.classes)
					if (resolveType || valueClasses.exists(c)) instantiate(c);
			for (c in p.classes)
				if (resolveType || typeOfValue || valueClasses.exists(c)) statics(c);
			// the methods callable on an instance now
			var n = p.classes.length;
			var below = [for (_ in 0...n + 1) 0]; // instantiated classes with an id below k
			for (i in 0...n)
				below[i + 1] = below[i] + (inst[i] ? 1 : 0);
			var rest = [];
			for (x in pending) {
				var m = x.m, c = m.selfClass;
				if (live.exists(m)) continue;
				var callable = below[c.lastDescendant + 1] > below[c.id]
					&& ((m.dispatchSel >= 0 && selLive[m.dispatchSel]) || anyName != null || names.exists(x.name));
				if (callable) {
					if (whyName != null) {
						var k = c.id;
						while (!inst[k]) k++;
						var by = instBy.get(k);
						why.set(m, {from: by, how: (m.dispatchSel >= 0 && selLive[m.dispatchSel] ? "dispatched" : "by name") + " on " + p.classes[k].name + ", made in "});
					}
					mark(m);
				} else rest.push(x);
			}
			pending = rest;
			cur = null;
			if (work.length == 0) break;
		}
	}

	function apply() {
		p.live = live;
		p.funcs = [for (f in p.funcs) if (live.exists(f)) f];
		p.inits = [for (f in p.inits) if (live.exists(f)) f];
		p.lambdas = [for (l in p.lambdas) if (live.exists(l.fn)) l];
		p.shapes = [for (s in p.shapes) if (shapes.exists(s)) s];
		p.liveSelectors = selLive;
		if (stats)
			Sys.println('hxmc: reach: ${p.funcs.length} live functions'
				+ (anyName != null ? ', every method name (a name computed in $anyName)' : ', ${Lambda.count(names)} method names'));
	}

	function explain() {
		for (f in p.funcs)
			if (nameOf(f) == whyName || f.name == whyName) {
				var k = f, n = 0;
				Sys.println("hxmc: reach: why " + nameOf(f) + (live.exists(f) ? "" : ": not live"));
				while (k != null && n++ < 100) {
					var w = why.get(k);
					Sys.println("  " + nameOf(k) + (w == null ? "" : " <- " + w.how + (w.from == null ? "(a root)" : "")));
					k = w == null ? null : w.from;
				}
			}
	}

	function mark(f:Null<FuncInfo>) {
		if (f == null || live.exists(f)) return;
		live.set(f, true);
		if (whyName != null && !why.exists(f)) why.set(f, {from: cur, how: ""});
		work.push(f);
		if (f.dfltEntry != null) mark(f.dfltEntry);
	}

	function instantiate(c:ClassInfo) {
		if (inst[c.id]) return;
		inst[c.id] = true;
		if (whyName != null) instBy.set(c.id, cur);
	}

	// the static functions reached by name through c's class value (DataGen's statics table)
	function statics(c:ClassInfo) {
		if (c.statics != null)
			for (s in c.statics)
				if (s.clos != null && !live.exists(s.clos.fn) && (anyName != null || names.exists(s.name))) mark(s.clos.fn);
	}

	// the globals a static initializer sets (its class's statics)
	function globalsOf(f:FuncInfo):Array<Int> {
		var gs = [];
		function st(s:Stmt) {
			switch s {
				case SSetGlobal(g, _): gs.push(g);
				case _:
			}
			Facts.iterStmt(st, _ -> {}, s);
		}
		for (s in body(f))
			st(s);
		return gs;
	}

	// ---- names

	// Where a function's string parameters go, from the runtime's lookups (a
	// fixpoint over the direct calls): `sinks`, a parameter passed on to a
	// lookup of a name (Names.fidSlow, Names.fidFind: its literals are names);
	// `methodSinks`, to a lookup that may find a method (Dyn.dynGet,
	// Dyn.dynCallField: Reflect.field, Reflect.callMethod's target, Dynamic
	// access; setting, testing or deleting a field never runs one);
	// `arraySinks`, an array parameter whose elements go to such a lookup
	function findSinks() {
		for (f in p.funcs)
			switch f.name {
				case NAMES_FID_SLOW | NAMES_FID_FIND: add(sinks, f, 0);
				case DYN_GET | DYN_CALL_FIELD | GC_FIND: addMethod(f, 1, "");
				case _:
			}
		// (the direct calls, in the order of the bodies, found once: the rounds go over them)
		var sites:Array<{f:FuncInfo, g:FuncInfo, args:Array<Ex>}> = [];
		for (f in p.funcs) {
			function ex(e:Ex) {
				switch e {
					case ECall(g, args): sites.push({f: f, g: g, args: args});
					case _:
				}
				Facts.iterEx(ex, e);
			}
			function st(s:Stmt)
				Facts.iterStmt(st, ex, s);
			for (s in body(f))
				st(s);
		}
		var changed = true;
		while (changed) {
			changed = false;
			for (site in sites) {
				var f = site.f, g = site.g, args = site.args;
				for (k in at(sinks, g)) {
					var j = paramOf(f, args[k]);
					if (j >= 0 && add(sinks, f, j)) changed = true;
				}
				for (s in atMethod(g)) {
					var x = args[s.j];
					var j = paramOf(f, x);
					if (j >= 0 && addMethod(f, j, s.pre)) changed = true;
					// ("get_" + field: Reflect.getProperty)
					var c = concatOf(f, x);
					if (c != null) {
						var j = paramOf(f, c.rest);
						if (j >= 0 && addMethod(f, j, s.pre + c.pre)) changed = true;
					}
					var a = s.pre == "" ? elementOf(f, x) : null;
					var j = a == null ? -1 : paramOf(f, a);
					if (j >= 0 && add(arraySinks, f, j)) changed = true;
				}
				for (k in at(arraySinks, g)) {
					var j = paramOf(f, args[k]);
					if (j >= 0 && add(arraySinks, f, j)) changed = true;
				}
			}
		}
	}

	static function add(m:Map<FuncInfo, Array<Int>>, f:FuncInfo, j:Int):Bool {
		var a = m.get(f);
		if (a == null) m.set(f, a = []);
		if (a.indexOf(j) >= 0) return false;
		a.push(j);
		return true;
	}

	static function at(m:Map<FuncInfo, Array<Int>>, f:FuncInfo):Array<Int> {
		var a = m.get(f);
		return a == null ? [] : a;
	}

	function addMethod(f:FuncInfo, j:Int, pre:String):Bool {
		var a = methodSinks.get(f);
		if (a == null) methodSinks.set(f, a = []);
		if (Lambda.exists(a, s -> s.j == j && s.pre == pre)) return false;
		a.push({j: j, pre: pre});
		return true;
	}

	function atMethod(f:FuncInfo):Array<{j:Int, pre:String}> {
		var a = methodSinks.get(f);
		return a == null ? [] : a;
	}

	// e as a literal followed by something (through casts and copies): the two, else null
	function concatOf(f:FuncInfo, e:Ex):Null<{pre:String, rest:Ex}> {
		return switch value(f, e) {
			case ECall(g, [a, rest]) if (g.name == STR_CONCAT):
				switch value(f, a) {
					case EStr(pre): {pre: pre, rest: rest};
					case _: null;
				}
			case _: null;
		}
	}

	// what e is, through casts, the conversions to String of a String and the
	// locals assigned once (not parameters)
	function value(f:FuncInfo, e:Ex):Ex {
		for (_ in 0...16)
			switch e {
				case ECast(_, x) | EUnbox(_, x): e = x;
				case ECall(g, [x]) if (g.name == STR_OR_NULL): e = x;
				case ELocal(l) if (f.args.indexOf(l) < 0):
					var ds = defs(f).get(l);
					if (ds == null || ds.length != 1) return e;
					e = ds[0];
				case _: return e;
			}
		return e;
	}

	// the values assigned to each local of f
	var defsCache = new Map<FuncInfo, Map<Local, Array<Ex>>>();

	function defs(f:FuncInfo):Map<Local, Array<Ex>> {
		var m = defsCache.get(f);
		if (m != null) return m;
		m = new Map();
		var m2 = m;
		function st(s:Stmt) {
			switch s {
				case SSet(l, e):
					var a = m2.get(l);
					if (a == null) m2.set(l, a = []);
					a.push(e);
				case STry(_, catches):
					for (c in catches)
						m2.set(c.l, [ENull(c.l.ty)]);
				case _:
			}
			Facts.iterStmt(st, _ -> {}, s);
		}
		for (s in body(f))
			st(s);
		defsCache.set(f, m);
		return m;
	}

	// e, as a parameter of f never assigned (through casts and copies): its index, else -1
	function paramOf(f:FuncInfo, e:Ex):Int {
		return switch value(f, e) {
			case ELocal(l): defs(f).exists(l) ? -1 : f.args.indexOf(l);
			case _: -1;
		}
	}

	// e as an element of an array (value): the array, else null
	function elementOf(f:FuncInfo, e:Ex):Null<Ex> {
		return switch value(f, e) {
			case EArrGet(_, a, _) | EArrGetU(_, a, _): a;
			case _: null;
		}
	}

	// a name passed to a lookup, in f: a literal (a name), a parameter passed on
	// (a sink of f: its callers are looked at), else, for a lookup that may find
	// a method, a name taken from the runtime's own tables (the name of a field
	// or method the program has: Reflect.fields, Type.getInstanceFields) or any
	// name at all
	function nameArg(f:FuncInfo, e:Ex, method:Bool, pre = "") {
		switch value(f, e) {
			case EStr(s):
				names.set(pre + s, true);
				return;
			case _:
		}
		if (!method) return;
		var j = paramOf(f, e);
		if (j >= 0 && Lambda.exists(atMethod(f), s -> s.j == j && s.pre == pre)) return;
		var c = concatOf(f, e);
		if (c != null) {
			var j = paramOf(f, c.rest);
			if (j >= 0 && Lambda.exists(atMethod(f), s -> s.j == j && s.pre == pre + c.pre)) return;
			switch value(f, c.rest) {
				case EStr(s):
					names.set(pre + c.pre + s, true);
					return;
				case _:
			}
		}
		if (pre == "" && tableName(f, e, 0)) return;
		computed(f);
	}

	function computed(f:FuncInfo) {
		if (anyName == null) anyName = nameOf(f);
		if (stats) Sys.println("hxmc: reach: a name computed in " + nameOf(f));
	}

	// e, in f, is a name from the runtime's tables or a literal (a name)
	function tableName(f:FuncInfo, e:Ex, depth:Int):Bool {
		if (depth > 16) return false;
		return switch e {
			case EStr(s):
				names.set(s, true);
				true;
			case ECast(_, x) | EUnbox(_, x): tableName(f, x, depth + 1);
			case ECall(g, [x]) if (g.name == STR_OR_NULL): tableName(f, x, depth + 1);
			case ECall(g, _): g.name == NAMES_FID_STR;
			case EArrGet(_, a, _) | EArrGetU(_, a, _): tableArray(f, a, depth + 1);
			case ELocal(l):
				var j = f.args.indexOf(l);
				var ds = defs(f).get(l);
				if (j >= 0) ds == null && Lambda.exists(atMethod(f), s -> s.j == j && s.pre == "") else ds != null && !Lambda.exists(ds, d -> !tableName(f, d, depth + 1));
			case _: false;
		}
	}

	// e, in f, is an array of names from the runtime's tables
	function tableArray(f:FuncInfo, e:Ex, depth:Int):Bool {
		if (depth > 16) return false;
		return switch e {
			case ECast(_, x): tableArray(f, x, depth + 1);
			case ECall(g, _): TABLE_ARRAYS.indexOf(g.name) >= 0;
			case ELocal(l):
				var j = f.args.indexOf(l);
				var ds = defs(f).get(l);
				if (j >= 0) ds == null && at(arraySinks, f).indexOf(j) >= 0 else ds != null && !Lambda.exists(ds, d -> !tableArray(f, d, depth + 1));
			case _: false;
		}
	}

	// an array passed on, in f, whose elements go to a lookup that may find a
	// method: from the runtime's tables, else any name
	function arrayArg(f:FuncInfo, e:Ex) {
		var j = paramOf(f, e);
		if (j >= 0 && at(arraySinks, f).indexOf(j) >= 0) return;
		if (!tableArray(f, e, 0)) computed(f);
	}

	// a static used by f: the initializers setting it run
	function setBy(g:Int, f:FuncInfo) {
		var a = setters.get(g);
		if (a != null)
			for (i in a)
				if (i != f) mark(i);
	}

	static function nameOf(f:FuncInfo):String
		return f.display != null ? f.display : f.name;

	function scan(f:FuncInfo) {
		cur = f;
		switch f.name {
			case "hxmc_rt_Dyn_createEmpty" | "hxmc_rt_gc_GcNative_createEmpty": emptyInstance = true;
			case "hxmc_rt_Dyn_resolveType" | "hxmc_rt_gc_GcNative_resolveType": resolveType = true;
			case "hxmc_rt_Dyn_getClass" | "hxmc_rt_gc_GcNative_getClass": typeOfValue = true;
			case _:
		}
		inline function runtime(sym:Null<String>)
			if (sym != null) mark(bySymbol.get(sym));
		function ex(e:Ex) {
			if (calls != null) runtime(calls.ex(e));
			switch e {
				case ECall(g, args):
					mark(g);
					for (k in at(sinks, g))
						nameArg(f, args[k], false);
					for (s in atMethod(g))
						nameArg(f, args[s.j], true, s.pre);
					for (k in at(arraySinks, g))
						arrayArg(f, args[k]);
				case ECallDispatch(sel, _, _):
					selLive[sel] = true;
				case ECallAnon(n, _, _, _):
					names.set(n, true);
				case EAnonGet(n, t, _, hint):
					// (a method only where the field's type is a function's or Dynamic:
					// a class's method unifies with no other structural field)
					if (t.match(TRef(RClos(_) | RAny))) names.set(n, true);
					if (hint != null) shapes.set(hint, true);
				case ENewAnon(s, _):
					shapes.set(s, true);
				case ECallHost("hx_dyn_get" | "hx_dyn_call_field", args, _):
					nameArg(f, args[1], true);
				case ECallHost("hx_dyn_set", args, _):
					nameArg(f, args[1], false);
				case ENewObj(c):
					instantiate(c);
				case ENewClos(l, _):
					mark(l.fn);
				case EType(TRClass(c)):
					valueClasses.set(c, true);
				case EGlobal(g, _):
					setBy(g, f);
				case _:
			}
			Facts.iterEx(ex, e);
		}
		function st(s:Stmt) {
			if (calls != null) runtime(calls.stmt(s));
			switch s {
				case SSetGlobal(g, _):
					setBy(g, f);
				case _:
			}
			Facts.iterStmt(st, ex, s);
		}
		for (s in body(f))
			st(s);
	}
}

// the symbols of the runtime functions a target's code calls for an expression, a statement (null: none)
typedef RuntimeCalls = {ex:Ex->Null<String>, stmt:Stmt->Null<String>};
