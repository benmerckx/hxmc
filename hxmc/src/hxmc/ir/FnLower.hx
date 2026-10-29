package hxmc.ir;

import hxmc.ir.Ir;
import hxmc.ir.Lower;
import hxmc.ir.LowerQueries;
import hxmc.ir.CInterop;
import core.Ast.Binop;
import core.Ast.Unop;
import core.Ast.UnopFlag;
import core.Ast.WhileFlag;
import core.TType;
import core.TFunctions;
import core.ds.VectorTools;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

using core.TFunctions;
using core.ds.VectorTools;

// Lowers one function body to IR statements (A-normal form: calls and
// allocations only as the value of an SSet/SExpr). Every lowered expression
// has the representation of its typed-AST type, `ty(e.etype)`; consumers
// convert with `coerce`.
class FnLower {
	var l:LowerQueries; // (not Lower: what a body asks is what the compilation server's reuse covers)
	var fi:FuncInfo;
	var self:Null<ClassInfo>;
	var lambda:Null<LambdaInfo>;
	var locals = new Map<Int, Local>();
	var structAliases = new Map<Int, TClass>(); // locals bound to a C struct class (Struct's argument)
	public var boxed:Map<Int, Bool>;
	var thisLocal:Null<Local>;
	var sretLocal:Null<Local> = null; // fi.sret: the address of the caller's memory for the result
	// struct values in this frame that nothing else holds (a call's result, a
	// copy): whoever takes one keeps it as its own memory
	var freshSlots = new Map<Local, Bool>();
	var curExpr:Null<TExpr> = null; // (the expression being lowered: errors)
	var structCtor = false; // (lowering a struct's constructor)
	var out:Array<Stmt> = []; // (the statements of the block being lowered)
	var nextLocal = 0;

	public function new(l, fi, self, lambda) {
		this.l = l;
		this.fi = fi;
		this.self = self;
		this.lambda = lambda;
		nextLocal = fi.args.length + 1;
		if (Lower.callSites != null && Lower.callSites.wants(fi)) {
			site = newLocal("site", TI32);
			out.push(SSet(site, ECallHost("hxmc_unsafe_Mem_getI32", vector(siteData(Lower.callSites.pending), EInt(0)), TI32)));
		}
	}

	// lowering a constructor (ObjC: super.init...)
	var inCtor = false;

	// (Lower.callSites) this function's site: where it was called from
	var site:Null<Local> = null;

	function siteData(sym:String):Ex
		return temp(TI64, ECallHost("hxmc_unsafe_Mem_sym", vector(EStr(sym)), TI64));

	// (Lower.callSites) before the call `e` (its arguments evaluated): its site, and this function's
	function noteCall(e:TExpr) {
		if (site == null) return;
		var cs = Lower.callSites;
		out.push(SExpr(ECallHost("hxmc_unsafe_Mem_setI32", vector(siteData(cs.pending), EInt(0), EInt(cs.site(e.epos))), TVoid)));
		out.push(SExpr(ECallHost("hxmc_unsafe_Mem_setI32", vector(siteData(cs.current), EInt(0), ELocal(site)), TVoid)));
	}

	// the body lowered (by one of the entry points below) becomes fi's
	public function finish()
		fi.body = Vector.fromArrayCopy(out);

	// (the expression's file and line, and the function being lowered)
	function fail(msg:String, ?e:TExpr):Dynamic {
		var at = e != null ? where(e) : "";
		throw new LowerError(msg, (at != "" ? at + " in " : "") + fi.name);
	}

	inline function ty(t:T):Ty
		return l.ty(t);

	inline function tyOf(e:TExpr):Ty
		return l.ty(e.etype);

	// the default values of a function's arguments, and their variables (LowerQueries.argDefaults)
	function defaultValues(f:FuncInfo):Null<Array<Null<TExpr>>> {
		var d = l.argDefaults(f);
		return d == null ? null : d.values;
	}

	function argVars(f:FuncInfo):Null<Array<Null<TVar>>> {
		var d = l.argDefaults(f);
		return d == null ? null : d.vars;
	}

	function newLocal(name:String, t:Ty):Local {
		if (t == TVoid) t = TI32;
		var lo = new Local(nextLocal++, name, t);
		fi.locals.push(lo);
		return lo;
	}

	// ---- entry points

	// a function body; `fi.args` already holds the caller-visible signature
	public function run(tf:TFunc, isCtor = false) {
		// (a kernel not @:hxmc.unsafe: the safe subset, docs/interop.md)
		if (fi.declKernel && !fi.declUnsafe) KernelCheck.check(l, fi, tf);
		spanSignature(tf);
		if (boxed == null) boxed = Boxing.analyze(tf.tfExpr, tf.tfArgs.mapToArray(a -> a.variable));
		var off = 0;
		if (self != null) {
			off = 1;
			if (isCtor) thisLocal = fi.args[0] else {
				thisLocal = newLocal("this", TRef(RObj(self)));
				out.push(SSet(thisLocal, ECast(thisLocal.ty, ELocal(fi.args[0]))));
			}
		}
		if (fi.sret) sretLocal = fi.args[fi.args.length - 1];
		bindArgs(tf, off);
		if (isCtor) objcOwnFields();
		if (isCtor) {
			inCtor = true;
			objcConstructor(tf);
		}
		stmt(tf.tfExpr);
	}

	// the constructor of a @:hxmc.struct class (Lower.structCtor): this is
	// the struct's address
	public function runStructCtor(tf:TFunc) {
		boxed = Boxing.analyze(tf.tfExpr, tf.tfArgs.mapToArray(a -> a.variable));
		thisLocal = fi.args[0];
		structCtor = true;
		spanSignature(tf);
		bindArgs(tf, 1);
		stmt(tf.tfExpr);
	}

	function bindArgs(tf:TFunc, off:Int) {
		for (i in 0...tf.tfArgs.length) {
			var v = tf.tfArgs[i].variable;
			var a = fi.args[i + off];
			var t = ty(v.vType);
			// direct calls pass defaults; calls through closures and Dynamic pass null
			var d = tf.tfArgs[i].defaultValue;
			if (d != null && Ir.isRef(a.ty) && !strip(d).eexpr.match(TConst(TNull)))
				out.push(SIf(EBin(RefEq, ELocal(a), ENull(a.ty)), block(() -> out.push(SSet(a, coerceRhs(rhs(d), tyOf(d), a.ty)))), vector()));
			var x:Ex = ELocal(a);
			if (Ir.repr(t) != Ir.repr(a.ty) || refConversion(a.ty, t)) {
				var lo = newLocal(v.vName, t);
				out.push(SSet(lo, coerce(x, a.ty, t)));
				x = ELocal(lo);
			}
			// (a span: its two words copied into a slot of this frame, which no call
			// takes, so that they stay in registers, Sroa: the caller's memory
			// would be read again after every store, which may alias it)
			var sc = KernelCheck.spanOf(v.vType) != null ? structOf(v.vType) : null;
			if (sc != null && !boxed.exists(v.vId)) {
				var own = newSlot(t, false);
				copyStruct(ELocal(own), x, sc);
				x = ELocal(own);
			}
			if (boxed.exists(v.vId)) {
				var b = newLocal(v.vName + "_box", TRef(RBox(t)));
				out.push(SSet(b, ENewBox(t, x)));
				locals.set(v.vId, b);
			} else switch x {
				case ELocal(lo): locals.set(v.vId, lo);
				case _:
			}
		}
	}

	// the body of a closure literal
	public function runLambda(tf:TFunc, outerBoxed:Map<Int, Bool>, captured:Array<{id:Int, ty:Ty}>) {
		boxed = outerBoxed;
		var inner = Boxing.analyze(tf.tfExpr, tf.tfArgs.mapToArray(a -> a.variable));
		for (k in inner.keys())
			boxed.set(k, true);
		var clos = ELocal(fi.args[0]);
		for (i in 0...captured.length) {
			var c = captured[i];
			var lo = newLocal(c.id == -1 ? "this" : "cap" + i, c.ty);
			out.push(SSet(lo, ECapture(lambda, i, clos)));
			if (c.id == -1) thisLocal = lo else locals.set(c.id, lo);
		}
		if (fi.sret) sretLocal = fi.args[fi.args.length - 1];
		spanSignature(tf);
		bindArgs(tf, 1);
		stmt(tf.tfExpr);
	}

	// static initializer: every static var with an expression, then __init__
	public function runInit(c:TClass) {
		boxed = new Map();
		for (cf in c.clOrderedStatics)
			switch cf.cfKind {
				case Var(_) if (cf.cfExpr != null):
					var g = l.staticVar(c, cf);
					var t = l.globalTy(g);
					var sc = structOf(cf.cfType);
					if (sc != null) {
						copyStruct(EGlobal(g, t), structRhs(cf.cfExpr).x, sc);
						continue;
					}
					var x = value(cf.cfExpr);
					out.push(SSetGlobal(g, coerce(x, tyOf(cf.cfExpr), t)));
				case _:
			}
		if (c.clInit != null && c.clInit.cfExpr != null) switch c.clInit.cfExpr.eexpr {
			case TFunction(tf):
				boxed = Boxing.analyze(tf.tfExpr, []);
				stmt(tf.tfExpr);
			case _: stmt(c.clInit.cfExpr);
		}
	}

	// an initializer setting the global g to e (Lower.reflectEnum)
	public function runGlobalInit(g:Int, e:TExpr) {
		boxed = new Map();
		var t = l.globalTy(g);
		out.push(SSetGlobal(g, coerce(value(e), tyOf(e), t)));
	}

	// closure body forwarding to a function (static or bound method)
	public function forward(f:Null<FuncInfo>, dispatch:Null<{sel:Int, sig:SigInfo, args:Array<Ty>, ?cls:TClass}>) {
		boxed = new Map();
		var args = [];
		var self = lambda.captures.length > 0 ? 1 : 0; // (the callee's arguments start with the receiver)
		var recv:Null<Local> = null;
		if (self > 0) {
			recv = newLocal("self", TRef(RObj(l.rootClass())));
			out.push(SSet(recv, ECapture(lambda, 0, ELocal(fi.args[0]))));
			args.push((ELocal(recv) : Ex));
		}
		var ds = f != null ? defaultValues(f) : null;
		var vars = f != null ? argVars(f) : null;
		var argTys = [for (x in args) TRef(RObj(l.rootClass()))];
		var last = fi.sret ? fi.args.length - 1 : fi.args.length;
		for (k in 1...fi.args.length) {
			var a = fi.args[k];
			var j = k - 1 + self;
			var target = k >= last ? a.ty : f != null ? f.args[j].ty : dispatch.args[j];
			switch a.ty {
				// (signatures keep references as Dynamic: a nullable number is a box)
				case TRef(_) if (target == TI32 || target == TF64 || target == TBool):
					var t = target;
					// (left out: the callee's default value, for the receiver's class when dispatched)
					var d = ds != null && j < ds.length ? ds[j] : null;
					var v = newLocal("o", t);
					var dflt = block(() -> {
						var x = d != null ? defaultValue(d, t, j, vars, args, argTys, recv != null ? () -> ELocal(recv) : null, f.selfClass) : nullOf(t);
						if (dispatch != null && dispatch.cls != null && recv != null) {
							var y = receiverDefault(dispatch.cls, l.selectorName(dispatch.sel), ELocal(recv), j, d, t, x, args, argTys);
							if (y != null) x = y;
						}
						out.push(SSet(v, x));
					});
					out.push(SIf(EBin(RefEq, ELocal(a), ENull(a.ty)), dflt, vector(SSet(v, coerce(ELocal(a), a.ty, t)))));
					args.push(ELocal(v));
					argTys.push(t);
				// (the function takes a closure, or a NativeArray, as the type it
				// declares, which the one passed here may not have: signatures keep
				// it Dynamic)
				case _ if (refConversion(a.ty, target)):
					args.push(coerce(ELocal(a), a.ty, target));
					argTys.push(target);
				case _:
					args.push(ELocal(a));
					argTys.push(a.ty);
			}
		}
		var xs = Vector.fromArrayCopy(args);
		var call = dispatch != null ? ECallDispatch(dispatch.sel, dispatch.sig, xs) : ECall(f, xs);
		var ret = f != null ? f.ret : dispatch.sig.ret;
		if (fi.sret) {
			// (the closure's result address is the function's: its last argument)
			out.push(SExpr(call));
			out.push(SReturn(ELocal(fi.args[fi.args.length - 1])));
			return;
		}
		if (fi.ret == TVoid) {
			out.push(SExpr(call));
			out.push(SReturn(null));
		} else {
			var r = newLocal("r", ret);
			out.push(SSet(r, call));
			out.push(SReturn(ELocal(r)));
		}
	}

	// the body of a method's entry for dynamic calls (Lower.defaultsEntry):
	// its nullable arguments null take the method's defaults
	public function forwardDefaults(f:FuncInfo) {
		boxed = new Map();
		var ds = defaultValues(f);
		var vars = argVars(f);
		var args:Array<Ex> = [ELocal(fi.args[0])];
		var argTys = [fi.args[0].ty];
		for (k in 1...fi.args.length) {
			var a = fi.args[k], t = f.args[k].ty;
			var d = ds != null && k < ds.length ? ds[k] : null;
			if (a.ty == t || d == null) {
				args.push(ELocal(a));
				argTys.push(a.ty);
				continue;
			}
			var v = newLocal("o", t);
			out.push(SIf(EBin(RefEq, ELocal(a), ENull(a.ty)), block(() -> out.push(SSet(v, defaultValue(d, t, k, vars, args, argTys, () -> ELocal(fi.args[0]), f.selfClass)))),
				vector(SSet(v, coerce(ELocal(a), a.ty, t)))));
			args.push(ELocal(v));
			argTys.push(t);
		}
		if (f.ret == TVoid) {
			out.push(SExpr(ECall(f, Vector.fromArrayCopy(args))));
			out.push(SReturn(null));
		} else {
			var r = newLocal("r", f.ret);
			out.push(SSet(r, ECall(f, Vector.fromArrayCopy(args))));
			out.push(SReturn(ELocal(r)));
		}
	}

	// closure body calling a runtime function
	public function forwardHost(name:String) {
		boxed = new Map();
		// (the receiver first, when there is one)
		var self = lambda.captures.length > 0 ? 1 : 0;
		var args = new Vector<Ex>(fi.args.length - 1 + self);
		for (i in 1...fi.args.length)
			args[i - 1 + self] = ELocal(fi.args[i]);
		if (self > 0) {
			var s = newLocal("self", lambda.captures[0].ty);
			out.push(SSet(s, ECapture(lambda, 0, ELocal(fi.args[0]))));
			args[0] = receiverCheck(ELocal(s), s.ty);
		}
		if (fi.ret == TVoid) {
			out.push(SExpr(ECallHost(name, args, TVoid)));
			out.push(SReturn(null));
		} else {
			var r = newLocal("r", fi.ret);
			out.push(SSet(r, ECallHost(name, args, fi.ret)));
			out.push(SReturn(ELocal(r)));
		}
	}

	// closure body constructing an enum value
	public function forwardCtor(ci:CtorInfo) {
		boxed = new Map();
		var args = new Vector<Ex>(fi.args.length - 1);
		for (i in 1...fi.args.length)
			args[i - 1] = ELocal(fi.args[i]);
		var r = newLocal("r", fi.ret);
		out.push(SSet(r, ENewEnum(ci, args)));
		out.push(SReturn(ELocal(r)));
	}

	// closure body converting arguments and result between representations
	public function adapt(from:SigInfo) {
		boxed = new Map();
		var inner = newLocal("inner", TRef(RClos(from)));
		out.push(SSet(inner, ECapture(lambda, 0, ELocal(fi.args[0]))));
		var args = new Vector<Ex>(from.args.length);
		for (i in 0...from.args.length) {
			var a = fi.args[i + 1];
			args[i] = coerce(ELocal(a), a.ty, from.args[i]);
		}
		var call = ECallClos(from, ELocal(inner), args);
		if (fi.ret == TVoid) {
			out.push(SExpr(call));
			out.push(SReturn(null));
		} else if (from.ret == TVoid) {
			out.push(SExpr(call));
			out.push(SReturn(nullOf(fi.ret)));
		} else {
			var r = newLocal("r", from.ret);
			out.push(SSet(r, call));
			out.push(SReturn(coerce(ELocal(r), from.ret, fi.ret)));
		}
	}

	// closure body calling a Dynamic value (its capture) with the arguments
	// boxed (hx_dyn_call), its result converted to this signature's
	public function adaptDynamic() {
		boxed = new Map();
		var inner = newLocal("inner", TRef(RAny));
		out.push(SSet(inner, ECapture(lambda, 0, ELocal(fi.args[0]))));
		var xs = new Vector<Ex>(fi.args.length - 1);
		for (i in 1...fi.args.length)
			xs[i - 1] = coerce(ELocal(fi.args[i]), fi.args[i].ty, TRef(RAny));
		var arr = temp(TRef(RArr(TRef(RAny))), ENewArr(TRef(RAny), xs));
		var call = ECallHost(l.native("hx_dyn_call"), vector(ELocal(inner), arr), TRef(RAny));
		if (fi.ret == TVoid) {
			out.push(SExpr(call));
			out.push(SReturn(null));
		} else {
			var r = newLocal("r", TRef(RAny));
			out.push(SSet(r, call));
			out.push(SReturn(coerce(ELocal(r), TRef(RAny), fi.ret)));
		}
	}

	// ---- helpers

	function local(v:TVar, e:TExpr):Local {
		var lo = locals.get(v.vId);
		if (lo == null) fail("unknown local " + v.vName, e);
		return lo;
	}

	function block(f:() -> Void):Vector<Stmt> {
		var saved = out;
		out = [];
		f();
		var r = out;
		out = saved;
		return Vector.fromArrayCopy(r);
	}

	function temp(t:Ty, e:Ex):Ex {
		var lo = newLocal("t", t);
		out.push(SSet(lo, e));
		return ELocal(lo);
	}

	// (not a global: a static variable a later operand's call may assign)
	static function isConst(e:Ex):Bool
		return switch e {
			case EInt(_) | EF64(_) | EStr(_) | ENull(_) | EType(_): true;
			case _: false;
		}

	// runtime functions that neither allocate nor call back into Haxe code
	public static var PURE = [
		"hx_str_eq" => true, "hx_str_cmp" => true, "hx_dyn_eq" => true, "hx_dyn_cmp" => true, "hx_is" => true, "String_length" => true,
		"String_charCodeAt_i" => true, "hx_str_hash" => true,
		"hx_unbox_int" => true, "hx_unbox_float" => true, "hx_unbox_bool" => true
	];
	// the Math natives: pure, expanded inline by MirBuild
	public static var MATH = [
		for (n in ["NaN", "POSITIVE_INFINITY", "NEGATIVE_INFINITY", "PI", "abs", "acos", "asin", "atan", "atan2", "cos", "sin", "tan", "exp", "log", "sqrt", "pow",
			"floor", "ceil", "round", "ffloor", "fceil", "fround", "max", "min", "isNaN", "isFinite"])
			"Math_" + n => true
	];
	// expanded inline by MirBuild: no function is emitted for them
	public static var RT_INLINE = {
		var m = MATH.copy();
		m.set("StringBuf_addChar", true);
		m;
	};
	// natives that never allocate (not GC points), with side effects
	public static var NOGC = ["Math_random" => true, "hx_box_bool" => true];

	public static function isPure(n:String):Bool
		return PURE.exists(n) || MATH.exists(n) || PURE_INTRINSICS.exists(n)
			|| StringTools.startsWith(n, "hxmc_narray_get_") || n == "hxmc_narray_length";

	// C functions declared @:hxmc.c (hxmc.unsafe.LibC): called with the C ABI,
	// never GC points (filled while lowering)
	public static var C_EXTERNS = new Map<String, Bool>();
	// the variadic ones: their first variadic argument (@:hxmc.varargs)
	public static var C_VARIADIC = new Map<String, Int>();
	// the intrinsics of hxmc.unsafe (MirBuild.intrinsic): no GC point but the
	// allocations; these are pure (they read no memory)
	public static var PURE_INTRINSICS = [
		for (n in ["addr", "obj", "sym", "cstr", "abi", "os", "arm", "target", "platform", "mirHost", "ult", "spanUlt", "udiv", "urem", "stack", "structSlot", "f64Bits", "bitsF64", "words"])
			"hxmc_unsafe_Mem_" + n => true
	];

	public static inline function isIntrinsic(n:String):Bool
		return StringTools.startsWith(n, "hxmc_unsafe_Mem_") || StringTools.startsWith(n, "hxmc_unsafe_Atomic_");

	// a runtime function call that is not a GC point
	public static function noGcHost(n:String):Bool
		return isPure(n) || NOGC.exists(n) || C_EXTERNS.exists(n) || StringTools.startsWith(n, "hxmc_narray_set_")
			|| (isIntrinsic(n) && !StringTools.startsWith(n, "hxmc_unsafe_Mem_alloc") && !StringTools.startsWith(n, "hxmc_unsafe_Mem_call"));

	// the layout an object literal of the structural type t gets, when the
	// field `name` has the representation rt there
	function anonHint(t:T, name:String, rt:Ty):Null<ShapeInfo> {
		switch TFunctions.follow(t) {
			case TAnon(an) if (an.aStatus.match(Closed | Const)):
				// (in the order of the names: a map's order follows its insertions,
				// which differ for a type read from HXB, and ty numbers the types it meets)
				var names = l.anonNames(an);
				var fs = [for (k in names) {name: k, ty: l.boxed(ty(an.aFields.get(k).cfType))}];
				var sh = l.shape(fs);
				var i = sh.slot(name);
				return i > 0 && Ir.repr(sh.fields[i - 1].ty) == Ir.repr(rt) ? sh : null;
			case _:
				return null;
		}
	}

	// haxe.ds.Vector's data (an Array on hxmc), as Vector.get inlines it
	// the typedef itself, not what it follows to: lazy types (HXB reads typedef
	// instances as TLazy) and bound monomorphs are looked through
	static function isVectorData(t:T):Bool
		return switch t {
			case TLazy(f): isVectorData(TFunctions.lazyType(f));
			case TMono(r) if (r.tmType != null): isVectorData(r.tmType);
			case TType(td, _): td.tPath.name == "VectorData" && StringTools.startsWith(td.tPath.pack.join("."), "haxe.ds"); // haxe.ds._Vector.VectorData
			case TAbstract(a, _): a.aPath.name == "Vector" && a.aPath.pack.join(".") == "haxe.ds";
			case _: false;
		}

	public static function isImpure(e:Ex):Bool
		return switch e {
			case ECall(_) | ECallDispatch(_) | ECallClos(_) | ECallAnon(_) | ENewObj(_) | ENewEnum(_) | ENewArr(_) | ENewClos(_) | ENewBox(_) | ENewAnon(_) | EBox(_):
				true;
			case ECallHost(n, _, _): !isPure(n);
			case EArrGet(TRef(RAny), _, _) | EArrGetU(TRef(RAny), _, _): true; // reading an Int/Float array as Dynamic boxes
			case EAnonGet(_): true; // the slow path may box
			case _: false;
		}

	// lowers operands left to right; spills earlier ones when a later one has side effects
	function operands(es:Vector<TExpr>):Vector<Ex> {
		var r = new Vector<Ex>(es.length);
		for (n in 0...es.length) {
			var e = es[n];
			var before = out.length;
			// (a struct: a copy of its own, made now)
			var sc = structOf(e.etype);
			var x = sc != null ? ELocal(structOwn(e, sc)) : value(e);
			if (out.length != before) {
				var spills = [];
				for (i in 0...n)
					if (!isConst(r[i]) && !stableFrom(r[i], before)) {
						var lo = newLocal("s", tyOf(es[i]));
						spills.push(SSet(lo, r[i]));
						r[i] = ELocal(lo);
					}
				for (j in 0...spills.length)
					out.insert(before + j, spills[j]);
			}
			r[n] = x;
		}
		return r;
	}

	// a local that the statements from `before` on (a later operand's) do not
	// assign: read after them, it is the value it had (`[i, s.cca(i++)]`, which the
	// analyzer leaves in that order: upstream's TestStringTools; corpus case
	// OperandOrder)
	function stableFrom(x:Ex, before:Int):Bool {
		var l = switch x {
			case ELocal(l): l;
			case _: return false;
		}
		for (k in before...out.length)
			if (assigns(out[k], l)) return false;
		return true;
	}

	static function assigns(s:Stmt, l:Local):Bool {
		inline function any(ss:Vector<Stmt>):Bool {
			var r = false;
			for (s in ss)
				if (assigns(s, l)) {
					r = true;
					break;
				}
			return r;
		}
		return switch s {
			case SSet(x, _): x == l;
			case SIf(_, a, b): any(a) || any(b);
			case SLoop(b): any(b);
			case SSwitch(_, cs, d):
				var r = any(d);
				for (c in cs)
					if (!r && any(c.body)) r = true;
				r;
			case STry(b, cs):
				var r = any(b);
				for (c in cs)
					if (!r && (c.l == l || any(c.body))) r = true;
				r;
			case SCold(_, s2): assigns(s2, l);
			case _: false;
		}
	}

	// x, lowered before the statements from `before` on (a later operand's
	// effects): read into a local ahead of them unless constant
	function spillBefore(x:Ex, t:Ty, before:Int):Ex {
		if (out.length == before || isConst(x) || stableFrom(x, before)) return x;
		var lo = newLocal("s", t);
		out.insert(before, SSet(lo, x));
		return ELocal(lo);
	}

