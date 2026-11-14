package hxmc.ir;

import core.Ast.Binop;
import core.Ast.Unop;
import core.TType;
import hxmc.ir.Ir;
import hxmc.ir.Lower.LowerError;

using core.TFunctions;

// The safe subset of kernels (docs/interop.md, "Kernels"): the
// body of a function declared @:hxmc.kernel or @:hxmc.blocking and not
// @:hxmc.unsafe, checked on the typed AST (FnLower.run) before it is
// lowered. Whatever Haxe inlined into it is checked as its own code. What
// GC-freedom itself asks (no GC point, no GC value, calls only of GC-free
// functions) Facts.kernelCulprit checks again on the lowered body, for every
// build: a body the compilation server reuses is not checked here again.
//
// The rules, each error naming the rule and the expression:
//   - GC values (an object, String, Array, enum value, anonymous object,
//     Dynamic, Null<T>, an erased type parameter) only as loans, and none
//     in a @:hxmc.blocking kernel: held in locals, passed to kernels,
//     returned, compared with null; read only through a kernel that knows
//     the layout (a view: hxmc.rt.StrView), never by a field or an index;
//     no allocation (string literals are static data); no Dynamic nor a
//     type parameter's value where a typed one is expected (a view trusts
//     its value's type);
//   - no raw memory: no value of hxmc.unsafe's types but its C scalars
//     (Ptr, IoBuffer, Arena, CString, Slice, ...) nor of an abstract over
//     one, no call of Mem (but its pure functions: unsigned comparisons
//     and divisions, bit casts), Atomic, Callback or a C function;
//   - no unchecked cast but between scalars;
//   - writes of statics only of plain values (Int, Float, Bool, I64, the C
//     scalars, enum abstracts over them, @:hxmc.struct values of them; a
//     @:hxmc.threadLocal static too): no static of a GC or raw type (a race
//     on a scalar is a data race, never memory unsafe; Facts.writesStatics
//     tells the optimizer such a kernel writes them);
//   - no closure, no call but of static @:hxmc.kernel functions, Math's
//     and Std.int; no throw, no try, no untyped code;
//   - a proof (a @:hxmc.proof abstract, or one over it: hxmc.rt.TypeView's
//     TypeIndex) is held, passed, compared and returned, never made: no
//     cast to it, no other value where one is expected (an unboxed Dynamic,
//     a call whose declared result is a type parameter);
//     only @:hxmc.unsafe code makes one, and only kernels and @:hxmc.unsafe
//     code call a function taking one (FnLower), which is no value
//     (Lower.reflectStatics); no span of proofs, no static or struct field
//     of one (Lower, CInterop).
class KernelCheck {
	var l:Lower;
	var fi:FuncInfo;
	var errors:Array<String> = [];
	var seen = new Map<String, Bool>();
	// GC values as loans (not blocking; Facts.kernelCulprit checks the rest:
	// no safe region entered, nothing stored)
	var loans:Bool;

	// the function's result type (a returned proof is checked as any flow)
	var ret:Null<T>;
	// the locals holding a span of the frame's scratch (Span.stack): never the result
	var scratch = new Map<Int, Bool>();

	public static inline var SCRATCH = "a span of a kernel's frame lives while the kernel runs";

	// whether e is a span of the frame's scratch, or of one (an element of one is no span)
	function fromScratch(e:TExpr):Bool
		return spanOf(e.etype) != null && switch e.eexpr {
			case TLocal(v): scratch.exists(v.vId);
			case TParenthesis(x) | TMeta(_, x) | TCast(x, _): fromScratch(x);
			case TIf(_, a, b): fromScratch(a) || b != null && fromScratch(b);
			case TBlock(el) if (el.length > 0): fromScratch(el[el.length - 1]);
			case TCall({eexpr: TField(_, FStatic({clKind: KAbstractImpl(a)}, {cfName: "stack"}))}, _) if (isSpanAbstract(a)):
				true;
			// (a call's span may be any span argument's: an identity kernel, a sub)
			case TCall(_, args):
				var any = false;
				for (a in args)
					if (fromScratch(a)) any = true;
				any;
			case _: false;
		}

	// the kernels C calls (a @:hxmc.callback taking spans, Lower.spanCallback):
	// as a blocking one, no loans: C may call them in a safe region
	public static var entries = new Map<String, Bool>();

