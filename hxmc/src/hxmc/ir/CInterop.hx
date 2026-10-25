package hxmc.ir;

import core.Ast.Binop;
import core.Ast.Unop;
import core.TType;
import core.TFunctions;
import hxmc.ir.Lower.LowerError;

using core.TFunctions;

// C interop (docs/plans/lowlevel.md, "C interop"): the C type of a Haxe type in
// extern signatures, struct fields and pointer accesses, the C layout of
// @:hxmc.struct classes, and what the program's C externs are (filled while
// lowering, read by MirBuild and the linkers).
enum CTy {
	CVoid;
	CBool; // C's bool: one byte
	CI8;
	CU8;
	CI16;
	CU16;
	CI32; // int, int32_t, uint32_t (Haxe's Int and UInt)
	CI64; // int64_t, uint64_t, size_t
	CF32;
	CF64;
	CPtr; // any pointer (Ptr<T>, CString)
	CStruct(c:TClass);
	COpaque(c:TClass);
	CNone; // no C type (a GC reference, Dynamic, ...)
}

typedef CField = {name:String, off:Int, ty:CTy, t:T};
typedef CLayout = {size:Int, align:Int, fields:Array<CField>};

// the C signature of an extern: the argument and result types
typedef CSig = {args:Array<CTy>, ret:CTy};

class CInterop {
	// C functions by symbol: their signature (one per symbol: every
	// declaration must agree), and the ones called in a safe region (the
	// externs not declared @:hxmc.fast: MirBuild wraps their calls in
	// rt_blocking_enter/rt_blocking_leave)
	public static var SIGS = new Map<String, CSig>();
	public static var BLOCKING = new Map<String, Bool>();
	// @:hxmc.lib: the library a symbol comes from (a DLL, a dylib, a
	// WebAssembly import module)
	public static var LIBS = new Map<String, String>();
	// the externs of the program's own code (not hxmc's runtime): on
	// WebAssembly, imports
	public static var USER = new Map<String, Bool>();
	// @:hxmc.link: objects and archives the program names (absolute paths)
	public static var LINKS:Array<String> = [];
	// the prefix of the keys of @:hxmc.indirect externs (calls through a function
	// pointer, their first argument): not a symbol
	public static inline var INDIRECT = "@indirect:";

	// the C functions declared, forgotten: a program's lowering starts so
	// (Lower), each of its bodies declaring those it calls, also a body the
	// compilation server replays (Lower.cExtern)
	public static function reset() {
		SIGS = new Map();
		BLOCKING = new Map();
		LIBS = new Map();
		USER = new Map();
		FnLower.C_EXTERNS = new Map();
		FnLower.C_VARIADIC = new Map();
	}

	// (-D hxmc.wasm-gc: a struct whose fields are all final is an object, there
	// being no copy to tell from it; the others live in the linear memory; a
	// scoped class is an object copied where a struct would be: isWasmValue)
	public static function isStruct(c:TClass):Bool
		return c.clMeta.length > 0 && Lower.hasMeta(":hxmc.struct", c.clMeta) && !(Lower.wasmGc && immutable(c)) || !Lower.wasmGc && isScopedValue(c);

	// -D hxmc.wasm-gc: a scoped class (a struct value elsewhere), an object
	// copied where a struct value is copied (valueCopies)
	public static function isWasmValue(c:TClass):Bool
		return Lower.wasmGc && isScopedValue(c);

	// a @:hxmc.scoped class with variables or a constructor is a struct value
	// (docs/plans/lowlevel.md, "Scoped memory"); one of static functions only
	// is not (its functions are scoped code)
	public static function isScopedValue(c:TClass):Bool {
		if (!core.HxmcScoped.isClass(c) || c.clKind.match(KModuleFields(_))) return false;
		if (c.clConstructor != null) return true;
		for (cf in c.clOrderedFields)
			if (cf.cfKind.match(Var(_))) return true;
		return false;
	}

	// ---- scoped enums: value enums (docs/plans/lowlevel.md, "Scoped enums"),
	// lowered as struct values of a class made for them: a 32-bit tag at 0,
	// each constructor's arguments from the payload's start (overlapping),
	// copied and compared as 8-byte words