	// a call's receiver o, evaluated before the statements from `before` on
	// (its arguments'), as a local: a default value reads it (defaultValue)
	function receiverLocal(o:Ex, t:Ty, before:Int):Ex {
		o = spillBefore(o, t, before);
		return isConst(o) || o.match(ELocal(_)) ? o : ELocal(asLocal(o, t));
	}

	// operands converted to the given representations (missing trailing ones:
	// defaults; `callee` the function they are of, `recv` its receiver, when
	// one may read its arguments or `this`: defaultValue)
	function args(es:Vector<TExpr>, to:Vector<Ty>, defaults:Null<Array<Null<TExpr>>>, offset = 0, ?callee:FuncInfo, ?recv:() -> Ex):Vector<Ex> {
		var xs = operands(es);
		var vars = callee != null ? argVars(callee) : null;
		var r = [], rTys = [];
		// (before a default value that is not a constant, outside of the branch
		// it may be in: the arguments as locals when it reads them or is in
		// a branch, the receiver when it reads it)
		function prepare(d:TExpr, branch:Bool) {
			if (constDefault(d)) return;
			var reads = vars != null && readsFunction(d, vars);
			if (!reads && !branch) return;
			for (k in 0...r.length)
				if (!isConst(r[k]) && !r[k].match(ELocal(_))) r[k] = ELocal(asLocal(r[k], rTys[k]));
			if (reads && recv != null) {
				var o = recv();
				recv = () -> o;
			}
		}
		// the default value d of argument i (of `to`), after the arguments before it
		function dflt(d:TExpr, i:Int):Ex {
			if (constDefault(d)) return coerce(value(d), tyOf(d), to[i]);
			var before = out.length;
			var x = defaultValue(d, to[i], i, vars, [for (k in 0...offset) null].concat(r), [for (k in 0...offset) null].concat(rTys), recv,
				callee != null ? callee.selfClass : null);
			// (its effects come after the arguments: those not read yet are read first)
			if (out.length != before) {
				var spills = [];
				for (k in 0...r.length)
					if (!isConst(r[k]) && !stableFrom(r[k], before)) {
						var lo = newLocal("s", rTys[k]);
						spills.push(SSet(lo, r[k]));
						r[k] = ELocal(lo);
					}
				for (j in 0...spills.length)
					out.insert(before + j, spills[j]);
			}
			return x;
		}
		for (i in 0...xs.length) {
			var t = i + offset < to.length ? to[i + offset] : TRef(RAny);
			var d = defaults != null && i + offset < defaults.length ? defaults[i + offset] : null;
			var from = tyOf(es[i]);
			if (d != null && Ir.isRef(from) && (t == TI32 || t == TF64 || t == TBool)) {
				// null for an argument with a default value: the default (Null<Int> passed
				// to `x:Int = 1`, as a bind's closure does with an argument left out)
				var x = asLocal(xs[i], from);
				var v = newLocal("o", t);
				prepare(d, true);
				out.push(SIf(EBin(RefEq, ELocal(x), ENull(from)), block(() -> out.push(SSet(v, dflt(d, i + offset)))),
					vector(SSet(v, coerce(ELocal(x), from, t)))));
				r.push(ELocal(v));
				rTys.push(t);
				continue;
			}
			r.push(coerce(xs[i], from, t));
			rTys.push(t);
		}
		for (i in xs.length + offset...to.length) {
			var d = defaults != null && i < defaults.length ? defaults[i] : null;
			if (d != null) prepare(d, false);
			r.push(d != null ? dflt(d, i) : nullOf(to[i]));
			rTys.push(to[i]);
		}
		return Vector.fromArrayCopy(r);
	}

	// A static function called or taken through one of its @:overload
	// signatures: a copy of its field with that type and no body
	// (typeload.ml's build_overloads), which a non-extern class implements
	// with the function itself; an extern class's is a function of its own.
	static function overloadImpl(c:TClass, cf:TClassField):TClassField {
		if (cf.cfExpr != null || c.hasClassFlag(CExtern)) return cf;
		var impl = c.clStatics.get(cf.cfName);
		return impl != null && impl.cfExpr != null && impl.cfOverloads.indexOf(cf) >= 0 ? impl : cf;
	}

	// ---- default values

	// A default value lowered outside of its function: calls pass those of
	// numbers and Bools themselves (and of references they leave out), the
	// forwarders of closures and dynamic calls fill them in. One reading the
	// function's arguments or `this` (Haxe 5: `function f(a:Int, b:Int = a)`,
	// `x:Int = this.y`) reads those of this call: `vars` are the function's
	// argument variables (Lower.argVars; null: the receiver, `recv`, an
	// instance of `cls`), `given` the values passed for those before argument
	// `i` (`givenTys` their representations), locals or constants.
	function defaultValue(d:TExpr, t:Ty, i:Int, vars:Null<Array<Null<TVar>>>, given:Array<Null<Ex>>, givenTys:Array<Null<Ty>>, recv:Null<() -> Ex>,
			cls:Null<ClassInfo>):Ex {
		if (vars == null || !readsFunction(d, vars)) return coerce(value(d), tyOf(d), t);
		// (`this` there is the receiver: none outside a method)
		var self = recv != null && cls != null ? recv() : null;
		var saved = [];
		for (k in 0...i) {
			var v = k < vars.length ? vars[k] : null;
			if (v == null) continue;
			var lo = newLocal(v.vName, ty(v.vType));
			out.push(SSet(lo, coerce(given[k], givenTys[k], lo.ty)));
			saved.push({id: v.vId, lo: locals.get(v.vId), boxed: boxed.exists(v.vId)});
			locals.set(v.vId, lo);
			boxed.remove(v.vId);
		}
		var savedThis = thisLocal;
		thisLocal = null;
		if (self != null) {
			thisLocal = newLocal("this", TRef(RObj(cls)));
			out.push(SSet(thisLocal, ECast(thisLocal.ty, self)));
		}
		function restore() {
			thisLocal = savedThis;
			for (s in saved) {
				if (s.lo != null) locals.set(s.id, s.lo) else locals.remove(s.id);
				if (s.boxed) boxed.set(s.id, true);
			}
		}
		var x = try coerce(value(d), tyOf(d), t) catch (e:Dynamic) {
			restore();
			throw e;
		}
		restore();
		return x;
	}

	// a default value that is a constant (as every one was before Haxe 5)
	static function constDefault(d:TExpr):Bool
		return switch strip(d).eexpr {
			case TConst(_): true;
			case TUnop(_, _, e): constDefault(e);
			case _: false;
		}

	// whether d reads the arguments `vars` or `this`
	static function readsFunction(d:TExpr, vars:Array<Null<TVar>>):Bool {
		var found = false;
		function loop(e:TExpr) {
			if (found) return;
			switch e.eexpr {
				case TConst(TThis | TSuper):
					found = true;
				case TLocal(v):
					for (w in vars)
						if (w != null && w.vId == v.vId) found = true;
				case _:
					core.Texpr.iter(loop, e);
			}
		}
		loop(d);
		return found;
	}

	static function tys(f:FuncInfo):Vector<Ty>
		return f.args.mapToVector(a -> a.ty);

	function asLocal(x:Ex, t:Ty):Local {
		return switch x {
			case ELocal(lo): lo;
			case _:
				var lo = newLocal("a", t);
				out.push(SSet(lo, x));
				lo;
		}
	}

	// -D hxmc.null-checks (Lower.nullChecks): the receiver x of a method the
	// runtime implements (String's, Array's, an extern class's), whose code
	// reads it without a test, tested against null before the call (the
	// program's own methods test what they read: MirBuild.nullCheck); null
	// throws "Null Access", as the native targets' fault handler does where
	// the runtime reads it (hxmc.rt.Faults); none in a @:hxmc.unsafe function,
	// which promises no GC point (a throw is one: Facts.findNoGc) and reads
	// memory unchecked, as the runtime's own code does
	function receiverCheck(x:Ex, t:Ty):Ex {
		if (!Lower.nullChecks || fi.declNoGc || !Ir.isRef(t)) return x;
		switch x {
			case EStr(_) | EType(_): return x;
			case _:
		}
		var r = ELocal(asLocal(x, t));
		out.push(SIf(EBin(RefEq, r, ENull(t)), vector(SThrow(EStr("Null Access"))), vector()));
		return r;
	}

	static function strip(e:TExpr):TExpr
		return switch e.eexpr {
			case TParenthesis(e1) | TMeta(_, e1): strip(e1);
			case TCast(e1, null): strip(e1);
			case _: e;
		}

	function nullOf(t:Ty):Ex
		return switch t {
			case TI32 | TBool | TU8: EInt(0);
			case TF64: EF64(0);
			case TI64: EConv(I2L, EInt(0));
			case TId: EConv(I2L, EInt(0)); // (nil)
			case TVoid: EInt(0);
			case TRef(_): ENull(t);
			case TStruct(n, _): structFail('the struct $n is never null (a value: zero its fields; Null<S> may be null)');
		}

	// ---- conversions

	// converts x from representation `from` to `to`: boxing, unboxing, numeric
	// conversion, closure adapters. Allocations go to a temporary.
	public function coerce(x:Ex, from:Ty, to:Ty):Ex {
		if (to == TVoid || from == TVoid) return x;
		switch [from, to] {
			case [TStruct(a, _), TStruct(b, _)]:
				if (a != b) structFail('the struct $a used as the struct $b');
				return x;
			// (its address: Ptr casts and the intrinsics)
			case [TStruct(_), TI64] | [TI64, TStruct(_)]:
				return x;
			case [TStruct(n, _), TRef(RClos(_))] | [TRef(RClos(_)), TStruct(n, _)]:
				structFail('the struct $n converted to or from a function');
			case [TStruct(n, _), TRef(_)]:
				return coerce(box(x, n), l.boxed(from), to);
			case [TRef(_), TStruct(n, _)]:
				return unbox(x, from, n);
			case [TStruct(n, _), _] | [_, TStruct(n, _)]:
				structFail('the struct $n converted to or from a number');
			case [TRef(RClos(a)), TRef(r)] if (!r.match(RClos(_)) && hasStruct(a)):
				structFail('a function taking or returning a struct value cannot become ' + (r == RAny ? "Dynamic" : "another type") + ' (call it directly)');
			case _:
		}
		switch [from, to] {
			// Objective-C objects (ObjC): an id is an i64, so a Ptr's cast
			// reinterprets it
			case [TId, TI64] | [TI64, TId]:
				return x;
			// an instance of a class extending an Objective-C one where an id
			// goes: its id (ObjC.ID_FIELD; null: nil)
			case [TRef(RObj(ci)), TId | TI64] if (Lambda.exists(ci.fields, f -> f.name == ObjC.ID_FIELD)):
				var o = asLocal(x, from);
				var r = newLocal("id", TId);
				out.push(SIf(EBin(RefEq, ELocal(o), ENull(from)), vector(SSet(r, EConv(I2L, EInt(0)))),
					vector(SSet(r, EField(ci, ci.fieldIndex(ObjC.ID_FIELD), ELocal(o))))));
				return ELocal(r);
			// an id as an instance of such a class (an unchecked cast): its Haxe
			// object, by the index in its instance variable (nil: null)
			case [TId | TI64, TRef(RObj(ci))] if (ci.objc != null):
				var id = asLocal(x, from);
				var r = newLocal("peer", to);
				var off = ECallHost("hxmc_unsafe_Mem_getI64", vector(ECallHost("hxmc_unsafe_Mem_sym", vector(EStr(ObjC.IVAR_CELL + ci.objc.root)), TI64), EInt(0)), TI64);
				var index = ECallHost("hxmc_unsafe_Mem_getI32", vector(EBin(LAdd, ELocal(id), off), EInt(0)), TI32);
				out.push(SIf(EBin(LEq, ELocal(id), EConv(I2L, EInt(0))), vector(SSet(r, ENull(to))),
					vector(SSet(r, ECast(to, ECallHost("rt_objc_peer_get", vector(index), TRef(RAny)))))));
				return ELocal(r);
			// an id where a reference goes (Dynamic, an element, a type
			// parameter): a box that holds a reference to it (nil: null)
			case [TId, TRef(_)]:
				var box = temp(TRef(RAny), ECallHost("rt_objc_box", vector(x, ECallHost("hxmc_unsafe_Mem_sym", vector(EStr(ObjC.symbol("objc_retain"))), TI64),
					ECallHost("hxmc_unsafe_Mem_sym", vector(EStr(ObjC.symbol("objc_release"))), TI64)), TRef(RAny)));
				return coerce(box, TRef(RAny), to);
			// a box's id (or a Haxe object's whose class extends an Objective-C one)
			case [TRef(_), TId]:
				var o = coerce(x, from, TRef(RAny));
				return temp(TId, ECallHost("rt_objc_unbox", vector(o), TId));
			// a typed view takes storage of its own kind (rt/NArray.view): from
			// a Dynamic-typed view or a Dynamic, and between the kinds Haxe lets
			// alias (Int and Null<Int>), checked; an open wrapper's storage, converted
			case [_, TRef(RNativeArr(b))] if (nativeConversion(from, to)):
				return temp(to, ECallHost(l.native("hx_narray_view"), vector(x, EInt(nativeKind(b))), to));
			case [TRef(RClos(a)), TRef(RClos(b))] if (a != b):
				if (x.match(ENull(_))) return ENull(to);
				if (hasStruct(a) || hasStruct(b)) structFail('a function taking or returning a struct value cannot become a function of another type');
				var li = l.adapter(a, b);
				var c = asLocal(x, from);
				var r = newLocal("adapted", to);
				out.push(SIf(EBin(RefEq, ELocal(c), ENull(from)), vector(SSet(r, ENull(to))), vector(SSet(r, ENewClos(li, vector(ELocal(c)))))));
				return ELocal(r);
			case [TRef(RAny), TRef(RClos(b))]:
				// a Dynamic as a function: kept when it is a closure of this
				// signature, else called through an adapter (its signature may
				// differ: a () -> Bool's result is not boxed)
				if (x.match(ENull(_))) return ENull(to);
				var c = asLocal(x, from);
				var r = newLocal("closure", to), same = newLocal("same", from);
				out.push(SIf(EBin(RefEq, ELocal(c), ENull(from)), vector(SSet(r, ENull(to))), vector(
					SSet(same, ECallHost(l.native("hx_clos_of_sig"), vector(ELocal(c), EStr(b.key)), TRef(RAny))),
					SIf(EBin(RefEq, ELocal(same), ENull(from)), vector(SSet(r, ENewClos(l.dynAdapter(b), vector(ELocal(c))))), vector(SSet(r, ECast(to, ELocal(same)))))
				)));
				return ELocal(r);
			case _:
		}
		var fr = Ir.repr(from), tr = Ir.repr(to);
		if (fr == tr) return x;
		return switch [from, to] {
			case [TI32, TF64]: EConv(I2F, x);
			case [TF64, TI32]: EConv(F2I, x);
			case [TI32 | TBool, TI64]: EConv(I2L, x);
			case [TI64, TI32]: EConv(L2I, x);
			case [TI64, TBool]: EBin(LNe, x, EConv(I2L, EInt(0)));
			case [TI64, TF64]: EConv(L2F, x);
			case [TF64, TI64]: EConv(F2L, x);
			case [TI32, TBool] | [TBool, TI32]: x;
			case [TF64, TBool]: EBin(FNe, x, EF64(0));
			case [TBool, TF64]: EConv(I2F, x);
			case [_, TRef(RNull(t))] if (Ir.isScalar(from)):
				x.match(ENull(_)) ? ENull(to) : temp(to, EBox(t, coerce(x, from, t)));
			case [_, TRef(_)] if (Ir.isScalar(from)):
				temp(to, EBox(from, x));
			case [TRef(_), _] if (Ir.isScalar(to)):
				x.match(ENull(_)) ? nullOf(to) : EUnbox(to, x);
			case _: x;
		}
	}

	static function nativeKind(elem:Ty):Int
		return switch elem {
			case TI32: 1;
			case TBool: 4;
			case TF64: 2;
			case TI64: 3;
			case TU8: 5;
			case _: 0;
		};

	// the type of the values of a NativeArray's elements: a byte's an Int
	static function elemValue(elem:Ty):Ty
		return elem == TU8 ? TI32 : elem;

	// the suffix of the typed accesses of a NativeArray (MirBuild), by nativeKind
	static final NATIVE_SUFFIX = ["p", "i", "f", "l", "b", "u"];

	// a NativeArray whose element is Dynamic (Dynamic, Any, an erased type
	// parameter) may hold any kind of storage, or be a wrapper (rt/NArray)
	static function dynElem(elem:Ty):Bool
		return elem.match(TRef(RAny));

	// element i of NativeArray a (both locals or constants, as they are read
	// again by the test of the index), the access at p: tested as -D
	// hxmc.native-array-outofbounds says (Lower.bounds); no p: not tested (the
	// std's own loops)
	function nativeRead(elem:Ty, a:Ex, i:Ex, ?p:core.Globals.Pos):Ex {
		var get = ECallHost(dynElem(elem) ? "hxmc_narray_dget" : "hxmc_narray_get_" + NATIVE_SUFFIX[nativeKind(elem)], vector(a, i), elemValue(elem));
		switch p == null ? Lower.BOUNDS_UNCHECKED : Lower.bounds {
			case Lower.BOUNDS_SILENT:
				var r = newLocal("e", elemValue(elem));
				// (seen as Dynamic: the default of the storage's kind)
				var none = dynElem(elem) ? ECallHost(l.native("hx_narray_default"), vector(a), elem) : nullOf(elemValue(elem));
				out.push(SIf(inBounds(a, i), vector(SSet(r, get)), vector(SSet(r, none))));
				return ELocal(r);
			case Lower.BOUNDS_THROWS:
				out.push(SIf(inBounds(a, i), vector(), vector(SThrow(outOfBounds(a, i, p)))));
			case _:
		}
		return dynElem(elem) ? temp(elem, get) : get;
	}

	// a[i] = x (x: a local or constant), as nativeRead
	function nativeWrite(elem:Ty, a:Ex, i:Ex, x:Ex, ?p:core.Globals.Pos) {
		var set = SExpr(ECallHost(dynElem(elem) ? "hxmc_narray_dset" : "hxmc_narray_set_" + NATIVE_SUFFIX[nativeKind(elem)], vector(a, i, x), TVoid));
		out.push(switch p == null ? Lower.BOUNDS_UNCHECKED : Lower.bounds {
			case Lower.BOUNDS_SILENT: SIf(inBounds(a, i), vector(set), vector());
			case Lower.BOUNDS_THROWS: SIf(inBounds(a, i), vector(set), vector(SThrow(outOfBounds(a, i, p))));
			case _: set;
		});
	}

	// (one unsigned comparison: negative indices too; the length of a
	// wrapper is its storage's)
	static function inBounds(a:Ex, i:Ex):Ex
		return ECallHost("hxmc_unsafe_Mem_ult", vector(i, ECallHost("hxmc_narray_length", vector(a), TI32)), TBool);

	// the exception, with the position of the access (thrown at once: the
	// call is the throw statement's own)
	function outOfBounds(a:Ex, i:Ex, p:core.Globals.Pos):Ex {
		var d = fi.display != null ? fi.display : fi.name;
		var dot = d.lastIndexOf(".");
		var file = EStr(p.pfile), line = EInt(CInterop.lineOf(p.pfile, p.pmin)), cls = EStr(dot < 0 ? "" : d.substr(0, dot)), name = EStr(d.substr(dot + 1));
		return ECallHost(l.native("hx_narray_oob"), vector(i, ECallHost("hxmc_narray_length", vector(a), TI32), file, line, cls, name), TRef(RAny));
	}

	// a value converted to String (for concatenation)
	function toStr(x:Ex, t:Ty):Ex {
		return switch t {
			case TRef(RStr): temp(TRef(RStr), ECallHost(l.native("hx_str_or_null"), vector(x), TRef(RStr)));
			case TI32: temp(TRef(RStr), ECallHost(l.native("hx_str_of_int"), vector(x), TRef(RStr)));
			case TF64: temp(TRef(RStr), ECallHost(l.native("hx_str_of_float"), vector(x), TRef(RStr)));
			case TI64: temp(TRef(RStr), ECallHost(l.native("hx_str_of_i64"), vector(x), TRef(RStr)));
			case TBool: temp(TRef(RStr), ECallHost(l.native("hx_str_of_bool"), vector(x), TRef(RStr)));
			case TStruct(_): toStr(coerce(x, t, TRef(RAny)), TRef(RAny));
			case _: temp(TRef(RStr), ECallHost(l.native("hx_std_string"), vector(x), TRef(RStr)));
		}
	}

	// ---- appends to a string in a loop

	// `s += x` in a loop (or `s = s + x + ...`) where nothing else reads or
	// writes the local s: s's units go to a StringBuf, made at the second
	// append (one append concatenates as before), and s becomes the buffer's
	// string after the loop, so the loop copies each unit about twice rather
	// than s's whole length at every append. Not inside a try of this
	// function (a catch could read s after an exception left the loop), nor
	// for a local a closure captures (it is boxed); every way out of the loop
	// but an exception (its break, the end) reaches the code after it, and an
	// exception leaves s dead. A read or write of s that the lowering meets
	// anyway takes the buffer's string first (flushAppend).
	var tryDepth = 0;
	var appends = new Map<Int, {buf:Local, first:Local, s:Local}>();

	static final SBUF = TRef(RNative("StringBuf"));

	// the locals of the loop (condition c, body) whose units go to a buffer,
	// their buffers declared (null: none)
	function appendLoop(c:TExpr, body:TExpr):Null<Array<Int>> {
		if (tryDepth > 0 || fi.declNoGc) return null;
		var cands:Array<TVar> = [];
		function find(e:TExpr) {
			switch e.eexpr {
				case TBinop(OpAssignOp(OpAdd), {eexpr: TLocal(v)}, _) | TBinop(OpAssign, {eexpr: TLocal(v)}, {eexpr: TBinop(OpAdd, _, _)})
					if (!isBoxed(v) && !appends.exists(v.vId) && locals.exists(v.vId) && locals.get(v.vId).ty.match(TRef(RStr))
						&& ty(v.vType).match(TRef(RStr)) && cands.indexOf(v) < 0):
					cands.push(v);
				case _:
			}
			core.Texpr.iter(find, e);
		}
		find(body);
		var r = null;
		for (v in cands)
			if (onlyAppends(c, v, false) && onlyAppends(body, v, true)) {
				var buf = newLocal(v.vName + "_buf", SBUF), first = newLocal(v.vName + "_first", TBool);
				out.push(SSet(buf, ENull(SBUF)));
				out.push(SSet(first, EInt(1)));
				appends.set(v.vId, {buf: buf, first: first, s: locals.get(v.vId)});
				if (r == null) r = [];
				r.push(v.vId);
			}
		return r;
	}

	// after the loop: s from its buffer
	function appendLoopEnd(ids:Null<Array<Int>>) {
		if (ids == null) return;
		for (id in ids) {
			var a = appends.get(id);
			appends.remove(id);
			out.push(SIf(EBin(RefNe, ELocal(a.buf), ENull(SBUF)), vector(SSet(a.s, ECallHost(l.native("StringBuf_toString"), vector(ELocal(a.buf)), TRef(RStr)))), vector()));
		}
	}

	// whether every use of v in e is an append as a statement (stmt: e is one)
	function onlyAppends(e:TExpr, v:TVar, stmt:Bool):Bool {
		inline function no(x:TExpr):Bool
			return onlyAppends(x, v, false);
		return switch e.eexpr {
			case TBinop(OpAssignOp(OpAdd), {eexpr: TLocal(w)}, r) if (w == v):
				stmt && no(r);
			case TBinop(OpAssign, {eexpr: TLocal(w)}, r) if (w == v):
				var xs = stmt ? appendedTo(r, v) : null;
				if (xs == null) return false;
				for (x in xs)
					if (!no(x)) return false;
				true;
			case TLocal(w) | TVar(w, _) if (w == v): false;
			case TParenthesis(x) | TMeta(_, x): onlyAppends(x, v, stmt);
			case TBlock(es):
				for (x in es)
					if (!onlyAppends(x, v, stmt)) return false;
				true;
			case TIf(c, a, b): no(c) && onlyAppends(a, v, stmt) && (b == null || onlyAppends(b, v, stmt));
			case TWhile(c, b, _): no(c) && onlyAppends(b, v, true);
			case TSwitch(sw):
				if (!no(sw.switchSubject)) return false;
				for (c in sw.switchCases) {
					for (x in c.casePatterns)
						if (!no(x)) return false;
					if (!onlyAppends(c.caseExpr, v, stmt)) return false;
				}
				sw.switchDefault == null || onlyAppends(sw.switchDefault, v, stmt);
			case TTry(b, cs):
				if (!onlyAppends(b, v, stmt)) return false;
				for (c in cs)
					if (!onlyAppends(c.expr, v, stmt)) return false;
				true;
			case _:
				var ok = true;
				core.Texpr.iter(x -> if (ok && !no(x)) ok = false, e);
				ok;
		}
	}

	// the operands r appends to v (r: v + x + ..., a chain of string +), or null
	function appendedTo(r:TExpr, v:TVar):Null<Array<TExpr>> {
		var xs = [];
		var x = r;
		while (isConcat(x))
			switch x.eexpr {
				case TBinop(_, a, b):
					xs.push(b);
					x = a;
				case _:
			}
		return switch strip(x).eexpr {
			case TLocal(w) if (w == v && xs.length > 0 && x.eexpr.match(TLocal(_))):
				xs.reverse();
				xs;
			case _: null;
		}
	}

