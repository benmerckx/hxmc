package hxmc.ir;

import core.Ast.Binop;
import core.TType;
import core.TFunctions;
import haxe.ds.ObjectMap;

using core.TFunctions;

// Scoped memory (docs/plans/lowlevel.md, "Scoped memory"): the root checker
// and the plan of the data-stack marks of a function.
//
// The checker interprets the typed AST of a function after Haxe's inlining,
// so the hxmc.scoped types' operations are plain Ptr and Mem code by then:
// every expression gets the roots of the memory it may point into (Root),
// which flow through locals, address arithmetic, struct values, loads and
// calls; a store must not put a reference into a variable or memory that
// outlives its root. Calls use the callee's summary (Summary), computed from
// its body on first use. It checks every @:hxmc.scoped function, and every
// other function that touches scoped values (GC code: `gc`), where scoped
// values may not escape into the GC heap.
//
// Scopes: the function's body, each loop (its condition and body) and each
// block in statement position. The plan says which of them allocate, so
// that the lowering (FnLower) marks the data stacks where they start and
// resets them where they end: a function's own scope only when its result
// holds no references (a function returning one leaves what it allocated
// to its caller's scope).

// where memory lives: what bounds its lifetime
class Root {
	public static inline var PARAM = 0; // what the caller passed for parameter `param`
	public static inline var FRESH = 1; // data-stack memory of a scope (at `level`)
	public static inline var FRAME = 2; // the frame (Mem.stack): never returned

	public var kind:Int;
	public var level:Int; // 2 for the function's scope, one more per nested scope
	public var param:Int;
	public var name:String;
	public var weakName = false; // (named after an inlined function's variable)
	public var line:Int;
	// what was stored into this memory (null: not known, then it is bounded
	// by this root itself: a store must outlive the memory it goes into);
	// a parameter's memory is the caller's, whose stores are not seen
	public var held:Null<Array<Root>> = [];

	// WasmGC: an array the representation makes, rooted by the object that
	// keeps it (stores into it unchecked, it outlives everything)
	public static final ANY = {
		var r = new Root(FRESH, 0, -1, "", 0);
		r.held = null;
		r;
	};

	public function new(kind, level, param, name, line) {
		this.kind = kind;
		this.level = level;
		this.param = param;
		this.name = name;
		this.line = line;
	}

	public function describe():String
		return switch kind {
			case PARAM: name;
			case FRAME: '$name (a frame area)';
			case _: (name == "" || weakName ? "a temporary" : name) + ' (made at line $line, memory of ${level > 2 ? "that scope" : "the function"})';
		}
}

// What a call does with roots: the parameters its result may be rooted at,
// whether it may be fresh memory (then the caller's: such a function does
// not reset), whether it leaves memory in the caller's scope, and the stores
// of a parameter's roots (or, src -1, memory it allocates) into another
// parameter's memory
class Summary {
	public var ret:Array<Int> = [];
	public var retFresh = false;
	// the fresh memory a result may reach: per region what it holds (those
	// parameters' roots and those regions; unknown: not known), and the
	// regions the result itself points into (retTop)
	public var retNodes:Array<{params:Array<Int>, held:Array<Int>, unknown:Bool}> = [];
	public var retTop:Array<Int> = [];
	public var allocates = false;
	public var stores:Array<{src:Int, dst:Int}> = [];

	public function new() {}

	public function same(o:Summary):Bool {
		if (retFresh != o.retFresh || allocates != o.allocates || ret.length != o.ret.length || stores.length != o.stores.length) return false;
		if (graph() != o.graph()) return false;
		for (i in ret)
			if (o.ret.indexOf(i) < 0) return false;
		for (s in stores)
			if (!o.hasStore(s.src, s.dst)) return false;
		return true;
	}

	public function graph():String
		return retTop.join(",") + ";" + [for (n in retNodes) n.params.join(",") + "/" + n.held.join(",") + (n.unknown ? "?" : "")].join(";");

	public function hasStore(src:Int, dst:Int):Bool {
		for (s in stores)
			if (s.src == src && s.dst == dst) return true;
		return false;
	}
}

// the marks of a function: of its own scope, of these loops and blocks;
// retRefs: its result holds references (it does not reset when it returns)
typedef Plan = {fnMark:Bool, scopes:ObjectMap<TExpr, Bool>, retRefs:Bool};

private typedef Roots = Array<Root>;

class Scoped {
	// hxmc.rt.DataStacks, the runtime's data stacks (null: the program has
	// none; WasmGC, where scopes end without a reset, has none)
	public static var runtime:Null<TClass> = null;

	static var summaries = new ObjectMap<TClassField, Summary>();
	static var inProgress = new ObjectMap<TClassField, Summary>();
	static var refMemo = new ObjectMap<{}, Int>();
	static var scopedClasses = new ObjectMap<TClass, Bool>();
	public static var unstable = false;

	// a new program (Lower)
	public static function reset(types:Array<ModuleType>) {
		summaries = new ObjectMap();
		inProgress = new ObjectMap();
		refMemo = new ObjectMap();
		scopedClasses = new ObjectMap();
		runtime = null;
		CInterop.objCopy = null;
		Images.reset();
		Soa.reset();
		Soa.setNativeArray(null);
		for (t in types)
			switch t {
				case TClassDecl(c) if (Lower.isNativeArray(c)):
					Soa.setNativeArray(c);
				case TClassDecl(c) if (c.clPath.pack.length == 2 && c.clPath.pack[0] == "hxmc" && c.clPath.pack[1] == "scoped" && (c.clPath.name == "ImageParts" || c.clPath.name == "ImageIO")):
					if (c.clPath.name == "ImageParts") Images.image = c else Images.io = c;
				case TClassDecl(c) if (Lower.wasmGc && c.clPath.name == "W" && c.clPath.pack.join(".") == "hxmc.rt.gc"):
					var cf = c.clStatics.get("objCopy");
					if (cf != null) CInterop.objCopy = {c: c, cf: cf};
				case TClassDecl(c) if (!Lower.wasmGc && c.clPath.name == "DataStacks" && c.clPath.pack.length == 2 && c.clPath.pack[1] == "rt" && c.clPath.pack[0] == "hxmc"):
					runtime = c;
				case _:
			}
	}

	// WasmGC: the objects of the scoped abstractions' representation
	// (docs/plans/lowlevel.md, "Two representations, one core"; @:hxmc.repr)
	// carry roots as struct values do, but are reached by reference: a field
	// stored is a store into their memory; their arrays (NativeArray) are
	// memory as an address's
	public static function isRepr(c:TClass):Bool
		return Lower.wasmGc && c.clMeta.length > 0 && Lower.hasMeta(":hxmc.repr", c.clMeta);

