package hxmc.wasmgc;

import hxmc.ir.Facts;
import hxmc.ir.Ir;
import haxe.ds.Vector;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

// Inlining and scalar replacement on the IR, for the WasmGC path: the native
// and linear-memory paths do both on Mir (hxmc.Inline, then hxmc.Sroa), which
// WasmGC, emitted from the IR, never reaches. A function's optimized body is
// made for each function the module has (GcGen.Uses; the function itself is left as Lower made
// it: the compilation server reuses its body).
//
// Inlining, for scalar replacement only (V8 inlines small functions of a
// WasmGC module itself, but leaves their objects in the heap; inlining more
// here made modules larger, not faster): a direct call to a candidate
// (hxmc.Inline.candidate, the IR test the Mir inliner also uses) that makes
// an object it returns, or is passed a local holding one made here (a
// constructor, a method reading its fields), is replaced by the callee's
// statements, its locals renamed, its parameters the caller's locals passed
// (those it never assigns) or fresh locals set to the arguments; a return at
// the end becomes the assignment of the call's result, returns elsewhere (not
// in a loop of the callee) jumps out of a loop around the copy.
// Inline.DEPTH levels.
//
// Scalar replacement: a local that only ever holds objects allocated in the
// function (one class or one anonymous structure), and is only read through
// its fields, becomes one local per field. Its fields may be written only
// right after the allocation, before anything else names the local (a
// constructor, inlined): a copy (`a = b`) then copies the field locals, and no
// other local sees a later write. WasmGC allocates in the engine's collector,
// where the native targets bump a pointer: for small objects in loops (a
// Complex in mandelbrot) the allocation, its casts and reads are most of the time.
class IrOpt {
	static var on = Sys.getEnv("HXMC_GC_OPT") != "0";

	final inlinables = new Map<FuncInfo, Bool>();
	final makers = new Map<FuncInfo, Bool>(); // functions returning an object they make
	var made:Map<Int, Bool>; // the locals assigned an object made in the function
	var nextId = 0;
	var locals:Array<Local>;
	var stack:Array<FuncInfo> = [];

	public function new() {}

	// f's body and locals as the WasmGC path emits them
	public function run(f:FuncInfo, opt:Bool):{body:Vector<Stmt>, locals:Array<Local>} {
		if (!opt || !on || f.body.length == 0) return {body: f.body, locals: f.locals};
		nextId = 0;
		for (l in f.args)
			if (l.id >= nextId) nextId = l.id + 1;
		for (l in f.locals)
			if (l.id >= nextId) nextId = l.id + 1;
		locals = f.locals.copy();
		stack = [f];
		made = new Map();
		for (s in f.body)
			allocs(s, made);
		var body = inlineAll(f.body, 0);
		body = new Sra(this, f, body).run();
		return {body: body, locals: locals};
	}

	// the statements that can run: an if on a constant (a target's test, Lower's
	// fold) as its branch, nothing after a statement that always leaves (as
	// Mir's dead code is dropped for linear memory: what follows
	// `if (Mem.os() == 3) {...; return;}` is another target's)
	public static function live(ss:Vector<Stmt>):Vector<Stmt> {
		var out = [];
		for (s in ss) {
			switch s {
				case SIf(EInt(c), a, b):
					for (x in live(c != 0 ? a : b))
						out.push(x);
				case SIf(c, a, b): out.push(SIf(c, live(a), live(b)));
				case SLoop(body): out.push(SLoop(live(body)));
				case SSwitch(e, cases, def): out.push(SSwitch(e, cases.map(k -> {values: k.values, body: live(k.body)}), live(def)));
				case STry(body, catches): out.push(STry(live(body), catches.map(c -> {test: c.test, l: c.l, body: live(c.body)})));
				case SCold(id, x):
					var y = live(vector(x));
					if (y.length == 1) out.push(SCold(id, y[0])) else for (z in y) out.push(z);
				case _: out.push(s);
			}
			if (out.length > 0 && leaves(out[out.length - 1])) break;
		}
		return Vector.fromArrayCopy(out);
	}

