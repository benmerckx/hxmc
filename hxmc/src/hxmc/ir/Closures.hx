package hxmc.ir;

import haxe.ds.Vector;
import hxmc.ir.Ir;

// Which functions a closure call may run (Facts: the effects and fates of
// closure calls). A flow of the program's closures (LambdaInfo) to a fixed
// point, over the places that hold them: locals and parameters, class
// fields, captures, statics and functions' results. What is put anywhere
// else (an array, a structural field, a box, an enum value, Dynamic, a
// runtime function's argument, a throw) goes into one set of escaped
// closures, and what is read from anywhere else is that set; so is what
// code outside the program's sight passes or stores: the parameters of
// lambdas and of functions called by name or from C, fields and statics
// read or written by name, closures made where no body shows it. A set larger than MAX is unknown.
class Closures {
	static inline var MAX = 48;

	var p:Program;
	var names:Map<String, Bool>;
	var impls:Map<Int, Array<FuncInfo>>;
	// per place, the closures (lambda ids, sorted; null: unknown)
	var sets:Array<Null<Array<Int>>> = [[]];
	var locals = new Map<Local, Int>();
	var keyed = new Map<String, Int>();
	var rets = new Map<FuncInfo, Int>();
	var lambdas = new Map<Int, LambdaInfo>();
	var changed = false;
	// the places changed in this round, those the function being walked reads
	var dirty = new Map<Int, Bool>();
	var read:Null<Array<Int>> = null;
	var stamps:Array<Int> = [];
	var serial = 0;

	public var sites = 0; // (stats: closure calls, of them with known functions)
	public var known = 0;

	static inline var ESCAPED = 0;
	static inline var NONE = -1; // (a place no closure is in)

	public function new(p:Program, names:Map<String, Bool>, impls:Map<Int, Array<FuncInfo>>) {
		this.p = p;
		this.names = names;
		this.impls = impls;
		for (l in p.lambdas)
			lambdas.set(l.id, l);
		// (closures made where no body shows it, the runtime's tables: escaped)
		var made = new Map<Int, Bool>();
		function ex(e:Ex) {
			switch e {
				case ENewClos(l, _): made.set(l.id, true);
				case _:
			}
			Facts.iterEx(ex, e);
		}
		function st(s:Stmt)
			Facts.iterStmt(st, ex, s);
		for (f in p.funcs)
			for (s in f.body)
				st(s);
		add(ESCAPED, [for (l in p.lambdas) if (!made.exists(l.id)) l.id]);
		var outside = new Map<FuncInfo, Bool>();
		for (f in p.inits)
			outside.set(f, true);
		for (f in p.roots)
			outside.set(f, true);
		if (p.main != null) outside.set(p.main, true);
		if (p.entryRun != null) outside.set(p.entryRun, true);
		for (f in p.funcs)
			if (f.lambda != null || f.cSymbol != null || f.callback || f.hostCode || f.selfClass != null && byName(f)) outside.set(f, true);
		var rounds = 0;
		changed = true;
		var reads = new Map<FuncInfo, Array<Int>>();
		while (changed && rounds++ < 64) {
			changed = false;
			var was = dirty;
			dirty = [];
			for (f in p.funcs) {
				var r = reads.get(f);
				if (r != null && !Lambda.exists(r, k -> was.exists(k))) continue;
				read = [];
				serial++;
				reads.set(f, read);
				// (called from where this flow does not see: its parameters any
				// escaped closure, its result escapes)
				if (outside.exists(f)) {
					for (a in f.args)
						add(local(a), get(ESCAPED));
					add(ESCAPED, get(ret(f)));
				}
				// (a body out of sight: its result is any escaped closure)
				if (f.hostCode || f.body.length == 0) add(ret(f), get(ESCAPED));
				for (s in f.body)
					stmt(f, s);
			}
		}
		read = null;
		// (not settled: nothing known)
		if (changed)
			for (k in 0...sets.length)
				sets[k] = null;
		function count(e:Ex) {
			switch e {
				case ECallClos(_, c, _):
					sites++;
					if (callees(c) != null) known++;
				case _:
			}
			Facts.iterEx(count, e);
		}
		function countSt(s:Stmt)
			Facts.iterStmt(countSt, count, s);
		for (f in p.funcs)
			for (s in f.body)
				countSt(s);
	}