	// a struct value (WasmGC: a scoped class's object, copied as one)
	public static function isValue(c:TClass):Bool
		return CInterop.isStruct(c) || CInterop.isWasmValue(c);

	public static function isReprArray(c:TClass):Bool
		return Lower.wasmGc && Lower.isNativeArray(c);

	public static function isScopedField(c:TClass, cf:TClassField):Bool {
		if (cf.cfMeta.length > 0 && Lower.hasMeta(":hxmc.scoped", cf.cfMeta)) return true;
		var r = scopedClasses.get(c);
		if (r == null) {
			r = core.HxmcScoped.isClass(c);
			scopedClasses.set(c, r);
		}
		return r;
	}

	// checks function tf (cf of class c, null for a closure; scoped: a
	// @:hxmc.scoped one) and plans its marks; null: GC code that touches no
	// scoped value. Throws the first error, at its position ("File.hx:12: ...").
	// (inRuntime: a function of hxmc's runtime, whose GC code may view a String's units)
	public static function check(cf:Null<TClassField>, tf:TFunc, display:String, scoped:Bool, inRuntime = false):Null<Plan> {
		if (!scoped && ((runtime == null && !Lower.wasmGc) || !touches(tf))) return null;
		var a = new Analysis(tf, display, !scoped);
		a.inRuntime = inRuntime;
		a.run();
		if (cf != null && !summaries.exists(cf)) summaries.set(cf, a.summary);
		// (WasmGC: checked the same, no marks: the engine's collector reclaims)
		if (runtime == null) return {fnMark: false, scopes: new ObjectMap(), retRefs: a.retRefs};
		return {fnMark: a.fnAllocates && !a.retRefs, scopes: a.allocScopes, retRefs: a.retRefs};
	}

	// whether GC code tf touches scoped values: a call of a scoped function or
	// of an allocating primitive, a local of a scoped type, a scoped value
	// made (a cheap walk: no other function is analyzed)
	static function touches(tf:TFunc):Bool {
		for (a in tf.tfArgs)
			if (holdsScoped(a.variable.vType)) return true;
		var found = false;
		function loop(e:TExpr) {
			if (found) return;
			switch e.eexpr {
				case TCall({eexpr: TField(_, FStatic(c, cf))}, _) if (isScopedField(c, cf) || cf.cfMeta.length > 0 && Lower.hasMeta(":hxmc.alloc", cf.cfMeta)):
					found = true;
				case TVar(v, _) if (holdsScoped(v.vType)):
					found = true;
				case TFunction(_):
					// (a closure is a function of its own)
				case _:
					core.Texpr.iter(loop, e);
			}
		}
		loop(tf.tfExpr);
		return found;
	}

	// the summary of function cf (its body checked on the way)
	public static function summary(c:TClass, cf:TClassField, scoped:Bool):Summary {
		var s = summaries.get(cf);
		if (s != null) return s;
		var p = inProgress.get(cf);
		if (p != null) {
			// (recursion: what is known so far, computed again until it holds)
			unstable = true;
			return p;
		}
		var tf = switch cf.cfExpr == null ? null : cf.cfExpr.eexpr {
			case TFunction(tf): tf;
			case _: null;
		};
		if (tf == null) return new Summary();
		var cur = new Summary();
		for (_ in 0...16) {
			inProgress.set(cf, cur);
			var outer = unstable;
			unstable = false;
			var a = new Analysis(tf, core.Globals.sTypePath(c.clPath) + "." + cf.cfName, !scoped);
			a.run();
			var again = unstable && !a.summary.same(cur);
			unstable = outer || unstable;
			cur = a.summary;
			if (!again) break;
		}
		inProgress.remove(cf);
		summaries.set(cf, cur);
		return cur;
	}

	public static function at(p:core.Globals.Pos):String {
		var s = CInterop.posOf(p);
		return s == "" ? "" : s + ": ";
	}

	// whether values of type t may hold addresses (Ptr, Grow, Str, Slice,
	// Ref, structs and scoped enums holding one): bit 1; whether they are
	// scoped values holding one (of hxmc.scoped, or a @:hxmc.scoped class or
	// enum holding one): bit 2
	static function refBits(t:T):Int {
		var r = refMemo.get(cast t);
		if (r != null) return r;
		refMemo.set(cast t, 0); // (a cycle: through a value, no reference)
		r = 0;
		var cur = t, scoped = false;
		// (abstracts one at a time: Ptr is an abstract over I64)
		for (_ in 0...16)
			switch TFunctions.follow(cur) {
				case TAbstract(a, params):
					var pack = a.aPath.pack;
					if (pack.length == 2 && pack[0] == "hxmc" && pack[1] == "scoped") scoped = true;
					if (pack.length == 2 && pack[0] == "hxmc" && pack[1] == "unsafe" && (a.aPath.name == "Ptr" || a.aPath.name == "CString")) {
						r = scoped ? 3 : 1;
						break;
					}
					if (core.Meta.has(CoreType, a.aMeta)) break;
					cur = TFunctions.applyParams(a.aParams, params, a.aThis);
				case TInst(c, _) if (CInterop.isStruct(c)):
					r = structBits(c, TFunctions.follow(cur), scoped || scopedType(cur));
					break;
				case TInst(c, _) if (isRepr(c) || CInterop.isWasmValue(c)):
					var rb = 0;
					var k = c;
					while (k != null) {
						for (cf in k.clOrderedFields)
							if (cf.cfKind.match(Var(_))) rb |= refBits(cf.cfType);
						k = k.clSuper == null ? null : k.clSuper.cls;
					}
					r = rb != 0 && (scoped || scopedType(cur)) ? 3 : rb;
					break;
				case TInst(c, _) if (isReprArray(c)):
					r = scoped ? 3 : 1;
					break;
				case TEnum(en, _) if (CInterop.isScopedEnum(en) && !Lower.wasmGc):
					r = structBits(CInterop.enumStruct(en), TFunctions.follow(cur), true);
					break;
				case _:
					break;
			}
		refMemo.set(cast t, r);
		return r;
	}

