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
//   - no value of a GC type (an object, String, Array, closure, enum value,
//     anonymous object, Dynamic, Null<T>, an erased type parameter);
//   - no raw memory: no value of hxmc.unsafe's types but its C scalars
//     (Ptr, IoBuffer, Arena, CString, Slice, ...) nor of an abstract over
//     one, no call of Mem, Atomic, Callback or a C function;
//   - no unchecked cast but between scalars;
//   - no write of a static (reading one is fine);
//   - no closure, no call but of static @:hxmc.kernel functions, Math's
//     and Std.int; no throw, no try, no untyped code.
class KernelCheck {
	var l:LowerQueries;
	var fi:FuncInfo;
	var errors:Array<String> = [];
	var seen = new Map<String, Bool>();

	function new(l, fi) {
		this.l = l;
		this.fi = fi;
	}

	// the violations of fi's body tf (an error listing them all), or nothing
	public static function check(l:LowerQueries, fi:FuncInfo, tf:TFunc) {
		var c = new KernelCheck(l, fi);
		for (a in tf.tfArgs)
			c.value(a.variable.vType, a.variable.vPos, "the parameter " + a.variable.vName);
		c.value(tf.tfType, fi.pos, "the result");
		c.expr(tf.tfExpr);
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

	// ---- types

	// hxmc.unsafe's C scalars, values like Int (docs/interop.md, "C interop")
	static final SCALARS = [
		"Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64", "Float32"
	];

	// whether t is raw memory: hxmc.unsafe's types but its C scalars, or an
	// abstract over one (a handle such as an IoBuffer or a Ptr wrapped)
	static function isRaw(t:T):Bool {
		var depth = 0;
		while (depth++ < 16)
			switch t.follow() {
				case TAbstract(a, pl):
					if (a.aPath.pack.join(".") == "hxmc.unsafe" && SCALARS.indexOf(a.aPath.name) < 0) return true;
					if (core.Meta.has(core.Meta.CoreType, a.aMeta)) return false;
					// (one abstract at a time: getUnderlyingType goes past Ptr)
					t = core.TFunctions.applyParams(a.aParams, pl, a.aThis);
				case TInst(c, _):
					return c.clPath.pack.join(".") == "hxmc.unsafe" && SCALARS.indexOf(c.clPath.name) < 0 && !CInterop.isStruct(c);
				case _:
					return false;
			}
		return false;
	}

	// a value of type t at p: neither raw memory nor of a GC type
	function value(t:T, p:core.Globals.Pos, what:String):Bool {
		if (isRaw(t)) {
			fail(p, what + " has the raw type " + typeName(t), "raw memory needs @:hxmc.unsafe");
			return false;
		}
		if (t.follow().match(TFun(_))) {
			fail(p, what + " is a function", "no closures");
			return false;
		}
		if (Ir.isRef(l.ty(t))) {
			fail(p, what + " has the GC type " + typeName(t), "no GC values");
			return false;
		}
		return true;
	}

	// a scalar: not a struct, not raw, not GC (an unchecked cast between two is a conversion)
	function scalar(t:T):Bool
		return !isRaw(t) && switch l.ty(t) {
			case TI32 | TI64 | TId | TF64 | TBool | TVoid: true;
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

	// the extern functions a safe kernel may call: Math's, Std.int, Struct's layout constants
	static function allowedExtern(c:TClass, cf:TClassField):Bool {
		switch c.clKind {
			// (a span's accessors; making one from a Ptr needs @:hxmc.unsafe)
			case KAbstractImpl(a) if (isSpanAbstract(a)): return cf.cfName != "unsafeOf";
			case _:
		}
		var path = core.Globals.sTypePath(c.clPath);
		return path == "Math" || (path == "Std" && cf.cfName == "int") || path == "hxmc.unsafe.Struct";
	}

	// the static an assignment or increment writes, through struct fields, or null
	static function writtenStatic(e:TExpr):Null<TClassField>
		return switch e.eexpr {
			case TField(_, FStatic(_, cf)): cf;
			case TField(o, FInstance(c, _, _)) if (CInterop.isStruct(c)): writtenStatic(o);
			case TParenthesis(x) | TMeta(_, x): writtenStatic(x);
			case _: null;
		}

	function call(f:TExpr, args:haxe.ds.Vector<TExpr>, e:TExpr) {
		switch f.eexpr {
			case TField(_, FStatic(c, cf)):
				var name = core.Globals.sTypePath(c.clPath) + "." + cf.cfName;
				if (c.hasClassFlag(CExtern) || cf.cfExpr == null || CInterop.cSymbol(c, cf) != null) {
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
				fail(e.epos, "a string", "no GC values");
				return;
			case TConst(TNull) | TConst(TThis) | TConst(TSuper):
				if (!value(e.etype, e.epos, "this value")) return;
			case TConst(_):
			case TLocal(_) | TBreak | TContinue | TTypeExpr(_):
			case TVar(v, _):
				if (!value(v.vType, e.epos, "the local " + v.vName)) return;
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
				if (!value(e.etype, e.epos, "the result of this call")) return;
				// (the callee is no value: its arguments only)
				for (a in args)
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
			case TArray(a, _):
				if (!value(a.etype, a.epos, "this array")) return;
			case TCast(x, null):
				if (!(scalar(x.etype) && scalar(e.etype)) && !core.TUnification.fastEq(x.etype.follow(), e.etype.follow()) && !toUnderlying(x.etype, e.etype)) {
					fail(e.epos, "an unchecked cast from " + typeName(x.etype) + " to " + typeName(e.etype), "unchecked casts only between scalars");
					return;
				}
			case TCast(_, _):
				fail(e.epos, "a checked cast", "no GC values");
				return;
			case TBinop(OpAssign | OpAssignOp(_), lhs, _):
				var s = writtenStatic(lhs);
				if (s != null) fail(e.epos, "a write of the static " + s.cfName, "statics are read-only in kernels");
			case TUnop(Increment | Decrement, _, x):
				var s = writtenStatic(x);
				if (s != null) fail(e.epos, "a write of the static " + s.cfName, "statics are read-only in kernels");
			case _:
		}
		core.Texpr.iter(expr, e);
	}
}