	public static function isScopedEnum(en:TEnum):Bool
		return core.HxmcScoped.isEnum(en);

	static var enumStructs = new Map<TEnum, TClass>();
	// per scoped enum: each constructor's arguments (by index), at their offsets
	static var enumArgs = new Map<TEnum, Array<Array<CField>>>();

	// the struct class of scoped enum en
	public static function enumStruct(en:TEnum):TClass {
		var c = enumStructs.get(en);
		if (c != null) return c;
		var where = en.ePath.name;
		if (en.eParams.length > 0) throw new LowerError('@:hxmc.scoped enum $where cannot have type parameters', posOf(en.ePos));
		if (inProgress.exists(cast en)) throw new LowerError('@:hxmc.scoped enum $where contains itself (use a Ref)', posOf(en.ePos));
		inProgress.set(cast en, true);
		var payload = 4;
		var ctors:Array<Array<CField>> = [];
		for (name in en.eNames) {
			var ef = en.eConstrs.get(name);
			var fields:Array<CField> = [];
			var off = 0;
			switch TFunctions.follow(ef.efType) {
				case TFun(s):
					for (a in s.args) {
						var ct = ctype(a.type);
						switch ct {
							case CStruct(_) | CBool | CI8 | CU8 | CI16 | CU16 | CI32 | CI64 | CF32 | CF64 | CPtr:
							case _: throw new LowerError('@:hxmc.scoped enum $where: ${ef.efName}: the argument ${a.name} is no value type (scalars, Ptr, scoped and struct values)', posOf(ef.efPos));
						}
						var al = alignOf(ct);
						off = (off + al - 1) & ~(al - 1);
						fields.push({name: a.name, off: off, ty: ct, t: a.type});
						off += sizeOf(ct);
						if (al > payload) payload = al;
					}
				case _:
			}
			ctors[ef.efIndex] = fields;
		}
		inProgress.remove(cast en);
		// (the payload starts at 4 when no argument needs more alignment)
		var end = 0;
		for (fields in ctors)
			if (fields != null)
				for (f in fields) {
					f.off += payload;
					if (f.off + sizeOf(f.ty) > end) end = f.off + sizeOf(f.ty);
				}
		var size = (end + 7) & ~7;
		if (size < 8) size = 8;
		var c = TFunctions.mkClass(en.eModule, en.ePath, en.ePos, en.ePos);
		var words:Array<CField> = [for (k in 0...(size >> 3)) {name: "w" + k, off: 8 * k, ty: CI64, t: null}];
		layouts.set(c, {size: size, align: 8, fields: words});
		enumStructs.set(en, c);
		enumArgs.set(en, ctors);
		return c;
	}

	// argument i of constructor ef of scoped enum en: its offset and C type
	public static function enumArg(en:TEnum, ef:TEnumField, i:Int):CField {
		enumStruct(en);
		return enumArgs.get(en)[ef.efIndex][i];
	}

	static function immutable(c:TClass):Bool {
		for (cf in c.clOrderedFields)
			if (cf.cfKind.match(Var(_)) && !cf.hasClassFieldFlag(CfFinal)) return false;
		return true;
	}

	// Haxe's inline constructors (a filter) turn an object of a class with an
	// inline constructor into locals shared by every variable it is assigned
	// to: right for an object, wrong for a struct value (`var b = a; b.x = 1`
	// would change a). For hxmc, a @:hxmc.struct class's constructor is an
	// ordinary function, set once typing is done, before the filters (Mir
	// inlines it, and Sroa keeps the struct in registers).
	//
	// Haxe's inliner passes a local (or a field) argument of an inline
	// function into the inlined body as itself; the analyzer replaces a
	// variable initialized from another by that one (fusion, copy
	// propagation). Both are right for references, wrong for struct values,
	// whose copies are separate: where an inlined body writes through a
	// struct parameter (a field, a compound assignment, the parameter passed
	// on as an abstract's `this`), the argument is copied into a temporary
	// first (Inline.copyArgumentHook), and a struct variable initialized
	// from a place stays a copy (AnalyzerTexpr.keepCopyHook). Programs
	// without struct values are compiled exactly as before.
	public static function install() {
		var prev = compiler.Compiler.beforeTypingHook;
		compiler.Compiler.beforeTypingHook = function(com, actx) {
			if (prev != null) prev(com, actx);
			var on = com.platform.match(CustomTarget("hxmc"));
			optimization.Inline.copyArgumentHook = on ? copyArgument : null;
			optimization.AnalyzerTexpr.keepCopyHook = on ? keepCopy : null;
			if (!on) return;
			com.callbacks.addAfterTyping(types -> {
				for (t in types)
					switch t {
						// (one whose fields are all final keeps it: no copy can be told from another)
						case TClassDecl(c) if (c.clConstructor != null && c.clConstructor.cfKind.match(Method(MethInline)) && (isStruct(c) || isWasmValue(c)) && !immutable(c)):
							c.clConstructor.cfKind = Method(MethNormal);
						case _:
					}
			});
		}
	}