	// a type of hxmc.scoped, or a @:hxmc.scoped class or enum
	static function scopedType(t:T):Bool {
		for (_ in 0...16)
			switch t {
				case TType(_, _) | TMono(_) | TLazy(_):
					t = TFunctions.follow(t);
				case TAbstract(a, params):
					if (a.aPath.pack.length == 2 && a.aPath.pack[0] == "hxmc" && a.aPath.pack[1] == "scoped") return true;
					if (core.Meta.has(CoreType, a.aMeta)) return false;
					t = core.Abstract.getUnderlyingType(a, params);
				case TInst(c, _):
					return core.HxmcScoped.isClass(c) || c.clPath.pack.length == 2 && c.clPath.pack[0] == "hxmc" && c.clPath.pack[1] == "scoped";
				case TEnum(en, _):
					return CInterop.isScopedEnum(en);
				case _:
					return false;
			}
		return false;
	}

	static function structBits(c:TClass, t:T, scoped:Bool):Int {
		var r = 0;
		switch t {
			case TEnum(en, _):
				for (n in en.eNames)
					switch TFunctions.follow(en.eConstrs.get(n).efType) {
						case TFun(s):
							for (a in s.args)
								r |= refBits(a.type);
						case _:
					}
			case _:
				for (f in CInterop.layout(c).fields)
					if (f.t != null) r |= refBits(f.t);
		}
		return r != 0 && scoped ? 3 : r;
	}

	public static function holdsRefs(t:T):Bool
		return refBits(t) & 1 != 0;

	public static function holdsScoped(t:T):Bool
		return refBits(t) & 2 != 0;

	// whether values of type t carry roots in the analysis (also an I64 made from an address)
	public static function carries(t:T):Bool
		return switch CInterop.ctype(t) {
			case CI64: true;
			case _: holdsRefs(t);
		}
}

// The interpretation of one function body
private class Analysis {
	var tf:TFunc;
	var display:String;
	var gc:Bool; // GC code: scoped values only checked
	var env = new Map<Int, Roots>(); // per local: the roots it holds
	var levels = new Map<Int, Int>(); // per local: the level of its scope
	var literals = new Map<Int, Bool>(); // String locals bound to literals
	var level = 2;
	var scopes:Array<TExpr> = []; // the scopes the current point is in (null: the function's)
	// the roots of fresh memory and frame areas, per expression making them
	// (the same object on every pass), and whether a pass added to what
	// memory holds (another pass then: loads read it)
	var sites = new ObjectMap<TExpr, Root>();
	var callSites = new ObjectMap<TExpr, Array<Root>>();
	var retRoots:Roots = []; // the fresh memory results point into
	var params:Array<Root> = [];
	var changed = false;

	public var summary = new Summary();
	public var retRefs:Bool;
	public var fnAllocates = false;
	public var allocScopes = new ObjectMap<TExpr, Bool>();

	public var inRuntime = false;

	public function new(tf, display, gc) {
		this.tf = tf;
		this.display = display;
		this.gc = gc;
		retRefs = Scoped.holdsRefs(tf.tfType);
	}

	function fail(p:core.Globals.Pos, msg:String):Dynamic {
		// (HXMC_SCOPED_DEBUG: the typed body of a function the checker rejects)
		if (Sys.getEnv("HXMC_SCOPED_DEBUG") != null) Sys.println(core.TPrinting.sExprAst(true, "", t -> core.TPrinting.sTypes(core.ds.VectorTools.vector(t)), tf.tfExpr));
		throw Scoped.at(p) + display + ": " + msg;
	}

	static function lineOf(p:core.Globals.Pos):Int
		return p == null || p.pfile == null ? 0 : CInterop.lineOf(p.pfile, p.pmin);

	public function run() {
		for (_ in 0...16) {
			changed = false;
			env = new Map();
			levels = new Map();
			literals = new Map();
			summary = new Summary();
			fnAllocates = false;
			allocScopes = new ObjectMap();
			retRoots = [];
			pass();
			graph();
			if (!changed) break;
		}
	}

	// the summary's regions: the fresh memory results reach (at most 8,
	// else one holding all that they hold)
	function graph() {
		var index = new ObjectMap<Root, Int>();
		var nodes = summary.retNodes = [];
		function node(r:Root):Int {
			var k = index.get(r);
			if (k != null) return k;
			k = nodes.length;
			index.set(r, k);
			var n = {params: [], held: [], unknown: r.held == null};
			nodes.push(n);
			if (r.held != null)
				for (h in r.held)
					switch h.kind {
						case Root.PARAM:
							if (n.params.indexOf(h.param) < 0) n.params.push(h.param);
						case Root.FRESH:
							var j = node(h);
							if (n.held.indexOf(j) < 0) n.held.push(j);
						case _:
					}
			return k;
		}
		summary.retTop = [for (r in retRoots) node(r)];
		if (nodes.length > 8) {
			var all = {params: [], held: [0], unknown: false};
			for (n in nodes) {
				for (p in n.params)
					if (all.params.indexOf(p) < 0) all.params.push(p);
				all.unknown = all.unknown || n.unknown;
			}
			summary.retNodes = [all];
			summary.retTop = [0];
		}
	}

	function pass() {
		if (gc && Scoped.holdsScoped(tf.tfType))
			fail(tf.tfExpr.epos, 'GC code returns no scoped value holding references: copy it out (toString, a Slice\'s elements) or make the function @:hxmc.scoped');
		for (i in 0...tf.tfArgs.length) {
			var v = tf.tfArgs[i].variable;
			if (!gc && TFunctions.follow(v.vType).match(TFun(_)))
				fail(v.vPos, 'the parameter ${v.vName} is a function: scoped functions take function values only when inline (a compile-time function value)');
			if (!gc && isGcType(v.vType)) fail(v.vPos, 'scoped code holds no GC references: the parameter ${v.vName} is a ${sType(v.vType)}');
			if (params.length <= i) params.push(new Root(Root.PARAM, 1, i, v.vName, lineOf(v.vPos)));
			var r = params[i];
			setVar(v.vId, Scoped.carries(v.vType) ? [r] : []);
			levels.set(v.vId, 2);
		}
		// (the function's body: its own scope)
		switch tf.tfExpr.eexpr {
			case TBlock(es):
				for (x in es)
					stmt(x);
			case _:
				stmt(tf.tfExpr);
		}
	}

	// ---- roots

	static function union(a:Roots, b:Roots):Roots {
		if (b.length == 0) return a;
		if (a.length == 0) return b;
		var r = a.copy();
		for (x in b)
			if (r.indexOf(x) < 0) r.push(x);
		return r;
	}