	// the statement appending xs to s (appends has it): each operand
	// evaluated and converted in turn, as + would, then all of them into the
	// buffer (an exception meanwhile appends none: a try in the loop may catch
	// it), or concatenated by the first append
	function appendStmt(v:TVar, xs:Array<TExpr>) {
		var a = appends.get(v.vId);
		var sxs = [];
		for (x in xs) {
			var t = tyOf(x);
			var sx = value(x);
			sx = t.match(TRef(RStr)) ? (isConst(sx) ? sx : ELocal(asLocal(sx, t))) : toStr(sx, t);
			sxs.push(sx);
		}
		var adds = [for (sx in sxs) SExpr(ECallHost(l.native("StringBuf_add"), vector(ELocal(a.buf), coerce(sx, TRef(RStr), TRef(RAny))), TVoid))];
		var start = [
			SSet(a.buf, ECallHost(l.native("StringBuf_new"), vector(), SBUF)),
			SExpr(ECallHost(l.native("StringBuf_add"), vector(ELocal(a.buf), coerce(ELocal(a.s), TRef(RStr), TRef(RAny))), TVoid))
		].concat(adds);
		var concat = [for (sx in sxs) SSet(a.s, ECallHost(l.native("hx_str_concat"), vector(ELocal(a.s), sx), TRef(RStr)))].concat([SSet(a.first, EInt(0))]);
		out.push(SIf(EBin(RefNe, ELocal(a.buf), ENull(SBUF)), Vector.fromArrayCopy(adds),
			vector(SIf(ELocal(a.first), Vector.fromArrayCopy(concat), Vector.fromArrayCopy(start)))));
	}

	// s (appends has it) as the buffer holds it, for a read or write the
	// lowering did not expect (the next append starts a new buffer)
	function flushAppend(v:TVar) {
		var a = appends.get(v.vId);
		out.push(SIf(EBin(RefNe, ELocal(a.buf), ENull(SBUF)),
			vector(SSet(a.s, ECallHost(l.native("StringBuf_toString"), vector(ELocal(a.buf)), TRef(RStr))), SSet(a.buf, ENull(SBUF))), vector()));
	}

	// ---- statements

	function stmt(e:TExpr) {
		curExpr = e;
		var at = Lower.lines ? pos(e) : -1;
		if (!Lower.survey) stmt1(e) else try stmt1(e) catch (err:LowerError) {
			l.record(err, fi.name);
			out.push(SThrow(ENull(TRef(RAny))));
		}
		// (a statement that lowered to nothing leaves no position)
		if (at >= 0 && out.length == at + 1) out.pop();
	}

	// (-debug) the position of a statement before its code: replaces a
	// position that no code followed; the index of the SPos
	function pos(e:TExpr):Int {
		var p = e.epos;
		if (p.pfile == null || p.pfile == "" || p.pfile == "?" || p.pmin < 0) return -1;
		var s = SPos(p.pfile, syntax.Lexer.findPos(p).line);
		if (out.length > 0 && out[out.length - 1].match(SPos(_))) {
			out[out.length - 1] = s;
			return out.length - 1;
		}
		out.push(s);
		return out.length - 1;
	}

	// (init: the local's first value; a struct local holds a C function's
	// struct result, which lives in this frame: MirBuild.cStructRet)
	function declare(v:TVar, ?init:TExpr):Local {
		if (structOf(v.vType) != null) throw new LowerError('the variable ' + v.vName + ' cannot hold a struct value here', CInterop.posOf(v.vPos));
		switch CInterop.ctype(v.vType) {
			case COpaque(c):
				throw new LowerError('local ' + v.vName + ' has the opaque C type ' + c.clPath.name + ' by value: it is reached through a Ptr only', CInterop.posOf(v.vPos));
			case _:
		}
		var t = ty(v.vType);
		var lo = isBoxed(v) ? newLocal(v.vName + "_box", TRef(RBox(t))) : newLocal(v.vName, t);
		locals.set(v.vId, lo);
		return lo;
	}

	function stmt1(e:TExpr) {
		switch e.eexpr {
			case TBlock(es):
				var i = 0;
				while (i < es.length) {
					if (i + 2 < es.length && structLiteralLoop(es, i)) {
						i += 3;
						continue;
					}
					stmt(es[i]);
					i++;
				}
			case TParenthesis(e1) | TMeta(_, e1):
				stmt(e1);
			case TVar(v, init):
				spanInGcCode(v.vType, e, "the local " + v.vName);
				// (an inlined Class<T> argument naming a C struct: Struct's constants take it)
				if (init != null) switch strip(init).eexpr {
					case TTypeExpr(TClassDecl(sc)) if (CInterop.isNativeClass(sc)):
						structAliases.set(v.vId, sc);
						return;
					case _:
				}
				var sc = structOf(v.vType);
				if (sc != null) {
					// a struct local: its memory in the frame, a copy of the
					// value (or the value itself, a temporary of this frame)
					if (isBoxed(v)) cfail('the struct local ' + v.vName + ' is captured by a closure and assigned: not supported (a class instead)', e);
					var s = if (init != null) structOwn(init, sc) else {
						var s = newSlot(structTy(sc), false);
						zeroStruct(ELocal(s), sc);
						s;
					};
					// (a variable of the program's own holds its copy; the compiler's
					// temporaries stay copies of the boxed value they read)
					if (!v.vKind.match(VGenerated)) unboxed.remove(s);
					locals.set(v.vId, s);
					return;
				}
				var t = ty(v.vType);
				if (isBoxed(v)) {
					var x = init != null ? coerce(value(init), tyOf(init), t) : nullOf(t);
					var b = declare(v, init);
					out.push(SSet(b, ENewBox(t, x)));
				} else {
					var x = init != null ? rhs(init) : null;
					var lo = declare(v, init);
					out.push(SSet(lo, x != null ? coerceRhs(x, tyOf(init), t) : nullOf(t)));
				}
			case TIf(c, a, b):
				var cx = cond(c);
				// (a test of the target: only the branch it takes)
				var k = Lower.targetConst(cx);
				if (k != null) {
					if (k != 0) stmt(a) else if (b != null) stmt(b);
				} else out.push(SIf(cx, block(() -> stmt(a)), b != null ? block(() -> stmt(b)) : vector()));
			case TWhile(c, body, NormalWhile):
				var ap = appendLoop(c, body);
				out.push(SLoop(block(() -> {
					var cx = cond(c);
					out.push(SIf(ENot(cx), vector(SBreak), vector()));
					stmt(body);
				})));
				appendLoopEnd(ap);
			case TWhile(c, body, DoWhile):
				var ap = appendLoop(c, body);
				// first iteration skips the test, so `continue` reaches it
				var first = newLocal("first", TBool);
				out.push(SSet(first, EInt(1)));
				out.push(SLoop(block(() -> {
					out.push(SIf(ENot(ELocal(first)), block(() -> {
						var cx = cond(c);
						out.push(SIf(ENot(cx), vector(SBreak), vector()));
					}), vector()));
					out.push(SSet(first, EInt(0)));
					stmt(body);
				})));
				appendLoopEnd(ap);
			case TBinop(OpAssignOp(OpAdd), {eexpr: TLocal(v)}, r) if (appends.exists(v.vId)):
				appendStmt(v, [r]);
			case TBinop(OpAssign, {eexpr: TLocal(v)}, r) if (appends.exists(v.vId) && appendedTo(r, v) != null):
				appendStmt(v, appendedTo(r, v));
			case TSwitch(sw):
				switchStmt(sw, null);
			case TTry(body, catches):
				tryStmt(body, catches, null);
			case TReturn(null):
				out.push(SReturn(null));
			case TReturn(r) if (sretLocal != null):
				// a struct result: into the caller's memory (built there by a constructor)
				var sc = structOf(r.etype);
				switch strip(r).eexpr {
					case TNew(c, _, cargs) if (c == sc): newStruct(c, cargs, sretLocal);
					case _:
						var x = structRhs(r).x;
						if (!x.match(ELocal(_) | EGlobal(_, _))) x = ELocal(asLocal(x, tyOf(r)));
						if (!isLocal(x, sretLocal)) copyStruct(ELocal(sretLocal), x, sc);
				}
				out.push(SReturn(ELocal(sretLocal)));
			case TReturn(r):
				var x = value(r);
				out.push(fi.ret == TVoid ? SReturn(null) : SReturn(coerce(x, tyOf(r), fi.ret)));
			case TBreak:
				out.push(SBreak);
			case TContinue:
				out.push(SContinue);
			case TThrow(x):
				// as the exceptions filter does for wildcard-catch targets: a haxe.Exception
				// is thrown as its native value (a wrapped value comes out unwrapped)
				var v = coerce(value(x), tyOf(x), TRef(RAny));
				var base = exceptionBase(x.etype);
				if (base != null) v = temp(TRef(RAny), ECall(l.staticFunc(base, base.clStatics.get("thrown")), vector(v)));
				out.push(SThrow(v));
			case TCall(_, _) | TNew(_, _, _) | TBinop(OpAssign | OpAssignOp(_), _, _) | TUnop(Increment | Decrement, _, _):
				var x = rhs(e);
				if (isImpure(x)) out.push(SExpr(x));
			case _:
				var x = rhs(e);
				if (isImpure(x)) out.push(SExpr(x));
		}
	}

	// A for loop over an array literal of struct values that the typer did not
	// unroll (its body has a continue or a break: ForLoop unrolls only bodies
	// without), as it leaves it in a block:
	//   var g = 0; var a = [e0, ..., en]; while (g < a.length) { var v = a[g]; ++g; body }
	// with the array read nowhere else: the elements in struct slots of the
	// frame, evaluated in order as the literal would be, and v a copy of the
	// g-th, picked by a switch. An array would box each element (Array<struct>
	// holds references) and allocate itself, on every run of the loop.
	function structLiteralLoop(es:Vector<TExpr>, i:Int):Bool {
		var g = switch strip(es[i]).eexpr {
			case TVar(g, {eexpr: TConst(TInt(0))}) if (!isBoxed(g)): g;
			case _: return false;
		}
		var a:TVar, el:Vector<TExpr>;
		switch strip(es[i + 1]).eexpr {
			case TVar(v, init) if (init != null && v.vKind.match(VGenerated)):
				switch strip(init).eexpr {
					case TArrayDecl(xs) if (xs.length > 0):
						a = v;
						el = xs;
					case _:
						return false;
				}
			case _:
				return false;
		}
		function isLocal(e:TExpr, v:TVar):Bool
			return switch strip(e).eexpr {
				case TLocal(w): w.vId == v.vId;
				case _: false;
			}
		var body = switch strip(es[i + 2]).eexpr {
			case TWhile(c, b, NormalWhile):
				switch strip(c).eexpr {
					case TBinop(OpLt, x, {eexpr: TField(y, FInstance(_, _, {cfName: "length"}))}) if (isLocal(x, g) && isLocal(y, a)):
					case _: return false;
				}
				switch strip(b).eexpr {
					case TBlock(bs) if (bs.length >= 2): bs;
					case _: return false;
				}
			case _:
				return false;
		}
		var v = switch strip(body[0]).eexpr {
			case TVar(v, {eexpr: TArray(x, y)}) if (isLocal(x, a) && isLocal(y, g) && !isBoxed(v)): v;
			case _: return false;
		}
		switch strip(body[1]).eexpr {
			case TUnop(Increment, Prefix, x) if (isLocal(x, g)):
			case _: return false;
		}
		var sc = structOf(v.vType);
		if (sc == null) return false;
		for (x in el)
			if (structOf(x.etype) != sc) return false;
		// (the array and the counter read only there: nothing else in the
		// loop's body nor after it in the block)
		var found = false;
		function reads(e:TExpr) {
			if (found) return;
			switch e.eexpr {
				case TLocal(w) if (w.vId == a.vId || w.vId == g.vId):
					found = true;
				case _:
					core.Texpr.iter(reads, e);
			}
		}
		for (k in 2...body.length)
			reads(body[k]);
		for (k in i + 3...es.length)
			reads(es[k]);
		if (found) return false;
		var slots = [for (x in el) structOwn(x, sc)];
		stmt(es[i]);
		var gl = locals.get(g.vId);
		out.push(SLoop(block(() -> {
			out.push(SIf(EBin(Ge, ELocal(gl), EInt(slots.length)), vector(SBreak), vector()));
			var s = newSlot(structTy(sc), false);
			var cases = new Vector<IrCase>(slots.length - 1);
			for (k in 0...slots.length - 1)
				cases[k] = {values: vector(k), body: block(() -> copyStruct(ELocal(s), ELocal(slots[k]), sc))};
			out.push(SSwitch(ELocal(gl), cases, block(() -> copyStruct(ELocal(s), ELocal(slots[slots.length - 1]), sc))));
			locals.set(v.vId, s);
			for (k in 1...body.length)
				stmt(body[k]);
		})));
		return true;
	}

	// value of an SSet: calls stay at the top, converted afterwards if needed
	// a conversion to a closure type that may need an adapter: from another
	// closure type, or from Dynamic (coerce)
	static function closureConversion(from:Ty, to:Ty):Bool
		return to.match(TRef(RClos(_))) && (from.match(TRef(RClos(_))) || from.match(TRef(RAny)));

	// a NativeArray taken by a typed view that may not have its kind (coerce)
	static function nativeConversion(from:Ty, to:Ty):Bool
		return switch [from, to] {
			case [TRef(RNativeArr(a)), TRef(RNativeArr(b))]: !dynElem(b) && (dynElem(a) || nativeKind(a) != nativeKind(b));
			case [TRef(_), TRef(RNativeArr(b))]: !dynElem(b); // (Dynamic; another reference, cast)
			case _: false;
		}

	// a conversion between two references that is not a cast (coerce)
	static function refConversion(from:Ty, to:Ty):Bool
		return closureConversion(from, to) || nativeConversion(from, to);

	function coerceRhs(x:Ex, from:Ty, to:Ty):Ex {
		if (Ir.repr(from) == Ir.repr(to) && !refConversion(from, to)) return x;
		if (isImpure(x)) x = temp(from, x);
		return coerce(x, from, to);
	}

	function cond(c:TExpr):Ex
		return coerce(value(c), tyOf(c), TBool);

	// assigns the value of a branch to `target` (null: statement)
	function branch(e:TExpr, target:Null<Local>):Vector<Stmt> {
		return block(() -> {
			if (target == null) stmt(e) else {
				var x = rhs(e);
				if (!isNoValue(e)) out.push(SSet(target, coerceRhs(x, tyOf(e), target.ty)));
			}
		});
	}

	static function isNoValue(e:TExpr):Bool
		return switch strip(e).eexpr {
			case TThrow(_) | TReturn(_) | TBreak | TContinue: true;
			case _: false;
		}

	function switchStmt(sw:TSwitch, target:Null<Local>) {
		var st = tyOf(sw.switchSubject);
		var subj = value(sw.switchSubject);
		var allInt = st == TI32 || st == TBool;
		if (allInt)
			for (c in sw.switchCases)
				for (p in c.casePatterns)
					if (!strip(p).eexpr.match(TConst(TInt(_) | TBool(_)))) allInt = false;
		var def = sw.switchDefault != null ? branch(sw.switchDefault, target) : vector();
		if (allInt) {
			var cases = new Vector<IrCase>(sw.switchCases.length);
			for (k in 0...sw.switchCases.length) {
				var c = sw.switchCases[k];
				cases[k] = {
					values: c.casePatterns.map(p -> switch strip(p).eexpr {
						case TConst(TInt(i)): i;
						case TConst(TBool(b)): b ? 1 : 0;
						case _: 0;
					}),
					body: branch(c.caseExpr, target)
				};
			}
			out.push(SSwitch(subj, cases, def));
		} else if (stringSwitch(sw, st, subj, def, target)) {
			// (by hash)
		} else {
			var s = asLocal(subj, st);
			var chain = def;
			var i = sw.switchCases.length;
			while (i-- > 0) {
				var c = sw.switchCases[i];
				var body = branch(c.caseExpr, target);
				var r = newLocal("m", TBool);
				var pre = block(() -> {
					out.push(SSet(r, EInt(0)));
					for (p in c.casePatterns) {
						var px = value(p);
						var eq = equality(ELocal(s), st, px, tyOf(p), true);
						out.push(SIf(eq, vector(SSet(r, EInt(1))), vector()));
					}
				});
				chain = pre.snoc(SIf(ELocal(r), body, chain));
			}
			for (x in chain)
				out.push(x);
		}
	}

	// FNV-1a over the UTF-16 units, never 0, as Str.hash computes (and
	// caches) it at run time
	public static function strHash(s:String):Int {
		var x = 0x811C9DC5;
		for (i in 0...s.length)
			x = (x ^ StringTools.fastCodeAt(s, i)) * 16777619;
		return x == 0 ? 1 : x;
	}

	// A switch on a String with many constant patterns: a switch on the
	// subject's hash (cached in the string) picks the candidates, which are
	// compared in the order of the cases, and gives the case's index; a switch
	// on that index runs the bodies. The chain of comparisons the general
	// lowering makes costs a comparison per pattern (a keyword table: a hundred).
	function stringSwitch(sw:TSwitch, st:Ty, subj:Ex, def:Vector<Stmt>, target:Null<Local>):Bool {
		if (!st.match(TRef(RStr))) return false;
		var n = 0;
		for (c in sw.switchCases)
			for (p in c.casePatterns)
				switch strip(p).eexpr {
					case TConst(TString(_)) if (tyOf(p).match(TRef(RStr))): n++;
					case _: return false;
				}
		if (n < 6) return false;
		var s = asLocal(subj, st);
		var k = newLocal("k", TI32);
		var hashes:Array<Int> = [];
		var groups = new Map<Int, Array<{p:TExpr, index:Int}>>();
		for (ci in 0...sw.switchCases.length)
			for (p in sw.switchCases[ci].casePatterns) {
				var h = switch strip(p).eexpr {
					case TConst(TString(v)): strHash(v);
					case _: throw "unreachable";
				}
				var g = groups.get(h);
				if (g == null) {
					groups.set(h, g = []);
					hashes.push(h);
				}
				g.push({p: p, index: ci});
			}
		var pick = new Vector<IrCase>(hashes.length);
		for (hi in 0...hashes.length) {
			var h = hashes[hi];
			var g = groups.get(h);
			var chain:Vector<Stmt> = vector();
			var i = g.length;
			while (i-- > 0) {
				var x = g[i];
				chain = vector(SIf(equality(ELocal(s), st, value(x.p), tyOf(x.p), true), vector(SSet(k, EInt(x.index))), chain));
			}
			pick[hi] = {values: vector(h), body: chain};
		}
		out.push(SSet(k, EInt(-1)));
		out.push(SIf(EBin(RefNe, ELocal(s), ENull(st)), vector(SSwitch(ECallHost("hx_str_hash", vector(ELocal(s)), TI32), pick, vector())), vector()));
		var cases = new Vector<IrCase>(sw.switchCases.length);
		for (ci in 0...sw.switchCases.length)
			cases[ci] = {values: vector(ci), body: branch(sw.switchCases[ci].caseExpr, target)};
		out.push(SSwitch(ELocal(k), cases, def));
		return true;
	}

	function tryStmt(body:TExpr, catches:Vector<{variable:TVar, expr:TExpr}>, target:Null<Local>) {
		fi.hasTry = true;
		tryDepth++;
		var b = branch(body, target);
		tryDepth--;
		var cs = new Vector<IrCatch>(catches.length);
		for (ci in 0...catches.length) {
			var c = catches[ci];
			var t = ty(c.variable.vType);
			var exn = newLocal("exn", TRef(RAny));
			var test = typeTest(c.variable.vType);
			var lo = declare(c.variable);
			// catching haxe.Exception (or a subclass) catches any value, wrapped by haxe.Exception.caught
			var base = exceptionBase(c.variable.vType);
			var caught = null;
			if (base != null) {
				var fn = l.staticFunc(base, base.clStatics.get("caught"));
				caught = newLocal("caught", fn.ret);
				var cls = switch TFunctions.follow(c.variable.vType) {
					case TInst(k, _): k;
					case _: null;
				};
				test = if (cls == base) null else {
					var ci = l.classInfo(cls);
					x -> EInstOf(ci, ECall(fn, vector(x))); // pure enough: caught allocates only for non-Exception values
				};
			}
			var handler = block(() -> {
				var src:Ex = ELocal(exn);
				if (caught != null) {
					out.push(SSet(caught, ECall(l.staticFunc(base, base.clStatics.get("caught")), vector(ELocal(exn)))));
					src = ELocal(caught);
				}
				var x = coerce(src, caught != null ? caught.ty : TRef(RAny), t);
				if (isBoxed(c.variable)) out.push(SSet(lo, ENewBox(t, x))) else out.push(SSet(lo, x));
			}).concat(branch(c.expr, target));
			cs[ci] = {test: test, l: exn, body: handler};
		}
		out.push(STry(b, cs));
	}

	// haxe.Exception when t is it or one of its subclasses
	function exceptionBase(t:T):Null<TClass> {
		var c = switch TFunctions.follow(t) {
			case TInst(c, _): c;
			case _: return null;
		};
		while (c != null) {
			if (c.clPath.name == "Exception" && c.clPath.pack.join(".") == "haxe") return c;
			c = c.clSuper != null ? c.clSuper.cls : null;
		}
		return null;
	}

	// a runtime test that a Dynamic value has the given type (null: always true)
	function typeTest(t:T):Null<Ex->Ex> {
		return switch TFunctions.follow(t) {
			case TDynamic(_) | TMono(_): null;
			case TAbstract(a, _) if (a.aPath.name == "Any"): null;
			case TInst(c, _) if (!c.hasClassFlag(CExtern) && !c.hasClassFlag(CInterface) && !c.clKind.match(KTypeParameter(_))):
				var ci = classOrBox(c);
				x -> EInstOf(ci, x);
			case _:
				var tr = typeRefOfType(t);
				tr == null ? null : x -> ECallHost(l.native("hx_is"), vector(x, EType(tr)), TBool);
		}
	}

	function typeRefOfType(t:T):Null<TypeRef> {
		return switch TFunctions.follow(t) {
			case TInst(c, _):
				if (c.hasClassFlag(CExtern) || c.clKind.match(KTypeParameter(_))) TRBuiltin(Lower.nativeName(c)) else TRClass(classOrBox(c));
			case TEnum(e, _): TREnum(l.enumInfo(e));
			case TAbstract(a, _): TRBuiltin(Lower.ident(a.aPath.pack, a.aPath.name));
			case _: null;
		}
	}

	// a class, or for a @:hxmc.struct class its box's (Std.isOfType, casts,
	// the class as a value)
	function classOrBox(c:TClass):ClassInfo
		return switch ty(TInst(c, vector())) {
			case TStruct(n, _): l.structBox(n);
			case _: l.classInfo(c);
		}

	function typeRef(mt:ModuleType):TypeRef {
		return switch mt {
			case TClassDecl(c):
				if (c.hasClassFlag(CExtern)) TRBuiltin(Lower.nativeName(c)) else TRClass(classOrBox(c));
			case TEnumDecl(e): TREnum(l.enumInfo(e));
			case TAbstractDecl(a): TRBuiltin(Lower.ident(a.aPath.pack, a.aPath.name));
			case TTypeDecl(d): typeRefOfType(d.tType);
		}
	}

	// ---- values

	// a pure expression with the representation of ty(e.etype); side effects go to `out`
	function value(e:TExpr):Ex {
		var x = rhs(e);
		if (!isImpure(x)) return x;
		var t = tyOf(e);
		if (t == TVoid) {
			out.push(SExpr(x));
			return EInt(0);
		}
		return temp(t, x);
	}

	function isBoxed(v:TVar):Bool
		return boxed.exists(v.vId);