	// a struct value: a @:hxmc.struct class, or an abstract over one (not
	// Null<S>, a box)
	public static function isStructValue(t:T):Bool {
		for (_ in 0...16)
			switch TFunctions.followWithoutNull(t) {
				case TAbstract(a, params) if (isFixed(a) && isFixedConst(params)):
					return !Lower.wasmGc;
				case TInst(c, _):
					return isStruct(c) || isWasmValue(c);
				case TEnum(en, _):
					return isScopedEnum(en) && !Lower.wasmGc;
				case TAbstract(a, params) if (!core.Meta.has(CoreType, a.aMeta) && !core.Meta.has(MultiType, a.aMeta)):
					t = TFunctions.applyParams(a.aParams, params, a.aThis);
				case _:
					return false;
			}
		return false;
	}

	static function strip(e:TExpr):TExpr
		return switch e.eexpr {
			case TParenthesis(e1) | TMeta(_, e1) | TCast(e1, null): strip(e1);
			case _: e;
		}

	// a new value (a call's result, a constructed one): nothing to copy
	static function fresh(e:TExpr):Bool
		return switch strip(e).eexpr {
			case TConst(TThis): false;
			case TNew(_, _, _) | TCall(_, _) | TConst(_) | TObjectDecl(_): true;
			case _: false;
		}

	// e is v or a field of it (of a field of it...)
	static function placeOf(v:TVar, e:TExpr):Bool
		return switch strip(e).eexpr {
			case TLocal(w): w == v;
			case TField(e1, _): placeOf(v, e1);
			case _: false;
		}

	// does body write v or a field of it: an assignment, an increment, v
	// passed as `this` to an inline abstract method still a call
	public static function writesThrough(v:TVar, body:TExpr):Bool {
		function loop(e:TExpr):Bool
			return switch e.eexpr {
				case TBinop(OpAssign | OpAssignOp(_), e1, _) | TUnop(Increment | Decrement, _, e1) if (placeOf(v, e1)):
					true;
				case TCall({eexpr: TField(_, FStatic({clKind: KAbstractImpl(_)}, cf))}, args) if (args.length > 0 && cf.cfKind.match(Method(MethInline))
					&& TFunctions.hasClassFieldFlag(cf, CfImpl) && placeOf(v, args[0])):
					true;
				case _: core.Texpr.checkExpr(loop, e);
			}
		return loop(body);
	}

	// -D hxmc.wasm-gc: a value of a scoped class copied where it is copied
	// from a place (a variable, a field, an element) into another: a variable
	// or a field set, an argument, a result, a constructor's argument (not a
	// value just made: new, a call's result, which the callee copied); a
	// scoped enum's values compared by value (Type.enumEq), as linear memory's
	// are
	public static var objCopy:Null<{c:TClass, cf:TClassField}> = null;

	static function isWasmValueType(t:T):Bool {
		for (_ in 0...16)
			switch TFunctions.followWithoutNull(t) {
				case TInst(c, _):
					return isWasmValue(c);
				case TAbstract(a, params) if (isFixed(a) && isFixedConst(params)):
					return Lower.wasmGc;
				case TAbstract(a, params) if (!core.Meta.has(CoreType, a.aMeta) && !core.Meta.has(MultiType, a.aMeta)):
					t = TFunctions.applyParams(a.aParams, params, a.aThis);
				case _:
					return false;
			}
		return false;
	}