	static function sameRoots(a:Roots, b:Roots):Bool {
		if (a.length != b.length) return false;
		for (x in a)
			if (b.indexOf(x) < 0) return false;
		return true;
	}

	// the root of what expression e makes (one object per expression)
	function site(e:TExpr, kind:Int, l:Int, name:String):Root {
		var r = sites.get(e);
		if (r == null) {
			r = new Root(kind, l, -1, name, lineOf(e.epos));
			sites.set(e, r);
		}
		return r;
	}

	// fresh memory of the current scope (which therefore allocates), made by e
	function fresh(e:TExpr, name:String):Roots {
		allocated();
		return [site(e, Root.FRESH, level, name)];
	}

	// a load through an address with roots rs: what was stored there
	static function load(rs:Roots):Roots {
		var r:Roots = [];
		for (x in rs)
			r = union(r, x.kind == Root.PARAM || x.held == null ? [x] : x.held);
		return r;
	}

	// what memory with roots ds holds now includes rs
	function hold(ds:Roots, rs:Roots) {
		if (rs.length == 0) return;
		for (d in ds)
			if (d.kind != Root.PARAM && d.held != null)
				for (r in rs)
					if (d.held.indexOf(r) < 0) {
						d.held.push(r);
						changed = true;
					}
	}

	// memory handed to the unchecked layer: what it holds is no longer known
	static function unknown(rs:Roots)
		for (r in rs)
			if (r.kind != Root.PARAM) r.held = null;

	function allocated() {
		if (scopes.length == 0) fnAllocates = true else allocScopes.set(scopes[scopes.length - 1], true);
		summary.allocates = summary.allocates || retRefs;
	}

	// r outlives a variable or memory of level l
	static function outlivesLevel(r:Root, l:Int):Bool
		return r.kind == Root.PARAM ? l >= 1 : r.level <= l;

	// a store of a value with roots rs into a variable of level l (named dst);
	// level 0: the GC heap or a static, which outlive every scope
	function storeVar(rs:Roots, l:Int, dst:String, p:core.Globals.Pos) {
		for (r in rs)
			if (!outlivesLevel(r, l)) fail(p, 'storing a reference rooted at ${r.describe()} into $dst, which outlives it');
	}

	// a store of a value with roots rs into memory with roots ds (none:
	// global memory, which outlives every scope)
	function storeMem(rs:Roots, ds:Roots, dst:String, p:core.Globals.Pos) {
		var into = dst == "" ? "" : dst + ", ";
		if (ds.length == 0) storeVar(rs, 0, into + "memory outside the data stacks", p);
		for (d in ds)
			for (r in rs) {
				if (r == d || d == Root.ANY || r == Root.ANY) continue;
				switch d.kind {
					case Root.PARAM:
						switch r.kind {
							case Root.PARAM:
								if (!summary.hasStore(r.param, d.param)) summary.stores.push({src: r.param, dst: d.param});
							case Root.FRESH if (retRefs):
								// (this function does not reset: its fresh memory is the caller's)
								if (!summary.hasStore(-1, d.param)) summary.stores.push({src: -1, dst: d.param});
							case _:
								fail(p, 'storing a reference rooted at ${r.describe()} into ${into}memory of the caller (${d.name}), which outlives it');
						}
					case _:
						if (!outlivesLevel(r, d.level)) fail(p, 'storing a reference rooted at ${r.describe()} into ${into}memory rooted at ${d.describe()}, which outlives it');
				}
			}
		hold(ds, rs);
	}

	// a value of type `from` (with roots rs) where a value of type `to` is
	// expected: a scoped value holding references becoming anything else
	// (Dynamic, a type parameter, Null<T>, a GC object) escapes the checker
	function convert(rs:Roots, from:T, to:T, what:String, p:core.Globals.Pos) {
		if (Scoped.holdsScoped(from) && !Scoped.carries(to))
			fail(p, '$what: a scoped value holding references (${core.TPrinting.sTypes(core.ds.VectorTools.vector(from))}) cannot become ${core.TPrinting.sTypes(core.ds.VectorTools.vector(to))} (the GC heap): copy it out instead (toString, its elements)');
	}

	// ---- environments (flow: branches merge by union, loops to a fixed point)

	function merge(a:Map<Int, Roots>, b:Map<Int, Roots>):Map<Int, Roots> {
		var r = a.copy();
		for (k => v in b)
			r.set(k, r.exists(k) ? union(r.get(k), v) : v);
		return r;
	}

	// (a local holding no roots has no entry: what a loop compares stays small)
	inline function setVar(id:Int, rs:Roots)
		if (rs.length == 0) env.remove(id) else env.set(id, rs);

	function sameEnv(a:Map<Int, Roots>, b:Map<Int, Roots>):Bool {
		for (k => v in a)
			if (!b.exists(k) || !sameRoots(v, b.get(k))) return false;
		for (k in b.keys())
			if (!a.exists(k)) return false;
		return true;
	}

	// ---- expressions: their roots

	static function strip(e:TExpr):TExpr
		return switch e.eexpr {
			case TParenthesis(e1) | TMeta(_, e1): strip(e1);
			case _: e;
		}

	static function sType(t:T):String
		return core.TPrinting.sTypes(core.ds.VectorTools.vector(t));

	// a GC reference (scoped code holds none)
	static function isGcType(t:T):Bool {
		return switch TFunctions.followWithoutNull(t) {
			case TInst(c, _) if (c.clKind.match(KTypeParameter(_))): true;
			case TInst(c, _): !Scoped.isValue(c) && !CInterop.isOpaque(c) && !Scoped.isRepr(c) && !Scoped.isReprArray(c);
			case TAnon(_) | TDynamic(_) | TFun(_) | TMono(_): true;
			case TEnum(en, _): !CInterop.isScopedEnum(en);
			case TAbstract(a, [p]) if (a.aPath.name == "Null" && a.aPath.pack.length == 0): true;
			case TAbstract(a, _) if (a.aPath.name == "Any" || a.aPath.name == "Class" || a.aPath.name == "Enum" || a.aPath.name == "EnumValue"): a.aPath.pack.length == 0;
			case _: false;
		}
	}

	// a scope: a block in statement position, a loop
	function scope(e:TExpr, f:() -> Void) {
		scopes.push(e);
		level++;
		f();
		level--;
		scopes.pop();
	}

