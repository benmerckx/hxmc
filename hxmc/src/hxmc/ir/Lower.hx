package hxmc.ir;

import hxmc.ir.Ir;
import core.Ast.Binop;
import core.Ast.Unop;
import core.TType;
import core.MetaList.StrictMeta;
import core.TFunctions;

using core.TFunctions;

// Lowers the filtered typed AST (the data HXB serializes) of everything
// reachable from `main` to the IR (docs/hxmc.md).
//
// Representation (see Ir.hx): Int/Bool/Float and haxe.Int64 unboxed;
// everything else is a pointer. Generics are erased: a type parameter is Dynamic (RAny), and values
// are converted (boxed, unboxed, wrapped in adapter closures) where a declared
// type and a use-site type differ: calls, returns, field and enum-argument
// access (FnLower.coerce).
class Lower {
	var prog = new Program();
	var classes = new Map<TClass, ClassInfo>();
	var enums = new Map<TEnum, EnumInfo>();
	var funcs = new Map<TClassField, FuncInfo>();
	var ctors = new Map<TClass, FuncInfo>();
	var pending:Array<() -> Void> = [];
	var tclasses:Array<TClass> = [];
	var subclasses = new Map<TClass, Array<TClass>>(); // per class: its subclasses in tclasses, in that order
	var root:ClassInfo;
	var usedSelectors = new Map<String, Int>();
	public var defaults = new Map<FuncInfo, Array<Null<TExpr>>>();
	// the variables of the arguments `defaults` belong to (null: the
	// receiver): a default value may read the arguments before it (FnLower.defaultValue)
	public var argVars = new Map<FuncInfo, Array<Null<TVar>>>();

	public function new() {
		root = new ClassInfo("Object", "Object", null);
		prog.classes.push(root);
	}

	// the program's basic types (the coroutine types: Coroutine below)
	static var basic:core.TType.BasicTypes;

	// follows `t`, a coroutine type as the function taking the continuation
	public static function followFun(t:T):T
		return switch TFunctions.followWithCoro(t) {
			case Coro(s): TFun(context.Common.expandCoroType(basic, s.args, s.ret));
			case NotCoro(t): t;
		}

	// `l`: a subclass to lower with (hxmc's resident compiler passes one that
	// reuses function bodies across builds, see `lowerBody`); otherwise none
	public static function program(main:TClass, types:Array<core.TType.ModuleType>, basic:core.TType.BasicTypes, ?l:Lower):Program {
		Lower.basic = basic;
		if (l == null) l = new Lower();
		var mainField = main.clStatics.get("main");
		l.prog.main = l.staticFunc(main, mainField);
		l.findHosts(types);
		l.drain();
		l.finish();
		// static initializers run in the order of com.types, which
		// Finalization.sortTypes arranged for static initialization
		var order = new Map<TClass, Int>();
		for (i in 0...types.length)
			switch types[i] {
				case TClassDecl(c): order.set(c, i);
				case _:
			}
		var pos = (fi:FuncInfo) -> {
			var c = l.initOf.get(fi);
			c != null && order.exists(c) ? order.get(c) : types.length;
		};
		l.prog.inits.sort((a, b) -> pos(a) - pos(b));
		if (survey) l.writeSurvey();
		return l.prog;
	}

	// ---- survey mode (HXMC_SURVEY=file): record unsupported constructs, keep going

	public static var survey = Sys.getEnv("HXMC_SURVEY") != null;
	// -debug: statements carry their source lines (Stmt.SPos)
	public static var lines = false;
	public var errors = new Map<String, {count:Int, example:String}>();
	public var natives = new Map<String, Int>(); // runtime functions called, with counts

	public function record(e:LowerError, fn:String) {
		var r = errors.get(e.msg);
		if (r == null) errors.set(e.msg, {count: 1, example: fn + " " + e.where}) else r.count++;
	}

	function writeSurvey() {
		var keys = [for (k in errors.keys()) k];
		keys.sort((a, b) -> errors.get(b).count - errors.get(a).count);
		var out = new StringBuf();
		for (k in keys)
			out.add('${errors.get(k).count}\t$k\t${errors.get(k).example}\n');
		var ns = [for (k in natives.keys()) k];
		ns.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		out.add('\n${ns.length} natives:\n');
		for (k in ns)
			out.add('${natives.get(k)}\t$k\n');
		out.add('\n${prog.funcs.length} functions, ${prog.classes.length} classes, ${prog.enums.length} enums, ${prog.shapes.length} shapes, ${prog.lambdas.length} lambdas\n');
		sys.io.File.saveContent(Sys.getEnv("HXMC_SURVEY"), out.toString());
	}

	public function guarded(fi:FuncInfo, f:() -> Void):() -> Void {
		return () -> {
			try f() catch (e:LowerError) {
				if (!survey) throw e.toString();
				record(e, fi.name);
				fi.body = [SThrow(ENull(TRef(RAny)))];
			}
			bindHosts(fi);
		}
	}

	// ---- the runtime in Haxe (docs/hxmc.md, "Runtime in Haxe")

	// runtime functions implemented in Haxe: @:hxmc.export("name") (also
	// called by the runtime's C code: always compiled, under that symbol) and
	// @:hxmc.host("name") (compiled when called) on static functions of the
	// hxmc package's classes; generated code's calls of `name` (ECallHost)
	// become calls of them (bindHosts). @:hxmc.export on a static function of
	// any other class: the program's own entry point under that symbol (a
	// shared library's export, Abi.exports), always compiled.
	var hostImpls = new Map<String, {c:TClass, cf:TClassField}>();

	function findHosts(types:Array<core.TType.ModuleType>) {
		for (t in types)
			switch t {
				case TClassDecl(c) if (!c.hasClassFlag(CExtern) && !(c.clPath.pack.length > 0 && c.clPath.pack[0] == "hxmc")):
					for (cf in c.clOrderedStatics)
						if (cf.cfMeta.length > 0 && cf.cfKind.match(Method(_)) && hasMeta(":hxmc.export", cf.cfMeta)) {
							var n = metaString(":hxmc.export", cf.cfMeta);
							if (hostImpls.exists(n)) fail("two Haxe functions exported as " + n);
							hostImpls.set(n, {c: c, cf: cf});
							staticFunc(c, cf);
						}
				case TClassDecl(c) if (c.clPath.pack.length > 0 && c.clPath.pack[0] == "hxmc" && !c.hasClassFlag(CExtern)):
					// @:hxmc.android: the Android targets' only (Mem.target() 9 and 10)
					if (hasMeta(":hxmc.android", c.clMeta) && targetCode >= 0 && targetCode < 9) continue;
					// @:hxmc.ios: the iOS targets' only (Mem.platform() 1 and 2)
					if (hasMeta(":hxmc.ios", c.clMeta) && targetPlatform >= 0 && targetPlatform < 1) continue;
					// @:hxmc.wasm: the runtime of WebAssembly only (what C provides elsewhere)
					if (hasMeta(":hxmc.wasm", c.clMeta) && targetOs != 3) continue;
					// @:hxmc.native: the runtime of the native targets only (over C libraries)
					if (hasMeta(":hxmc.native", c.clMeta) && targetOs == 3) continue;
					// @:hxmc.wasmgc: the runtime of -D hxmc.wasm-gc only; @:hxmc.anyHeap: of
					// both (written over hxmc.rt.Repr); the others of linear memory only
					if (hasMeta(":hxmc.wasmgc", c.clMeta) != wasmGc && !hasMeta(":hxmc.anyHeap", c.clMeta)) continue;
					// @:hxmc.os("windows"): the runtime of one system only
					var os = metaString(":hxmc.os", c.clMeta);
					if (os != null && targetOs >= 0 && ["linux", "macos", "windows", "wasm"].indexOf(os) != targetOs) continue;
					for (cf in c.clOrderedStatics) {
						if (cf.cfMeta.length == 0) continue;
						// (an exported variable: data read by its symbol, always there)
						if (!cf.cfKind.match(Method(_))) {
							if (hasMeta(":hxmc.export", cf.cfMeta)) staticVar(c, cf);
							continue;
						}
						var n = metaString(":hxmc.export", cf.cfMeta);
						var exported = n != null;
						if (n == null) n = metaString(":hxmc.host", cf.cfMeta);
						if (n == null) continue;
						if (hostImpls.exists(n)) fail("two Haxe implementations of the runtime's " + n);
						hostImpls.set(n, {c: c, cf: cf});
						if (exported) staticFunc(c, cf);
					}
				case _:
			}
	}