	function new(l, fi) {
		this.l = l;
		this.fi = fi;
		loans = !fi.declBlocking && !entries.exists(fi.name);
	}

	// the violations of fi's body tf (an error listing them all), or nothing
	// the seconds spent checking (HXMC_STATS)
	public static var seconds = 0.0;

	public static function check(l:Lower, fi:FuncInfo, tf:TFunc) {
		var t0 = haxe.Timer.stamp();
		var c = new KernelCheck(l, fi);
		c.ret = tf.tfType;
		for (a in tf.tfArgs)
			c.value(a.variable.vType, a.variable.vPos, "the parameter " + a.variable.vName);
		c.value(tf.tfType, fi.pos, "the result");
		c.expr(tf.tfExpr);
		seconds += haxe.Timer.stamp() - t0;
		if (c.errors.length > 0) throw new LowerError(c.errors.join("\n"), "");
	}

	function fail(p:core.Globals.Pos, what:String, rule:String) {
		var at = CInterop.posOf(p);
		var msg = (at != "" ? at + ": " : "") + Facts.displayName(fi) + ": " + what + " (kernel: " + rule + ")";
		if (seen.exists(msg)) return;
		seen.set(msg, true);
		errors.push(msg);
	}

	static function typeName(t:T):String
		return core.TPrinting.Printer.sType(t);

	// ---- spans (hxmc.Span, hxmc.ReadOnlySpan: FnLower.spanCall)

	// the rule of where spans exist, as errors name it
	public static inline var SPANS_LOCAL = "spans live in parameters and locals only";
	public static inline var SPANS_KERNEL = "spans exist only in kernels";

	public static function isSpanAbstract(a:TAbstract):Bool
		return a.aPath.pack.length == 1 && a.aPath.pack[0] == "hxmc" && (a.aPath.name == "Span" || a.aPath.name == "ReadOnlySpan");

	// t a span type: its element type, and whether it is read-only; else null
	public static function spanOf(t:T):Null<{ro:Bool, elem:T}>
		return switch t.follow() {
			case TAbstract(a, pl) if (pl.length == 1 && isSpanAbstract(a)): {ro: a.aPath.name == "ReadOnlySpan", elem: pl[0]};
			case _: null;
		}

	// the error of a span where it may not be (outside a kernel, in a
	// declaration): `what` names it
	public static function spanError(at:String, fn:String, what:String, rule:String):String
		return (at != "" ? at + ": " : "") + (fn != "" ? fn + ": " : "") + what + " (kernel: " + rule + ")";

	// ---- proofs

	public static inline var PROOF = "a proof is made only by @:hxmc.unsafe code";

	// the @:hxmc.proof abstract t is, or stands on (an abstract over one), or null
	public static function proofOf(t:T):Null<TAbstract> {
		var depth = 0;
		while (depth++ < 16)
			switch t.follow() {
				case TAbstract(a, pl):
					if (a.aMeta.length > 0 && Lower.hasMeta(":hxmc.proof", a.aMeta)) return a;
					if (core.Meta.has(core.Meta.CoreType, a.aMeta)) return null;
					t = core.TFunctions.applyParams(a.aParams, pl, a.aThis);
				case _:
					return null;
			}
		return null;
	}

	// whether a function of type t takes a proof (GC code cannot call it, nor take it as a value)
	public static function takesProof(t:T):Bool {
		switch t.follow() {
			case TFun(s):
				for (a in s.args)
					if (proofOf(a.type) != null) return true;
			case _:
		}
		return false;
	}

	public static inline var HANDLE = "a handle is made only by a C function or @:hxmc.unsafe code";

	// the kind of value only trusted code makes: a proof or a handle, or null
	static function vouched(t:T):Null<TAbstract> {
		var p = proofOf(t);
		if (p != null) return p;
		var h = CInterop.handleOf(t);
		return h != null ? h.a : null;
	}

	public static inline var TYPED = "a view trusts its value's type: no Dynamic or type parameter where a typed GC value is expected";

	// t loose: Dynamic, a type parameter, or an abstract over one (Any)
	static function loose(t:T):Bool {
		var depth = 0;
		while (depth++ < 16)
			switch t.follow() {
				case TDynamic(_): return true;
				case TInst(c, _): return c.clKind.match(KTypeParameter(_));
				case TAbstract(a, pl) if (!core.Meta.has(core.Meta.CoreType, a.aMeta)):
					t = core.TFunctions.applyParams(a.aParams, pl, a.aThis);
				case _: return false;
			}
		return false;
	}