	// e in statement position (its value unused)
	function stmt(e:TExpr) {
		switch e.eexpr {
			// (a block merged into the enclosing one: `var a, b`, and the inlined
			// body of a store of the scoped std, @:hxmc.noScope, so that what its
			// arguments make is the enclosing scope's, as what it stores is)
			case TMeta({meta: core.MetaList.StrictMeta.MergeBlock | core.MetaList.StrictMeta.Custom(":hxmc.noScope")}, {eexpr: TBlock(es)}):
				for (x in es)
					stmt(x);
			case TBlock(es):
				scope(e, () -> for (x in es) stmt(x));
			case TParenthesis(e1) | TMeta(_, e1):
				stmt(e1);
			case TIf(c, a, b):
				ev(c);
				var before = env.copy();
				stmt(a);
				var ea = env;
				env = before;
				if (b != null) stmt(b);
				env = merge(ea, env);
			case TSwitch(sw):
				switchOf(sw, true);
			case TTry(body, catches):
				if (!gc) fail(e.epos, 'scoped code has no try (it cannot throw)');
				var before = env.copy();
				stmt(body);
				var out = env;
				for (c in catches) {
					env = merge(before, out);
					stmt(c.expr);
					out = merge(out, env);
				}
				env = out;
			case _:
				ev(e);
		}
	}

	function switchOf(sw:TSwitch, asStmt:Bool):Roots {
		ev(sw.switchSubject);
		var before = env.copy();
		var out:Null<Map<Int, Roots>> = null;
		var r:Roots = [];
		var bodies = [for (c in sw.switchCases) c.caseExpr];
		if (sw.switchDefault != null) bodies.push(sw.switchDefault);
		for (b in bodies) {
			env = before.copy();
			if (asStmt) stmt(b) else r = union(r, ev(b));
			out = out == null ? env : merge(out, env);
		}
		env = out == null ? before : (sw.switchDefault == null ? merge(out, before) : out);
		return r;
	}

	// e in value position: its roots
	static var trace = Sys.getEnv("HXMC_SCOPED_TRACE") != null;

	function ev(e:TExpr):Roots {
		var r = ev0(e);
		if (trace) Sys.println(display + " " + core.TPrinting.sExprKind(e) + " " + CInterop.lineOf(e.epos.pfile, e.epos.pmin) + " -> [" + [for (x in r) x.name].join(",") + "]");
		return r;
	}

	function ev0(e:TExpr):Roots {
		return switch e.eexpr {
			case TConst(_) | TTypeExpr(_) | TIdent(_) | TBreak | TContinue: [];
			case TLocal(v): env.exists(v.vId) ? env.get(v.vId) : [];
			case TParenthesis(e1) | TMeta(_, e1): ev(e1);
			case TCast(e1, _):
				var r = ev(e1);
				convert(r, e1.etype, e.etype, "a cast", e.epos);
				Scoped.carries(e.etype) ? r : [];
			case TBlock(es):
				// (a block's value: not a scope, its memory the enclosing scope's)
				var r:Roots = [];
				for (k in 0...es.length)
					if (k < es.length - 1) stmt(es[k]) else r = ev(es[k]);
				r;
			case TVar(v, init):
				levels.set(v.vId, level);
				var rs:Roots = [];
				if (init != null) {
					rs = ev(init);
					if (strip(init).eexpr.match(TConst(TString(_)))) literals.set(v.vId, true);
					// (fresh memory first bound to a variable of the source is named
					// after it: an inlined function's variables are declared elsewhere)
					var own = own(v, e);
					for (r in rs)
						if (r.kind == Root.FRESH && (r.name == "" || r.weakName && own)) {
							r.name = v.vName;
							r.weakName = !own;
						}
					convert(rs, init.etype, v.vType, v.vName, e.epos);
				}
				if (!gc && isGcType(v.vType) && !literals.exists(v.vId))
					fail(e.epos, 'scoped code holds no GC references: ${v.vName} is a ${sType(v.vType)}');
				if (!Scoped.carries(v.vType)) rs = [];
				storeVar(rs, level, v.vName, e.epos);
				setVar(v.vId, rs);
				[];
			case TBinop(OpAssign, lhs, rhs):
				var rs = ev(rhs);
				convert(rs, rhs.etype, lhs.etype, "an assignment", e.epos);
				assign(lhs, rs, e);
				rs;
			case TBinop(OpAssignOp(_), lhs, rhs):
				var rs = union(ev(lhs), ev(rhs));
				assign(lhs, rs, e);
				rs;
			case TBinop(OpEq | OpNotEq | OpGt | OpGte | OpLt | OpLte | OpBoolAnd | OpBoolOr, a, b):
				ev(a);
				ev(b);
				[];
			case TBinop(_, a, b):
				var r = union(ev(a), ev(b));
				Scoped.carries(e.etype) ? r : [];
			case TUnop(_, _, e1):
				var r = ev(e1);
				Scoped.carries(e.etype) ? r : [];
			case TField(obj, fa): field(obj, fa, e);
			case TArray(a, i) if (reprArray(a.etype)):
				var r = ev(a);
				ev(i);
				Scoped.carries(e.etype) ? load(r) : [];
			case TArray(a, i):
				var r = ev(a);
				ev(i);
				Scoped.carries(e.etype) ? r : [];
			case TCall(f, args): call(f, args, e);
			case TNew(c, _, args) if (Scoped.isReprArray(c)):
				// (an array of the representation: memory the object that keeps it
				// roots; unchecked itself, as a Grow's array reallocated)
				for (a in args)
					ev(a);
				[Root.ANY];
			case TNew(c, _, args) if (Scoped.isRepr(c) && c.clMeta.length > 0 && Lower.hasMeta(":hxmc.fresh", c.clMeta)):
				// (WasmGC's allocation of scoped memory: fresh memory of the scope, as a data stack's)
				for (a in args)
					ev(a);
				fresh(e, "");
			case TNew(c, _, args):
				if (!Scoped.isValue(c) && !Scoped.isRepr(c)) {
					if (!gc) fail(e.epos, 'scoped code holds no GC references: new ${c.clPath.name} makes an object');
					escapingArgs(args, c.clConstructor == null ? null : c.clConstructor.cfType, e);
					[];
				} else {
					var r:Roots = [];
					for (a in args)
						r = union(r, ev(a));
					r;
				}
			case TIf(c, a, b):
				ev(c);
				var before = env.copy();
				var ra = ev(a);
				var ea = env;
				env = before;
				var rb = b == null ? [] : ev(b);
				env = merge(ea, env);
				union(ra, rb);
			case TSwitch(sw):
				switchOf(sw, false);
			case TWhile(c, body, _):
				scope(e, () -> {
					var start = env.copy(), outer = level;
					for (_ in 0...32) {
						ev(c);
						switch body.eexpr {
							case TBlock(es):
								for (x in es)
									stmt(x);
							case _:
								stmt(body);
						}
						// (the locals declared before the loop: the body's own start again on each iteration)
						var next = start.copy();
						for (k => v in env)
							if (v.length > 0 && (!levels.exists(k) || levels.get(k) < outer)) next.set(k, next.exists(k) ? union(next.get(k), v) : v);
						if (sameEnv(next, start)) break;
						start = next;
						env = start.copy();
					}
					env = start;
				});
				[];
			case TReturn(x):
				if (x != null) {
					var rs = ev(x);
					convert(rs, x.etype, tf.tfType, "the result", e.epos);
					if (Scoped.carries(x.etype)) ret(rs, x);
				}
				[];
			case TFunction(f):
				if (!gc) fail(e.epos, 'a function value in scoped code: only as the argument of an inline function, which inlines it');
				// (GC code: a closure captures no scoped value holding references)
				function cap(x:TExpr)
					switch x.eexpr {
						case TLocal(v) if (levels.exists(v.vId) && Scoped.holdsScoped(v.vType)):
							fail(x.epos, '${v.vName} holds a scoped value with references: a closure cannot capture it (the GC heap)');
						case _: core.Texpr.iter(cap, x);
					}
				cap(f.tfExpr);
				[];
			case TThrow(x):
				if (!gc) fail(e.epos, 'scoped code cannot throw (it is no-GC code: abort with a message instead)');
				convert(ev(x), x.etype, TDynamic(null), "a thrown value", e.epos);
				[];
			case TTry(_):
				stmt(e);
				[];
			case TObjectDecl(fs):
				if (!gc) fail(e.epos, 'scoped code holds no GC references: an anonymous object');
				for (f in fs)
					convert(ev(f.expr), f.expr.etype, TDynamic(null), f.key.name, e.epos);
				[];
			case TArrayDecl(vs):
				if (!gc) fail(e.epos, 'scoped code holds no GC references: an array literal (a Grow or a Slice instead)');
				for (v in vs)
					convert(ev(v), v.etype, TDynamic(null), "an array element", e.epos);
				[];
			case TEnumParameter(e1, _, _):
				var r = ev(e1);
				Scoped.carries(e.etype) ? r : [];
			case TEnumIndex(e1):
				ev(e1);
				[];
		}
	}