	static function leaves(s:Stmt):Bool
		return switch s {
			case SReturn(_) | SThrow(_) | SBreak | SContinue: true;
			case SIf(_, a, b): a.length > 0 && b.length > 0 && leaves(a[a.length - 1]) && leaves(b[b.length - 1]);
			case _: false;
		}

	public function fresh(name:String, t:Ty):Local {
		var l = new Local(nextId++, name, t);
		locals.push(l);
		return l;
	}

	public function drop(l:Local)
		locals.remove(l);

	// ---- inlining

	// the locals s assigns an object made there
	static function allocs(s:Stmt, out:Map<Int, Bool>) {
		switch s {
			case SSet(l, ENewObj(_) | ENewAnon(_, _)): out.set(l.id, true);
			case _:
		}
		Facts.iterStmt(x -> allocs(x, out), _ -> {}, s);
	}

	function maker(g:FuncInfo):Bool {
		var r = makers.get(g);
		if (r != null) return r;
		var ls = new Map();
		for (s in g.body)
			allocs(s, ls);
		r = false;
		function st(s:Stmt) {
			switch s {
				case SReturn(ELocal(l)) if (ls.exists(l.id)): r = true;
				case _:
			}
			Facts.iterStmt(st, _ -> {}, s);
		}
		for (s in g.body)
			st(s);
		makers.set(g, r);
		return r;
	}

	function inlinable(g:FuncInfo):Bool {
		var r = inlinables.get(g);
		if (r == null) inlinables.set(g, r = canInline(g));
		return r;
	}

	function canInline(g:FuncInfo):Bool {
		if (!Inline.candidate(g) || g.lambda != null || g.cAbi != null || g.sret || g.body.length == 0) return false;
		for (a in g.args)
			if (a.ty.match(TStruct(_))) return false;
		// (a return in a loop of the callee: its copy cannot jump out of the loop around it)
		var ok = true;
		function st(s:Stmt, inLoop:Bool)
			switch s {
				case SReturn(_) if (inLoop): ok = false;
				case SLoop(body): for (x in body) st(x, true);
				case _: Facts.iterStmt(x -> st(x, inLoop), _ -> {}, s);
			}
		for (s in g.body)
			st(s, false);
		return ok;
	}

	function inlineAll(ss:Vector<Stmt>, depth:Int):Vector<Stmt> {
		var out = [];
		for (s in ss)
			inlineStmt(s, depth, out);
		return Vector.fromArrayCopy(out);
	}

	function inlineStmt(s:Stmt, depth:Int, out:Array<Stmt>) {
		inline function sub(b:Vector<Stmt>)
			return inlineAll(b, depth);
		switch s {
			case SSet(l, ECall(g, args)) if (wanted(g, args, depth)):
				if (maker(g)) made.set(l.id, true);
				expand(g, args, l, depth, out);
			case SExpr(ECall(g, args)) if (wanted(g, args, depth)):
				expand(g, args, null, depth, out);
			case SCold(_, x):
				// (cold sites are the shadow stack's: nothing here)
				inlineStmt(x, depth, out);
			case SIf(c, a, b):
				out.push(SIf(c, sub(a), sub(b)));
			case SLoop(body):
				out.push(SLoop(sub(body)));
			case SSwitch(e, cases, def):
				out.push(SSwitch(e, cases.map(c -> {values: c.values, body: sub(c.body)}), sub(def)));
			case STry(body, catches):
				out.push(STry(sub(body), catches.map(c -> {test: c.test, l: c.l, body: sub(c.body)})));
			case _:
				out.push(s);
		}
	}

	function wanted(g:FuncInfo, args:Vector<Ex>, depth:Int):Bool {
		if (depth >= Inline.DEPTH || stack.contains(g) || !inlinable(g)) return false;
		if (maker(g)) return true;
		for (a in args)
			switch a {
				case ELocal(l) if (made.exists(l.id)): return true;
				case _:
			}
		return false;
	}