	// an expression that may be a call or allocation at the top, with the
	// representation of ty(e.etype)
	function rhs(e:TExpr):Ex {
		curExpr = e;
		return switch e.eexpr {
			case TConst(TInt(i)):
				switch tyOf(e) {
					case TF64: EF64(i);
					case TRef(_): coerce(EInt(i), TI32, tyOf(e));
					case _: EInt(i);
				}
			case TConst(TFloat(f)):
				var v = Std.parseFloat(StringTools.replace(f, "_", ""));
				tyOf(e) == TF64 ? EF64(v) : coerce(EF64(v), TF64, tyOf(e));
			case TConst(TBool(b)): coerce(EInt(b ? 1 : 0), TBool, tyOf(e));
			case TConst(TString(s)): EStr(s);
			case TConst(TNull): nullOf(tyOf(e));
			case TConst(TThis):
				if (thisLocal == null) fail("this outside a method", e);
				ELocal(thisLocal);
			case TConst(TSuper):
				if (thisLocal == null) fail("super outside a method", e);
				ELocal(thisLocal);
			case TLocal(v):
				if (appends.exists(v.vId)) flushAppend(v);
				var lo = local(v, e);
				var x:Ex = isBoxed(v) ? EBoxGet(ty(v.vType), ELocal(lo)) : ELocal(lo);
				coerce(x, ty(v.vType), tyOf(e));
			case TParenthesis(e1) | TMeta(_, e1): coerceRhs(rhs(e1), tyOf(e1), tyOf(e));
			case TCast(e1, null): coerceRhs(rhs(e1), tyOf(e1), tyOf(e));
			case TCast(e1, mt):
				// checked cast: throws when the value doesn't have the type
				var x = coerce(value(e1), tyOf(e1), TRef(RAny));
				var ci = castClass(mt);
				if (ci != null) {
					// of a class: the instance test, hx_cast (which throws) only when it fails
					var lo = asLocal(x, TRef(RAny));
					var r = newLocal("cast", TRef(RAny));
					out.push(SSet(r, ELocal(lo)));
					out.push(SIf(ENot(EInstOf(ci, ELocal(lo))), vector(SSet(r, ECallHost(l.native("hx_cast"), vector(ELocal(lo), EType(TRClass(ci))), TRef(RAny)))), vector()));
					return coerce(ELocal(r), TRef(RAny), tyOf(e));
				}
				var c = temp(TRef(RAny), ECallHost(l.native("hx_cast"), vector(x, EType(typeRef(mt))), TRef(RAny)));
				coerce(c, TRef(RAny), tyOf(e));
			case TTypeExpr(mt):
				switch mt {
					case TClassDecl(c): l.reflectStatics(c);
					case TEnumDecl(en): l.reflectEnum(en);
					case _:
				}
				EType(typeRef(mt));
			case TField(obj, fa): field(obj, fa, e);
			case TEnumIndex(e1):
				var en = switch TFunctions.follow(e1.etype) {
					case TEnum(en, _): l.enumInfo(en);
					case _: null;
				};
				EEnumTag(value(e1), en);
			case TEnumParameter(e1, ef, i):
				var en = switch TFunctions.follow(e1.etype) {
					case TEnum(en, _): en;
					case _: fail("enum parameter of non-enum", e);
				};
				var c = l.ctorInfo(ef, en);
				coerce(EEnumParam(c, i, value(e1)), c.params[i], tyOf(e));
			case TArray(a, i):
				switch tyOf(a) {
					case TRef(RNativeArr(elem)):
						var xs = operands(vector(a, i));
						var al = ELocal(asLocal(xs[0], tyOf(a)));
						elemRead(nativeRead(elem, al, ELocal(asLocal(coerce(xs[1], tyOf(i), TI32), TI32)), e.epos), elem, tyOf(e));
					case TRef(RArr(elem)):
						var xs = operands(vector(a, i));
						var ix = coerce(xs[1], tyOf(i), TI32);
						elemRead(isVectorData(a.etype) ? EArrGetU(elem, xs[0], ix) : EArrGet(elem, xs[0], ix), elem, tyOf(e));
					case _:
						var xs = operands(vector(a, i));
						var r = temp(TRef(RAny), ECallHost(l.native("hx_dyn_aget"), vector(coerce(xs[0], tyOf(a), TRef(RAny)), coerce(xs[1], tyOf(i), TI32)), TRef(RAny)));
						coerce(r, TRef(RAny), tyOf(e));
				}
			case TBinop(op = OpBoolAnd | OpBoolOr | OpEq | OpNotEq | OpLt | OpLte | OpGt | OpGte, a, b) if (tyOf(e) != TBool):
				// a Bool typed as something else (the optimizer's `c && x` for
				// `c ? x : false`, typed as the conditional was: Dynamic, a box)
				coerce(binop(op, a, b, e), TBool, tyOf(e));
			case TBinop(op, a, b): binop(op, a, b, e);
			case TUnop(op, flag, e1): unop(op, flag, e1, e);
			case TCall(f, cargs) if (site != null):
				var x = call(f, cargs, e);
				if (x.match(ECall(_) | ECallDispatch(_) | ECallClos(_) | ECallAnon(_) | ECallHost(_))) noteCall(e);
				x;
			case TCall(f, cargs): call(f, cargs, e);
			case TNew(c, params, cargs) if (Lower.isNativeArray(c)):
				var n = coerce(value(cargs[0]), tyOf(cargs[0]), TI32);
				// (of an erased type parameter: a wrapper, which the first typed
				// view converts to its kind, rt/NArray)
				var erased = switch TFunctions.follow(params[0]) {
					case TInst(pc, _): pc.clKind.match(KTypeParameter(_));
					case _: false;
				};
				if (erased) temp(tyOf(e), ECallHost(l.native("hx_narray_open"), vector(n), tyOf(e)));
				else ECallHost("hxmc_narray_new", vector(EInt(nativeKind(switch tyOf(e) {
					case TRef(RNativeArr(t)): t;
					case _: fail("NativeArray type", e);
				})), n), tyOf(e));
			case TNew(c, _, cargs) if (Lower.isCore(c, "Array")):
				var elem = switch tyOf(e) {
					case TRef(RArr(t)): t;
					case _: TRef(RAny);
				};
				ENewArr(elem, vector());
			case TNew(c, _, cargs) if (CInterop.isStruct(c)):
				coerce(ELocal(newStruct(c, cargs, null)), structTy(c), tyOf(e));
			case TNew(c, _, _) if (ObjC.isObjC(c)):
				fail("Objective-C class " + c.clPath.name + ": made by " + c.clPath.name + ".alloc().init...(...), not new", e);
			case TNew(c, _, cargs) if (c.hasClassFlag(CExtern)):
				var s = ctorSig(c);
				var x = temp(TRef(RNative(Lower.nativeName(c))), ECallHost(l.native(Lower.nativeName(c) + "_new"), args(cargs, s, null), TRef(RNative(Lower.nativeName(c)))));
				coerce(x, TRef(RNative(Lower.nativeName(c))), tyOf(e));
			case TNew(c, _, cargs):
				var ci = l.classInfo(c);
				var k = c;
				while (k.clConstructor == null && k.clSuper != null)
					k = k.clSuper.cls;
				var obj = temp(TRef(RObj(ci)), ENewObj(ci));
				if (k.clConstructor != null) {
					var ctor = l.ctor(k);
					var xs = args(cargs, tys(ctor), defaultValues(ctor), 1, ctor, () -> obj);
					out.push(SExpr(ECall(ctor, VectorTools.cons(obj, xs))));
				}
				coerce(obj, TRef(RObj(ci)), tyOf(e));
			case TArrayDecl(vs):
				var elem = switch tyOf(e) {
					case TRef(RArr(t)): t;
					case _: TRef(RAny);
				};
				var xs = operands(vs);
				ENewArr(elem, xs.mapi((i, x) -> coerce(x, tyOf(vs[i]), elem)));
			case TObjectDecl(fs):
				var xs = operands(fs.map(f -> f.expr));
				var fields = [for (i in 0...fs.length) {name: fs[i].key.name, ty: l.boxed(tyOf(fs[i].expr))}];
				var sh = l.shape(fields);
				var vals = [];
				// (a shape is its fields' names and representations, its types
				// those of the first object of that shape: a reference is stored
				// as it is, a closure with its own signature, not converted to
				// another object's (anonGet adapts it where it is read))
				for (sf in sh.fields)
					for (i in 0...fs.length)
						if (fs[i].key.name == sf.name) {
							var from = tyOf(fs[i].expr);
							vals.push(Ir.isRef(from) && Ir.isRef(sf.ty) ? xs[i] : coerce(xs[i], from, sf.ty));
						}
				ENewAnon(sh, Vector.fromArrayCopy(vals));
			case TFunction(tf): closure(tf, e);
			case TBlock(es):
				if (es.length == 0) EInt(0) else {
					for (i in 0...es.length - 1)
						stmt(es[i]);
					var last = es[es.length - 1];
					coerceRhs(rhs(last), tyOf(last), tyOf(e));
				}
			case TIf(c, a, b) if (b != null && tyOf(e) != TVoid):
				var t = tyOf(e);
				var cx = cond(c);
				var lo = newLocal("r", t);
				var k = Lower.targetConst(cx);
				if (k != null) {
					for (s in branch(k != 0 ? a : b, lo))
						out.push(s);
				} else out.push(SIf(cx, branch(a, lo), branch(b, lo)));
				ELocal(lo);
			case TSwitch(sw):
				var t = tyOf(e);
				if (t == TVoid) {
					switchStmt(sw, null);
					EInt(0);
				} else {
					var lo = newLocal("r", t);
					switchStmt(sw, lo);
					ELocal(lo);
				}
			case TTry(body, catches):
				var t = tyOf(e);
				var lo = t == TVoid ? null : newLocal("r", t);
				tryStmt(body, catches, lo);
				lo == null ? EInt(0) : ELocal(lo);
			case TThrow(_) | TReturn(_) | TBreak | TContinue | TIf(_, _, _) | TWhile(_, _, _) | TVar(_, _):
				stmt(e);
				nullOf(tyOf(e));
			// (reification's position in macro code compiled for hxmc, -D hxmc.macros=mir:
			// the expression's own, as Eval has it; the compiler that loads the code makes it)
			case TIdent("$__mk_pos__"):
				temp(TRef(RAny), ECallHost(l.native("hxmc_mir_macro_pos"), vector(EStr(e.epos.pfile), EInt(e.epos.pmin), EInt(e.epos.pmax)), TRef(RAny)));
			case TIdent(n): fail("identifier " + n, e);
			case _: fail("expression " + e.eexpr.getName(), e);
		}
	}

	function ctorSig(c:TClass):Vector<Ty> {
		if (c.clConstructor == null) return vector();
		return switch TFunctions.follow(c.clConstructor.cfType) {
			case TFun(s): s.args.map(a -> ty(a.type));
			case _: vector();
		}
	}

	// ---- field access

	function field(obj:TExpr, fa:TFieldAccess, e:TExpr):Ex {
		return switch fa {
			case FInstance(c, _, cf):
				switch cf.cfKind {
					case Method(MethDynamic) if (isDynMethod(c, cf)): coerce(dynMethod(obj, c, cf, e), dynSlotTy(c, cf), tyOf(e));
					// (an interface's dynamic method: the field, by name)
					case Method(MethDynamic) if (c.hasClassFlag(CInterface)): anonGet(cf.cfName, obj, e);
					case Method(_): methodClosure(obj, c, cf, e);
					case Var(_) if (Lower.isCore(c, "Array") && cf.cfName == "length"):
						EArrLen(value(obj));
					case Var(_) if (Lower.isNativeArray(c) && cf.cfName == "length"):
						ECallHost("hxmc_narray_length", vector(value(obj)), TI32);
					case Var(_) if (Lower.isCore(c, "String") && cf.cfName == "length"):
						ECallHost("String_length", vector(value(obj)), TI32);
					case Var(_) if (ObjC.isObjC(c)): objcGet(obj, c, cf, e);
					case Var(_) if (CInterop.isStruct(c)): structGet(obj, c, cf, e);
					case Var(_) if (c.hasClassFlag(CExtern)):
						var t = ty(cf.cfType);
						var x = temp(t, ECallHost(l.native(Lower.nativeName(c) + "_get_" + cf.cfName), vector(receiverCheck(value(obj), tyOf(obj))), t));
						coerce(x, t, tyOf(e));
					case Var(_) if (c.hasClassFlag(CInterface)):
						anonGet(cf.cfName, obj, e);
					case Var(_) if (structOf(cf.cfType) != null):
						// a struct field (in the object's memory): copied out
						var sc = structOf(cf.cfType);
						var ci = l.classInfo(c);
						var o = asLocal(value(obj), tyOf(obj));
						var s = newSlot(structTy(sc), true);
						copyStruct(ELocal(s), EFieldAddr(ci, ci.fieldIndex(cf.cfName), ELocal(o)), sc);
						coerce(ELocal(s), structTy(sc), tyOf(e));
					case Var(_):
						var ci = l.classInfo(c);
						var idx = ci.fieldIndex(cf.cfName);
						coerce(EField(ci, idx, value(obj)), ci.fields[idx].ty, tyOf(e));
				}
			case FStatic(c, cf) if (cf.cfKind.match(Var(_)) && ObjC.isObjC(c)): objcGet(null, c, cf, e);
			case FStatic(c, cf):
				var cf = overloadImpl(c, cf);
				switch cf.cfKind {
					case Var(_) if (c.hasClassFlag(CExtern)):
						var t = ty(cf.cfType);
						coerce(temp(t, ECallHost(l.native(Lower.nativeName(c) + "_" + cf.cfName), vector(), t)), t, tyOf(e));
					case Var(_):
						var g = l.staticVar(c, cf);
						var t = l.globalTy(g);
						coerce(EGlobal(g, t), t, tyOf(e));
					case Method(_) if (c.hasClassFlag(CExtern) || cf.cfExpr == null):
						var s = switch TFunctions.follow(cf.cfType) {
							case TFun(s): s;
							case _: fail("extern static " + cf.cfName + " is not a function", e);
						};
						var sig = l.sig([for (a in s.args) ty(a.type)], ty(s.ret));
						var li = l.hostClosure(l.native(Lower.nativeName(c) + "_" + cf.cfName), sig);
						coerce(temp(TRef(RClos(sig)), ENewClos(li, vector())), TRef(RClos(sig)), tyOf(e));
					case Method(MethDynamic):
						var g = staticDynMethod(c, cf);
						var t = l.globalTy(g);
						coerce(EGlobal(g, t), t, tyOf(e));
					case Method(_):
						var f = l.staticFunc(c, cf);
						var li = l.staticClosure(f);
						var x = temp(TRef(RClos(li.sig)), ENewClos(li, vector()));
						coerce(x, TRef(RClos(li.sig)), tyOf(e));
				}
			case FAnon(cf):
				anonGet(cf.cfName, obj, e);
			case FDynamic(name):
				var o = coerce(value(obj), tyOf(obj), TRef(RAny));
				var r = temp(TRef(RAny), ECallHost(l.native("hx_dyn_get"), vector(o, EStr(name)), TRef(RAny)));
				coerce(r, TRef(RAny), tyOf(e));
			case FClosure(cl, cf):
				if (cl == null) {
					// a closure of a structural field: just the field's value
					anonGet(cf.cfName, obj, e);
				} else if (cf.cfKind.match(Method(MethDynamic)) && isDynMethod(cl.cls, cf)) {
					coerce(dynMethod(obj, cl.cls, cf, e), dynSlotTy(cl.cls, cf), tyOf(e));
				} else if (cf.cfKind.match(Method(MethDynamic)) && cl.cls.hasClassFlag(CInterface)) {
					anonGet(cf.cfName, obj, e);
				} else methodClosure(obj, cl.cls, cf, e);
			case FEnum(en, ef):
				var ci = l.ctorInfo(ef, en);
				if (ci.global >= 0) coerce(EGlobal(ci.global, TRef(RCtor(ci))), TRef(RCtor(ci)), tyOf(e)) else {
					// a constructor with arguments used as a function
					var sig = l.sig(ci.params.toArray(), TRef(REnum(ci.en)));
					var li = l.ctorClosure(ci, sig);
					coerce(temp(TRef(RClos(sig)), ENewClos(li, vector())), TRef(RClos(sig)), tyOf(e));
				}
		}
	}

	// dynamic methods (`dynamic function`): the current function lives in a field
	// slot (Lower.classInfo) or, for statics, a global. The slot starts null and
	// gets the bound method on first use, so every allocation path (constructors,
	// Type.createEmptyInstance) is covered. Deviation: assigning null and calling
	// restores the original method instead of failing.
	function isDynMethod(c:TClass, cf:TClassField):Bool
		return !c.hasClassFlag(CExtern) && !c.hasClassFlag(CInterface) && !Lower.isCore(c, "String") && !Lower.isCore(c, "Array");

	function dynSlotTy(c:TClass, cf:TClassField):Ty {
		var ci = l.classInfo(c);
		return ci.fields[ci.fieldIndex(cf.cfName)].ty;
	}

	function dynMethod(obj:TExpr, c:TClass, cf:TClassField, e:TExpr):Ex {
		var ci = l.classInfo(c);
		var idx = ci.fieldIndex(cf.cfName);
		var st = ci.fields[idx].ty;
		var o = asLocal(value(obj), tyOf(obj));
		var s = newLocal("dm", st);
		out.push(SSet(s, EField(ci, idx, ELocal(o))));
		out.push(SIf(EBin(RefEq, ELocal(s), ENull(st)), block(() -> {
			out.push(SSet(s, methodClosureOf(ELocal(o), c, cf, st, e)));
			out.push(SSetField(ci, idx, ELocal(o), ELocal(s)));
		}), vector()));
		return ELocal(s);
	}

	function staticDynMethod(c:TClass, cf:TClassField):Int {
		var g = l.staticVar(c, cf);
		var t = l.globalTy(g);
		out.push(SIf(EBin(RefEq, EGlobal(g, t), ENull(t)), block(() -> {
			var f = l.staticFunc(c, cf);
			var li = l.staticClosure(f);
			out.push(SSetGlobal(g, coerce(temp(TRef(RClos(li.sig)), ENewClos(li, vector())), TRef(RClos(li.sig)), t)));
		}), vector()));
		return g;
	}

	// obj.method as a value
	function methodClosure(obj:TExpr, c:TClass, cf:TClassField, e:TExpr):Ex {
		if (c.hasClassFlag(CExtern) || Lower.isCore(c, "String") || Lower.isCore(c, "Array"))
			return methodClosureOf(null, c, cf, tyOf(e), e, obj);
		return methodClosureOf(value(obj), c, cf, tyOf(e), e);
	}

	function methodClosureOf(o:Null<Ex>, c:TClass, cf:TClassField, rt:Ty, e:TExpr, ?obj:TExpr):Ex {
		if (c.hasClassFlag(CExtern) || Lower.isCore(c, "String") || Lower.isCore(c, "Array")) {
			var s = switch TFunctions.follow(cf.cfType) {
				case TFun(s): s;
				case _: fail("extern method " + cf.cfName + " is not a function", e);
			};
			var sig = l.sig([for (a in s.args) ty(a.type)], ty(s.ret));
			var li = l.hostClosure(l.native(Lower.nativeName(c) + "_" + cf.cfName), sig, tyOf(obj));
			var x = temp(TRef(RClos(sig)), ENewClos(li, vector(value(obj))));
			return coerce(x, TRef(RClos(sig)), rt);
		}
		var li:LambdaInfo;
		if (l.needsDispatch(c, cf.cfName)) {
			var d = dispatchType(c, cf);
			var impl = l.lookupMethod(c, cf.cfName);
			var f = impl != null ? l.method(impl.cls, impl.field) : null;
			li = l.boundClosure(f, {sel: l.selector(cf.cfName, d.sig), sig: d.sig, args: d.args, cls: c}, fi);
		} else {
			var impl = l.lookupMethod(c, cf.cfName);
			if (impl == null) fail("no implementation of " + cf.cfName, e);
			li = l.boundClosure(l.method(impl.cls, impl.field), null, fi);
		}
		var x = temp(TRef(RClos(li.sig)), ENewClos(li, vector(o)));
		return coerce(x, TRef(RClos(li.sig)), rt);
	}

	// A dispatched call's missing arguments get the defaults of the method the
	// receiver's class runs (an override may declare other values than the
	// method the static type finds, `ds`). `xs` are the arguments after the
	// receiver (`to` with it).
	function overrideDefaults(c:TClass, name:String, o:Ex, xs:Vector<Ex>, given:Int, to:Vector<Ty>, ds:Null<Array<Null<TExpr>>>) {
		for (i in given + 1...to.length) {
			var all:Array<Null<Ex>> = [o];
			for (x in xs)
				all.push(x);
			var x = receiverDefault(c, name, o, i, ds != null && i < ds.length ? ds[i] : null, to[i], xs[i - 1], all, to.toArray());
			for (k in 1...all.length)
				xs[k - 1] = all[k];
			if (x != null) xs[i - 1] = x;
		}
	}

	// The default value of argument i (the receiver is 0) of the method `name`
	// for the receiver o of static class c, when the implementations under c
	// disagree with `base` (that of the method c finds), else null: a number or
	// a Bool is `x` (base's value) changed by a test of the receiver's class for
	// each implementation, each after its superclass's; a reference is null.
	function receiverDefault(c:TClass, name:String, o:Ex, i:Int, base:Null<TExpr>, t:Ty, x:Ex, given:Array<Null<Ex>>, givenTys:Array<Null<Ty>>):Null<Ex> {
		var impls = l.implementors(c, name);
		// (the implementations' own: LowerQueries.fieldDefaults)
		var dfs = [for (k in impls) l.fieldDefaults(k.cls, k.field)];
		inline function defaultOf(j:Int):Null<TExpr> {
			var d = dfs[j];
			return d != null && i < d.values.length ? d.values[i] : null;
		}
		inline function varsOf(j:Int):Null<Array<Null<TVar>>> {
			var d = dfs[j];
			return d == null ? null : d.vars;
		}
		var differs = false;
		for (j in 0...impls.length)
			if (!sameDefault(defaultOf(j), base)) differs = true;
		if (!differs) return null;
		// (a reference: null, which the callee replaces with its own default)
		if (t != TI32 && t != TF64 && t != TBool) return nullOf(t);
		var r = newLocal("d", t);
		// (the arguments as locals, for defaults reading them: defaultValue)
		var reads = false;
		for (j in 0...impls.length) {
			var d = defaultOf(j), vars = varsOf(j);
			if (d != null && vars != null && !constDefault(d) && readsFunction(d, vars)) reads = true;
		}
		if (reads)
			for (k in 1...i)
				if (k < given.length && !isConst(given[k]) && !given[k].match(ELocal(_))) given[k] = ELocal(asLocal(given[k], givenTys[k]));
		out.push(SSet(r, x));
		for (j in 0...impls.length) {
			var k = impls[j];
			var d = defaultOf(j);
			var vars = varsOf(j);
			var test = ECallHost(l.native("hx_is"), vector(coerce(o, TRef(RObj(l.rootClass())), TRef(RAny)), EType(TRClass(l.classInfo(k.cls)))), TBool);
			out.push(SIf(test, block(() -> out.push(SSet(r, d != null ? defaultValue(d, t, i, vars, given, givenTys, () -> o, l.classInfo(k.cls)) : nullOf(t)))), vector()));
		}
		return ELocal(r);
	}

	static function sameDefault(a:Null<TExpr>, b:Null<TExpr>):Bool {
		if (a == null || b == null) return a == b;
		a = strip(a);
		b = strip(b);
		return switch [a.eexpr, b.eexpr] {
			case [TConst(x), TConst(y)]: Type.enumEq(x, y);
			case [TUnop(o1, f1, x), TUnop(o2, f2, y)]: o1 == o2 && f1 == f2 && sameDefault(x, y);
			case _: a == b;
		}
	}

	// the selector signature of a method (its root declaration's), and the
	// types of its arguments and result there: the signature keeps references
	// as Dynamic, but an implementation takes a closure argument as a closure
	// of the declared type (Lower.method), so a call converts to these
	function dispatchType(c:TClass, cf:TClassField):{sig:SigInfo, args:Array<Ty>, ret:Ty} {
		var decl = l.rootDecl(c, cf.cfName);
		var impl = l.lookupMethod(c, cf.cfName);
		var args:Array<Ty>, ret:Ty;
		if (impl != null) {
			var f = l.method(impl.cls, impl.field);
			args = [for (a in f.args) a.ty];
			ret = f.ret;
		} else switch Lower.followFun((decl != null ? decl : cf).cfType) {
			case TFun(s):
				ret = ty(s.ret);
				args = [TRef(RObj(l.rootClass()))].concat([for (a in s.args) ty(a.type)]).concat(ret.match(TStruct(_)) ? [TI64] : []);
			case _: return fail("method type");
		}
		return {sig: l.sig(args, ret), args: args, ret: ret};
	}

	// ---- operators

	function binop(op:Binop, a:TExpr, b:TExpr, e:TExpr):Ex {
		switch op {
			case OpAssign if (structOf(a.etype) != null):
				return structAssign(a, b, structOf(a.etype), e);
			case OpAssign:
				return assign(a, () -> {x: rhs(b), t: tyOf(b)}, e);
			case OpEq | OpNotEq if (structOf(a.etype) != null && structOf(b.etype) != null):
				var eq = structEq(a, b, structOf(a.etype), e);
				return op == OpEq ? eq : ENot(eq);
			case OpAssignOp(op2):
				// (the result in the representation of what a holds, curTy, as
				// assign stores it: a Dynamic array's element typed Float, a
				// generic field read as Int are references there)
				return assign(a, null, e, (cur, curTy) -> arith(op2, cur, curTy, () -> {x: value(b), t: tyOf(b)}, curTy, e));
			case OpBoolAnd | OpBoolOr:
				var lo = newLocal("c", TBool);
				out.push(SSet(lo, cond(a)));
				var rest = block(() -> out.push(SSet(lo, cond(b))));
				out.push(op == OpBoolAnd ? SIf(ELocal(lo), rest, vector()) : SIf(ELocal(lo), vector(), rest));
				return ELocal(lo);
			case OpEq | OpNotEq:
				var xs = operands(vector(a, b));
				var eq = equality(xs[0], tyOf(a), xs[1], tyOf(b), false);
				return op == OpEq ? eq : ENot(eq);
			case OpLt | OpLte | OpGt | OpGte:
				var xs = operands(vector(a, b));
				return compare(op, xs[0], tyOf(a), xs[1], tyOf(b));
			case OpNullCoal:
				var t = tyOf(e);
				var lo = newLocal("nc", tyOf(a));
				out.push(SSet(lo, rhs(a)));
				var r = newLocal("r", t);
				var other = block(() -> out.push(SSet(r, coerceRhs(rhs(b), tyOf(b), t))));
				var isNull = Ir.isRef(lo.ty) ? EBin(RefEq, ELocal(lo), ENull(lo.ty)) : EInt(0);
				out.push(SIf(isNull, other, block(() -> out.push(SSet(r, coerce(ELocal(lo), lo.ty, t))))));
				return ELocal(r);
			case OpAdd if (isConcat(e) && isConcat(a)):
				return concatChain(e);
			case _:
				var xa = value(a);
				return arith(op, xa, tyOf(a), () -> {x: value(b), t: tyOf(b)}, tyOf(e), e);
		}
	}

	function isConcat(e:TExpr):Bool
		return e.eexpr.match(TBinop(OpAdd, _, _)) && tyOf(e).match(TRef(RStr));