	static function isScopedEnumType(t:T):Bool
		return switch TFunctions.followWithoutNull(t) {
			case TEnum(en, _): isScopedEnum(en);
			case _: false;
		}

	// an expression that reads a place (an array element read by unsafeGet too)
	static function isPlace(e:TExpr):Bool
		return switch strip(e).eexpr {
			case TLocal(_) | TField(_, _) | TArray(_, _) | TConst(TThis): true;
			case TCall({eexpr: TField(_, FInstance(c, _, cf))}, _): Lower.isNativeArray(c) && cf.cfName == "unsafeGet";
			case TCast(e1, _): isPlace(e1);
			case TBlock(es) if (es.length > 0): isPlace(es[es.length - 1]);
			case _: false;
		}

	public static function valueCopies(e:TExpr):TExpr {
		if (objCopy == null) return e;
		function copy(x:TExpr):TExpr {
			if (!isWasmValueType(x.etype) || !isPlace(x)) return x;
			// (a Fixed: its array copied, Fixed.copyOf)
			switch TFunctions.followWithoutNull(x.etype) {
				case TAbstract(a, _) if (isFixed(a) && a.aImpl != null):
					var cf = a.aImpl.clStatics.get("copyOf");
					var f = TFunctions.mk(TField(TFunctions.mk(TTypeExpr(TClassDecl(a.aImpl)), TDynamic(null), x.epos), FStatic(a.aImpl, cf)), cf.cfType, x.epos);
					return TFunctions.mk(TCast(TFunctions.mk(TCall(f, core.ds.VectorTools.vector(x)), TDynamic(null), x.epos), null), x.etype, x.epos);
				case _:
			}
			var w = objCopy;
			var f = TFunctions.mk(TField(TFunctions.mk(TTypeExpr(TClassDecl(w.c)), TDynamic(null), x.epos), FStatic(w.c, w.cf)), w.cf.cfType, x.epos);
			return TFunctions.mk(TCast(TFunctions.mk(TCall(f, core.ds.VectorTools.vector(x)), TDynamic(null), x.epos), null), x.etype, x.epos);
		}
		function map(e:TExpr):TExpr {
			var e = core.Texpr.mapExpr(map, e);
			return switch e.eexpr {
				case TVar(v, init) if (init != null && isWasmValueType(v.vType)):
					TFunctions.mk(TVar(v, copy(init)), e.etype, e.epos);
				case TBinop(OpAssign, lhs, rhs) if (isWasmValueType(lhs.etype)):
					TFunctions.mk(TBinop(OpAssign, lhs, copy(rhs)), e.etype, e.epos);
				case TCall(f, args):
					TFunctions.mk(TCall(f, args.map(copy)), e.etype, e.epos);
				case TNew(c, ps, args):
					TFunctions.mk(TNew(c, ps, args.map(copy)), e.etype, e.epos);
				case TReturn(x) if (x != null):
					TFunctions.mk(TReturn(copy(x)), e.etype, e.epos);
				case TArrayDecl(xs):
					TFunctions.mk(TArrayDecl(xs.map(copy)), e.etype, e.epos);
				case TBinop(op = OpEq | OpNotEq, a, b) if (isScopedEnumType(a.etype) && isScopedEnumType(b.etype)):
					var w = objCopy.c, eq = objCopy.c.clStatics.get("enumEq");
					var f = TFunctions.mk(TField(TFunctions.mk(TTypeExpr(TClassDecl(w)), TDynamic(null), e.epos), FStatic(w, eq)), eq.cfType, e.epos);
					var c = TFunctions.mk(TCall(f, core.ds.VectorTools.vector(a, b)), e.etype, e.epos);
					op == OpEq ? c : TFunctions.mk(TUnop(Not, Prefix, c), e.etype, e.epos);
				case _: e;
			}
		}
		return map(e);
	}

	static function copyArgument(v:TVar, arg:TExpr, body:TExpr):Bool
		return isStructValue(v.vType) && !fresh(arg) && writesThrough(v, body);

	static function keepCopy(t:T, e:TExpr):Bool
		return isStructValue(t) && !fresh(e);

	// ---- hxmc.scoped.Fixed<T, N> (docs/plans/lowlevel.md, "Types"): linearly
	// a struct value of N elements of T, its class made for it here; on WasmGC
	// the engine's array (copied: valueCopies)