	// a GC value of a type a view may trust (a String, a class's instance)
	function typed(t:T):Bool
		return !loose(t) && gcType(t);

	// the type src has as its callee declares it: a call's result type before
	// its type parameters are applied (conv<T>(x:Dynamic):T makes any T)
	static function declared(src:TExpr):T
		return switch src.eexpr {
			case TCall({eexpr: TField(_, FStatic(_, cf))}, _):
				switch cf.cfType.follow() {
					case TFun(s): s.ret;
					case _: src.etype;
				}
			case _: src.etype;
		}

	// a value src where one of type t is expected: a proof (a handle) only
	// from one of its kind, a typed GC value only from one of its type
	function flow(t:T, src:TExpr) {
		var p = vouched(t);
		if (p == null && !typed(t)) return;
		switch src.eexpr {
			case TParenthesis(x) | TMeta(_, x):
				flow(t, x);
			case TIf(_, a, b):
				flow(t, a);
				if (b != null) flow(t, b);
			case TBlock(el) if (el.length > 0):
				flow(t, el[el.length - 1]);
			case TSwitch(sw):
				for (c in sw.switchCases)
					flow(t, c.caseExpr);
				if (sw.switchDefault != null) flow(t, sw.switchDefault);
			case _:
				var st = declared(src);
				if (p == null) {
					if (loose(st)) fail(src.epos, "a value of type " + typeName(st) + " as a " + typeName(t), TYPED);
				} else if (vouched(st) != p)
					fail(src.epos, "a value of type " + typeName(st) + " as the " + (proofOf(t) != null ? "proof " : "handle ") + typeName(t), proofOf(t) != null ? PROOF : HANDLE);
		}
	}

	// ---- types

	// hxmc.unsafe's C scalars, values like Int (docs/interop.md, "C interop")
	static final SCALARS = [
		"Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64", "Float32", "USize"
	];

	public static function isScalar(name:String):Bool
		return SCALARS.indexOf(name) >= 0;

	// whether t is raw memory: hxmc.unsafe's types but its C scalars, or an
	// abstract over one (a handle such as an IoBuffer or a Ptr wrapped)
	static inline function inUnsafe(pack:Array<String>):Bool
		return pack.length == 2 && pack[1] == "unsafe" && pack[0] == "hxmc";

	public static function isRaw(t:T):Bool {
		var depth = 0;
		while (depth++ < 16)
			switch t.follow() {
				case TAbstract(a, pl):
					if (inUnsafe(a.aPath.pack) && SCALARS.indexOf(a.aPath.name) < 0) return true;
					// (a handle: a value, also over a Ptr, that only a C result makes)
					if (a.aMeta.length > 0 && Lower.hasMeta(":hxmc.handle", a.aMeta)) return false;
					if (core.Meta.has(core.Meta.CoreType, a.aMeta)) return false;
					// (one abstract at a time: getUnderlyingType goes past Ptr)
					t = core.TFunctions.applyParams(a.aParams, pl, a.aThis);
				case TInst(c, _):
					return inUnsafe(c.clPath.pack) && SCALARS.indexOf(c.clPath.name) < 0 && !CInterop.isStruct(c);
				case _:
					return false;
			}
		return false;
	}

	// a value of type t at p: neither raw memory nor of a GC type
	function value(t:T, p:core.Globals.Pos, what:String):Bool {
		var sp = spanOf(t);
		if (sp != null && proofOf(sp.elem) != null) {
			fail(p, what + " is a span of proofs", PROOF);
			return false;
		}
		if (isRaw(t)) {
			fail(p, what + " has the raw type " + typeName(t), "raw memory needs @:hxmc.unsafe");
			return false;
		}
		if (t.follow().match(TFun(_))) {
			fail(p, what + " is a function", "no closures");
			return false;
		}
		if (Ir.isRef(l.ty(t))) {
			if (loans) return true;
			fail(p, what + " has the GC type " + typeName(t), "no GC values in a blocking kernel");
			return false;
		}
		return true;
	}

	function gcType(t:T):Bool
		return !isRaw(t) && !t.follow().match(TFun(_)) && Ir.isRef(l.ty(t));

	function isGc(e:TExpr):Bool
		return gcType(e.etype);