	// the Haxe implementation of runtime function `name`, lowered on first use
	public function hostImpl(name:String):Null<FuncInfo> {
		var h = hostImpls.get(name);
		return h == null ? null : staticFunc(h.c, h.cf);
	}

	// the target (Mem.os, Mem.arm: constants here, so that the code of the
	// other targets is dropped with the branch it is in; -1: unknown)
	public static var targetOs = -1;
	public static var targetArm = -1;
	public static var targetCode = -1;
	public static var targetPlatform = -1; // (Mem.platform: Abi.platformCode)
	// -D hxmc.wasm-gc (hxmc.wasmgc): the runtime's Haxe implementations are those of @:hxmc.wasmgc classes
	public static var wasmGc = false;
	// the program's resources (--resource), haxe.Resource's content: each
	// one's name and data in base64, in genjs's order (Main.generate)
	public static var resources:Array<{name:String, data:String}> = [];
	// -D hxmc.native-array-outofbounds: what an access of a NativeArray
	// (haxe.ds.Vector) at an index out of bounds does (FnLower.nativeRead)
	public static var bounds = BOUNDS_UNCHECKED;
	public static inline var BOUNDS_UNCHECKED = 0; // not tested (unspecified)
	public static inline var BOUNDS_THROWS = 1; // haxe.exceptions.ArgumentException (rt/NArray.outOfBounds)
	public static inline var BOUNDS_SILENT = 2; // a read gives the element type's default, a write does nothing

	// a condition on the target (Mem.os, Mem.arm, Mem.target compared with
	// constants) as a constant (EInt), when it is one: FnLower lowers only
	// the branch it takes (the other target's functions are not reached)
	public static function targetConst(e:Ex):Null<Int> {
		function v(e:Ex):Null<Int>
			return switch e {
				case EInt(n): n;
				case ECallHost("hxmc_unsafe_Mem_os", [], _) if (targetOs >= 0): targetOs;
				case ECallHost("hxmc_unsafe_Mem_arm", [], _) if (targetArm >= 0): targetArm;
				case ECallHost("hxmc_unsafe_Mem_target", [], _) if (targetCode >= 0): targetCode;
				case ECallHost("hxmc_unsafe_Mem_platform", [], _) if (targetPlatform >= 0): targetPlatform;
				case ENot(a):
					var x = v(a);
					x == null ? null : x == 0 ? 1 : 0;
				case EBin(op, a, b):
					var x = v(a), y = v(b);
					if (x == null || y == null) null else switch op {
						case Eq: x == y ? 1 : 0;
						case Ne: x != y ? 1 : 0;
						case Lt: x < y ? 1 : 0;
						case Le: x <= y ? 1 : 0;
						case Gt: x > y ? 1 : 0;
						case Ge: x >= y ? 1 : 0;
						case _: null;
					}
				case _: null;
			};
		return switch e {
			case EInt(_): null; // (a literal: left as it is)
			case _: v(e);
		}
	}

	// replaces the calls of runtime functions implemented in Haxe in fi's
	// body, and folds the target's constants: `if (Mem.os() == 2) a else b`
	// keeps one branch (its symbols stay out of the other targets' links).
	// An expression nothing changes in is kept; the statement lists are new
	// (Facts.markCold rewrites them in place).
	function bindHosts(fi:FuncInfo) {
		function fold(e:Ex):Ex {
			return switch e {
				case EBin(op, EInt(a), EInt(b)):
					switch op {
						case Eq: EInt(a == b ? 1 : 0);
						case Ne: EInt(a != b ? 1 : 0);
						case Lt: EInt(a < b ? 1 : 0);
						case Le: EInt(a <= b ? 1 : 0);
						case Gt: EInt(a > b ? 1 : 0);
						case Ge: EInt(a >= b ? 1 : 0);
						case _: e;
					}
				case ENot(EInt(a)): EInt(a == 0 ? 1 : 0);
				case _: e;
			}
		}
		var ex:Ex->Ex = null;
		// (xs itself when no element changes)
		function exs(xs:Array<Ex>):Array<Ex> {
			for (i in 0...xs.length) {
				var x = ex(xs[i]);
				if (x != xs[i]) {
					var r = xs.slice(0, i);
					r.push(x);
					for (k in i + 1...xs.length)
						r.push(ex(xs[k]));
					return r;
				}
			}
			return xs;
		}
		ex = e -> fold(switch e {
			case ECallHost("hxmc_unsafe_Mem_os", [], _) if (targetOs >= 0): EInt(targetOs);
			case ECallHost("hxmc_unsafe_Mem_arm", [], _) if (targetArm >= 0): EInt(targetArm);
			case ECallHost("hxmc_unsafe_Mem_target", [], _) if (targetCode >= 0): EInt(targetCode);
			case ECallHost("hxmc_unsafe_Mem_platform", [], _) if (targetPlatform >= 0): EInt(targetPlatform);
			case EInt(_) | EF64(_) | EStr(_) | ENull(_) | ELocal(_) | EGlobal(_, _) | EType(_) | ENewObj(_): e;
			// (Float's %: hxmc.rt.LibM.fmod, as Math's natives)
			case EBin(FMod, a, b) if (hostImpls.exists("fmod")): ECall(hostImpl("fmod"), [ex(a), ex(b)]);
			case EBin(op, a, b):
				var x = ex(a), y = ex(b);
				x == a && y == b ? e : EBin(op, x, y);
			case ENot(a):
				var x = ex(a);
				x == a ? e : ENot(x);
			case EConv(c, a):
				var x = ex(a);
				x == a ? e : EConv(c, x);
			case EBox(t, a):
				var x = ex(a);
				x == a ? e : EBox(t, x);
			case EUnbox(t, a):
				var x = ex(a);
				x == a ? e : EUnbox(t, x);
			case EField(c, i, a):
				var x = ex(a);
				x == a ? e : EField(c, i, x);
			case EFieldAddr(c, i, a):
				var x = ex(a);
				x == a ? e : EFieldAddr(c, i, x);
			case EAnonGet(n, t, a, h):
				var x = ex(a);
				x == a ? e : EAnonGet(n, t, x, h);
			case ECast(t, a):
				var x = ex(a);
				x == a ? e : ECast(t, x);
			case EInstOf(c, a):
				var x = ex(a);
				x == a ? e : EInstOf(c, x);
			case EEnumTag(a, en):
				var x = ex(a);
				x == a ? e : EEnumTag(x, en);
			case EEnumParam(c, i, a):
				var x = ex(a);
				x == a ? e : EEnumParam(c, i, x);
			case EArrLen(a):
				var x = ex(a);
				x == a ? e : EArrLen(x);
			case EArrGet(t, a, i):
				var x = ex(a), y = ex(i);
				x == a && y == i ? e : EArrGet(t, x, y);
			case EArrGetU(t, a, i):
				var x = ex(a), y = ex(i);
				x == a && y == i ? e : EArrGetU(t, x, y);
			case EBoxGet(t, a):
				var x = ex(a);
				x == a ? e : EBoxGet(t, x);
			case ECapture(l, i, a):
				var x = ex(a);
				x == a ? e : ECapture(l, i, x);
			case ECall(f, args):
				var xs = exs(args);
				xs == args ? e : ECall(f, xs);
			case ECallDispatch(sel, s, args):
				var xs = exs(args);
				xs == args ? e : ECallDispatch(sel, s, xs);
			case ECallClos(s, c, args):
				var x = ex(c), xs = exs(args);
				x == c && xs == args ? e : ECallClos(s, x, xs);
			case ECallAnon(n, s, o, args):
				var x = ex(o), xs = exs(args);
				x == o && xs == args ? e : ECallAnon(n, s, x, xs);
			case ECallHost(n, args, ret):
				var xs = exs(args);
				// (the safe region's markers stay calls by symbol: Facts tells
				// the functions that enter one by them)
				var impl = hostImpls.exists(n) && fi.cSymbol != n && n != "rt_blocking_enter" && n != "rt_blocking_leave" ? hostImpl(n) : null;
				if (impl == null) xs == args ? e : ECallHost(n, xs, ret) else {
					if (impl.args.length != xs.length || Ir.repr(impl.ret) != Ir.repr(ret))
						fail('the Haxe implementation ${impl.name} of the runtime\'s $n does not have its signature');
					// a pure runtime function may be nested in an expression:
					// its implementation must not reach a GC point
					if (hxmc.ir.FnLower.noGcHost(n) && !impl.declNoGc) fail('${impl.name} implements the runtime\'s $n, which is not a GC point: it must be @:hxmc.noGc');
					ECall(impl, xs);
				}
			case ENewEnum(c, args):
				var xs = exs(args);
				xs == args ? e : ENewEnum(c, xs);
			case ENewArr(t, args):
				var xs = exs(args);
				xs == args ? e : ENewArr(t, xs);
			case ENewClos(l, args):
				var xs = exs(args);
				xs == args ? e : ENewClos(l, xs);
			case ENewBox(t, a):
				var x = ex(a);
				x == a ? e : ENewBox(t, x);
			case ENewAnon(s, args):
				var xs = exs(args);
				xs == args ? e : ENewAnon(s, xs);
		});
		var sts:Array<Stmt>->Array<Stmt> = null;
		function st(s:Stmt):Stmt {
			return switch s {
				case SSet(l, e):
					var x = ex(e);
					x == e ? s : SSet(l, x);
				case SExpr(e):
					var x = ex(e);
					x == e ? s : SExpr(x);
				case SSetField(c, i, o, v):
					var x = ex(o), y = ex(v);
					x == o && y == v ? s : SSetField(c, i, x, y);
				case SAnonSet(n, t, o, v):
					var x = ex(o), y = ex(v);
					x == o && y == v ? s : SAnonSet(n, t, x, y);
				case SArrSet(t, a, i, v):
					var x = ex(i), y = ex(v);
					x == i && y == v ? s : SArrSet(t, a, x, y);
				case SArrPush(t, a, v):
					var x = ex(v);
					x == v ? s : SArrPush(t, a, x);
				case SBoxSet(t, b, v):
					var x = ex(b), y = ex(v);
					x == b && y == v ? s : SBoxSet(t, x, y);
				case SSetGlobal(g, v):
					var x = ex(v);
					x == v ? s : SSetGlobal(g, x);
				case SIf(c, a, b):
					switch ex(c) {
						case EInt(v): SIf(EInt(1), v != 0 ? sts(a) : sts(b), []);
						case x: SIf(x, sts(a), sts(b));
					}
				case SLoop(body): SLoop(sts(body));
				case SBreak | SContinue: s;
				case SSwitch(e, cases, def): SSwitch(ex(e), [for (c in cases) {values: c.values, body: sts(c.body)}], sts(def));
				case SReturn(null): s;
				case SReturn(e):
					var x = ex(e);
					x == e ? s : SReturn(x);
				case SThrow(e):
					var x = ex(e);
					x == e ? s : SThrow(x);
				case STry(body, catches):
					STry(sts(body), [
						for (c in catches) {
							var test = c.test;
							// (bound now: the test is built when the try is, after Facts; the
							// runtime functions it calls, hx_is, are lowered with the program)
							if (test != null) ex(test(ELocal(c.l)));
							{test: test == null ? null : x -> ex(test(x)), l: c.l, body: sts(c.body)};
						}
					]);
				case SCold(id, x): SCold(id, st(x));
				case SPos(_): s;
			}
		}
		sts = ss -> [for (s in ss) st(s)];
		fi.body = sts(fi.body);
	}