	// what a closure call through e may run (null: unknown)
	public function callees(e:Ex):Null<Array<LambdaInfo>> {
		var s = value(e, false);
		if (s == null || s.length == 0) return null;
		return [for (id in s) lambdas.get(id)];
	}

	// a method a computed or literal name may reach (Reflect, structural access)
	function byName(f:FuncInfo):Bool {
		if (p.computedNames) return true;
		var d = f.display;
		if (d == null) return true;
		return names.exists(d.substr(d.lastIndexOf(".") + 1));
	}

	// whether a place of type t may hold a closure (others are not followed:
	// what is put there escapes, nothing is read)
	static function holds(t:Ty):Bool
		return t.match(TRef(RClos(_) | RAny | RTag | RAnon));

	function local(l:Local):Int {
		if (!holds(l.ty)) return NONE;
		var k = locals.get(l);
		if (k == null) locals.set(l, k = fresh());
		return k;
	}

	function key(s:String):Int {
		var k = keyed.get(s);
		if (k == null) keyed.set(s, k = fresh());
		return k;
	}

	function ret(f:FuncInfo):Int {
		var k = rets.get(f);
		if (k == null) rets.set(f, k = fresh());
		return k;
	}

	inline function get(k:Int):Null<Array<Int>> {
		if (k == NONE) return [];
		if (read != null) {
			while (stamps.length <= k)
				stamps.push(0);
			if (stamps[k] != serial) {
				stamps[k] = serial;
				read.push(k);
			}
		}
		return sets[k];
	}

	function fresh():Int {
		sets.push([]);
		return sets.length - 1;
	}

	// a field of a class instance, by the class that declares it (fields
	// written by name: escaped closures)
	function field(c:ClassInfo, idx:Int):Int {
		if (!holds(c.fields[idx].ty)) return NONE;
		var d = c;
		while (d.sup != null && idx < d.sup.fields.length)
			d = d.sup;
		var k = key("f" + d.id + ":" + idx);
		if (p.computedNames || names.exists(c.fields[idx].name)) {
			add(k, get(ESCAPED));
			add(ESCAPED, get(k));
		}
		return k;
	}

	function global(g:Int):Int {
		if (!holds(p.globals[g].ty)) return NONE;
		var k = key("g" + g);
		if (p.computedNames || names.exists(p.globals[g].name)) {
			add(k, get(ESCAPED));
			add(ESCAPED, get(k));
		}
		return k;
	}

	inline function capture(l:LambdaInfo, idx:Int):Int
		return key("c" + l.id + ":" + idx);

	// s into place k
	function add(k:Int, s:Null<Array<Int>>) {
		if (k == NONE) k = ESCAPED;
		var t = sets[k];
		if (t == null) return;
		if (s == null) {
			sets[k] = null;
			changed = true;
			dirty.set(k, true);
			return;
		}
		for (x in s)
			if (t.indexOf(x) < 0) {
				if (t.length >= MAX) {
					sets[k] = null;
					changed = true;
					dirty.set(k, true);
					return;
				}
				t.push(x);
				changed = true;
				dirty.set(k, true);
			}
	}

	static function union(a:Null<Array<Int>>, b:Null<Array<Int>>):Null<Array<Int>> {
		if (a == null || b == null) return null;
		if (b.length == 0) return a;
		var r = a.copy();
		for (x in b)
			if (r.indexOf(x) < 0) r.push(x);
		return r.length > MAX ? null : r;
	}

	// what e is put where this flow does not follow
	function sink(e:Ex, flow:Bool) {
		var v = value(e, flow);
		if (flow) add(ESCAPED, v);
	}