	public static function isFixed(a:TAbstract):Bool
		return a.aPath.name == "Fixed" && a.aPath.pack.length == 2 && a.aPath.pack[0] == "hxmc" && a.aPath.pack[1] == "scoped";

	// T and N of a Fixed type, or null
	public static function fixedOf(t:T):Null<{elem:T, n:Int}> {
		return switch TFunctions.followWithoutNull(t) {
			case TAbstract(a, params) if (isFixed(a) && isFixedConst(params)):
				{elem: params[0], n: fixedLength(params[1], a)};
			case _: null;
		}
	}

	// whether N is a constant (not the abstract's own parameter, in its functions)
	public static function isFixedConst(params:core.TType.TParams):Bool
		return params.length == 2 && switch TFunctions.follow(params[1]) {
			case TInst({clKind: KTypeParameter(_)}, _): false;
			case _: true;
		};

	static function fixedLength(nt:T, a:TAbstract):Int {
		switch TFunctions.follow(nt) {
			case TInst({clKind: KExpr({expr: EConst(core.Ast.Constant.Int(v, _))})}, _):
				var n = Std.parseInt(v);
				if (n != null && n > 0) return n;
			case _:
		}
		throw new LowerError('Fixed<T, N>: N must be a positive Int constant (' + core.TPrinting.sType(core.TPrinting.printContext(), nt) + ')', posOf(a.aPos));
	}

	static var fixedStructs = new Map<String, TClass>();

	// the struct class of Fixed<T, N>: its elements, each at a multiple of
	// T's size (scalars as 8-byte words: copied and zeroed so)
	public static function fixedStruct(a:TAbstract, params:core.TType.TParams):TClass {
		var et = params[0], n = fixedLength(params[1], a);
		var ct = ctype(et);
		var where = 'Fixed<' + core.TPrinting.sType(core.TPrinting.printContext(), et) + ', ' + n + '>';
		switch ct {
			case CStruct(_) | CBool | CI8 | CU8 | CI16 | CU16 | CI32 | CI64 | CF32 | CF64:
			case _: throw new LowerError(where + ': its elements are scalars or struct values (not Ptr, references or GC types)', posOf(a.aPos));
		}
		if (Scoped.holdsRefs(et) || Scoped.holdsScoped(et)) throw new LowerError(where + ': its elements hold references (a Slice, a Str, a Ref): a Grow of them instead', posOf(a.aPos));
		var key = name(ct) + ':' + (switch ct { case CStruct(sc): core.Globals.sTypePath(sc.clPath); case _: ''; }) + ':' + n;
		var c = fixedStructs.get(key);
		if (c != null) return c;
		var es = sizeOf(ct), al = alignOf(ct);
		if (al < 8) al = 8;
		var size = (n * es + 7) & ~7;
		var fields:Array<CField> = switch ct {
			case CStruct(_): [for (k in 0...n) {name: 'e' + k, off: k * es, ty: ct, t: et}];
			case _: [for (k in 0...(size >> 3)) {name: 'w' + k, off: 8 * k, ty: CI64, t: null}];
		};
		c = TFunctions.mkClass(a.aModule, {pack: ['hxmc', 'scoped'], name: 'Fixed_' + key.split(':').join('_').split('.').join('_')}, a.aPos, a.aPos);
		layouts.set(c, {size: size, align: al, fields: fields});
		fixedStructs.set(key, c);
		return c;
	}

	public static function isOpaque(c:TClass):Bool
		return Lower.hasMeta(":hxmc.opaque", c.clMeta);

	// a class whose values are addresses of C memory (struct or opaque)
	public static function isNativeClass(c:TClass):Bool
		return isStruct(c) || isOpaque(c);

	static function path(a:TAbstract):String
		return a.aPath.pack.length == 0 ? a.aPath.name : a.aPath.pack.join(".") + "." + a.aPath.name;