	// Lowers the body of `fi` (`run`). The hook for a subclass that caches
	// bodies (hxmc/src/hxmc/LowerCache.hx): `key` is the field the body comes
	// from (null: a closure or a static initializer); the cache keeps a body
	// while the field object and its expression stay the same (the
	// compilation server retypes a changed module and the modules depending
	// on it, which makes new ones) and replays the calls the body made into
	// this class. Whole-program builds do not override it.
	function lowerBody(fi:FuncInfo, key:Null<TClassField>, run:() -> Void):Void
		run();

	public function fail(msg:String):Dynamic
		throw new LowerError(msg, "");

	public function native(name:String):String {
		natives.set(name, (natives.exists(name) ? natives.get(name) : 0) + 1);
		return name;
	}

	public static function ident(pack:Array<String>, name:String):String
		return pack.concat([name]).join("_");

	public static function nativeName(c:TClass):String
		return ident(c.clPath.pack, c.clPath.name);

	public static function moduleOf(c:TClass):String
		return core.Globals.sTypePath(c.clModule.mPath);

	// the name of the next closure created in `owner`: stable while other functions change
	public static function lambdaName(owner:FuncInfo):String
		return owner.name + "__lambda" + owner.nlambdas++;

	// hxmc's own metadata (@:hxmc.c, @:hxmc.noGc, @:hxmc.export, @:hxmc.host)
	public static function hasMeta(name:String, ml:core.Ast.Metadata):Bool
		return core.Meta.has(Custom(name), ml);

	// the string literal argument of hxmc's metadata `name`, or null
	public static function metaString(name:String, ml:core.Ast.Metadata):Null<String>
		return metaArg(core.Meta.getOpt(Custom(name), ml));

	public static function metaArg(m:Null<core.Ast.MetadataEntry>):Null<String> {
		if (m == null || m.exprs.length != 1) return null;
		return switch m.exprs[0].expr {
			case EConst(core.Ast.Constant.String(s, _)): s;
			case _: null;
		}
	}

	public static function isNativeArray(c:TClass):Bool
		return c.clPath.name == "NativeArray" && c.clPath.pack.join(".") == "hxmc";

	public static function isCore(c:TClass, name:String):Bool
		return c.clPath.pack.length == 0 && c.clPath.name == name;

	var methodsDone = 0; // classes whose every method is lowered

	function drain() {
		while (true) {
			while (pending.length > 0)
				pending.shift()();
			// all methods of every class seen: structural and dynamic access
			// (Iterator.hasNext, Reflect) reach them through the method tables;
			// DCE already removed the unused ones
			while (methodsDone < tclasses.length) {
				var tc = tclasses[methodsDone++];
				for (f in tc.clOrderedFields)
					if (f.cfKind.match(Method(MethNormal | MethInline)) && funcOf(f) != null && !f.hasClassFieldFlag(CfExtern))
						method(tc, f);
			}
			while (pending.length > 0)
				pending.shift()();
			// every implementation of a dispatched selector, in every class seen so far
			var more = false;
			for (name => sel in usedSelectors)
				for (tc in tclasses.copy()) {
					var f = tc.clFields.get(name);
					if (f != null && f.cfExpr != null && !tc.hasClassFlag(CInterface)) {
						var fi = method(tc, f);
						if (fi.dispatchSel < 0) {
							fi.dispatchSel = sel;
							more = true;
						}
					}
				}
			if (!more && pending.length == 0) break;
		}
	}

	function finish() {
		// preorder class ids, so subclass tests are range checks
		var next = 0;
		var children = new Map<ClassInfo, Array<ClassInfo>>();
		for (c in prog.classes)
			if (c.sup != null) {
				if (!children.exists(c.sup)) children.set(c.sup, []);
				children.get(c.sup).push(c);
			}
		function visit(c:ClassInfo) {
			c.id = next++;
			if (children.exists(c)) for (d in children.get(c)) visit(d);
			c.lastDescendant = next - 1;
		}
		visit(root);
		prog.classes.sort((a, b) -> a.id - b.id);
	}

	// ---- types

	// ty per type object: the lowering reads the typed program, whose types no
	// longer change, but for a monomorph still unbound (Dynamic until something
	// binds it): a type that meets one is lowered again each time. Effects are
	// the first lowering's (the classes, enums, signatures it registers; asking
	// again would find them registered).
	var tyMemo = new haxe.ds.ObjectMap<{}, Ty>();
	var tyMono = false; // (the type being lowered met an unbound monomorph)
	// (before tyMemo: the types asked last, one per position by the object's
	// hash; most asks repeat a type met just before)
	var tyLastK = new haxe.ds.Vector<{}>(4096);
	var tyLastV = new haxe.ds.Vector<Ty>(4096);

	public function ty(t:T):Ty {
		var i = hxmc.Native.objHash(t) >>> 20;
		if (tyLastK[i] == (cast t : {})) return tyLastV[i];
		var r = tyMemo.get(cast t);
		if (r == null) {
			var outer = tyMono;
			tyMono = false;
			r = lowerTy(t);
			var mono = tyMono;
			tyMono = mono || outer;
			if (mono) return r;
			tyMemo.set(cast t, r);
		}
		tyLastK[i] = cast t;
		tyLastV[i] = r;
		return r;
	}