	// a + b + c...: joined four at a time (hx_str_concat3, 4), no string
	// in between; each operand evaluated and converted where the chain of
	// binary + would (the first two after both are evaluated, the others
	// right after their own)
	function concatChain(e:TExpr):Ex {
		var es = [];
		var x = e;
		while (isConcat(x))
			switch x.eexpr {
				case TBinop(_, a, b):
					es.push(b);
					x = a;
				case _:
			}
		es.push(x);
		es.reverse();
		var n = es.length;
		var xs = new Vector<Ex>(n);
		var str = (i:Int) -> {
			var t = tyOf(es[i]);
			if (!t.match(TRef(RStr))) xs[i] = toStr(xs[i], t);
		};
		for (k in 0...n) {
			var before = out.length;
			var v = value(es[k]);
			if (out.length != before) {
				var spills = [];
				for (i in 0...k)
					if (!isConst(xs[i]) && !stableFrom(xs[i], before)) {
						var lo = newLocal("s", k > 1 ? TRef(RStr) : tyOf(es[i]));
						spills.push(SSet(lo, xs[i]));
						xs[i] = ELocal(lo);
					}
				for (j in 0...spills.length)
					out.insert(before + j, spills[j]);
			}
			xs[k] = v;
			if (k == 1) str(0);
			if (k >= 1) str(k);
		}
		var acc = xs[0];
		var i = 1;
		while (i < n) {
			var m = n - i < 3 ? n - i : 3;
			var args = new Vector<Ex>(m + 1);
			args[0] = acc;
			for (j in 0...m)
				args[j + 1] = xs[i + j];
			acc = temp(TRef(RStr), ECallHost(l.native(m == 1 ? "hx_str_concat" : "hx_str_concat" + (m + 1)), args, TRef(RStr)));
			i += m;
		}
		return acc;
	}

	// a op b, with a already lowered; b lowered by the callback (after a)
	function arith(op:Binop, xa:Ex, ta:Ty, getB:() -> {x:Ex, t:Ty}, rt:Ty, e:TExpr):Ex {
		var before = out.length;
		var rb = getB();
		if (out.length != before && !isConst(xa) && !stableFrom(xa, before)) {
			var lo = newLocal("s", ta);
			out.insert(before, SSet(lo, xa));
			xa = ELocal(lo);
		}
		var xb = rb.x, tb = rb.t;
		var isStr = (t:Ty) -> t.match(TRef(RStr));
		if (op == OpAdd && (rt.match(TRef(RStr)) || isStr(ta) || isStr(tb))) {
			var sa = toStr(xa, ta), sb = toStr(xb, tb);
			return temp(TRef(RStr), ECallHost(l.native("hx_str_concat"), vector(sa, sb), TRef(RStr)));
		}
		var num = (t:Ty) -> t == TI32 || t == TF64 || t == TBool || t == TI64 || t.match(TRef(RNull(_)));
		if (!num(ta) || !num(tb)) {
			// Dynamic arithmetic
			var da = coerce(xa, ta, TRef(RAny)), db = coerce(xb, tb, TRef(RAny));
			var r = temp(TRef(RAny), ECallHost(l.native("hx_dyn_op"), vector(EInt(opCode(op)), da, db), TRef(RAny)));
			return coerce(r, TRef(RAny), rt);
		}
		var scalar = (t:Ty) -> switch t {
			case TRef(RNull(s)): s;
			case _: t;
		};
		var sa = scalar(ta), sb = scalar(tb);
		if ((sa == TI64 || sb == TI64) && sa != TF64 && sb != TF64) {
			// Int64 (hxmc.I64 operators): the shift count stays an Int
			var shift = op == OpShl || op == OpShr || op == OpUShr;
			var la = coerce(xa, ta, TI64), lb = shift ? coerce(xb, tb, TI32) : coerce(xb, tb, TI64);
			var r = EBin(switch op {
				case OpAdd: LAdd;
				case OpSub: LSub;
				case OpMult: LMul;
				case OpDiv: LDiv;
				case OpMod: LMod;
				case OpAnd: LAnd;
				case OpOr: LOr;
				case OpXor: LXor;
				case OpShl: LShl;
				case OpShr: LShr;
				case OpUShr: LUShr;
				case _: fail("Int64 operator " + op, e);
			}, la, lb);
			return coerce(r, TI64, rt);
		}
		var isFloat = sa == TF64 || sb == TF64 || op == OpDiv || rt == TF64 && (op == OpAdd || op == OpSub || op == OpMult || op == OpMod);
		if (isFloat && !(op == OpAnd || op == OpOr || op == OpXor || op == OpShl || op == OpShr || op == OpUShr)) {
			var fa = coerce(xa, ta, TF64), fb = coerce(xb, tb, TF64);
			var r = EBin(switch op {
				case OpAdd: FAdd;
				case OpSub: FSub;
				case OpMult: FMul;
				case OpDiv: FDiv;
				case OpMod: FMod;
				case _: fail("float operator " + op, e);
			}, fa, fb);
			return coerce(r, TF64, rt);
		}
		var ia = coerce(xa, ta, TI32), ib = coerce(xb, tb, TI32);
		var r = EBin(switch op {
			case OpAdd: Add;
			case OpSub: Sub;
			case OpMult: Mul;
			case OpMod: Mod;
			case OpAnd: And;
			case OpOr: Or;
			case OpXor: Xor;
			case OpShl: Shl;
			case OpShr: Shr;
			case OpUShr: UShr;
			case _: fail("int operator " + op, e);
		}, ia, ib);
		return coerce(r, TI32, rt);
	}

	static function opCode(op:Binop):Int
		return switch op {
			case OpAdd: 0;
			case OpSub: 1;
			case OpMult: 2;
			case OpDiv: 3;
			case OpMod: 4;
			case OpAnd: 5;
			case OpOr: 6;
			case OpXor: 7;
			case OpShl: 8;
			case OpShr: 9;
			case OpUShr: 10;
			case _: -1;
		}

	// a == b as a TBool expression
	function equality(xa:Ex, ta:Ty, xb:Ex, tb:Ty, pureOnly:Bool):Ex {
		if (xb.match(ENull(_)) || xa.match(ENull(_))) {
			var x = xb.match(ENull(_)) ? xa : xb;
			var t = xb.match(ENull(_)) ? ta : tb;
			if (t == TId) return EBin(LEq, x, EConv(I2L, EInt(0))); // (nil)
			return Ir.isRef(t) ? EBin(RefEq, x, ENull(t)) : EInt(0);
		}
		// ids: the same object (never boxed for it: a box holds a reference, ObjC)
		if (ta == TId || tb == TId) return EBin(LEq, coerce(xa, ta, TId), coerce(xb, tb, TId));
		var scalar = (t:Ty) -> t == TI32 || t == TBool || t == TF64 || t == TI64;
		if (scalar(ta) && scalar(tb)) {
			if (ta == TF64 || tb == TF64) return EBin(FEq, coerce(xa, ta, TF64), coerce(xb, tb, TF64));
			if (ta == TI64 || tb == TI64) return EBin(LEq, coerce(xa, ta, TI64), coerce(xb, tb, TI64));
			return EBin(Eq, xa, xb);
		}
		switch [ta, tb] {
			case [TRef(RStr), TRef(RStr)]:
				return ECallHost("hx_str_eq", vector(xa, xb), TBool);
			// (a method closure: equal to another of the same method and object, made
			// apart, as on Eval and hl: hx_dyn_eq; upstream's Issue6705)
			case [TRef(RClos(_)), TRef(_)] | [TRef(_), TRef(RClos(_))]:
				return ECallHost("hx_dyn_eq", vector(coerce(xa, ta, TRef(RAny)), coerce(xb, tb, TRef(RAny))), TBool);
			// (a NativeArray: its identity, as hx_dyn_eq has it)
			case [TRef(RObj(_) | REnum(_) | RCtor(_) | RClos(_) | RArr(_) | RNativeArr(_) | RAnon | RType | RNative(_)), TRef(RObj(_) | REnum(_) | RCtor(_) | RClos(_) | RArr(_) | RNativeArr(_) | RAnon | RType | RNative(_))]:
				return EBin(RefEq, xa, xb);
			case _:
				var da = coerce(xa, ta, TRef(RAny)), db = coerce(xb, tb, TRef(RAny));
				return ECallHost("hx_dyn_eq", vector(da, db), TBool);
		}
	}

	function compare(op:Binop, xa:Ex, ta:Ty, xb:Ex, tb:Ty):Ex {
		var scalar = (t:Ty) -> switch t {
			case TI32 | TBool | TF64 | TI64: t;
			case TRef(RNull(s)): s;
			case _: null;
		};
		var sa = scalar(ta), sb = scalar(tb);
		// (a nullable number: null is not ordered with a number, two nulls are
		// equal, as on Eval and the static targets; null was read as 0: upstream's
		// TestOps)
		if (sa != null && sb != null && (ta.match(TRef(RNull(_))) || tb.match(TRef(RNull(_))))) {
			var a = asLocal(xa, ta), b = asLocal(xb, tb);
			inline function isNull(l:Local, t:Ty):Ex
				return t.match(TRef(RNull(_))) ? EBin(RefEq, ELocal(l), ENull(t)) : EInt(0);
			var r = newLocal("ord", TBool);
			var both = op == OpLte || op == OpGte ? 1 : 0;
			out.push(SIf(isNull(a, ta), vector(SIf(isNull(b, tb), vector(SSet(r, EInt(both))), vector(SSet(r, EInt(0))))),
				vector(SIf(isNull(b, tb), vector(SSet(r, EInt(0))), block(() -> out.push(SSet(r, compare(op, coerce(ELocal(a), ta, sa), sa, coerce(ELocal(b), tb, sb), sb))))))));
			return ELocal(r);
		}
		if (sa != null && sb != null) {
			if ((sa == TI64 || sb == TI64) && sa != TF64 && sb != TF64) {
				var la = coerce(xa, ta, TI64), lb = coerce(xb, tb, TI64);
				return EBin(switch op {
					case OpLt: LLt;
					case OpLte: LLe;
					case OpGt: LGt;
					case _: LGe;
				}, la, lb);
			}
			if (sa == TF64 || sb == TF64) {
				var fa = coerce(xa, ta, TF64), fb = coerce(xb, tb, TF64);
				return EBin(switch op {
					case OpLt: FLt;
					case OpLte: FLe;
					case OpGt: FGt;
					case _: FGe;
				}, fa, fb);
			}
			var ia = coerce(xa, ta, TI32), ib = coerce(xb, tb, TI32);
			return EBin(switch op {
				case OpLt: Lt;
				case OpLte: Le;
				case OpGt: Gt;
				case _: Ge;
			}, ia, ib);
		}
		var c = if (ta.match(TRef(RStr)) && tb.match(TRef(RStr))) ECallHost("hx_str_cmp", vector(xa, xb), TI32) else
			ECallHost("hx_dyn_cmp", vector(coerce(xa, ta, TRef(RAny)), coerce(xb, tb, TRef(RAny))), TI32);
		return EBin(switch op {
			case OpLt: Lt;
			case OpLte: Le;
			case OpGt: Gt;
			case _: Ge;
		}, c, EInt(0));
	}

	// lhs = value (or lhs = update(current)); returns the new value in ty(e.etype)
	function assign(lhs:TExpr, getValue:Null<() -> {x:Ex, t:Ty}>, e:TExpr, ?update:(Ex, Ty) -> Ex):Ex {
		inline function compute(cur:() -> Ex, curTy:Ty, to:Ty):Ex {
			if (update != null) return coerce(update(cur(), curTy), curTy, to);
			var v = getValue();
			return coerceRhs(v.x, v.t, to);
		}
		function pure(x:Ex, t:Ty):Ex
			return isConst(x) || x.match(ELocal(_)) ? x : ELocal(asLocal(x, t));
		var et = tyOf(e);
		switch strip(lhs).eexpr {
			case TLocal(v):
				if (appends.exists(v.vId)) flushAppend(v);
				var lo = local(v, e);
				var t = ty(v.vType);
				if (isBoxed(v)) {
					var x = pure(compute(() -> EBoxGet(t, ELocal(lo)), t, t), t);
					out.push(SBoxSet(t, ELocal(lo), x));
					return coerce(x, t, et);
				}
				var x = compute(() -> ELocal(lo), t, t);
				out.push(SSet(lo, x));
				return coerce(ELocal(lo), t, et);
			case TField(obj, FInstance(c, _, cf) | FStatic(c, cf)) if (cf.cfKind.match(Var(_)) && ObjC.isObjC(c)):
				// (a property: its setter, after the value, the getter first for an update)
				var instance = strip(lhs).eexpr.match(TField(_, FInstance(_, _, _)));
				var self = ELocal(asLocal(instance ? coerce(value(obj), tyOf(obj), TId) : objcClass(c), TI64));
				var t = ty(cf.cfType);
				var x = pure(compute(() -> objcMsg(self, ObjC.getter(cf), [], [], cf.cfType, cf, lhs, t), t, t), t);
				objcSet(self, c, cf, x, t, e);
				return coerce(x, t, et);
			case TField(obj, FInstance(c, _, cf)) if (CInterop.isStruct(c)):
				// (the address after the value: an object may move meanwhile)
				var f = CInterop.field(c, cf.cfName);
				var p = placeOf(obj, true);
				var t = tyOf(lhs);
				var x = pure(compute(() -> cLoad(p.addr(), f.off, f.ty, lhs), t, t), t);
				cStore(p.addr(), f.off, f.ty, x, t, e);
				return coerce(x, t, et);
			case TField(obj, FInstance(c, _, cf)) if (!c.hasClassFlag(CExtern) && !c.hasClassFlag(CInterface)):
				var ci = l.classInfo(c);
				var idx = ci.fieldIndex(cf.cfName);
				var t = ci.fields[idx].ty;
				var o = ELocal(asLocal(value(obj), tyOf(obj)));
				var x = pure(compute(() -> EField(ci, idx, o), t, t), t);
				if (t == TId) {
					// (an id: the field holds a reference, ObjC)
					var old = asLocal(EField(ci, idx, o), t);
					objcRetain(x);
					out.push(SSetField(ci, idx, o, x));
					objcRelease(ELocal(old));
					return coerce(x, t, et);
				}
				out.push(SSetField(ci, idx, o, x));
				return coerce(x, t, et);
			case TField(obj, FInstance(c, _, cf)) if (Lower.isCore(c, "Array") && cf.cfName == "length"):
				// `untyped a.length = n` (haxe.ds.Vector's generic constructor):
				// Array.resize, not a structural store by name
				var o = ELocal(asLocal(value(obj), tyOf(obj)));
				var x = pure(compute(() -> EArrLen(o), TI32, TI32), TI32);
				out.push(SExpr(ECallHost(l.native("Array_resize"), vector(o, x), TVoid)));
				return coerce(x, TI32, et);
			case TField(obj, FAnon(cf) | FInstance(_, _, cf)):
				var t = l.boxed(tyOf(lhs));
				var o = ELocal(asLocal(value(obj), tyOf(obj)));
				var x = pure(compute(() -> EAnonGet(cf.cfName, t, o, null), t, t), t);
				out.push(SAnonSet(cf.cfName, t, o, x));
				return coerce(x, t, et);
			case TField(_, FStatic(c, cf)) if (!c.hasClassFlag(CExtern)):
				var g = l.staticVar(c, cf);
				var t = l.globalTy(g);
				var x = pure(compute(() -> EGlobal(g, t), t, t), t);
				if (t == TId) {
					var old = asLocal(EGlobal(g, t), t);
					objcRetain(x);
					out.push(SSetGlobal(g, x));
					objcRelease(ELocal(old));
					return coerce(x, t, et);
				}
				out.push(SSetGlobal(g, x));
				return coerce(x, t, et);
			case TField(obj, FDynamic(name)):
				var o = ELocal(asLocal(coerce(value(obj), tyOf(obj), TRef(RAny)), TRef(RAny)));
				var t = TRef(RAny);
				var x = pure(compute(() -> temp(t, ECallHost(l.native("hx_dyn_get"), vector(o, EStr(name)), t)), t, t), t);
				out.push(SExpr(ECallHost(l.native("hx_dyn_set"), vector(o, EStr(name), x), TVoid)));
				return coerce(x, t, et);
			case TArray(a, i):
				switch tyOf(a) {
					case TRef(RNativeArr(elem)):
						var al = asLocal(value(a), tyOf(a));
						var ix = ELocal(asLocal(coerce(value(i), tyOf(i), TI32), TI32));
						var t = elemValue(elem);
						var x = pure(compute(() -> nativeRead(elem, ELocal(al), ix, lhs.epos), t, t), t);
						nativeWrite(elem, ELocal(al), ix, x, lhs.epos);
						return coerce(x, t, et);
					case TRef(RArr(elem)):
						var al = asLocal(value(a), tyOf(a));
						var ix = ELocal(asLocal(coerce(value(i), tyOf(i), TI32), TI32));
						var x = pure(compute(() -> EArrGet(elem, ELocal(al), ix), elem, elem), elem);
						out.push(SArrSet(elem, al, ix, x));
						return coerce(x, elem, et);
					case _:
						var t = TRef(RAny);
						var o = ELocal(asLocal(coerce(value(a), tyOf(a), t), t));
						var ix = ELocal(asLocal(coerce(value(i), tyOf(i), TI32), TI32));
						var x = pure(compute(() -> temp(t, ECallHost(l.native("hx_dyn_aget"), vector(o, ix), t)), t, t), t);
						out.push(SExpr(ECallHost(l.native("hx_dyn_aset"), vector(o, ix, x), TVoid)));
						return coerce(x, t, et);
				}
			case _:
				return fail("assignment target " + strip(lhs).eexpr.getName(), e);
		}
	}

	function unop(op:Unop, flag:UnopFlag, e1:TExpr, e:TExpr):Ex {
		return switch op {
			case Increment | Decrement:
				var bop = op == Increment ? OpAdd : OpSub;
				var one = () -> {x: (EInt(1) : Ex), t: TI32};
				if (flag == Prefix) assign(e1, null, e, (cur, t) -> arith(bop, cur, t, one, t, e)) else {
					var t1 = tyOf(e1);
					var old = newLocal("old", t1);
					// (the target may hold another representation, t: a generic field read as Int)
					assign(e1, null, e, (cur, t) -> {
						out.push(SSet(old, coerce(cur, t, t1)));
						arith(bop, ELocal(old), t1, one, t, e);
					});
					coerce(ELocal(old), t1, tyOf(e));
				}
			// the result has the representation of tyOf(e), which may be Null<T>
			case Not: coerce(ENot(cond(e1)), TBool, tyOf(e));
			case Neg:
				var t1 = tyOf(e1);
				var x = value(e1);
				switch tyOf(e) {
					case TF64: EConv(FNeg, coerce(x, t1, TF64));
					case TI64: EConv(LNeg, coerce(x, t1, TI64));
					case TI32: EBin(Sub, EInt(0), coerce(x, t1, TI32));
					case t = TRef(RNull(TI32)): coerce(EBin(Sub, EInt(0), coerce(x, t1, TI32)), TI32, t);
					case t: coerce(EConv(FNeg, coerce(x, t1, TF64)), TF64, t);
				}
			case NegBits: coerce(EBin(Xor, coerce(value(e1), tyOf(e1), TI32), EInt(-1)), TI32, tyOf(e));
			case Spread: fail("spread", e);
		}
	}

	// ---- calls

