package hxmc.ir;

import core.Ast.Binop;
import core.Ast.Unop;
import core.TType;
import core.TFunctions;
import hxmc.ir.Lower.LowerError;

using core.TFunctions;

// C interop (docs/interop.md, "C interop"): the C type of a Haxe type in
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

// how a call passes one Haxe parameter of a C function (docs/interop.md,
// "Typed bindings"): as its C type, a span as its address and its length,
// a span as its address alone (its length another parameter's, or a
// minimum), a handle (checked against its invalid value), a callback's address,
// a String as a NUL-terminated UTF-8 copy for the call's duration (NULL for null),
// an hxmc.Out<T> as the address of a slot C stores a T in, a COM interface
// as its interface pointer (borrowed)
enum CArg {
	AValue;
	ASpan;
	ASpanPtr(count:Int, min:Int);
	AHandle(invalid:Null<Int>, close:Bool);
	ACallback;
	AString;
	AOut(kind:OutKind);
	AIface(iface:TClass);
}

// what an hxmc.Out<T> takes: a COM interface (IFoo **, adopted), an
// Objective-C or Core Foundation object (id *: owned, as the Create rule's,
// or borrowed, as ARC's __autoreleasing), a handle (H *)
enum OutKind {
	OCom(iface:TClass);
	OObj(owned:Bool);
	OHandle(t:T);
}

// a C function's parameters as its calls pass them; ret: the length of a
// span result (@:hxmc.len(n)), else -1; typed: whether any parameter or
// the result is passed otherwise than as its C type; str: a String result,
// C's NUL-terminated UTF-8 copied (null for NULL), free: the function of the
// same class freeing it after the copy (@:hxmc.free(fn)), or null: borrowed;
// nil: the parameters of a Null<...> type, whose null passes NULL (a span,
// a callback, a handle: then unchecked)
typedef CPlan = {args:Array<CArg>, ret:Int, typed:Bool, str:Bool, free:Null<String>, nil:Array<Bool>};