	function lowerTy(t:T):Ty {
		// (a typedef, expanded below: unfolding)
		if (t.match(TType(_))) return unfolding(t, () -> ty(TFunctions.followWithoutNull(t)));
		var t = TFunctions.followWithoutNull(t);
		return switch t {
			case TMono(_):
				tyMono = true;
				TRef(RAny);
			case TAbstract(a, params):
				var isStd = a.aPath.pack.length == 0;
				switch a.aPath.name {
					case "Int" if (isStd): TI32;
					case "Bool" if (isStd): TBool;
					case "Float" if (isStd): TF64;
					case "Void" if (isStd): TVoid;
					case "Null" if (isStd):
						var inner = ty(params[0]);
						Ir.isScalar(inner) ? TRef(RNull(inner)) : boxed(inner);
					case "Any" if (isStd): TRef(RAny);
					case "Class" | "Enum" if (isStd): TRef(RType);
					case "EnumValue" if (isStd): TRef(REnum(null));
					case "UInt" if (isStd): TI32;
					case "I64" if (a.aPath.pack.join(".") == "hxmc"): TI64;
					// in macro mode (native macros, hxmc/src/hxmc/macro): the compiler's position, opaque
					case "Position" if (a.aPath.pack.join(".") == "haxe.macro"): TRef(RAny);
					// a coroutine is a function taking the continuation, as on HashLink
					case "Coroutine" if (a.aPath.pack.join(".") == "haxe.coro"):
						switch followFun(t) {
							case t = TFun(_): ty(t);
							case _: fail("coroutine type");
						}
					case _:
						if (core.Meta.has(CoreType, a.aMeta)) fail("core type " + a.aPath.pack.join(".") + "." + a.aPath.name);
						unfolding(t, () -> ty(core.Abstract.getUnderlyingType(a, params)));
				}
			case TInst(c, params):
				switch c.clKind {
					case KTypeParameter(_): TRef(RAny);
					case _:
						if (isCore(c, "String")) TRef(RStr);
						else if (isCore(c, "Array")) TRef(RArr(boxed(ty(params[0]))));
						else if (isNativeArray(c)) TRef(RNativeArr(boxed(ty(params[0]))));
						else if (CInterop.isStruct(c)) {
							var n = core.Globals.sTypePath(c.clPath);
							structClasses.set(n, c);
							TStruct(n, CInterop.layout(c).size);
						}
						else if (CInterop.isOpaque(c)) TI64; // the address of C memory (CInterop: through a Ptr only)
						else if (c.hasClassFlag(CInterface)) TRef(RObj(classInfo(c)));
						else if (c.hasClassFlag(CExtern)) TRef(RNative(nativeName(c)));
						else TRef(RObj(classInfo(c)));
				}
			case TEnum(e, _): TRef(REnum(enumInfo(e)));
			case TFun(s): TRef(RClos(prog.sig([for (a in s.args) a.optional ? optionalTy(ty(a.type)) : ty(a.type)], ty(s.ret))));
			case TAnon(an):
				switch an.aStatus {
					case ClassStatics(_) | EnumStatics(_) | AbstractStatics(_): TRef(RType);
					case _: TRef(RAnon);
				}
			case TDynamic(_): TRef(RAny);
			case _: TRef(RAny);
		}
	}

	// the abstracts and typedefs (with their type parameters) `ty` is
	// lowering the underlying type or expansion of, innermost last
	var unfolded:Array<T> = [];

	// t, an abstract or a typedef, as `f()` lowers its underlying type or
	// expansion. A recursive one (`abstract Rec(Array<Rec>)`, upstream's
	// unit test Issue8243; `typedef Rec<F> = Rec<F> -> F`, Issue12539) is
	// in it, endlessly: where it occurs in itself (the same type parameters,
	// compared as Abstract.getUnderlyingType compares them for its chains:
	// fastEq) it is Dynamic. That occurrence is within a reference: an
	// abstract over itself, also through Null, is an error (the typer's
	// "Abstract underlying type cannot be recursive", Abstract's chains), as
	// is a typedef of itself, so the cycle passes an Array's element or a
	// function's argument or result; the values there are references (an
	// Array, a function), which convert to and from Dynamic as they are, a
	// closure through an adapter (FnLower.coerce).
	function unfolding(t:T, f:() -> Ty):Ty {
		// (Dynamic there depends on where the type is lowered: not memoized, as
		// a type meeting an unbound monomorph, ty)
		for (u in unfolded)
			if (core.TUnification.fastEq(u, t)) {
				tyMono = true;
				return TRef(RAny);
			}
		unfolded.push(t);
		var r = try f() catch (e:Dynamic) {
			unfolded.pop();
			throw e;
		}
		unfolded.pop();
		return r;
	}

	// `f()` (the types of a class's fields, of an enum's arguments) lowered
	// outside of any abstract or typedef: the same wherever the class or
	// enum is first seen
	function outsideUnfolding(f:() -> Void) {
		var saved = unfolded;
		unfolded = [];
		try f() catch (e:Dynamic) {
			unfolded = saved;
			throw e;
		}
		unfolded = saved;
	}

	// the @:hxmc.struct class of a struct value of type t, or null (FnLower), per
	// type object as `ty` (a monomorph unbound: asked again)
	// (Null<S> is not a struct value: a reference to its box, Lower.boxed)
	var structMemo = new haxe.ds.ObjectMap<{}, Array<TClass>>();
	static var NOT_STRUCT:Array<TClass> = [];

	public function structOf(t:T):Null<TClass> {
		var r = structMemo.get(cast t);
		if (r != null) return r.length == 0 ? null : r[0];
		var c = switch TFunctions.followWithoutNull(t) {
			case TAbstract({aPath: {pack: [], name: "Null"}}, _): null;
			case TMono(_): return null;
			case _:
				switch CInterop.ctype(t) {
					case CStruct(c): c;
					case _: null;
				}
		}
		structMemo.set(cast t, c == null ? NOT_STRUCT : [c]);
		return c;
	}

	// the field names of a structural type, sorted (FnLower.anonHint)
	var anonFieldNames = new haxe.ds.ObjectMap<core.TType.TAnon, Array<String>>();

	public function anonNames(an:core.TType.TAnon):Array<String> {
		var names = anonFieldNames.get(an);
		if (names == null) {
			names = [for (k in an.aFields.keys()) k];
			names.sort(Reflect.compare);
			anonFieldNames.set(an, names);
		}
		return names;
	}

	// An optional argument of a function type (`?x:Int`, or `x:Int = 1`) is
	// nullable when its type is a number or a Bool: a call through a closure
	// passes null for it when left out, and the function the closure calls
	// gives it its own default value (the closures of functions,
	// `closureArgTy`, and function literals, FnLower.bindArgs). Direct calls
	// pass the callee's default values themselves.
	public static function optionalTy(t:Ty):Ty
		return t == TI32 || t == TF64 || t == TBool ? TRef(RNull(t)) : t;

	// an argument of a closure calling a function: nullable where the function has a default value
	public static function closureArgTy(t:Ty, d:Null<TExpr>):Ty
		return d != null ? optionalTy(t) : t;

	// Where a reference is needed (Dynamic, a type parameter, an Array's
	// element, an enum's argument, a structural type's field, Null<S>), a
	// struct value is boxed: an object holding a copy, never changed once
	// made, of a class of its own named after the struct (FnLower.coerce)
	public var structClasses = new Map<String, TClass>();
	var boxes = new Map<String, ClassInfo>();

	public function structBox(name:String):ClassInfo {
		var ci = boxes.get(name);
		if (ci != null) return ci;
		var c = structClasses.get(name);
		ci = new ClassInfo(name, nativeName(c) + "__box", root);
		ci.fields.push({name: "value", ty: TStruct(name, CInterop.layout(c).size)});
		boxes.set(name, ci);
		prog.classes.push(ci);
		return ci;
	}

	// t, or the reference to its box for a struct
	public function boxed(t:Ty):Ty
		return switch t {
			case TStruct(n, _): TRef(RObj(structBox(n)));
			case _: t;
		}