	static function isNullConst(e:TExpr):Bool
		return switch e.eexpr {
			case TConst(TNull): true;
			case TParenthesis(x) | TMeta(_, x): isNullConst(x);
			case _: false;
		}

	// a GC value read inside (a loan is opaque: its view reads it)
	function opaque(e:TExpr, what:String)
		fail(e.epos, what + " of the GC value " + typeName(e.etype), "a kernel reads a GC value through its view");

	// a scalar: not a struct, not raw, not GC (an unchecked cast between two is a conversion)
	function scalar(t:T):Bool
		return !isRaw(t) && switch l.ty(t) {
			case TI32 | TI64 | TId | TF64 | TBool | TVoid: true;
			case _: false;
		}

	// a vector of hxmc.simd: the V128 struct, or an abstract over it (F32x4,
	// I16x8, ...), whose unchecked casts reinterpret the same 128 bits
	static function isVector(t:T):Bool {
		var depth = 0;
		while (depth++ < 16)
			switch t.follow() {
				case TAbstract(a, pl) if (!core.Meta.has(core.Meta.CoreType, a.aMeta)):
					t = core.TFunctions.applyParams(a.aParams, pl, a.aThis);
				case TInst(c, _):
					return FnLower.isV128(c);
				case _:
					return false;
			}
		return false;
	}

	// a call whose string arguments are literals naming an operation (hxmc.simd's
	// intrinsics, a span's vload and vstore): no string at run time
	static function simdIntrinsic(f:TExpr):Bool
		return switch f.eexpr {
			case TField(_, FStatic(c, cf)):
				core.Globals.sTypePath(c.clPath) == "hxmc.simd.Simd" || (cf.cfName == "vload" || cf.cfName == "vstore") && switch c.clKind {
					case KAbstractImpl(a): isSpanAbstract(a);
					case _: false;
				};
			case _: false;
		}

	// ---- expressions

	// an abstract seen as its own underlying type (an inline method's `this`:
	// what it then reads is checked as any value is); never the other way
	static function toUnderlying(from:T, to:T):Bool
		return switch from.follow() {
			case TAbstract(a, pl) if (!core.Meta.has(core.Meta.CoreType, a.aMeta)):
				core.TUnification.fastEq(core.TFunctions.applyParams(a.aParams, pl, a.aThis).follow(), to.follow());
			case _: false;
		}

	static function isKernelDecl(c:TClass, cf:TClassField):Bool {
		inline function has(ml:core.Ast.Metadata, n:String)
			return ml.length > 0 && Lower.hasMeta(n, ml);
		if (has(cf.cfMeta, ":hxmc.kernel") || has(cf.cfMeta, ":hxmc.blocking") || has(c.clMeta, ":hxmc.kernel")) return true;
		return switch c.clKind {
			case KAbstractImpl(a): has(a.aMeta, ":hxmc.kernel");
			case _: false;
		}
	}

	// Mem's functions of values alone: unsigned comparisons and divisions, bit casts; the target's constants
	public static final PURE_MEM = ["ult", "spanUlt", "udiv", "urem", "f64Bits", "bitsF64", "f32Bits", "bitsF32", "os", "arm", "target", "platform"];

	// the extern functions a safe kernel may call: Math's, Std.int, Struct's
	// layout constants, the target's (hxmc.Platform), Mem's pure ones
	static function allowedExtern(c:TClass, cf:TClassField):Bool {
		switch c.clKind {
			// (a span's accessors; making one from a Ptr needs @:hxmc.unsafe)
			case KAbstractImpl(a) if (isSpanAbstract(a)): return cf.cfName != "unsafeOf";
			case _:
		}
		var path = core.Globals.sTypePath(c.clPath);
		// (hxmc.simd's intrinsics: values; their raw memory accesses need hxmc.unsafe)
		return path == "Math" || (path == "Std" && cf.cfName == "int") || path == "hxmc.unsafe.Struct" || path == "hxmc.Handle" || path == "hxmc.Platform"
			|| path == "hxmc.unsafe.Mem" && PURE_MEM.indexOf(cf.cfName) >= 0
			|| path == "hxmc.simd.Simd" && cf.cfName != "load" && cf.cfName != "store";
	}

	public static inline var STATICS = "a kernel writes statics of plain values only";

