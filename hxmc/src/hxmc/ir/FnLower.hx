package hxmc.ir;

import hxmc.ir.Ir;
import hxmc.ir.Lower;
import hxmc.ir.CInterop;
import core.Ast.Binop;
import core.Ast.Unop;
import core.Ast.UnopFlag;
import core.Ast.WhileFlag;
import core.TType;
import core.TFunctions;

using core.TFunctions;

// Lowers one function body to IR statements (A-normal form: calls and
// allocations only as the value of an SSet/SExpr). Every lowered expression
// has the representation of its typed-AST type, `ty(e.etype)`; consumers
// convert with `coerce`.
class FnLower {
	var l:Lower;
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
	var out:Array<Stmt>;
	var nextLocal = 0;

	public function new(l, fi, self, lambda) {
		this.l = l;
		this.fi = fi;
		this.self = self;
		this.lambda = lambda;
		nextLocal = fi.args.length + 1;
		out = fi.body;
	}

	// (the expression's file and line, and the function being lowered)
	function fail(msg:String, ?e:TExpr):Dynamic {
		var at = e != null ? where(e) : "";
		throw new LowerError(msg, (at != "" ? at + " in " : "") + fi.name);
	}

	inline function ty(t:T):Ty
		return l.ty(t);

	inline function tyOf(e:TExpr):Ty
		return l.ty(e.etype);

	function newLocal(name:String, t:Ty):Local {
		if (t == TVoid) t = TI32;
		var lo = new Local(nextLocal++, name, t);
		fi.locals.push(lo);
		return lo;
	}

	// ---- entry points

	// a function body; `fi.args` already holds the caller-visible signature
	public function run(tf:TFunc, isCtor = false) {
		if (boxed == null) boxed = Boxing.analyze(tf.tfExpr, tf.tfArgs.map(a -> a.variable));
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
		stmt(tf.tfExpr);
	}