	public function classInfo(c:TClass):ClassInfo {
		var ci = classes.get(c);
		if (ci != null) return ci;
		if (c.hasClassFlag(CExtern)) fail("extern class " + c.clPath.name + " used as a class");
		if (CInterop.isNativeClass(c)) fail(c.clPath.name + " is a C type (@:hxmc.struct or @:hxmc.opaque): it has no class value (Struct.sizeOf takes it only as a literal argument)");
		if (c.hasClassFlag(CInterface)) {
			// interfaces have no layout: values are any object
			ci = new ClassInfo(core.Globals.sTypePath(c.clPath), nativeName(c), null);
			ci.isInterface = true;
			classes.set(c, ci);
			prog.interfaces.push(ci);
			return ci;
		}
		var sup = c.clSuper != null ? classInfo(c.clSuper.cls) : root;
		// (the superclass's field types may name this class, which has its
		// ClassInfo then: `class Node extends Base<Node>`, upstream's unit test TestGeneric)
		ci = classes.get(c);
		if (ci != null) return ci;
		ci = new ClassInfo(core.Globals.sTypePath(c.clPath), nativeName(c), sup);
		classes.set(c, ci);
		tclasses.push(c);
		var k = c.clSuper;
		while (k != null) {
			var subs = subclasses.get(k.cls);
			if (subs == null) subclasses.set(k.cls, subs = []);
			subs.push(c);
			k = k.cls.clSuper;
		}
		ci.ifaces = sup.ifaces.copy();
		for (i in c.clImplements)
			addIface(ci, i.cls);
		prog.classes.push(ci);
		for (f in sup.fields)
			ci.fields.push(f);
		var own = [];
		for (f in c.clOrderedFields)
			switch f.cfKind {
				case Var(v) if (isPhysical(c, f, v)):
					var slot = {name: f.cfName, ty: null};
					ci.fields.push(slot);
					own.push({slot: slot, f: f});
				// a dynamic method's current function (null until first use or assignment, see FnLower.dynMethod)
				case Method(MethDynamic) if (!Lambda.exists(ci.fields, x -> x.name == f.cfName)):
					var slot = {name: f.cfName, ty: null};
					ci.fields.push(slot);
					own.push({slot: slot, f: f});
				case _:
			}
		// field types may refer back to this class
		outsideUnfolding(() -> for (o in own)
			o.slot.ty = ty(o.f.cfType));
		return ci;
	}

	function addIface(ci:ClassInfo, i:TClass) {
		var ii = classInfo(i);
		if (ci.ifaces.indexOf(ii) < 0) ci.ifaces.push(ii);
		for (j in i.clImplements)
			addIface(ci, j.cls);
	}

	// a var field with storage (not a property with only accessor methods):
	// tFunctions.ml is_physical_var_field, but inline vars have no storage
	static function isPhysical(c:TClass, f:TClassField, v:VarKind):Bool {
		return switch [v.vRead, v.vWrite] {
			case [AccInline, _]: false;
			case [AccNormal | AccNo, _] | [_, AccNormal | AccNo]: true;
			case _: core.Meta.has(IsVar, f.cfMeta);
		}
	}

	public function enumInfo(e:TEnum):EnumInfo {
		var ei = enums.get(e);
		if (ei != null) return ei;
		ei = new EnumInfo(core.Globals.sTypePath(e.ePath), ident(e.ePath.pack, e.ePath.name));
		enums.set(e, ei);
		prog.enums.push(ei);
		for (name in e.eNames) {
			var ef = e.eConstrs.get(name);
			ei.ctors.push(new CtorInfo(ei, name, ef.efIndex, []));
		}
		ei.ctors.sort((a, b) -> a.tag - b.tag);
		outsideUnfolding(() -> for (name in e.eNames) {
			var ef = e.eConstrs.get(name);
			var ci = ei.ctors[ef.efIndex];
			switch TFunctions.follow(ef.efType) {
				case TFun(s):
					ci.params = [for (a in s.args) boxed(ty(a.type))];
					ci.paramNames = [for (a in s.args) a.name];
				case _:
					ci.global = prog.globals.length;
					prog.globals.push({ty: TRef(RCtor(ci)), init: ci, name: ei.ident + "_" + ci.name});
			}
		});
		return ei;
	}

	public function ctorInfo(ef:TEnumField, en:TEnum):CtorInfo
		return enumInfo(en).ctors[ef.efIndex];

	// ---- functions

	static function funcOf(cf:TClassField):TFunc
		return cf.cfExpr == null ? null : switch cf.cfExpr.eexpr {
			case TFunction(tf): tf;
			case _: null;
		}

	// argument and return representation of a function: the signature callers see
	function signature(fi:FuncInfo, tf:TFunc, self:Null<Ty>) {
		var id = 0;
		if (self != null) fi.args.push(new Local(id++, "this0", self));
		for (a in tf.tfArgs)
			fi.args.push(new Local(id++, a.variable.vName, ty(a.variable.vType)));
		fi.ret = ty(tf.tfType);
		// (a struct result: the address of the caller's memory for it, last)
		if (fi.ret.match(TStruct(_))) {
			fi.args.push(new Local(id++, "sret", TI64));
			fi.sret = true;
		}
		var ds = [for (a in tf.tfArgs) a.defaultValue];
		var vs:Array<Null<TVar>> = [for (a in tf.tfArgs) a.variable];
		if (self != null) {
			ds.unshift(null);
			vs.unshift(null);
		}
		defaults.set(fi, ds);
		argVars.set(fi, vs);
	}

	public function staticFunc(c:TClass, cf:TClassField):FuncInfo {
		var fi = funcs.get(cf);
		if (fi != null) return fi;
		var tf = funcOf(cf);
		if (tf == null) fail("static " + cf.cfName + " is not a function");
		fi = new FuncInfo(nativeName(c) + "_" + cf.cfName, moduleOf(c));
		fieldAttrs(fi, cf, c);
		funcs.set(cf, fi);
		prog.funcs.push(fi);
		signature(fi, tf, null);
		if (hasMeta(":hxmc.callback", cf.cfMeta)) callback(fi, cf);
		pending.push(guarded(fi, () -> lowerBody(fi, cf, () -> new FnLower(this, fi, null, null).run(tf))));
		return fi;
	}

	// @:hxmc.callback: a static function C calls through its address
	// (hxmc.unsafe.Callback.addr) in the C convention (hxmc's own). Its
	// symbol is fixed (the address C keeps names it). A @:hxmc.noGc callback
	// is the function itself: it may run on any thread, in any state. Any
	// other is reached through a wrapper that leaves the safe region the
	// calling thread is in (a call of C that is not @:hxmc.fast, the only
	// kind that may call back) and enters it again on return. One taking or
	// returning structs by value always has a wrapper (FuncInfo.cAbi).
	public var callbackSyms = new Map<TClassField, String>();