	// a plain value: a scalar, or a struct of plain values (a static a kernel may write)
	function plain(t:T, depth = 0):Bool {
		if (isRaw(t) || depth > 8) return false;
		if (scalar(t)) return l.ty(t) != TId;
		return switch t.follow() {
			case TInst(c, _) if (CInterop.isStruct(c)):
				var all = true;
				for (cf in c.clOrderedFields)
					if (cf.cfKind.match(Var(_)) && !plain(cf.cfType, depth + 1)) all = false;
				all;
			case _: false;
		}
	}

	// the static an assignment or increment writes, through struct fields, or null
	static function writtenStatic(e:TExpr):Null<TClassField>
		return switch e.eexpr {
			case TField(_, FStatic(_, cf)): cf;
			case TField(o, FInstance(c, _, _)) if (CInterop.isStruct(c)): writtenStatic(o);
			case TParenthesis(x) | TMeta(_, x): writtenStatic(x);
			case _: null;
		}

	// a static @:hxmc.callback function named as a typed C function's
	// argument: its address, no closure (FnLower.callbackAddr)
	static function callbackRef(a:TExpr):Bool
		return switch a.eexpr {
			case TField(_, FStatic(_, cf)): cf.cfKind.match(Method(_)) && Lower.hasMeta(":hxmc.callback", cf.cfMeta);
			case TParenthesis(x) | TMeta(_, x): callbackRef(x);
			case _: false;
		}

	function call(f:TExpr, args:haxe.ds.Vector<TExpr>, e:TExpr) {
		switch f.eexpr {
			case TField(_, FStatic(c, cf)):
				var name = core.Globals.sTypePath(c.clPath) + "." + cf.cfName;
				if (c.hasClassFlag(CExtern) || cf.cfExpr == null || CInterop.cSymbol(c, cf) != null) {
					// (a typed binding the declaration vouches for: CInterop.plan checked its types)
					if (CInterop.cSymbol(c, cf) != null && CInterop.isSafe(c, cf)) return;
					if (!allowedExtern(c, cf))
						fail(e.epos, "a call of " + name, "Mem, Atomic and C functions need @:hxmc.unsafe");
				} else if (!isKernelDecl(c, cf))
					fail(e.epos, "a call of " + name + ", which is not @:hxmc.kernel", "calls only kernels");
			case TField(_, FInstance(c, _, cf)):
				fail(e.epos, "a call of the method " + core.Globals.sTypePath(c.clPath) + "." + cf.cfName, "calls only static kernels");
			case _:
				fail(e.epos, "a call through a closure or a structural field", "calls only static kernels");
		}
	}

	// a struct's constructor, called by `new`: its body is checked as this
	// function's (once), unless declared a kernel itself
	var ctors:Array<TClass> = [];

	function structCtor(c:TClass) {
		var cf = c.clConstructor;
		if (cf == null || ctors.indexOf(c) >= 0 || isKernelDecl(c, cf)) return;
		ctors.push(c);
		switch cf.cfExpr {
			case {eexpr: TFunction(tf)}:
				for (a in tf.tfArgs)
					value(a.variable.vType, a.variable.vPos, "the parameter " + a.variable.vName + " of " + core.Globals.sTypePath(c.clPath) + ".new");
				expr(tf.tfExpr);
			case _:
		}
	}

