package hxmc.ir;

import hxmc.ir.Ir;
import hxmc.ir.LowerQueries;
import core.Ast.Binop;
import core.Ast.Unop;
import core.TType;
import core.MetaList.StrictMeta;
import core.TFunctions;
import core.ds.VectorTools;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

using core.TFunctions;
using core.ds.VectorTools;

// Lowers the filtered typed AST (the data HXB serializes) of everything
// reachable from `main` to the IR (docs/hxmc.md).
//
// Representation (see Ir.hx): Int/Bool/Float and haxe.Int64 unboxed;
// everything else is a pointer. Generics are erased: a type parameter is Dynamic (RAny), and values
// are converted (boxed, unboxed, wrapped in adapter closures) where a declared
// type and a use-site type differ: calls, returns, field and enum-argument
// access (FnLower.coerce). A function body sees this class through
// LowerQueries alone (what the compilation server's reuse of bodies covers).
class Lower implements LowerQueries {
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
	// the default values of each function's arguments (argDefaults)
	var defaults = new Map<FuncInfo, ArgDefaults>();

	public function new() {
		CInterop.resetCaches();
		root = new ClassInfo("Object", "Object", null);
		prog.classes.push(root);
		// (the C functions are this program's: those of an earlier build of the
		// compilation server are not, and a body it replays declares its own, cExtern)
		CInterop.reset();
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
		// (haxe.EntryPoint.run after main, as Finalization.maybeAddEntrypoint adds
		// it to the main expression when the program keeps the class: the event
		// loop, haxe.Timer and haxe.MainLoop's events; upstream's threads suite)
		for (t in types)
			switch t {
				case TClassDecl(c) if (c.clPath.name == "EntryPoint" && c.clPath.pack.length == 1 && c.clPath.pack[0] == "haxe" && c.clStatics.exists("run")):
					l.prog.entryRun = l.staticFunc(c, c.clStatics.get("run"));
				case _:
			}
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
			if (l.metaInits.exists(fi)) return -1;
			var c = l.initOf.get(fi);
			c != null && order.exists(c) ? order.get(c) : types.length;
		};
		l.prog.inits.sort((a, b) -> pos(a) - pos(b));
		if (survey) l.writeSurvey();
		return l.prog;
	}

	// ---- survey mode (HXMC_SURVEY=file): record unsupported constructs, keep going

	public static var survey = Sys.getEnv("HXMC_SURVEY") != null;
	// statements carry their source lines (Stmt.SPos): native builds but with
	// -D hxmc.no-stacks (the call stacks' table, -debug's DWARF: Main)
	public static var lines = false;
	// (-D hxmc.macros=mir: hxmc.interp.MirMacros) the macro code's calls note
	// where they are, as Eval's frames do (env_leave_pmin/pmax, which the
	// macro API's get_api_call_pos reads): before each call, the call's site
	// (`site`: its id) in `pending` and the calling function's own site in
	// `current`; each function takes its site from `pending` as it starts.
	// (pending, current: symbols of the compiler's 32-bit data; wants: the functions that do)
	public static var callSites:Null<{site:core.Globals.Pos->Int, pending:String, current:String, wants:FuncInfo->Bool}> = null;
	// (-D hxmc.macros=mir: hxmc.interp.MacroRuntime) a static function of the
	// runtime marked @:hxmc.hostCode, whose body was not typed: the native
	// code of the compiler running this lowering is its code. What that code
	// does (FuncInfo.noGc, blocks), or null when the compiler lacks it.
	public static var hostCode:Null<FuncInfo->Null<{noGc:Bool, blocks:Bool}>> = null;
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
				fi.body = vector(SThrow(ENull(TRef(RAny))));
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
					// a class's __init__ runs at startup whether or not code uses the
					// class (initClass, otherwise made when a static is used)
					if (c.clInit != null) initClass(c);
					for (cf in c.clOrderedStatics)
						if (cf.cfMeta.length > 0 && cf.cfKind.match(Method(_)) && hasMeta(":hxmc.export", cf.cfMeta)) {
							var n = metaString(":hxmc.export", cf.cfMeta);
							if (hostImpls.exists(n)) fail("two Haxe functions exported as " + n);
							hostImpls.set(n, {c: c, cf: cf});
							staticFunc(c, cf);
						}
				case TClassDecl(c) if (runtimeClass(c)):
					if (!ofTarget(c)) continue;
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

	// a class of the hxmc package, whose statics may implement the runtime's
	// functions (findHosts; hxmc.ir.RuntimeSymbols)
	public static function runtimeClass(c:TClass):Bool
		return c.clPath.pack.length > 0 && c.clPath.pack[0] == "hxmc" && !c.hasClassFlag(CExtern);

	// whether such a class is of this target's runtime
	public static function ofTarget(c:TClass):Bool {
		// @:hxmc.android: the Android targets' only (Mem.target() 9 and 10)
		if (hasMeta(":hxmc.android", c.clMeta) && targetCode >= 0 && targetCode < 9) return false;
		// @:hxmc.ios: the iOS targets' only (Mem.platform() 1 and 2)
		if (hasMeta(":hxmc.ios", c.clMeta) && targetPlatform >= 0 && targetPlatform < 1) return false;
		// @:hxmc.wasm: the runtime of WebAssembly only (what C provides elsewhere)
		if (hasMeta(":hxmc.wasm", c.clMeta) && targetOs != 3) return false;
		// @:hxmc.native: the runtime of the native targets only (over C libraries)
		if (hasMeta(":hxmc.native", c.clMeta) && targetOs == 3) return false;
		// @:hxmc.os("windows"): the runtime of one system only
		var os = metaString(":hxmc.os", c.clMeta);
		if (os != null && targetOs >= 0 && ["linux", "macos", "windows", "wasm"].indexOf(os) != targetOs) return false;
		return true;
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
	// Mem.mirHost: 1 when the program loads code for the Mir interpreter (Main)
	public static var mirHost = 0;
	// the program's resources (--resource, Context.addResource), haxe.Resource's
	// content: each one's name and bytes, in genjs's order (Main.generate); the
	// names are literals of the code (FnLower), the bytes DataGen's data
	public static var resources:Array<{name:String, data:haxe.io.Bytes}> = [];
	// -D hxmc.native-array-outofbounds: what an access of a NativeArray
	// (haxe.ds.Vector) at an index out of bounds does (FnLower.nativeRead)
	public static var bounds = BOUNDS_UNCHECKED;
	public static inline var BOUNDS_UNCHECKED = 0; // not tested (unspecified)
	public static inline var BOUNDS_THROWS = 1; // haxe.exceptions.ArgumentException (rt/NArray.outOfBounds)
	public static inline var BOUNDS_SILENT = 2; // a read gives the element type's default, a write does nothing
	// -D hxmc.null-checks (default: WebAssembly): references are tested against
	// null before they are dereferenced (MirBuild.nullCheck; the receivers of
	// the runtime's methods: FnLower.receiverCheck), and null
	// throws "Null Access"; without, the native targets fault and the runtime's
	// handler throws (hxmc.rt.Faults)
	public static var nullChecks = false;
	// -D hxmc.span-checks: whether a span's element accesses are range-checked
	// (FnLower.spanCall; default: yes); ranges always are
	public static var spanChecks = true;
	// Std.isOfType, Std.downcast and cast of a class literal test a span of type
	// indices (FnLower.instClass); false while Mir macros lower their bundles
	// (interp.MirMacros.build: a class of a later bundle may extend one of an
	// earlier bundle, whose span cannot cover it, macro.Loader), whose tests
	// walk the superclasses (hx_is)
	public static var classSpans = true;
	// -D hxmc.interp: functions of the program are interpreted (hxmc.interp.InterpGen: their entry stubs call hxmc_interp_enter)
	public static var interp = false;

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
				case ECallHost("hxmc_unsafe_Mem_mirHost", [], _): mirHost;
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
		function exs(xs:Vector<Ex>):Vector<Ex> {
			for (i in 0...xs.length) {
				var x = ex(xs[i]);
				if (x != xs[i]) {
					var r = new Vector<Ex>(xs.length);
					Vector.blit(xs, 0, r, 0, i);
					r[i] = x;
					for (k in i + 1...xs.length)
						r[k] = ex(xs[k]);
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
			case ECallHost("hxmc_unsafe_Mem_mirHost", [], _): EInt(mirHost);
			case EInt(_) | EF64(_) | EStr(_) | ENull(_) | ELocal(_) | EGlobal(_, _) | EType(_) | ENewObj(_): e;
			// (Float's %: hxmc.rt.LibM.fmod, as Math's natives)
			case EBin(FMod, a, b) if (hostImpls.exists("fmod")): ECall(hostImpl("fmod"), vector(ex(a), ex(b)));
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
				var impl = hostImpls.exists(n) && fi.cSymbol != n && n != "rt_blocking_enter" && n != "rt_blocking_leave" && n != "rt_blocking_restore" ? hostImpl(n) : null;
				if (impl == null) xs == args ? e : ECallHost(n, xs, ret) else {
					if (impl.args.length != xs.length || Ir.repr(impl.ret) != Ir.repr(ret))
						fail('the Haxe implementation ${impl.name} of the runtime\'s $n does not have its signature');
					// a pure runtime function may be nested in an expression:
					// its implementation must not reach a GC point
					if (hxmc.ir.FnLower.noGcHost(n) && !impl.declNoGc) fail('${impl.name} implements the runtime\'s $n, which is not a GC point: it must be @:hxmc.unsafe');
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
		var sts:Vector<Stmt>->Vector<Stmt> = null;
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
						case EInt(v): SIf(EInt(1), v != 0 ? sts(a) : sts(b), vector());
						case x: SIf(x, sts(a), sts(b));
					}
				case SLoop(body): SLoop(sts(body));
				case SBreak | SContinue: s;
				case SSwitch(e, cases, def): SSwitch(ex(e), cases.map(c -> {values: c.values, body: sts(c.body)}), sts(def));
				case SReturn(null): s;
				case SReturn(e):
					var x = ex(e);
					x == e ? s : SReturn(x);
				case SThrow(e):
					var x = ex(e);
					x == e ? s : SThrow(x);
				case STry(body, catches):
					STry(sts(body), catches.map(c -> {
						var test = c.test;
						// (bound now: the test is built when the try is, after Facts; the
						// runtime functions it calls, hx_is, are lowered with the program)
						if (test != null) ex(test(ELocal(c.l)));
						({test: test == null ? null : x -> ex(test(x)), l: c.l, body: sts(c.body)} : IrCatch);
					}));
				case SCold(id, x): SCold(id, st(x));
				case SPos(_): s;
			}
		}
		sts = ss -> ss.map(st);
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
	public static function lambdaName(owner:FuncInfo):String {
		var n = owner.nlambdas++;
		var name = owner.name + "__lambda" + n;
		// (its Haxe name: the owner's, `$` and its number, a local function in
		// stacks: StackTable, NativeStackTrace; kept by name, which a body
		// the server replays asks again, newLambda)
		if (owner.display != null) lambdaDisplays.set(name, owner.display + "$" + n);
		return name;
	}

	static var lambdaDisplays = new Map<String, String>();

	// hxmc's own metadata (@:hxmc.c, @:hxmc.unsafe, @:hxmc.export, @:hxmc.host)
	public static function hasMeta(name:String, ml:core.Ast.Metadata):Bool
		return core.Meta.has(Custom(name), ml);

	// @:hxmc.unsafe, or its former name @:hxmc.noGc (still accepted): no GC
	// point is reached (Facts.findNoGc checks it)
	public static function isUnsafe(ml:core.Ast.Metadata):Bool
		return hasMeta(":hxmc.unsafe", ml) || hasMeta(":hxmc.noGc", ml);

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

	// hxmc.Byte (through typedefs): a NativeArray of them stores bytes (TU8)
	static function isByte(t:T):Bool
		return switch TFunctions.followWithoutNull(t) {
			case TAbstract(a, _): a.aPath.name == "Byte" && a.aPath.pack.join(".") == "hxmc";
			case _: false;
		};

	public static function isCore(c:TClass, name:String):Bool
		return c.clPath.pack.length == 0 && c.clPath.name == name;

	var methodsDone = 0; // classes whose every method is lowered
	var makersDone = 0; // classes given their Type.createInstance entry (makers)

	function drain() {
		while (true) {
			while (pending.length > 0)
				pending.shift()();
			// all methods of every class seen: structural and dynamic access
			// (Iterator.hasNext, Reflect) reach them through the method tables;
			// DCE already removed the unused ones. A dynamic method is there
			// too: what its field holds before first use (Dyn.anonGetSlow)
			while (methodsDone < tclasses.length) {
				var tc = tclasses[methodsDone++];
				for (f in tc.clOrderedFields)
					if (f.cfKind.match(Method(MethNormal | MethInline | MethDynamic)) && funcOf(f) != null && !f.hasClassFieldFlag(CfExtern))
						method(tc, f);
			}
			if (makers)
				while (makersDone < tclasses.length)
					maker(tclasses[makersDone++]);
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
						// (an Objective-C object: nil is its null)
						if (ObjC.isIdType(params[0])) return TId;
						var inner = ty(params[0]);
						Ir.isScalar(inner) ? TRef(RNull(inner)) : boxed(inner);
					case "Any" if (isStd): TRef(RAny);
					case "Class" | "Enum" if (isStd): TRef(RType);
					case "EnumValue" if (isStd): TRef(REnum(null));
					case "UInt" if (isStd): TI32;
					case "I64" if (a.aPath.pack.join(".") == "hxmc"): TI64;
					// an Objective-C block (ObjC): an id
					case "Block" if (a.aPath.pack.join(".") == "hxmc.objc"): TId;
					// in macro mode (Mir macros, hxmc.interp.MirMacros): the compiler's position, opaque
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
					// (one bound to Objective-C objects: an id, ObjC.isObjCParam)
					case KTypeParameter(_): ObjC.isObjCParam(c) ? TId : TRef(RAny);
					case _:
						if (isCore(c, "String")) TRef(RStr);
						else if (isCore(c, "Array")) TRef(RArr(boxed(ty(params[0]))));
						else if (isNativeArray(c)) TRef(RNativeArr(isByte(params[0]) ? TU8 : boxed(ty(params[0]))));
						else if (CInterop.isStruct(c)) {
							var n = core.Globals.sTypePath(c.clPath);
							structClasses.set(n, c);
							TStruct(n, CInterop.layout(c).size);
						}
						else if (CInterop.isOpaque(c)) TI64; // the address of C memory (CInterop: through a Ptr only)
						else if (ObjC.isObjC(c) || ObjC.isCF(c)) TId; // an Objective-C object (or C's, CGColorRef): its id
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
	var structClasses = new Map<String, TClass>();

	public function structClass(name:String):TClass
		return structClasses.get(name);

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
			case TId: TRef(RAny); // (an id box: FnLower.coerce)
			case _: t;
		}

	// the prefix of a class's fields that no name reaches (no identifier starts with it)
	public static inline var HIDDEN_FIELD = "#";

	// StringBuf, the runtime's extern class
	public static function isRuntimeStringBuf(c:TClass):Bool
		return isCore(c, "StringBuf") && c.hasClassFlag(CExtern);

	// a class, an enum by its path (samePaths: Mir macros, whose compilations
	// hand over the types of a module again, other objects of the same module,
	// which a generation of bundles lowers as one): the first object lowered
	public var samePaths = false;
	var classByPath = new Map<String, TClass>();
	var enumByPath = new Map<String, TEnum>();
	var canonClasses = new haxe.ds.ObjectMap<TClass, TClass>();
	var canonEnums = new haxe.ds.ObjectMap<TEnum, TEnum>();

	public function canonClass(c:TClass):TClass {
		if (!samePaths) return c;
		var o = canonClasses.get(c);
		if (o != null) return o;
		var k = core.Globals.sTypePath(c.clPath);
		o = classByPath.get(k);
		if (o == null || o.clModule.mId != c.clModule.mId) {
			classByPath.set(k, c);
			o = c;
		}
		canonClasses.set(c, o);
		return o;
	}

	public function canonEnum(e:TEnum):TEnum {
		if (!samePaths) return e;
		var o = canonEnums.get(e);
		if (o != null) return o;
		var k = core.Globals.sTypePath(e.ePath);
		o = enumByPath.get(k);
		if (o == null || o.eModule.mId != e.eModule.mId) {
			enumByPath.set(k, e);
			o = e;
		}
		canonEnums.set(e, o);
		return o;
	}

	// a field of c as a field of the class canonClass(c) is (its own object of the field)
	public function canonField(c:TClass, cf:TClassField):TClassField {
		if (!samePaths) return cf;
		var o = canonClass(c);
		if (o == c) return cf;
		if (cf == c.clConstructor) return o.clConstructor != null ? o.clConstructor : cf;
		var x = c.clStatics.get(cf.cfName) == cf ? o.clStatics.get(cf.cfName) : o.clFields.get(cf.cfName);
		return x != null ? x : cf;
	}

	public function classInfo(c:TClass):ClassInfo {
		c = canonClass(c);
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
		// a class extending StringBuf (upstream's Issue6446): StringBuf is the
		// runtime's (T_STRINGBUF), so the subclass starts with its layout, slot
		// 0 the length and slot 1 the units (MemRepr.sbNew; fields that no name
		// reaches, Facts.assignTypes), which the runtime's StringBuf functions
		// and the inline addChar read; its constructor fills them
		// (stringBufCtor). Its class is not a subclass of StringBuf to
		// reflection (Std.isOfType, Type.getSuperClass).
		var sbuf = c.clSuper != null && isRuntimeStringBuf(c.clSuper.cls);
		// (a class extending an Objective-C one: a Haxe object with its id, ObjC)
		var objc = c.clSuper != null && ObjC.isObjC(c.clSuper.cls);
		// (C's objects have no class to subclass: only @:hxmc.objc classes do)
		if (!c.hasClassFlag(CExtern) && c.clSuper != null && ObjC.isCF(c.clSuper.cls))
			throw new LowerError('${c.clPath.name} extends ${c.clSuper.cls.clPath.name}, an object of C without an Objective-C class: only a class declared @:hxmc.objc can be subclassed',
				CInterop.posOf(c.clPos));
		var sup = c.clSuper != null && !sbuf && !objc ? classInfo(c.clSuper.cls) : root;
		// (the superclass's field types may name this class, which has its
		// ClassInfo then: `class Node extends Base<Node>`, upstream's unit test TestGeneric)
		ci = classes.get(c);
		if (ci != null) return ci;
		ci = new ClassInfo(core.Globals.sTypePath(c.clPath), nativeName(c), sup);
		classes.set(c, ci);
		tclasses.push(c);
		var k = c.clSuper;
		while (k != null) {
			var subs = subclasses.get(canonClass(k.cls));
			if (subs == null) subclasses.set(canonClass(k.cls), subs = []);
			subs.push(c);
			k = k.cls.clSuper;
		}
		ci.ifaces = sup.ifaces.copy();
		for (i in c.clImplements) {
			// (a protocol: Objective-C's objects conform to them, a Haxe class's when it extends an Objective-C one)
			if ((ObjC.isProtocol(i.cls) || ObjC.isId(i.cls)) && ObjC.peerBase(c) == null)
				throw new LowerError('${c.clPath.name} implements the Objective-C protocol ${i.cls.clPath.name}: only a class extending an Objective-C class can',
					CInterop.posOf(c.clPos));
			addIface(ci, i.cls);
		}
		prog.classes.push(ci);
		for (f in sup.fields)
			ci.fields.push(f);
		for (d in sup.derived)
			ci.derived.push(d);
		if (sbuf) {
			ci.fields.push({name: HIDDEN_FIELD + "length", ty: TI32});
			ci.fields.push({name: HIDDEN_FIELD + "units", ty: TRef(RAny)});
		}
		if (objc) {
			ci.fields.push({name: ObjC.ID_FIELD, ty: TId});
			ci.fields.push({name: ObjC.CELL_FIELD, ty: TI64});
		}
		var own = [];
		for (f in c.clOrderedFields)
			switch f.cfKind {
				case Var(v) if (isPhysical(c, f, v)):
					if (KernelCheck.spanOf(f.cfType) != null)
						throw new LowerError(KernelCheck.spanError(CInterop.posOf(f.cfPos), "", "the field " + f.cfName + " has a span type", KernelCheck.SPANS_LOCAL), "");
					var slot = {name: f.cfName, ty: null};
					ci.fields.push(slot);
					own.push({slot: slot, f: f});
					var weak = hasMeta(":hxmc.weak", f.cfMeta);
					if (weak && !ObjC.isIdType(f.cfType))
						throw new LowerError('@:hxmc.weak ${f.cfName}: only a field holding an Objective-C object can be weak', CInterop.posOf(f.cfPos));
					// (as Swift's weak variables are optional: it becomes nil once its object is gone)
					if (weak && !TFunctions.isExplicitNull(f.cfType))
						throw new LowerError('@:hxmc.weak ${f.cfName}: a weak field becomes nil once its object is gone: declare it Null<...>', CInterop.posOf(f.cfPos));
					if (ObjC.isIdType(f.cfType)) (weak ? ci.weakFields : ci.idFields).push(f.cfName);
				// a dynamic method's current function (null until first use or assignment, see FnLower.dynMethod)
				case Method(MethDynamic) if (!Lambda.exists(ci.fields, x -> x.name == f.cfName)):
					var slot = {name: f.cfName, ty: null};
					ci.fields.push(slot);
					own.push({slot: slot, f: f});
				// a property Dynamic access and reflection read as the length of a NativeArray field
				case Var(_) if (f.cfMeta.length > 0 && hasMeta(":hxmc.lengthOf", f.cfMeta)):
					ci.derived.push({name: f.cfName, of: metaString(":hxmc.lengthOf", f.cfMeta)});
				case _:
			}
		for (d in ci.derived)
			if (d.of == null || !Lambda.exists(ci.fields, x -> x.name == d.of))
				fail("@:hxmc.lengthOf on " + ci.name + "." + d.name + ": the name of a field of the class, as a string literal");
		// field types may refer back to this class
		outsideUnfolding(() -> for (o in own)
			o.slot.ty = ty(o.f.cfType));
		// (a weak id field: the address of its cell, ObjC)
		for (o in own)
			if (ci.weakFields.indexOf(o.f.cfName) >= 0) o.slot.ty = TI64;
		// (a class extending an Objective-C one, or such a class: its Objective-C
		// class, registered by a function of its own when first needed)
		if (objc || (sup.objc != null)) {
			var root = objc ? ci.ident : sup.objc.root;
			var reg = new FuncInfo(ObjC.REGISTER + ci.ident, moduleOf(c));
			reg.cSymbol = reg.name;
			reg.display = core.Globals.sTypePath(c.clPath) + " (its Objective-C class)";
			reg.ret = TVoid;
			ci.objc = {
				name: ci.ident,
				root: root,
				methods: ObjC.imps(this, c, ci.ident, root),
				classMethods: ObjC.imps(this, c, ci.ident, root, true),
				protocols: [for (p in ObjC.protocols(c)) ObjC.className(p)],
				register: reg
			};
			prog.funcs.push(reg);
			var parent = c.clSuper.cls;
			pending.push(guarded(reg, () -> {
				var fl = new FnLower(this, reg, ci, null);
				fl.objcRegisterBody(parent);
				fl.finish();
			}));
		}
		return ci;
	}

	function addIface(ci:ClassInfo, i:TClass) {
		// (an Objective-C protocol: the Objective-C class's, ObjC.protocols; Id too)
		if (ObjC.isProtocol(i) || ObjC.isId(i)) return;
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
		e = canonEnum(e);
		var ei = enums.get(e);
		if (ei != null) return ei;
		ei = new EnumInfo(core.Globals.sTypePath(e.ePath), ident(e.ePath.pack, e.ePath.name));
		enums.set(e, ei);
		prog.enums.push(ei);
		var ctors = [];
		for (name in e.eNames) {
			var ef = e.eConstrs.get(name);
			ctors.push(new CtorInfo(ei, name, ef.efIndex, vector()));
		}
		ctors.sort((a, b) -> a.tag - b.tag);
		ei.ctors = Vector.fromArrayCopy(ctors);
		outsideUnfolding(() -> for (name in e.eNames) {
			var ef = e.eConstrs.get(name);
			var ci = ei.ctors[ef.efIndex];
			switch TFunctions.follow(ef.efType) {
				case TFun(s):
					ci.params = s.args.map(a -> boxed(ty(a.type)));
					ci.paramNames = s.args.map(a -> a.name);
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
		defaults.set(fi, new ArgDefaults(ds, vs));
	}

	// a method's own default values (an override may declare others than the
	// declaration it shares its signature with), the receiver first
	static function ownDefaults(tf:TFunc):ArgDefaults
		return new ArgDefaults([null].concat([for (a in tf.tfArgs) a.defaultValue]), [null].concat([for (a in tf.tfArgs) a.variable]));

	function defaultValues(f:FuncInfo):Null<Array<Null<TExpr>>> {
		var d = defaults.get(f);
		return d == null ? null : d.values;
	}

	public function argDefaults(f:FuncInfo):Null<ArgDefaults>
		return defaults.get(f);

	public function fieldDefaults(c:TClass, cf:TClassField):Null<ArgDefaults> {
		var tf = funcOf(cf);
		return tf == null ? null : ownDefaults(tf);
	}

	public function staticFunc(c:TClass, cf:TClassField):FuncInfo {
		cf = canonField(c, cf);
		c = canonClass(c);
		var fi = funcs.get(cf);
		if (fi != null) return fi;
		var tf = funcOf(cf);
		if (tf == null) fail("static " + cf.cfName + " is not a function");
		fi = new FuncInfo(nativeName(c) + "_" + cf.cfName, moduleOf(c));
		fieldAttrs(fi, cf, c);
		funcs.set(cf, fi);
		prog.funcs.push(fi);
		signature(fi, tf, null);
		if (isCreateInstance(fi.name)) makers = true;
		if (cf.cfMeta.length > 0 && hasMeta(":hxmc.hostCode", cf.cfMeta)) {
			// (its body stands for the compiler's native code: never lowered;
			// Facts takes what that code does instead of scanning it)
			var h = hostCode == null ? null : hostCode(fi);
			if (h == null) fail(fi.display + " has no body (@:hxmc.hostCode: the native code of the compiler that typed it), and this compiler lacks it");
			fi.hostCode = true;
			fi.gcScan = {gc: !h.noGc, here: h.blocks, addr: false, callees: [], names: []};
			return fi;
		}
		if (hasMeta(":hxmc.callback", cf.cfMeta)) callback(fi, cf);
		whenTyped(c, cf, guarded(fi, () -> lowerBody(fi, cf, () -> {
			var fl = new FnLower(this, fi, null, null);
			fl.run(funcOf(cf));
			fl.finish();
		})));
		return fi;
	}

	// (-D hxmc.macros=mir: hxmc.interp.MirMacros, while it lowers) whether a
	// field's body may be lowered now: the macro context types the std's
	// bodies when they are asked for (TypeBinding.lazyBodies) and hands the
	// types they load over after; null: always
	public static var bodyReady:Null<(TClass, TClassField) -> Bool> = null;
	// the bodies that may not be lowered yet: their fields, their lowering
	// (`resume` once they may)
	public var deferred:Array<{c:TClass, cf:TClassField, lower:() -> Void}> = [];

	// a field's body lowered (`lower`, when drain runs it), or deferred
	function whenTyped(c:TClass, cf:TClassField, lower:() -> Void)
		pending.push(() -> if (bodyReady != null && !bodyReady(c, cf)) deferred.push({c: c, cf: cf, lower: lower}) else lower());

	// the deferred bodies lowered (drain runs them)
	public function resume() {
		var ds = deferred;
		deferred = [];
		for (d in ds)
			pending.push(d.lower);
	}

	// @:hxmc.callback: a static function C calls through its address
	// (hxmc.unsafe.Callback.addr) in the C convention (hxmc's own). Its
	// symbol is fixed (the address C keeps names it). A @:hxmc.unsafe callback
	// is the function itself: it may run on any thread, in any state. Any
	// other is reached through a wrapper that leaves the safe region the
	// calling thread is in (a call of C that is not @:hxmc.fast, the only
	// kind that may call back) and enters it again on return. One taking or
	// returning structs by value always has a wrapper (FuncInfo.cAbi).
	public function callbackSym(fi:FuncInfo):String
		return "hxmc_cb_" + fi.name;

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
		var sym = callbackSym(fi);
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
			var xs = w.args.mapToVector(a -> (ELocal(a) : Ex));
			var body:Array<Stmt> = [];
			var gc = !fi.declNoGc && targetOs != 3;
			if (gc) body.push(SExpr(ECallHost("rt_blocking_leave", vector(), TVoid)));
			var r = new Local(w.args.length, "r", fi.ret == TVoid ? TI32 : fi.ret);
			if (fi.sret) {
				w.locals.push(r);
				body.push(SSet(r, ECallHost("hxmc_unsafe_Mem_structSlot", vector(EInt(switch fi.ret { case TStruct(_, s): s; case _: 8; }), EInt(8)), TI64)));
				body.push(SExpr(ECall(fi, xs.snoc(ELocal(r)))));
			} else if (fi.ret != TVoid) {
				w.locals.push(r);
				body.push(SSet(r, ECall(fi, xs)));
			} else body.push(SExpr(ECall(fi, xs)));
			if (gc) body.push(SExpr(ECallHost("rt_blocking_enter", vector(), TVoid)));
			body.push(SReturn(fi.ret == TVoid ? null : ELocal(r)));
			w.body = Vector.fromArrayCopy(body);
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
		var call = ECall(fi, w.args.mapToVector(a -> (ELocal(a) : Ex)));
		if (fi.ret == TVoid)
			w.body = vector(SExpr(ECallHost("rt_blocking_leave", vector(), TVoid)), SExpr(call), SExpr(ECallHost("rt_blocking_enter", vector(), TVoid)), SReturn(null));
		else {
			var r = new Local(w.args.length, "r", fi.ret);
			w.locals.push(r);
			w.body = vector(SExpr(ECallHost("rt_blocking_leave", vector(), TVoid)), SSet(r, call), SExpr(ECallHost("rt_blocking_enter", vector(), TVoid)), SReturn(ELocal(r)));
		}
		prog.funcs.push(w);
	}

	// hxmc's attributes of a function: @:hxmc.unsafe, @:hxmc.kernel and
	// @:hxmc.blocking (checked by Facts.findNoGc), @:hxmc.collects (it runs
	// the collector), @:hxmc.export (its symbol) (@:hxmc.unsafe and
	// @:hxmc.kernel on a class: on each of its functions)
	static function fieldAttrs(fi:FuncInfo, cf:TClassField, c:TClass) {
		fi.pos = cf.cfPos;
		fi.display = core.Globals.sTypePath(c.clPath) + "." + cf.cfName;
		if (c.clMeta.length > 0) {
			if (isUnsafe(c.clMeta)) fi.declNoGc = fi.declUnsafe = true;
			if (hasMeta(":hxmc.kernel", c.clMeta)) fi.declNoGc = fi.declKernel = true;
		}
		if (cf.cfMeta.length == 0) return;
		if (isUnsafe(cf.cfMeta)) fi.declNoGc = fi.declUnsafe = true;
		if (hasMeta(":hxmc.kernel", cf.cfMeta)) fi.declNoGc = fi.declKernel = true;
		fi.declBlocking = hasMeta(":hxmc.blocking", cf.cfMeta);
		if (fi.declBlocking) fi.declNoGc = fi.declKernel = true;
		fi.collects = hasMeta(":hxmc.collects", cf.cfMeta);
		fi.withStacks = hasMeta(":hxmc.withStacks", cf.cfMeta);
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
		cf = canonField(c, cf);
		c = canonClass(c);
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
			defaults.set(fi, ownDefaults(tf));
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
					defaults.set(fi, ownDefaults(tf));
				case _: signature(fi, tf, TRef(RObj(root)));
			}
		} else signature(fi, tf, TRef(RObj(root)));
		whenTyped(c, cf, guarded(fi, () -> lowerBody(fi, cf, () -> {
			var fl = new FnLower(this, fi, ci, null);
			fl.run(funcOf(cf));
			fl.finish();
		})));
		fi.dfltEntry = defaultsEntry(fi, ci);
		return fi;
	}

	// A method called dynamically (by name through Dynamic, Reflect) may be
	// given fewer arguments than it has: where it has default values for
	// numbers or Bools, its entry in the method table (DataGen.types: dynamic
	// and structural calls) is this one, those arguments nullable
	// (closureArgTy, as a closure of a function type with optional
	// arguments), null meaning the default (null: the method itself is the
	// entry). A constructor's, for Type.createInstance: maker.
	function defaultsEntry(fi:FuncInfo, ci:ClassInfo):Null<FuncInfo> {
		if (fi.sret) return null;
		var ds = defaultValues(fi);
		if (ds == null) return null;
		var tys = [for (i in 1...fi.args.length) closureArgTy(fi.args[i].ty, i < ds.length ? ds[i] : null)];
		var differs = false;
		for (i in 0...tys.length)
			if (tys[i] != fi.args[i + 1].ty) differs = true;
		if (!differs) return null;
		var w = new FuncInfo(fi.name + "__dflt", fi.module);
		w.args.push(new Local(0, "this0", fi.args[0].ty));
		for (i in 0...tys.length)
			w.args.push(new Local(i + 1, fi.args[i + 1].name, tys[i]));
		w.ret = fi.ret;
		w.pos = fi.pos;
		w.display = fi.display;
		prog.funcs.push(w);
		pending.push(guarded(w, () -> lowerBody(w, null, () -> {
			var fl = new FnLower(this, w, ci, null);
			fl.forwardDefaults(fi);
			fl.finish();
		})));
		return w;
	}

	// Type.createInstance can be called: the lowering met the runtime's
	// function (staticFunc; a program whose classes another one makes, as the
	// compiler makes macro code's, may set it too). Every class seen then gets
	// its entry (ClassInfo.maker), which Reach keeps where live code can have
	// the class value; a program that never calls it gets none.
	public var makers = false;

	// the runtime's Type.createInstance: Reach's too
	public static function isCreateInstance(name:String):Bool
		return name == "hxmc_rt_Dyn_createInstance";

	// (a constructor's entry, shared by the subclasses calling it)
	var ctorEntries = new Map<FuncInfo, FuncInfo>();

	// c's entry for Type.createInstance (ClassInfo.maker): the constructor
	// `new` calls (its own, else the nearest superclass's), its entry for
	// dynamic calls where it has default values for numbers or Bools; none to
	// call when no class of the chain has one (the call fails, as Eval's);
	// no entry when an argument is a struct, which no array of Dynamic holds
	function maker(c:TClass) {
		var ci = classInfo(c);
		var k = c;
		while (k.clConstructor == null && k.clSuper != null)
			k = k.clSuper.cls;
		if (k.clConstructor == null) {
			ci.maker = {fn: null};
			return;
		}
		var f = ctor(k);
		if (isRuntimeStringBuf(k)) {
			ci.maker = {fn: f};
			return;
		}
		if (hasStruct(f)) return;
		var e = ctorEntries.get(f);
		if (e == null) {
			e = defaultsEntry(f, classInfo(k));
			if (e == null) e = f;
			ctorEntries.set(f, e);
		}
		ci.maker = {fn: e};
	}

	public function ctor(c:TClass):FuncInfo {
		c = canonClass(c);
		var fi = ctors.get(c);
		if (fi != null) return fi;
		if (isRuntimeStringBuf(c)) return stringBufCtor(c);
		var ci = classInfo(c);
		fi = new FuncInfo(nativeName(c) + "_new", moduleOf(c));
		fi.display = core.Globals.sTypePath(c.clPath) + ".new";
		ci.ctor = fi;
		ctors.set(c, fi);
		prog.funcs.push(fi);
		if (c.clConstructor == null) {
			// no constructor: the parent's, or nothing
			signature(fi, {tfArgs: vector(), tfType: null, tfExpr: null}, TRef(RObj(ci)));
			fi.ret = TVoid;
			return fi;
		}
		var tf = funcOf(c.clConstructor);
		signature(fi, tf, TRef(RObj(ci)));
		fi.ret = TVoid;
		pending.push(guarded(fi, () -> lowerBody(fi, c.clConstructor, () -> {
			var fl = new FnLower(this, fi, ci, null);
			fl.run(tf, true);
			fl.finish();
		})));
		return fi;
	}

	// StringBuf's constructor as a subclass's super(): the runtime fills the
	// length and the units of the new instance (Str.sbInit)
	function stringBufCtor(c:TClass):FuncInfo {
		var fi = new FuncInfo("StringBuf_new__super", moduleOf(c));
		fi.display = "StringBuf.new";
		ctors.set(c, fi);
		prog.funcs.push(fi);
		var self = new Local(0, "this0", TRef(RAny));
		fi.args.push(self);
		fi.ret = TVoid;
		fi.body = vector(SExpr(ECallHost(native("StringBuf_init"), vector(ELocal(self)), TVoid)), SReturn(null));
		pending.push(() -> bindHosts(fi));
		return fi;
	}

	// the constructor of a @:hxmc.struct class: a function of the struct's
	// address (this) and the arguments, which fills the memory (zeroed by
	// the caller, FnLower.newStruct)
	var structCtors = new Map<TClass, FuncInfo>();

	public function structCtor(c:TClass):FuncInfo {
		c = canonClass(c);
		var fi = structCtors.get(c);
		if (fi != null) return fi;
		fi = new FuncInfo(nativeName(c) + "_new", moduleOf(c));
		fi.display = core.Globals.sTypePath(c.clPath) + ".new";
		fi.structCtor = true;
		structCtors.set(c, fi);
		prog.funcs.push(fi);
		var tf = funcOf(c.clConstructor);
		signature(fi, tf, TI64);
		fi.ret = TVoid;
		pending.push(guarded(fi, () -> lowerBody(fi, c.clConstructor, () -> {
			var fl = new FnLower(this, fi, null, null);
			fl.runStructCtor(tf);
			fl.finish();
		})));
		return fi;
	}

	// `name` and `module`: a name that stays the same when unrelated code changes
	// (Lower.lambdaName for closures in a function body, else derived from what
	// the closure forwards to) and the module whose C file holds it
	public function newLambda(sig:SigInfo, captures:Vector<Local>, body:FnLower->Void, name:String, module:String):LambdaInfo {
		var fi = new FuncInfo(name, module);
		fi.display = lambdaDisplays.get(name);
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
		pending.push(guarded(fi, () -> lowerBody(fi, null, () -> {
			var fl = new FnLower(this, fi, null, li);
			body(fl);
			fl.finish();
		})));
		return li;
	}

	// a closure calling a static function (the function used as a value)
	var staticClosures = new Map<FuncInfo, LambdaInfo>();

	// the class is used as a value: its statics become reachable dynamically
	// (Reach keeps those live code can reach; an interface's: the __meta__
	// the filters give it). They are those Eval has (not extern nor generic; a
	// variable with storage or an initializer: an inline one's sets a global
	// too, FnLower.runInit), in Eval's order, the reference's:
	// Type.getClassFields lists the names of its static prototype by their
	// hashes (EvalStdLib's getClassFields folds an IntMap, Globals', whose
	// keys go down, onto a list)
	public function reflectStatics(c:TClass) {
		if (c.hasClassFlag(CExtern) || CInterop.isNativeClass(c)) return;
		var ci = classInfo(c);
		if (ci.statics != null) return;
		ci.statics = [];
		for (cf in c.clOrderedStatics) {
			if (cf.hasClassFieldFlag(CfExtern) || cf.hasClassFieldFlag(CfGeneric)) continue;
			switch cf.cfKind {
				// (a function taking or returning a struct is not reachable by name)
				case Method(MethNormal | MethInline) if (funcOf(cf) != null && !hasStruct(staticFunc(c, cf))):
					var f = staticFunc(c, cf);
					ci.statics.push({name: cf.cfName, clos: staticClosure(f), fn: f, global: -1});
				case Var(v) if ((cf.cfExpr != null || isPhysical(c, cf, v)) && !ty(cf.cfType).match(TStruct(_))):
					var g = staticVar(c, cf);
					// (not a thread's own, nor the address of a block: no global holds those)
					if (prog.globals[g].tls == null && prog.globals[g].bss == null)
						ci.statics.push({name: cf.cfName, clos: null, fn: null, global: g});
				case _:
			}
		}
		var hash = [for (s in ci.statics) s.name => macros.eval.EvalHash.camlHashString(s.name)];
		ci.statics.sort((a, b) -> {
			var x = hash[a.name], y = hash[b.name];
			x != y ? (x < y ? -1 : 1) : a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
		});
	}

	// an enum used as a value: haxe.rtti.Meta reads its metadata as the static
	// __meta__ (a class has the field from the compiler's filters; an enum's
	// is Texpr.buildMetadata's, as the other targets' generators write it),
	// a global its initializer sets, before the classes' (metaInits)
	public function reflectEnum(e:TEnum) {
		var ei = enumInfo(e);
		if (ei.statics != null) return;
		ei.statics = [];
		var m = core.Texpr.buildMetadata(basic, TEnumDecl(e));
		if (m == null) return;
		var g = prog.globals.length;
		prog.globals.push({ty: TRef(RAny), init: null, name: ei.ident + "___meta__"});
		ei.statics.push({name: "__meta__", clos: null, fn: null, global: g});
		var fi = new FuncInfo(ei.ident + "__meta", core.Globals.sTypePath(e.eModule.mPath));
		prog.funcs.push(fi);
		prog.inits.push(fi);
		metaInits.set(fi, true);
		pending.push(guarded(fi, () -> {
			var fl = new FnLower(this, fi, null, null);
			fl.runGlobalInit(g, m);
			fl.finish();
		}));
	}

	var metaInits = new Map<FuncInfo, Bool>();

	static function hasStruct(f:FuncInfo):Bool {
		for (a in f.args)
			if (a.ty.match(TStruct(_))) return true;
		return f.sret;
	}

	public function staticClosure(f:FuncInfo):LambdaInfo {
		var li = staticClosures.get(f);
		if (li != null) return li;
		var ds = defaultValues(f);
		var sig = prog.sig([
			for (i in 0...f.args.length)
				if (!(f.sret && i == f.args.length - 1)) closureArgTy(f.args[i].ty, ds != null && i < ds.length ? ds[i] : null)
		], f.ret);
		li = newLambda(sig, vector(), fl -> fl.forward(f, null), f.name + "__sclos", f.module);
		// (named as the function: its body, inlined here, is that function's in stacks)
		li.fn.display = f.display;
		staticClosures.set(f, li);
		return li;
	}

	var hostClosures = new Map<String, LambdaInfo>();

	// a closure calling a runtime function (an extern static used as a value)
	public function hostClosure(name:String, sig:SigInfo, ?self:Ty):LambdaInfo {
		var li = hostClosures.get(name);
		if (li != null) return li;
		li = newLambda(sig, self == null ? vector() : vector(new Local(-1, "self", self)), fl -> fl.forwardHost(name), name + "__hclos", "_closures");
		hostClosures.set(name, li);
		return li;
	}

	var ctorClosures = new Map<CtorInfo, LambdaInfo>();

	public function ctorClosure(ci:CtorInfo, sig:SigInfo):LambdaInfo {
		var li = ctorClosures.get(ci);
		if (li != null) return li;
		li = newLambda(sig, vector(), fl -> fl.forwardCtor(ci), ci.en.ident + "_" + ci.name + "__cclos", "_closures");
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
			return newLambda(sig, vector(self), fl -> fl.forward(null, dispatch), lambdaName(owner), owner.module);
		}
		var li = boundClosures.get(f);
		if (li != null && dispatch == null) return li;
		var ds = defaultValues(f);
		var args = [for (i in 1...(f.sret ? f.args.length - 1 : f.args.length)) closureArgTy(f.args[i].ty, ds != null && i < ds.length ? ds[i] : null)];
		var sig = prog.sig(args, f.ret);
		var self = new Local(-1, "self", TRef(RObj(root)));
		li = newLambda(sig, vector(self), fl -> fl.forward(f, dispatch), dispatch == null ? f.name + "__bound" : lambdaName(owner), dispatch == null ? f.module : owner.module);
		if (f != null) li.fn.display = f.display;
		if (dispatch == null) boundClosures.set(f, li);
		return li;
	}

	// Objective-C blocks (ObjC.blockSig): the invoke of the blocks of a
	// signature (its symbol), and the closure calling such a block, once per
	// signature and C types
	var blockInvokes = new Map<String, String>();

	public function blockInvoke(b:ObjC.BlockSig):String {
		var key = ObjC.blockKey(b);
		var sym = blockInvokes.get(key);
		if (sym != null) return sym;
		sym = ObjC.INVOKE + haxe.io.Bytes.ofString(key).toHex();
		blockInvokes.set(key, sym);
		ObjC.invoke(this, sym, b);
		return sym;
	}

	var blockCallers = new Map<String, LambdaInfo>();

	public function blockCaller(b:ObjC.BlockSig):LambdaInfo {
		var key = ObjC.blockKey(b);
		var li = blockCallers.get(key);
		if (li != null) return li;
		var box = new Local(-1, "block", TRef(RAny));
		li = newLambda(b.sig, vector(box), fl -> fl.blockCall(b), "blockcall__" + key, "_closures");
		blockCallers.set(key, li);
		return li;
	}

	// a closure converting between two closure representations
	var adapters = new Map<String, LambdaInfo>();

	public function adapter(from:SigInfo, to:SigInfo):LambdaInfo {
		var key = from.key + ">" + to.key;
		var li = adapters.get(key);
		if (li != null) return li;
		var inner = new Local(-1, "inner", TRef(RClos(from)));
		li = newLambda(to, vector(inner), fl -> fl.adapt(from), "adapt__" + from.key + "__" + to.key, "_closures");
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
		li = newLambda(to, vector(inner), fl -> fl.adaptDynamic(), "dynadapt__" + to.key, "_closures");
		dynAdapters.set(to.key, li);
		return li;
	}

	var staticVars = new Map<TClassField, Int>();
	// the class whose static variable a global is (interp.MirMacros: what a new
	// generation of macro bundles carries over)
	public var globalOwner = new Map<Int, TClass>();

	// a class static variable: a global, initialized by the static initializer
	public function staticVar(c:TClass, cf:TClassField):Int {
		cf = canonField(c, cf);
		c = canonClass(c);
		var g = staticVars.get(cf);
		if (g != null) return g;
		if (KernelCheck.spanOf(cf.cfType) != null)
			throw new LowerError(KernelCheck.spanError(CInterop.posOf(cf.cfPos), "", "the static " + cf.cfName + " has a span type", KernelCheck.SPANS_LOCAL), "");
		var t = ty(cf.cfType); // first: it may register globals itself (enum constructors)
		g = prog.globals.length;
		globalOwner.set(g, c);
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
	public var initOf = new Map<FuncInfo, TClass>();

	// static variable initializers and __init__ of a class, run at startup
	// (in the order of com.types, see `program`)
	function initClass(c:TClass) {
		c = canonClass(c);
		if (initialized.exists(c)) return;
		initialized.set(c, true);
		var fi = new FuncInfo(nativeName(c) + "__init", moduleOf(c));
		prog.funcs.push(fi);
		prog.inits.push(fi);
		initOf.set(fi, c);
		// (a class's __init__ runs whether or not live code reads its statics: Reach)
		if (c.clInit != null) prog.roots.push(fi);
		pending.push(guarded(fi, () -> lowerBody(fi, null, () -> {
			var fl = new FnLower(this, fi, null, null);
			fl.runInit(c);
			fl.finish();
		})));
	}

	public function rootClass():ClassInfo
		return root;

	public function getProgram():Program
		return prog;

	public function sig(args:Array<Ty>, ret:Ty):SigInfo
		return prog.sig(args, ret);

	public function shape(fields:Array<{name:String, ty:Ty}>):ShapeInfo
		return prog.shape(fields);

	public function globalTy(g:Int):Ty
		return prog.globals[g].ty;

	public function selectorName(s:Int):String
		return prog.selectors[s].name;

	// C function (or variable) sym, the extern field cf of c, declared for this program
	// (called by the bodies calling it: CInterop.reset forgets the previous program's)
	public function cExtern(sym:String, c:TClass, cf:TClassField):CInterop.CSig {
		// (a C variable: no arguments, its type the result)
		if (CInterop.isVar(c, cf)) return CInterop.declareVar(sym, c, cf);
		var s = switch TFunctions.follow(cf.cfType) {
			case TFun(s): s;
			case _: fail("extern static " + cf.cfName + " is not a function");
		}
		return CInterop.declare(sym, c, cf, s);
	}

	// Objective-C's declaration d, for this program (as cExtern)
	public function objcDeclare(d:ObjC.Decl):Void
		ObjC.define(d);

	public function objcPeer(ci:ClassInfo):Null<ObjCClass>
		return ci.objc;

	public function idFields(ci:ClassInfo):Array<String>
		return ci.idFields;

	public function weakFields(ci:ClassInfo):Array<String>
		return ci.weakFields;

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
		var subs = subclasses.get(canonClass(c));
		if (subs != null)
			for (d in subs)
				if (d.clFields.exists(name) && d.clFields.get(name).cfExpr != null) return true;
		// (a class of the compiler code is loaded into: its own subclasses may override)
		if (hostOverrides != null && hostOverrides.exists(core.Globals.sTypePath(c.clPath) + "." + name)) return true;
		// a subclass lowered later may still override: dispatch if any
		// descendant the typer knows does (clDescendants holds the direct
		// subclasses: their subclasses too)
		return overriddenBelow(c, name);
	}

	// the methods the compiler's own classes override ("pack.C.name": code
	// loaded into the compiler, interp.MirMacros, macro.Loader.hostOverrides)
	public static var hostOverrides:Null<Map<String, Bool>> = null;

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

	public function classOf(ci:ClassInfo):Null<TClass> {
		for (tc => c in classes)
			if (c == ci) return tc;
		return null;
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