	function ret(rs:Roots, x:TExpr) {
		for (r in rs)
			switch r.kind {
				case Root.PARAM:
					if (summary.ret.indexOf(r.param) < 0) summary.ret.push(r.param);
				case Root.FRESH:
					summary.retFresh = true;
					if (retRoots.indexOf(r) < 0) retRoots.push(r);
					// (what it reaches may not be a frame area)
					var seen:Roots = [];
					function reach(m:Root) {
						if (seen.indexOf(m) >= 0 || m.held == null) return;
						seen.push(m);
						for (h in m.held)
							if (h.kind == Root.FRAME) fail(x.epos, 'returning memory that holds a reference rooted at ${h.describe()}, which ends with the function') else reach(h);
					}
					reach(r);
				case _:
					fail(x.epos, 'returning a reference rooted at ${r.describe()}, which ends with the function');
			}
	}

	// lhs = (or op=) a value with roots rs
	function assign(lhs:TExpr, rs:Roots, e:TExpr) {
		if (!Scoped.carries(lhs.etype)) {
			placeEv(lhs);
			return;
		}
		switch strip(lhs).eexpr {
			case TLocal(v):
				storeVar(rs, levels.exists(v.vId) ? levels.get(v.vId) : 2, v.vName, e.epos);
				setVar(v.vId, rs);
			case TField(_, FStatic(_, cf)):
				storeVar(rs, 0, "the static " + cf.cfName, e.epos);
			case TField(obj, FInstance(c, _, cf)) if (Scoped.isValue(c)):
				// (a field of a struct: of a local, a weak update of it; else memory behind an address)
				var v = baseLocal(obj);
				if (v != null && levels.exists(v.vId)) {
					storeVar(rs, levels.get(v.vId), describePlace(lhs), e.epos);
					setVar(v.vId, union(env.exists(v.vId) ? env.get(v.vId) : [], rs));
				} else
					storeMem(rs, placeRoots(obj), describePlace(lhs), e.epos);
			case TField(obj, FInstance(c, _, _)) if (Scoped.isRepr(c)):
				storeMem(rs, ev(obj), describePlace(lhs), e.epos);
			case TField(obj, _):
				// (a field of an object: the GC heap)
				ev(obj);
				storeVar(rs, 0, describePlace(lhs) + " (the GC heap)", e.epos);
			case TArray(a, i) if (reprArray(a.etype)):
				var p = ev(a);
				ev(i);
				storeMem(rs, p, describePlace(lhs), e.epos);
			case TArray(a, i):
				ev(a);
				ev(i);
				storeVar(rs, 0, "an array element (the GC heap)", e.epos);
			case _:
				storeMem(rs, ev(lhs), describePlace(lhs), e.epos);
		}
	}

	// the local a struct place is a field of (of a field of...)
	static function baseLocal(e:TExpr):Null<TVar>
		return switch strip(e).eexpr {
			case TLocal(v): v;
			case TField(o, FInstance(c, _, _)) if (Scoped.isValue(c)): baseLocal(o);
			case _: null;
		}

	// the roots of the memory a struct place is in (its address's, for one
	// reached through an address)
	static function isFixedImpl(c:TClass):Bool
		return switch c.clKind {
			case KAbstractImpl(a): CInterop.isFixed(a);
			case _: false;
		}

	function placeRoots(obj:TExpr):Roots
		return switch strip(obj).eexpr {
			case TCall({eexpr: TField(_, FStatic(c, cf))}, args) if (isPtrImpl(c) && (cf.cfName == "get_value" || cf.cfName == "get")):
				var r = ev(args[0]);
				for (k in 1...args.length)
					ev(args[k]);
				r;
			case TField(o, FInstance(c, _, _)) if (Scoped.isValue(c)): placeRoots(o);
			case TCall({eexpr: TField(a, FInstance(c, _, cf))}, args) if (Scoped.isReprArray(c) && cf.cfName == "unsafeGet"):
				// (an element of a representation's array: in its memory)
				var r = ev(a);
				for (x in args)
					ev(x);
				r;
			case TArray(a, i) if (reprArray(a.etype)):
				var r = ev(a);
				ev(i);
				r;
			case TBlock(es) if (es.length > 0):
				for (k in 0...es.length - 1)
					stmt(es[k]);
				placeRoots(es[es.length - 1]);
			case _: ev(obj);
		}