	function expr(e:TExpr) {
		switch e.eexpr {
			case TConst(TString(_)):
				if (!loans) fail(e.epos, "a string", "no GC values in a blocking kernel");
				return;
			case TConst(TNull) | TConst(TThis) | TConst(TSuper):
				if (!value(e.etype, e.epos, "this value")) return;
			case TConst(_):
			case TLocal(_) | TBreak | TContinue | TTypeExpr(_):
			case TVar(v, init):
				if (!value(v.vType, e.epos, "the local " + v.vName)) return;
				if (init != null) flow(v.vType, init);
				if (init != null && fromScratch(init)) scratch.set(v.vId, true);
			case TReturn(x) if (x != null && ret != null):
				flow(ret, x);
				if (fromScratch(x)) fail(e.epos, "a span of the frame's scratch (Span.stack) returned", SCRATCH);
			case TFunction(_):
				fail(e.epos, "a closure", "no closures");
				return;
			case TThrow(_):
				fail(e.epos, "a throw", "no exceptions: errors are results");
				return;
			case TTry(_):
				fail(e.epos, "a try block", "no exceptions: errors are results");
				return;
			case TIdent(n):
				fail(e.epos, "untyped code (" + n + ")", "no untyped code");
				return;
			case TObjectDecl(_) | TArrayDecl(_) | TEnumParameter(_) | TEnumIndex(_):
				if (!value(e.etype, e.epos, "this value")) return;
				fail(e.epos, "an object, array or enum value", "no GC values");
				return;
			case TNew(c, _, _):
				if (!CInterop.isStruct(c)) {
					fail(e.epos, "new " + core.Globals.sTypePath(c.clPath), "no GC values: only @:hxmc.struct values");
					return;
				}
				structCtor(c);
			case TCall(f, args):
				call(f, args, e);
				switch f.etype.follow() {
					case TFun(s):
						for (i in 0...args.length)
							if (i < s.args.length) flow(s.args[i].type, args[i]);
					case _:
				}
				if (!value(e.etype, e.epos, "the result of this call")) return;
				// (the callee is no value: its arguments only)
				var named = simdIntrinsic(f);
				for (a in args)
					// (null for a typed C call's Null<F> callback: NULL)
					if (!(named && a.eexpr.match(TConst(TString(_)))) && !callbackRef(a) && !(isNullConst(a) && a.etype.follow().match(TFun(_))))
						expr(a);
				switch f.eexpr {
					case TField(o, _): expr(o);
					case _:
				}
				return;
			case TField(o, fa):
				switch fa {
					case FStatic(_) | FInstance(_):
					case FClosure(_):
						fail(e.epos, "a method as a closure", "no closures");
						return;
					case FAnon(_) | FDynamic(_):
						fail(e.epos, "a structural or dynamic field", "no GC values");
						return;
					case FEnum(_):
				}
				if (!value(e.etype, e.epos, "this field")) return;
				switch fa {
					case FInstance(c, _, cf) if (!CInterop.isStruct(c) && isGc(o)):
						opaque(o, "the field " + cf.cfName);
						return;
					case _:
				}
			case TArray(a, _):
				if (!value(a.etype, a.epos, "this array")) return;
				if (isGc(a)) {
					opaque(a, "an element");
					return;
				}
			case TBinop(op, a, b) if (loans && op != OpAssign && (isGc(a) || isGc(b))):
				if (!(op.match(OpEq | OpNotEq) && (isNullConst(a) || isNullConst(b)))) {
					opaque(isGc(a) ? a : b, "an operation on");
					return;
				}
			case TUnop(_, _, x) if (loans && isGc(x)):
				opaque(x, "an operation on");
				return;
			case TCast(x, null) if (proofOf(e.etype) != null && proofOf(x.etype) != proofOf(e.etype)):
				fail(e.epos, "a cast from " + typeName(x.etype) + " to the proof " + typeName(e.etype), PROOF);
				return;
			case TCast(x, null) if (CInterop.handleOf(e.etype) != null && vouched(x.etype) != vouched(e.etype)):
				fail(e.epos, "a cast from " + typeName(x.etype) + " to the handle " + typeName(e.etype), HANDLE);
				return;
			case TCast(x, null):
				if (!(scalar(x.etype) && scalar(e.etype)) && !core.TUnification.fastEq(x.etype.follow(), e.etype.follow()) && !toUnderlying(x.etype, e.etype)
					&& !(isVector(x.etype) && isVector(e.etype))) {
					fail(e.epos, "an unchecked cast from " + typeName(x.etype) + " to " + typeName(e.etype), "unchecked casts only between scalars");
					return;
				}
			case TCast(_, _):
				fail(e.epos, "a checked cast", "no GC values");
				return;
			case TBinop(OpAssign | OpAssignOp(_), lhs, rhs):
				flow(lhs.etype, rhs);
				switch lhs.eexpr {
					case TLocal(v) if (fromScratch(rhs)): scratch.set(v.vId, true);
					case _:
				}
				var s = writtenStatic(lhs);
				if (s != null && !plain(s.cfType)) fail(e.epos, "a write of the static " + s.cfName + " of the type " + typeName(s.cfType), STATICS);
			case TUnop(Increment | Decrement, _, x):
				var s = writtenStatic(x);
				if (s != null && !plain(s.cfType)) fail(e.epos, "a write of the static " + s.cfName + " of the type " + typeName(s.cfType), STATICS);
			case _:
		}
		core.Texpr.iter(expr, e);
	}
}