	function expand(g:FuncInfo, args:Vector<Ex>, target:Null<Local>, depth:Int, out:Array<Stmt>) {
		var assigned = new Map<Int, Bool>();
		function st(s:Stmt) {
			switch s {
				case SSet(l, _): assigned.set(l.id, true);
				case _:
			}
			Facts.iterStmt(st, _ -> {}, s);
		}
		for (s in g.body)
			st(s);
		var map = new Map<Int, Local>();
		for (k in 0...g.args.length) {
			var p = g.args[k];
			switch args[k] {
				case ELocal(x) if (!assigned.exists(p.id)):
					map.set(p.id, x);
				case a:
					var t = k == 0 && g.selfClass != null ? TRef(RObj(g.selfClass)) : p.ty;
					var x = fresh(p.name, t);
					out.push(SSet(x, k == 0 && g.selfClass != null ? ECast(t, a) : a));
					map.set(p.id, x);
			}
		}
		for (l in g.locals)
			if (!map.exists(l.id)) map.set(l.id, fresh(l.name, l.ty));
		// the returns: at the end only, or anywhere (a loop around the copy, left at each)
		var last = g.body.length - 1;
		while (last >= 0 && g.body[last].match(SPos(_)))
			last--;
		var tail = true;
		function ret(s:Stmt) {
			if (s.match(SReturn(_))) tail = false;
			Facts.iterStmt(ret, _ -> {}, s);
		}
		for (i in 0...last)
			ret(g.body[i]);
		if (last >= 0) switch g.body[last] {
			case SReturn(_):
			case s: ret(s);
		}
		var body = rename(g.body, map, target, !tail);
		for (s in body)
			allocs(s, made);
		stack.push(g);
		body = inlineAll(body, depth + 1);
		stack.pop();
		if (tail) {
			for (s in body)
				out.push(s);
		} else
			out.push(SLoop(body.snoc(SBreak)));
	}

	// the callee's statements in the caller: its locals renamed, its returns the call's result (and a break)
	function rename(ss:Vector<Stmt>, map:Map<Int, Local>, target:Null<Local>, brk:Bool):Vector<Stmt> {
		function loc(l:Local):Local {
			var x = map.get(l.id);
			if (x == null) throw 'hxmc: -D hxmc.wasm-gc: inlining: the local ${l.name} is not declared';
			return x;
		}
		function ex(e:Ex):Ex
			return switch e {
				case ELocal(l): ELocal(loc(l));
				case _: Facts.mapEx(ex, e);
			}
		var st:(Stmt, Array<Stmt>) -> Void = null;
		function sts(ss:Vector<Stmt>):Vector<Stmt> {
			var out = [];
			for (s in ss)
				st(s, out);
			return Vector.fromArrayCopy(out);
		}
		st = (s, out) -> out.push(switch s {
				case SSet(l, e): SSet(loc(l), ex(e));
				case SExpr(e): SExpr(ex(e));
				case SSetField(c, i, o, v): SSetField(c, i, ex(o), ex(v));
				case SAnonSet(n, t, o, v): SAnonSet(n, t, ex(o), ex(v));
				case SArrSet(t, a, i, v): SArrSet(t, loc(a), ex(i), ex(v));
				case SArrPush(t, a, v): SArrPush(t, loc(a), ex(v));
				case SBoxSet(t, b, v): SBoxSet(t, ex(b), ex(v));
				case SSetGlobal(g, v): SSetGlobal(g, ex(v));
				case SIf(c, a, b): SIf(ex(c), sts(a), sts(b));
				case SLoop(body): SLoop(sts(body));
				case SBreak | SContinue | SPos(_): s;
				case SSwitch(e, cases, def): SSwitch(ex(e), cases.map(c -> {values: c.values, body: sts(c.body)}), sts(def));
				case SReturn(e):
					if (e != null) out.push(target != null ? SSet(target, ex(e)) : SExpr(ex(e)));
					if (!brk) return;
					SBreak;
				case SThrow(e): SThrow(ex(e));
				case STry(_, _): throw "hxmc: -D hxmc.wasm-gc: inlining a try";
				case SCold(_, x):
					st(x, out);
					return;
			});
		return sts(ss);
	}
}