	function callback(fi:FuncInfo, cf:TClassField) {
		var where = CInterop.posOf(cf.cfPos);
		var tf = funcOf(cf);
		var cargs = [], structs = false;
		for (a in fi.args.concat([new Local(-1, "result", fi.ret)])) {
			if (a.id == -1 && a.ty == TVoid || a.name == "sret" && fi.sret && a.id == fi.args.length - 1) continue;
			var t = a.id == -1 ? tf.tfType : tf.tfArgs[a.id].variable.vType;
			var ct = CInterop.ctype(t);
			switch ct {
				case CI32 | CI64 | CF64 | CPtr:
				case CStruct(_): structs = true;
				case _:
					throw new LowerError('@:hxmc.callback ${cf.cfName}: ${a.id == -1 ? "the result" : "parameter " + a.name} has the type ${CInterop.name(ct)}, which a callback cannot take yet (Int, Int64, Float, Ptr, a struct)', where);
			}
			if (a.id != -1) cargs.push(ct);
		}
		var sym = "hxmc_cb_" + fi.name;
		callbackSyms.set(cf, sym);
		if (structs) {
			// structs by value: a wrapper receives them by the C ABI's rules
			// (MirBuild.cEntry) and passes their addresses; a struct result
			// comes back in a slot of its frame
			if (fi.cSymbol != null) throw new LowerError('@:hxmc.callback ${cf.cfName} is also @:hxmc.export', where);
			var w = new FuncInfo(fi.name + "__callback", fi.module);
			w.cSymbol = sym;
			w.display = fi.display;
			w.pos = fi.pos;
			w.cAbi = {args: cargs, ret: CInterop.ctype(tf.tfType)};
			var n = fi.sret ? fi.args.length - 1 : fi.args.length;
			w.args = [for (k in 0...n) new Local(fi.args[k].id, fi.args[k].name, fi.args[k].ty)];
			w.ret = fi.ret;
			var xs:Array<Ex> = [for (a in w.args) ELocal(a)];
			var gc = !fi.declNoGc && targetOs != 3;
			if (gc) w.body.push(SExpr(ECallHost("rt_blocking_leave", [], TVoid)));
			var r = new Local(w.args.length, "r", fi.ret == TVoid ? TI32 : fi.ret);
			if (fi.sret) {
				w.locals.push(r);
				w.body.push(SSet(r, ECallHost("hxmc_unsafe_Mem_structSlot", [EInt(switch fi.ret { case TStruct(_, s): s; case _: 8; }), EInt(8)], TI64)));
				w.body.push(SExpr(ECall(fi, xs.concat([ELocal(r)]))));
			} else if (fi.ret != TVoid) {
				w.locals.push(r);
				w.body.push(SSet(r, ECall(fi, xs)));
			} else w.body.push(SExpr(ECall(fi, xs)));
			if (gc) w.body.push(SExpr(ECallHost("rt_blocking_enter", [], TVoid)));
			w.body.push(SReturn(fi.ret == TVoid ? null : ELocal(r)));
			prog.funcs.push(w);
			return;
		}
		if (fi.declNoGc || targetOs == 3) {
			// (WebAssembly: one thread, no safe region)
			if (fi.cSymbol != null) throw new LowerError('@:hxmc.callback ${cf.cfName} is also @:hxmc.export', where);
			fi.cSymbol = sym;
			return;
		}
		var w = new FuncInfo(fi.name + "__callback", fi.module);
		w.cSymbol = sym;
		w.display = fi.display;
		w.pos = fi.pos;
		w.args = [for (a in fi.args) new Local(a.id, a.name, a.ty)];
		w.ret = fi.ret;
		var call = ECall(fi, [for (a in w.args) (ELocal(a) : Ex)]);
		w.body.push(SExpr(ECallHost("rt_blocking_leave", [], TVoid)));
		if (fi.ret == TVoid) {
			w.body.push(SExpr(call));
			w.body.push(SExpr(ECallHost("rt_blocking_enter", [], TVoid)));
			w.body.push(SReturn(null));
		} else {
			var r = new Local(w.args.length, "r", fi.ret);
			w.locals.push(r);
			w.body.push(SSet(r, call));
			w.body.push(SExpr(ECallHost("rt_blocking_enter", [], TVoid)));
			w.body.push(SReturn(ELocal(r)));
		}
		prog.funcs.push(w);
	}

	// hxmc's attributes of a function: @:hxmc.noGc (checked by Facts.findNoGc),
	// @:hxmc.collects (it runs the collector), @:hxmc.export (its symbol)
	// (@:hxmc.noGc on a class: on each of its functions)
	static function fieldAttrs(fi:FuncInfo, cf:TClassField, c:TClass) {
		fi.pos = cf.cfPos;
		fi.display = core.Globals.sTypePath(c.clPath) + "." + cf.cfName;
		if (c.clMeta.length > 0 && hasMeta(":hxmc.noGc", c.clMeta)) fi.declNoGc = true;
		if (cf.cfMeta.length == 0) return;
		if (hasMeta(":hxmc.noGc", cf.cfMeta)) fi.declNoGc = true;
		fi.collects = hasMeta(":hxmc.collects", cf.cfMeta);
		fi.cSymbol = metaString(":hxmc.export", cf.cfMeta);
	}

	// metadata m as the source writes it: not the @:keep DCE gives every class
	// it filtered (Dce.mkKeepMeta, at no width)
	static function written(m:StrictMeta, ml:core.Ast.Metadata):Bool {
		for (e in ml)
			if (core.Meta.metaEq(m, e.meta) && e.pos.pmax > e.pos.pmin) return true;
		return false;
	}

	// The declaration a method overrides or implements: its signature is the one
	// every implementation of the selector shares.
	public function rootDecl(c:TClass, name:String):TClassField {
		var best:TClassField = null;
		function visit(k:TClass) {
			if (k == null) return;
			var f = k.clFields.get(name);
			if (f != null) best = f;
			if (k.clSuper != null) visit(k.clSuper.cls);
			for (i in k.clImplements)
				visit(i.cls);
		}
		visit(c);
		return best;
	}

	public function method(c:TClass, cf:TClassField):FuncInfo {
		var fi = funcs.get(cf);
		if (fi != null) return fi;
		var tf = funcOf(cf);
		if (tf == null) fail("method " + cf.cfName + " is not a function");
		var ci = classInfo(c);
		fi = new FuncInfo(nativeName(c) + "_" + cf.cfName, moduleOf(c));
		fieldAttrs(fi, cf, c);
		fi.selfClass = ci;
		funcs.set(cf, fi);
		ci.methods.set(cf.cfName, fi);
		// (@:keep, on the method or its class, or @:keepSub on a superclass: live whatever reaches it, Reach)
		if (written(Keep, cf.cfMeta) || written(Keep, c.clMeta) || optimization.Dce.superForcesKeep(c)) prog.roots.push(fi);
		prog.funcs.push(fi);
		// shared signature: the root declaration's (generic parameters are Dynamic there)
		var decl = rootDecl(c, cf.cfName);
		var dtf = decl != null ? funcOf(decl) : null;
		if (dtf != null && dtf.tfArgs.length == tf.tfArgs.length) {
			signature(fi, dtf, TRef(RObj(root)));
			// (the default values are the method's own: an override may declare others)
			defaults.set(fi, [null].concat([for (a in tf.tfArgs) a.defaultValue]));
			argVars.set(fi, [null].concat([for (a in tf.tfArgs) a.variable]));
		} else if (decl != null && dtf == null) {
			// interface or abstract declaration without a body: use its type
			switch followFun(decl.cfType) {
				case TFun(s) if (s.args.length == tf.tfArgs.length):
					var id = 0;
					fi.args.push(new Local(id++, "this0", TRef(RObj(root))));
					for (a in s.args)
						fi.args.push(new Local(id++, a.name, ty(a.type)));
					fi.ret = ty(s.ret);
					if (fi.ret.match(TStruct(_))) {
						fi.args.push(new Local(id++, "sret", TI64));
						fi.sret = true;
					}
					var ds:Array<Null<TExpr>> = [null];
					for (a in tf.tfArgs) ds.push(a.defaultValue);
					defaults.set(fi, ds);
					argVars.set(fi, [null].concat([for (a in tf.tfArgs) a.variable]));
				case _: signature(fi, tf, TRef(RObj(root)));
			}
		} else signature(fi, tf, TRef(RObj(root)));
		pending.push(guarded(fi, () -> lowerBody(fi, cf, () -> new FnLower(this, fi, ci, null).run(tf))));
		defaultsEntry(fi, ci);
		return fi;
	}

	// A method called dynamically (by name through Dynamic, Reflect) may be
	// given fewer arguments than it has: where it has default values for
	// numbers or Bools, its entry in the method table (DataGen.types: dynamic
	// and structural calls) is this one, those arguments nullable
	// (closureArgTy, as a closure of a function type with optional
	// arguments), null meaning the default.
	function defaultsEntry(fi:FuncInfo, ci:ClassInfo) {
		if (fi.sret) return;
		var ds = defaults.get(fi);
		if (ds == null) return;
		var tys = [for (i in 1...fi.args.length) closureArgTy(fi.args[i].ty, i < ds.length ? ds[i] : null)];
		var differs = false;
		for (i in 0...tys.length)
			if (tys[i] != fi.args[i + 1].ty) differs = true;
		if (!differs) return;
		var w = new FuncInfo(fi.name + "__dflt", fi.module);
		w.args.push(new Local(0, "this0", fi.args[0].ty));
		for (i in 0...tys.length)
			w.args.push(new Local(i + 1, fi.args[i + 1].name, tys[i]));
		w.ret = fi.ret;
		w.pos = fi.pos;
		w.display = fi.display;
		fi.dfltEntry = w;
		prog.funcs.push(w);
		pending.push(guarded(w, () -> lowerBody(w, null, () -> new FnLower(this, w, ci, null).forwardDefaults(fi))));
	}