	// a place's subexpressions evaluated (for their effects)
	function placeEv(lhs:TExpr)
		switch strip(lhs).eexpr {
			case TLocal(_):
			case TField(obj, _): ev(obj);
			case TArray(a, i):
				ev(a);
				ev(i);
			case _: ev(lhs);
		}

	// a place as the source names it ("": none, an inlined function's variable)
	static function describePlace(e:TExpr):String {
		inline function of(s:String, suffix:String):String
			return s == "" ? "" : s + suffix;
		return switch strip(e).eexpr {
			case TLocal(v): own(v, e) ? v.vName : "";
			case TField(obj, fa): of(describePlace(obj), "." + TFunctions.fieldName(fa));
			case TCall(_, args) if (args.length > 0): of(describePlace(args[0]), "'s target");
			case TCast(e1, _): describePlace(e1);
			case TArray(a, _): of(describePlace(a), "[]");
			case _: "";
		}
	}

	// v declared in the source, not by an inlined function (whose
	// expressions have the call's position, its variables their own)
	static function own(v:TVar, at:TExpr):Bool
		return v.vPos == null || at.epos == null || v.vPos.pfile == at.epos.pfile;

	function field(obj:TExpr, fa:TFieldAccess, e:TExpr):Roots {
		return switch fa {
			case FStatic(_, cf):
				if (!gc && cf.cfKind.match(Var(_)) && isGcType(cf.cfType))
					fail(e.epos, 'scoped code holds no GC references: the static ${cf.cfName} is a ${sType(cf.cfType)}');
				[];
			case FEnum(_, _): [];
			case FInstance(c, _, _) if (Scoped.isValue(c) || Scoped.isRepr(c)):
				var r = ev(obj);
				Scoped.carries(e.etype) ? r : [];
			case FInstance(c, _, _) if (Scoped.isReprArray(c)):
				ev(obj);
				[];
			case FInstance(c, _, cf) if (Lower.isCore(c, "String") && cf.cfName == "length"):
				ev(obj);
				[];
			case _:
				ev(obj);
				if (!gc) fail(e.epos, 'scoped code holds no GC references: ${TFunctions.fieldName(fa)} of a ${sType(obj.etype)}');
				[];
		}
	}

	static function reprArray(t:T):Bool
		return switch TFunctions.follow(t) {
			case TInst(c, _): Scoped.isReprArray(c);
			case _: false;
		}

	static function isPtrImpl(c:TClass):Bool
		return switch c.clKind {
			case KAbstractImpl(a): a.aPath.name == "Ptr" && a.aPath.pack.length == 2 && a.aPath.pack[1] == "unsafe";
			case _: false;
		}

	static function isMem(c:TClass):Bool
		return c.clPath.name == "Mem" && c.clPath.pack.length == 2 && c.clPath.pack[1] == "unsafe" && c.clPath.pack[0] == "hxmc";

	static function isString(t:T):Bool
		return switch TFunctions.follow(t) {
			case TInst(c, _): Lower.isCore(c, "String");
			case _: false;
		}

	// arguments of a call of GC code that does not take them as scoped values
	// (or of the unchecked layer: what their memory holds is no longer known)
	function escapingArgs(args:haxe.ds.Vector<TExpr>, ft:Null<T>, e:TExpr, trusted = false) {
		var ps = ft == null ? null : switch TFunctions.follow(ft) {
			case TFun(s): s.args;
			case _: null;
		};
		for (k in 0...args.length) {
			var r = ev(args[k]);
			if (trusted) unknown(r) else convert(r, args[k].etype, ps != null && k < ps.length ? ps[k].type : TDynamic(null), "an argument", e.epos);
		}
	}

	// a store through an address (the last argument into the memory of the first)
	function storeArgs(args:haxe.ds.Vector<TExpr>, e:TExpr):Roots {
		var p = ev(args[0]);
		for (k in 1...args.length - 1)
			ev(args[k]);
		var v = args[args.length - 1];
		var rs = ev(v);
		if (Scoped.carries(v.etype)) storeMem(rs, p, describePlace(args[0]) == "" ? "" : describePlace(args[0]) + "'s target", e.epos);
		return rs;
	}