// Scalar replacement of one function's objects (IrOpt)
private class Sra {
	final o:IrOpt;
	final f:FuncInfo;
	final body:Vector<Stmt>;
	final parent = new Map<Int, Int>(); // union-find over local ids: the locals one object may pass through
	final bad = new Map<Int, Bool>();
	final allocs = new Map<Int, Array<Ex>>(); // a local's allocations (ENewObj, ENewAnon)
	final byId = new Map<Int, Local>();

	public function new(o, f, body) {
		this.o = o;
		this.f = f;
		this.body = body;
	}

	function find(x:Int):Int {
		var p = parent.get(x);
		if (p == null || p == x) return x;
		var r = find(p);
		parent.set(x, r);
		return r;
	}

	function union(a:Int, b:Int) {
		var ra = find(a), rb = find(b);
		if (ra != rb) parent.set(ra, rb);
	}

	static function base(e:Ex):Null<Local>
		return switch e {
			case ELocal(l): l;
			case ECast(_, x): base(x);
			case _: null;
		}

	public function run():Vector<Stmt> {
		for (a in f.args)
			bad.set(a.id, true);
		for (s in body)
			stmt(s);
		inits(body);
		// the groups: no member escapes, every definition an allocation of one shape or a copy
		var groups = new Map<Int, {kind:Ex, members:Array<Local>}>();
		var badRoot = new Map<Int, Bool>();
		for (id => l in byId) {
			if (!Ir.isRef(l.ty)) bad.set(id, true);
			if (bad.exists(id)) badRoot.set(find(id), true);
		}
		for (id => l in byId) {
			var r = find(id);
			if (badRoot.exists(r)) continue;
			var g = groups.get(r);
			if (g == null) groups.set(r, g = {kind: null, members: []});
			g.members.push(l);
			var as = allocs.get(id);
			if (as != null)
				for (a in as) {
					if (g.kind == null) g.kind = a;
					else if (!sameShape(g.kind, a)) badRoot.set(r, true);
				}
		}
		var fields = new Map<Int, Vector<Local>>(); // per replaced local: a local per field
		var tys = new Map<Int, Array<{name:String, ty:Ty}>>();
		for (r => g in groups) {
			if (badRoot.exists(r) || g.kind == null) continue;
			var fs = fieldsOf(g.kind);
			if (Lambda.exists(fs, x -> x.ty.match(TStruct(_))) || !accessesOk(g.members, fs)) continue;
			for (l in g.members) {
				fields.set(l.id, fs.mapToVector(x -> o.fresh(l.name + "_" + x.name, x.ty)));
				tys.set(l.id, fs);
				o.drop(l);
			}
		}
		if (!fields.keys().hasNext()) return body;
		return new Rewrite(o, fields, tys).stmts(body);
	}

	static function sameShape(a:Ex, b:Ex):Bool
		return switch [a, b] {
			case [ENewObj(c), ENewObj(d)]: c == d;
			case [ENewAnon(s, _), ENewAnon(t, _)]: s == t;
			case _: false;
		}

	// (a layout's references as Dynamic: literals of other types share it, Program.shape)
	public static function fieldsOf(kind:Ex):Array<{name:String, ty:Ty}>
		return switch kind {
			case ENewObj(c): c.fields;
			case ENewAnon(s, _): [for (f in s.fields) {name: f.name, ty: Ir.isRef(f.ty) ? TRef(RAny) : f.ty}];
			case _: throw "unreachable";
		}

	// the accesses name fields of the shape, with their types
	var accesses:Array<{l:Local, a:Access}> = [];

	function accessesOk(members:Array<Local>, fs:Array<{name:String, ty:Ty}>):Bool {
		for (a in accesses) {
			if (!members.contains(a.l)) continue;
			var ok = switch a.a {
				case AField(c, idx): idx < fs.length && fs[idx].name == c.fields[idx].name;
				case AAnon(name, t):
					var k = -1;
					for (i in 0...fs.length)
						if (fs[i].name == name) k = i;
					k >= 0 && Ir.repr(fs[k].ty) == Ir.repr(t);
			}
			if (!ok) return false;
		}
		return true;
	}

	function see(l:Local)
		byId.set(l.id, l);