	function call(f:TExpr, cargs:Vector<TExpr>, e:TExpr):Ex {
		var rt = tyOf(e);
		switch strip(f).eexpr {
			case TField(o, FStatic(c, cf)) if (overloadImpl(c, cf) != cf):
				// (its arguments and result converted from the overload's types)
				f = {eexpr: TField(o, FStatic(c, overloadImpl(c, cf))), etype: f.etype, epos: f.epos};
			case _:
		}
		switch strip(f).eexpr {
			// a selector literal (hxmc.objc.Selector.of)
			case TField(_, FStatic({clKind: KAbstractImpl(a)}, cf)) if (cf.cfName == "of" && a.aPath.name == "Selector" && a.aPath.pack.join(".") == "hxmc.objc"):
				var name = switch strip(cargs[0]).eexpr {
					case TConst(TString(s)): s;
					case _: fail("Selector.of: the name must be a string literal", e);
				};
				var ref = temp(TI64, ECallHost("hxmc_unsafe_Mem_sym", vector(EStr(ObjC.selRef(name))), TI64));
				return coerce(ECallHost("hxmc_unsafe_Mem_getI64", vector(ref, EInt(0)), TI64), TI64, rt);
			// a message (ObjC)
			case TField(obj, FInstance(c, _, cf)) if (cf.cfKind.match(Method(_)) && ObjC.isObjC(c) && !strip(obj).eexpr.match(TConst(TSuper))):
				return objcSend(obj, c, cf, cargs, e);
			case TField(_, FStatic(c, cf)) if (cf.cfKind.match(Method(_)) && ObjC.isObjC(c)):
				return objcSend(null, c, cf, cargs, e);
			// (the std's own loops, over indices they keep in bounds: not
			// tested, whatever -D hxmc.native-array-outofbounds says)
			case TField(obj, FInstance(c, _, cf)) if (Lower.isNativeArray(c) && (cf.cfName == "unsafeGet" || cf.cfName == "unsafeSet")):
				var elem = switch tyOf(obj) {
					case TRef(RNativeArr(t)): t;
					case _: return fail("NativeArray." + cf.cfName + " of another type", e);
				};
				var xs = operands(VectorTools.cons(obj, cargs));
				var a = ELocal(asLocal(xs[0], tyOf(obj))), i = coerce(xs[1], tyOf(cargs[0]), TI32);
				if (cf.cfName == "unsafeGet") return elemRead(nativeRead(elem, a, i), elem, rt);
				nativeWrite(elem, a, i, ELocal(asLocal(coerce(xs[2], tyOf(cargs[1]), elemValue(elem)), elemValue(elem))));
				return EInt(0);
			// NativeArray.literal([a, b, c]) (VectorTools' `vector(a, b, c)`): one
			// allocation and the elements stored in order, as an Array literal is
			// (MirBuild, hxmc_narray_lit); the storage of an erased type parameter
			// as `new NativeArray(n)` and its stores
			case TField(_, FStatic(c, cf)) if (Lower.isNativeArray(c) && cf.cfName == "literal"):
				var el = switch strip(cargs[0]).eexpr {
					case TArrayDecl(el): el;
					case _: return fail("NativeArray.literal of something else than an array literal", e);
				};
				var elem = switch rt {
					case TRef(RNativeArr(t)): t;
					case _: return fail("NativeArray.literal of another type", e);
				};
				var erased = switch TFunctions.follow(e.etype) {
					case TInst(_, [p]): switch TFunctions.follow(p) {
							case TInst(pc, _): pc.clKind.match(KTypeParameter(_));
							case _: false;
						}
					case _: false;
				};
				var xs = operands(el);
				if (!erased)
					return ECallHost("hxmc_narray_lit", VectorTools.cons(EInt(nativeKind(elem)), xs.mapi((i, x) -> coerce(x, tyOf(el[i]), elemValue(elem)))), rt);
				var a = ELocal(asLocal(ECallHost(l.native("hx_narray_open"), vector(EInt(el.length)), rt), rt));
				for (i in 0...el.length)
					nativeWrite(elem, a, EInt(i), ELocal(asLocal(coerce(xs[i], tyOf(el[i]), elemValue(elem)), elemValue(elem))));
				return a;
			case TField(_, FStatic(_, cf)) if (cf.cfKind.match(Var(_))):
				return callValue(f, cargs, e);
			case TField(_, FStatic(c, cf)) if (cf.cfName == "names" && c.clPath.name == "NativeResource" && c.clPath.pack.join(".") == "hxmc"):
				// haxe.Resource's names (hxmc.NativeResource): a new array of
				// them as literals, in Lower.resources' order (their bytes are
				// DataGen's, read by the runtime: hxmc.rt.Bytes)
				var at = TRef(RArr(TRef(RStr)));
				return coerce(temp(at, ENewArr(TRef(RStr), Lower.resources.mapToVector(r -> EStr(r.name)))), at, rt);
			case TField(_, FStatic(c, cf)) if (c.hasClassFlag(CExtern) || cf.cfExpr == null):
				var s = switch TFunctions.follow(cf.cfType) {
					case TFun(s): s;
					case _: fail("extern static " + cf.cfName + " is not a function", e);
				};
				var ci = cInteropCall(c, cf, cargs, e);
				if (ci != null) return ci;
				// a C function by its own symbol (@:hxmc.c, CInterop): a GC point
				// in a safe region, or none (@:hxmc.fast: hxmc.unsafe.LibC)
				// @:hxmc.indirect: the first argument is the C function's address
				if (Lower.hasMeta(":hxmc.indirect", cf.cfMeta)) return cCall(CInterop.INDIRECT + Lower.nativeName(c) + "_" + cf.cfName, c, cf, s, cargs, e);
				var sym = CInterop.cSymbol(c, cf);
				if (sym != null) return cCall(sym, c, cf, s, cargs, e);
				var name = Lower.nativeName(c) + "_" + cf.cfName;
				if (Lower.hasMeta(":hxmc.rt", c.clMeta)) {
					// the runtime's C functions (hxmc.rt.C), which may collect
					var n = Lower.metaArg(core.Meta.getOpt(Native, cf.cfMeta));
					name = n != null ? n : cf.cfName;
				}
				var intrinsic = intrinsicStatic(name, cargs, e);
				if (intrinsic != null) return intrinsic;
				var t = ty(s.ret);
				var xs = args(cargs, s.args.map(a -> ty(a.type)), null);
				return coerceRhs(ECallHost(l.native(name), xs, t), t, rt);
			case TField(obj, FDynamic("cca")) if (tyOf(obj).match(TRef(RStr)) && cargs.length == 1):
				// StringTools.fastCodeAt / unsafeCodeAt: `untyped s.cca(i)` (0 past the end, as on cpp/hl)
				var xs = operands(vector(obj, cargs[0]));
				return coerceRhs(ECallHost("String_charCodeAt_i", vector(xs[0], coerce(xs[1], tyOf(cargs[0]), TI32)), TI32), TI32, rt);
			case TField(_, FStatic(c, cf)) if (cf.cfKind.match(Method(MethDynamic)) && !c.hasClassFlag(CExtern)):
				var g = staticDynMethod(c, cf);
				var t = l.globalTy(g);
				var s = switch t { case TRef(RClos(s)): s; case _: fail("dynamic static " + cf.cfName + " is not a closure", e); };
				var cl = asLocal(EGlobal(g, t), t);
				var xs = args(cargs, s.args, null);
				return callClos(s, ELocal(cl), xs, rt);
			// (@:hxmc.withStacks: a call left out of a program without the
			// table of its functions and lines, Lower.lines: hxmc.rt.Stacks'
			// recording of a throw and report of an uncaught exception)
			case TField(_, FStatic(c, cf)) if (!Lower.lines && rt == TVoid && Lower.hasMeta(":hxmc.withStacks", cf.cfMeta)):
				return EInt(0);
			case TField(_, FStatic(c, cf)):
				var fn = l.staticFunc(c, cf);
				// (spans made as arguments of a kernel: filled once
				// every argument is evaluated, spanCall)
				var outer = boundary;
				var made = fn.declKernel ? [for (a in cargs) if (spanMaker(a)) strip(a)] : [];
				boundary = made.length > 0 ? {direct: made, fills: []} : null;
				var xs = args(cargs, callTys(fn), defaultValues(fn), 0, fn);
				var fills = boundary != null ? boundary.fills : null;
				boundary = outer;
				if (fills != null)
					for (fill in fills)
						fill();
				spanInGcCode(e.etype, e, "the result of " + (fn.display != null ? fn.display : fn.name));
				// (@:hxmc.blocking: in a safe region, unless called from one)
				if (fn.declBlocking && !fi.declBlocking && Lower.targetOs != 3)
					return inRegion(xs, callTys(fn), xs -> ECall(fn, xs), fn.ret, rt);
				return callFn(fn, xs, rt);
			// a message to super (ObjC): in a constructor, an initializer
			// (`self = [super initX:...]`); elsewhere, objc_msgSendSuper
			case TField({eexpr: TConst(TSuper)}, FInstance(c, _, cf)) if (ObjC.isObjC(c)):
				if (self == null || self.objc == null)
					return fail("super." + cf.cfName + ": a message to super in a class that does not extend an Objective-C class", e);
				if (ObjC.isInit(cf)) {
					if (!inCtor) return fail("super." + cf.cfName + "(...): an initializer, called in the constructor only", e);
					return coerce(objcSuperInit(l.superOf(self), cf, cargs, e), TId, rt);
				}
				return objcSendSuper(l.superOf(self), c, cf, cargs, e);
			case TField({eexpr: TConst(TSuper)}, FInstance(c, _, cf)):
				var impl = l.lookupMethod(c, cf.cfName);
				if (impl == null) fail("super." + cf.cfName + " without implementation", e);
				var fn = l.method(impl.cls, impl.field);
				var xs = args(cargs, callTys(fn), defaultValues(fn), 1, fn, () -> ELocal(thisLocal));
				return callFn(fn, VectorTools.cons(ELocal(thisLocal), xs), rt);
			case TConst(TSuper) if (self != null && l.superOf(self) != null && ObjC.isObjC(l.superOf(self))):
				return fail("super(...) of an Objective-C class: call super.init...(...) instead", e);
			case TConst(TSuper):
				var sup = l.superOf(self);
				while (sup != null && sup.clConstructor == null && sup.clSuper != null)
					sup = sup.clSuper.cls;
				if (sup == null || sup.clConstructor == null) return EInt(0);
				var fn = l.ctor(sup);
				var xs = args(cargs, tys(fn), defaultValues(fn), 1, fn, () -> ELocal(thisLocal));
				out.push(SExpr(ECall(fn, VectorTools.cons(ELocal(thisLocal), xs))));
				return EInt(0);
			case TField(obj, FInstance(c, _, cf)) if (Lower.isCore(c, "Array") && cf.cfName == "push"):
				var at = tyOf(obj);
				var elem = switch at {
					case TRef(RArr(t)): t;
					case _: TRef(RAny);
				};
				var xs = operands(vector(obj, cargs[0]));
				var al = asLocal(xs[0], at);
				out.push(SArrPush(elem, al, coerce(xs[1], tyOf(cargs[0]), elem)));
				return coerce(EArrLen(ELocal(al)), TI32, rt);
			case TField(obj, FInstance(c, _, cf)) if (c.hasClassFlag(CInterface) && cf.cfKind.match(Method(MethDynamic)) && tyOf(f).match(TRef(RClos(_)))):
				// a dynamic method through an interface: the function its field
				// holds, by name, as through a structure (upstream's Issue3159)
				var s = switch tyOf(f) {
					case TRef(RClos(s)): s;
					case _: null;
				};
				if (hasStruct(s)) structFail('a struct value passed to or returned by a dynamic method of an interface: not supported');
				var o = asLocal(value(obj), tyOf(obj));
				var xs = args(cargs, s.args, null);
				return coerceRhs(ECallAnon(cf.cfName, s, ELocal(o), xs), s.ret, rt);
			case TField(obj, FInstance(c, _, cf)) if (Lower.isCore(c, "Array") && cf.cfName == "sort" && sortElem(tyOf(obj), cargs[0]) != null):
				// Array<Int> and Array<Float> sorted with a comparator of their
				// type: Arr.sortInt, sortFloat, which call it with their
				// elements unboxed (Array_sort takes Dynamic ones: a box per
				// element read)
				var elem = sortElem(tyOf(obj), cargs[0]);
				var cmp = TRef(RClos(l.sig([elem, elem], TI32)));
				var xs = args(VectorTools.cons(obj, cargs), vector(tyOf(obj), cmp), null);
				xs[0] = receiverCheck(xs[0], tyOf(obj));
				return coerceRhs(ECallHost(l.native(elem == TI32 ? "Array_sortInt" : "Array_sortFloat"), xs, TVoid), TVoid, rt);
			case TField(obj, FInstance(c, _, cf)) if (c.hasClassFlag(CExtern) || Lower.isCore(c, "String") || Lower.isCore(c, "Array")):
				var s = switch TFunctions.follow(cf.cfType) {
					case TFun(s): s;
					case _: fail("extern method " + cf.cfName + " is not a function", e);
				};
				var name = Lower.nativeName(c) + "_" + cf.cfName;
				var t = ty(s.ret);
				var to = new Vector<Ty>(s.args.length + 1);
				to[0] = tyOf(obj);
				for (k in 0...s.args.length)
					to[k + 1] = ty(s.args[k].type);
				var xs = args(VectorTools.cons(obj, cargs), to, null);
				xs[0] = receiverCheck(xs[0], tyOf(obj));
				var intrinsic = intrinsicMethod(name, xs, tyOf(obj));
				if (intrinsic != null) return coerce(intrinsic, t, rt);
				return coerceRhs(ECallHost(l.native(name), xs, t), t, rt);
			case TField(obj, FInstance(c, _, cf)):
				switch cf.cfKind {
					case Var(_):
						// a field holding a function
						return callValue(f, cargs, e);
					case Method(MethDynamic) if (isDynMethod(c, cf)):
						var st = dynSlotTy(c, cf);
						var s = switch st { case TRef(RClos(s)): s; case _: fail("dynamic method " + cf.cfName + " is not a closure", e); };
						var cl = asLocal(dynMethod(obj, c, cf, e), st);
						var xs = args(cargs, s.args, null); // closure calls apply defaults in the callee
						return callClos(s, ELocal(cl), xs, rt);
					case Method(_):
				}
				if (l.needsDispatch(c, cf.cfName)) {
					var d = dispatchType(c, cf);
					var sig = d.sig;
					var decl = l.rootDecl(c, cf.cfName);
					var impl = l.lookupMethod(c, cf.cfName);
					var implFn = impl != null ? l.method(impl.cls, impl.field) : null;
					var ds = implFn != null ? defaultValues(implFn) : null;
					var rootTy = TRef(RObj(l.rootClass()));
					var o = coerce(value(obj), tyOf(obj), rootTy);
					var before = out.length;
					var to = VectorTools.ofArray(sig.ret.match(TStruct(_)) ? d.args.slice(0, d.args.length - 1) : d.args);
					var xs = args(cargs, to, ds, 1, implFn, () -> o = receiverLocal(o, rootTy, before));
					o = spillBefore(o, rootTy, before);
					if (cargs.length + 1 < to.length && !o.match(ELocal(_))) o = ELocal(asLocal(o, rootTy)); // (the defaults may test it)
					overrideDefaults(c, cf.cfName, o, xs, cargs.length, to, ds);
					if (sig.ret.match(TStruct(_))) {
						// (a struct result: the address of a slot here, last)
						var s = newSlot(sig.ret, true);
						out.push(SExpr(ECallDispatch(l.selector(cf.cfName, sig), sig, VectorTools.cons(o, xs).snoc(ELocal(s)))));
						return coerce(ELocal(s), sig.ret, rt);
					}
					return coerceRhs(ECallDispatch(l.selector(cf.cfName, sig), sig, VectorTools.cons(o, xs)), d.ret, rt);
				}
				var impl = l.lookupMethod(c, cf.cfName);
				if (impl == null) fail("no implementation of " + cf.cfName, e);
				var fn = l.method(impl.cls, impl.field);
				var o = value(obj);
				var before = out.length;
				var xs = args(cargs, callTys(fn), defaultValues(fn), 1, fn, () -> o = receiverLocal(o, tyOf(obj), before));
				return callFn(fn, VectorTools.cons(spillBefore(o, tyOf(obj), before), xs), rt);
			case TField(_, FEnum(en, ef)):
				var ci = l.ctorInfo(ef, en);
				var xs = args(cargs, ci.params, null);
				return coerceRhs(ENewEnum(ci, xs), TRef(RCtor(ci)), rt);
			case TField(obj, FAnon(cf) | FInstance(_, _, cf)) if (tyOf(f).match(TRef(RClos(_)))):
				var s = switch tyOf(f) {
					case TRef(RClos(s)): s;
					case _: null;
				};
				if (hasStruct(s)) structFail('a struct value passed to or returned by a function of a structural type: not supported (an interface or a class)');
				var o = asLocal(value(obj), tyOf(obj));
				var xs = args(cargs, s.args, null);
				return coerceRhs(ECallAnon(cf.cfName, s, ELocal(o), xs), s.ret, rt);
			case TField(obj, FDynamic(name)):
				var o = coerce(value(obj), tyOf(obj), TRef(RAny));
				var xs = args(cargs, new Vector<Ty>(cargs.length, TRef(RAny)), null);
				var arr = temp(TRef(RArr(TRef(RAny))), ENewArr(TRef(RAny), xs));
				var r = ECallHost(l.native("hx_dyn_call_field"), vector(o, EStr(name), arr), TRef(RAny));
				return coerceRhs(r, TRef(RAny), rt);
			case _:
				return callValue(f, cargs, e);
		}
	}

	// calling a function value: a closure, or Dynamic
	function callValue(f:TExpr, cargs:Vector<TExpr>, e:TExpr):Ex {
		var rt = tyOf(e);
		switch tyOf(f) {
			case TRef(RClos(s)):
				var fx = value(f);
				var c = asLocal(fx, tyOf(f));
				var xs = args(cargs, s.args, null);
				return callClos(s, ELocal(c), xs, rt);
			case _:
				var fx = coerce(value(f), tyOf(f), TRef(RAny));
				var c = asLocal(fx, TRef(RAny));
				var xs = args(cargs, new Vector<Ty>(cargs.length, TRef(RAny)), null);
				var arr = temp(TRef(RArr(TRef(RAny))), ENewArr(TRef(RAny), xs));
				return coerceRhs(ECallHost(l.native("hx_dyn_call"), vector(ELocal(c), arr), TRef(RAny)), TRef(RAny), rt);
		}
	}

	// static externs lowered to IR operations instead of runtime calls
	function intrinsicStatic(name:String, cargs:Vector<TExpr>, e:TExpr):Null<Ex> {
		return switch name {
			case "Std_int" if (cargs.length == 1):
				var mm = intMinMax(cargs[0]);
				if (mm != null) return coerce(mm, TI32, tyOf(e));
				var x = coerce(value(cargs[0]), tyOf(cargs[0]), TF64);
				// Std.int(a / b) of an Int by a constant: an Int division (MirBuild.idiv),
				// the same Int for every a: the Float quotient of two Ints is never
				// rounded across an integer (error below 2^-22 / |b|, distance at least
				// 1 / |b|), MIN / -1 (2^31) converts to MIN as -MIN wraps, a / 0 to 0.
				// (By a run-time b the Float division stays: faster than a guarded idiv.)
				switch x {
					case EBin(FDiv, xa, xb = (EConv(I2F, EInt(_)) | EF64(_))) if (intOperand(xa) != null && intOperand(xb) != null):
						return coerce(EBin(Div, intOperand(xa), intOperand(xb)), TI32, tyOf(e));
					case _:
				}
				coerce(EConv(F2I, x), TI32, tyOf(e));
			case "Std_isOfType" if (cargs.length == 2 && instClass(cargs[1]) != null):
				// Std.isOfType(v, C) of a class literal: the instance test, a range of
				// type indices (MemLower.instOf; null is no instance), not hx_is's walk
				var ci = instClass(cargs[1]);
				coerce(EInstOf(ci, coerce(value(cargs[0]), tyOf(cargs[0]), TRef(RAny))), TBool, tyOf(e));
			case "Std_downcast" if (cargs.length == 2 && instClass(cargs[1]) != null):
				var ci = instClass(cargs[1]);
				var x = ELocal(asLocal(coerce(value(cargs[0]), tyOf(cargs[0]), TRef(RAny)), TRef(RAny)));
				var r = newLocal("down", TRef(RAny));
				out.push(SSet(r, ENull(TRef(RAny))));
				out.push(SIf(EInstOf(ci, x), vector(SSet(r, x)), vector()));
				coerce(ELocal(r), TRef(RAny), tyOf(e));
			case "Std_isOfType" if (cargs.length == 2 && typeObjectKind(cargs[1]) >= 0):
				// Std.isOfType(v, Class), (v, Enum): whether v is a type object of a
				// class or of an enum (hx_is_typeobj; hx_is knows no such type)
				var k = typeObjectKind(cargs[1]);
				coerce(ECallHost(l.native("hx_is_typeobj"), vector(coerce(value(cargs[0]), tyOf(cargs[0]), TRef(RAny)), EInt(k)), TBool), TBool, tyOf(e));
			case _: null;
		}
	}

	// the class whose instance test (EInstOf) Std.isOfType, Std.downcast and
	// cast give for the type expression x, or null where hx_is must decide:
	// an interface, an extern class (String, Array, Date, the boxes: the
	// runtime's own type indices), a type parameter; any class while Mir macros
	// lower their bundles (Lower.classSpans)
	function instClass(x:TExpr):Null<ClassInfo> {
		return switch strip(x).eexpr {
			case TTypeExpr(mt): castClass(mt);
			case _: null;
		}
	}

	function castClass(mt:ModuleType):Null<ClassInfo> {
		if (!Lower.classSpans) return null;
		return switch mt {
			case TClassDecl(c) if (!c.hasClassFlag(CExtern) && !c.hasClassFlag(CInterface) && !c.clKind.match(KTypeParameter(_))): classOrBox(c);
			case _: null;
		}
	}

	// 0 for the type expression Class, 1 for Enum, else -1
	function typeObjectKind(x:TExpr):Int {
		return switch strip(x).eexpr {
			case TTypeExpr(TAbstractDecl(a)) if (a.aPath.pack.length == 0 && a.aPath.name == "Class"): 0;
			case TTypeExpr(TAbstractDecl(a)) if (a.aPath.pack.length == 0 && a.aPath.name == "Enum"): 1;
			case _: -1;
		}
	}

	// the Int a Float operand is exactly (an Int converted, an integral literal), or null
	static function intOperand(x:Ex):Null<Ex> {
		return switch x {
			case EConv(I2F, i) if (Ir.typeOf(i) == TI32): i;
			case EF64(v) if (v == Math.ffloor(v) && v >= -2147483648.0 && v <= 2147483647.0): EInt(Std.int(v));
			case _: null;
		}
	}

	// Std.int(Math.min(a, b)) (or max) of two Ints: the smaller (larger) Int,
	// which is what the Float operation gives back exactly
	function intMinMax(x:TExpr):Null<Ex> {
		return switch strip(x).eexpr {
			case TCall({eexpr: TField(_, FStatic(c, cf))}, [a, b])
				if (c.clPath.pack.length == 0 && c.clPath.name == "Math" && (cf.cfName == "min" || cf.cfName == "max")
					&& tyOf(a) == TI32 && tyOf(b) == TI32):
				var xa = newLocal("mm", TI32);
				out.push(SSet(xa, value(a))); // (a copy: evaluating b may change it)
				var xb = asLocal(value(b), TI32);
				var r = newLocal("mm", TI32);
				out.push(SSet(r, ELocal(xb)));
				out.push(SIf(EBin(cf.cfName == "min" ? Lt : Gt, ELocal(xa), ELocal(xb)), vector(SSet(r, ELocal(xa))), vector()));
				ELocal(r);
			case _: null;
		}
	}

	// the element type of an Array<Int> or Array<Float> sorted with a
	// comparator of that type (Int or Float arguments, an Int result), else null
	function sortElem(at:Ty, cmp:TExpr):Null<Ty> {
		var elem = switch at {
			case TRef(RArr(t)) if (t == TI32 || t == TF64): t;
			case _: return null;
		}
		return switch tyOf(cmp) {
			case TRef(RClos(s)) if (s.args.length == 2 && s.args[0] == elem && s.args[1] == elem && s.ret == TI32): elem;
			case _: null;
		}
	}

	function intrinsicMethod(name:String, xs:Vector<Ex>, selfTy:Ty):Null<Ex> {
		return null;
	}

	// ---- C interop (docs/interop.md; CInterop)

	static inline function where(e:TExpr):String
		return CInterop.posOf(e.epos);

	function cfail(msg:String, e:TExpr):Dynamic
		throw new LowerError(msg, where(e));


	// the load of C type ct at addr + off, with the representation of ty(t)
	function cLoad(addr:Ex, off:Int, ct:CTy, e:TExpr):Ex {
		inline function get(n:String, t:Ty):Ex
			return coerce(temp(t, ECallHost("hxmc_unsafe_Mem_" + n, vector(addr, EInt(off)), t)), t, tyOf(e));
		return switch ct {
			case CI8: get("getI8", TI32);
			case CU8: get("getU8", TI32);
			case CBool: coerce(EBin(Ne, temp(TI32, ECallHost("hxmc_unsafe_Mem_getU8", vector(addr, EInt(off)), TI32)), EInt(0)), TBool, tyOf(e));
			case CI16: get("getI16", TI32);
			case CU16: get("getU16", TI32);
			case CI32: get("getI32", TI32);
			case CI64 | CPtr: get("getI64", TI64);
			case CF32: get("getF32", TF64);
			case CF64: get("getF64", TF64);
			case CStruct(_): off == 0 ? addr : EBin(LAdd, addr, EConv(I2L, EInt(off))); // (a struct: its address)
			case _: cfail("no C type to load (" + CInterop.name(ct) + ")", e);
		}
	}

	// the store of v (with the representation of from) as C type ct at addr + off
	function cStore(addr:Ex, off:Int, ct:CTy, v:Ex, from:Ty, e:TExpr) {
		inline function set(n:String, t:Ty)
			out.push(SExpr(ECallHost("hxmc_unsafe_Mem_" + n, vector(addr, EInt(off), coerce(v, from, t)), TVoid)));
		switch ct {
			case CI8 | CU8 | CBool: set("setI8", TI32);
			case CI16 | CU16: set("setI16", TI32);
			case CI32: set("setI32", TI32);
			case CI64 | CPtr: set("setI64", TI64);
			case CF32: set("setF32", TF64);
			case CF64: set("setF64", TF64);
			case CStruct(c):
				var src = ELocal(asLocal(coerce(v, from, TI64), TI64));
				copyStruct(off == 0 ? addr : EBin(LAdd, addr, EConv(I2L, EInt(off))), src, c);
			case _: cfail("no C type to store (" + CInterop.name(ct) + ")", e);
		}
	}

	// the element type of the Ptr a call of Ptr's typed access works on
	function ptrElemCt(t:core.TType.T, e:TExpr):CTy {
		var ct = CInterop.ctype(t);
		return switch ct {
			case CNone | CVoid: cfail('Ptr<${core.TPrinting.sTypes(vector(t))}>: no C type to access (scalars, Ptr, CString and @:hxmc.struct classes)', e);
			case COpaque(c): cfail('Ptr<${c.clPath.name}>: an opaque type has no contents to access', e);
			case _: ct;
		}
	}

	// calls of Ptr's extern accessors (value, [i], offset) and of Struct's layout
	// constants; null for any other call
	function cInteropCall(c:TClass, cf:TClassField, cargs:Vector<TExpr>, e:TExpr):Null<Ex> {
		switch c.clKind {
			case KAbstractImpl(a) if (KernelCheck.isSpanAbstract(a)):
				return spanCall(a, cf, cargs, e);
			case KAbstractImpl(a) if (a.aPath.name == "Ptr" && a.aPath.pack.join(".") == "hxmc.unsafe"):
				var n = cf.cfName;
				// (T: the result of value, [i] and their setters; offset returns Ptr<T>)
				var et = n == "offset" ? CInterop.ptrElem(e.etype) : e.etype;
				if (et == null) cfail("Ptr." + n + ": unknown element type", e);
				var ct = ptrElemCt(et, e);
				var size = CInterop.sizeOf(ct);
				var xs = operands(cargs);
				var p = coerce(xs[0], tyOf(cargs[0]), TI64);
				// p + i * size
				function at(i:Ex, it:Ty):Ex {
					var k = coerce(i, it, TI32);
					return switch k {
						case EInt(0): p;
						case EInt(v): EBin(LAdd, p, EBin(LMul, EConv(I2L, EInt(v)), EConv(I2L, EInt(size))));
						case _: EBin(LAdd, p, EBin(LMul, EConv(I2L, k), EConv(I2L, EInt(size))));
					}
				}
				return switch n {
					case "get_value": cLoad(ELocal(asLocal(p, TI64)), 0, ct, e);
					case "get": cLoad(ELocal(asLocal(at(xs[1], tyOf(cargs[1])), TI64)), 0, ct, e);
					case "set_value":
						var v = ELocal(asLocal(xs[1], tyOf(cargs[1])));
						cStore(ELocal(asLocal(p, TI64)), 0, ct, v, tyOf(cargs[1]), e);
						coerce(v, tyOf(cargs[1]), tyOf(e));
					case "set":
						var v = ELocal(asLocal(xs[2], tyOf(cargs[2])));
						cStore(ELocal(asLocal(at(xs[1], tyOf(cargs[1])), TI64)), 0, ct, v, tyOf(cargs[2]), e);
						coerce(v, tyOf(cargs[2]), tyOf(e));
					case "offset": at(xs[1], tyOf(cargs[1]));
					case _: cfail("Ptr." + n + " is not an accessor", e);
				}
			case _:
		}
		if (c.clPath.name == "Callback" && c.clPath.pack.join(".") == "hxmc.unsafe" && cf.cfName == "addr") {
			switch strip(cargs[0]).eexpr {
				case TField(_, FStatic(fc, fcf)) if (Lower.hasMeta(":hxmc.callback", fcf.cfMeta)):
					var cb = l.staticFunc(fc, fcf);
					return ECallHost("hxmc_unsafe_Mem_sym", vector(EStr(l.callbackSym(cb))), TI64);
				case _:
					cfail("Callback.addr: the argument must name a static function declared @:hxmc.callback", e);
			}
		}
		if (c.clPath.name == "Struct" && c.clPath.pack.join(".") == "hxmc.unsafe") {
			var sc = switch strip(cargs[0]).eexpr {
				case TTypeExpr(TClassDecl(sc)) if (CInterop.isStruct(sc)): sc;
				case TLocal(v) if (structAliases.exists(v.vId) && CInterop.isStruct(structAliases.get(v.vId))): structAliases.get(v.vId);
				case _: cfail("Struct." + cf.cfName + ": the argument must be a @:hxmc.struct class", e);
			};
			var lay = CInterop.layout(sc);
			return switch cf.cfName {
				case "sizeOf": EInt(lay.size);
				case "alignOf": EInt(lay.align);
				case "offsetOf":
					var fname = switch strip(cargs[1]).eexpr {
						case TConst(TString(s)): s;
						case _: cfail("Struct.offsetOf: the field name must be a string literal", e);
					};
					EInt(CInterop.field(sc, fname).off);
				case n: cfail("Struct." + n + " is unknown", e);
			}
		}
		return null;
	}

	// ---- spans (hxmc.Span, hxmc.ReadOnlySpan; docs/interop.md, "Spans"): a
	// struct of two words, SpanData's address and number of elements; every
	// access checked (Lower.spanChecks), a range always

	// the direct arguments, making spans (Span.ofBytes & co.), of the call of
	// a kernel being lowered, and what fills those spans once every
	// argument is evaluated: their addresses are taken last, after any GC
	// point (Facts.checkHeapSpans: the callee of a Bytes' enters no region)
	var boundary:Null<{direct:Array<TExpr>, fills:Array<() -> Void>}> = null;