	public static function ctype(t:T):CTy {
		var t = TFunctions.follow(t);
		return switch t {
			case TAbstract(a, params):
				switch path(a) {
					case "hxmc.unsafe.Int8": CI8;
					case "hxmc.unsafe.UInt8": CU8;
					case "hxmc.unsafe.Int16": CI16;
					case "hxmc.unsafe.UInt16": CU16;
					case "hxmc.unsafe.Float32": CF32;
					case "hxmc.unsafe.UInt64" | "hxmc.I64": CI64;
					case "hxmc.unsafe.Ptr" | "hxmc.unsafe.CString" | "hxmc.unsafe.Arena": CPtr;
					case "Int" | "UInt": CI32;
					case "Bool": CBool;
					case "Float": CF64;
					case "Void": CVoid;
					case "Null" | "Any" | "Class" | "Enum" | "EnumValue": CNone;
					case "hxmc.scoped.Fixed" if (!Lower.wasmGc && isFixedConst(params)): CStruct(fixedStruct(a, params));
					case _:
						if (core.Meta.has(CoreType, a.aMeta)) CNone else ctype(core.Abstract.getUnderlyingType(a, params));
				}
			case TInst(c, _):
				if (isStruct(c)) CStruct(c) else if (isOpaque(c)) COpaque(c) else CNone;
			case TEnum(en, _) if (isScopedEnum(en) && !Lower.wasmGc):
				CStruct(enumStruct(en));
			case _: CNone;
		}
	}

	// the element type of a Ptr<T> (or CString: UInt8)
	public static function ptrElem(t:T):Null<T> {
		return switch TFunctions.follow(t) {
			case TAbstract(a, [e]) if (path(a) == "hxmc.unsafe.Ptr"): e;
			case TAbstract(a, params) if (!core.Meta.has(CoreType, a.aMeta)): ptrElem(core.Abstract.getUnderlyingType(a, params));
			case _: null;
		}
	}

	public static function isScalar(c:CTy):Bool
		return switch c {
			case CBool | CI8 | CU8 | CI16 | CU16 | CI32 | CI64 | CF32 | CF64 | CPtr: true;
			case _: false;
		}

	public static function sizeOf(c:CTy):Int
		return switch c {
			case CBool | CI8 | CU8: 1;
			case CI16 | CU16: 2;
			case CI32 | CF32: 4;
			case CI64 | CF64 | CPtr: 8;
			case CStruct(s): layout(s).size;
			case _: 0;
		}

	public static function alignOf(c:CTy):Int
		return switch c {
			case CStruct(s): layout(s).align;
			case _: sizeOf(c);
		}

	public static function name(c:CTy):String
		return switch c {
			case CStruct(s) | COpaque(s): s.clPath.name;
			case _: c.getName().substr(1).toLowerCase();
		}

	static var layouts = new Map<TClass, CLayout>();
	static var inProgress = new Map<TClass, Bool>();

	// a new program (Lower): the caches hold the last one's classes and files
	// (a server's builds: they would keep its modules, and a file's lines change)
	public static function resetCaches() {
		layouts = new Map();
		inProgress = new Map();
		enumStructs = new Map();
		enumArgs = new Map();
		fixedStructs = new Map();
		lineCache = new Map();
	}

	// the C layout of a @:hxmc.struct class: its variables in order, each at
	// the next multiple of its alignment; the size a multiple of the largest
	// alignment (the same on the six 64-bit targets: no type here differs)
	public static function layout(c:TClass):CLayout {
		var l = layouts.get(c);
		if (l != null) return l;
		var where = c.clPath.name;
		if (inProgress.exists(c)) throw new LowerError('@:hxmc.struct $where contains itself (use a Ptr)', posOf(c.clPos));
		if (c.clParams.length > 0) throw new LowerError('@:hxmc.struct $where cannot have type parameters', posOf(c.clPos));
		if (c.clSuper != null) throw new LowerError('@:hxmc.struct $where cannot extend a class', posOf(c.clPos));
		if (c.clImplements.length > 0) throw new LowerError('@:hxmc.struct $where cannot implement an interface (its values are not objects)', posOf(c.clPos));
		inProgress.set(c, true);
		var off = 0, align = 1;
		var fields:Array<CField> = [];
		for (cf in c.clOrderedFields) {
			switch cf.cfKind {
				case Var(_):
				case Method(_): throw new LowerError('@:hxmc.struct $where: ${cf.cfName}: a struct has no methods (yet)', posOf(cf.cfPos));
			}
			var ct = ctype(cf.cfType);
			switch ct {
				case COpaque(o): throw new LowerError('@:hxmc.struct $where: ${cf.cfName}: an opaque type (${o.clPath.name}) only stands behind a Ptr', posOf(cf.cfPos));
				case CNone | CVoid: throw new LowerError('@:hxmc.struct $where: ${cf.cfName} has no C type (scalars, Ptr, CString and structs only)', posOf(cf.cfPos));
				case _:
			}
			var a = alignOf(ct);
			off = (off + a - 1) & ~(a - 1);
			fields.push({name: cf.cfName, off: off, ty: ct, t: cf.cfType});
			off += sizeOf(ct);
			if (a > align) align = a;
		}
		inProgress.remove(c);
		l = {size: (off + align - 1) & ~(align - 1), align: align, fields: fields};
		layouts.set(c, l);
		return l;
	}