	function call(f:TExpr, args:haxe.ds.Vector<TExpr>, e:TExpr):Roots {
		switch strip(f).eexpr {
			case TField(_, FStatic(c, cf)) if (isFixedImpl(c) && (cf.cfName == "_new" || cf.cfName == "_hx_new" || !Lower.wasmGc && (cf.cfName == "view" || cf.cfName == "get_length"))):
				// (hxmc.scoped.Fixed, linearly the lowering's: a view is of the
				// memory holding the Fixed, a local's frame area or its holder's)
				if (cf.cfName != "view") {
					for (x in args)
						ev(x);
					return [];
				}
				var x = args[0];
				for (_ in 0...8)
					switch x.eexpr {
						case TCast(y, null) | TParenthesis(y) | TMeta(_, y) if (CInterop.fixedOf(x.etype) == null): x = y;
						case _: break;
					}
				return switch strip(x).eexpr {
					case TLocal(v):
						ev(x);
						[site(e, Root.FRAME, levels.exists(v.vId) ? levels.get(v.vId) : 2, "the Fixed " + v.vName)];
					case _: placeRoots(x);
				};
			case TField(_, FStatic(c, cf)) if (Scoped.isRepr(c)):
				// (WasmGC's representation, trusted: `fresh...` makes scoped
				// memory, fresh as a data stack's; `of` memory rooted at its first
				// argument, a Pool)
				var rs = [for (a in args) ev(a)];
				return StringTools.startsWith(cf.cfName, "fresh") ? fresh(e, "") : cf.cfName == "of" ? union(rs[0], [Root.ANY]) : [];
			case TField(_, FStatic(c, cf)):
				// Ptr's typed access (FnLower.ptrAccess): loads keep the roots
				// of the address, stores are stores into its memory
				if (isPtrImpl(c))
					switch cf.cfName {
						case "set_value" | "set":
							return storeArgs(args, e);
						case _:
							var r = ev(args[0]);
							for (k in 1...args.length)
								ev(args[k]);
							return switch cf.cfName {
								case "get_value" | "get": Scoped.carries(e.etype) ? load(r) : [];
								case _: Scoped.carries(e.etype) ? r : [];
							}
					}
				if (isMem(c))
					switch cf.cfName {
						case "addr":
							var a = strip(args[0]);
							switch a.eexpr {
								case TConst(TString(_)): return [];
								case TLocal(v) if (literals.exists(v.vId)): return [];
								case _ if (!gc):
									fail(e.epos, 'scoped code holds no GC references: Mem.addr of a heap object (a Str views a string literal only: Str.copyOf copies a String)');
								case _ if (isString(a.etype) && !inRuntime):
									fail(e.epos, 'a Str views a string literal only (a String moves with the collector): Str.copyOf copies one');
								case _:
									ev(args[0]);
									return [];
							}
						case "stack":
							return [site(e, Root.FRAME, 2, "the area at line " + lineOf(e.epos))];
						case n if (StringTools.startsWith(n, "set")):
							storeArgs(args, e);
							return [];
						case "getPtr":
							var r = ev(args[0]);
							for (k in 1...args.length)
								ev(args[k]);
							return load(r);
						case _:
							for (a in args)
								ev(a);
							return [];
					}
				if (cf.cfMeta.length > 0 && Lower.hasMeta(":hxmc.alloc", cf.cfMeta)) {
					for (a in args)
						ev(a);
					if (Scoped.carries(e.etype)) return fresh(e, "");
					allocated();
					return [];
				}
				var scoped = Scoped.isScopedField(c, cf);
				var takes = false;
				switch TFunctions.follow(cf.cfType) {
					case TFun(s):
						for (a in s.args)
							if (Scoped.holdsScoped(a.type)) takes = true;
					case _:
				}
				var trusted = c.hasClassFlag(CExtern) || Lower.isUnsafe(cf.cfMeta)
					|| Lower.isUnsafe(c.clMeta) || cf.cfExpr == null;
				// (C keeps no pointer it is passed, unless declared @:hxmc.retains)
				if (trusted && !scoped && CInterop.retains(c, cf)) {
					for (a in args)
						if (ev(a).length > 0)
							fail(a.epos, 'scoped memory passed to ${c.clPath.name}.${cf.cfName}, which keeps the pointer (@:hxmc.retains)');
					return [];
				}
				if (!scoped && (trusted || !takes)) {
					if (!gc && !trusted) fail(e.epos, 'scoped code calls ${c.clPath.name}.${cf.cfName}, which is neither @:hxmc.scoped nor @:hxmc.unsafe');
					// (the trusted no-GC layer, C, GC code taking no scoped value: unchecked, the global root)
					escapingArgs(args, cf.cfType, e, trusted);
					return [];
				}
				var rs = [for (a in args) ev(a)];
				return applySummary(Scoped.summary(c, cf, scoped), rs, args, c.clPath.name + "." + cf.cfName, e);
			case TField(obj, FInstance(c, _, cf)) if (Scoped.isReprArray(c)):
				// (an array of the representation: memory, as an address's)
				var p = ev(obj);
				switch cf.cfName {
					case "unsafeGet":
						ev(args[0]);
						return Scoped.carries(e.etype) ? load(p) : [];
					case "unsafeSet":
						ev(args[0]);
						var rs = ev(args[1]);
						if (Scoped.carries(args[1].etype)) storeMem(rs, p, "", e.epos);
						return [];
					case _:
						for (a in args)
							ev(a);
						return [];
				}
			case TField(obj, FInstance(c, _, cf)) if (Scoped.isValue(c)):
				fail(e.epos, 'a struct has no methods (yet)');
			case TField(_, FEnum(_, _)):
				var r:Roots = [];
				for (a in args)
					r = union(r, ev(a));
				return r;
			case TField(obj, FInstance(c, _, cf)) if (gc):
				// (a method of GC code: its declaration's summary when it takes scoped values)
				ev(obj);
				var takes = false;
				switch TFunctions.follow(cf.cfType) {
					case TFun(s):
						for (a in s.args)
							if (Scoped.holdsScoped(a.type)) takes = true;
					case _:
				}
				if (!takes) {
					escapingArgs(args, cf.cfType, e);
					return [];
				}
				var rs = [for (a in args) ev(a)];
				return applySummary(Scoped.summary(c, cf, false), rs, args, c.clPath.name + "." + cf.cfName, e);
			case _ if (gc):
				ev(f);
				escapingArgs(args, f.etype, e);
				return [];
			case _:
				fail(e.epos, 'scoped code calls only functions known at compile time (no closures, no dynamic or virtual calls)');
		}
		return [];
	}

	function applySummary(s:Summary, rs:Array<Roots>, args:haxe.ds.Vector<TExpr>, name:String, e:TExpr):Roots {
		var r:Roots = [];
		for (i in s.ret)
			if (i < rs.length) r = union(r, rs[i]);
		if (s.allocates) allocated();
		// (what the callee allocates is the caller's, in this scope: its
		// regions as the summary says, one root each, the same on every pass)
		var nodes = callSites.get(e);
		if (nodes == null || nodes.length != s.retNodes.length) {
			nodes = [for (k in 0...s.retNodes.length) new Root(Root.FRESH, level, -1, (s.retTop.indexOf(k) >= 0 ? "the result of " : "memory allocated by ") + name, lineOf(e.epos))];
			callSites.set(e, nodes);
		}
		for (k in 0...nodes.length) {
			var n = s.retNodes[k];
			if (n.unknown) nodes[k].held = null else {
				var h:Roots = [];
				for (i in n.params)
					if (i < rs.length) h = union(h, rs[i]);
				for (j in n.held)
					h = union(h, [nodes[j]]);
				hold([nodes[k]], h);
			}
		}
		for (k in s.retTop)
			r = union(r, [nodes[k]]);
		for (st in s.stores) {
			if (st.dst >= rs.length) continue;
			var src = st.src < 0 ? (nodes.length > 0 ? nodes : [site(e, Root.FRESH, level, "memory allocated by " + name)]) : (st.src < rs.length ? rs[st.src] : []);
			try storeMem(src, rs[st.dst], "", e.epos) catch (msg:String) {
				var k = msg.indexOf("storing ");
				throw Scoped.at(e.epos) + display + ": " + name + " stores " + (st.src < 0 ? "memory it allocates" : "its argument " + describePlace(args[st.src]))
					+ " into the memory of its argument " + describePlace(args[st.dst]) + ": " + (k >= 0 ? msg.substr(k) : msg);
			}
		}
		return Scoped.carries(e.etype) ? r : [];
	}
}