	function access(l:Local, a:Access) {
		see(l);
		accesses.push({l: l, a: a});
	}

	// the uses: a local named other than as an object whose field is read or written, or copied to another, escapes
	function ex(e:Ex) {
		switch e {
			case ELocal(l):
				see(l);
				bad.set(l.id, true);
			case EField(c, idx, x) if (base(x) != null):
				access(base(x), AField(c, idx));
			case EAnonGet(name, t, x, _) if (base(x) != null):
				access(base(x), AAnon(name, t));
			case _:
				Facts.iterEx(ex, e);
		}
	}

	function stmt(s:Stmt) {
		switch s {
			case SSet(l, e):
				see(l);
				switch e {
					case ENewObj(_):
						add(l, e);
					case ENewAnon(_, vals):
						add(l, e);
						for (v in vals)
							ex(v);
					case _ if (base(e) != null):
						see(base(e));
						union(l.id, base(e).id);
					case _:
						bad.set(l.id, true);
						ex(e);
				}
			case SSetField(c, idx, x, v) if (base(x) != null):
				access(base(x), AField(c, idx));
				ex(v);
			case SAnonSet(name, t, x, v) if (base(x) != null):
				access(base(x), AAnon(name, t));
				ex(v);
			case SArrSet(_, a, _, _) | SArrPush(_, a, _):
				see(a);
				bad.set(a.id, true);
				Facts.iterStmt(stmt, ex, s);
			case STry(_, catches):
				for (c in catches) {
					see(c.l);
					bad.set(c.l.id, true);
				}
				Facts.iterStmt(stmt, ex, s);
			case _:
				Facts.iterStmt(stmt, ex, s);
		}
	}

	function add(l:Local, e:Ex) {
		var a = allocs.get(l.id);
		if (a == null) allocs.set(l.id, a = []);
		a.push(e);
	}

	// a field written other than right after the local's allocation: the object stays
	function inits(ss:Vector<Stmt>) {
		var open = new Map<Int, Bool>();
		for (s0 in ss) {
			var s = switch s0 {
				case SCold(_, x): x;
				case _: s0;
			}
			switch s {
				case SPos(_):
				case SSetField(_, _, x, v) | SAnonSet(_, _, x, v) if (base(x) != null):
					var l = base(x);
					if (!open.exists(l.id)) bad.set(l.id, true);
					names(SExpr(v), open);
				case SSet(l, ENewObj(_) | ENewAnon(_, _)):
					names(SSet(l, ENull(l.ty)), open);
					open.set(l.id, true);
				case _:
					names(s, open);
			}
			switch s {
				case SIf(_, a, b):
					inits(a);
					inits(b);
				case SLoop(body):
					inits(body);
				case SSwitch(_, cases, def):
					for (c in cases)
						inits(c.body);
					inits(def);
				case STry(body, catches):
					inits(body);
					for (c in catches)
						inits(c.body);
				case _:
			}
		}
	}

	// the locals s names close their initialization
	static function names(s:Stmt, open:Map<Int, Bool>) {
		function ex(e:Ex) {
			switch e {
				case ELocal(l): open.remove(l.id);
				case _:
			}
			Facts.iterEx(ex, e);
		}
		function st(s:Stmt) {
			switch s {
				case SSet(l, _) | SArrSet(_, l, _, _) | SArrPush(_, l, _): open.remove(l.id);
				case STry(_, cs): for (c in cs) open.remove(c.l.id);
				case _:
			}
			Facts.iterStmt(st, ex, s);
		}
		st(s);
	}
}

private enum Access {
	AField(c:ClassInfo, idx:Int);
	AAnon(name:String, t:Ty);
}

// the replaced locals' statements on their field locals
private class Rewrite {
	final o:IrOpt;
	final fields:Map<Int, Vector<Local>>;
	final tys:Map<Int, Array<{name:String, ty:Ty}>>;

	public function new(o, fields, tys) {
		this.o = o;
		this.fields = fields;
		this.tys = tys;
	}

	static function base(e:Ex):Null<Local>
		return switch e {
			case ELocal(l): l;
			case ECast(_, x): base(x);
			case _: null;
		}