	public static function field(c:TClass, name:String):CField {
		for (f in layout(c).fields)
			if (f.name == name) return f;
		throw new LowerError('@:hxmc.struct ${c.clPath.name} has no field $name', posOf(c.clPos));
	}

	// file:line of a position (for errors)
	public static function posOf(p:core.Globals.Pos):String {
		if (p == null || p.pfile == null || p.pfile == "?") return "";
		return p.pfile + ":" + lineOf(p.pfile, p.pmin);
	}

	static var lineCache = new Map<String, Array<Int>>();

	public static function lineOf(file:String, pmin:Int):Int {
		var starts = lineCache.get(file);
		if (starts == null) {
			starts = [0];
			try {
				var s = sys.io.File.getBytes(file);
				for (i in 0...s.length)
					if (s.get(i) == 10) starts.push(i + 1);
			} catch (_:Dynamic) {}
			lineCache.set(file, starts);
		}
		var lo = 0, hi = starts.length - 1;
		while (lo < hi) {
			var mid = (lo + hi + 1) >> 1;
			if (starts[mid] <= pmin) lo = mid else hi = mid - 1;
		}
		return lo + 1;
	}

	// ---- externs

	// the C symbol of an extern function: @:hxmc.c("symbol") on the field,
	// or @:hxmc.c on the field or its class (the field's @:native name, or
	// its own name); null: not a C function
	public static function cSymbol(c:TClass, cf:TClassField):Null<String> {
		var m = core.Meta.getOpt(Custom(":hxmc.c"), cf.cfMeta);
		if (m != null) {
			var s = Lower.metaArg(m);
			if (s != null) return s;
		} else if (!Lower.hasMeta(":hxmc.c", c.clMeta)) return null;
		var n = Lower.metaArg(core.Meta.getOpt(Native, cf.cfMeta));
		return n != null ? n : cf.cfName;
	}

	static function meta(name:String, c:TClass, cf:TClassField):Bool
		return Lower.hasMeta(name, cf.cfMeta) || Lower.hasMeta(name, c.clMeta);

	static function metaStr(name:String, c:TClass, cf:TClassField):Null<String> {
		var s = Lower.metaString(name, cf.cfMeta);
		return s != null ? s : Lower.metaString(name, c.clMeta);
	}