class CInterop {
	// C functions by symbol: their signature (one per symbol: every
	// declaration must agree, but for the variadic arguments of a
	// @:hxmc.varargs function, which each call passes its own: the first
	// declaration's, sameSig), and the ones called in a safe region (the
	// externs not declared @:hxmc.fast: MirBuild wraps their calls in
	// rt_blocking_enter/rt_blocking_leave)
	public static var SIGS = new Map<String, CSig>();
	public static var BLOCKING = new Map<String, Bool>();
	// @:hxmc.lib: the library a symbol comes from (a DLL, a dylib, a
	// WebAssembly import module)
	public static var LIBS = new Map<String, String>();
	// libraries loaded though the program imports nothing of them: the
	// frameworks of the Objective-C category members it sends (ObjC.memberLibrary)
	public static var LOADS = new Map<String, Bool>();
	// WebAssembly: the import's name of a symbol that importKey made (a C
	// function of an @:hxmc.lib module other than "env")
	public static var IMPORT_NAMES = new Map<String, String>();
	// the externs of the program's own code (not hxmc's runtime): on
	// WebAssembly, imports
	public static var USER = new Map<String, Bool>();
	// @:hxmc.link: objects and archives the program names (absolute paths)
	public static var LINKS:Array<String> = [];
	// C variables (@:hxmc.c statics): their C types, one per symbol
	public static var VARS = new Map<String, CTy>();
	// the word in the program's data holding a C variable's address, which
	// the loader fills (DataGen.cVars; on Windows, a DLL's: its import's slot)
	public static inline var CVAR = "hxmc$cvar$";
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
		LOADS = new Map();
		IMPORT_NAMES = new Map();
		USER = new Map();
		VARS = new Map();
		FnLower.C_EXTERNS = new Map();
		FnLower.C_VARIADIC = new Map();
	}

	public static function isStruct(c:TClass):Bool
		return Lower.hasMeta(":hxmc.struct", c.clMeta);

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
						case TClassDecl(c) if (isStruct(c)):
							if (c.clConstructor != null && c.clConstructor.cfKind.match(Method(MethInline)))
								c.clConstructor.cfKind = Method(MethNormal);
							keepFields(c);
						case _:
					}
			});
		}
	}

	// A struct's variables are its C layout (layout): every one is kept with
	// the class, used or not. Under `-dce full`, DCE kept only those the
	// typed code reads or writes: a struct the lowering reaches itself
	// (hxmc.Span's SpanData, whose ptr only FnLower.spanCall uses), or one
	// whose fields C alone reads, lost fields, and so its layout. Each
	// variable gets @:ifFeature("<the class>.*"), the feature DCE checks when
	// it marks the class (optimization/Dce.hx, markClass).
	static function keepFields(c:TClass) {
		var feature = core.Globals.sTypePath(c.clPath) + ".*";
		for (cf in c.clOrderedFields) {
			if (!cf.cfKind.match(Var(_))) continue;
			var exprs = [new core.Ast.Expr(EConst(String(feature, SDoubleQuotes)), cf.cfPos)];
			var meta:Array<core.Ast.MetadataEntry> = [];
			var done = false;
			for (m in cf.cfMeta)
				if (m.meta == core.MetaList.StrictMeta.IfFeature) {
					// (the field's own features too: DCE reads the first entry)
					for (e in m.exprs)
						switch e.expr {
							case EConst(String(s, _)) if (s == feature): done = true;
							case _: exprs.push(e);
						}
				} else
					meta.push(m);
			if (done) continue;
			meta.push(new core.Ast.MetadataEntry(core.MetaList.StrictMeta.IfFeature, core.ds.VectorTools.ofArray(exprs), cf.cfPos));
			// (metadata is replaced, never changed in place: Dce.hx)
			cf.cfMeta = haxe.ds.Vector.fromArrayCopy(meta);
		}
	}

	// a struct value: a @:hxmc.struct class, or an abstract over one (not
	// Null<S>, a box)
	public static function isStructValue(t:T):Bool {
		for (_ in 0...16)
			switch TFunctions.followWithoutNull(t) {
				case TInst(c, _):
					return isStruct(c);
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

	static function copyArgument(v:TVar, arg:TExpr, body:TExpr):Bool
		return isStructValue(v.vType) && !fresh(arg) && writesThrough(v, body);

	static function keepCopy(t:T, e:TExpr):Bool
		return isStructValue(t) && !fresh(e);

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
					// (a size_t: pointer-sized, as wide as a CPtr on every target)
					case "hxmc.unsafe.USize": CPtr;
					case "Int" | "UInt": CI32;
					case "Bool": CBool;
					case "Float": CF64;
					case "Void": CVoid;
					case "Null" | "Any" | "Class" | "Enum" | "EnumValue": CNone;
					case _:
						if (core.Meta.has(CoreType, a.aMeta)) CNone else ctype(core.Abstract.getUnderlyingType(a, params));
				}
			case TInst(c, _):
				if (isStruct(c)) CStruct(c) else if (isOpaque(c)) COpaque(c) else if (ObjC.isObjC(c) || ObjC.isCF(c) || ObjC.isObjCParam(c) || ObjC.peerBase(c) != null) CPtr else CNone;
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
			if (KernelCheck.spanOf(cf.cfType) != null)
				throw new LowerError(KernelCheck.spanError(posOf(cf.cfPos), "", "the field " + cf.cfName + " of the struct " + where + " has a span type", KernelCheck.SPANS_LOCAL), "");
			// (a struct's fields are written by any code, and its bytes reinterpreted)
			if (KernelCheck.proofOf(cf.cfType) != null)
				throw new LowerError(KernelCheck.spanError(posOf(cf.cfPos), "", "the field " + cf.cfName + " of the struct " + where + " is a proof", KernelCheck.PROOF + ": no struct holds one"), "");
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
		// (hxmc.simd's vector: C's __m128 and float32x4_t, 16-byte aligned, in
		// a struct too)
		if (FnLower.isV128(c)) align = 16;
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
		var name = cName(c, cf);
		if (name == null || Lower.targetOs != 3) return name;
		var lib = metaStr(":hxmc.lib", c, cf);
		return lib != null && lib != "env" ? importKey(lib, name) : name;
	}

	// WebAssembly: a C function of the @:hxmc.lib module `lib` is the import
	// (lib, name), so the same name in two modules is two functions, each
	// with its own signature; their symbol in the program's objects (never a
	// C identifier, and the module's length keeps two pairs apart). Natively
	// C symbols share one namespace: the name alone (docs/interop.md)
	static function importKey(lib:String, name:String):String
		return "@import:" + lib.length + ":" + lib + "." + name;

	// the C name of an extern function, as cSymbol describes it
	public static function cName(c:TClass, cf:TClassField):Null<String> {
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

	// @:hxmc.blocking: its calls run in a safe region that the call site
	// enters and leaves (FnLower.cCall), on the field, or on its class for
	// the fields not @:hxmc.fast
	public static function blockingCall(c:TClass, cf:TClassField):Bool
		return Lower.hasMeta(":hxmc.blocking", cf.cfMeta)
			|| Lower.hasMeta(":hxmc.blocking", c.clMeta) && !Lower.hasMeta(":hxmc.fast", cf.cfMeta);

	// the library of a C symbol: @:hxmc.framework("Name") (a system framework)
	// or @:hxmc.lib, the field's before its class's (a sub-framework's
	// function in its framework's class)
	static function library(c:TClass, cf:TClassField):Null<String> {
		function of(m:core.Ast.Metadata):Null<String> {
			var fw = Lower.metaString(":hxmc.framework", m);
			return fw != null ? ObjC.frameworkPath(fw) : Lower.metaString(":hxmc.lib", m);
		}
		var l = of(cf.cfMeta);
		return l != null ? l : of(c.clMeta);
	}

	static function metaStr(name:String, c:TClass, cf:TClassField):Null<String> {
		var s = Lower.metaString(name, cf.cfMeta);
		return s != null ? s : Lower.metaString(name, c.clMeta);
	}

	// records the extern `sym` (field cf of c, of type s): its C signature,
	// whether its calls stay in the running state (@:hxmc.fast), its library
	public static function declare(sym:String, c:TClass, cf:TClassField, s:TSignature):CSig {
		var where = posOf(cf.cfPos);
		var lib = library(c, cf);
		// (an import of WebAssembly, cSymbol: named by the module and the name)
		var imported = !StringTools.startsWith(sym, INDIRECT) && lib != null && sym == importKey(lib, cName(c, cf));
		if (imported) IMPORT_NAMES.set(sym, cName(c, cf));
		var shown = imported ? IMPORT_NAMES.get(sym) + " of the import module " + lib : sym;
		if (Lower.hasMeta(":hxmc.blocking", cf.cfMeta) && Lower.hasMeta(":hxmc.fast", cf.cfMeta))
			throw new LowerError('C function $shown is declared both @:hxmc.blocking and @:hxmc.fast', where);
		// (@:hxmc.blocking: the call site enters the safe region, FnLower.cCall;
		// the symbol itself is called as a fast one, so the runtime's fast
		// declaration of the same function, read or poll, may coexist)
		var blocking = blockingCall(c, cf);
		var fast = !blocking && meta(":hxmc.fast", c, cf);
		// a fast call may take and return GC references (nothing moves during
		// it: the runtime's own C functions); a call in a safe region may not
		function gc(ct:CTy):CTy
			return ct == CNone && fast ? CPtr : ct;
		var p = plan(c, cf, s, shown, where);
		var args = [];
		for (i in 0...s.args.length) {
			switch p.args[i] {
				case ASpan:
					// (the address, then the length: a size_t, pointer-sized)
					args.push(CPtr);
					args.push(CPtr);
					continue;
				case ASpanPtr(_) | ACallback | AString | AOut(_) | AIface(_):
					args.push(CPtr);
					continue;
				case AHandle(_):
					args.push(handleType(s.args[i].type));
					continue;
				case AValue:
			}
			var ct = gc(ctype(s.args[i].type));
			if (!isScalar(ct) && !ct.match(CStruct(_)))
				throw new LowerError('C function $shown: parameter ${s.args[i].name} has no C type a call can pass (${describe(ct)}; scalars, Ptr, CString and structs)', where);
			args.push(ct);
		}
		var ret = p.ret >= 0 || p.str ? CPtr : handleOf(s.ret) != null ? handleType(s.ret) : gc(ctype(s.ret));
		if (ret != CVoid && !isScalar(ret) && !ret.match(CStruct(_)))
			throw new LowerError('C function $shown: the result has no C type a call can return (${describe(ret)}; scalars, Ptr, CString, a struct or Void)', where);
		var sig = {args: args, ret: ret};
		// @:hxmc.varargs(k): the first variadic argument (the function's
		// address of @:hxmc.indirect not counted)
		var va:Null<Int> = null;
		var vm = core.Meta.getOpt(Custom(":hxmc.varargs"), cf.cfMeta);
		if (vm != null && vm.exprs.length == 1)
			switch vm.exprs[0].expr {
				case EConst(core.Ast.Constant.Int(k, _)): va = Std.parseInt(k);
				case _:
			}
		var first = StringTools.startsWith(sym, INDIRECT) ? 1 : 0;
		if (va != null && (va < 0 || va + first > args.length))
			throw new LowerError('C function $shown: @:hxmc.varargs($va) names more fixed arguments than it has', where);
		var prev = SIGS.get(sym);
		if (prev != null) {
			var pva = FnLower.C_VARIADIC.get(sym);
			// (a variadic one: its variadic arguments may differ, natively, where
			// each call passes its own; a WebAssembly import has one signature)
			var same = (pva == null) == (va == null) && (va == null || (pva : Int) == (va : Int))
				&& sameSig(prev, sig, va == null || Lower.targetOs == 3 ? -1 : va + first);
			if (!same) throw new LowerError('C function $shown is declared twice with different signatures', where);
		} else {
			SIGS.set(sym, sig);
			if (va != null) FnLower.C_VARIADIC.set(sym, va);
		}
		if (blocking) {
			if (BLOCKING.exists(sym)) throw new LowerError('C function $shown is declared both @:hxmc.blocking and without it nor @:hxmc.fast: declare its calls the same way', where);
			FnLower.C_EXTERNS.set(sym, true);
		} else if (fast) {
			if (BLOCKING.exists(sym)) throw new LowerError('C function $shown is declared both @:hxmc.fast and not', where);
			FnLower.C_EXTERNS.set(sym, true);
		} else {
			if (FnLower.C_EXTERNS.exists(sym)) throw new LowerError('C function $shown is declared both @:hxmc.fast and not', where);
			BLOCKING.set(sym, true);
		}
		if (StringTools.startsWith(sym, INDIRECT)) {
			if (args.length == 0 || args[0] != CPtr) throw new LowerError('@:hxmc.indirect : the first parameter is the function\'s address (a Ptr)', where);
			return sig;
		}
		if (lib != null) LIBS.set(sym, lib);
		// (the program's, not the runtime's: outside the package hxmc, or of a
		// library, as packages/os and packages/gfx declare theirs)
		if (lib != null || c.clPath.pack.length == 0 || c.clPath.pack[0] != "hxmc") USER.set(sym, true);
		if (HeaderCheck.on) HeaderCheck.declare(sym, c, cf, s, sig, p);
		return sig;
	}

	// ---- typed bindings (docs/interop.md, "Typed bindings")

	// @:hxmc.safe on the field or its class: the declaration vouches that the
	// function is memory-safe given its typed parameters (no raw memory among
	// them), so safe kernels call it
	public static function isSafe(c:TClass, cf:TClassField):Bool
		return Lower.hasMeta(":hxmc.safe", cf.cfMeta) || Lower.hasMeta(":hxmc.safe", c.clMeta);

	// a @:hxmc.handle abstract t is (or an abstract over one): a value only
	// C functions' results and @:hxmc.unsafe code make; invalid: its
	// @:hxmc.handle(v) value, which calls taking one refuse
	public static function handleOf(t:T):Null<{a:TAbstract, invalid:Null<Int>}> {
		for (_ in 0...16)
			switch TFunctions.follow(t) {
				case TAbstract(a, pl):
					var m = a.aMeta.length > 0 ? core.Meta.getOpt(Custom(":hxmc.handle"), a.aMeta) : null;
					if (m != null) return {a: a, invalid: m.exprs.length == 1 ? intOf(m.exprs[0]) : null};
					if (core.Meta.has(CoreType, a.aMeta)) return null;
					t = TFunctions.applyParams(a.aParams, pl, a.aThis);
				case _:
					return null;
			}
		return null;
	}

	// a handle's C type: what it stands on, one abstract at a time (a Ptr
	// is a pointer, which ctype would see through as the I64 it stands on)
	// whether t is hxmc.unsafe.USize, C's size_t (HeaderCheck: an integer, not a pointer)
	public static function isSize(t:T):Bool
		return switch TFunctions.follow(t) {
			case TAbstract(a, _): path(a) == "hxmc.unsafe.USize";
			case _: false;
		}

	public static function handleType(t:T):CTy {
		for (_ in 0...16)
			switch TFunctions.follow(t) {
				case TAbstract(a, pl) if (path(a) == "hxmc.unsafe.Ptr"):
					return CPtr;
				case TAbstract(a, pl) if (!core.Meta.has(CoreType, a.aMeta)):
					t = TFunctions.applyParams(a.aParams, pl, a.aThis);
				case _:
					return ctype(t);
			}
		return ctype(t);
	}

	public static function intOf(e:core.Ast.Expr):Null<Int>
		return switch e.expr {
			case EConst(core.Ast.Constant.Int(v, _)): Std.parseInt(v);
			case EUnop(Neg, Prefix, x):
				var v = intOf(x);
				v == null ? null : -v;
			case EParenthesis(x): intOf(x);
			case _: null;
		}

	public static function identOf(e:core.Ast.Expr):Null<String>
		return switch e.expr {
			case EConst(core.Ast.Constant.Ident(n)): n;
			case _: null;
		}

	// the parameters of C function cf (or of an Objective-C method: msg) as
	// its calls pass them: spans (their @:hxmc.len), handles (@:hxmc.close),
	// callbacks, Strings, Outs; for a @:hxmc.safe one, the check that no raw
	// memory crosses it. A message takes a String without @:hxmc.safe (it
	// takes none otherwise), and its function types are blocks but for the
	// parameters @:hxmc.callback names: C's function pointers
	public static function plan(c:TClass, cf:TClassField, s:TSignature, shown:String, where:String, msg = false):CPlan {
		var what = msg ? "Objective-C method" : "C function";
		var args = [for (a in s.args) AValue], ret = -1, typed = false;
		var nil = [for (a in s.args) false];
		function index(name:String):Int {
			for (i in 0...s.args.length)
				if (s.args[i].name == name) return i;
			return -1;
		}
		for (m in cf.cfMeta) {
			if (core.Meta.metaEq(Custom(":hxmc.len"), m.meta)) {
				// @:hxmc.len(n): the result is a span of n elements
				if (m.exprs.length == 1) {
					var n = intOf(m.exprs[0]);
					if (n == null || n < 0 || KernelCheck.spanOf(s.ret) == null)
						throw new LowerError('$what $shown: @:hxmc.len(n) gives the length of a span result: a constant', where);
					ret = n;
					continue;
				}
				// @:hxmc.len(buf, n): the span buf passes its address alone, its
				// length the parameter n (checked: at most buf's), or at least
				// the constant n
				var name = m.exprs.length == 2 ? identOf(m.exprs[0]) : null;
				var k = name == null ? -1 : index(name);
				if (k < 0 || KernelCheck.spanOf(s.args[k].type) == null)
					throw new LowerError('$what $shown: @:hxmc.len(buf, n) names a span parameter, then a parameter or a constant', where);
				var min = intOf(m.exprs[1]);
				var count = min == null ? index(identOf(m.exprs[1])) : -1;
				if (min == null && (count < 0 || count == k || !isCount(s.args[count].type)))
					throw new LowerError('$what $shown: @:hxmc.len(${name}, n): n is an integer parameter or a constant', where);
				args[k] = ASpanPtr(count, min == null ? 0 : min);
			}
		}
		var closes = [], fnptrs = [];
		for (m in cf.cfMeta)
			if (core.Meta.metaEq(Custom(":hxmc.close"), m.meta))
				for (e in m.exprs) {
					var k = identOf(e) == null ? -1 : index(identOf(e));
					var h = k < 0 ? null : handleOf(s.args[k].type);
					if (h == null || h.invalid == null)
						throw new LowerError('$what $shown: @:hxmc.close names a parameter of a handle type with an invalid value (@:hxmc.handle(-1))', where);
					closes.push(k);
				}
			else if (msg && core.Meta.metaEq(Custom(":hxmc.callback"), m.meta))
				// (a message's function pointer: a block otherwise)
				for (e in m.exprs) {
					var k = identOf(e) == null ? -1 : index(identOf(e));
					if (k < 0 || !TFunctions.follow(s.args[k].type).match(TFun(_)))
						throw new LowerError('$what $shown: @:hxmc.callback names a parameter of a function type (a C function pointer; a block otherwise)', where);
					fnptrs.push(k);
				}
		var strings = msg || isSafe(c, cf);
		for (i in 0...s.args.length) {
			var t = s.args[i].type;
			var optional = TFunctions.isExplicitNull(t);
			if (KernelCheck.spanOf(t) != null) {
				// (a message's length is a parameter of its own, part of the selector)
				if (msg && args[i].match(AValue))
					throw new LowerError('$what $shown: the span ${s.args[i].name} needs @:hxmc.len(${s.args[i].name}, n): a message passes its address alone', where);
				if (args[i].match(AValue)) args[i] = ASpan;
				nil[i] = optional;
				typed = true;
				continue;
			}
			var h = handleOf(t);
			if (h != null) {
				args[i] = AHandle(h.invalid, closes.indexOf(i) >= 0);
				nil[i] = optional;
				if (h.invalid != null || optional) typed = true;
				if (optional && closes.indexOf(i) >= 0)
					throw new LowerError('$what $shown: @:hxmc.close names ${s.args[i].name}, which may be null', where);
				continue;
			}
			if (TFunctions.follow(t).match(TFun(_)) && (!msg || fnptrs.indexOf(i) >= 0)) {
				args[i] = ACallback;
				nil[i] = optional;
				typed = true;
				continue;
			}
			var o = outKind(c, cf, s.args[i].name, t, msg, what + " " + shown, where);
			if (o != null) {
				args[i] = AOut(o);
				typed = true;
				continue;
			}
			// (a COM interface of a @:hxmc.safe function: its interface pointer, borrowed)
			var ci = !msg && isSafe(c, cf) ? Com.ifaceOf(t) : null;
			if (ci != null) {
				args[i] = AIface(ci);
				typed = true;
				continue;
			}
			if (isString(t) && strings) {
				args[i] = AString;
				typed = true;
			}
		}
		var str = isString(s.ret) && strings, free:Null<String> = null;
		var fm = core.Meta.getOpt(Custom(":hxmc.free"), cf.cfMeta);
		if (fm != null) {
			free = fm.exprs.length == 1 ? identOf(fm.exprs[0]) : null;
			if (msg || !str || free == null || !c.clStatics.exists(free))
				throw new LowerError('$what $shown: @:hxmc.free(fn) names the function of its class that frees its String result', where);
		}
		if (ret >= 0 || str) typed = true;
		if (KernelCheck.spanOf(s.ret) != null && ret < 0)
			throw new LowerError('$what $shown: a span result needs its length (@:hxmc.len(n))', where);
		// (a function another of its class names in @:hxmc.free takes C's pointer: the
		// compiler calls it; a call of it in the program passes raw memory, RawCheck)
		if (!msg && isSafe(c, cf) && !freesResults(c, cf.cfName)) {
			if (Lower.hasMeta(":hxmc.indirect", cf.cfMeta)) throw new LowerError('C function $shown: @:hxmc.safe and @:hxmc.indirect (a raw address)', where);
			for (i in 0...s.args.length)
				if (args[i].match(AValue) && !safeValue(s.args[i].type))
					throw new LowerError('C function $shown is @:hxmc.safe but its parameter ${s.args[i].name} is raw memory or a GC value (${core.TPrinting.Printer.sType(s.args[i].type)}: spans, handles, objects, scalars and structs of them)', where);
			if (ret < 0 && !str && ctype(s.ret) != CVoid && !safeValue(s.ret))
				throw new LowerError('C function $shown is @:hxmc.safe but its result is raw memory or a GC value (${core.TPrinting.Printer.sType(s.ret)})', where);
		}
		return {args: args, ret: ret, typed: typed, str: str, free: free, nil: nil};
	}

	// the T of an hxmc.Out<T> (hxmc.com.Out<T> too), else null
	public static function outParam(t:T):Null<T>
		return switch TFunctions.follow(t) {
			case TInst(c, [p]) if (c.clPath.name == "Out" && c.clPath.pack.length == 1 && c.clPath.pack[0] == "hxmc"): p;
			case _: null;
		}

	// what an hxmc.Out<T> parameter takes: a COM interface, an object (owned
	// by a C function of the Create rule, Create or Copy in its name, or one
	// naming it in @:hxmc.retained(p); else borrowed, as ARC's
	// __autoreleasing out-parameters are), a handle
	static function outKind(c:TClass, cf:TClassField, name:String, t:T, msg:Bool, shown:String, where:String):Null<OutKind> {
		var p = outParam(t);
		if (p == null) return null;
		var i = Com.ifaceOf(p);
		if (i != null) return OCom(i);
		if (handleOf(p) != null) return OHandle(p);
		switch TFunctions.follow(p) {
			case TInst(k, _) if (ObjC.peerBase(k) != null):
				throw new LowerError('$shown: hxmc.Out<${k.clPath.name}>: a Haxe class\'s objects are not stored by C (an Out of its Objective-C superclass)', where);
			case TInst(k, _) if (ObjC.isObjC(k) || ObjC.isCF(k) || ObjC.isObjCParam(k) || ObjC.isId(k)):
				var named = false;
				for (m in cf.cfMeta)
					if (core.Meta.metaEq(Custom(":hxmc.retained"), m.meta))
						for (e in m.exprs)
							if (identOf(e) == name) named = true;
				if (named) return OObj(true);
				var n = msg ? "" : cName(c, cf);
				return OObj(n.indexOf("Create") >= 0 || n.indexOf("Copy") >= 0);
			case _:
				throw new LowerError('$shown: hxmc.Out<T> holds a COM interface, an Objective-C or Core Foundation object, or a handle', where);
		}
	}

	// @:hxmc.retained on cf without a parameter's name: its object result is
	// the caller's (the Create rule)
	public static function retainedResult(cf:TClassField):Bool {
		for (m in cf.cfMeta)
			if (core.Meta.metaEq(Custom(":hxmc.retained"), m.meta) && m.exprs.length == 0) return true;
		return false;
	}

	// whether a function of c names fn in @:hxmc.free
	static function freesResults(c:TClass, fn:String):Bool {
		for (f in c.clOrderedStatics) {
			var m = f.cfMeta.length > 0 ? core.Meta.getOpt(Custom(":hxmc.free"), f.cfMeta) : null;
			if (m != null && m.exprs.length == 1 && identOf(m.exprs[0]) == fn) return true;
		}
		return false;
	}

	// a String parameter or result: C's `const char *`, NUL-terminated UTF-8
	public static function isString(t:T):Bool
		return switch TFunctions.follow(t) {
			case TInst(c, _): Lower.isCore(c, "String");
			case _: false;
		}

	static function isInteger(ct:CTy):Bool
		return ct.match(CI8 | CU8 | CI16 | CU16 | CI32 | CI64);

	static function isCount(t:T):Bool
		return isSize(t) || isInteger(ctype(t));

	// what a @:hxmc.safe function passes as its C type: a scalar that is no
	// raw memory, a handle, a struct of such fields
	static function safeValue(t:T, depth = 0):Bool {
		if (depth > 8) return false;
		if (handleOf(t) != null) return true;
		// (an object, borrowed for the call: Objective-C's, Core Foundation's, a
		// block, a COM interface, which no struct field holds)
		if (depth == 0 && (ObjC.isObjCType(t) || ObjC.blockOfType(t) != null || Com.ifaceOf(t) != null)) return true;
		if (KernelCheck.isRaw(t)) return false;
		return switch ctype(t) {
			case CStruct(sc):
				var ok = true;
				for (f in sc.clOrderedFields)
					if (f.cfKind.match(Var(_)) && !safeValue(f.cfType, depth + 1)) ok = false;
				ok;
			case CPtr: isSize(t);
			case CNone | CVoid | COpaque(_): false;
			case _: true;
		}
	}

	// a C variable: a static var of an extern class that @:hxmc.c names (on
	// the field or the class), read and written at its address
	public static function isVar(c:TClass, cf:TClassField):Bool
		return c.hasClassFlag(CExtern) && cf.cfKind.match(Var(_)) && cName(c, cf) != null;

	// records the C variable `sym` (the static cf of c): its C type, its library
	public static function declareVar(sym:String, c:TClass, cf:TClassField):CSig {
		var where = posOf(cf.cfPos);
		if (Lower.targetOs == 3) throw new LowerError('C variable $sym: WebAssembly imports functions, not variables', where);
		var ct = ctype(cf.cfType);
		if (!isScalar(ct) && !ct.match(CStruct(_)))
			throw new LowerError('C variable $sym has no C type a load can read (${describe(ct)}; scalars, Ptr, CString and structs)', where);
		if (SIGS.exists(sym)) throw new LowerError('C variable $sym is declared as a function too', where);
		var prev = VARS.get(sym);
		if (prev != null && !Type.enumEq(prev, ct)) throw new LowerError('C variable $sym is declared twice with different types', where);
		VARS.set(sym, ct);
		var lib = library(c, cf);
		if (lib != null) LIBS.set(sym, lib);
		if (lib != null || c.clPath.pack.length == 0 || c.clPath.pack[0] != "hxmc") USER.set(sym, true);
		return {args: [], ret: ct};
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
	// own operands, so POSIX's int sockets and Winsock's SOCKET may share a name).
	// fixed >= 0: a variadic function's, its arguments from fixed on variadic:
	// those may differ (syscall(2) of the runtime's three and six arguments)
	// unless one is a struct, which MirBuild.cCall passes by the declaration
	static function sameSig(a:CSig, b:CSig, fixed:Int):Bool {
		if (abiKey(a.ret) != abiKey(b.ret)) return false;
		if (fixed >= 0 && scalarTail(a, fixed) && scalarTail(b, fixed)) {
			for (i in 0...fixed)
				if (abiKey(a.args[i]) != abiKey(b.args[i])) return false;
			return true;
		}
		if (a.args.length != b.args.length) return false;
		for (i in 0...a.args.length)
			if (abiKey(a.args[i]) != abiKey(b.args[i])) return false;
		return true;
	}

	static function scalarTail(s:CSig, fixed:Int):Bool {
		for (i in fixed...s.args.length)
			if (s.args[i].match(CStruct(_))) return false;
		return true;
	}

	// the arguments of a call of sym (signature sig, SIGS) whose C types every
	// declaration agrees on: all but the variadic ones that are scalars, which
	// the call's operands describe (Fingerprint)
	public static function fixedArgs(sym:String, sig:CSig):Int {
		var va = FnLower.C_VARIADIC.get(sym);
		if (va == null) return sig.args.length;
		var fixed = va + (StringTools.startsWith(sym, INDIRECT) ? 1 : 0);
		return scalarTail(sig, fixed) ? fixed : sig.args.length;
	}

	// a C type as errors and the header check name it (a struct by its name)
	public static function abiName(t:CTy):String
		return switch t {
			case CStruct(c) | COpaque(c): c.clPath.name;
			case CNone: "gc";
			case _: name(t);
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
			case CStruct(c): 'S${layout(c).size}{' + [for (f in scalars(c, 0, true)) f.off + ":" + f.ty.getName()].join(",") + "}";
			case _: t.getName();
		}

	// the scalar fields of a struct, nested structs flattened, at their
	// offsets; vectors: hxmc.simd's vectors whole (CStruct(V128), C's
	// __m128), else their four words
	public static function scalars(c:TClass, at:Int, vectors = false):Array<{off:Int, ty:CTy}> {
		if (vectors && FnLower.isV128(c)) return [{off: at, ty: CStruct(c)}];
		var r = [];
		for (f in layout(c).fields)
			switch f.ty {
				case CStruct(s): r = r.concat(scalars(s, at + f.off, vectors));
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