	// whether e makes a span (ofBytes, ofIoBuffer, unsafeOf)
	static function spanMaker(e:TExpr):Bool {
		switch strip(e).eexpr {
			case TCall({eexpr: TField(_, FStatic(c, cf))}, _):
				switch c.clKind {
					case KAbstractImpl(a) if (KernelCheck.isSpanAbstract(a)):
						return cf.cfName == "ofBytes" || cf.cfName == "ofIoBuffer" || cf.cfName == "unsafeOf";
					case _:
				}
			case _:
		}
		return false;
	}

	// (errors) where e is, and the function
	function spanWhere(e:TExpr):String
		return where(e) + " (" + (fi.display != null ? fi.display : fi.name) + ")";

	function spanFail(e:TExpr, what:String, rule:String):Dynamic
		throw new LowerError(KernelCheck.spanError(where(e), fi.display != null ? fi.display : fi.name, what, rule), "");

	// a span type where GC code would hold it: an error
	function spanInGcCode(t:T, e:TExpr, what:String) {
		if (!fi.declKernel && KernelCheck.spanOf(t) != null)
			spanFail(e, what + " has a span type", KernelCheck.SPANS_KERNEL + ": only a @:hxmc.kernel function holds one");
	}

	// a function's parameters and result: no span in GC code
	function spanSignature(tf:TFunc) {
		if (fi.declKernel) return;
		var at:TExpr = {eexpr: TConst(TNull), etype: tf.tfType, epos: tf.tfExpr.epos};
		for (a in tf.tfArgs)
			spanInGcCode(a.variable.vType, ({eexpr: TConst(TNull), etype: a.variable.vType, epos: a.variable.vPos} : TExpr), "the parameter " + a.variable.vName);
		spanInGcCode(tf.tfType, at, "the result");
	}

	// SpanSupport (hxmc.Span's module): what the expansion calls
	function spanSupport(sd:TClass, name:String):FuncInfo {
		for (t in sd.clModule.mTypes)
			switch t {
				case TClassDecl(c) if (c.clPath.name == "SpanSupport"):
					var cf = c.clStatics.get(name);
					if (cf == null) fail("hxmc.SpanSupport." + name + " is missing");
					return l.staticFunc(c, cf);
				case _:
			}
		return fail("hxmc.SpanSupport is missing");
	}

	// Mem's indexed access of a C type (getU8At & co.: a scaled address), or null
	static function indexed(ct:CTy, load:Bool):Null<{n:String, t:Ty}>
		return switch ct {
			case CU8: {n: "U8", t: TI32};
			case CI8 if (!load): {n: "U8", t: TI32};
			case CU16: {n: "U16", t: TI32};
			case CI16 if (!load): {n: "U16", t: TI32};
			case CI32: {n: "I32", t: TI32};
			case CI64 | CPtr: {n: "I64", t: TI64};
			case CF64: {n: "F64", t: TF64};
			case _: null;
		}

	// a call of a span's method or maker (extern: expanded here)
	function spanCall(a:core.TType.TAbstract, cf:TClassField, cargs:Vector<TExpr>, e:TExpr):Ex {
		var sd = structOf(a.aThis);
		if (sd == null) cfail("hxmc." + a.aPath.name + ": its data is no struct", e);
		var sdt = structTy(sd);
		var ptrOff = CInterop.field(sd, "ptr").off, lenOff = CInterop.field(sd, "length").off;
		var name = cf.cfName;
		// (the failed check of an index or a range: the program ends)
		var at = ECallHost("hxmc_unsafe_Mem_cstr", vector(EStr(spanWhere(e))), TI64);
		// (in a loop without an exit: the call does not return, and the path
		// never joins the access again, so nothing lives across the call)
		function fatal(f:String, xs:Array<Ex>):Stmt
			return SLoop(vector(SExpr(ECall(spanSupport(sd, f), Vector.fromArrayCopy(xs.concat([at]))))));
		// a new span: p, n (locals or constants) into a fresh slot
		function make(s:Local, p:Ex, n:Ex) {
			out.push(SExpr(ECallHost("hxmc_unsafe_Mem_setI64", vector(ELocal(s), EInt(ptrOff), p), TVoid)));
			out.push(SExpr(ECallHost("hxmc_unsafe_Mem_setI32", vector(ELocal(s), EInt(lenOff), n), TVoid)));
		}
		inline function loc(x:Ex, t:Ty):Ex
			return isConst(x) ? x : ELocal(asLocal(x, t));
		if (name == "ofBytes" || name == "ofIoBuffer" || name == "unsafeOf") {
			var direct = boundary != null && boundary.direct.indexOf(e) >= 0;
			if (!direct && !fi.declKernel)
				spanFail(e, "a span made outside a call's arguments",
					KernelCheck.SPANS_KERNEL + "; pass " + a.aPath.name + "." + name + "(...) as an argument of a @:hxmc.kernel function");
			var xs = operands(cargs);
			function arg(k:Int, d:Int):Ex
				return k < xs.length && !strip(cargs[k]).eexpr.match(TConst(TNull)) ? loc(coerce(xs[k], tyOf(cargs[k]), TI32), TI32) : EInt(d);
			var s = newSlot(sdt, true);
			var fill:() -> Void;
			switch name {
				case "unsafeOf":
					var p = loc(coerce(xs[0], tyOf(cargs[0]), TI64), TI64), n = arg(1, 0);
					// (a negative length would pass every unsigned check)
					out.push(SIf(EBin(Lt, n, EInt(0)), vector(fatal("badRange", [EInt(0), n, EInt(0)])), vector()));
					fill = () -> make(s, p, n);
				case "ofBytes":
					var b = loc(xs[0], tyOf(cargs[0])), pos = arg(1, 0), len = arg(2, -1);
					var n = loc(ECall(spanSupport(sd, "bytesRange"), vector(b, pos, len)), TI32);
					fill = () -> make(s, loc(ECall(spanSupport(sd, "bytesAddr"), vector(b, pos)), TI64), n);
				case _:
					var buf = loc(coerce(xs[0], tyOf(cargs[0]), TI64), TI64), pos = arg(1, 0), len = arg(2, -1);
					// (GC code throws OutsideBounds; a kernel cannot: it ends the program)
					var n = fi.declKernel ? loc(ECall(spanSupport(sd, "ioRangeFatal"), vector(buf, pos, len, at)),
						TI32) : loc(ECall(spanSupport(sd, "ioRange"), vector(buf, pos, len)), TI32);
					fill = () -> make(s, loc(ECall(spanSupport(sd, "ioAddr"), vector(buf, pos)), TI64), n);
			}
			if (direct) boundary.fills.push(fill) else fill();
			return coerce(ELocal(s), sdt, tyOf(e));
		}
		// (the element type: elem and setElem are called by the inline get and
		// set, whose `this` is SpanData: their own type is the element's)
		var elemT = if (name == "elem" || name == "setElem") e.etype else {
			var sp = KernelCheck.spanOf(cargs[0].etype);
			if (sp == null) cfail("hxmc." + a.aPath.name + "." + name + ": not called on a span", e);
			sp.elem;
		}
		var base = ELocal(asLocal(placeOf(cargs[0]).addr(), TI64));
		var rest = operands(Vector.fromArrayCopy([for (k in 1...cargs.length) cargs[k]]));
		inline function restTy(k:Int):Ty
			return tyOf(cargs[k + 1]);
		var ct = ptrElemCt(elemT, e);
		var size = CInterop.sizeOf(ct);
		var ptr = loc(ECallHost("hxmc_unsafe_Mem_getI64", vector(base, EInt(ptrOff)), TI64), TI64);
		var len = loc(ECallHost("hxmc_unsafe_Mem_getI32", vector(base, EInt(lenOff)), TI32), TI32);
		// p + i * size
		function elem(p:Ex, i:Ex):Ex
			return switch i {
				case EInt(0): p;
				case _: loc(EBin(LAdd, p, EBin(LMul, EConv(I2L, i), EConv(I2L, EInt(size)))), TI64);
			}
		// 0 <= i < n
		function check(i:Ex, n:Ex)
			// (Mem.ult, marked: Opt.condProp drops the checks a loop proves)
			if (Lower.spanChecks) out.push(SIf(ECallHost("hxmc_unsafe_Mem_spanUlt", vector(i, n), TBool), vector(), vector(fatal("outOfRange", [i, n]))));
		// [pos, pos + cnt) inside n (64-bit: no overflow; negative ones fail unsigned)
		function range(pos:Ex, cnt:Ex, n:Ex) {
			var n64 = EConv(I2L, n), p64 = EConv(I2L, pos);
			var bad = vector(fatal("badRange", [pos, cnt, n]));
			out.push(SIf(ECallHost("hxmc_unsafe_Mem_ult", vector(n64, p64), TBool), bad,
				vector(SIf(ECallHost("hxmc_unsafe_Mem_ult", vector(EBin(LSub, n64, p64), EConv(I2L, cnt)), TBool), bad, vector()))));
		}
		function int(k:Int):Ex
			return loc(coerce(rest[k], restTy(k), TI32), TI32);
		return switch name {
			case "elem":
				var i = int(0);
				check(i, len);
				// (the indexed load where there is one: a scaled address)
				var k = indexed(ct, true);
				k != null ? coerce(temp(k.t, ECallHost("hxmc_unsafe_Mem_get" + k.n + "At", vector(ptr, EInt(0), i), k.t)), k.t, tyOf(e)) : cLoad(elem(ptr, i), 0, ct, e);
			case "setElem":
				var i = int(0);
				var v = ELocal(asLocal(rest[1], restTy(1)));
				check(i, len);
				var k = indexed(ct, false);
				if (k != null) out.push(SExpr(ECallHost("hxmc_unsafe_Mem_set" + k.n + "At", vector(ptr, EInt(0), i, coerce(v, restTy(1), k.t)), TVoid))) else
					cStore(elem(ptr, i), 0, ct, v, restTy(1), e);
				coerce(v, restTy(1), tyOf(e));
			case "sub":
				var pos = int(0), cnt = int(1);
				range(pos, cnt, len);
				var s = newSlot(sdt, true);
				make(s, elem(ptr, pos), cnt);
				coerce(ELocal(s), sdt, tyOf(e));
			case "reinterpret":
				var to = KernelCheck.spanOf(e.etype);
				var sizeU = CInterop.sizeOf(ptrElemCt(to.elem, e));
				var n = loc(EConv(L2I, ECallHost("hxmc_unsafe_Mem_udiv", vector(EBin(LMul, EConv(I2L, len), EConv(I2L, EInt(size))), EConv(I2L, EInt(sizeU))), TI64)), TI32);
				var s = newSlot(sdt, true);
				make(s, ptr, n);
				coerce(ELocal(s), sdt, tyOf(e));
			case "toReadOnly":
				var s = newSlot(sdt, true);
				make(s, ptr, len);
				coerce(ELocal(s), sdt, tyOf(e));
			case "blit":
				var pos = int(0), srcpos = int(2), cnt = int(3);
				var src = ELocal(asLocal(rest[1], restTy(1)));
				var sptr = loc(ECallHost("hxmc_unsafe_Mem_getI64", vector(src, EInt(ptrOff)), TI64), TI64);
				var slen = loc(ECallHost("hxmc_unsafe_Mem_getI32", vector(src, EInt(lenOff)), TI32), TI32);
				range(pos, cnt, len);
				range(srcpos, cnt, slen);
				out.push(SExpr(ECall(spanSupport(sd, "move"), vector(elem(ptr, pos), elem(sptr, srcpos), EBin(LMul, EConv(I2L, cnt), EConv(I2L, EInt(size)))))));
				EInt(0);
			case "fill":
				var pos = int(0), cnt = int(1);
				var v = ELocal(asLocal(rest[2], restTy(2)));
				range(pos, cnt, len);
				var k = newLocal("k", TI32);
				out.push(SSet(k, EInt(0)));
				var p = elem(ptr, pos);
				out.push(SLoop(block(() -> {
					out.push(SIf(EBin(Lt, ELocal(k), cnt), vector(), vector(SBreak)));
					cStore(loc(EBin(LAdd, p, EBin(LMul, EConv(I2L, ELocal(k)), EConv(I2L, EInt(size)))), TI64), 0, ct, v, restTy(2), e);
					out.push(SSet(k, EBin(Add, ELocal(k), EInt(1))));
				})));
				EInt(0);
			case "load" | "store" | "compareExchange":
				// (Atomic's 32- and 64-bit operations: integer elements only)
				var w = switch ct {
					case CI32: 32;
					case CI64: 64;
					case _: cfail("hxmc." + a.aPath.name + "." + name + ": atomic accesses are of Int, UInt and Int64 elements, not "
						+ core.TPrinting.sTypes(vector(elemT)), e);
				}
				var t = w == 32 ? TI32 : TI64;
				var i = int(0);
				check(i, len);
				var p = elem(ptr, i);
				switch name {
					case "load":
						coerce(temp(t, ECallHost("hxmc_unsafe_Atomic_load" + w, vector(p), t)), t, tyOf(e));
					case "store":
						out.push(SExpr(ECallHost("hxmc_unsafe_Atomic_store" + w, vector(p, coerce(rest[1], restTy(1), t)), TVoid)));
						EInt(0);
					case _:
						var expected = loc(coerce(rest[1], restTy(1), t), t), replacement = loc(coerce(rest[2], restTy(2), t), t);
						coerce(temp(t, ECallHost("hxmc_unsafe_Atomic_cas" + w, vector(p, expected, replacement), t)), t, tyOf(e));
				}
			case _:
				cfail("hxmc." + a.aPath.name + "." + name + " is not a span accessor", e);
		}
	}

	// a call of a C function declared by an extern (CInterop.declare): the
	// arguments converted to their C types' representations; MirBuild applies
	// the ABI (narrow and float32 values) and the safe region
	function cCall(sym:String, c:TClass, cf:TClassField, s:core.TType.TSignature, cargs:Vector<TExpr>, e:TExpr):Ex {
		var sig = try l.cExtern(sym, c, cf) catch (err:LowerError) {
			if (err.where == "") err.where = where(e);
			throw err;
		};
		var t = ty(s.ret);
		var ats = s.args.map(a -> ty(a.type));
		var xs = args(cargs, ats, null);
		// @:hxmc.blocking: the call in a safe region entered here
		if (CInterop.blockingCall(c, cf) && !fi.declBlocking && Lower.targetOs != 3)
			return inRegion(xs, ats, xs -> ECallHost(sym, xs, t), t, tyOf(e));
		if (t.match(TStruct(_))) {
			// (the result's slot in this frame, MirBuild.cStructRet)
			var lo = newLocal("cr", t);
			out.push(SSet(lo, ECallHost(sym, xs, t)));
			freshSlots.set(lo, true);
			return coerce(ELocal(lo), t, tyOf(e));
		}
		return coerceRhs(ECallHost(sym, xs, t), t, tyOf(e));
	}

	// ---- ids held by Haxe storage (ObjC): a field or a static holds a
	// reference to its id (nil: none), as an ARC strong variable

	function objcRetain(x:Ex) {
		var retain = ObjC.runtime("objc_retain", [CPtr], CPtr);
		out.push(SExpr(ECallHost(retain, vector(x), TI64)));
	}

	// x (a +1 id) given to the autorelease pool
	function objcAutorelease(x:Ex):Ex {
		var autorelease = ObjC.runtime("objc_autorelease", [CPtr], CPtr);
		return temp(TId, ECallHost(autorelease, vector(x), TId));
	}

	function objcRelease(x:Ex) {
		var release = ObjC.runtime("objc_release", [CPtr], CVoid);
		out.push(SExpr(ECallHost(release, vector(x), TVoid)));
	}

	// a constructor: its own id fields entered in the runtime's table, which
	// releases what they hold once the object dies (hxmc.rt.Gc.own)
	function objcOwnFields() {
		if (self == null || self.idFields.length == 0) return;
		var release = ObjC.symbol("objc_release");
		var base = temp(TI64, ECallHost("hxmc_unsafe_Mem_addr", vector(ECast(TRef(RAny), ELocal(thisLocal))), TI64));
		for (n in self.idFields) {
			var at = EFieldAddr(self, self.fieldIndex(n), ELocal(thisLocal));
			var off = EConv(L2I, EBin(LSub, at, base));
			out.push(SExpr(ECallHost("rt_objc_own", vector(ECast(TRef(RAny), ELocal(thisLocal)), off, ECallHost("hxmc_unsafe_Mem_sym", vector(EStr(release)), TI64)), TVoid)));
		}
	}

	// `super.f(args)` in a method of a class extending an Objective-C one
	// (sup): objc_msgSendSuper, its receiver a struct objc_super in this
	// frame (the object's id and the class the method is looked up from:
	// sup, the registered class's superclass); a property's set_x as
	// objcSend has it
	function objcSendSuper(sup:TClass, c:TClass, cf:TClassField, cargs:Vector<TExpr>, e:TExpr):Ex {
		var s = objcSig(cf, e);
		var ats = s.args.map(a -> ty(a.type));
		var xs = args(cargs, ats, null);
		var id = ELocal(asLocal(coerce(ELocal(thisLocal), TRef(RObj(self)), TId), TId));
		var receiver = temp(TI64, ECallHost("hxmc_unsafe_Mem_structSlot", vector(EInt(16), EInt(8)), TI64));
		out.push(SExpr(ECallHost("hxmc_unsafe_Mem_setI64", vector(receiver, EInt(0), id), TVoid)));
		// (a Haxe superclass: its registered class, from its cell)
		var superClass = ObjC.isObjC(sup) ? objcClass(sup)
			: objcCellClass(ECallHost("hxmc_unsafe_Mem_sym", vector(EStr(ObjC.CLASS_CELL + l.classInfo(sup).objc.name)), TI64));
		out.push(SExpr(ECallHost("hxmc_unsafe_Mem_setI64", vector(receiver, EInt(8), superClass), TVoid)));
		var types = [for (a in s.args) a.type];
		if (xs.length == 1 && ObjC.isSetter(c, cf)) {
			var v = ELocal(asLocal(xs[0], ats[0]));
			out.push(SExpr(objcMsg(receiver, ObjC.selector(cf, s), types, [v], null, cf, e, TVoid, false, "objc_msgSendSuper")));
			return coerce(v, ats[0], tyOf(e));
		}
		return objcMsg(receiver, ObjC.selector(cf, s), types, xs.toArray(), s.ret, cf, e, null, false, "objc_msgSendSuper");
	}

	// a message to obj (an instance method of an Objective-C class) or to the
	// class (a static one, obj null)
	function objcSend(obj:Null<TExpr>, c:TClass, cf:TClassField, cargs:Vector<TExpr>, e:TExpr):Ex {
		var s = objcSig(cf, e);
		var ats = s.args.map(a -> ty(a.type));
		var xs = obj != null ? args(VectorTools.cons(obj, cargs), VectorTools.cons(tyOf(obj), ats), null) : args(cargs, ats, null);
		var self = obj != null ? coerce(xs[0], tyOf(obj), TId) : objcClass(c);
		var rest = [for (i in (obj != null ? 1 : 0)...xs.length) xs[i]];
		if (rest.length == 1 && ObjC.isSetter(c, cf)) {
			// (a property's set_x: the message returns nothing, the call the value)
			var v = ELocal(asLocal(rest[0], ats[0]));
			out.push(SExpr(objcMsg(self, ObjC.selector(cf, s), [for (a in s.args) a.type], [v], null, cf, e, TVoid)));
			return coerce(v, ats[0], tyOf(e));
		}
		return objcMsg(self, ObjC.selector(cf, s), [for (a in s.args) a.type], rest, s.ret, cf, e);
	}

	// a property of an Objective-C object (obj) or class (null) read: its getter
	function objcGet(obj:Null<TExpr>, c:TClass, cf:TClassField, e:TExpr):Ex {
		var self = obj != null ? coerce(value(obj), tyOf(obj), TId) : objcClass(c);
		return objcMsg(self, ObjC.getter(cf), [], [], cf.cfType, cf, e);
	}

	// the property's setter sent the value x (of type t)
	function objcSet(self:Ex, c:TClass, cf:TClassField, x:Ex, t:Ty, e:TExpr) {
		var v = coerce(x, t, ty(cf.cfType));
		out.push(SExpr(objcMsg(self, ObjC.setter(cf), [cf.cfType], [v], null, cf, e, TVoid)));
	}

	// `super.initX(args)` in the constructor of a class extending an
	// Objective-C one (sup), as `self = [super initX:args]`: the Objective-C
	// object, [[C alloc] initX:args] of the instance's own class C (the
	// most derived: its cell, CELL_FIELD; registered on first use), kept in
	// the hidden field (the +1 alloc and init give it), and entered in the
	// runtime's peers, the instance variable the entry's index; init (the
	// declaration of NSObject's, or plain) where the constructor calls none
	// (objcConstructor). Its value is the id.
	function objcSuperInit(sup:TClass, init:Null<TClassField>, cargs:Vector<TExpr>, e:TExpr):Ex {
		var s = init != null ? objcSig(init, e) : null;
		var xs = s != null ? args(cargs, Vector.fromArrayCopy([for (a in s.args) ty(a.type)]), null) : vector();
		var cell = temp(TI64, EField(self, self.fieldIndex(ObjC.CELL_FIELD), ELocal(thisLocal)));
		var cls = objcCellClass(cell);
		var idType = TInst(sup, vector());
		var alloc = ELocal(asLocal(objcMsg(cls, "alloc", [], [], idType, init, e, TI64), TI64));
		var sel = init != null ? ObjC.selector(init, s) : "init";
		var id = asLocal(objcMsg(alloc, sel, s != null ? [for (a in s.args) a.type] : [], xs.toArray(), idType, init, e, TId, true), TId);
		out.push(SSetField(self, self.fieldIndex(ObjC.ID_FIELD), ELocal(thisLocal), ELocal(id)));
		var retainCount = ObjC.symbol("_objc_rootRetainCount");
		var release = ObjC.symbol("objc_release");
		var index = asLocal(ECallHost("rt_objc_peer_add", vector(ECast(TRef(RAny), ELocal(thisLocal)), ELocal(id),
			ECallHost("hxmc_unsafe_Mem_sym", vector(EStr(retainCount)), TI64), ECallHost("hxmc_unsafe_Mem_sym", vector(EStr(release)), TI64)), TI32), TI32);
		var off = ECallHost("hxmc_unsafe_Mem_getI64", vector(ECallHost("hxmc_unsafe_Mem_sym", vector(EStr(ObjC.IVAR_CELL + self.objc.root)), TI64), EInt(0)), TI64);
		out.push(SExpr(ECallHost("hxmc_unsafe_Mem_setI32", vector(EBin(LAdd, ELocal(id), off), EInt(0), ELocal(index)), TVoid)));
		return ELocal(id);
	}

	// the class of a class cell (at the address cell), registered first when
	// it is not yet (by the function the cell's second word holds)
	function objcCellClass(cell:Ex):Ex {
		var cls = newLocal("cls", TI64);
		out.push(SSet(cls, ECallHost("hxmc_unsafe_Mem_getI64", vector(cell, EInt(0)), TI64)));
		out.push(SIf(EBin(LEq, ELocal(cls), EConv(I2L, EInt(0))), vector(
			SExpr(ECallHost("hxmc_unsafe_Mem_call0", vector(ECallHost("hxmc_unsafe_Mem_getI64", vector(cell, EInt(8)), TI64)), TVoid)),
			SSet(cls, ECallHost("hxmc_unsafe_Mem_getI64", vector(cell, EInt(0)), TI64))
		), vector()));
		return ELocal(cls);
	}

	// a constructor of such a class: the instance's own class noted (the first
	// constructor to run is the most derived class's); and in the first such
	// class's, plain init first when it calls no super.init...
	function objcConstructor(tf:TFunc) {
		if (self == null || self.objc == null) return;
		var cellField = self.fieldIndex(ObjC.CELL_FIELD);
		var own = ECallHost("hxmc_unsafe_Mem_sym", vector(EStr(ObjC.CLASS_CELL + self.objc.name)), TI64);
		out.push(SIf(EBin(LEq, EField(self, cellField, ELocal(thisLocal)), EConv(I2L, EInt(0))),
			vector(SSetField(self, cellField, ELocal(thisLocal), own)), vector()));
		var sup = l.superOf(self);
		if (!ObjC.isObjC(sup)) return;
		var called = false;
		function scan(e:TExpr)
			switch e.eexpr {
				case TCall({eexpr: TField({eexpr: TConst(TSuper)}, FInstance(c, _, cf))}, _) if (ObjC.isObjC(c) && ObjC.isInit(cf)):
					called = true;
				case _:
					core.Texpr.iter(scan, e);
			}
		scan(tf.tfExpr);
		if (!called) objcSuperInit(sup, null, vector(), tf.tfExpr);
	}