	public function ctor(c:TClass):FuncInfo {
		var fi = ctors.get(c);
		if (fi != null) return fi;
		var ci = classInfo(c);
		fi = new FuncInfo(nativeName(c) + "_new", moduleOf(c));
		ci.ctor = fi;
		ctors.set(c, fi);
		prog.funcs.push(fi);
		if (c.clConstructor == null) {
			// no constructor: the parent's, or nothing
			signature(fi, {tfArgs: [], tfType: null, tfExpr: null}, TRef(RObj(ci)));
			fi.ret = TVoid;
			return fi;
		}
		var tf = funcOf(c.clConstructor);
		signature(fi, tf, TRef(RObj(ci)));
		fi.ret = TVoid;
		pending.push(guarded(fi, () -> lowerBody(fi, c.clConstructor, () -> new FnLower(this, fi, ci, null).run(tf, true))));
		return fi;
	}

	// the constructor of a @:hxmc.struct class: a function of the struct's
	// address (this) and the arguments, which fills the memory (zeroed by
	// the caller, FnLower.newStruct)
	var structCtors = new Map<TClass, FuncInfo>();

	public function structCtor(c:TClass):FuncInfo {
		var fi = structCtors.get(c);
		if (fi != null) return fi;
		fi = new FuncInfo(nativeName(c) + "_new", moduleOf(c));
		structCtors.set(c, fi);
		prog.funcs.push(fi);
		var tf = funcOf(c.clConstructor);
		signature(fi, tf, TI64);
		fi.ret = TVoid;
		pending.push(guarded(fi, () -> lowerBody(fi, c.clConstructor, () -> new FnLower(this, fi, null, null).runStructCtor(tf))));
		return fi;
	}

	// `name` and `module`: a name that stays the same when unrelated code changes
	// (Lower.lambdaName for closures in a function body, else derived from what
	// the closure forwards to) and the module whose C file holds it
	public function newLambda(sig:SigInfo, captures:Array<Local>, body:FnLower->Void, name:String, module:String):LambdaInfo {
		var fi = new FuncInfo(name, module);
		var li = new LambdaInfo(prog.lambdas.length, sig, captures, fi);
		fi.lambda = li;
		fi.args.push(new Local(0, "clos", TRef(RClos(sig))));
		for (i in 0...sig.args.length)
			fi.args.push(new Local(i + 1, "a" + i, sig.args[i]));
		fi.ret = sig.ret;
		if (fi.ret.match(TStruct(_))) {
			fi.args.push(new Local(sig.args.length + 1, "sret", TI64));
			fi.sret = true;
		}
		prog.lambdas.push(li);
		prog.funcs.push(fi);
		pending.push(guarded(fi, () -> lowerBody(fi, null, () -> body(new FnLower(this, fi, null, li)))));
		return li;
	}

	// a closure calling a static function (the function used as a value)
	var staticClosures = new Map<FuncInfo, LambdaInfo>();

	// the class is used as a value: its statics become reachable dynamically
	public function reflectStatics(c:TClass) {
		if (c.hasClassFlag(CExtern) || c.hasClassFlag(CInterface) || CInterop.isNativeClass(c)) return;
		var ci = classInfo(c);
		if (ci.statics != null) return;
		ci.statics = [];
		for (cf in c.clOrderedStatics)
			switch cf.cfKind {
				// (a function taking or returning a struct is not reachable by name)
				case Method(MethNormal | MethInline) if (funcOf(cf) != null && !hasStruct(staticFunc(c, cf))):
					ci.statics.push({name: cf.cfName, clos: staticClosure(staticFunc(c, cf)), global: -1});
				case Var(v) if (isPhysical(c, cf, v) && !v.vRead.match(AccInline) && !ty(cf.cfType).match(TStruct(_))):
					ci.statics.push({name: cf.cfName, clos: null, global: staticVar(c, cf)});
				case _:
			}
	}

	static function hasStruct(f:FuncInfo):Bool {
		for (a in f.args)
			if (a.ty.match(TStruct(_))) return true;
		return f.sret;
	}

	public function staticClosure(f:FuncInfo):LambdaInfo {
		var li = staticClosures.get(f);
		if (li != null) return li;
		var ds = defaults.get(f);
		var sig = prog.sig([
			for (i in 0...f.args.length)
				if (!(f.sret && i == f.args.length - 1)) closureArgTy(f.args[i].ty, ds != null && i < ds.length ? ds[i] : null)
		], f.ret);
		li = newLambda(sig, [], fl -> fl.forward(f, null), f.name + "__sclos", f.module);
		staticClosures.set(f, li);
		return li;
	}

	var hostClosures = new Map<String, LambdaInfo>();

	// a closure calling a runtime function (an extern static used as a value)
	public function hostClosure(name:String, sig:SigInfo, ?self:Ty):LambdaInfo {
		var li = hostClosures.get(name);
		if (li != null) return li;
		li = newLambda(sig, self == null ? [] : [new Local(-1, "self", self)], fl -> fl.forwardHost(name), name + "__hclos", "_closures");
		hostClosures.set(name, li);
		return li;
	}

	var ctorClosures = new Map<CtorInfo, LambdaInfo>();

	public function ctorClosure(ci:CtorInfo, sig:SigInfo):LambdaInfo {
		var li = ctorClosures.get(ci);
		if (li != null) return li;
		li = newLambda(sig, [], fl -> fl.forwardCtor(ci), ci.en.ident + "_" + ci.name + "__cclos", "_closures");
		ctorClosures.set(ci, li);
		return li;
	}

	// a closure over `this` calling a method (obj.method used as a value)
	var boundClosures = new Map<FuncInfo, LambdaInfo>();

	public function boundClosure(f:Null<FuncInfo>, dispatch:Null<{sel:Int, sig:SigInfo, args:Array<Ty>, ?cls:TClass}>, owner:FuncInfo):LambdaInfo {
		if (f == null) {
			// (an interface's method, or an abstract one no class of the chain
			// implements: dispatched, the selector's signature without the
			// receiver and the result address; nullable where an implementation
			// has a default value)
			var ds = dispatch.sig;
			var n = ds.ret.match(TStruct(_)) ? ds.args.length - 1 : ds.args.length;
			var impls = dispatch.cls != null ? implementors(dispatch.cls, prog.selectors[dispatch.sel].name) : [];
			function hasDefault(i:Int):Bool {
				for (k in impls)
					switch k.field.cfExpr.eexpr {
						case TFunction(tf) if (i - 1 < tf.tfArgs.length && tf.tfArgs[i - 1].defaultValue != null): return true;
						case _:
					}
				return false;
			}
			var sig = prog.sig([for (i in 1...n) hasDefault(i) ? optionalTy(ds.args[i]) : ds.args[i]], ds.ret);
			var self = new Local(-1, "self", TRef(RObj(root)));
			return newLambda(sig, [self], fl -> fl.forward(null, dispatch), lambdaName(owner), owner.module);
		}
		var li = boundClosures.get(f);
		if (li != null && dispatch == null) return li;
		var ds = defaults.get(f);
		var args = [for (i in 1...(f.sret ? f.args.length - 1 : f.args.length)) closureArgTy(f.args[i].ty, ds != null && i < ds.length ? ds[i] : null)];
		var sig = prog.sig(args, f.ret);
		var self = new Local(-1, "self", TRef(RObj(root)));
		li = newLambda(sig, [self], fl -> fl.forward(f, dispatch), dispatch == null ? f.name + "__bound" : lambdaName(owner), dispatch == null ? f.module : owner.module);
		if (dispatch == null) boundClosures.set(f, li);
		return li;
	}

	// a closure converting between two closure representations
	var adapters = new Map<String, LambdaInfo>();

	public function adapter(from:SigInfo, to:SigInfo):LambdaInfo {
		var key = from.key + ">" + to.key;
		var li = adapters.get(key);
		if (li != null) return li;
		var inner = new Local(-1, "inner", TRef(RClos(from)));
		li = newLambda(to, [inner], fl -> fl.adapt(from), "adapt__" + from.key + "__" + to.key, "_closures");
		adapters.set(key, li);
		return li;
	}

	// a closure of signature `to` calling a Dynamic value through the dynamic
	// call (hx_dyn_call: the arguments boxed, the result converted)
	var dynAdapters = new Map<String, LambdaInfo>();