	// records the extern `sym` (field cf of c, of type s): its C signature,
	// whether its calls stay in the running state (@:hxmc.fast), its library
	public static function declare(sym:String, c:TClass, cf:TClassField, s:TSignature):CSig {
		var where = posOf(cf.cfPos);
		var fast = meta(":hxmc.fast", c, cf);
		// a fast call may take and return GC references (nothing moves during
		// it: the runtime's own C functions); a call in a safe region may not
		function gc(ct:CTy):CTy
			return ct == CNone && fast ? CPtr : ct;
		var args = [];
		for (i in 0...s.args.length) {
			var ct = gc(ctype(s.args[i].type));
			if (!isScalar(ct) && !ct.match(CStruct(_)))
				throw new LowerError('C function $sym: parameter ${s.args[i].name} has no C type a call can pass (${describe(ct)}; scalars, Ptr, CString and structs)', where);
			args.push(ct);
		}
		var ret = gc(ctype(s.ret));
		if (ret != CVoid && !isScalar(ret) && !ret.match(CStruct(_)))
			throw new LowerError('C function $sym: the result has no C type a call can return (${describe(ret)}; scalars, Ptr, CString, a struct or Void)', where);
		var sig = {args: args, ret: ret};
		var prev = SIGS.get(sym);
		if (prev != null) {
			if (!sameSig(prev, sig)) throw new LowerError('C function $sym is declared twice with different signatures', where);
		} else SIGS.set(sym, sig);
		if (fast) {
			if (BLOCKING.exists(sym)) throw new LowerError('C function $sym is declared both @:hxmc.fast and not', where);
			FnLower.C_EXTERNS.set(sym, true);
		} else {
			if (FnLower.C_EXTERNS.exists(sym)) throw new LowerError('C function $sym is declared both @:hxmc.fast and not', where);
			BLOCKING.set(sym, true);
		}
		if (StringTools.startsWith(sym, INDIRECT)) {
			if (args.length == 0 || args[0] != CPtr) throw new LowerError('@:hxmc.indirect : the first parameter is the function\'s address (a Ptr)', where);
			return sig;
		}
		var lib = metaStr(":hxmc.lib", c, cf);
		if (lib != null) LIBS.set(sym, lib);
		// (the program's, not the runtime's: outside the package hxmc, or of a
		// library, as packages/os and packages/gfx declare theirs)
		if (lib != null || c.clPath.pack.length == 0 || c.clPath.pack[0] != "hxmc") USER.set(sym, true);
		return sig;
	}

	static function describe(ct:CTy):String
		return switch ct {
			case CNone: "a GC reference, which only a @:hxmc.fast call may take";
			case CVoid: "Void";
			case CStruct(s): "the struct " + s.clPath.name + " by value";
			case COpaque(s): "the opaque " + s.clPath.name + " by value";
			case _: name(ct);
		}

	// whether two declarations of a symbol lower the same (the conversions
	// MirBuild.cCall makes: narrow integers, bool, float; the rest is passed as
	// its value: a 32-bit int and a 64-bit one are told apart by the call's
	// own operands, so POSIX's int sockets and Winsock's SOCKET may share a name)
	static function sameSig(a:CSig, b:CSig):Bool {
		if (a.args.length != b.args.length || abiKey(a.ret) != abiKey(b.ret)) return false;
		for (i in 0...a.args.length)
			if (abiKey(a.args[i]) != abiKey(b.args[i])) return false;
		return true;
	}

	static function abiKey(t:CTy):String
		return switch t {
			case CBool | CI8 | CU8 | CI16 | CU16 | CF32 | CVoid: t.getName();
			case CStruct(_): shape(t);
			case _: "w";
		}

	// what decides how a struct travels in a call: its size and its scalars
	// at their offsets (Fingerprint: a changed struct compiles its calls again)
	public static function shape(t:CTy):String
		return switch t {
			case CStruct(c): 'S${layout(c).size}{' + [for (f in scalars(c, 0)) f.off + ":" + f.ty.getName()].join(",") + "}";
			case _: t.getName();
		}

	// the scalar fields of a struct, nested structs flattened, at their offsets
	public static function scalars(c:TClass, at:Int):Array<{off:Int, ty:CTy}> {
		var r = [];
		for (f in layout(c).fields)
			switch f.ty {
				case CStruct(s): r = r.concat(scalars(s, at + f.off));
				case t: r.push({off: at + f.off, ty: t});
			}
		return r;
	}

	// @:hxmc.link("path") on a class: an object or archive linked with the
	// program, relative to the file declaring it; ${target} becomes the
	// target's name (linux-x86_64, ...)
	public static function links(c:TClass, target:String) {
		for (m in c.clMeta)
			if (core.Meta.metaEq(Custom(":hxmc.link"), m.meta) && m.exprs.length == 1)
				switch m.exprs[0].expr {
					case EConst(core.Ast.Constant.String(s, _)):
						var p = StringTools.replace(s, "${target}", target);
						if (!haxe.io.Path.isAbsolute(p)) p = haxe.io.Path.join([haxe.io.Path.directory(c.clPos.pfile), p]);
						p = haxe.io.Path.normalize(p);
						if (LINKS.indexOf(p) < 0) LINKS.push(p);
					case _:
				}
	}
}