	// the body of this class's registering function (ObjC.REGISTER, its cell's
	// second word): unless registered, its superclass (parent: the Objective-C
	// class, or the Haxe class registered first), the instance variable (the
	// first such class's only: the others inherit it), its methods (their
	// entries, ObjC.imps), and its class and the variable's offset in their cells
	public function objcRegisterBody(parent:TClass) {
		inline function cstr(s:String):Ex
			return ECallHost("hxmc_unsafe_Mem_cstr", vector(EStr(s)), TI64);
		inline function sym(s:String):Ex
			return ECallHost("hxmc_unsafe_Mem_sym", vector(EStr(s)), TI64);
		var name = self.objc.name;
		var allocate = ObjC.runtime("objc_allocateClassPair", [CPtr, CPtr, CI64], CPtr);
		var addIvar = ObjC.runtime("class_addIvar", [CPtr, CPtr, CI64, CU8, CPtr], CBool);
		var addMethod = ObjC.runtime("class_addMethod", [CPtr, CPtr, CPtr, CPtr], CBool);
		var register = ObjC.runtime("objc_registerClassPair", [CPtr], CVoid);
		var getIvar = ObjC.runtime("class_getInstanceVariable", [CPtr, CPtr], CPtr);
		var ivarOffset = ObjC.runtime("ivar_getOffset", [CPtr], CI64);
		var done = block(() -> {
			var root = name == self.objc.root;
			var superClass = root ? objcClass(parent) : objcCellClass(sym(ObjC.CLASS_CELL + l.classInfo(parent).objc.name));
			var cls = asLocal(ECallHost(allocate, vector(superClass, cstr(name), EConv(I2L, EInt(0))), TI64), TI64);
			if (root) out.push(SExpr(ECallHost(addIvar, vector(ELocal(cls), cstr(ObjC.PEER_IVAR), EConv(I2L, EInt(4)), EInt(2), cstr("i")), TBool)));
			for (m in self.objc.methods) {
				var selRef = temp(TI64, sym(ObjC.selRef(m.sel)));
				var sel = temp(TI64, ECallHost("hxmc_unsafe_Mem_getI64", vector(selRef, EInt(0)), TI64));
				out.push(SExpr(ECallHost(addMethod, vector(ELocal(cls), sel, sym(m.sym), cstr(m.types)), TBool)));
			}
			out.push(SExpr(ECallHost(register, vector(ELocal(cls)), TVoid)));
			if (root) {
				var off = temp(TI64, ECallHost(ivarOffset, vector(ECallHost(getIvar, vector(ELocal(cls), cstr(ObjC.PEER_IVAR)), TI64)), TI64));
				out.push(SExpr(ECallHost("hxmc_unsafe_Mem_setI64", vector(sym(ObjC.IVAR_CELL + name), EInt(0), off), TVoid)));
			}
			out.push(SExpr(ECallHost("hxmc_unsafe_Mem_setI64", vector(sym(ObjC.CLASS_CELL + name), EInt(0), ELocal(cls)), TVoid)));
		});
		var current = ECallHost("hxmc_unsafe_Mem_getI64", vector(sym(ObjC.CLASS_CELL + name), EInt(0)), TI64);
		out.push(SIf(EBin(LEq, current, EConv(I2L, EInt(0))), done, vector()));
		out.push(SReturn(null));
	}

	function objcSig(cf:TClassField, e:TExpr):core.TType.TSignature
		return switch TFunctions.follow(cf.cfType) {
			case TFun(s): s;
			case _: fail("Objective-C method " + cf.cfName + " is not a function", e);
		};

	// the class object: its classref (ObjC.classRef), or looked up by name
	function objcClass(c:TClass):Ex {
		var classRef = ObjC.classRef(c);
		if (classRef != null) {
			var ref = temp(TI64, ECallHost("hxmc_unsafe_Mem_sym", vector(EStr(classRef)), TI64));
			return temp(TI64, ECallHost("hxmc_unsafe_Mem_getI64", vector(ref, EInt(0)), TI64));
		}
		var getClass = ObjC.runtime("objc_getClass", [CPtr], CPtr);
		return temp(TI64, ECallHost(getClass, vector(ECallHost("hxmc_unsafe_Mem_cstr", vector(EStr(ObjC.className(c))), TI64)), TI64));
	}

	// objc_msgSend(self, sel, xs...) called through its address in the C
	// types of the arguments (types) and the result (ret) (ObjC.declare); the
	// selector from its selref (DataGen.objcRefs)
	function objcMsg(self:Ex, sel:String, types:Array<core.TType.T>, xs:Array<Ex>, ret:Null<core.TType.T>, cf:Null<TClassField>, e:TExpr, ?to:Ty, keep = false,
			send = "objc_msgSend"):Ex {
		if (to == null) to = tyOf(e);
		if (cf != null) {
			var lib = ObjC.memberLibrary(cf);
			if (lib != null) CInterop.LOADS.set(lib, true);
		}
		var key = try ObjC.declare(cf, types, ret) catch (err:LowerError) {
			if (err.where == "") err.where = where(e);
			throw err;
		};
		var t = ret == null ? TVoid : ty(ret);
		var selRef = temp(TI64, ECallHost("hxmc_unsafe_Mem_sym", vector(EStr(ObjC.selRef(sel))), TI64));
		var selector = temp(TI64, ECallHost("hxmc_unsafe_Mem_getI64", vector(selRef, EInt(0)), TI64));
		var fn = temp(TI64, ECallHost("hxmc_unsafe_Mem_sym", vector(EStr(ObjC.symbol(send))), TI64));
		var cx = ECallHost(key, Vector.fromArrayCopy([fn, self, selector].concat(xs)), t);
		if (t == TId && !keep && ObjC.returnsRetained(sel))
			cx = objcAutorelease(cx);
		if (t.match(TStruct(_))) {
			// (the result's slot in this frame, MirBuild.cStructRet)
			var lo = newLocal("cr", t);
			out.push(SSet(lo, cx));
			freshSlots.set(lo, true);
			return coerce(ELocal(lo), t, to);
		}
		return coerceRhs(cx, t, to);
	}

	// a call made by `call` of the operands xs (of types ats) in a safe
	// region (@:hxmc.blocking): the operands evaluated before it (a GC point
	// among them would run in the region), then rt_blocking_enter, the call,
	// its result kept in a local, and rt_blocking_restore with what enter
	// returned (inside another region it stays: regions nest). No safe
	// region on WebAssembly, which has one thread (the callers' test).
	function inRegion(xs:Vector<Ex>, ats:Vector<Ty>, call:Vector<Ex>->Ex, t:Ty, to:Ty):Ex {
		xs = Vector.fromArrayCopy([
			for (i in 0...xs.length)
				isConst(xs[i]) || xs[i].match(ELocal(_)) || ats[i].match(TStruct(_)) ? xs[i] : ELocal(asLocal(xs[i], ats[i]))
		]);
		var region = newLocal("region", TI32);
		out.push(SSet(region, ECallHost("rt_blocking_enter", vector(), TI32)));
		var lo = t == TVoid ? null : newLocal("cr", t);
		out.push(lo == null ? SExpr(call(xs)) : SSet(lo, call(xs)));
		if (lo != null && t.match(TStruct(_))) freshSlots.set(lo, true);
		out.push(SExpr(ECallHost("rt_blocking_restore", vector(ELocal(region)), TVoid)));
		return lo == null ? EInt(0) : coerce(ELocal(lo), t, to);
	}

	// a field of a @:hxmc.struct object (an address): a load
	function structGet(obj:TExpr, c:TClass, cf:TClassField, e:TExpr):Ex {
		var f = CInterop.field(c, cf.cfName);
		var p = placeOf(obj);
		switch f.ty {
			case CStruct(sc) if (p.heap):
				// (a struct in an object: copied out)
				var s = newSlot(structTy(sc), true);
				copyStruct(ELocal(s), EBin(LAdd, p.addr(), EConv(I2L, EInt(f.off))), sc);
				return coerce(ELocal(s), structTy(sc), tyOf(e));
			case _:
		}
		var a = p.addr();
		return cLoad(a.match(ELocal(_)) ? a : ELocal(asLocal(a, TI64)), f.off, f.ty, e);
	}

	// ---- struct values (docs/interop.md, "Struct values"): the address
	// of their memory, which assignments, arguments and results copy

	static function isLocal(x:Ex, lo:Local):Bool
		return switch x {
			case ELocal(l): l == lo;
			case _: false;
		}

	inline function structOf(t:core.TType.T):Null<TClass>
		return l.structOf(t);

	static function structTy(c:TClass):Ty
		return TStruct(core.Globals.sTypePath(c.clPath), CInterop.layout(c).size);

	function structFail(msg:String):Dynamic
		throw new LowerError(msg, curExpr != null ? where(curExpr) : "");

	// a slot of this frame for a struct of type t, its address in a local
	// (fresh: a temporary, which its user may keep)
	function newSlot(t:Ty, fresh:Bool):Local {
		var size = switch t {
			case TStruct(_, n): n;
			case _: 8;
		};
		var lo = newLocal("st", t);
		out.push(SSet(lo, ECallHost("hxmc_unsafe_Mem_structSlot", vector(EInt(size), EInt(8)), TI64)));
		if (fresh) freshSlots.set(lo, true);
		return lo;
	}

	// the loads and stores that copy a C scalar's bytes
	static function rawAccess(ct:CTy):{get:String, set:String, t:Ty}
		return switch ct {
			case CBool | CI8 | CU8: {get: "getU8", set: "setI8", t: TI32};
			case CI16 | CU16: {get: "getU16", set: "setI16", t: TI32};
			case CI32 | CF32: {get: "getI32", set: "setI32", t: TI32};
			case CF64: {get: "getF64", set: "setF64", t: TF64};
			case _: {get: "getI64", set: "setI64", t: TI64};
		}

	// the struct at src copied to dst, scalar by scalar (dst and src: pure)
	function copyStruct(dst:Ex, src:Ex, c:TClass) {
		for (f in CInterop.scalars(c, 0)) {
			var a = rawAccess(f.ty);
			var v = ECallHost("hxmc_unsafe_Mem_" + a.get, vector(src, EInt(f.off)), a.t);
			out.push(SExpr(ECallHost("hxmc_unsafe_Mem_" + a.set, vector(dst, EInt(f.off), v), TVoid)));
		}
	}

	function zeroStruct(dst:Ex, c:TClass) {
		for (f in CInterop.scalars(c, 0)) {
			var a = rawAccess(f.ty);
			out.push(SExpr(ECallHost("hxmc_unsafe_Mem_" + a.set, vector(dst, EInt(f.off), nullOf(a.t)), TVoid)));
		}
	}

	// a struct value: its address, which stays valid while this function runs
	// (an object's struct field is copied out); fresh: a temporary of this
	// frame that nothing else holds
	function structRhs(e:TExpr):{x:Ex, fresh:Bool} {
		var x = rhs(e);
		return {x: x, fresh: switch x {
			case ELocal(lo): freshSlots.exists(lo);
			case _: false;
		}};
	}

	// a struct value in memory of its own: the temporary itself, or a copy
	function structOwn(e:TExpr, c:TClass):Local {
		var r = structRhs(e);
		switch r.x {
			case ELocal(lo) if (r.fresh):
				freshSlots.remove(lo);
				return lo;
			case _:
		}
		var src = r.x.match(ELocal(_) | EGlobal(_, _)) ? r.x : ELocal(asLocal(r.x, structTy(c)));
		var s = newSlot(structTy(c), false);
		copyStruct(ELocal(s), src, c);
		return s;
	}

	// struct values copied out of a box: assigning their fields would change
	// the copy only (FnLower.placeOf)
	var unboxed = new Map<Local, Bool>();

	// where the struct e is, without a copy: its address, built when the
	// caller asks (after what it evaluates next: an object moves at a GC
	// point); heap: in an object
	// (write: for an assignment, which a copy out of a box cannot take)
	function placeOf(e:TExpr, write = false):{addr:() -> Ex, heap:Bool} {
		switch strip(e).eexpr {
			case TField(obj, FInstance(c, _, cf)) if (CInterop.isStruct(c)):
				var base = placeOf(obj, write);
				var off = CInterop.field(c, cf.cfName).off;
				return {addr: () -> off == 0 ? base.addr() : EBin(LAdd, base.addr(), EConv(I2L, EInt(off))), heap: base.heap};
			case TField(obj, FInstance(c, _, cf)) if (!c.hasClassFlag(CExtern) && !c.hasClassFlag(CInterface) && cf.cfKind.match(Var(_)) && structOf(cf.cfType) != null):
				var ci = l.classInfo(c);
				var idx = ci.fieldIndex(cf.cfName);
				var o = asLocal(value(obj), tyOf(obj));
				return {addr: () -> EFieldAddr(ci, idx, ELocal(o)), heap: true};
			case TCall({eexpr: TField(_, FStatic(c, cf))}, _) if (write && cf.cfName == "elem" && c.clKind.match(KAbstractImpl({aPath: {pack: ["hxmc"], name: "ReadOnlySpan"}}))):
				return spanFail(e, "a write through a read-only span", "a ReadOnlySpan cannot be written through");
			case _:
				var x = rhs(e);
				var lo = switch x {
					case ELocal(lo): lo;
					case _: asLocal(x, tyOf(e));
				};
				if (write && unboxed.exists(lo)) cfail('this struct value is a copy (of an Array element, a Dynamic or a Null<T> value): assigning its fields would change the copy only (copy it into a variable, change that, store it back)', e);
				return {addr: () -> ELocal(lo), heap: false};
		}
	}

	// lhs = r for a struct: its bytes copied; the value is the copy's source
	function structAssign(lhs:TExpr, r:TExpr, c:TClass, e:TExpr):Ex {
		switch strip(lhs).eexpr {
			case TLocal(v) if (isBoxed(v)):
				return cfail('the struct local ' + v.vName + ' is captured by a closure and assigned: not supported (a class instead)', e);
			case TLocal(v):
				var lo = local(v, lhs);
				var src = structRhs(r).x;
				if (!src.match(ELocal(_) | EGlobal(_, _))) src = ELocal(asLocal(src, tyOf(r)));
				if (!isLocal(src, lo)) copyStruct(ELocal(lo), src, c);
				return coerce(ELocal(lo), structTy(c), tyOf(e));
			case TField(_, FStatic(k, cf)) if (!k.hasClassFlag(CExtern)):
				var g = l.staticVar(k, cf);
				var t = l.globalTy(g);
				var src = structRhs(r).x;
				if (!src.match(ELocal(_) | EGlobal(_, _))) src = ELocal(asLocal(src, tyOf(r)));
				copyStruct(EGlobal(g, t), src, c);
				return coerce(EGlobal(g, t), t, tyOf(e));
			case TField(_, FInstance(k, _, _)) if (!k.hasClassFlag(CInterface) && !k.hasClassFlag(CExtern)):
				var p = placeOf(lhs, true);
				var src = ELocal(asLocal(structRhs(r).x, tyOf(r)));
				copyStruct(p.addr(), src, c);
				return coerce(src, structTy(c), tyOf(e));
			case _:
				// (an Array's element, a structural type's field: a new box)
				return assign(lhs, () -> {x: rhs(r), t: tyOf(r)}, e);
		}
	}

	// a == b for structs: every scalar equal (floats as floats: NaN differs from itself)
	function structEq(a:TExpr, b:TExpr, c:TClass, e:TExpr):Ex {
		var pa = placeOf(a);
		var pb = placeOf(b);
		var r:Null<Ex> = null;
		for (f in CInterop.scalars(c, 0)) {
			var x:Ex;
			switch f.ty {
				case CF64 | CF32:
					var n = f.ty == CF64 ? "getF64" : "getF32";
					x = EBin(FEq, temp(TF64, ECallHost("hxmc_unsafe_Mem_" + n, vector(pa.addr(), EInt(f.off)), TF64)),
						temp(TF64, ECallHost("hxmc_unsafe_Mem_" + n, vector(pb.addr(), EInt(f.off)), TF64)));
				case _:
					var acc = rawAccess(f.ty);
					var ga = temp(acc.t, ECallHost("hxmc_unsafe_Mem_" + acc.get, vector(pa.addr(), EInt(f.off)), acc.t));
					var gb = temp(acc.t, ECallHost("hxmc_unsafe_Mem_" + acc.get, vector(pb.addr(), EInt(f.off)), acc.t));
					x = EBin(acc.t == TI64 ? LEq : Eq, ga, gb);
			}
			r = r == null ? x : EBin(And, r, x);
		}
		return r == null ? EInt(1) : temp(TBool, r);
	}

	// new S(args) for a @:hxmc.struct class: its memory (a fresh slot, or
	// into) zeroed, then the constructor called on it
	function newStruct(c:TClass, cargs:Vector<TExpr>, into:Null<Local>):Local {
		var t = structTy(c);
		var s = into != null ? into : newSlot(t, true);
		if (c.clConstructor == null) {
			zeroStruct(ELocal(s), c);
			return s;
		}
		var ctor = l.structCtor(c);
		var xs = args(cargs, tys(ctor), defaultValues(ctor), 1, ctor);
		zeroStruct(ELocal(s), c);
		out.push(SExpr(ECall(ctor, VectorTools.cons(ELocal(s), xs))));
		return s;
	}

	// the argument types a call passes to f (without its result's address)
	static function callTys(f:FuncInfo):Vector<Ty> {
		var n = f.sret ? f.args.length - 1 : f.args.length;
		var t = new Vector<Ty>(n);
		for (k in 0...n)
			t[k] = f.args[k].ty;
		return t;
	}

	// a call of f; a struct result lands in a slot of this frame
	function callFn(f:FuncInfo, xs:Vector<Ex>, rt:Ty):Ex {
		if (!f.sret) return coerceRhs(ECall(f, xs), f.ret, rt);
		var s = newSlot(f.ret, true);
		out.push(SExpr(ECall(f, xs.snoc(ELocal(s)))));
		return coerce(ELocal(s), f.ret, rt);
	}

	static function hasStruct(s:SigInfo):Bool {
		for (t in s.args)
			if (t.match(TStruct(_))) return true;
		return s.ret.match(TStruct(_));
	}

	// a call of a closure; a struct result lands in a slot of this frame
	function callClos(s:SigInfo, c:Ex, xs:Vector<Ex>, rt:Ty):Ex {
		if (!s.ret.match(TStruct(_))) return coerceRhs(ECallClos(s, c, xs), s.ret, rt);
		var r = newSlot(s.ret, true);
		out.push(SExpr(ECallClos(s, c, xs.snoc(ELocal(r)))));
		return coerce(ELocal(r), s.ret, rt);
	}

	// a struct value in a new box (its copy)
	function box(x:Ex, n:String):Ex {
		var ci = l.structBox(n);
		var c = l.structClass(n);
		var src = x.match(ELocal(_) | EGlobal(_, _)) ? x : ELocal(asLocal(x, structTy(c)));
		var b = temp(TRef(RObj(ci)), ENewObj(ci));
		copyStruct(EFieldAddr(ci, 0, b), src, c);
		return b;
	}

	// the value a box holds, copied out (null: zeros); a reference that is
	// not one fails as a cast does
	function unbox(x:Ex, from:Ty, n:String):Ex {
		var ci = l.structBox(n);
		var c = l.structClass(n);
		var t = TRef(RObj(ci));
		var b = switch from {
			case TRef(RObj(k)) if (k == ci): asLocal(x, from);
			case _: asLocal(temp(TRef(RAny), ECallHost(l.native("hx_cast"), vector(coerce(x, from, TRef(RAny)), EType(TRClass(ci))), TRef(RAny))), TRef(RAny));
		};
		var s = newSlot(structTy(c), true);
		unboxed.set(s, true);
		out.push(SIf(EBin(RefEq, ELocal(b), ENull(b.ty)), block(() -> zeroStruct(ELocal(s), c)), block(() -> copyStruct(ELocal(s), EFieldAddr(ci, 0, ECast(t, ELocal(b))), c))));
		return ELocal(s);
	}

	// a field of a structural type (or an interface's variable): a struct's box.
	// A closure is stored with the signature of the value put there, which
	// the field's type at the read may not have (a (Int) -> X in an object
	// passed where a type parameter makes it a (T) -> X, its argument boxed):
	// it is read as Dynamic and kept when its signature is the one wanted,
	// else wrapped in an adapter (coerce)
	// x, an element of an Array or a NativeArray of element type elem, as `to`.
	// An element is stored as it was put there, and the same array is an
	// Array<(Int) -> Bool> where it is filled and an Array<(T) -> Bool> where
	// a generic function or rest argument reads it (the element type is the
	// instantiated one, not erased: Lower.ty), so a closure read may have
	// another signature than the element type's (its argument boxed): read as
	// Dynamic, kept when it has this signature, else adapted (coerce), as
	// anonGet does
	function elemRead(x:Ex, elem:Ty, to:Ty):Ex {
		switch [elem, to] {
			case [TRef(RClos(a)), TRef(RClos(b))] if (!hasStruct(a) && !hasStruct(b)):
				return coerce(temp(TRef(RAny), x), TRef(RAny), to);
			case _:
				return coerce(x, elemValue(elem), to);
		}
	}

	function anonGet(name:String, obj:TExpr, e:TExpr):Ex {
		var t = l.boxed(tyOf(e));
		if (t.match(TRef(RClos(_)))) {
			var x = temp(TRef(RAny), EAnonGet(name, TRef(RAny), value(obj), anonHint(obj.etype, name, TRef(RAny))));
			return coerce(x, TRef(RAny), tyOf(e));
		}
		var x = EAnonGet(name, t, value(obj), anonHint(obj.etype, name, t));
		// (a reference through a temporary; a number or a Bool as it is)
		return Ir.isRef(t) ? coerce(temp(t, x), t, tyOf(e)) : x;
	}

	// ---- closures

	function closure(tf:TFunc, e:TExpr):Ex {
		var free = Boxing.freeVars(tf);
		var caps:Array<{id:Int, ty:Ty}> = [];
		var capVals = [];
		var captureLocals = [];
		for (v in free) {
			if (v == null) {
				if (thisLocal == null) continue;
				if (structCtor) cfail('a closure cannot capture this in the constructor of a struct (its memory is the caller\'s)', e);
				caps.push({id: -1, ty: thisLocal.ty});
				capVals.push(ELocal(thisLocal));
				captureLocals.push(new Local(-1, "this", thisLocal.ty));
				continue;
			}
			var lo = locals.get(v.vId);
			if (lo == null) continue;
			if (lo.ty.match(TStruct(_))) cfail('a closure cannot capture the struct local ' + v.vName + ' (its memory is in this frame: copy the fields into locals)', e);
			caps.push({id: v.vId, ty: lo.ty});
			capVals.push(ELocal(lo));
			captureLocals.push(new Local(v.vId, v.vName, lo.ty));
		}
		var sig = switch tyOf(e) {
			case TRef(RClos(s)): s;
			case _: l.sig([for (a in tf.tfArgs) ty(a.variable.vType)], ty(tf.tfType));
		};
		var outerBoxed = boxed;
		var li = l.newLambda(sig, Vector.fromArrayCopy(captureLocals), fl -> fl.runLambda(tf, copyMap(outerBoxed), caps), Lower.lambdaName(fi), fi.module);
		return ENewClos(li, Vector.fromArrayCopy(capVals));
	}

	static function copyMap(m:Map<Int, Bool>):Map<Int, Bool> {
		var r = new Map();
		for (k in m.keys())
			r.set(k, true);
		return r;
	}
}

// Which locals are captured by a closure and also assigned after their
// declaration: those live in a heap box shared by all closures.
class Boxing {
	public static function analyze(body:TExpr, args:Array<TVar>):Map<Int, Bool> {
		var captured = new Map<Int, Bool>();
		var assigned = new Map<Int, Bool>();
		// (the walk's depth in closures, and the depth each local is declared
		// at: nothing is captured at depth 0)
		var depth = 0;
		var declDepth = new Map<Int, Int>();
		function walk(e:TExpr) {
			switch e.eexpr {
				case TVar(v, init):
					declDepth.set(v.vId, depth);
					if (init != null) walk(init);
				case TLocal(v):
					if (depth > 0) {
						var d = declDepth.get(v.vId);
						if (d != null && d < depth) captured.set(v.vId, true);
					}
				case TBinop(OpAssign | OpAssignOp(_), {eexpr: TLocal(v)}, rhs):
					assigned.set(v.vId, true);
					if (depth > 0) {
						var d = declDepth.get(v.vId);
						if (d != null && d < depth) captured.set(v.vId, true);
					}
					walk(rhs);
				case TUnop(Increment | Decrement, _, {eexpr: TLocal(v)}):
					assigned.set(v.vId, true);
					if (depth > 0) {
						var d = declDepth.get(v.vId);
						if (d != null && d < depth) captured.set(v.vId, true);
					}
				case TFunction(tf):
					for (a in tf.tfArgs)
						declDepth.set(a.variable.vId, depth + 1);
					depth++;
					walk(tf.tfExpr);
					depth--;
				case TTry(b, cs):
					walk(b);
					for (c in cs) {
						declDepth.set(c.variable.vId, depth);
						walk(c.expr);
					}
				case _:
					core.Texpr.iter(walk, e);
			}
		}
		for (a in args)
			declDepth.set(a.vId, 0);
		walk(body);
		var r = new Map<Int, Bool>();
		for (id in captured.keys())
			if (assigned.exists(id)) r.set(id, true);
		return r;
	}

	// free variables of a closure literal; null stands for `this`
	public static function freeVars(tf:TFunc):Array<Null<TVar>> {
		var declared = new Map<Int, Bool>();
		for (a in tf.tfArgs)
			declared.set(a.variable.vId, true);
		var seen = new Map<Int, Bool>();
		var r:Array<Null<TVar>> = [];
		var usesThis = false;
		function walk(e:TExpr) {
			switch e.eexpr {
				case TVar(v, init):
					declared.set(v.vId, true);
					if (init != null) walk(init);
				case TLocal(v):
					if (!declared.exists(v.vId) && !seen.exists(v.vId)) {
						seen.set(v.vId, true);
						r.push(v);
					}
				case TConst(TThis | TSuper):
					usesThis = true;
				case TFunction(tf2):
					for (a in tf2.tfArgs)
						declared.set(a.variable.vId, true);
					walk(tf2.tfExpr);
				case TTry(b, cs):
					walk(b);
					for (c in cs) {
						declared.set(c.variable.vId, true);
						walk(c.expr);
					}
				case _:
					core.Texpr.iter(walk, e);
			}
		}
		walk(tf.tfExpr);
		if (usesThis) r.unshift(null);
		return r;
	}
}