	// the closures e may be (flow: what it passes on goes where it goes)
	function value(e:Ex, flow:Bool):Null<Array<Int>> {
		return switch e {
			case ENewClos(l, caps):
				if (flow)
					for (k in 0...caps.length)
						add(capture(l, k), value(caps[k], true));
				[l.id];
			case ELocal(l): get(local(l));
			// (to a closure from a type this flow does not follow: any escaped one too)
			case ECast(t, x): holds(t) && !holds(Ir.typeOf(x)) ? union(value(x, flow), get(ESCAPED)) : value(x, flow);
			case EField(c, idx, o):
				value(o, flow);
				get(field(c, idx));
			case ECapture(l, idx, c):
				value(c, flow);
				get(capture(l, idx));
			case EGlobal(g, _): get(global(g));
			case ECall(g, args):
				for (k in 0...args.length) {
					var v = value(args[k], flow);
					if (flow && k < g.args.length) add(local(g.args[k]), v);
				}
				get(ret(g));
			case ECallDispatch(sel, _, args):
				var l = impls.get(sel);
				var r:Null<Array<Int>> = [];
				for (k in 0...args.length) {
					var v = value(args[k], flow);
					if (flow) {
						if (l == null) add(ESCAPED, v) else for (g in l)
							if (k < g.args.length) add(local(g.args[k]), v);
					}
				}
				if (l == null) get(ESCAPED) else {
					for (g in l)
						r = union(r, get(ret(g)));
					r;
				}
			case ECallClos(_, c, args):
				var s = value(c, flow);
				var vs = [for (a in args) value(a, flow)];
				// (a lambda's parameters take every escaped closure: callers
				// out of sight; what this call passes, they take too)
				if (flow)
					for (v in vs)
						add(ESCAPED, v);
				if (s == null) null else {
					var r:Null<Array<Int>> = [];
					for (id in s) {
						var l = lambdas.get(id);
						if (l == null) return null;
						r = union(r, get(ret(l.fn)));
					}
					r;
				}
			case ENull(_) | EInt(_) | EF64(_) | EStr(_) | EType(_) | ENewObj(_): [];
			case EBin(_, a, b):
				value(a, flow);
				value(b, flow);
				[];
			case ENot(x) | EConv(_, x) | EInstOf(_, x) | EEnumTag(x, _) | EArrLen(x) | EFieldAddr(_, _, x) | ETag(_, x):
				value(x, flow);
				[];
			// (a type parameter's word as a reference: the same reference)
			case EUntag(t, x) if (Ir.isRef(t)): value(x, flow);
			case EEnumParam(_, _, x) | EBoxGet(_, x) | EUnbox(_, x) | EAnonGet(_, _, x, _) | EUntag(_, x):
				value(x, flow);
				get(ESCAPED);
			case EArrGet(_, a, i) | EArrGetU(_, a, i):
				value(a, flow);
				value(i, flow);
				get(ESCAPED);
			case ECallHost(_, args, _) | ENewEnum(_, args) | ENewArr(_, args) | ENewAnon(_, args):
				for (a in args)
					sink(a, flow);
				get(ESCAPED);
			case ECallAnon(_, _, o, args):
				value(o, flow);
				for (a in args)
					sink(a, flow);
				get(ESCAPED);
			case EBox(_, x) | ENewBox(_, x):
				sink(x, flow);
				get(ESCAPED);
		}
	}

	function stmt(f:FuncInfo, s:Stmt) {
		switch s {
			case SSet(l, e): add(local(l), value(e, true));
			case SExpr(e): value(e, true);
			case SSetField(c, idx, o, v):
				value(o, true);
				add(field(c, idx), value(v, true));
			case SSetGlobal(g, v): add(global(g), value(v, true));
			case SReturn(e): if (e != null) add(ret(f), value(e, true));
			case SAnonSet(_, _, o, v) | SBoxSet(_, o, v):
				value(o, true);
				add(ESCAPED, value(v, true));
			case SArrSet(_, _, i, v):
				value(i, true);
				add(ESCAPED, value(v, true));
			case SArrPush(_, _, v) | SThrow(v): add(ESCAPED, value(v, true));
			case SIf(c, a, b):
				value(c, true);
				for (x in a)
					stmt(f, x);
				for (x in b)
					stmt(f, x);
			case SLoop(body):
				for (x in body)
					stmt(f, x);
			case SSwitch(e, cases, def):
				value(e, true);
				for (c in cases)
					for (x in c.body)
						stmt(f, x);
				for (x in def)
					stmt(f, x);
			case STry(body, catches):
				for (x in body)
					stmt(f, x);
				for (c in catches) {
					add(local(c.l), get(ESCAPED));
					for (x in c.body)
						stmt(f, x);
				}
			case SBreak | SContinue | SPos(_):
		}
	}
}