	function replaced(e:Ex):Null<Local> {
		var l = base(e);
		return l != null && fields.exists(l.id) ? l : null;
	}

	function fieldLocal(l:Local, name:String):{l:Local, ty:Ty} {
		var fs = tys.get(l.id);
		for (i in 0...fs.length)
			if (fs[i].name == name) return {l: fields.get(l.id)[i], ty: fs[i].ty};
		throw "unreachable";
	}

	function read(l:Local, name:String, t:Ty):Ex {
		var x = fieldLocal(l, name);
		return Ir.repr(x.ty) == Ir.repr(t) && Ir.isScalar(t) ? ELocal(x.l) : ECast(t, ELocal(x.l));
	}

	function ex(e:Ex):Ex
		return switch e {
			case EField(c, idx, x) if (replaced(x) != null): read(replaced(x), c.fields[idx].name, c.fields[idx].ty);
			case EAnonGet(name, t, x, _) if (replaced(x) != null): read(replaced(x), name, t);
			case _: Facts.mapEx(ex, e);
		}

	public function stmts(ss:Vector<Stmt>):Vector<Stmt> {
		var out = [];
		for (s in ss)
			stmt(s, out);
		return Vector.fromArrayCopy(out);
	}

	function stmt(s:Stmt, out:Array<Stmt>) {
		switch s {
			case SSet(l, e) if (fields.exists(l.id)):
				var fs = fields.get(l.id);
				switch e {
					case ENewObj(c):
						for (i in 0...fs.length)
							out.push(SSet(fs[i], ENull(fs[i].ty)));
					case ENewAnon(sh, vals):
						// (all values first: they may read the fields being replaced)
						var tmps = [for (i in 0...fs.length) o.fresh(fs[i].name, fs[i].ty)];
						for (i in 0...fs.length)
							out.push(SSet(tmps[i], ex(vals[i])));
						for (i in 0...fs.length)
							out.push(SSet(fs[i], ELocal(tmps[i])));
					case _:
						var src = fields.get(replaced(e).id);
						if (src != fs)
							for (i in 0...fs.length)
								out.push(SSet(fs[i], ELocal(src[i])));
				}
			case SSetField(c, idx, x, v) if (replaced(x) != null):
				out.push(SSet(fieldLocal(replaced(x), c.fields[idx].name).l, ex(v)));
			case SAnonSet(name, _, x, v) if (replaced(x) != null):
				out.push(SSet(fieldLocal(replaced(x), name).l, ex(v)));
			case SSet(l, e): out.push(SSet(l, ex(e)));
			case SExpr(e): out.push(SExpr(ex(e)));
			case SSetField(c, i, x, v): out.push(SSetField(c, i, ex(x), ex(v)));
			case SAnonSet(n, t, x, v): out.push(SAnonSet(n, t, ex(x), ex(v)));
			case SArrSet(t, a, i, v): out.push(SArrSet(t, a, ex(i), ex(v)));
			case SArrPush(t, a, v): out.push(SArrPush(t, a, ex(v)));
			case SBoxSet(t, b, v): out.push(SBoxSet(t, ex(b), ex(v)));
			case SSetGlobal(g, v): out.push(SSetGlobal(g, ex(v)));
			case SIf(c, a, b): out.push(SIf(ex(c), stmts(a), stmts(b)));
			case SLoop(body): out.push(SLoop(stmts(body)));
			case SBreak | SContinue | SPos(_): out.push(s);
			case SSwitch(e, cases, def): out.push(SSwitch(ex(e), cases.map(c -> {values: c.values, body: stmts(c.body)}), stmts(def)));
			case SReturn(e): out.push(SReturn(e == null ? null : ex(e)));
			case SThrow(e): out.push(SThrow(ex(e)));
			case STry(body, catches): out.push(STry(stmts(body), catches.map(c -> {test: c.test, l: c.l, body: stmts(c.body)})));
			case SCold(id, x):
				var xs = [];
				stmt(x, xs);
				for (y in xs)
					out.push(y);
		}
	}
}