	// the constructor of a @:hxmc.struct class (Lower.structCtor): this is
	// the struct's address
	public function runStructCtor(tf:TFunc) {
		boxed = Boxing.analyze(tf.tfExpr, tf.tfArgs.map(a -> a.variable));
		thisLocal = fi.args[0];
		structCtor = true;
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
				out.push(SIf(EBin(RefEq, ELocal(a), ENull(a.ty)), block(() -> out.push(SSet(a, coerceRhs(rhs(d), tyOf(d), a.ty)))), []));
			var x:Ex = ELocal(a);
			if (Ir.repr(t) != Ir.repr(a.ty) || refConversion(a.ty, t)) {
				var lo = newLocal(v.vName, t);
				out.push(SSet(lo, coerce(x, a.ty, t)));
				x = ELocal(lo);
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
		var inner = Boxing.analyze(tf.tfExpr, tf.tfArgs.map(a -> a.variable));
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
					var t = l.getProgram().globals[g].ty;
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
		var ds = f != null ? l.defaults.get(f) : null;
		var vars = f != null ? l.argVars.get(f) : null;
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
							var y = receiverDefault(dispatch.cls, l.getProgram().selectors[dispatch.sel].name, ELocal(recv), j, d, t, x, args, argTys);
							if (y != null) x = y;
						}
						out.push(SSet(v, x));
					});
					out.push(SIf(EBin(RefEq, ELocal(a), ENull(a.ty)), dflt, [SSet(v, coerce(ELocal(a), a.ty, t))]));
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
		var call = dispatch != null ? ECallDispatch(dispatch.sel, dispatch.sig, args) : ECall(f, args);
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
		var ds = l.defaults.get(f);
		var vars = l.argVars.get(f);
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
				[SSet(v, coerce(ELocal(a), a.ty, t))]));
			args.push(ELocal(v));
			argTys.push(t);
		}
		if (f.ret == TVoid) {
			out.push(SExpr(ECall(f, args)));
			out.push(SReturn(null));
		} else {
			var r = newLocal("r", f.ret);
			out.push(SSet(r, ECall(f, args)));
			out.push(SReturn(ELocal(r)));
		}
	}

	// closure body calling a runtime function
	public function forwardHost(name:String) {
		boxed = new Map();
		var args = [for (i in 1...fi.args.length) (ELocal(fi.args[i]) : Ex)];
		if (lambda.captures.length > 0) {
			var s = newLocal("self", lambda.captures[0].ty);
			out.push(SSet(s, ECapture(lambda, 0, ELocal(fi.args[0]))));
			args.unshift(ELocal(s));
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
		var args = [for (i in 1...fi.args.length) (ELocal(fi.args[i]) : Ex)];
		var r = newLocal("r", fi.ret);
		out.push(SSet(r, ENewEnum(ci, args)));
		out.push(SReturn(ELocal(r)));
	}

	// closure body converting arguments and result between representations
	public function adapt(from:SigInfo) {
		boxed = new Map();
		var inner = newLocal("inner", TRef(RClos(from)));
		out.push(SSet(inner, ECapture(lambda, 0, ELocal(fi.args[0]))));
		var args = [];
		for (i in 0...from.args.length) {
			var a = fi.args[i + 1];
			args.push(coerce(ELocal(a), a.ty, from.args[i]));
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
		var xs = [for (i in 1...fi.args.length) coerce(ELocal(fi.args[i]), fi.args[i].ty, TRef(RAny))];
		var arr = temp(TRef(RArr(TRef(RAny))), ENewArr(TRef(RAny), xs));
		var call = ECallHost(l.native("hx_dyn_call"), [ELocal(inner), arr], TRef(RAny));
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

	function block(f:() -> Void):Array<Stmt> {
		var saved = out;
		out = [];
		f();
		var r = out;
		out = saved;
		return r;
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
		for (n in ["addr", "obj", "sym", "cstr", "abi", "os", "arm", "target", "platform", "ult", "stack", "structSlot", "f64Bits", "bitsF64", "words"])
			"hxmc_unsafe_Mem_" + n => true
	];

	public static inline function isIntrinsic(n:String):Bool
		return StringTools.startsWith(n, "hxmc_unsafe_Mem_") || StringTools.startsWith(n, "hxmc_unsafe_Atomic_");

	// a runtime function call that is not a GC point
	public static function noGcHost(n:String):Bool
		return isPure(n) || NOGC.exists(n) || C_EXTERNS.exists(n) || StringTools.startsWith(n, "hxmc_narray_set_")
			|| (isIntrinsic(n) && n != "hxmc_unsafe_Mem_alloc" && n != "hxmc_unsafe_Mem_allocRaw" && !StringTools.startsWith(n, "hxmc_unsafe_Mem_call"));

	// the layout an object literal of the structural type t gets, when the
	// field `name` has the representation rt there
	function anonHint(t:T, name:String, rt:Ty):Null<ShapeInfo> {
		switch TFunctions.follow(t) {
			case TAnon(an) if (an.aStatus.match(Closed | Const)):
				// (in the order of the names: a map's order follows its insertions,
				// which differ for a type read from HXB, and ty numbers the types it meets)
				var names = l.anonNames(an);
				var fs = [for (k in names) {name: k, ty: l.boxed(ty(an.aFields.get(k).cfType))}];
				var sh = l.getProgram().shape(fs);
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
	function operands(es:Array<TExpr>):Array<Ex> {
		var r = [];
		for (e in es) {
			var before = out.length;
			// (a struct: a copy of its own, made now)
			var sc = structOf(e.etype);
			var x = sc != null ? ELocal(structOwn(e, sc)) : value(e);
			if (out.length != before) {
				var spills = [];
				for (i in 0...r.length)
					if (!isConst(r[i]) && !r[i].match(ELocal(_))) {
						var lo = newLocal("s", tyOf(es[i]));
						spills.push(SSet(lo, r[i]));
						r[i] = ELocal(lo);
					}
				for (j in 0...spills.length)
					out.insert(before + j, spills[j]);
			}
			r.push(x);
		}
		return r;
	}

	// x, lowered before the statements from `before` on (a later operand's
	// effects): read into a local ahead of them unless constant
	function spillBefore(x:Ex, t:Ty, before:Int):Ex {
		if (out.length == before || isConst(x) || x.match(ELocal(_))) return x;
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
	function args(es:Array<TExpr>, to:Array<Ty>, defaults:Null<Array<Null<TExpr>>>, offset = 0, ?callee:FuncInfo, ?recv:() -> Ex):Array<Ex> {
		var xs = operands(es);
		var vars = callee != null ? l.argVars.get(callee) : null;
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
					if (!isConst(r[k]) && !r[k].match(ELocal(_))) {
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
					[SSet(v, coerce(ELocal(x), from, t))]));
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
		return r;
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

	static function tys(f:FuncInfo):Array<Ty>
		return [for (a in f.args) a.ty];

	function asLocal(x:Ex, t:Ty):Local {
		return switch x {
			case ELocal(lo): lo;
			case _:
				var lo = newLocal("a", t);
				out.push(SSet(lo, x));
				lo;
		}
	}

	static function strip(e:TExpr):TExpr
		return switch e.eexpr {
			case TParenthesis(e1) | TMeta(_, e1): strip(e1);
			case TCast(e1, null): strip(e1);
			case _: e;
		}

	function nullOf(t:Ty):Ex
		return switch t {
			case TI32 | TBool: EInt(0);
			case TF64: EF64(0);
			case TI64: EConv(I2L, EInt(0));
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
			// a typed view takes storage of its own kind (rt/NArray.view): from
			// a Dynamic-typed view or a Dynamic, and between the kinds Haxe lets
			// alias (Int and Null<Int>), checked; an open wrapper's storage, converted
			case [_, TRef(RNativeArr(b))] if (nativeConversion(from, to)):
				return temp(to, ECallHost(l.native("hx_narray_view"), [x, EInt(nativeKind(b))], to));
			case [TRef(RClos(a)), TRef(RClos(b))] if (a != b):
				if (x.match(ENull(_))) return ENull(to);
				if (hasStruct(a) || hasStruct(b)) structFail('a function taking or returning a struct value cannot become a function of another type');
				var li = l.adapter(a, b);
				var c = asLocal(x, from);
				var r = newLocal("adapted", to);
				out.push(SIf(EBin(RefEq, ELocal(c), ENull(from)), [SSet(r, ENull(to))], [SSet(r, ENewClos(li, [ELocal(c)]))]));
				return ELocal(r);
			case [TRef(RAny), TRef(RClos(b))]:
				// a Dynamic as a function: kept when it is a closure of this
				// signature, else called through an adapter (its signature may
				// differ: a () -> Bool's result is not boxed)
				if (x.match(ENull(_))) return ENull(to);
				var c = asLocal(x, from);
				var r = newLocal("closure", to), same = newLocal("same", from);
				out.push(SIf(EBin(RefEq, ELocal(c), ENull(from)), [SSet(r, ENull(to))], [
					SSet(same, ECallHost(l.native("hx_clos_of_sig"), [ELocal(c), EStr(b.key)], TRef(RAny))),
					SIf(EBin(RefEq, ELocal(same), ENull(from)), [SSet(r, ENewClos(l.dynAdapter(b), [ELocal(c)]))], [SSet(r, ECast(to, ELocal(same)))])
				]));
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
			case _: 0;
		};

	// a NativeArray whose element is Dynamic (Dynamic, Any, an erased type
	// parameter) may hold any kind of storage, or be a wrapper (rt/NArray)
	static function dynElem(elem:Ty):Bool
		return elem.match(TRef(RAny));

	// element i of NativeArray a (both locals or constants, as they are read
	// again by the test of the index), the access at p: tested as -D
	// hxmc.native-array-outofbounds says (Lower.bounds); no p: not tested (the
	// std's own loops)
	function nativeRead(elem:Ty, a:Ex, i:Ex, ?p:core.Globals.Pos):Ex {
		var get = ECallHost(dynElem(elem) ? "hxmc_narray_dget" : "hxmc_narray_get_" + ["p", "i", "f", "l", "b"][nativeKind(elem)], [a, i], elem);
		switch p == null ? Lower.BOUNDS_UNCHECKED : Lower.bounds {
			case Lower.BOUNDS_SILENT:
				var r = newLocal("e", elem);
				// (seen as Dynamic: the default of the storage's kind)
				var none = dynElem(elem) ? ECallHost(l.native("hx_narray_default"), [a], elem) : nullOf(elem);
				out.push(SIf(inBounds(a, i), [SSet(r, get)], [SSet(r, none)]));
				return ELocal(r);
			case Lower.BOUNDS_THROWS:
				out.push(SIf(inBounds(a, i), [], [SThrow(outOfBounds(a, i, p))]));
			case _:
		}
		return dynElem(elem) ? temp(elem, get) : get;
	}

	// a[i] = x (x: a local or constant), as nativeRead
	function nativeWrite(elem:Ty, a:Ex, i:Ex, x:Ex, ?p:core.Globals.Pos) {
		var set = SExpr(ECallHost(dynElem(elem) ? "hxmc_narray_dset" : "hxmc_narray_set_" + ["p", "i", "f", "l", "b"][nativeKind(elem)], [a, i, x], TVoid));
		out.push(switch p == null ? Lower.BOUNDS_UNCHECKED : Lower.bounds {
			case Lower.BOUNDS_SILENT: SIf(inBounds(a, i), [set], []);
			case Lower.BOUNDS_THROWS: SIf(inBounds(a, i), [set], [SThrow(outOfBounds(a, i, p))]);
			case _: set;
		});
	}

	// (one unsigned comparison: negative indices too; the length of a
	// wrapper is its storage's)
	static function inBounds(a:Ex, i:Ex):Ex
		return ECallHost("hxmc_unsafe_Mem_ult", [i, ECallHost("hxmc_narray_length", [a], TI32)], TBool);

	// the exception, with the position of the access (thrown at once: the
	// call is the throw statement's own)
	function outOfBounds(a:Ex, i:Ex, p:core.Globals.Pos):Ex {
		var d = fi.display != null ? fi.display : fi.name;
		var dot = d.lastIndexOf(".");
		var pos = [EStr(p.pfile), EInt(CInterop.lineOf(p.pfile, p.pmin)), EStr(dot < 0 ? "" : d.substr(0, dot)), EStr(d.substr(dot + 1))];
		return ECallHost(l.native("hx_narray_oob"), [i, ECallHost("hxmc_narray_length", [a], TI32)].concat(pos), TRef(RAny));
	}

	// a value converted to String (for concatenation)
	function toStr(x:Ex, t:Ty):Ex {
		return switch t {
			case TRef(RStr): temp(TRef(RStr), ECallHost(l.native("hx_str_or_null"), [x], TRef(RStr)));
			case TI32: temp(TRef(RStr), ECallHost(l.native("hx_str_of_int"), [x], TRef(RStr)));
			case TF64: temp(TRef(RStr), ECallHost(l.native("hx_str_of_float"), [x], TRef(RStr)));
			case TI64: temp(TRef(RStr), ECallHost(l.native("hx_str_of_i64"), [x], TRef(RStr)));
			case TBool: temp(TRef(RStr), ECallHost(l.native("hx_str_of_bool"), [x], TRef(RStr)));
			case TStruct(_): toStr(coerce(x, t, TRef(RAny)), TRef(RAny));
			case _: temp(TRef(RStr), ECallHost(l.native("hx_std_string"), [x], TRef(RStr)));
		}
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
				for (x in es)
					stmt(x);
			case TParenthesis(e1) | TMeta(_, e1):
				stmt(e1);
			case TVar(v, init):
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
				} else out.push(SIf(cx, block(() -> stmt(a)), b != null ? block(() -> stmt(b)) : []));
			case TWhile(c, body, NormalWhile):
				out.push(SLoop(block(() -> {
					var cx = cond(c);
					out.push(SIf(ENot(cx), [SBreak], []));
					stmt(body);
				})));
			case TWhile(c, body, DoWhile):
				// first iteration skips the test, so `continue` reaches it
				var first = newLocal("first", TBool);
				out.push(SSet(first, EInt(1)));
				out.push(SLoop(block(() -> {
					out.push(SIf(ENot(ELocal(first)), block(() -> {
						var cx = cond(c);
						out.push(SIf(ENot(cx), [SBreak], []));
					}), []));
					out.push(SSet(first, EInt(0)));
					stmt(body);
				})));
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
				if (base != null) v = temp(TRef(RAny), ECall(l.staticFunc(base, base.clStatics.get("thrown")), [v]));
				out.push(SThrow(v));
			case TCall(_, _) | TNew(_, _, _) | TBinop(OpAssign | OpAssignOp(_), _, _) | TUnop(Increment | Decrement, _, _):
				var x = rhs(e);
				if (isImpure(x)) out.push(SExpr(x));
			case _:
				var x = rhs(e);
				if (isImpure(x)) out.push(SExpr(x));
		}
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
	function branch(e:TExpr, target:Null<Local>):Array<Stmt> {
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
		var def = sw.switchDefault != null ? branch(sw.switchDefault, target) : [];
		if (allInt) {
			var cases = [];
			for (c in sw.switchCases)
				cases.push({
					values: [
						for (p in c.casePatterns)
							switch strip(p).eexpr {
								case TConst(TInt(i)): i;
								case TConst(TBool(b)): b ? 1 : 0;
								case _: 0;
							}
					],
					body: branch(c.caseExpr, target)
				});
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
						out.push(SIf(eq, [SSet(r, EInt(1))], []));
					}
				});
				chain = pre.concat([SIf(ELocal(r), body, chain)]);
			}
			for (x in chain)
				out.push(x);
		}
	}

	// FNV-1a over the UTF-16 units, as Str.hash computes (and caches) it at run time
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
	function stringSwitch(sw:TSwitch, st:Ty, subj:Ex, def:Array<Stmt>, target:Null<Local>):Bool {
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
		var pick = [];
		for (h in hashes) {
			var g = groups.get(h);
			var chain:Array<Stmt> = [];
			var i = g.length;
			while (i-- > 0) {
				var x = g[i];
				chain = [SIf(equality(ELocal(s), st, value(x.p), tyOf(x.p), true), [SSet(k, EInt(x.index))], chain)];
			}
			pick.push({values: [h], body: chain});
		}
		out.push(SSet(k, EInt(-1)));
		out.push(SIf(EBin(RefNe, ELocal(s), ENull(st)), [SSwitch(ECallHost("hx_str_hash", [ELocal(s)], TI32), pick, [])], []));
		var cases = [for (ci in 0...sw.switchCases.length) {values: [ci], body: branch(sw.switchCases[ci].caseExpr, target)}];
		out.push(SSwitch(ELocal(k), cases, def));
		return true;
	}

	function tryStmt(body:TExpr, catches:Array<{variable:TVar, expr:TExpr}>, target:Null<Local>) {
		fi.hasTry = true;
		var b = branch(body, target);
		var cs = [];
		for (c in catches) {
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
					x -> EInstOf(ci, ECall(fn, [x])); // pure enough: caught allocates only for non-Exception values
				};
			}
			var handler = block(() -> {
				var src:Ex = ELocal(exn);
				if (caught != null) {
					out.push(SSet(caught, ECall(l.staticFunc(base, base.clStatics.get("caught")), [ELocal(exn)])));
					src = ELocal(caught);
				}
				var x = coerce(src, caught != null ? caught.ty : TRef(RAny), t);
				if (isBoxed(c.variable)) out.push(SSet(lo, ENewBox(t, x))) else out.push(SSet(lo, x));
			}).concat(branch(c.expr, target));
			cs.push({test: test, l: exn, body: handler});
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
				tr == null ? null : x -> ECallHost(l.native("hx_is"), [x, EType(tr)], TBool);
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
		return switch ty(TInst(c, [])) {
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
				var lo = local(v, e);
				var x:Ex = isBoxed(v) ? EBoxGet(ty(v.vType), ELocal(lo)) : ELocal(lo);
				coerce(x, ty(v.vType), tyOf(e));
			case TParenthesis(e1) | TMeta(_, e1): coerceRhs(rhs(e1), tyOf(e1), tyOf(e));
			case TCast(e1, null): coerceRhs(rhs(e1), tyOf(e1), tyOf(e));
			case TCast(e1, mt):
				// checked cast: throws when the value doesn't have the type
				var x = coerce(value(e1), tyOf(e1), TRef(RAny));
				var c = temp(TRef(RAny), ECallHost(l.native("hx_cast"), [x, EType(typeRef(mt))], TRef(RAny)));
				coerce(c, TRef(RAny), tyOf(e));
			case TTypeExpr(mt):
				switch mt {
					case TClassDecl(c): l.reflectStatics(c);
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
						var xs = operands([a, i]);
						var al = ELocal(asLocal(xs[0], tyOf(a)));
						coerce(nativeRead(elem, al, ELocal(asLocal(coerce(xs[1], tyOf(i), TI32), TI32)), e.epos), elem, tyOf(e));
					case TRef(RArr(elem)):
						var xs = operands([a, i]);
						var ix = coerce(xs[1], tyOf(i), TI32);
						coerce(isVectorData(a.etype) ? EArrGetU(elem, xs[0], ix) : EArrGet(elem, xs[0], ix), elem, tyOf(e));
					case _:
						var xs = operands([a, i]);
						var r = temp(TRef(RAny), ECallHost(l.native("hx_dyn_aget"), [coerce(xs[0], tyOf(a), TRef(RAny)), coerce(xs[1], tyOf(i), TI32)], TRef(RAny)));
						coerce(r, TRef(RAny), tyOf(e));
				}
			case TBinop(op = OpBoolAnd | OpBoolOr | OpEq | OpNotEq | OpLt | OpLte | OpGt | OpGte, a, b) if (tyOf(e) != TBool):
				// a Bool typed as something else (the optimizer's `c && x` for
				// `c ? x : false`, typed as the conditional was: Dynamic, a box)
				coerce(binop(op, a, b, e), TBool, tyOf(e));
			case TBinop(op, a, b): binop(op, a, b, e);
			case TUnop(op, flag, e1): unop(op, flag, e1, e);
			case TCall(f, cargs): call(f, cargs, e);
			case TNew(c, params, cargs) if (Lower.isNativeArray(c)):
				var n = coerce(value(cargs[0]), tyOf(cargs[0]), TI32);
				// (of an erased type parameter: a wrapper, which the first typed
				// view converts to its kind, rt/NArray)
				var erased = switch TFunctions.follow(params[0]) {
					case TInst(pc, _): pc.clKind.match(KTypeParameter(_));
					case _: false;
				};
				if (erased) temp(tyOf(e), ECallHost(l.native("hx_narray_open"), [n], tyOf(e)));
				else ECallHost("hxmc_narray_new", [EInt(nativeKind(switch tyOf(e) {
					case TRef(RNativeArr(t)): t;
					case _: fail("NativeArray type", e);
				})), n], tyOf(e));
			case TNew(c, _, cargs) if (Lower.isCore(c, "Array")):
				var elem = switch tyOf(e) {
					case TRef(RArr(t)): t;
					case _: TRef(RAny);
				};
				ENewArr(elem, []);
			case TNew(c, _, cargs) if (CInterop.isStruct(c)):
				coerce(ELocal(newStruct(c, cargs, null)), structTy(c), tyOf(e));
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
					var xs = args(cargs, tys(ctor), l.defaults.get(ctor), 1, ctor, () -> obj);
					out.push(SExpr(ECall(ctor, [obj].concat(xs))));
				}
				coerce(obj, TRef(RObj(ci)), tyOf(e));
			case TArrayDecl(vs):
				var elem = switch tyOf(e) {
					case TRef(RArr(t)): t;
					case _: TRef(RAny);
				};
				var xs = operands(vs);
				ENewArr(elem, [for (i in 0...xs.length) coerce(xs[i], tyOf(vs[i]), elem)]);
			case TObjectDecl(fs):
				var xs = operands([for (f in fs) f.expr]);
				var fields = [for (i in 0...fs.length) {name: fs[i].key.name, ty: l.boxed(tyOf(fs[i].expr))}];
				var sh = l.getProgram().shape(fields);
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
				ENewAnon(sh, vals);
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
			case TIdent(n): fail("identifier " + n, e);
			case _: fail("expression " + e.eexpr.getName(), e);
		}
	}

	function ctorSig(c:TClass):Array<Ty> {
		if (c.clConstructor == null) return [];
		return switch TFunctions.follow(c.clConstructor.cfType) {
			case TFun(s): [for (a in s.args) ty(a.type)];
			case _: [];
		}
	}

	// ---- field access

	function field(obj:TExpr, fa:TFieldAccess, e:TExpr):Ex {
		return switch fa {
			case FInstance(c, _, cf):
				switch cf.cfKind {
					case Method(MethDynamic) if (isDynMethod(c, cf)): coerce(dynMethod(obj, c, cf, e), dynSlotTy(c, cf), tyOf(e));
					case Method(_): methodClosure(obj, c, cf, e);
					case Var(_) if (Lower.isCore(c, "Array") && cf.cfName == "length"):
						EArrLen(value(obj));
					case Var(_) if (Lower.isNativeArray(c) && cf.cfName == "length"):
						ECallHost("hxmc_narray_length", [value(obj)], TI32);
					case Var(_) if (Lower.isCore(c, "String") && cf.cfName == "length"):
						ECallHost("String_length", [value(obj)], TI32);
					case Var(_) if (CInterop.isStruct(c)): structGet(obj, c, cf, e);
					case Var(_) if (c.hasClassFlag(CExtern)):
						var t = ty(cf.cfType);
						var x = temp(t, ECallHost(l.native(Lower.nativeName(c) + "_get_" + cf.cfName), [value(obj)], t));
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
			case FStatic(c, cf):
				var cf = overloadImpl(c, cf);
				switch cf.cfKind {
					case Var(_) if (c.hasClassFlag(CExtern)):
						var t = ty(cf.cfType);
						coerce(temp(t, ECallHost(l.native(Lower.nativeName(c) + "_" + cf.cfName), [], t)), t, tyOf(e));
					case Var(_):
						var g = l.staticVar(c, cf);
						var t = l.getProgram().globals[g].ty;
						coerce(EGlobal(g, t), t, tyOf(e));
					case Method(_) if (c.hasClassFlag(CExtern) || cf.cfExpr == null):
						var s = switch TFunctions.follow(cf.cfType) {
							case TFun(s): s;
							case _: fail("extern static " + cf.cfName + " is not a function", e);
						};
						var sig = l.getProgram().sig([for (a in s.args) ty(a.type)], ty(s.ret));
						var li = l.hostClosure(l.native(Lower.nativeName(c) + "_" + cf.cfName), sig);
						coerce(temp(TRef(RClos(sig)), ENewClos(li, [])), TRef(RClos(sig)), tyOf(e));
					case Method(MethDynamic):
						var g = staticDynMethod(c, cf);
						coerce(EGlobal(g, l.getProgram().globals[g].ty), l.getProgram().globals[g].ty, tyOf(e));
					case Method(_):
						var f = l.staticFunc(c, cf);
						var li = l.staticClosure(f);
						var x = temp(TRef(RClos(li.sig)), ENewClos(li, []));
						coerce(x, TRef(RClos(li.sig)), tyOf(e));
				}
			case FAnon(cf):
				anonGet(cf.cfName, obj, e);
			case FDynamic(name):
				var o = coerce(value(obj), tyOf(obj), TRef(RAny));
				var r = temp(TRef(RAny), ECallHost(l.native("hx_dyn_get"), [o, EStr(name)], TRef(RAny)));
				coerce(r, TRef(RAny), tyOf(e));
			case FClosure(cl, cf):
				if (cl == null) {
					// a closure of a structural field: just the field's value
					anonGet(cf.cfName, obj, e);
				} else if (cf.cfKind.match(Method(MethDynamic)) && isDynMethod(cl.cls, cf)) {
					coerce(dynMethod(obj, cl.cls, cf, e), dynSlotTy(cl.cls, cf), tyOf(e));
				} else methodClosure(obj, cl.cls, cf, e);
			case FEnum(en, ef):
				var ci = l.ctorInfo(ef, en);
				if (ci.global >= 0) coerce(EGlobal(ci.global, TRef(RCtor(ci))), TRef(RCtor(ci)), tyOf(e)) else {
					// a constructor with arguments used as a function
					var sig = l.getProgram().sig(ci.params, TRef(REnum(ci.en)));
					var li = l.ctorClosure(ci, sig);
					coerce(temp(TRef(RClos(sig)), ENewClos(li, [])), TRef(RClos(sig)), tyOf(e));
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
		}), []));
		return ELocal(s);
	}

	function staticDynMethod(c:TClass, cf:TClassField):Int {
		var g = l.staticVar(c, cf);
		var t = l.getProgram().globals[g].ty;
		out.push(SIf(EBin(RefEq, EGlobal(g, t), ENull(t)), block(() -> {
			var f = l.staticFunc(c, cf);
			var li = l.staticClosure(f);
			out.push(SSetGlobal(g, coerce(temp(TRef(RClos(li.sig)), ENewClos(li, [])), TRef(RClos(li.sig)), t)));
		}), []));
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
			var sig = l.getProgram().sig([for (a in s.args) ty(a.type)], ty(s.ret));
			var li = l.hostClosure(l.native(Lower.nativeName(c) + "_" + cf.cfName), sig, tyOf(obj));
			var x = temp(TRef(RClos(sig)), ENewClos(li, [value(obj)]));
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
		var x = temp(TRef(RClos(li.sig)), ENewClos(li, [o]));
		return coerce(x, TRef(RClos(li.sig)), rt);
	}

	// A dispatched call's missing arguments get the defaults of the method the
	// receiver's class runs (an override may declare other values than the
	// method the static type finds, `ds`). `xs` are the arguments after the
	// receiver (`to` with it).
	function overrideDefaults(c:TClass, name:String, o:Ex, xs:Array<Ex>, given:Int, to:Array<Ty>, ds:Null<Array<Null<TExpr>>>) {
		for (i in given + 1...to.length) {
			var all:Array<Null<Ex>> = [o].concat(xs);
			var x = receiverDefault(c, name, o, i, ds != null && i < ds.length ? ds[i] : null, to[i], xs[i - 1], all, to);
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
		inline function defaultOf(f:TClassField):Null<TExpr> {
			var tf = switch f.cfExpr.eexpr { case TFunction(tf): tf; case _: null; };
			return tf != null && i - 1 < tf.tfArgs.length ? tf.tfArgs[i - 1].defaultValue : null;
		}
		var impls = l.implementors(c, name);
		var differs = false;
		for (k in impls)
			if (!sameDefault(defaultOf(k.field), base)) differs = true;
		if (!differs) return null;
		// (a reference: null, which the callee replaces with its own default)
		if (t != TI32 && t != TF64 && t != TBool) return nullOf(t);
		var r = newLocal("d", t);
		inline function varsOf(f:TClassField):Null<Array<Null<TVar>>>
			return switch f.cfExpr.eexpr {
				case TFunction(tf): [null].concat([for (a in tf.tfArgs) a.variable]);
				case _: null;
			};
		// (the arguments as locals, for defaults reading them: defaultValue)
		var reads = false;
		for (k in impls) {
			var d = defaultOf(k.field), vars = varsOf(k.field);
			if (d != null && vars != null && !constDefault(d) && readsFunction(d, vars)) reads = true;
		}
		if (reads)
			for (k in 1...i)
				if (k < given.length && !isConst(given[k]) && !given[k].match(ELocal(_))) given[k] = ELocal(asLocal(given[k], givenTys[k]));
		out.push(SSet(r, x));
		for (k in impls) {
			var d = defaultOf(k.field);
			var vars = varsOf(k.field);
			var test = ECallHost(l.native("hx_is"), [coerce(o, TRef(RObj(l.rootClass())), TRef(RAny)), EType(TRClass(l.classInfo(k.cls)))], TBool);
			out.push(SIf(test, block(() -> out.push(SSet(r, d != null ? defaultValue(d, t, i, vars, given, givenTys, () -> o, l.classInfo(k.cls)) : nullOf(t)))), []));
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
		return {sig: l.getProgram().sig(args, ret), args: args, ret: ret};
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
				out.push(op == OpBoolAnd ? SIf(ELocal(lo), rest, []) : SIf(ELocal(lo), [], rest));
				return ELocal(lo);
			case OpEq | OpNotEq:
				var xs = operands([a, b]);
				var eq = equality(xs[0], tyOf(a), xs[1], tyOf(b), false);
				return op == OpEq ? eq : ENot(eq);
			case OpLt | OpLte | OpGt | OpGte:
				var xs = operands([a, b]);
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
			case _:
				var xa = value(a);
				return arith(op, xa, tyOf(a), () -> {x: value(b), t: tyOf(b)}, tyOf(e), e);
		}
	}

	// a op b, with a already lowered; b lowered by the callback (after a)
	function arith(op:Binop, xa:Ex, ta:Ty, getB:() -> {x:Ex, t:Ty}, rt:Ty, e:TExpr):Ex {
		var before = out.length;
		var rb = getB();
		if (out.length != before && !isConst(xa) && !xa.match(ELocal(_))) {
			var lo = newLocal("s", ta);
			out.insert(before, SSet(lo, xa));
			xa = ELocal(lo);
		}
		var xb = rb.x, tb = rb.t;
		var isStr = (t:Ty) -> t.match(TRef(RStr));
		if (op == OpAdd && (rt.match(TRef(RStr)) || isStr(ta) || isStr(tb))) {
			var sa = toStr(xa, ta), sb = toStr(xb, tb);
			return temp(TRef(RStr), ECallHost(l.native("hx_str_concat"), [sa, sb], TRef(RStr)));
		}
		var num = (t:Ty) -> t == TI32 || t == TF64 || t == TBool || t == TI64 || t.match(TRef(RNull(_)));
		if (!num(ta) || !num(tb)) {
			// Dynamic arithmetic
			var da = coerce(xa, ta, TRef(RAny)), db = coerce(xb, tb, TRef(RAny));
			var r = temp(TRef(RAny), ECallHost(l.native("hx_dyn_op"), [EInt(opCode(op)), da, db], TRef(RAny)));
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
			return Ir.isRef(t) ? EBin(RefEq, x, ENull(t)) : EInt(0);
		}
		var scalar = (t:Ty) -> t == TI32 || t == TBool || t == TF64 || t == TI64;
		if (scalar(ta) && scalar(tb)) {
			if (ta == TF64 || tb == TF64) return EBin(FEq, coerce(xa, ta, TF64), coerce(xb, tb, TF64));
			if (ta == TI64 || tb == TI64) return EBin(LEq, coerce(xa, ta, TI64), coerce(xb, tb, TI64));
			return EBin(Eq, xa, xb);
		}
		switch [ta, tb] {
			case [TRef(RStr), TRef(RStr)]:
				return ECallHost("hx_str_eq", [xa, xb], TBool);
			// (a NativeArray: its identity, as hx_dyn_eq has it)
			case [TRef(RObj(_) | REnum(_) | RCtor(_) | RClos(_) | RArr(_) | RNativeArr(_) | RAnon | RType | RNative(_)), TRef(RObj(_) | REnum(_) | RCtor(_) | RClos(_) | RArr(_) | RNativeArr(_) | RAnon | RType | RNative(_))]:
				return EBin(RefEq, xa, xb);
			case _:
				var da = coerce(xa, ta, TRef(RAny)), db = coerce(xb, tb, TRef(RAny));
				return ECallHost("hx_dyn_eq", [da, db], TBool);
		}
	}

	function compare(op:Binop, xa:Ex, ta:Ty, xb:Ex, tb:Ty):Ex {
		var scalar = (t:Ty) -> switch t {
			case TI32 | TBool | TF64 | TI64: t;
			case TRef(RNull(s)): s;
			case _: null;
		};
		var sa = scalar(ta), sb = scalar(tb);
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
		var c = if (ta.match(TRef(RStr)) && tb.match(TRef(RStr))) ECallHost("hx_str_cmp", [xa, xb], TI32) else
			ECallHost("hx_dyn_cmp", [coerce(xa, ta, TRef(RAny)), coerce(xb, tb, TRef(RAny))], TI32);
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
				out.push(SSetField(ci, idx, o, x));
				return coerce(x, t, et);
			case TField(obj, FInstance(c, _, cf)) if (Lower.isCore(c, "Array") && cf.cfName == "length"):
				// `untyped a.length = n` (haxe.ds.Vector's generic constructor):
				// Array.resize, not a structural store by name
				var o = ELocal(asLocal(value(obj), tyOf(obj)));
				var x = pure(compute(() -> EArrLen(o), TI32, TI32), TI32);
				out.push(SExpr(ECallHost(l.native("Array_resize"), [o, x], TVoid)));
				return coerce(x, TI32, et);
			case TField(obj, FAnon(cf) | FInstance(_, _, cf)):
				var t = l.boxed(tyOf(lhs));
				var o = ELocal(asLocal(value(obj), tyOf(obj)));
				var x = pure(compute(() -> EAnonGet(cf.cfName, t, o, null), t, t), t);
				out.push(SAnonSet(cf.cfName, t, o, x));
				return coerce(x, t, et);
			case TField(_, FStatic(c, cf)) if (!c.hasClassFlag(CExtern)):
				var g = l.staticVar(c, cf);
				var t = l.getProgram().globals[g].ty;
				var x = pure(compute(() -> EGlobal(g, t), t, t), t);
				out.push(SSetGlobal(g, x));
				return coerce(x, t, et);
			case TField(obj, FDynamic(name)):
				var o = ELocal(asLocal(coerce(value(obj), tyOf(obj), TRef(RAny)), TRef(RAny)));
				var t = TRef(RAny);
				var x = pure(compute(() -> temp(t, ECallHost(l.native("hx_dyn_get"), [o, EStr(name)], t)), t, t), t);
				out.push(SExpr(ECallHost(l.native("hx_dyn_set"), [o, EStr(name), x], TVoid)));
				return coerce(x, t, et);
			case TArray(a, i):
				switch tyOf(a) {
					case TRef(RNativeArr(elem)):
						var al = asLocal(value(a), tyOf(a));
						var ix = ELocal(asLocal(coerce(value(i), tyOf(i), TI32), TI32));
						var x = pure(compute(() -> nativeRead(elem, ELocal(al), ix, lhs.epos), elem, elem), elem);
						nativeWrite(elem, ELocal(al), ix, x, lhs.epos);
						return coerce(x, elem, et);
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
						var x = pure(compute(() -> temp(t, ECallHost(l.native("hx_dyn_aget"), [o, ix], t)), t, t), t);
						out.push(SExpr(ECallHost(l.native("hx_dyn_aset"), [o, ix, x], TVoid)));
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

	function call(f:TExpr, cargs:Array<TExpr>, e:TExpr):Ex {
		var rt = tyOf(e);
		switch strip(f).eexpr {
			case TField(o, FStatic(c, cf)) if (overloadImpl(c, cf) != cf):
				// (its arguments and result converted from the overload's types)
				f = {eexpr: TField(o, FStatic(c, overloadImpl(c, cf))), etype: f.etype, epos: f.epos};
			case _:
		}
		switch strip(f).eexpr {
			// (the std's own loops, over indices they keep in bounds: not
			// tested, whatever -D hxmc.native-array-outofbounds says)
			case TField(obj, FInstance(c, _, cf)) if (Lower.isNativeArray(c) && (cf.cfName == "unsafeGet" || cf.cfName == "unsafeSet")):
				var elem = switch tyOf(obj) {
					case TRef(RNativeArr(t)): t;
					case _: return fail("NativeArray." + cf.cfName + " of another type", e);
				};
				var xs = operands([obj].concat(cargs));
				var a = ELocal(asLocal(xs[0], tyOf(obj))), i = coerce(xs[1], tyOf(cargs[0]), TI32);
				if (cf.cfName == "unsafeGet") return coerce(nativeRead(elem, a, i), elem, rt);
				nativeWrite(elem, a, i, ELocal(asLocal(coerce(xs[2], tyOf(cargs[1]), elem), elem)));
				return EInt(0);
			case TField(_, FStatic(_, cf)) if (cf.cfKind.match(Var(_))):
				return callValue(f, cargs, e);
			case TIdent("__resources__") if (cargs.length == 0):
				// haxe.Resource's content: an object per resource with its name
				// and its data in base64 (Lower.resources), as genjs writes it
				var sh = l.getProgram().shape([{name: "name", ty: TRef(RStr)}, {name: "data", ty: TRef(RStr)}]);
				var objs:Array<Ex> = [
					for (r in Lower.resources)
						temp(TRef(RAnon), ENewAnon(sh, [for (f in sh.fields) EStr(f.name == "name" ? r.name : r.data)]))
				];
				var at = TRef(RArr(TRef(RAnon)));
				return coerce(temp(at, ENewArr(TRef(RAnon), objs)), at, rt);
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
				var xs = args(cargs, [for (a in s.args) ty(a.type)], null);
				return coerceRhs(ECallHost(l.native(name), xs, t), t, rt);
			case TField(obj, FDynamic("cca")) if (tyOf(obj).match(TRef(RStr)) && cargs.length == 1):
				// StringTools.fastCodeAt / unsafeCodeAt: `untyped s.cca(i)` (0 past the end, as on cpp/hl)
				var xs = operands([obj, cargs[0]]);
				return coerceRhs(ECallHost("String_charCodeAt_i", [xs[0], coerce(xs[1], tyOf(cargs[0]), TI32)], TI32), TI32, rt);
			case TField(_, FStatic(c, cf)) if (cf.cfKind.match(Method(MethDynamic)) && !c.hasClassFlag(CExtern)):
				var g = staticDynMethod(c, cf);
				var t = l.getProgram().globals[g].ty;
				var s = switch t { case TRef(RClos(s)): s; case _: fail("dynamic static " + cf.cfName + " is not a closure", e); };
				var cl = asLocal(EGlobal(g, t), t);
				var xs = args(cargs, s.args, null);
				return callClos(s, ELocal(cl), xs, rt);
			case TField(_, FStatic(c, cf)):
				var fn = l.staticFunc(c, cf);
				var xs = args(cargs, callTys(fn), l.defaults.get(fn), 0, fn);
				return callFn(fn, xs, rt);
			case TField({eexpr: TConst(TSuper)}, FInstance(c, _, cf)):
				var impl = l.lookupMethod(c, cf.cfName);
				if (impl == null) fail("super." + cf.cfName + " without implementation", e);
				var fn = l.method(impl.cls, impl.field);
				var xs = args(cargs, callTys(fn), l.defaults.get(fn), 1, fn, () -> ELocal(thisLocal));
				return callFn(fn, [(ELocal(thisLocal) : Ex)].concat(xs), rt);
			case TConst(TSuper):
				var sup = l.superOf(self);
				while (sup != null && sup.clConstructor == null && sup.clSuper != null)
					sup = sup.clSuper.cls;
				if (sup == null || sup.clConstructor == null) return EInt(0);
				var fn = l.ctor(sup);
				var xs = args(cargs, tys(fn), l.defaults.get(fn), 1, fn, () -> ELocal(thisLocal));
				out.push(SExpr(ECall(fn, [(ELocal(thisLocal) : Ex)].concat(xs))));
				return EInt(0);
			case TField(obj, FInstance(c, _, cf)) if (Lower.isCore(c, "Array") && cf.cfName == "push"):
				var at = tyOf(obj);
				var elem = switch at {
					case TRef(RArr(t)): t;
					case _: TRef(RAny);
				};
				var xs = operands([obj, cargs[0]]);
				var al = asLocal(xs[0], at);
				out.push(SArrPush(elem, al, coerce(xs[1], tyOf(cargs[0]), elem)));
				return coerce(EArrLen(ELocal(al)), TI32, rt);
			case TField(obj, FInstance(c, _, cf)) if (c.hasClassFlag(CExtern) || Lower.isCore(c, "String") || Lower.isCore(c, "Array")):
				var s = switch TFunctions.follow(cf.cfType) {
					case TFun(s): s;
					case _: fail("extern method " + cf.cfName + " is not a function", e);
				};
				var name = Lower.nativeName(c) + "_" + cf.cfName;
				var t = ty(s.ret);
				var xs = args([obj].concat(cargs), [tyOf(obj)].concat([for (a in s.args) ty(a.type)]), null);
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
					var ds = implFn != null ? l.defaults.get(implFn) : null;
					var rootTy = TRef(RObj(l.rootClass()));
					var o = coerce(value(obj), tyOf(obj), rootTy);
					var before = out.length;
					var to = sig.ret.match(TStruct(_)) ? d.args.slice(0, d.args.length - 1) : d.args;
					var xs = args(cargs, to, ds, 1, implFn, () -> o = receiverLocal(o, rootTy, before));
					o = spillBefore(o, rootTy, before);
					if (cargs.length + 1 < to.length && !o.match(ELocal(_))) o = ELocal(asLocal(o, rootTy)); // (the defaults may test it)
					overrideDefaults(c, cf.cfName, o, xs, cargs.length, to, ds);
					if (sig.ret.match(TStruct(_))) {
						// (a struct result: the address of a slot here, last)
						var s = newSlot(sig.ret, true);
						out.push(SExpr(ECallDispatch(l.selector(cf.cfName, sig), sig, [o].concat(xs).concat([ELocal(s)]))));
						return coerce(ELocal(s), sig.ret, rt);
					}
					return coerceRhs(ECallDispatch(l.selector(cf.cfName, sig), sig, [o].concat(xs)), d.ret, rt);
				}
				var impl = l.lookupMethod(c, cf.cfName);
				if (impl == null) fail("no implementation of " + cf.cfName, e);
				var fn = l.method(impl.cls, impl.field);
				var o = value(obj);
				var before = out.length;
				var xs = args(cargs, callTys(fn), l.defaults.get(fn), 1, fn, () -> o = receiverLocal(o, tyOf(obj), before));
				return callFn(fn, [spillBefore(o, tyOf(obj), before)].concat(xs), rt);
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
				var xs = args(cargs, [for (_ in cargs) TRef(RAny)], null);
				var arr = temp(TRef(RArr(TRef(RAny))), ENewArr(TRef(RAny), xs));
				var r = ECallHost(l.native("hx_dyn_call_field"), [o, EStr(name), arr], TRef(RAny));
				return coerceRhs(r, TRef(RAny), rt);
			case _:
				return callValue(f, cargs, e);
		}
	}

	// calling a function value: a closure, or Dynamic
	function callValue(f:TExpr, cargs:Array<TExpr>, e:TExpr):Ex {
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
				var xs = args(cargs, [for (_ in cargs) TRef(RAny)], null);
				var arr = temp(TRef(RArr(TRef(RAny))), ENewArr(TRef(RAny), xs));
				return coerceRhs(ECallHost(l.native("hx_dyn_call"), [ELocal(c), arr], TRef(RAny)), TRef(RAny), rt);
		}
	}

	// static externs lowered to IR operations instead of runtime calls
	function intrinsicStatic(name:String, cargs:Array<TExpr>, e:TExpr):Null<Ex> {
		return switch name {
			case "Std_int" if (cargs.length == 1):
				var mm = intMinMax(cargs[0]);
				if (mm != null) return coerce(mm, TI32, tyOf(e));
				coerce(EConv(F2I, coerce(value(cargs[0]), tyOf(cargs[0]), TF64)), TI32, tyOf(e));
			case "Std_isOfType" if (cargs.length == 2 && typeObjectKind(cargs[1]) >= 0):
				// Std.isOfType(v, Class), (v, Enum): whether v is a type object of a
				// class or of an enum (hx_is_typeobj; hx_is knows no such type)
				var k = typeObjectKind(cargs[1]);
				coerce(ECallHost(l.native("hx_is_typeobj"), [coerce(value(cargs[0]), tyOf(cargs[0]), TRef(RAny)), EInt(k)], TBool), TBool, tyOf(e));
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
				out.push(SIf(EBin(cf.cfName == "min" ? Lt : Gt, ELocal(xa), ELocal(xb)), [SSet(r, ELocal(xa))], []));
				ELocal(r);
			case _: null;
		}
	}

	function intrinsicMethod(name:String, xs:Array<Ex>, selfTy:Ty):Null<Ex> {
		return null;
	}

	// ---- C interop (docs/plans/lowlevel.md, CInterop)

	static inline function where(e:TExpr):String
		return CInterop.posOf(e.epos);

	function cfail(msg:String, e:TExpr):Dynamic
		throw new LowerError(msg, where(e));


	// the load of C type ct at addr + off, with the representation of ty(t)
	function cLoad(addr:Ex, off:Int, ct:CTy, e:TExpr):Ex {
		inline function get(n:String, t:Ty):Ex
			return coerce(temp(t, ECallHost("hxmc_unsafe_Mem_" + n, [addr, EInt(off)], t)), t, tyOf(e));
		return switch ct {
			case CI8: get("getI8", TI32);
			case CU8: get("getU8", TI32);
			case CBool: coerce(EBin(Ne, temp(TI32, ECallHost("hxmc_unsafe_Mem_getU8", [addr, EInt(off)], TI32)), EInt(0)), TBool, tyOf(e));
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
			out.push(SExpr(ECallHost("hxmc_unsafe_Mem_" + n, [addr, EInt(off), coerce(v, from, t)], TVoid)));
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
			case CNone | CVoid: cfail('Ptr<${core.TPrinting.sTypes([t])}>: no C type to access (scalars, Ptr, CString and @:hxmc.struct classes)', e);
			case COpaque(c): cfail('Ptr<${c.clPath.name}>: an opaque type has no contents to access', e);
			case _: ct;
		}
	}

	// calls of Ptr's extern accessors (value, [i], offset) and of Struct's layout
	// constants; null for any other call
	function cInteropCall(c:TClass, cf:TClassField, cargs:Array<TExpr>, e:TExpr):Null<Ex> {
		switch c.clKind {
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
					l.staticFunc(fc, fcf);
					return ECallHost("hxmc_unsafe_Mem_sym", [EStr(l.callbackSyms.get(fcf))], TI64);
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

	// a call of a C function declared by an extern (CInterop.declare): the
	// arguments converted to their C types' representations; MirBuild applies
	// the ABI (narrow and float32 values) and the safe region
	function cCall(sym:String, c:TClass, cf:TClassField, s:core.TType.TSignature, cargs:Array<TExpr>, e:TExpr):Ex {
		var sig = try CInterop.declare(sym, c, cf, s) catch (err:LowerError) {
			if (err.where == "") err.where = where(e);
			throw err;
		};
		var va = core.Meta.getOpt(Custom(":hxmc.varargs"), cf.cfMeta);
		if (va != null && va.exprs.length == 1)
			switch va.exprs[0].expr {
				case EConst(Int(k, _)): C_VARIADIC.set(sym, Std.parseInt(k));
				case _:
			}
		var t = ty(s.ret);
		var xs = args(cargs, [for (a in s.args) ty(a.type)], null);
		if (t.match(TStruct(_))) {
			// (the result's slot in this frame, MirBuild.cStructRet)
			var lo = newLocal("cr", t);
			out.push(SSet(lo, ECallHost(sym, xs, t)));
			freshSlots.set(lo, true);
			return coerce(ELocal(lo), t, tyOf(e));
		}
		return coerceRhs(ECallHost(sym, xs, t), t, tyOf(e));
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

	// ---- struct values (docs/plans/lowlevel.md, "Struct values"): the address
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
		out.push(SSet(lo, ECallHost("hxmc_unsafe_Mem_structSlot", [EInt(size), EInt(8)], TI64)));
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
			var v = ECallHost("hxmc_unsafe_Mem_" + a.get, [src, EInt(f.off)], a.t);
			out.push(SExpr(ECallHost("hxmc_unsafe_Mem_" + a.set, [dst, EInt(f.off), v], TVoid)));
		}
	}

	function zeroStruct(dst:Ex, c:TClass) {
		for (f in CInterop.scalars(c, 0)) {
			var a = rawAccess(f.ty);
			out.push(SExpr(ECallHost("hxmc_unsafe_Mem_" + a.set, [dst, EInt(f.off), nullOf(a.t)], TVoid)));
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
				var t = l.getProgram().globals[g].ty;
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
					x = EBin(FEq, temp(TF64, ECallHost("hxmc_unsafe_Mem_" + n, [pa.addr(), EInt(f.off)], TF64)),
						temp(TF64, ECallHost("hxmc_unsafe_Mem_" + n, [pb.addr(), EInt(f.off)], TF64)));
				case _:
					var acc = rawAccess(f.ty);
					var ga = temp(acc.t, ECallHost("hxmc_unsafe_Mem_" + acc.get, [pa.addr(), EInt(f.off)], acc.t));
					var gb = temp(acc.t, ECallHost("hxmc_unsafe_Mem_" + acc.get, [pb.addr(), EInt(f.off)], acc.t));
					x = EBin(acc.t == TI64 ? LEq : Eq, ga, gb);
			}
			r = r == null ? x : EBin(And, r, x);
		}
		return r == null ? EInt(1) : temp(TBool, r);
	}

	// new S(args) for a @:hxmc.struct class: its memory (a fresh slot, or
	// into) zeroed, then the constructor called on it
	function newStruct(c:TClass, cargs:Array<TExpr>, into:Null<Local>):Local {
		var t = structTy(c);
		var s = into != null ? into : newSlot(t, true);
		if (c.clConstructor == null) {
			zeroStruct(ELocal(s), c);
			return s;
		}
		var ctor = l.structCtor(c);
		var xs = args(cargs, tys(ctor), l.defaults.get(ctor), 1, ctor);
		zeroStruct(ELocal(s), c);
		out.push(SExpr(ECall(ctor, [(ELocal(s) : Ex)].concat(xs))));
		return s;
	}

	// the argument types a call passes to f (without its result's address)
	static function callTys(f:FuncInfo):Array<Ty> {
		var t = tys(f);
		if (f.sret) t.pop();
		return t;
	}

	// a call of f; a struct result lands in a slot of this frame
	function callFn(f:FuncInfo, xs:Array<Ex>, rt:Ty):Ex {
		if (!f.sret) return coerceRhs(ECall(f, xs), f.ret, rt);
		var s = newSlot(f.ret, true);
		out.push(SExpr(ECall(f, xs.concat([ELocal(s)]))));
		return coerce(ELocal(s), f.ret, rt);
	}

	static function hasStruct(s:SigInfo):Bool {
		for (t in s.args)
			if (t.match(TStruct(_))) return true;
		return s.ret.match(TStruct(_));
	}

	// a call of a closure; a struct result lands in a slot of this frame
	function callClos(s:SigInfo, c:Ex, xs:Array<Ex>, rt:Ty):Ex {
		if (!s.ret.match(TStruct(_))) return coerceRhs(ECallClos(s, c, xs), s.ret, rt);
		var r = newSlot(s.ret, true);
		out.push(SExpr(ECallClos(s, c, xs.concat([ELocal(r)]))));
		return coerce(ELocal(r), s.ret, rt);
	}

	// a struct value in a new box (its copy)
	function box(x:Ex, n:String):Ex {
		var ci = l.structBox(n);
		var c = l.structClasses.get(n);
		var src = x.match(ELocal(_) | EGlobal(_, _)) ? x : ELocal(asLocal(x, structTy(c)));
		var b = temp(TRef(RObj(ci)), ENewObj(ci));
		copyStruct(EFieldAddr(ci, 0, b), src, c);
		return b;
	}

	// the value a box holds, copied out (null: zeros); a reference that is
	// not one fails as a cast does
	function unbox(x:Ex, from:Ty, n:String):Ex {
		var ci = l.structBox(n);
		var c = l.structClasses.get(n);
		var t = TRef(RObj(ci));
		var b = switch from {
			case TRef(RObj(k)) if (k == ci): asLocal(x, from);
			case _: asLocal(temp(TRef(RAny), ECallHost(l.native("hx_cast"), [coerce(x, from, TRef(RAny)), EType(TRClass(ci))], TRef(RAny))), TRef(RAny));
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
			case _: l.getProgram().sig([for (a in tf.tfArgs) ty(a.variable.vType)], ty(tf.tfType));
		};
		var outerBoxed = boxed;
		var li = l.newLambda(sig, captureLocals, fl -> fl.runLambda(tf, copyMap(outerBoxed), caps), Lower.lambdaName(fi), fi.module);
		return ENewClos(li, capVals);
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