	public function dynAdapter(to:SigInfo):LambdaInfo {
		var li = dynAdapters.get(to.key);
		if (li != null) return li;
		var inner = new Local(-1, "inner", TRef(RAny));
		li = newLambda(to, [inner], fl -> fl.adaptDynamic(), "dynadapt__" + to.key, "_closures");
		dynAdapters.set(to.key, li);
		return li;
	}

	var staticVars = new Map<TClassField, Int>();

	// a class static variable: a global, initialized by the static initializer
	public function staticVar(c:TClass, cf:TClassField):Int {
		var g = staticVars.get(cf);
		if (g != null) return g;
		var t = ty(cf.cfType); // first: it may register globals itself (enum constructors)
		g = prog.globals.length;
		var name = nativeName(c) + "_" + cf.cfName;
		// @:hxmc.threadLocal("symbol"): a scalar or Ptr per thread (zero in a new
		// thread: no initializer), in the thread-local storage of each format
		var tls:Null<String> = null;
		if (hasMeta(":hxmc.threadLocal", cf.cfMeta)) {
			var where = CInterop.posOf(cf.cfPos);
			if (!Ir.isScalar(t)) throw new LowerError('@:hxmc.threadLocal ' + cf.cfName + ': only scalars and Ptr (a reference would need the collector to scan every thread\'s copy)', where);
			if (cf.cfExpr != null) throw new LowerError('@:hxmc.threadLocal ' + cf.cfName + ' has no initializer: every thread\'s copy starts at zero', where);
			tls = metaString(":hxmc.threadLocal", cf.cfMeta);
			if (tls == null) tls = "hxmc_tl_" + name;
		}
		// @:hxmc.bss(bytes[, "symbol"]): a Ptr whose value is the address of a
		// zeroed block of that size outside the heap (C's static arrays)
		var bss = core.Meta.getOpt(Custom(":hxmc.bss"), cf.cfMeta);
		// a struct static: its memory is a block outside the heap
		switch t {
			case TStruct(_, size):
				if (tls != null || bss != null) throw new LowerError('a struct static (' + cf.cfName + ') cannot be @:hxmc.threadLocal or @:hxmc.bss', CInterop.posOf(cf.cfPos));
				prog.globals.push({ty: t, init: null, name: name, bss: size, sym: "hxmc_bss_" + name});
				staticVars.set(cf, g);
				initClass(c);
				return g;
			case _:
		}
		if (bss != null) {
			var where = CInterop.posOf(cf.cfPos);
			var args = bss.exprs;
			var bytes:Null<Int> = args.length > 0 ? switch args[0].expr { case EConst(core.Ast.Constant.Int(v, _)): Std.parseInt(v); case _: null; } : null;
			var sym:Null<String> = args.length > 1 ? switch args[1].expr { case EConst(core.Ast.Constant.String(v, _)): v; case _: null; } : "hxmc_bss_" + name;
			if (bytes == null || bytes <= 0 || sym == null) throw new LowerError('@:hxmc.bss ' + cf.cfName + ': give the size in bytes (an integer literal) and optionally the symbol (a string literal)', where);
			if (t != TI64 || cf.cfExpr != null) throw new LowerError('@:hxmc.bss ' + cf.cfName + ': a Ptr without initializer (its value is the block\'s address)', where);
			prog.globals.push({ty: t, init: null, name: name, bss: bytes, sym: sym});
			staticVars.set(cf, g);
			return g;
		}
		// @:hxmc.export("symbol"): a scalar static under that symbol (data that
		// generated code and the runtime's code read by name: rt_young_start, ...)
		var exp = metaString(":hxmc.export", cf.cfMeta);
		if (exp != null && (tls != null || !Ir.isScalar(t))) throw new LowerError('@:hxmc.export on the static variable ' + cf.cfName + ': only scalars and Ptr, not thread-local', CInterop.posOf(cf.cfPos));
		prog.globals.push(tls != null ? {ty: t, init: null, name: name, tls: tls} : exp != null ? {ty: t, init: null, name: name, exp: exp} : {ty: t, init: null, name: name});
		staticVars.set(cf, g);
		initClass(c);
		return g;
	}

	var initialized = new Map<TClass, Bool>();
	var initOf = new Map<FuncInfo, TClass>();

	// static variable initializers and __init__ of a class, run at startup
	// (in the order of com.types, see `program`)
	function initClass(c:TClass) {
		if (initialized.exists(c)) return;
		initialized.set(c, true);
		var fi = new FuncInfo(nativeName(c) + "__init", moduleOf(c));
		prog.funcs.push(fi);
		prog.inits.push(fi);
		initOf.set(fi, c);
		// (a class's __init__ runs whether or not live code reads its statics: Reach)
		if (c.clInit != null) prog.roots.push(fi);
		pending.push(guarded(fi, () -> lowerBody(fi, null, () -> new FnLower(this, fi, null, null).runInit(c))));
	}

	public function rootClass():ClassInfo
		return root;

	public function getProgram():Program
		return prog;

	public function lookupMethod(c:TClass, name:String):Null<{cls:TClass, field:TClassField}> {
		var k = c;
		while (k != null) {
			var f = k.clFields.get(name);
			if (f != null && f.cfExpr != null) return {cls: k, field: f};
			k = k.clSuper != null ? k.clSuper.cls : null;
		}
		return null;
	}

	// the classes under c (c itself, its subclasses; for an interface, the
	// classes implementing it and theirs) declaring a body for the method
	// `name`, each after its superclass
	public function implementors(c:TClass, name:String):Array<{cls:TClass, field:TClassField}> {
		var r = [];
		var seen = new haxe.ds.ObjectMap<TClass, Bool>();
		function visit(k:TClass) {
			if (seen.exists(k)) return;
			seen.set(k, true);
			var f = k.clFields.get(name);
			if (f != null && f.cfExpr != null && !k.hasClassFlag(CInterface)) r.push({cls: k, field: f});
			for (d in k.clDescendants)
				visit(d);
		}
		visit(c);
		function depth(k:TClass):Int
			return k.clSuper == null ? 0 : 1 + depth(k.clSuper.cls);
		haxe.ds.ArraySort.sort(r, (a, b) -> depth(a.cls) - depth(b.cls));
		return r;
	}

	// virtual unless no known subclass overrides it; an abstract method no
	// class of the chain implements is dispatched too (no instance may exist,
	// but the call must still compile)
	public function needsDispatch(c:TClass, name:String):Bool {
		if (c.hasClassFlag(CInterface)) return true;
		if (lookupMethod(c, name) == null) return true;
		var f = c.clFields.get(name);
		if (f != null && f.hasClassFieldFlag(CfFinal)) return false;
		var subs = subclasses.get(c);
		if (subs != null)
			for (d in subs)
				if (d.clFields.exists(name) && d.clFields.get(name).cfExpr != null) return true;
		// a subclass lowered later may still override: dispatch if any
		// descendant the typer knows does (clDescendants holds the direct
		// subclasses: their subclasses too)
		return overriddenBelow(c, name);
	}

	var overridden = new Map<String, Bool>();

	function overriddenBelow(c:TClass, name:String):Bool {
		var key = core.Globals.sTypePath(c.clPath) + "." + name;
		var r = overridden.get(key);
		if (r != null) return r;
		r = false;
		for (d in c.clDescendants)
			if (!d.hasClassFlag(CInterface) && d.clSuper != null && d.clSuper.cls == c
				&& (d.clFields.exists(name) && d.clFields.get(name).cfExpr != null || overriddenBelow(d, name))) {
				r = true;
				break;
			}
		overridden.set(key, r);
		return r;
	}

	public function selector(name:String, sig:SigInfo):Int {
		var s = usedSelectors.get(name);
		if (s != null) return s;
		s = prog.selectors.length;
		prog.selectors.push({name: name, sig: sig});
		usedSelectors.set(name, s);
		return s;
	}

	public function superOf(ci:ClassInfo):TClass {
		for (tc => c in classes)
			if (c == ci) return tc.clSuper != null ? tc.clSuper.cls : null;
		return null;
	}
}

class LowerError {
	public var msg:String;
	public var where:String;

	public function new(msg, where) {
		this.msg = msg;
		this.where = where;
	}

	public function toString()
		return "lowering: " + msg + (where != "" ? " (" + where + ")" : "");
}
