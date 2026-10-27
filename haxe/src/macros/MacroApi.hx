package macros;

import core.Globals.Pos;
import core.Globals.GlobalTypePath;
import core.Globals.Platform;
import core.Globals;
import core.Ast;
import core.TType;
import core.TFunctions;
import core.TFunctions.*;
import core.DisplayTypes.DisplayModeValue;
import core.Message.CompilerMessage;
import core.Message.MessageSeverity;
import core.Meta;
import core.MetaList.MetaParameter;
import core.DefineRegistry.DefineParameter;
import core.ds.AtomicLazy;
import core.ds.NotFound;
import core.ds.PMap;
import context.Common;
import context.PlatformConfig;
import macros.eval.EvalValue.Value;
import haxe.ds.StringMap;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

using core.ds.VectorTools;

// port: haxe/src/macro/macroApi.ml: the compiler side of the macro API (`compiler_api`)
// and the encoding/decoding of compiler values. Upstream is a functor over the
// interpreter; there is only Eval here, so it uses Eval's values directly.
class InvalidExpr extends haxe.Exception {
	public static final instance = new InvalidExpr();

	public function new() super("Invalid_expr");

	public static inline function raise():InvalidExpr return core.ds.FastThrow.of(instance);
}

class Abort extends haxe.Exception {
	public function new() super("Abort");
}

@:structInit class CompilerOptions {
	public var optInlining:Null<Bool>;
	public var optTransform:Null<Bool>;

	public inline function new(optInlining:Null<Bool>, optTransform:Null<Bool>) {
		this.optInlining = optInlining;
		this.optTransform = optTransform;
	}
}

typedef MacroValue = macros.eval.EvalValue.Value;

// port: `'value compiler_api`. A structure rather than a class: a constructor
// would take one argument per field, more than HashLink's JIT allows in a call.

/**
	Our access to the compiler from the macro api
**/
typedef CompilerApi = {
	var pos:Pos;
	var getCom:Void->context.Common.CommonContext;
	var getMacroCom:Void->context.Common.CommonContext;
	var getMacroStack:Void->Array<Pos>;
	var initMacrosDone:Void->Bool;
	var getType:String->Null<T>;
	var getModule:String->Array<T>;
	var includeModule:String->Void;
	var afterInitMacros:(Void->Void)->Void;
	var afterTyping:(Array<ModuleType>->Void)->Void;
	var onGenerate:(Array<T>->Void)->Bool->Void;
	var afterGenerate:(Void->Void)->Void;
	var onTypeNotFound:(String->MacroValue)->Void;
	var parseString:String->Pos->Bool->Expr;
	var registerFileContents:String->String->Void;
	// port: `parse f s`: runs the parser function `f` on the source `s`
	var parse:(syntax.Parser.ParserContext->core.ds.Stream<syntax.Lexer.LexedToken>->Dynamic)->String->Dynamic;
	var typeExpr:Expr->TExpr;
	var resolveType:ComplexType->Pos->T;
	var resolveComplexType:TypeHint->TypeHint;
	var storeTypedExpr:TExpr->Expr;
	var allowPackage:String->Void;
	var getLocalType:Void->Null<T>;
	var getExpectedType:Void->Null<T>;
	var getCallArguments:Void->Null<Vector<Expr>>;
	var getLocalMethod:Void->String;
	var getLocalImports:Void->Array<Import>;
	var getLocalUsing:Void->Array<TClass>;
	var getLocalVars:Void->haxe.ds.StringMap<TVar>;
	var getBuildFields:Void->MacroValue;
	var defineType:MacroValue->Null<String>->Void;
	var defineModule:String->Array<MacroValue>->Array<{path:Vector<PlacedName>, mode:ImportMode}>->Array<TypePath>->Void;
	var moduleDependency:String->String->Void;
	var currentModule:Void->ModuleDef;
	var formatString:String->Pos->Expr;
	var castOrUnify:T->TExpr->Pos->Bool;
	var addGlobalMetadata:String->String->{a:Bool, b:Bool, c:Bool}->Pos->Void;
	var registerDefine:String->core.Define.UserDefine->Void;
	var registerMetadata:String->core.Meta.UserMeta->Void;
	var addModuleCheckPolicy:Array<String>->Array<Int>->Bool->Void;
	var decodeExpr:MacroValue->Expr;
	var encodeExpr:Expr->MacroValue;
	var encodeCtype:TypeHint->MacroValue;
	var decodeType:MacroValue->T;
	// port: optional arguments are explicit: HashLink cannot call a closure typed with them through a structure field
	var info:(msg:String, p:Pos, depth:Int) -> Void;
	var warning:(w:core.Message.WarningCode, msg:String, p:Pos, depth:Int) -> Void;
	var displayError:(msg:String, p:Pos, sub:Null<Array<core.Error.MacroError>>) -> Void;
	// port: `with_imports imports usings f`
	var withImports:Array<Import>->Array<Vector<PlacedName>>->(Void->Dynamic)->Dynamic;
	var withOptions:CompilerOptions->(Void->Dynamic)->Dynamic;
	var excString:String->Dynamic;
	var getHxbWriterConfig:Void->MacroValue;
	var setHxbWriterConfig:MacroValue->Void;
}

class CompilerApiTools {
	// port: `{ api with ... }`: a shallow copy.
	public static function clone(api:CompilerApi):CompilerApi return Reflect.copy(api);

	/**
		A null compiler API that holds no references to any compilation context.
		Used to clear the eval interpreter's curapi between compilations so that
		the compilation context can be garbage collected. Any accidental access
		raises [Globals.Ice].
	**/
	public static function nullApi():CompilerApi {
		inline function die():Dynamic return core.Globals.die("Macro API accessed after compilation cleanup", "MacroApi.nullApi");
		return {
			pos: core.Globals.nullPos,
			getCom: () -> die(),
			getMacroCom: () -> die(),
			getMacroStack: () -> die(),
			initMacrosDone: () -> die(),
			getType: _ -> die(),
			getModule: _ -> die(),
			includeModule: _ -> die(),
			afterInitMacros: _ -> die(),
			afterTyping: _ -> die(),
			onGenerate: (_, _) -> die(),
			afterGenerate: _ -> die(),
			onTypeNotFound: _ -> die(),
			parseString: (_, _, _) -> die(),
			registerFileContents: (_, _) -> die(),
			parse: (_, _) -> die(),
			typeExpr: _ -> die(),
			resolveType: (_, _) -> die(),
			resolveComplexType: _ -> die(),
			storeTypedExpr: _ -> die(),
			allowPackage: _ -> die(),
			getLocalType: () -> die(),
			getExpectedType: () -> die(),
			getCallArguments: () -> die(),
			getLocalMethod: () -> die(),
			getLocalImports: () -> die(),
			getLocalUsing: () -> die(),
			getLocalVars: () -> die(),
			getBuildFields: () -> die(),
			defineType: (_, _) -> die(),
			defineModule: (_, _, _, _) -> die(),
			moduleDependency: (_, _) -> die(),
			currentModule: () -> die(),
			formatString: (_, _) -> die(),
			castOrUnify: (_, _, _) -> die(),
			addGlobalMetadata: (_, _, _, _) -> die(),
			registerDefine: (_, _) -> die(),
			registerMetadata: (_, _) -> die(),
			addModuleCheckPolicy: (_, _, _) -> die(),
			decodeExpr: _ -> die(),
			encodeExpr: _ -> die(),
			encodeCtype: _ -> die(),
			decodeType: _ -> die(),
			info: (_, _, _) -> die(),
			warning: (_, _, _, _) -> die(),
			displayError: (_, _, _) -> die(),
			withImports: (_, _, _) -> die(),
			withOptions: (_, _) -> die(),
			excString: _ -> die(),
			getHxbWriterConfig: () -> die(),
			setHxbWriterConfig: _ -> die()
		};
	}
}

enum EnumType {
	IExpr;
	IEFieldKind;
	IBinop;
	IUnop;
	IConst;
	ITParam;
	ICType;
	IField;
	IType;
	IFieldKind;
	IMethodKind;
	IVarAccess;
	IAccess;
	IClassKind;
	ITypedExpr;
	ITConstant;
	IModuleType;
	IFieldAccess;
	IAnonStatus;
	IQuoteStatus;
	IImportMode;
	IDisplayKind;
	IDisplayMode;
	ICapturePolicy;
	IVarScope;
	IVarScopingFlags;
	IPlatform;
	IPackageRule;
	IMessage;
	IFunctionKind;
	IStringLiteralKind;
}

// port: an object field of an encoded anonymous object (`string * value`).
private typedef ObjField = {name:String, value:Value};

// port: the result of `decode_enum` (`int * value list`).
private typedef DecodedEnum = {index:Int, args:Array<Value>};

// port: the result of `decode_enum_with_pos` (`(int * value list) * pos`).
private typedef DecodedEnumWithPos = {index:Int, args:Array<Value>, pos:Pos};

// port: a decoded type definition (`Globals.path * Ast.type_def * pos`).
typedef DecodedTypeDef = {path:GlobalTypePath, def:TypeDef, pos:Pos};

class MacroApi {
	public static function sTypePath(p:GlobalTypePath):String return Globals.sTypePath(p);

	static function efield(e:Expr, s:String):ExprDef return EField(e, s, EFNormal);

	/** convert float value to haxe expression, handling inf/-inf/nan **/
	public static function haxeFloat(f:Float, p:Pos):Expr {
		var std:Expr = {expr: EConst(Constant.Ident("std")), pos: p};
		var math:Expr = {expr: efield(std, "Math"), pos: p};
		if (f == Math.POSITIVE_INFINITY)
			return {expr: efield(math, "POSITIVE_INFINITY"), pos: p};
		else if (f == Math.NEGATIVE_INFINITY)
			return {expr: efield(math, "NEGATIVE_INFINITY"), pos: p};
		else if (f != f)
			return {expr: efield(math, "NaN"), pos: p};
		else
			return {expr: EConst(Constant.Float(core.Numeric.floatRepres(f), null)), pos: p};
	}
}

// ------------------------------------------------------------------------------------------------------------- //
// Our macro api functor

// port: `MacroApiImpl(InterpImpl)`, instantiated for Eval. Upstream's
// `InterpImpl` is `Eval` (EvalEncode, EvalDecode, EvalValue, EvalContext and
// EvalMain included in that order); its members are bound in the first section
// below so that the rest of the module reads like upstream.
// Deviations:
// - OCaml evaluates the elements of a list literal (and the arguments of an
//   application) right to left. Where an element can have an observable side
//   effect (forcing lazy types, building classes, encoding typed expressions),
//   the elements are evaluated into locals in that order before building the
//   list; the order of the encoded fields is unchanged. Decoders and the pure
//   AST encoders are evaluated left to right.
// - `Stack_overflow` cannot be caught portably; the `try ... with
//   Stack_overflow -> raise Invalid_expr` wrappers of decode_expr/decode_texpr
//   are not reproduced.
// - Services the port does not have (native libraries, the JS generator) fail
//   with an explicit error.
class MacroApiImpl {
	// port: InterpImpl (Eval), or the compiler's own values when a host sets
	// nativeValues (hook, not upstream: MacroNativeValues)
	// port: a native value goes through Dynamic to the declared type explicitly
	// (the reference's hl generator cannot cast e.g. an Array to the Value enum
	// directly once these are inlined)
	public static var nativeValues = false;

	public static var vnull(get, never):Value;

	static inline function get_vnull():Value return nativeValues ? null : VNull;

	static inline function vint(i:Int):Value return nativeValues ? ((i : Dynamic) : Value) : VInt32(i);

	static inline function vint32(i:Int):Value return nativeValues ? ((i : Dynamic) : Value) : VInt32(i);

	static inline function vfloat(f:Float):Value return nativeValues ? ((f : Dynamic) : Value) : VFloat(f);

	static inline function vbool(b:Bool):Value return nativeValues ? ((b : Dynamic) : Value) : b ? VTrue : VFalse;

	public static inline function encodeArray(l:Array<Value>):Value return nativeValues ? ((l : Dynamic) : Value) : macros.eval.EvalEncode.encodeArray(l);

	// port: a Vector as macro code's Array (native values: a copy)
	public static inline function encodeArrayV(v:Vector<Value>):Value return nativeValues ? ((v.toArray() : Dynamic) : Value) : macros.eval.EvalEncode.encodeArrayV(v);

	static inline function encodeString(s:String):Value return nativeValues ? ((s : Dynamic) : Value) : macros.eval.EvalEncode.encodeString(s);

	// port: EvalMain.encode_obj = EvalEncode.encode_obj_s
	static inline function encodeObj(l:Array<ObjField>):Value return nativeValues ? MacroNativeValues.encodeObj(cast l) : macros.eval.EvalEncode.encodeObjS(l);

	static inline function encodeLazy(l:AtomicLazy<Value>):Value return nativeValues ? l.force() : macros.eval.EvalEncode.encodeLazy(l);

	// port: not inline: inlined, each function of macroApi's list became a
	// temporary of its own (over a hundred locals in one scope, where the
	// reference's neko bytecode compiler splits the list's array without end:
	// Stack overflow), its closure twice
	static function vfun0(f:Void->Value):Value return nativeValues ? ((() -> MacroNativeValues.apiCall(() -> f()) : Dynamic) : Value) : macros.eval.EvalEncode.vfun0(f);

	static function vfun1(f:Value->Value):Value return nativeValues ? (((a) -> MacroNativeValues.apiCall(() -> f(a)) : Dynamic) : Value) : macros.eval.EvalEncode.vfun1(f);

	static function vfun2(f:Value->Value->Value):Value return nativeValues ? (((a, b) -> MacroNativeValues.apiCall(() -> f(a, b)) : Dynamic) : Value) : macros.eval.EvalEncode.vfun2(f);

	static function vfun3(f:Value->Value->Value->Value):Value return nativeValues ? (((a, b, c) -> MacroNativeValues.apiCall(() -> f(a, b, c)) : Dynamic) : Value) : macros.eval.EvalEncode.vfun3(f);

	static function vfun4(f:Value->Value->Value->Value->Value):Value return nativeValues ? (((a, b, c, d) -> MacroNativeValues.apiCall(() -> f(a, b, c, d)) : Dynamic) : Value) : macros.eval.EvalEncode.vfun4(f);

	static function vfun5(f:Value->Value->Value->Value->Value->Value):Value return nativeValues ? (((a, b, c, d, e) -> MacroNativeValues.apiCall(() -> f(a, b, c, d, e)) : Dynamic) : Value) : macros.eval.EvalEncode.vfun5(f);

	static inline function encodePos(p:Pos):Value return nativeValues ? ((p : Dynamic) : Value) : macros.eval.EvalEncode.encodePos(p);

	static inline function encodeStringMap<A>(convert:A->Value,
			m:StringMap<A>):Value return nativeValues ? MacroNativeValues.encodeStringMap(convert, m) : macros.eval.EvalEncode.encodeStringMap(convert, m);

	static inline function encodeTdecl(t:ModuleType):Value return nativeValues ? ((t : Dynamic) : Value) : macros.eval.EvalEncode.encodeTdecl(t);

	static inline function encodeLazytype(t:TLazy, f:Void->Value):Value return nativeValues ? MacroNativeValues.encodeLazytype(t, f) : macros.eval.EvalEncode.encodeLazytype(t, f);

	static inline function encodeUnsafe(o:Dynamic):Value return nativeValues ? ((new NativeRef(o, () -> null, () -> "<unsafe>") : Dynamic) : Value) : macros.eval.EvalEncode.encodeUnsafe(o);

	// port: EvalMain.field v f =EvalField.field v (EvalHash.hash f)
	static inline function field(v:Value, f:String):Value return nativeValues ? Reflect.field(v, f) : macros.eval.EvalField.field(v, macros.eval.EvalHash.hash(f));

	static inline function decodeBool(v:Value):Bool return nativeValues ? MacroNativeValues.decodeBool(v) : macros.eval.EvalDecode.decodeBool(v);

	static inline function decodeInt(v:Value):Int return nativeValues ? MacroNativeValues.decodeInt(v) : macros.eval.EvalDecode.decodeInt(v);

	static inline function decodeI32(v:Value):Int return nativeValues ? MacroNativeValues.decodeInt(v) : macros.eval.EvalDecode.decodeI32(v);

	static inline function decodeString(v:Value):String return nativeValues ? MacroNativeValues.decodeString(v) : macros.eval.EvalDecode.decodeString(v);

	public static inline function decodeArray(v:Value):Array<Value> return nativeValues ? cast MacroNativeValues.decodeArray(v) : macros.eval.EvalDecode.decodeArray(v);

	static inline function decodePos(v:Value):Pos return nativeValues ? MacroNativeValues.decodePos(v) : macros.eval.EvalDecode.decodePos(v);

	static inline function decodeEnum(v:Value):DecodedEnum return nativeValues ? cast MacroNativeValues.decodeEnum(v) : macros.eval.EvalDecode.decodeEnum(v);

	static inline function decodeTdecl(v:Value):ModuleType return nativeValues ? ((v : Dynamic) : ModuleType) : macros.eval.EvalDecode.decodeTdecl(v);

	static inline function decodeLazytype(v:Value):TLazy return nativeValues ? MacroNativeValues.decodeLazytype(v) : macros.eval.EvalDecode.decodeLazytype(v);

	static inline function decodeUnsafe(v:Value):Dynamic return nativeValues ? MacroNativeValues.decodeRef(v) : macros.eval.EvalDecode.decodeUnsafe(v);

	static inline function decodeEnumWithPos(v:Value):DecodedEnumWithPos return nativeValues ? cast MacroNativeValues.decodeEnumWithPos(v) : macros.eval.EvalDecode.decodeEnumWithPos(v);

	static inline function encodeRef<A>(v:A, convert:A->Value,
			tostr:Void->String):Value return nativeValues ? MacroNativeValues.encodeRef(v, convert, tostr) : macros.eval.EvalEncode.encodeRef(v, convert, tostr);

	static inline function decodeRef(v:Value):Dynamic return nativeValues ? MacroNativeValues.decodeRef(v) : macros.eval.EvalDecode.decodeRef(v);

	public static inline function compilerError(err:core.Error.CompilerError):Dynamic return nativeValues ? MacroNativeValues.compilerError(err) : macros.eval.EvalMain.compilerError(err);

	// port: EvalContext.exc_string (a string thrown into the macro code)
	public static function excString(s:String):Dynamic return nativeValues ? throw s : macros.eval.EvalContext.excString(s);

	// port: EvalPrinting.value_string
	public static function valueString(v:Value):String return nativeValues ? MacroNativeValues.valueString(v) : macros.eval.EvalPrinting.valueString(v);

	static inline function errorMessage(msg:String):Dynamic return nativeValues ? throw msg : macros.eval.EvalContext.errorMessage(msg);

	static inline function valueToExpr(v:Value, p:Pos):Expr return nativeValues ? MacroNativeValues.valueToExpr(v, p) : macros.eval.EvalMain.valueToExpr(v, p);

	// port: returns `Digest.to_hex` of upstream's raw digest (see EvalMain)
	static inline function valueSignature(v:Value):String return nativeValues ? MacroNativeValues.valueSignature(v) : macros.eval.EvalMain.valueSignature(v);

	static inline function encodeBytes(b:haxe.io.Bytes):Value return nativeValues ? ((b : Dynamic) : Value) : macros.eval.EvalEncode.encodeBytes(b);

	static inline function decodeBytes(v:Value):haxe.io.Bytes return nativeValues ? ((v : Dynamic) : haxe.io.Bytes) : macros.eval.EvalDecode.decodeBytes(v); // haxe.io.Bytes

	// port: EvalMain.prepare_callback = EvalMisc.prepare_callback
	static inline function prepareCallback(v:Value, nargs:Int):Array<Value>->Value return nativeValues ? cast MacroNativeValues.prepareCallback(v, nargs) : macros.eval.EvalMisc.prepareCallback(v, nargs);

	static inline function getApiCallPos():Pos return nativeValues ? MacroNativeValues.apiCallPos() : macros.eval.EvalMain.getApiCallPos();

	static inline function associateEnumValuePos(v:Value, p:Pos):Void if (nativeValues) MacroNativeValues.associateEnumValuePos(v, p) else macros.eval.EvalValue.EvalValueTools.associateEnumValuePos(v, p);

	// port: Helpers

	static inline function fld(name:String, value:Value):ObjField return {name: name, value: value};

	// port: OCaml `v = vnull`.
	public static function isNull(v:Value):Bool return nativeValues ? v == null : switch v {
		case VNull: true;
		case _: false;
	}

	// port: OCaml structural equality on positions.
	static function posEq(a:Pos, b:Pos):Bool return a.pfile == b.pfile && a.pmin == b.pmin && a.pmax == b.pmax;

	static function isNotFound(e:Dynamic):Bool return Std.isOfType(e, NotFound)
		|| (Std.isOfType(e, String) && (e : String) == "Not_found");

	static function notSupported(what:String):Dynamic throw new core.ds.Failure(what + " is not supported by haxe-in-haxe");

	// The whole encoding/decoding of compiler values from/to interpreter values based on interpreter api

	static function vnullOr<A>(f:A->Value, v:Null<A>):Value return v == null ? vnull : f(v);

	static function encodeEnum(k:EnumType, tag:Int, vl:Vector<Value>,
			?pos:Pos):Value return nativeValues ? MacroNativeValues.encodeEnum(k, pos, tag, vl.toArray()) : macros.eval.EvalEncode.encodeEnum(k, pos, tag, vl);

	public static function encodeStringLiteralKind(qs:StringLiteralKind):Value {
		var tag = switch qs {
			case SDoubleQuotes: 0;
			case SSingleQuotes: 1;
		}
		return encodeEnum(IStringLiteralKind, tag, vector());
	}

	public static function encodeConst(c:Constant):Value {
		return switch c {
			case Int(s, suffix): encodeEnum(IConst, 0, vector(encodeString(s), vnullOr(encodeString, suffix)));
			case Float(s, suffix): encodeEnum(IConst, 1, vector(encodeString(s), vnullOr(encodeString, suffix)));
			case String(s, qs): encodeEnum(IConst, 2, vector(encodeString(s), encodeStringLiteralKind(qs)));
			case Ident(s): encodeEnum(IConst, 3, vector(encodeString(s)));
			case Regexp(s, opt): encodeEnum(IConst, 4, vector(encodeString(s), encodeString(opt)));
		}
	}

	public static function encodeBinop(op:Binop):Value {
		return switch op {
			case OpAdd: encodeEnum(IBinop, 0, vector());
			case OpMult: encodeEnum(IBinop, 1, vector());
			case OpDiv: encodeEnum(IBinop, 2, vector());
			case OpSub: encodeEnum(IBinop, 3, vector());
			case OpAssign: encodeEnum(IBinop, 4, vector());
			case OpEq: encodeEnum(IBinop, 5, vector());
			case OpNotEq: encodeEnum(IBinop, 6, vector());
			case OpGt: encodeEnum(IBinop, 7, vector());
			case OpGte: encodeEnum(IBinop, 8, vector());
			case OpLt: encodeEnum(IBinop, 9, vector());
			case OpLte: encodeEnum(IBinop, 10, vector());
			case OpAnd: encodeEnum(IBinop, 11, vector());
			case OpOr: encodeEnum(IBinop, 12, vector());
			case OpXor: encodeEnum(IBinop, 13, vector());
			case OpBoolAnd: encodeEnum(IBinop, 14, vector());
			case OpBoolOr: encodeEnum(IBinop, 15, vector());
			case OpShl: encodeEnum(IBinop, 16, vector());
			case OpShr: encodeEnum(IBinop, 17, vector());
			case OpUShr: encodeEnum(IBinop, 18, vector());
			case OpMod: encodeEnum(IBinop, 19, vector());
			case OpAssignOp(op): encodeEnum(IBinop, 20, vector(encodeBinop(op)));
			case OpInterval: encodeEnum(IBinop, 21, vector());
			case OpArrow: encodeEnum(IBinop, 22, vector());
			case OpIn: encodeEnum(IBinop, 23, vector());
			case OpNullCoal: encodeEnum(IBinop, 24, vector());
		}
	}

	public static function encodeUnop(op:Unop):Value {
		var tag = switch op {
			case Increment: 0;
			case Decrement: 1;
			case Not: 2;
			case Neg: 3;
			case NegBits: 4;
			case Spread: 5;
		}
		return encodeEnum(IUnop, tag, vector());
	}

	public static function encodeImport(imp:Import):Value {
		var mode = switch imp.mode {
			case INormal: encodeEnum(IImportMode, 0, vector());
			case IAsName(pn): encodeEnum(IImportMode, 1, vector(encodeString(pn.name)));
			case IAll: encodeEnum(IImportMode, 2, vector());
		}
		return encodeObj([
			fld("path", encodeArrayV(imp.path.map(pn -> encodeObj([fld("pos", encodePos(pn.pos)), fld("name", encodeString(pn.name))])))),
			fld("mode", mode)
		]);
	}

	public static function encodePlacedName(pn:PlacedName):Value return encodeString(pn.name);

	/** Globals.path **/
	public static function encodePath(p:GlobalTypePath):Value {
		return encodeObj([
			fld("pack", encodeArrayV(p.pack.mapToVector(encodeString))),
			fld("name", encodeString(p.name)),
		]);
	}

	/** Ast.placed_type_path **/
	public static function encodeAstPath(ptp:PlacedTypePath):Value {
		var t = ptp.path;
		var fields = [
			fld("pack", encodeArrayV(t.tpackage.mapToVector(encodeString))),
			fld("name", encodeString(t.tname)),
			fld("params", encodeArrayV(t.tparams.map(encodeTparam))),
			fld("pos", encodePos(ptp.posFull)),
		];
		if (!posEq(ptp.posFull, ptp.posPath))
			fields.unshift(fld("posPath", encodePos(ptp.posPath)));
		if (t.tsub != null)
			fields.unshift(fld("sub", encodeString(t.tsub)));
		return encodeObj(fields);
	}

	public static function encodeTparam(tp:TypeParamOrConst):Value {
		return switch tp {
			case TPType(t): encodeEnum(ITParam, 0, vector(encodeCtype(t)));
			case TPExpr(e): encodeEnum(ITParam, 1, vector(encodeExpr(e)));
		}
	}

	public static function encodeAccess(a:PlacedAccess):Value {
		var tag = switch a.access {
			case APublic: 0;
			case APrivate: 1;
			case AStatic: 2;
			case AOverride: 3;
			case ADynamic: 4;
			case AInline: 5;
			case AMacro: 6;
			case AFinal: 7;
			case AExtern: 8;
			case AAbstract: 9;
			case AOverload: 10;
			case AEnum: 11;
		}
		return encodeEnum(IAccess, tag, vector(), a.pos);
	}

	public static function encodeMetaEntry(m:MetadataEntry):Value {
		return encodeObj([
			fld("name", encodeString(Meta.toString(m.meta))),
			fld("params", encodeArrayV(m.exprs.map(encodeExpr))),
			fld("pos", encodePos(m.pos)),
		]);
	}

	public static function encodeMetaContent(m:Metadata):Value return encodeArrayV(m.mapToVector(encodeMetaEntry));

	public static function encodeField(f:ClassField):Value {
		var kind = switch f.cffKind {
			case FVar(t, e): encodeEnum(IField, 0, vector(vnullOr(encodeCtype, t), vnullOr(encodeExpr, e)));
			case FFun(f): encodeEnum(IField, 1, vector(encodeFun(f)));
			case FProp(get, set, t, e): encodeEnum(IField, 2, vector(
					encodePlacedName(get),
					encodePlacedName(set),
					vnullOr(encodeCtype, t),
					vnullOr(encodeExpr, e)
				));
		}
		return encodeObj([
			fld("name", encodePlacedName(f.cffName)),
			fld("name_pos", encodePos(f.cffName.pos)),
			fld("doc", vnullOr(encodeString, Ast.genDocTextOpt(f.cffDoc))),
			fld("pos", encodePos(f.cffPos)),
			fld("kind", kind),
			fld("meta", encodeMetaContent(f.cffMeta)),
			fld("access", encodeArrayV(f.cffAccess.mapToVector(encodeAccess))),
		]);
	}

	public static function encodeCtype(t:TypeHint):Value {
		var r:{tag:Int, pl:Vector<Value>} = switch t.type {
			case CTPath(ptp): {tag: 0, pl: vector(encodeAstPath(ptp))};
			case CTFunction(pl, r): {tag: 1, pl: vector(encodeArrayV(pl.map(encodeCtype)), encodeCtype(r))};
			case CTAnonymous(fl): {tag: 2, pl: vector(encodeArrayV(fl.map(encodeField)))};
			case CTParent(t): {tag: 3, pl: vector(encodeCtype(t))};
			case CTExtend(tl, fields): {tag: 4, pl: vector(encodeArrayV(tl.map(encodeAstPath)), encodeArrayV(fields.map(encodeField)))};
			case CTOptional(t): {tag: 5, pl: vector(encodeCtype(t))};
			case CTNamed(n, t): {tag: 6, pl: vector(encodePlacedName(n), encodeCtype(t))};
			case CTIntersection(tl): {tag: 7, pl: vector(encodeArrayV(tl.map(encodeCtype)))};
		}
		return encodeEnum(ICType, r.tag, r.pl, t.pos);
	}

	public static function encodeTparamDecl(tp:TypeParam):Value {
		return encodeObj([
			fld("name", encodePlacedName(tp.tpName)),
			fld("name_pos", encodePos(tp.tpName.pos)),
			fld("params", encodeArrayV(tp.tpParams.map(encodeTparamDecl))),
			fld("constraints", tp.tpConstraints == null ? encodeArray([]) : encodeArray([encodeCtype(tp.tpConstraints)])),
			fld("meta", encodeMetaContent(tp.tpMeta)),
		]);
	}

	public static function encodeFun(f:Func):Value {
		return encodeObj([
			fld("params", encodeArrayV(f.fParams.map(encodeTparamDecl))),
			fld("args", encodeArrayV(f.fArgs.map(a -> encodeObj([
				fld("name", encodePlacedName(a.name)),
				fld("name_pos", encodePos(a.name.pos)),
				fld("opt", vbool(a.optional)),
				fld("meta", encodeMetaContent(a.meta)),
				fld("type", vnullOr(encodeCtype, a.type)),
				fld("value", vnullOr(encodeExpr, a.expr)),
			])))),
			fld("ret", vnullOr(encodeCtype, f.fType)),
			fld("expr", vnullOr(encodeExpr, f.fExpr))
		]);
	}

	public static function encodeDisplayKind(dk:DisplayKind):Value {
		return switch dk {
			case DKCall: encodeEnum(IDisplayKind, 0, vector());
			case DKDot: encodeEnum(IDisplayKind, 1, vector());
			case DKStructure: encodeEnum(IDisplayKind, 2, vector());
			case DKMarked: encodeEnum(IDisplayKind, 3, vector());
			case DKPattern(outermost): encodeEnum(IDisplayKind, 4, vector(vbool(outermost)));
		}
	}

	public static function encodeDisplayMode(dm:DisplayModeValue):Value {
		return switch dm {
			case DMNone: encodeEnum(IDisplayMode, 0, vector());
			case DMDefault: encodeEnum(IDisplayMode, 1, vector());
			case DMDefinition: encodeEnum(IDisplayMode, 2, vector());
			case DMTypeDefinition: encodeEnum(IDisplayMode, 3, vector());
			case DMImplementation: encodeEnum(IDisplayMode, 4, vector());
			case DMPackage: encodeEnum(IDisplayMode, 5, vector());
			case DMHover: encodeEnum(IDisplayMode, 6, vector());
			case DMUsage(withDefinition, findDescendants,
				findBase): encodeEnum(IDisplayMode, 7, vector(vbool(withDefinition), vbool(findDescendants), vbool(findBase)));
			case DMModuleSymbols(null): encodeEnum(IDisplayMode, 8, vector());
			case DMModuleSymbols(s): encodeEnum(IDisplayMode, 9, vector(encodeString(s)));
			case DMSignature: encodeEnum(IDisplayMode, 10, vector());
		}
	}

	public static function encodePlatform(p:Platform):Value {
		return switch p {
			case Cross: encodeEnum(IPlatform, 0, vector());
			case Js: encodeEnum(IPlatform, 1, vector());
			case Lua: encodeEnum(IPlatform, 2, vector());
			case Neko: encodeEnum(IPlatform, 3, vector());
			case Flash: encodeEnum(IPlatform, 4, vector());
			case Php: encodeEnum(IPlatform, 5, vector());
			case Cpp: encodeEnum(IPlatform, 6, vector());
			case Jvm: encodeEnum(IPlatform, 7, vector());
			case Python: encodeEnum(IPlatform, 8, vector());
			case Hl: encodeEnum(IPlatform, 9, vector());
			case Eval: encodeEnum(IPlatform, 10, vector());
			case CustomTarget(s): encodeEnum(IPlatform, 11, vector(encodeString(s)));
		}
	}

	public static function encodePlatformConfig(pc:PlatformConfig):Value {
		return encodeObj([
			fld("staticTypeSystem", vbool(pc.pfStatic)),
			fld("sys", vbool(pc.pfSys)),
			fld("capturePolicy", encodeCapturePolicy(pc.pfCapturePolicy)),
			fld("padNulls", vbool(pc.pfPadNulls)),
			fld("addFinalReturn", vbool(pc.pfAddFinalReturn)),
			fld("overloadFunctions", vbool(pc.pfOverload)),
			fld("reservedTypePaths", encodeArrayV(pc.pfReservedTypePaths.mapToVector(encodePath))),
			fld("supportsFunctionEquality", vbool(pc.pfSupportsFunctionEquality)),
			fld("usesUtf16", vbool(pc.pfUsesUtf16)),
			fld("thisBeforeSuper", vbool(pc.pfThisBeforeSuper)),
			fld("supportsThreads", vbool(pc.pfSupportsThreads)),
			fld("supportsUnicode", vbool(pc.pfSupportsUnicode)),
			fld("supportsRestArgs", vbool(pc.pfSupportsRestArgs)),
			fld("exceptions", encodeExceptionsConfig(pc.pfExceptions)),
			fld("scoping", encodeVarScopingConfig(pc.pfScoping)),
			fld("supportsAtomics", vbool(pc.pfSupportsAtomics)),
		]);
	}

	public static function encodeCapturePolicy(cp:CapturePolicy):Value {
		var tag = switch cp {
			case CPNone: 0;
			case CPWrapRef: 1;
			case CPLoopVars: 2;
		}
		return encodeEnum(ICapturePolicy, tag, vector());
	}

	public static function encodeVarScopingConfig(vsc:VarScopingConfig):Value {
		return encodeObj([
			fld("scope", encodeVarScope(vsc.vsScope)),
			fld("flags", encodeArrayV(vsc.vsFlags.mapToVector(encodeVarScopingFlags))),
		]);
	}

	public static function encodeVarScope(vs:VarScope):Value {
		var tag = switch vs {
			case FunctionScope: 0;
			case BlockScope: 1;
		}
		return encodeEnum(IVarScope, tag, vector());
	}

	public static function encodeVarScopingFlags(vsf:VarScopingFlags):Value {
		return switch vsf {
			case VarHoisting: encodeEnum(IVarScopingFlags, 0, vector());
			case NoShadowing: encodeEnum(IVarScopingFlags, 1, vector());
			case NoCatchVarShadowing: encodeEnum(IVarScopingFlags, 2, vector());
			case ReserveCurrentTopLevelSymbol: encodeEnum(IVarScopingFlags, 3, vector());
			case ReserveAllTopLevelSymbols: encodeEnum(IVarScopingFlags, 4, vector());
			case ReserveAllTypesFlat: encodeEnum(IVarScopingFlags, 5, vector());
			case ReserveNames(names): encodeEnum(IVarScopingFlags, 6, vector(encodeArrayV(names.mapToVector(encodeString))));
			case SwitchCasesNoBlocks: encodeEnum(IVarScopingFlags, 7, vector());
		}
	}

	public static function encodeExceptionsConfig(ec:ExceptionsConfig):Value {
		return encodeObj([
			fld("nativeThrows", encodeArrayV(ec.ecNativeThrows.mapToVector(encodePath))),
			fld("nativeCatches", encodeArrayV(ec.ecNativeCatches.mapToVector(encodePath))),
			fld("avoidWrapping", vbool(ec.ecAvoidWrapping)),
			fld("wildcardCatch", encodePath(ec.ecWildcardCatch)),
			fld("baseThrow", encodePath(ec.ecBaseThrow)),
			// skipping "specialThrow" since cannot use "decode_texpr" here
		]);
	}

	public static function encodePackageRule(pr:PackageRule):Value {
		return switch pr {
			case Forbidden: encodeEnum(IPackageRule, 0, vector());
			case Remap(path): encodeEnum(IPackageRule, 2, vector(encodeString(path)));
		}
	}

	public static function encodeMessage(cm:CompilerMessage):Value {
		return switch core.Message.Message.severity(cm) {
			case Information: encodeEnum(IMessage, 0, vector(encodeString(cm.cmMessage), encodePos(cm.cmPos)));
			case Warning | Hint: encodeEnum(IMessage, 1, vector(encodeString(cm.cmMessage), encodePos(cm.cmPos)));
			case Error: Globals.die("", "macroApi.ml encode_message");
		}
	}

	public static function encodeEfieldKind(efk:EFieldKind):Value {
		var i = switch efk {
			case EFNormal: 0;
			case EFSafe: 1;
		}
		return encodeEnum(IEFieldKind, i, vector());
	}

	public static function encodeExpr(e:Expr):Value {
		function loop(e:Expr):Value {
			var p = e.pos;
			var r:{tag:Int, pl:Vector<Value>} = switch e.expr {
				case EConst(c):
					{tag: 0, pl: vector(encodeConst(c))};
				case EArray(e1, e2):
					{tag: 1, pl: vector(loop(e1), loop(e2))};
				case EBinop(op, e1, e2):
					{tag: 2, pl: vector(encodeBinop(op), loop(e1), loop(e2))};
				case EField(e, f, efk):
					{tag: 3, pl: vector(loop(e), encodeString(f), encodeEfieldKind(efk))};
				case EParenthesis(e):
					{tag: 4, pl: vector(loop(e))};
				case EObjectDecl(fl):
					{
						tag: 5,
						pl: vector(
							encodeArrayV(fl.map(of -> encodeObj([
								fld("field", encodeString(of.key.name)),
								fld("name_pos", encodePos(of.key.pos)),
								fld("quotes", encodeEnum(IQuoteStatus, switch of.key.quote {
									case NoQuotes: 0;
									case DoubleQuotes: 1;
								}, vector())),
								fld("expr", loop(of.expr)),
							])))
						)
					};
				case EArrayDecl(el):
					{tag: 6, pl: vector(encodeArrayV(el.map(loop)))};
				case ECall(e, el):
					{tag: 7, pl: vector(loop(e), encodeArrayV(el.map(loop)))};
				case ENew(p, el):
					{tag: 8, pl: vector(encodeAstPath(p), encodeArrayV(el.map(loop)))};
				case EUnop(op, flag, e):
					{
						tag: 9,
						pl: vector(
							encodeUnop(op),
							vbool(switch flag {
								case Prefix: false;
								case Postfix: true;
							}),
							loop(e)
						)
					};
				case EVars(vl):
					{
						tag: 10,
						pl: vector(
							encodeArrayV(vl.map(v -> encodeObj([
								fld("name", encodePlacedName(v.evName)),
								fld("namePos", encodePos(v.evName.pos)),
								fld("isFinal", vbool(v.evFinal)),
								fld("isStatic", vbool(v.evStatic)),
								fld("type", vnullOr(encodeCtype, v.evType)),
								fld("expr", vnullOr(loop, v.evExpr)),
								fld("meta", encodeMetaContent(v.evMeta)),
							])))
						)
					};
				case EFunction(kind, f):
					{tag: 11, pl: vector(encodeFunctionKind(kind), encodeFun(f))};
				case EBlock(el):
					{tag: 12, pl: vector(encodeArrayV(el.map(loop)))};
				case EFor(e, eloop):
					{tag: 13, pl: vector(loop(e), loop(eloop))};
				case EIf(econd, e, eelse):
					{tag: 14, pl: vector(loop(econd), loop(e), vnullOr(loop, eelse))};
				case EWhile(econd, e, flag):
					{
						tag: 15,
						pl: vector(
							loop(econd),
							loop(e),
							vbool(switch flag {
								case NormalWhile: true;
								case DoWhile: false;
							})
						)
					};
				case ESwitch(e, cases, eopt):
					{
						tag: 16,
						pl: vector(
							loop(e),
							encodeArrayV(cases.map(c -> encodeObj([
								fld("values", encodeArrayV(c.values.map(loop))),
								fld("guard", vnullOr(loop, c.guard)),
								fld("expr", vnullOr(loop, c.expr)),
								fld("pos", encodePos(c.pos)),
							]))),
							vnullOr((d:SwitchDefault) -> encodeNullExpr(d.expr), eopt)
						)
					};
				case ETry(e, catches):
					{
						tag: 17,
						pl: vector(
							loop(e),
							encodeArrayV(catches.map(c -> encodeObj([
								fld("name", encodePlacedName(c.name)),
								fld("name_pos", encodePos(c.name.pos)),
								fld("type", vnullOr(encodeCtype, c.type)),
								fld("expr", loop(c.expr)),
								fld("pos", encodePos(c.pos))
							])))
						)
					};
				case EReturn(eo):
					{tag: 18, pl: vector(vnullOr(loop, eo))};
				case EBreak:
					{tag: 19, pl: vector()};
				case EContinue:
					{tag: 20, pl: vector()};
				case EUntyped(e):
					{tag: 21, pl: vector(loop(e))};
				case EThrow(e):
					{tag: 22, pl: vector(loop(e))};
				case ECast(e, t):
					{tag: 23, pl: vector(loop(e), vnullOr(encodeCtype, t))};
				case EDisplay(e, dk):
					{tag: 24, pl: vector(loop(e), encodeDisplayKind(dk))};
				case ETernary(econd, e1, e2):
					{tag: 25, pl: vector(loop(econd), loop(e1), loop(e2))};
				case ECheckType(e, t):
					{tag: 26, pl: vector(loop(e), encodeCtype(t))};
				case EMeta(m, e):
					{tag: 27, pl: vector(encodeMetaEntry(m), loop(e))};
				case EIs(e, t):
					{tag: 28, pl: vector(loop(e), encodeCtype(t))};
			}
			return encodeObj([fld("pos", encodePos(p)), fld("expr", encodeEnum(IExpr, r.tag, r.pl)),]);
		}
		return encodeLazy(AtomicLazy.fromFun(() -> loop(e)));
	}

	public static function encodeNullExpr(e:Null<Expr>):Value {
		return if (e == null) encodeObj([fld("pos", vnull), fld("expr", vnull)]); else encodeExpr(e);
	}

	public static function encodeFunctionKind(kind:FunctionKind):Value {
		return switch kind {
			case FKAnonymous: encodeEnum(IFunctionKind, 0, vector());
			case FKNamed(name, inl): encodeEnum(IFunctionKind, 1, vector(encodePlacedName(name), vbool(inl)));
			case FKArrow: encodeEnum(IFunctionKind, 2, vector());
		}
	}

	// ---------------------------------------------------------------------- //
	// EXPR DECODING

	static function opt<A>(f:Value->A, v:Value):Null<A> return isNull(v) ? null : f(v);

	static function optList<A>(f:Value->Array<A>, v:Value):Array<A> return isNull(v) ? [] : f(v);

	static function decodeOptBool(v:Value):Bool return isNull(v) ? false : decodeBool(v);

	public static function decodeStringLiteralKind(v:Value):StringLiteralKind {
		if (isNull(v))
			return SDoubleQuotes;
		return switch decodeEnum(v) {
			case {index: 0, args: []}: SDoubleQuotes;
			case {index: 1, args: []}: SSingleQuotes;
			case _: throw InvalidExpr.raise();
		}
	}

	public static function decodeConst(c:Value):Constant {
		return switch decodeEnum(c) {
			case {index: 0, args: [s, suffix]}:
				var decodedSuffix = opt(decodeString, suffix);
				switch decodedSuffix {
					case null | "i32" | "i64" | "u32":
						Constant.Int(decodeString(s), decodedSuffix);
					case _:
						throw InvalidExpr.raise();
				}
			case {index: 1, args: [s, suffix]}:
				var decodedSuffix = opt(decodeString, suffix);
				switch decodedSuffix {
					case null | "f64":
						Constant.Float(decodeString(s), opt(decodeString, suffix));
					case _:
						throw InvalidExpr.raise();
				}
			case {index: 2, args: [s, qs]}: Constant.String(decodeString(s), decodeStringLiteralKind(qs));
			case {index: 3, args: [s]}: Constant.Ident(decodeString(s));
			case {index: 4, args: [s, opt]}: Constant.Regexp(decodeString(s), decodeString(opt));
			case {index: 5, args: [s]}: Constant.Ident(decodeString(s)); // deprecated CType, keep until 3.0 release
			case _: throw InvalidExpr.raise();
		}
	}

	public static function decodeOp(op:Value):Binop {
		return switch decodeEnum(op) {
			case {index: 0, args: []}: OpAdd;
			case {index: 1, args: []}: OpMult;
			case {index: 2, args: []}: OpDiv;
			case {index: 3, args: []}: OpSub;
			case {index: 4, args: []}: OpAssign;
			case {index: 5, args: []}: OpEq;
			case {index: 6, args: []}: OpNotEq;
			case {index: 7, args: []}: OpGt;
			case {index: 8, args: []}: OpGte;
			case {index: 9, args: []}: OpLt;
			case {index: 10, args: []}: OpLte;
			case {index: 11, args: []}: OpAnd;
			case {index: 12, args: []}: OpOr;
			case {index: 13, args: []}: OpXor;
			case {index: 14, args: []}: OpBoolAnd;
			case {index: 15, args: []}: OpBoolOr;
			case {index: 16, args: []}: OpShl;
			case {index: 17, args: []}: OpShr;
			case {index: 18, args: []}: OpUShr;
			case {index: 19, args: []}: OpMod;
			case {index: 20, args: [op]}: OpAssignOp(decodeOp(op));
			case {index: 21, args: []}: OpInterval;
			case {index: 22, args: []}: OpArrow;
			case {index: 23, args: []}: OpIn;
			case {index: 24, args: []}: OpNullCoal;
			case _: throw InvalidExpr.raise();
		}
	}

	public static function decodeUnop(op:Value):Unop {
		return switch decodeEnum(op) {
			case {index: 0, args: []}: Increment;
			case {index: 1, args: []}: Decrement;
			case {index: 2, args: []}: Not;
			case {index: 3, args: []}: Neg;
			case {index: 4, args: []}: NegBits;
			case {index: 5, args: []}: Spread;
			case _: throw InvalidExpr.raise();
		}
	}

	public static function decodeImportMode(t:Value):ImportMode {
		return switch decodeEnum(t) {
			case {index: 0, args: []}: ImportMode.INormal;
			case {index: 1, args: [alias]}: ImportMode.IAsName({
					name: decodeString(alias),
					pos: Globals.nullPos
				}); // TODO: is it okay to lose the pos here?
			case {index: 2, args: []}: ImportMode.IAll;
			case _: throw InvalidExpr.raise();
		}
	}

	public static function decodeImport(t:Value):Import {
		var path:Vector<PlacedName> = mapDecodedArray(field(t,
			"path"), o -> ({name: decodeString(field(o, "name")), pos: decodePos(field(o, "pos"))} : PlacedName));
		return {path: path, mode: decodeImportMode(field(t, "mode"))};
	}

	static function maybeDecodePos(p:Value):Pos {
		return try decodePos(p) catch (_:InvalidExpr) Globals.nullPos;
	}

	static function decodePosDefault(p:Value, pd:Pos):Pos {
		return try decodePos(p) catch (_:InvalidExpr) pd;
	}

	static function decodePlacedName(vp:Value, v:Value):PlacedName {
		return {name: decodeString(v), pos: maybeDecodePos(vp)};
	}

	static function decodeOptArray<A>(f:Value->A, v:Value):Array<A> return isNull(v) ? [] : decodeArray(v).map(f);

	// port: `List.map f (decode_array v)` for the AST lists, which are Vectors here:
	// allocated at the array's length and filled in order, with no list in between
	static inline function mapDecodedArray<A>(v:Value, f:Value->A):Vector<A> {
		// port: native values (MacroNativeValues): the macro code's Array
		if (nativeValues) {
			var a:Array<Value> = cast MacroNativeValues.decodeArray(v);
			var r = new Vector<A>(a.length);
			for (i in 0...a.length) r[i] = f(a[i]);
			return r;
		}
		var va = macros.eval.EvalDecode.decodeVarray(v);
		var r = new Vector<A>(va.alength);
		for (i in 0...va.alength) r[i] = f(va.avalues[i]);
		return r;
	}

	// port: `decode_opt_array` for the AST lists
	static inline function decodeOptVector<A>(f:Value->A, v:Value):Vector<A> return isNull(v) ? vector() : mapDecodedArray(v, f);

	public static function decodeSubErrors(sub:Value):Array<core.Error.MacroError> {
		function decodeSub(o:Value):core.Error.MacroError {
			var msg = decodeString(field(o, "msg"));
			var pos = decodePos(field(o, "pos"));
			var sub = decodeOptArray(decodeSub, field(o, "sub"));
			return {msg: msg, pos: pos, sub: sub};
		}
		return decodeOptArray(decodeSub, sub);
	}

	/** Ast.placed_type_path **/
	public static function decodeAstPath(t:Value):PlacedTypePath {
		var pack = decodeArray(field(t, "pack")).map(decodeString);
		var name = decodeString(field(t, "name"));
		var params = decodeOptVector(decodeTparam, field(t, "params"));
		var sub = opt(decodeString, field(t, "sub"));
		var pFull = field(t, "pos");
		var pFull = if (isNull(pFull)) Globals.nullPos else decodePos(pFull);
		var pPath = field(t, "posPath");
		var pPath = if (isNull(pPath)) pFull else decodePos(pPath);
		return Ast.makePtp(Ast.mkTypePath(pack, name, params, sub), pFull, pPath);
	}

	public static function decodeTparam(v:Value):TypeParamOrConst {
		return switch decodeEnum(v) {
			case {index: 0, args: [t]}: TPType(decodeCtype(t));
			case {index: 1, args: [e]}: TPExpr(decodeExpr(e));
			case _: throw InvalidExpr.raise();
		}
	}

	public static function decodeTparams(v:Value):Vector<TypeParam> return decodeOptVector(decodeTparamDecl, v);

	public static function decodeTparamDecl(v:Value):TypeParam {
		var vconstraints = field(v, "constraints");
		var vdefault = field(v, "defaultType");
		var tpName = decodePlacedName(field(v, "name_pos"), field(v, "name"));
		var tpConstraints:Null<TypeHint> = if (isNull(vconstraints)) null else switch decodeArray(vconstraints) {
			case []: null;
			case [t]: decodeCtype(t);
			case tl: {type: CTIntersection(tl.mapToVector(decodeCtype)), pos: Globals.nullPos};
		}
		var tpDefault = opt(decodeCtype, vdefault);
		var tpParams = decodeTparams(field(v, "params"));
		var tpMeta = decodeMetaContent(field(v, "meta"));
		return {
			tpName: tpName,
			tpConstraints: tpConstraints,
			tpDefault: tpDefault,
			tpParams: tpParams,
			tpMeta: tpMeta,
		};
	}

	public static function decodeFun(v:Value):Func {
		var fParams = decodeTparams(field(v, "params"));
		var fArgs = mapDecodedArray(field(v, "args"), o -> ({
			name: decodePlacedName(field(o, "name_pos"), field(o, "name")),
			optional: decodeOptBool(field(o, "opt")),
			meta: decodeMetaContent(field(o, "meta")),
			type: opt(decodeCtype, field(o, "type")),
			expr: opt(decodeExpr, field(o, "value"))
		} : FuncArg));
		var fType = opt(decodeCtype, field(v, "ret"));
		var fExpr = opt(decodeExpr, field(v, "expr"));
		return {
			fParams: fParams,
			fArgs: fArgs,
			fType: fType,
			fExpr: fExpr,
		};
	}

	public static function decodeAccess(v:Value):PlacedAccess {
		var d = decodeEnumWithPos(v);
		var a = switch d.index {
			case 0: APublic;
			case 1: APrivate;
			case 2: AStatic;
			case 3: AOverride;
			case 4: ADynamic;
			case 5: AInline;
			case 6: AMacro;
			case 7: AFinal;
			case 8: AExtern;
			case 9: AAbstract;
			case 10: AOverload;
			case 11: AEnum;
			case _: throw InvalidExpr.raise();
		}
		return {access: a, pos: d.pos};
	}

	public static function decodeMetaEntry(v:Value):MetadataEntry {
		return {
			meta: Meta.fromString(decodeString(field(v, "name"))),
			exprs: decodeOptVector(decodeExpr, field(v, "params")),
			pos: decodePos(field(v, "pos"))
		};
	}

	public static function decodeMetaContent(m:Value):Metadata return decodeOptArray(decodeMetaEntry, m);

	static function decodeDoc(v:Value):Documentation return opt(s -> ({docOwn: decodeString(s), docInherited: []} : DocBlock), v);

	public static function decodeClassFieldKind(v:Value):ClassFieldKind {
		return switch decodeEnum(v) {
			case {index: 0, args: [t, e]}:
				FVar(opt(decodeCtype, t), opt(decodeExpr, e));
			case {index: 1, args: [f]}:
				FFun(decodeFun(f));
			case {index: 2, args: [get, set, t, e]}:
				FProp(decodePlacedName(vnull, get), decodePlacedName(vnull, set), opt(decodeCtype, t), opt(decodeExpr, e));
			case _:
				throw InvalidExpr.raise();
		}
	}

	public static function decodeField(v:Value):ClassField {
		var fkind = decodeClassFieldKind(field(v, "kind"));
		var pos = decodePos(field(v, "pos"));
		return {
			cffName: {name: decodeString(field(v, "name")), pos: decodePosDefault(field(v, "name_pos"), pos)},
			cffDoc: decodeDoc(field(v, "doc")),
			cffPos: pos,
			cffKind: fkind,
			cffAccess: optList(decodeArray, field(v, "access")).map(decodeAccess),
			cffMeta: optList(decodeMetaContent, field(v, "meta")),
		};
	}

	public static function decodeCtype(t:Value):TypeHint {
		var d = decodeEnumWithPos(t);
		var p = d.pos;
		var ct = switch {index: d.index, args: d.args} {
			case {index: 0, args: [p]}:
				CTPath(decodeAstPath(p));
			case {index: 1, args: [a, r]}:
				CTFunction(mapDecodedArray(a, decodeCtype), decodeCtype(r));
			case {index: 2, args: [fl]}:
				CTAnonymous(mapDecodedArray(fl, decodeField));
			case {index: 3, args: [t]}:
				CTParent(decodeCtype(t));
			case {index: 4, args: [tl, fl]}:
				CTExtend(mapDecodedArray(tl, decodeAstPath), mapDecodedArray(fl, decodeField));
			case {index: 5, args: [t]}:
				CTOptional(decodeCtype(t));
			case {index: 6, args: [n, t]}:
				CTNamed({name: decodeString(n), pos: p}, decodeCtype(t));
			case {index: 7, args: [tl]}:
				CTIntersection(mapDecodedArray(tl, decodeCtype));
			case _:
				throw InvalidExpr.raise();
		}
		return {type: ct, pos: p};
	}

	public static function decodeDisplayKind(v:Value):DisplayKind {
		return switch decodeEnum(v) {
			case {index: 0, args: []}: DKCall;
			case {index: 1, args: []}: DKDot;
			case {index: 2, args: []}: DKStructure;
			case {index: 3, args: []}: DKMarked;
			case {index: 4, args: [outermost]}: DKPattern(decodeBool(outermost));
			case _: throw InvalidExpr.raise();
		}
	}

	public static function decodeFunctionKind(kind:Value):FunctionKind {
		if (isNull(kind))
			return FKAnonymous;
		return switch decodeEnum(kind) {
			case {index: 0, args: []}: FKAnonymous;
			case {index: 1, args: [name, inl]}: FKNamed({name: decodeString(name), pos: Globals.nullPos}, decodeOptBool(inl));
			case {index: 2, args: []}: FKArrow;
			case _: throw InvalidExpr.raise();
		}
	}

	public static function decodeExpr(v:Value):Expr {
		// port: upstream has `try loop v with Stack_overflow -> raise Invalid_expr`
		return decodeExprLoop(v);
	}

	static function decodeExprLoop(v:Value):Expr {
		var p = decodePos(field(v, "pos"));
		return {expr: decodeExprDef(field(v, "expr"), p), pos: p};
	}

	static function decodeExprDef(e:Value, p:Pos):ExprDef {
		var loop = decodeExprLoop;
		return switch decodeEnum(e) {
			case {index: 0, args: [c]}:
				EConst(decodeConst(c));
			case {index: 1, args: [e1, e2]}:
				EArray(loop(e1), loop(e2));
			case {index: 2, args: [op, e1, e2]}:
				EBinop(decodeOp(op), loop(e1), loop(e2));
			case {index: 3, args: [e, f, efk]}:
				var efk = if (isNull(efk)) EFNormal else switch decodeEnum(efk) {
					case {index: 0, args: []}: EFNormal;
					case {index: 1, args: []}: EFSafe;
					case _: throw InvalidExpr.raise();
				}
				EField(loop(e), decodeString(f), efk);
			case {index: 4, args: [e]}:
				EParenthesis(loop(e));
			case {index: 5, args: [a]}:
				EObjectDecl(mapDecodedArray(a, o -> {
					var pn = decodePlacedName(field(o, "name_pos"), field(o, "field"));
					var vquotes = field(o, "quotes");
					var quotes = if (isNull(vquotes)) NoQuotes else switch decodeEnum(vquotes) {
						case {index: 0, args: []}: NoQuotes;
						case {index: 1, args: []}: DoubleQuotes;
						case _: throw InvalidExpr.raise();
					}
						({key: {name: pn.name, pos: pn.pos, quote: quotes}, expr: loop(field(o, "expr"))} : ObjectField);
				}));
			case {index: 6, args: [a]}:
				EArrayDecl(mapDecodedArray(a, loop));
			case {index: 7, args: [e, el]}:
				ECall(loop(e), mapDecodedArray(el, loop));
			case {index: 8, args: [t, el]}:
				ENew(decodeAstPath(t), mapDecodedArray(el, loop));
			case {index: 9, args: [op, f, e]}:
				EUnop(decodeUnop(op), if (decodeBool(f)) Postfix else Prefix, loop(e));
			case {index: 10, args: [vl]}:
				EVars(mapDecodedArray(vl, v -> {
					var vfinal = field(v, "isFinal");
					var isFinal = if (isNull(vfinal)) false else decodeBool(vfinal);
					var vstatic = field(v, "isStatic");
					var isStatic = if (isNull(vstatic)) false else decodeBool(vstatic);
					var vmeta = field(v, "meta");
					var meta = if (isNull(vmeta)) [] else decodeMetaContent(vmeta);
					var namePos = maybeDecodePos(field(v, "namePos"));
					var namePos = if (posEq(namePos, Globals.nullPos)) p else namePos;
					var name:PlacedName = {name: decodeString(field(v, "name")), pos: namePos};
					var t = opt(decodeCtype, field(v, "type"));
					var eo = opt(loop, field(v, "expr"));
					Ast.mkEVar(name, isFinal, isStatic, t, eo, meta);
				}));
			case {index: 11, args: [kind, f]}:
				EFunction(decodeFunctionKind(kind), decodeFun(f));
			case {index: 12, args: [el]}:
				EBlock(mapDecodedArray(el, loop));
			case {index: 13, args: [e1, e2]}:
				EFor(loop(e1), loop(e2));
			case {index: 14, args: [e1, e2, e3]}:
				EIf(loop(e1), loop(e2), opt(loop, e3));
			case {index: 15, args: [e1, e2, flag]}:
				EWhile(loop(e1), loop(e2), if (decodeBool(flag)) NormalWhile else DoWhile);
			case {index: 16, args: [e, cases, eo]}:
				var cases = mapDecodedArray(cases, c -> ({
					values: mapDecodedArray(field(c, "values"), loop),
					guard: opt(loop, field(c, "guard")),
					expr: opt(loop, field(c, "expr")),
					pos: maybeDecodePos(field(c, "pos"))
				} : SwitchCase));
				ESwitch(loop(e), cases,
					opt(v -> ({expr: if (isNull(field(v, "expr"))) null else decodeExpr(v), pos: p} : SwitchDefault), eo));
			case {index: 17, args: [e, catches]}:
				var catches = mapDecodedArray(catches, c -> ({
					name: decodePlacedName(field(c, "name_pos"), field(c, "name")),
					type: opt(decodeCtype, field(c, "type")),
					expr: loop(field(c, "expr")),
					pos: maybeDecodePos(field(c, "pos"))
				} : Catch));
				ETry(loop(e), catches);
			case {index: 18, args: [e]}:
				EReturn(opt(loop, e));
			case {index: 19, args: []}:
				EBreak;
			case {index: 20, args: []}:
				EContinue;
			case {index: 21, args: [e]}:
				EUntyped(loop(e));
			case {index: 22, args: [e]}:
				EThrow(loop(e));
			case {index: 23, args: [e, t]}:
				ECast(loop(e), opt(decodeCtype, t));
			case {index: 24, args: [e, dk]}:
				EDisplay(loop(e), decodeDisplayKind(dk));
			case {index: 25, args: [e1, e2, e3]}:
				ETernary(loop(e1), loop(e2), loop(e3));
			case {index: 26, args: [e, t]}:
				ECheckType(loop(e), decodeCtype(t));
			case {index: 27, args: [m, e]}:
				EMeta(decodeMetaEntry(m), loop(e));
			case {index: 28, args: [e, t]}:
				EIs(loop(e), decodeCtype(t));
			case _:
				throw InvalidExpr.raise();
		}
	}

	// ---------------------------------------------------------------------- //
	// TYPE ENCODING

	static function encodePmapArray<A>(convert:A->Value, m:StringMap<A>):Value {
		var l = [];
		PMap.iter((_, v) -> l.push(convert(v)), m);
		return encodeArray(l);
	}

	static function encodeAndMapArray<A>(convert:A->Value, l:Array<A>):Value return encodeArrayV(l.mapToVector(convert));

	static function vopt<A>(f:A->Value, v:Null<A>):Value return v == null ? vnull : f(v);

	public static function encodeMeta(m:Metadata, set:Metadata->Void):Value {
		var meta = m;
		return encodeObj([
			fld("get", vfun0(() -> encodeMetaContent(meta))),
			fld("add", vfun3((k, vl, p) -> {
				var el = mapDecodedArray(vl, decodeExpr);
				var entry:MetadataEntry = {meta: Meta.fromString(decodeString(k)), exprs: el, pos: decodePos(p)};
				meta = [entry].concat(meta);
				set(meta);
				vnull;
			})),
			fld("extract", vfun1(k -> {
				var k = Meta.fromString(decodeString(k));
				encodeAndMapArray(encodeMetaEntry, meta.filter(m -> Meta.metaEq(k, m.meta)));
			})),
			fld("remove", vfun1(k -> {
				var k = Meta.fromString(decodeString(k));
				meta = meta.filter(m -> !Meta.metaEq(k, m.meta));
				set(meta);
				vnull;
			})),
			fld("has", vfun1(k -> {
				var k = Meta.fromString(decodeString(k));
				vbool(Lambda.exists(meta, m -> Meta.metaEq(k, m.meta)));
			})),
		]);
	}

	// port: `i.mt_meta <- m`: upstream's `t_infos` returns the type's own record,
	// while `TFunctions.tInfos` returns a copy, so the update is applied to
	// the module type itself.
	static function setMtMeta(t:ModuleType, m:Metadata):Void {
		switch t {
			case TClassDecl(c):
				c.clMeta = m;
			case TEnumDecl(e):
				e.eMeta = m;
			case TTypeDecl(t):
				t.tMeta = m;
			case TAbstractDecl(a):
				a.aMeta = m;
		}
	}

	public static function encodeMtype(t:ModuleType, fields:Array<ObjField>):Value {
		var i = tInfos(t);
		// port: evaluated right to left as upstream's list literal
		var params = encodeTypeParams(i.mtParams);
		var doc = vnullOr(encodeString, Ast.getOwnDocOpt(i.mtDoc));
		var meta = encodeMeta(i.mtMeta, m -> setMtMeta(t, m));
		var isPrivate = vbool(i.mtPrivate);
		var vmodule = encodeString(MacroApi.sTypePath(i.mtModule.mPath));
		var pos = encodePos(i.mtPos);
		var name = encodeString(i.mtPath.name);
		var pack = encodeArrayV(i.mtPath.pack.mapToVector(encodeString));
		var tdecl = encodeTdecl(t);
		return encodeObj([
			fld("__t", tdecl),
			fld("pack", pack),
			fld("name", name),
			fld("pos", pos),
			fld("module", vmodule),
			fld("isPrivate", isPrivate),
			fld("meta", meta),
			fld("doc", doc),
			fld("params", params),
		].concat(fields));
	}

	public static function encodeTypeParams(tl:TypeParams):Value {
		return encodeArrayV(tl.map(tp -> {
			var defaultType = tp.ttpDefault == null ? vnull : encodeType(tp.ttpDefault);
			var t = encodeType(tp.ttpType);
			var name = encodeString(tp.ttpName);
			encodeObj([fld("name", name), fld("t", t), fld("defaultType", defaultType),]);
		}));
	}

	public static function encodeTenum(e:TEnum):Value {
		var names = encodeArrayV(e.eNames.mapToVector(encodeString));
		var constructs = encodeStringMap(encodeEfield, e.eConstrs);
		var exclude = vfun0(() -> {
			addEnumFlag(e, EnExcluded);
			vnull;
		});
		var isExtern = vbool(hasEnumFlag(e, EnExtern));
		return encodeMtype(TEnumDecl(e), [
			fld("isExtern", isExtern),
			fld("exclude", exclude),
			fld("constructs", constructs),
			fld("names", names),
		]);
	}

	public static function encodeTabstract(a:TAbstract):Value {
		var resolveWrite = a.aWrite == null ? vnull : encodeCfref(a.aWrite);
		var resolve = a.aRead == null ? vnull : encodeCfref(a.aRead);
		var array = encodeArrayV(a.aArray.mapToVector(encodeCfield));
		inline function fromTo(l:Array<T>, lf:Array<{type:T, field:TClassField}>):Value {
			var withField = lf.map(x -> {
				var field = encodeCfield(x.field);
				var t = encodeType(x.type);
				encodeObj([fld("t", t), fld("field", field)]);
			});
			var withoutField = l.map(t -> {
				var field = vnull;
				encodeObj([fld("t", encodeType(t)), fld("field", field)]);
			});
			return encodeArray(withoutField.concat(withField));
		}
		var to = fromTo(a.aTo, a.aToField);
		var from = fromTo(a.aFrom, a.aFromField);
		var unops = encodeArrayV(a.aUnops.mapToVector(u -> {
			var field = encodeCfield(u.field);
			var postFix = vbool(switch u.flag {
				case Postfix: true;
				case Prefix: false;
			});
			var op = encodeUnop(u.op);
			encodeObj([fld("op", op), fld("postFix", postFix), fld("field", field)]);
		}));
		var binops = encodeArrayV(a.aOps.mapToVector(b -> {
			var field = encodeCfield(b.field);
			var op = encodeBinop(b.op);
			encodeObj([fld("op", op), fld("field", field)]);
		}));
		var impl = a.aImpl == null ? vnull : encodeClref(a.aImpl);
		var type = encodeType(a.aThis);
		return encodeMtype(TAbstractDecl(a), [
			fld("type", type),
			fld("impl", impl),
			fld("binops", binops),
			fld("unops", unops),
			fld("from", from),
			fld("to", to),
			fld("array", array),
			fld("resolve", resolve),
			fld("resolveWrite", resolveWrite),
		]);
	}

	public static function encodeEfield(f:TEnumField):Value {
		var params = encodeTypeParams(f.efParams);
		var doc = vnullOr(encodeString, Ast.getOwnDocOpt(f.efDoc));
		var meta = encodeMeta(f.efMeta, m -> f.efMeta = m);
		var index = vint(f.efIndex);
		var namePos = encodePos(f.efNamePos);
		var pos = encodePos(f.efPos);
		var type = encodeType(f.efType);
		var name = encodeString(f.efName);
		return encodeObj([
			fld("name", name),
			fld("type", type),
			fld("pos", pos),
			fld("namePos", namePos),
			fld("index", index),
			fld("meta", meta),
			fld("doc", doc),
			fld("params", params),
		]);
	}

	public static function encodeCfield(f:TClassField):Value {
		var isAbstract = vbool(hasClassFieldFlag(f, CfAbstract));
		var isFinal = vbool(hasClassFieldFlag(f, CfFinal));
		var isExtern = vbool(hasClassFieldFlag(f, CfExtern));
		var overloads = encodeRef(f.cfOverloads, l -> encodeAndMapArray(encodeCfield, l), () -> "overloads");
		var doc = vnullOr(encodeString, Ast.getOwnDocOpt(f.cfDoc));
		var namePos = encodePos(f.cfNamePos);
		var pos = encodePos(f.cfPos);
		var kind = encodeFieldKind(f.cfKind);
		var expr = vfun0(() -> {
			follow(f.cfType);
			f.cfExpr == null ? vnull : encodeTexpr(f.cfExpr);
		});
		var meta = encodeMeta(f.cfMeta, m -> f.cfMeta = m);
		var params = encodeTypeParams(f.cfParams);
		var isPublic = vbool(hasClassFieldFlag(f, CfPublic));
		var type = encodeLazyType(f.cfType);
		var name = encodeString(f.cfName);
		return encodeObj([
			fld("name", name),
			fld("type", type),
			fld("isPublic", isPublic),
			fld("params", params),
			fld("meta", meta),
			fld("expr", expr),
			fld("kind", kind),
			fld("pos", pos),
			fld("namePos", namePos),
			fld("doc", doc),
			fld("overloads", overloads),
			fld("isExtern", isExtern),
			fld("isFinal", isFinal),
			fld("isAbstract", isAbstract),
		]);
	}

	public static function encodeFieldKind(k:FieldKind):Value {
		return switch k {
			case Var(v):
				var write = encodeVarAccess(v.vWrite);
				var read = encodeVarAccess(v.vRead);
				encodeEnum(IFieldKind, 0, vector(read, write));
			case Method(m): encodeEnum(IFieldKind, 1, vector(encodeMethodKind(m)));
		}
	}

	public static function encodeVarAccess(a:VarAccess):Value {
		return switch a {
			case AccNormal: encodeEnum(IVarAccess, 0, vector());
			case AccNo: encodeEnum(IVarAccess, 1, vector());
			case AccNever: encodeEnum(IVarAccess, 2, vector());
			case AccCall: encodeEnum(IVarAccess, 4, vector());
			case AccPrivateCall: encodeEnum(IVarAccess, 5, vector());
			case AccInline: encodeEnum(IVarAccess, 6, vector());
			case AccRequire(s, msg): encodeEnum(IVarAccess, 7, vector(encodeString(s), vnullOr(encodeString, msg)));
			case AccCtor: encodeEnum(IVarAccess, 8, vector());
		}
	}

	public static function encodeMethodKind(m:MethodKind):Value {
		return switch m {
			case MethNormal: encodeEnum(IMethodKind, 0, vector());
			case MethInline: encodeEnum(IMethodKind, 1, vector());
			case MethDynamic: encodeEnum(IMethodKind, 2, vector());
			case MethMacro: encodeEnum(IMethodKind, 3, vector());
		}
	}

	public static function encodeClassKind(k:TClassKind):Value {
		return switch k {
			case KNormal: encodeEnum(IClassKind, 0, vector());
			case KTypeParameter(ttp): encodeEnum(IClassKind, 1, vector(encodeTparams(getConstraints(ttp)))); // TTPTODO
			case KModuleFields(m): encodeEnum(IClassKind, 2, vector(encodeString(MacroApi.sTypePath(m.mPath))));
			case KExpr(e): encodeEnum(IClassKind, 3, vector(encodeExpr(e)));
			case KGeneric: encodeEnum(IClassKind, 4, vector());
			case KGenericInstance(cl, params):
				var vparams = encodeTparams(params);
				encodeEnum(IClassKind, 5, vector(encodeClref(cl), vparams));
			case KMacroType: encodeEnum(IClassKind, 6, vector());
			case KAbstractImpl(a): encodeEnum(IClassKind, 7, vector(encodeAbref(a)));
			case KGenericBuild(cfl): encodeEnum(IClassKind, 8, vector());
		}
	}

	static function encodeClassAndParams(c:TClass, pl:TParams):Value {
		var params = encodeTparams(pl);
		return encodeObj([fld("t", encodeClref(c)), fld("params", params)]);
	}

	public static function encodeTclass(c:TClass):Value {
		c.clBuild();
		var overrides = encodeArray(c.clOrderedFields.filter(cf -> hasClassFieldFlag(cf, CfOverride)).map(encodeCfref));
		var init = switch core.TOther.TClassTools.getClInit(c) {
			case null: vnull;
			case e: encodeTexpr(e);
		}
		var constructor = c.clConstructor == null ? vnull : encodeCfref(c.clConstructor);
		var statics = encodeRef(c.clOrderedStatics, l -> encodeAndMapArray(encodeCfield, l), () -> "class fields");
		var fields = encodeRef(c.clOrderedFields, l -> encodeAndMapArray(encodeCfield, l), () -> "class fields");
		var interfaces = encodeArrayV(c.clImplements.mapToVector(i -> encodeClassAndParams(i.cls, i.params)));
		var superClass = c.clSuper == null ? vnull : encodeClassAndParams(c.clSuper.cls, c.clSuper.params);
		var isAbstract = vbool(hasClassFlag(c, CAbstract));
		var isFinal = vbool(hasClassFlag(c, CFinal));
		var isInterface = vbool(hasClassFlag(c, CInterface));
		var exclude = vfun0(() -> {
			addClassFlag(c, CExcluded);
			c.clInit = null;
			vnull;
		});
		var isExtern = vbool(hasClassFlag(c, CExtern));
		var kind = encodeClassKind(c.clKind);
		return encodeMtype(TClassDecl(c), [
			fld("kind", kind),
			fld("isExtern", isExtern),
			fld("exclude", exclude),
			fld("isInterface", isInterface),
			fld("isFinal", isFinal),
			fld("isAbstract", isAbstract),
			fld("superClass", superClass),
			fld("interfaces", interfaces),
			fld("fields", fields),
			fld("statics", statics),
			fld("constructor", constructor),
			fld("init", init),
			fld("overrides", overrides)
		]);
	}

	public static function encodeTtype(t:TDef):Value {
		var type = encodeType(t.tType);
		return encodeMtype(TTypeDecl(t), [
			fld("isExtern", vbool(false)),
			fld("exclude", vfun0(() -> vnull)),
			fld("type", type),
		]);
	}

	public static function encodeTanon(a:TAnon):Value {
		var status = encodeAnonStatus(a.aStatus);
		var fields = encodePmapArray(encodeCfield, a.aFields);
		return encodeObj([fld("fields", fields), fld("status", status),]);
	}

	public static function encodeAnonStatus(s:AnonStatus):Value {
		return switch s {
			case Closed: encodeEnum(IAnonStatus, 0, vector());
			case Const: encodeEnum(IAnonStatus, 2, vector());
			case Extend(tl): encodeEnum(IAnonStatus, 3, vector(encodeRef(tl, tl -> encodeArrayV(tl.map(encodeType)), () -> "<extended types>")));
			case ClassStatics(cl): encodeEnum(IAnonStatus, 4, vector(encodeClref(cl)));
			case EnumStatics(en): encodeEnum(IAnonStatus, 5, vector(encodeEnref(en)));
			case AbstractStatics(ab): encodeEnum(IAnonStatus, 6, vector(encodeAbref(ab)));
		}
	}

	public static function encodeTparams(pl:TParams):Value return encodeArrayV(pl.map(encodeType));

	public static function encodeClref(c:TClass):Value return encodeRef(c, encodeTclass, () -> MacroApi.sTypePath(c.clPath));

	public static function encodeEnref(en:TEnum):Value return encodeRef(en, encodeTenum, () -> MacroApi.sTypePath(en.ePath));

	public static function encodeCfref(cf:TClassField):Value return encodeRef(cf, encodeCfield, () -> cf.cfName);

	public static function encodeAbref(ab:TAbstract):Value return encodeRef(ab, encodeTabstract, () -> MacroApi.sTypePath(ab.aPath));

	public static function encodeType(t:T):Value {
		function loop(t:T):{tag:Int, pl:Vector<Value>} {
			return switch t {
				case TMono(r):
					if (r.tmType == null) {
						{
							tag: 0,
							pl: vector(
								encodeRef(r, (r:TMono) -> r.tmType == null ? vnull : encodeType(r.tmType), () -> "<mono>")
							)
						};
					} else {
						loop(r.tmType);
					}
				case TEnum(e, pl):
					var params = encodeTparams(pl);
					{tag: 1, pl: vector(encodeRef(e, encodeTenum, () -> MacroApi.sTypePath(e.ePath)), params)};
				case TInst(c, pl):
					var params = encodeTparams(pl);
					{tag: 2, pl: vector(encodeClref(c), params)};
				case TType(t, pl):
					var params = encodeTparams(pl);
					{tag: 3, pl: vector(encodeRef(t, encodeTtype, () -> MacroApi.sTypePath(t.tPath)), params)};
				case TFun(sig):
					var pl = sig.args.map(a -> {
						var t = encodeType(a.type);
						var o = vbool(a.optional);
						var n = encodeString(a.name);
						encodeObj([fld("name", n), fld("opt", o), fld("t", t)]);
					});
					var ret = encodeType(sig.ret);
					{tag: 4, pl: vector(encodeArrayV(pl), ret)};
				case TAnon(a):
					{tag: 5, pl: vector(encodeRef(a, encodeTanon, () -> "<anonymous>"))};
				case TDynamic(null):
					{tag: 6, pl: vector(vnull)};
				case TDynamic(tsub):
					{tag: 6, pl: vector(encodeType(tsub))};
				case TLazy(f):
					loop(lazyType(f));
				case TAbstract(a, pl):
					var params = encodeTparams(pl);
					{tag: 8, pl: vector(encodeAbref(a), params)};
			}
		}
		var r = loop(t);
		return encodeEnum(IType, r.tag, r.pl);
	}

	public static function encodeLazyType(t:T):Value {
		var outer = t;
		function loop(t:T):Value {
			return switch t {
				case TMono(r):
					if (r.tmType != null) loop(r.tmType) else encodeType(outer);
				case TLazy(f):
					switch f.value {
						case LAvailable(t):
							encodeType(t);
						case _:
							encodeEnum(IType, 7, vector(
								encodeLazytype(f, () -> switch f.value {
									case LAvailable(t):
										encodeType(t);
									case LWait(_):
										encodeType(lazyType(f));
									case LProcessing(_):
										// our type in on the processing stack, error instead of returning most likely an unbound mono
										errorMessage("Accessing a type while it's being typed");
								})
							));
					}
				case _:
					encodeType(outer);
			}
		}
		return loop(t);
	}

	public static function decodeType(t:Value):T {
		return switch decodeEnum(t) {
			case {index: 0, args: [r]}: T.TMono(decodeRef(r));
			case {index: 1, args: [e, pl]}: T.TEnum(decodeRef(e), mapDecodedArray(pl, decodeType));
			case {index: 2, args: [c, pl]}: T.TInst(decodeRef(c), mapDecodedArray(pl, decodeType));
			case {index: 3, args: [t, pl]}: T.TType(decodeRef(t), mapDecodedArray(pl, decodeType));
			case {index: 4, args: [pl, r]}:
				var args = mapDecodedArray(pl, p -> {
					name: decodeString(field(p, "name")),
					optional: decodeBool(field(p, "opt")),
					type: decodeType(field(p, "t"))
				});
				T.TFun({args: args, ret: decodeType(r)});
			case {index: 5, args: [a]}: T.TAnon(decodeRef(a));
			case {index: 6, args: [t]}: if (isNull(t)) tDynamic else T.TDynamic(decodeType(t));
			case {index: 7, args: [f]}: T.TLazy(decodeLazytype(f));
			case {index: 8, args: [a, pl]}: T.TAbstract(decodeRef(a), mapDecodedArray(pl, decodeType));
			case _: throw InvalidExpr.raise();
		}
	}

	public static function decodeTypeDecl(t:Value):ModuleType return decodeTdecl(field(t, "__t"));

	// ---------------------------------------------------------------------- //
	// TEXPR Encoding

	public static function encodeTconst(c:TConstant):Value {
		return switch c {
			case TInt(i): encodeEnum(ITConstant, 0, vector(vint32(i)));
			case TFloat(f): encodeEnum(ITConstant, 1, vector(encodeString(f)));
			case TString(s): encodeEnum(ITConstant, 2, vector(encodeString(s)));
			case TBool(b): encodeEnum(ITConstant, 3, vector(vbool(b)));
			case TNull: encodeEnum(ITConstant, 4, vector());
			case TThis: encodeEnum(ITConstant, 5, vector());
			case TSuper: encodeEnum(ITConstant, 6, vector());
		}
	}

	public static function encodeTvar(v:TVar):Value {
		function fExtra(ve:TVarExtra):Value {
			var expr = vopt(encodeTexpr, ve.vExpr);
			var params = encodeTypeParams(ve.vParams);
			return encodeObj([fld("params", params), fld("expr", expr),]);
		}
		var unsafe = encodeUnsafe(v);
		var isStatic = vbool(hasVarFlag(v, VStatic));
		var meta = encodeMeta(v.vMeta, m -> v.vMeta = m);
		var extra = vopt(fExtra, v.vExtra);
		var capture = vbool(hasVarFlag(v, VCaptured));
		var t = encodeType(v.vType);
		var name = encodeString(v.vName);
		var id = vint(v.vId);
		return encodeObj([
			fld("id", id),
			fld("name", name),
			fld("t", t),
			fld("capture", capture),
			fld("extra", extra),
			fld("meta", meta),
			fld("isStatic", isStatic),
			fld("$", unsafe),
		]);
	}

	public static function encodeModuleType(mt:ModuleType):Value {
		return switch mt {
			case TClassDecl(c): encodeEnum(IModuleType, 0, vector(encodeClref(c)));
			case TEnumDecl(e): encodeEnum(IModuleType, 1, vector(encodeEnref(e)));
			case TTypeDecl(t): encodeEnum(IModuleType, 2, vector(encodeRef(t, encodeTtype, () -> MacroApi.sTypePath(t.tPath))));
			case TAbstractDecl(a): encodeEnum(IModuleType, 3, vector(encodeAbref(a)));
		}
	}

	public static function encodeTfunc(func:TFunc):Value {
		var expr = encodeTexpr(func.tfExpr);
		var t = encodeType(func.tfType);
		var args = encodeArrayV(func.tfArgs.map(a -> {
			var value = a.defaultValue == null ? vnull : encodeTexpr(a.defaultValue);
			var v = encodeTvar(a.variable);
			encodeObj([fld("v", v), fld("value", value)]);
		}));
		return encodeObj([fld("args", args), fld("t", t), fld("expr", expr)]);
	}

	public static function encodeFieldAccess(fa:TFieldAccess):Value {
		inline function encodeInstance(c:TClass, tl:TParams):Value {
			var params = encodeTparams(tl);
			return encodeObj([fld("c", encodeClref(c)), fld("params", params)]);
		}
		return switch fa {
			case FInstance(c, tl, cf):
				var vcf = encodeCfref(cf);
				var vtl = encodeTparams(tl);
				encodeEnum(IFieldAccess, 0, vector(encodeClref(c), vtl, vcf));
			case FStatic(c, cf):
				var vcf = encodeCfref(cf);
				encodeEnum(IFieldAccess, 1, vector(encodeClref(c), vcf));
			case FAnon(cf):
				encodeEnum(IFieldAccess, 2, vector(encodeCfref(cf)));
			case FDynamic(s):
				encodeEnum(IFieldAccess, 3, vector(encodeString(s)));
			case FClosure(co, cf):
				var vcf = encodeCfref(cf);
				encodeEnum(IFieldAccess, 4, vector(co == null ? vnull : encodeInstance(co.cls, co.params), vcf));
			case FEnum(en, ef):
				var vef = encodeEfield(ef);
				encodeEnum(IFieldAccess, 5, vector(encodeEnref(en), vef));
		}
	}

	public static function encodeTexpr(e:TExpr):Value {
		function loop(e:TExpr):Value {
			// port: the elements of each upstream list literal are evaluated right to left
			var r:{tag:Int, pl:Vector<Value>} = switch e.eexpr {
				case TConst(c):
					{tag: 0, pl: vector(encodeTconst(c))};
				case TLocal(v):
					{tag: 1, pl: vector(encodeTvar(v))};
				case TArray(e1, e2):
					var v2 = loop(e2);
					{tag: 2, pl: vector(loop(e1), v2)};
				case TBinop(op, e1, e2):
					var v2 = loop(e2);
					var v1 = loop(e1);
					{tag: 3, pl: vector(encodeBinop(op), v1, v2)};
				case TField(e1, fa):
					var vfa = encodeFieldAccess(fa);
					{tag: 4, pl: vector(loop(e1), vfa)};
				case TTypeExpr(mt):
					{tag: 5, pl: vector(encodeModuleType(mt))};
				case TParenthesis(e1):
					{tag: 6, pl: vector(loop(e1))};
				case TObjectDecl(fl):
					{
						tag: 7,
						pl: vector(
							encodeArrayV(fl.map(f -> {
								var expr = loop(f.expr);
								encodeObj([fld("name", encodeString(f.key.name)), fld("expr", expr),]);
							}))
						)
					};
				case TArrayDecl(el):
					{tag: 8, pl: vector(encodeTexprList(el))};
				case TCall(e1, el):
					var vel = encodeTexprList(el);
					{tag: 9, pl: vector(loop(e1), vel)};
				case TNew(c, pl, el):
					var vel = encodeTexprList(el);
					var vpl = encodeTparams(pl);
					{tag: 10, pl: vector(encodeClref(c), vpl, vel)};
				case TUnop(op, flag, e1):
					var v1 = loop(e1);
					{tag: 11, pl: vector(encodeUnop(op), vbool(flag.match(Postfix)), v1)};
				case TFunction(func):
					{tag: 12, pl: vector(encodeTfunc(func))};
				case TVar(v, eo):
					var veo = vopt(encodeTexpr, eo);
					{tag: 13, pl: vector(encodeTvar(v), veo)};
				case TBlock(el):
					{tag: 14, pl: vector(encodeTexprList(el))};
				case TIf(eif, ethen, eelse):
					var velse = vopt(encodeTexpr, eelse);
					var vthen = loop(ethen);
					{tag: 16, pl: vector(loop(eif), vthen, velse)};
				case TWhile(econd, e1, flag):
					var vflag = vbool(flag.match(NormalWhile));
					var v1 = loop(e1);
					{tag: 17, pl: vector(loop(econd), v1, vflag)};
				case TSwitch(sw):
					var switchSubject = if (sw.switchExhaustive) {
						var meta:MetadataEntry = {meta: core.MetaList.StrictMeta.Exhaustive, exprs: vector(), pos: Globals.nullPos};
						new TExpr(TMeta(meta, sw.switchSubject), sw.switchSubject.etype, sw.switchSubject.epos);
					} else {
						sw.switchSubject;
					}
					var vdefault = vopt(encodeTexpr, sw.switchDefault);
					var vcases = encodeArrayV(sw.switchCases.map(c -> {
						var expr = loop(c.caseExpr);
						encodeObj([fld("values", encodeTexprList(c.casePatterns)), fld("expr", expr)]);
					}));
					{tag: 18, pl: vector(loop(switchSubject), vcases, vdefault)};
				case TTry(e1, catches):
					var vcatches = encodeArrayV(catches.map(c -> {
						var expr = loop(c.expr);
						encodeObj([fld("v", encodeTvar(c.variable)), fld("expr", expr)]);
					}));
					{tag: 19, pl: vector(loop(e1), vcatches)};
				case TReturn(e1):
					{tag: 20, pl: vector(vopt(encodeTexpr, e1))};
				case TBreak:
					{tag: 21, pl: vector()};
				case TContinue:
					{tag: 22, pl: vector()};
				case TThrow(e1):
					{tag: 23, pl: vector(loop(e1))};
				case TCast(e1, mt):
					var vmt = mt == null ? vnull : encodeModuleType(mt);
					{tag: 24, pl: vector(loop(e1), vmt)};
				case TMeta(m, e1):
					var v1 = loop(e1);
					{tag: 25, pl: vector(encodeMetaEntry(m), v1)};
				case TEnumParameter(e1, ef, i):
					var vef = encodeEfield(ef);
					{tag: 26, pl: vector(loop(e1), vef, vint(i))};
				case TEnumIndex(e1):
					{tag: 27, pl: vector(loop(e1))};
				case TIdent(s):
					{tag: 28, pl: vector(encodeString(s))};
			}
			var t = encodeType(e.etype);
			var expr = encodeEnum(ITypedExpr, r.tag, r.pl);
			return encodeObj([fld("pos", encodePos(e.epos)), fld("expr", expr), fld("t", t)]);
		}
		return loop(e);
	}

	public static function encodeTexprList(el:Vector<TExpr>):Value return encodeArrayV(el.map(encodeTexpr));

	// ---------------------------------------------------------------------- //
	// TEXPR Decoding

	public static function decodeTconst(c:Value):TConstant {
		return switch decodeEnum(c) {
			case {index: 0, args: [s]}: TInt(decodeI32(s));
			case {index: 1, args: [s]}: TFloat(decodeString(s));
			case {index: 2, args: [s]}: TString(decodeString(s));
			case {index: 3, args: [s]}: TBool(decodeBool(s));
			case {index: 4, args: []}: TNull;
			case {index: 5, args: []}: TThis;
			case {index: 6, args: []}: TSuper;
			case _: throw InvalidExpr.raise();
		}
	}

	public static function decodeTvar(v:Value):TVar return (decodeUnsafe(field(v, "$")) : TVar);

	public static function decodeVarAccess(v:Value):VarAccess {
		return switch decodeEnum(v) {
			case {index: 0, args: []}: AccNormal;
			case {index: 1, args: []}: AccNo;
			case {index: 2, args: []}: AccNever;
			case {index: 4, args: []}: AccCall;
			case {index: 5, args: []}: AccPrivateCall;
			case {index: 6, args: []}: AccInline;
			case {index: 7, args: [s1, s2]}: AccRequire(decodeString(s1), opt(decodeString, s2));
			case {index: 8, args: []}: AccCtor;
			case _: throw InvalidExpr.raise();
		}
	}

	public static function decodeMethodKind(v:Value):MethodKind {
		return switch decodeEnum(v) {
			case {index: 0, args: []}: MethNormal;
			case {index: 1, args: []}: MethInline;
			case {index: 2, args: []}: MethDynamic;
			case {index: 3, args: []}: MethMacro;
			case _: throw InvalidExpr.raise();
		}
	}

	public static function decodeFieldKind(v:Value):FieldKind {
		return switch decodeEnum(v) {
			case {index: 0, args: [vr, vw]}: FieldKind.Var({vRead: decodeVarAccess(vr), vWrite: decodeVarAccess(vw)});
			case {index: 1, args: [m]}: FieldKind.Method(decodeMethodKind(m));
			case _: throw InvalidExpr.raise();
		}
	}

	public static function decodeEfield(v:Value):TEnumField {
		function getEnum(t:T):TEnum {
			return switch follow(t) {
				case TEnum(enm, _): enm;
				case TFun(sig): getEnum(sig.ret);
				case _: throw NotFound.raise();
			}
		}
		var name = decodeString(field(v, "name"));
		try {
			var enm = getEnum(decodeType(field(v, "type")));
			return PMap.find(name, enm.eConstrs);
		} catch (_:NotFound) {
			throw InvalidExpr.raise();
		}
	}

	public static function decodeFieldAccess(v:Value):TFieldAccess {
		return switch decodeEnum(v) {
			case {index: 0, args: [c, tl, cf]}:
				var c:TClass = decodeRef(c);
				FInstance(c, mapDecodedArray(tl, decodeType), decodeRef(cf));
			case {index: 1, args: [c, cf]}: FStatic(decodeRef(c), decodeRef(cf));
			case {index: 2, args: [cf]}: FAnon(decodeRef(cf));
			case {index: 3, args: [s]}: FDynamic(decodeString(s));
			case {index: 4, args: [co, cf]}:
				var co = if (isNull(co)) null else {
					cls: (decodeRef(field(co, "c")) : TClass),
					params: mapDecodedArray(field(co, "params"), decodeType)
				};
				FClosure(co, decodeRef(cf));
			case {index: 5, args: [e, ef]}: FEnum(decodeRef(e), decodeEfield(ef));
			case _: throw InvalidExpr.raise();
		}
	}

	public static function decodeModuleType(v:Value):ModuleType {
		return switch decodeEnum(v) {
			case {index: 0, args: [c]}: TClassDecl(decodeRef(c));
			case {index: 1, args: [en]}: TEnumDecl(decodeRef(en));
			case {index: 2, args: [t]}: TTypeDecl(decodeRef(t));
			case {index: 3, args: [a]}: TAbstractDecl(decodeRef(a));
			case _: throw InvalidExpr.raise();
		}
	}

	public static function decodeTfunc(v:Value):TFunc {
		var tfArgs = mapDecodedArray(field(v, "args"), v -> {variable: decodeTvar(field(v, "v")), defaultValue: opt(decodeTexpr, field(v, "value"))});
		var tfType = decodeType(field(v, "t"));
		var tfExpr = decodeTexpr(field(v, "expr"));
		return {
			tfArgs: tfArgs,
			tfType: tfType,
			tfExpr: tfExpr
		};
	}

	public static function decodeTexpr(v:Value):TExpr {
		// port: upstream has `try loop v with Stack_overflow -> raise Invalid_expr`
		return decodeTexprLoop(v);
	}

	static function decodeTexprLoop(v:Value):TExpr {
		var p = decodePos(field(v, "pos"));
		return mk(decodeTexprDef(field(v, "expr"), p), decodeType(field(v, "t")), p);
	}

	static function decodeTexprDef(e:Value, p:Pos):TExprDef {
		var loop = decodeTexprLoop;
		return switch decodeEnum(e) {
			case {index: 0, args: [c]}: TConst(decodeTconst(c));
			case {index: 1, args: [v]}: TLocal(decodeTvar(v));
			case {index: 2, args: [v1, v2]}: TArray(loop(v1), loop(v2));
			case {index: 3, args: [op, v1, v2]}: TBinop(decodeOp(op), loop(v1), loop(v2));
			case {index: 4, args: [v1, fa]}: TField(loop(v1), decodeFieldAccess(fa));
			case {index: 5, args: [mt]}: TTypeExpr(decodeModuleType(mt));
			case {index: 6, args: [v1]}: TParenthesis(loop(v1));
			case {index: 7, args: [v]}: TObjectDecl(mapDecodedArray(v, v -> {
					key: {
						name: decodeString(field(v, "name")),
						pos: p,
						quote: NoQuotes
					},
					expr: loop(field(v, "expr"))
				}));
			case {index: 8, args: [vl]}: TArrayDecl(mapDecodedArray(vl, loop));
			case {index: 9, args: [v1, vl]}: TCall(loop(v1), mapDecodedArray(vl, loop));
			case {index: 10, args: [c, tl, vl]}: TNew(decodeRef(c), mapDecodedArray(tl, decodeType), mapDecodedArray(vl, loop));
			case {index: 11, args: [op, pf, v1]}: TUnop(decodeUnop(op), if (decodeBool(pf)) Postfix else Prefix, loop(v1));
			case {index: 12, args: [f]}: TFunction(decodeTfunc(f));
			case {index: 13, args: [v, eo]}: TExprDef.TVar(decodeTvar(v), opt(loop, eo));
			case {index: 14, args: [vl]}: TBlock(mapDecodedArray(vl, loop));
			// 15 was TFor
			case {index: 16, args: [vif, vthen, velse]}: TIf(loop(vif), loop(vthen), opt(loop, velse));
			case {index: 17, args: [vcond, v1, b]}: TWhile(loop(vcond), loop(v1), if (decodeBool(b)) NormalWhile else DoWhile);
			case {index: 18, args: [v1, cl, vdef]}:
				inline function isExhaustive(e1:TExpr, def:Null<TExpr>):Bool {
					function loop(e1:TExpr):Bool {
						return switch e1.eexpr {
							case TMeta(m, _) if (Meta.metaEq(core.MetaList.StrictMeta.Exhaustive, m.meta)): true;
							case TMeta(_, e1) | TParenthesis(e1): loop(e1);
							case _: false;
						}
					}
					return def != null || loop(e1);
				}
				var subject = loop(v1);
				var cases = mapDecodedArray(cl, v -> ({
					casePatterns: mapDecodedArray(field(v, "values"), loop),
					caseExpr: loop(field(v, "expr"))
				} : TSwitchCase));
				var def = opt(loop, vdef);
				var sw = core.Texpr.mkSwitch(subject, cases, def, isExhaustive(subject, def));
				TExprDef.TSwitch(sw);
			case {index: 19, args: [v1, cl]}: TTry(loop(v1),
					mapDecodedArray(cl, v -> {variable: decodeTvar(field(v, "v")), expr: loop(field(v, "expr"))}));
			case {index: 20, args: [vo]}: TReturn(opt(loop, vo));
			case {index: 21, args: []}: TBreak;
			case {index: 22, args: []}: TContinue;
			case {index: 23, args: [v1]}: TThrow(loop(v1));
			case {index: 24, args: [v1, mto]}: TCast(loop(v1), opt(decodeModuleType, mto));
			case {index: 25, args: [m, v1]}: TMeta(decodeMetaEntry(m), loop(v1));
			case {index: 26, args: [v1, ef, i]}: TEnumParameter(loop(v1), decodeEfield(ef), decodeInt(i));
			case {index: 27, args: [v1]}: TEnumIndex(loop(v1));
			case {index: 28, args: [v1]}: TIdent(decodeString(v1));
			case {index: i, args: el}:
				Sys.print(i + " " + el.length + "\n");
				throw InvalidExpr.raise();
		}
	}

	// ---------------------------------------------------------------------- //
	// TYPE DEFINITION

	public static function decodeTypeDef(v:Value):DecodedTypeDef {
		var pack = decodeArray(field(v, "pack")).map(decodeString);
		var name = decodePlacedName(field(v, "name_pos"), field(v, "name"));
		var meta = decodeMetaContent(field(v, "meta"));
		var pos = decodePos(field(v, "pos"));
		var isExtern = decodeOptBool(field(v, "isExtern"));
		var fields = mapDecodedArray(field(v, "fields"), decodeField);
		var doc = decodeDoc(field(v, "doc"));
		// port: `mk fl dl`: d_params is decoded when the definition is built
		function params():Vector<TypeParam> return decodeTparams(field(v, "params"));
		var tdef:TypeDef = switch decodeEnum(field(v, "kind")) {
			case {index: 0, args: []}:
				function conv(f:ClassField):EnumConstructor {
					function loop(a:FuncArg):EnumConstructorArg {
						return switch a.type {
							case null: throw InvalidExpr.raise();
							case t: {name: a.name.name, optional: a.optional, type: t};
						}
					}
					var r:{args:Vector<EnumConstructorArg>, params:Vector<TypeParam>, t:Null<TypeHint>} = switch f.cffKind {
						case FVar(t, null): {args: vector(), params: vector(), t: t};
						case FFun(f): {args: f.fArgs.map(loop), params: f.fParams, t: f.fType};
						case _: throw InvalidExpr.raise();
					}
					return {
						ecName: f.cffName,
						ecDoc: f.cffDoc,
						ecMeta: f.cffMeta,
						ecPos: f.cffPos,
						ecArgs: r.args,
						ecParams: r.params,
						ecType: r.t,
					};
				}
				var data = fields.map(conv);
				var flags:Array<EnumFlag> = if (isExtern) [EExtern] else [];
				EEnum({
					name: name,
					doc: doc,
					params: params(),
					meta: meta,
					flags: Vector.fromArrayCopy(flags),
					data: data
				});
			case {index: 1, args: []}:
				var data:TypeHint = {type: CTAnonymous(fields), pos: pos};
				var flags:Array<TypedefFlag> = if (isExtern) [TDExtern] else [];
				ETypedef({
					name: name,
					doc: doc,
					params: params(),
					meta: meta,
					flags: Vector.fromArrayCopy(flags),
					data: data
				});
			case {index: 2, args: [ext, impl, interf, isFinal, isAbstract]}:
				var flags:Array<ClassFlag> = if (isExtern) [HExtern] else [];
				var isInterface = decodeOptBool(interf);
				var isFinal = decodeOptBool(isFinal);
				var isAbstract = decodeOptBool(isAbstract);
				var interfaces = switch opt(v -> decodeArray(v).map(decodeAstPath), impl) {
					case null: [];
					case l: l;
				}
				var flags = switch opt(decodeAstPath, ext) {
					case null: flags;
					case t: [HExtends(t)].concat(flags);
				}
				var flags = if (isInterface) {
					var flags = [HInterface].concat(flags);
					interfaces.map(t -> HExtends(t)).concat(flags);
				} else {
					interfaces.map(t -> HImplements(t)).concat(flags);
				}
				var flags = if (isFinal) [HFinal].concat(flags) else flags;
				var flags = if (isAbstract) [HAbstract].concat(flags) else flags;
				EClass({
					name: name,
					doc: doc,
					params: params(),
					meta: meta,
					flags: Vector.fromArrayCopy(flags),
					data: fields
				});
			case {index: 3, args: [t]}:
				var data = decodeCtype(t);
				var flags:Array<TypedefFlag> = if (isExtern) [TDExtern] else [];
				ETypedef({
					name: name,
					doc: doc,
					params: params(),
					meta: meta,
					flags: Vector.fromArrayCopy(flags),
					data: data
				});
			case {index: 4, args: [tthis, tflags, tfrom, tto]}:
				var flags:Array<AbstractFlag> = switch opt(decodeArray, tflags) {
					case null: [];
					case ta: ta.map(f -> switch decodeEnum(f) {
							case {index: 0, args: []}: AbEnum;
							case {index: 1, args: [ct]}: AbFrom(decodeCtype(ct));
							case {index: 2, args: [ct]}: AbTo(decodeCtype(ct));
							case _: throw InvalidExpr.raise();
						});
				}
				var flags = switch opt(decodeArray, tfrom) {
					case null: flags;
					case ta: ta.map(t -> AbFrom(decodeCtype(t))).concat(flags);
				}
				var flags = switch opt(decodeArray, tto) {
					case null: flags;
					case ta: ta.map(t -> AbTo(decodeCtype(t))).concat(flags);
				}
				var flags = switch opt(decodeCtype, tthis) {
					case null: flags;
					case t: [AbOver(t)].concat(flags);
				}
				var flags = if (isExtern) [AbExtern].concat(flags) else flags;
				EAbstract({
					name: name,
					doc: doc,
					params: params(),
					meta: meta,
					flags: Vector.fromArrayCopy(flags),
					data: fields
				});
			case {index: 5, args: [fk, al]}:
				var fk = decodeClassFieldKind(fk);
				var al = optList(decodeArray, al).map(decodeAccess);
				// let al = if isExtern then (AExtern,pos) :: al else al in
				EStatic({
					name: name,
					doc: doc,
					params: params(),
					meta: meta,
					flags: Vector.fromArrayCopy(al),
					data: fk
				});
			case _:
				throw InvalidExpr.raise();
		}
		// if our package ends with an uppercase letter, then it's the module name
		var path:GlobalTypePath = if (pack.length > 0
			&& pack[pack.length - 1].length > 0
			&& core.StringHelper.startsUppercaseIdentifier(pack[pack.length - 1])) {
			{pack: pack.slice(0, pack.length - 1), name: pack[pack.length - 1]};
		} else {
			{pack: pack, name: name.name};
		}
		return {path: path, def: tdef, pos: pos};
	}

	public static function decodePath(v:Value):GlobalTypePath {
		var pack = decodeArray(field(v, "pack")).map(decodeString);
		var name = decodeString(field(v, "name"));
		return {pack: pack, name: name};
	}

	public static function decodePlatform(v:Value):Platform {
		return switch decodeEnum(v) {
			case {index: 0, args: []}: Platform.Cross;
			case {index: 1, args: []}: Platform.Js;
			case {index: 2, args: []}: Platform.Lua;
			case {index: 3, args: []}: Platform.Neko;
			case {index: 4, args: []}: Platform.Flash;
			case {index: 5, args: []}: Platform.Php;
			case {index: 6, args: []}: Platform.Cpp;
			case {index: 7, args: []}: Platform.Jvm;
			case {index: 8, args: []}: Platform.Python;
			case {index: 9, args: []}: Platform.Hl;
			case {index: 10, args: []}: Platform.Eval;
			case {index: 11, args: [s]}: Platform.CustomTarget(decodeString(s));
			case _: throw InvalidExpr.raise();
		}
	}

	public static function decodePlatformConfig(v:Value):PlatformConfig {
		var capturePolicy = switch decodeEnum(field(v, "capturePolicy")) {
			case {index: 0, args: []}: CPNone;
			case {index: 1, args: []}: CPWrapRef;
			case {index: 2, args: []}: CPLoopVars;
			case _: throw InvalidExpr.raise();
		}
		var vExc = field(v, "exceptions");
		var exceptionConfig:ExceptionsConfig = {
			ecNativeThrows: decodeArray(field(vExc, "nativeThrows")).map(decodePath),
			ecNativeCatches: decodeArray(field(vExc, "nativeCatches")).map(decodePath),
			ecAvoidWrapping: decodeBool(field(vExc, "avoidWrapping")),
			ecWildcardCatch: decodePath(field(vExc, "wildcardCatch")),
			ecBaseThrow: decodePath(field(vExc, "baseThrow")),
			ecSpecialThrow: (_) -> false, // wtf is this?
		};
		var vScoping = field(v, "scoping");
		function decodeScopeFlag(v:Value):VarScopingFlags {
			return switch decodeEnum(v) {
				case {index: 0, args: []}: VarHoisting;
				case {index: 1, args: []}: NoShadowing;
				case {index: 2, args: []}: NoCatchVarShadowing;
				case {index: 3, args: []}: ReserveCurrentTopLevelSymbol;
				case {index: 4, args: []}: ReserveAllTopLevelSymbols;
				case {index: 5, args: []}: ReserveAllTypesFlat;
				case {index: 6, args: [sl]}: ReserveNames(decodeArray(sl).map(decodeString));
				case {index: 7, args: []}: SwitchCasesNoBlocks;
				case _: throw InvalidExpr.raise();
			}
		}
		var varScopingConfig:VarScopingConfig = {
			vsScope: switch decodeEnum(field(vScoping, "scope")) {
				case {index: 0, args: []}: FunctionScope;
				case {index: 1, args: []}: BlockScope;
				case _: throw InvalidExpr.raise();
			},
			vsFlags: decodeArray(field(vScoping, "flags")).map(decodeScopeFlag),
		};
		return {
			pfStatic: decodeBool(field(v, "staticTypeSystem")),
			pfSys: decodeBool(field(v, "sys")),
			pfCapturePolicy: capturePolicy,
			pfPadNulls: decodeBool(field(v, "padNulls")),
			pfAddFinalReturn: decodeBool(field(v, "addFinalReturn")),
			pfOverload: decodeBool(field(v, "overloadFunctions")),
			pfCanSkipNonNullableArgument: false,
			pfReservedTypePaths: decodeArray(field(v, "reservedTypePaths")).map(decodePath),
			pfSupportsFunctionEquality: decodeBool(field(v, "supportsFunctionEquality")),
			pfUsesUtf16: decodeBool(field(v, "usesUtf16")),
			pfThisBeforeSuper: decodeBool(field(v, "thisBeforeSuper")),
			pfSupportsThreads: decodeBool(field(v, "supportsThreads")),
			pfSupportsUnicode: decodeBool(field(v, "supportsUnicode")),
			pfSupportsRestArgs: decodeBool(field(v, "supportsRestArgs")),
			pfExceptions: exceptionConfig,
			pfScoping: varScopingConfig,
			pfSupportsAtomics: decodeBool(field(v, "supportsAtomics")),
		};
	}

	// ---------------------------------------------------------------------- //
	// VALUE-TO-CONSTANT

	public static function makeConst(e:TExpr):Value {
		return switch e.eexpr {
			case TConst(c):
				switch c {
					case TInt(i): vint32(i);
					case TFloat(s): vfloat(core.ds.OcamlFloat.ofString(s));
					case TString(s): encodeString(s);
					case TBool(b): vbool(b);
					case TNull: vnull;
					case TThis | TSuper: throw core.ds.Exit.raise();
				}
			case TParenthesis(e) | TMeta(_, e) | TCast(e, null):
				makeConst(e);
			case TObjectDecl(el):
				encodeObj(el.mapToArray(f -> fld(f.key.name, makeConst(f.expr))));
			case TArrayDecl(al):
				encodeArrayV(al.map(makeConst));
			case _:
				throw core.ds.Exit.raise();
		}
	}

	// ---------------------------------------------------------------------- //
	// MACRO API

	/**
		Our macro API implementation. It gets called by the interpreter and
		accesses the compiler with the compiler_api
	**/
	public static function macroApi(ccom:Void->CommonContext, getApi:Void->CompilerApi):Array<{name:String, value:Value}> {
		var decodeType = function(v:Value):T {
			return try MacroApiImpl.decodeType(v) catch (_:InvalidExpr) getApi().excString("Invalid expression");
		}
		var decodeExpr = function(v:Value):Expr {
			return try MacroApiImpl.decodeExpr(v) catch (_:InvalidExpr) getApi().excString("Invalid expression");
		}
		var decodeTexpr = function(v:Value):TExpr {
			return try MacroApiImpl.decodeTexpr(v) catch (_:InvalidExpr) getApi().excString("Invalid expression");
		}
		var failwith = function(s:String):Dynamic return getApi().excString(s);
		return [
			{
				name: "contains_display_position",
				value: vfun1(vp -> {
					var p = decodePos(vp);
					var displayPos = core.display.DisplayPosition.displayPosition;
					inline function sameFile():Bool {
						var dfile = displayPos.get().pfile;
						return dfile == p.pfile || {
							var com = ccom();
							(core.OcamlFilename.isRelative(p.pfile) || core.OcamlFilename.isRelative(dfile)) && (com.partScope.fileKeys.get(dfile) == com.partScope.fileKeys.get(p.pfile));
						};
					}
					vbool(displayPos.enclosedIn(p) && sameFile());
				})
			},
			{
				name: "current_pos",
				value: vfun0(() -> {
					encodePos(getApi().pos);
				})
			},
			{
				name: "get_macro_stack",
				value: vfun0(() -> {
					var stack = getApi().getMacroStack();
					encodeArrayV(stack.mapToVector(encodePos));
				})
			},
			{
				name: "init_macros_done",
				value: vfun0(() -> {
					vbool(getApi().initMacrosDone());
				})
			},
			{
				name: "error",
				value: vfun3((msg, p, sub) -> {
					var msg = decodeString(msg);
					var p = decodePos(p);
					var sub = decodeSubErrors(sub);
					getApi().displayError(msg, p, sub);
					throw new Abort();
				})
			},
			{
				name: "fatal_error",
				value: vfun3((msg, p, sub) -> {
					var msg = decodeString(msg);
					var pos = decodePos(p);
					var sub = decodeSubErrors(sub);
					throw new core.Error.FatalError(core.Error.convertError({msg: msg, pos: pos, sub: sub}));
				})
			},
			{
				name: "report_error",
				value: vfun3((msg, p, sub) -> {
					var msg = decodeString(msg);
					var p = decodePos(p);
					var sub = decodeSubErrors(sub);
					getApi().displayError(msg, p, sub);
					vnull;
				})
			},
			{
				name: "warning",
				value: vfun3((msg, p, depth) -> {
					var msg = decodeString(msg);
					var p = decodePos(p);
					var depth = decodeInt(depth);
					getApi().warning(WUser, msg, p, depth);
					vnull;
				})
			},
			{
				name: "info",
				value: vfun3((msg, p, depth) -> {
					var msg = decodeString(msg);
					var p = decodePos(p);
					var depth = decodeInt(depth);
					getApi().info(msg, p, depth);
					vnull;
				})
			},
			{
				name: "get_messages",
				value: vfun0(() -> {
					encodeArray(ccom().getMessages().map(msg -> encodeMessage(msg)));
				})
			},
			{
				name: "filter_messages",
				value: vfun1(predicate -> {
					var predicate = prepareCallback(predicate, 2);
					ccom().filterMessages(msg -> decodeBool(predicate([encodeMessage(msg)])));
					vnull;
				})
			},
			{
				name: "class_path",
				value: vfun0(() -> {
					encodeArray((ccom().classPaths.asStringList() : Array<String>).map(encodeString));
				})
			},
			{
				name: "resolve_path",
				value: vfun1(file -> {
					var file = decodeString(file);
					encodeString(try Common.findFile(ccom(),
						file) catch (e:Dynamic) if (isNotFound(e)) failwith("File not found '" + file + "'")
					else throw e);
				})
			},
			{
				name: "define",
				value: vfun2((s, v) -> {
					var s = decodeString(s);
					var com = ccom();
					if (isNull(v))
						Common.externalDefine(com, s)
					else
						Common.externalDefineValue(com, s, decodeString(v));
					vnull;
				})
			},
			{
				name: "defined",
				value: vfun1(s -> {
					vbool(Common.externalDefined(ccom(), decodeString(s)));
				})
			},
			{
				name: "defined_value",
				value: vfun1(s -> {
					try encodeString(Common.externalDefinedValue(ccom(), decodeString(s)))
					catch (e:Dynamic) if (isNotFound(e)) vnull
					else throw e;
				})
			},
			{
				name: "get_defines",
				value: vfun0(() -> {
					encodeStringMap(encodeString, Common.definesForExternal(ccom()));
				})
			},
			{
				name: "get_type",
				value: vfun1(s -> {
					var tname = decodeString(s);
					switch getApi().getType(tname) {
						case null: failwith("Type not found '" + tname + "'");
						case t: encodeType(t);
					}
				})
			},
			{
				name: "get_module",
				value: vfun1(s -> {
					encodeArray(getApi().getModule(decodeString(s)).map(encodeType));
				})
			},
			{
				name: "include_module",
				value: vfun1(s -> {
					getApi().includeModule(decodeString(s));
					vnull;
				})
			},
			{
				name: "on_after_init_macros",
				value: vfun1(f -> {
					var f = prepareCallback(f, 1);
					getApi().afterInitMacros(() -> {
						f([]);
					});
					vnull;
				})
			},
			{
				name: "on_after_typing",
				value: vfun1(f -> {
					var f = prepareCallback(f, 1);
					getApi().afterTyping(tl -> {
						f([encodeArrayV(tl.mapToVector(encodeModuleType))]);
					});
					vnull;
				})
			},
			{
				name: "on_generate",
				value: vfun2((f, b) -> {
					var f = prepareCallback(f, 1);
					getApi().onGenerate(tl -> {
						f([encodeArrayV(tl.mapToVector(encodeType))]);
					}, decodeBool(b));
					vnull;
				})
			},
			{
				name: "on_after_generate",
				value: vfun1(f -> {
					var f = prepareCallback(f, 0);
					getApi().afterGenerate(() -> {
						f([]);
					});
					vnull;
				})
			},
			{
				name: "on_type_not_found",
				value: vfun1(f -> {
					var f = prepareCallback(f, 1);
					getApi().onTypeNotFound(path -> f([encodeString(path)]));
					vnull;
				})
			},
			{
				name: "do_parse",
				value: vfun3((s, p, b) -> {
					var s = decodeString(s);
					if (s == "")
						getApi().excString("Invalid expression");
					encodeExpr(getApi().parseString(s, decodePos(p), decodeBool(b)));
				})
			},
			{
				name: "register_file_contents",
				value: vfun2((f, c) -> {
					var f = decodeString(f);
					var content = decodeString(c);
					getApi().registerFileContents(f, content);
					vnull;
				})
			},
			{
				name: "make_expr",
				value: vfun2((v, p) -> {
					encodeExpr(valueToExpr(v, decodePos(p)));
				})
			},
			{
				name: "signature",
				value: vfun1(v -> {
					try {
						encodeString(valueSignature(v));
					} catch (e:core.ds.InvalidArgument) {
						getApi().excString(e.message);
					}
				})
			},
			{
				name: "to_complex_type",
				value: vfun1(v -> {
					try {
						encodeCtype(core.TOther.TExprToExpr.convertTypeHint(decodeType(v)));
					} catch (_:core.ds.Exit) {
						vnull;
					} catch (_:TypeExit) {
						// port: TExprToExpr raises TypeExit where upstream raises Exit
						vnull;
					}
				})
			},
			{
				name: "unify",
				value: vfun2((t1, t2) -> {
					var e1 = mk(TObjectDecl(vector()), decodeType(t1), Globals.nullPos);
					vbool(getApi().castOrUnify(decodeType(t2), e1, Globals.nullPos));
				})
			},
			{
				name: "typeof",
				value: vfun1(v -> {
					encodeType(getApi().typeExpr(decodeExpr(v)).etype);
				})
			},
			{
				name: "type_expr",
				value: vfun1(v -> {
					encodeTexpr(getApi().typeExpr(decodeExpr(v)));
				})
			},
			{
				name: "resolve_type",
				value: vfun2((t, p) -> {
					encodeType(getApi().resolveType(decodeCtype(t).type, decodePos(p)));
				})
			},
			{
				name: "resolve_complex_type",
				value: vfun2((ct, p) -> {
					encodeCtype(getApi().resolveComplexType({type: decodeCtype(ct).type, pos: decodePos(p)}));
				})
			},
			{
				name: "s_type",
				value: vfun1(v -> {
					encodeString(core.TPrinting.sType(core.TPrinting.printContext(), decodeType(v)));
				})
			},
			{
				name: "s_expr",
				value: vfun2((v, b) -> {
					var f:(T->String) -> TExpr -> String = if (decodeOptBool(b)) core.TPrinting.sExprPretty.bind(false, "",
						false) else core.TPrinting.sExprAst.bind(true, "");
					encodeString(f(core.TPrinting.sType.bind(core.TPrinting.printContext()), decodeTexpr(v)));
				})
			},
			{
				name: "format_string",
				value: vfun2((s, p) -> {
					encodeExpr(getApi().formatString(decodeString(s), decodePos(p)));
				})
			},
			{
				name: "allow_package",
				value: vfun1(s -> {
					getApi().allowPackage(decodeString(s));
					vnull;
				})
			},
			{
				name: "add_global_metadata_impl",
				value: vfun5((s1, s2, b1, b2, b3) -> {
					getApi().addGlobalMetadata(decodeString(s1), decodeString(s2),
						{a: decodeBool(b1), b: decodeBool(b2), c: decodeBool(b3)}, getApiCallPos());
					vnull;
				})
			},
			{
				name: "register_define_impl",
				value: vfun2((d, src) -> {
					var flags:Array<DefineParameter> = [];

					var platforms = decodeOptArray(decodePlatform, field(d, "platforms"));
					var flags = switch platforms {
						case []: flags;
						case _: [DefineParameter.Platforms(platforms)].concat(flags);
					}

					var params = decodeOptArray(decodeString, field(d, "params"));
					var flags = flags.concat(params.map(p -> DefineParameter.HasParam(p)));

					var links = decodeOptArray(decodeString, field(d, "links"));
					var flags = flags.concat(links.map(l -> DefineParameter.Link(l)));

					getApi().registerDefine(decodeString(field(d, "define")), {
						doc: decodeString(field(d, "doc")),
						flags: flags,
						source: opt(decodeString, src),
					});
					vnull;
				})
			},
			{
				name: "register_metadata_impl",
				value: vfun2((m, src) -> {
					var flags:Array<MetaParameter> = [];

					var platforms = decodeOptArray(decodePlatform, field(m, "platforms"));
					var flags = if (platforms.length == 0) flags else [MetaParameter.Platforms(platforms)].concat(flags);

					var targets = decodeOptArray(decodeString, field(m, "targets"));
					var flags = if (targets.length == 0) flags else
						[MetaParameter.UsedOn(targets.map(core.MetaList.MetaList.parseMetaUsage))].concat(flags);

					var params = decodeOptArray(decodeString, field(m, "params"));
					var flags = flags.concat(params.map(p -> MetaParameter.HasParam(p)));

					var links = decodeOptArray(decodeString, field(m, "links"));
					var flags = flags.concat(links.map(l -> MetaParameter.Link(l)));

					getApi().registerMetadata(decodeString(field(m, "metadata")), {
						doc: decodeString(field(m, "doc")),
						flags: flags,
						source: opt(decodeString, src),
					});
					vnull;
				})
			},
			{
				name: "set_custom_js_generator",
				// port: without the target generators (-D hih_no_generators, the playground's build), no JS generator to drive
				#if hih_no_generators
				value: vfun1(f -> notSupported("set_custom_js_generator without the target generators"))
				#else
				value: vfun1(f -> {
					var f = prepareCallback(f, 1);
					function gen(com:generators.Gctx, jsCtx:generators.Genjs.JsCtx):Void {
						generators.Genjs.setupKwds(com);
						var api = encodeObj([
							fld("outputFile", encodeString(com.file)),
							fld("types", encodeArrayV(com.types.mapToVector(t -> encodeType(typeOfModuleType(t))))),
							fld("main", (switch com.main.mainExpr {
								case null: vnull;
								case e: encodeTexpr(e);
							})),
							fld("generateValue", vfun1(v -> {
								var e = decodeTexpr(v);
								var str = generators.Genjs.genSingleExpr(jsCtx, e, false);
								encodeString(str);
							})),
							fld("isKeyword", vfun1(v -> vbool(generators.Genjs.isKeyword(decodeString(v))))),
							fld("hasFeature", vfun1(v -> vbool(generators.Gctx.hasFeature(com, decodeString(v))))),
							fld("addFeature", vfun1(v -> {
								generators.Gctx.addFeature(com, decodeString(v));
								vnull;
							})),
							fld("quoteString", vfun1(v -> encodeString("\"" + core.StringHelper.sEscape(decodeString(v)) + "\""))),
							fld("buildMetaData", vfun1(t -> switch core.Texpr.buildMetadata(com.basic, decodeTypeDecl(t)) {
								case null: vnull;
								case e: encodeTexpr(e);
							})),
							fld("generateStatement", vfun1(v -> {
								var e = decodeTexpr(v);
								var str = generators.Genjs.genSingleExpr(jsCtx, e, true);
								encodeString(str);
							})),
							fld("setTypeAccessor", vfun1(callb -> {
								var callb = prepareCallback(callb, 1);
								jsCtx.typeAccessor = t -> decodeString(callb([encodeType(typeOfModuleType(t))]));
								vnull;
							})),
							fld("setCurrentClass", vfun1(c -> {
								generators.Genjs.setCurrentClass(jsCtx, switch decodeTypeDecl(c) {
									case TClassDecl(c): c;
									case _: Globals.die("", "macroApi.ml");
								});
								vnull;
							})),
						]);
						f([api]);
					}
					var com = ccom();
					com.jsGen = () -> {
						core.Path.mkdirFromPath(com.file);
						var jsCtx = generators.Genjs.allocCtx(Common.toGctx(com), generators.Gctx.getEsVersion(com.defines));
						gen(Common.toGctx(com), jsCtx);
					};
					vnull;
				})
				#end
			},
			{
				name: "flush_disk_cache",
				value: vfun0(() -> {
					var com = getApi().getCom();
					com.classPaths.clearCache();
					vnull;
				})
			},
			{
				name: "get_pos_infos",
				value: vfun1(p -> {
					var p = decodePos(p);
					encodeObj([
						fld("min", vint(p.pmin)),
						fld("max", vint(p.pmax)),
						fld("file", encodeString(p.pfile))
					]);
				})
			},
			{
				name: "make_position",
				value: vfun3((min, max, file) -> {
					encodePos({pmin: decodeInt(min), pmax: decodeInt(max), pfile: decodeString(file)});
				})
			},
			{
				name: "add_resource",
				value: vfun2((name, data) -> {
					var name = decodeString(name);
					var data = decodeBytes(data);
					if (name == "")
						failwith("Empty resource name");
					ccom().resources.replace(name, data);
					var m = getApi().currentModule();
					m.mExtra.mCacheBoundObjects.push(Resource(name, data));
					vnull;
				})
			},
			{
				name: "get_resources",
				value: vfun0(() -> {
					var pmapResources = new StringMap<haxe.io.Bytes>();
					ccom().resources.iter((k, v) -> pmapResources.set(k, v));
					encodeStringMap(encodeBytes, pmapResources);
				})
			},
			{
				name: "get_local_module",
				value: vfun0(() -> {
					var m = getApi().currentModule();
					encodeString(MacroApi.sTypePath(m.mPath));
				})
			},
			{
				name: "get_local_type",
				value: vfun0(() -> {
					switch getApi().getLocalType() {
						case null: vnull;
						case t: encodeType(t);
					}
				})
			},
			{
				name: "get_expected_type",
				value: vfun0(() -> {
					switch getApi().getExpectedType() {
						case null: vnull;
						case t: encodeType(t);
					}
				})
			},
			{
				name: "get_call_arguments",
				value: vfun0(() -> {
					switch getApi().getCallArguments() {
						case null: vnull;
						case el: encodeArrayV(el.map(encodeExpr));
					}
				})
			},
			{
				name: "get_local_method",
				value: vfun0(() -> {
					encodeString(getApi().getLocalMethod());
				})
			},
			{
				name: "get_local_using",
				value: vfun0(() -> {
					encodeArray(getApi().getLocalUsing().map(encodeClref));
				})
			},
			{
				name: "get_local_imports",
				value: vfun0(() -> {
					encodeArray(getApi().getLocalImports().map(encodeImport));
				})
			},
			{
				name: "local_vars",
				value: vfun1(asVar -> {
					var asVar = decodeOptBool(asVar);
					var vars = getApi().getLocalVars();
					encodeStringMap(if (asVar) encodeTvar else(v:TVar) -> encodeType(v.vType), vars);
				})
			},
			{
				name: "follow_with_abstracts",
				value: vfun2((v, once) -> {
					var t = decodeType(v);
					inline function followOnce(t:T):T {
						return switch t {
							case TMono(r):
								switch r.tmType {
									case null: t;
									case t: t;
								}
							case TAbstract(a, tl) if (!Meta.has(core.MetaList.StrictMeta.CoreType, a.aMeta)):
								core.Abstract.getUnderlyingType(a, tl);
							case TAbstract(_) | TEnum(_) | TInst(_) | TFun(_) | TAnon(_) | TDynamic(_):
								t;
							case TType(t, tl):
								applyTypedef(t, tl);
							case TLazy(f):
								lazyType(f);
						}
					}
					encodeType(if (decodeOptBool(once)) followOnce(t) else core.Abstract.followWithAbstracts(t));
				})
			},
			{
				name: "follow",
				value: vfun2((v, once) -> {
					var t = decodeType(v);
					encodeType(if (decodeOptBool(once)) TFunctions.followOnce(t) else follow(t));
				})
			},
			{
				name: "get_build_fields",
				value: vfun0(() -> {
					getApi().getBuildFields();
				})
			},
			{
				name: "define_type",
				value: vfun2((v, m) -> {
					getApi().defineType(v, opt(decodeString, m));
					vnull;
				})
			},
			{
				name: "make_monomorph",
				value: vfun0(() -> {
					var t = T.TMono(core.TUnification.Monomorph.create());
					encodeType(t);
				})
			},
			{
				name: "define_module",
				value: vfun4((path, vl, ui, ul) -> {
					getApi().defineModule(decodeString(path), decodeArray(vl), decodeArray(ui).map(v -> {
						var imp = decodeImport(v);
						{path: imp.path, mode: imp.mode};
					}), decodeArray(ul).map(decodeAstPath).map(ptp -> ptp.path));
					vnull;
				})
			},
			{
				name: "add_class_path",
				value: vfun1(cp -> {
					var com = ccom();
					var cp = decodeString(cp);
					var path = core.Path.addTrailingSlash(cp);
					var cp = new core.ClassPath.DirectoryClassPath(path, User);
					com.classPaths.add(cp);
					switch com.getMacros() {
						case null:
						case mcom:
							mcom.classPaths.add(cp.clone());
					}
					com.classPaths.clearCache();
					vnull;
				})
			},
			{
				name: "add_native_lib",
				value: vfun1(file -> {
					var file = decodeString(file);
					var com = ccom();
					var kind:compiler.ParsedArg.NativeLibKind = switch com.platform {
						case Jvm: JavaLib;
						case Flash: SwfLib;
						case _: failwith("Unsupported platform");
					}
					var lib = compiler.ParsedArg.ParsedArgTools.createNativeLib(file, false, kind);
					context.NativeLibraryHandler.addNativeLib(com, lib)();
					vnull;
				})
			},
			{
				name: "register_module_dependency",
				value: vfun2((m, file) -> {
					getApi().moduleDependency(decodeString(m), decodeString(file));
					vnull;
				})
			},
			{
				name: "get_typed_expr",
				value: vfun1(e -> {
					var e = decodeTexpr(e);
					encodeExpr(core.TOther.TExprToExpr.convertExpr(e));
				})
			},
			{
				name: "store_expr",
				value: vfun1(e -> {
					var api = getApi();
					var te = api.typeExpr(decodeExpr(e));
					encodeExpr(api.storeTypedExpr(te));
				})
			},
			{
				name: "store_typed_expr",
				value: vfun1(e -> {
					var e = decodeTexpr(e);
					encodeExpr(getApi().storeTypedExpr(e));
				})
			},
			{
				name: "type_and_store_expr",
				value: vfun1(e -> {
					var api = getApi();
					var te = api.typeExpr(decodeExpr(e));
					var vE = encodeExpr(api.storeTypedExpr(te));
					function vToString():String return core.TPrinting.sType(core.TPrinting.printContext(), te.etype);
					encodeObj([fld("expr", vE), fld("type", encodeRef(te.etype, encodeType, vToString))]);
				})
			},
			{
				name: "get_output",
				value: vfun0(() -> {
					encodeString(ccom().file);
				})
			},
			{
				name: "set_output",
				value: vfun1(s -> {
					ccom().file = decodeString(s);
					vnull;
				})
			},
			{
				name: "get_display_pos",
				value: vfun0(() -> {
					var p = core.display.DisplayPosition.displayPosition.get();
					if (posEq(p, Globals.nullPos))
						vnull;
					else
						encodeObj([fld("file", encodeString(p.pfile)), fld("pos", vint(p.pmin))]);
				})
			},
			{
				name: "get_display_mode",
				value: vfun0(() -> {
					encodeDisplayMode(ccom().display.dmsKind);
				})
			},
			{
				name: "get_configuration",
				value: vfun0(() -> {
					var com = ccom();
					encodeObj([
						fld("version", vint(com.sctx.version.version)),
						fld("args", encodeArray(compiler.Args.toRawArgs(com.parsedArgs).map(encodeString))),
						fld("debug", vbool(com.debug)),
						fld("verbose", vbool(com.verbose)),
						fld("foptimize", vbool(com.foptimize)),
						fld("platform", encodePlatform(com.platform)),
						fld("platformConfig", encodePlatformConfig(com.config)),
						fld("stdPath",
							encodeArray((com.classPaths.getStdPaths() : Array<core.ClassPath.IClassPath>).map(path ->
								encodeString(path.path)))),
						fld("mainClass", switch com.main.mainPath {
							case null: vnull;
							case path: encodePath(path);
						}),
						fld("packageRules", encodeStringMap(encodePackageRule, com.packageRules)),
					]);
				})
			},
			{
				name: "set_platform_configuration",
				value: vfun1(v -> {
					ccom().config = decodePlatformConfig(v);
					vnull;
				})
			},
			{
				name: "get_main_expr",
				value: vfun0(() -> {
					switch ccom().main.mainExpr {
						case null: vnull;
						case e: encodeTexpr(e);
					}
				})
			},
			{
				name: "get_module_types",
				value: vfun0(() -> {
					encodeArray(ccom().types.map(encodeModuleType));
				})
			},
			{
				name: "type_to_module_type",
				value: vfun1(t -> {
					encodeModuleType(moduleTypeOfType(decodeType(t)));
				})
			},
			{
				name: "module_type_to_type",
				value: vfun1(t -> {
					encodeType(typeOfModuleType(decodeModuleType(t)));
				})
			},
			{
				name: "apply_params",
				value: vfun3((tpl, tl, t) -> {
					var tl = mapDecodedArray(tl, decodeType);
					var tpl = mapDecodedArray(tpl, v -> {
						var t = decodeType(field(v, "t"));
						var defaultType:Null<T> = null; // we don't care here
						var c = switch t {
							case TInst(c = {clKind: KTypeParameter(_)}, _):
								c;
							case _:
								(getApi().excString("Unexpected type where type parameter was expected: "
									+ core.TPrinting.sTypeKind(t)) : TClass);
						}
						mkTypeParam(c, TPHType, defaultType, null);
					});
					function map(t:T):T {
						return switch t {
							case TInst({clKind: KTypeParameter(_)}, _):
								// use non-physical equality check here to make apply_params work
								var found = tpl.find(tp2 -> core.TUnification.TUnification.typeIseq(t, tp2.ttpType));
								if (found != null) extractParamType(found) else TFunctions.map(map, t);
							case _:
								TFunctions.map(map, t);
						}
					}
					var t = map(decodeType(t));
					var t = try {
						applyParams(tpl, tl, t);
					} catch (_:ApplyParamsMismatch) {
						var msg = "Could not apply type parameters to "
							+ core.TPrinting.sTypeKind(t)
							+ ":\n\tparams: "
							+ tpl.map(tp -> core.TPrinting.sTypeParam(core.TPrinting.sTypeKind, tp)).join(", ")
							+ "\n\ttypes: "
							+ tl.map(core.TPrinting.sTypeKind).join(", ");
						(getApi().excString(msg) : T);
					}
					encodeType(t);
				})
			},
			{
				name: "include_file",
				value: vfun2((file, position) -> {
					var file = decodeString(file);
					var position = decodeString(position);
					var file = if (sys.FileSystem.exists(file)) {
						file;
					} else {
						try Common.findFile(ccom(), file)
						catch (e:Dynamic) if (isNotFound(e)) failwith("unable to find file for inclusion: " + file)
						else throw e;
					}
					ccom().includeFiles = [({file: file, position: position} : context.Common.IncludeFile)].concat(ccom().includeFiles);
					var m = getApi().currentModule();
					m.mExtra.mCacheBoundObjects.push(IncludeFile(file, position));
					vnull;
				})
			},
			// Compilation server
			{
				name: "server_add_module_check_policy",
				value: vfun3((filter, policy, recursive) -> {
					var filter = decodeArray(filter).map(decodeString);
					var policy = decodeArray(policy).map(decodeInt);
					getApi().addModuleCheckPolicy(filter, policy, decodeBool(recursive));
					vnull;
				})
			},
			{
				name: "server_invalidate_module",
				value: vfun1(p -> {
					var mpath = Ast.parsePath(decodeString(p));
					var com = ccom();
					try {
						com.moduleLut.find(mpath);
						var msg = "Cannot invalidate loaded module " + MacroApi.sTypePath(mpath);
						var pos = getApiCallPos();
						compilerError(core.Error.makeError(core.Error.ErrorMsg.Custom(msg), pos));
					} catch (e:NotFound) {
						com.cs.taintModule(mpath, ServerInvalidateModule);
					}
					vnull;
				})
			},
			{
				name: "server_invalidate_files",
				value: vfun1(a -> {
					var com = ccom();
					var cs = com.cs;
					for (v in decodeArray(a)) {
						var s = decodeString(v);
						var s = com.partScope.fileKeys.get(s);
						cs.taintModules(s, ServerInvalidateFiles);
						cs.removeFiles(s);
					}
					vnull;
				})
			},
			{
				name: "server_stats",
				value: vfun0(() -> {
					var com = ccom();
					var stats = com.requestScope.stats;
					encodeObj([
						fld("filesParsed", vint(stats.sFilesParsed)),
						fld("modulesTyped", vint(stats.sModulesTyped)),
						fld("modulesRestoredFromHxb", vint(stats.sModulesRestored)),
						fld("classesBuilt", vint(stats.sClassesBuilt)),
						fld("methodsTyped", vint(stats.sMethodsTyped)),
						fld("macrosCalled", vint(stats.sMacrosCalled)),
					]);
				})
			},
			{
				name: "position_to_range",
				value: vfun1(p -> {
					var p = decodePos(p);
					var c = syntax.Lexer.getPosCoords(p);
					inline function makePos(line:Int, character:Int):Value {
						return encodeObj([fld("line", vint(line)), fld("character", vint(character)),]);
					}
					var posStart = makePos(c.lineStart, c.columnStart);
					var posEnd = makePos(c.lineEnd, c.columnEnd);
					var range = encodeObj([fld("start", posStart), fld("end", posEnd),]);
					var location = encodeObj([fld("file", encodeString(p.pfile)), fld("range", range)]);
					location;
				})
			},
			{
				name: "position_to_zero_range",
				value: vfun1(p -> {
					var p = decodePos(p);
					encodePos(Globals.mkZeroRangePos(p));
				})
			},
			{
				name: "on_null_safety_report",
				value: vfun1(f -> {
					var f = prepareCallback(f, 1);
					ccom().callbacks.addNullSafetyReport(function(errors:Array<{msg:String, pos:Pos}>,
							warnings:Array<{warning:core.Message.WarningCode, msg:String, pos:Pos}>):Void {
						inline function encodeItem(kind:String, msg:String, pos:Pos):Value {
							return encodeObj([
								fld("type", encodeString(kind)),
								fld("msg", encodeString(msg)),
								fld("pos", encodePos(pos))
							]);
						}
						function encodeWarning(w:{warning:core.Message.WarningCode, msg:String, pos:Pos}):Value {
							return encodeItem("warning", w.msg, w.pos);
						}
						var errors = errors.map(e -> encodeItem("error", e.msg, e.pos));
						var warnings = warnings.map(encodeWarning);
						f([encodeArray(errors.concat(warnings))]);
					});
					vnull;
				})
			},
			{
				name: "timer",
				value: vfun1(id -> {
					var com = ccom();
					var fullId = (com.timerCtx.current.id : Array<String>).concat([decodeString(id)]);
					// TIMERTODO: Exposing this seems potentially dangerous... Have to at least document.
					var stop = core.Timer.startTimer(com.timerCtx, fullId);
					vfun0(() -> {
						stop();
						vnull;
					});
				})
			},
			{
				name: "map_anon_ref",
				value: vfun2((aRef, fn) -> {
					var a:TAnon = decodeRef(aRef);
					var fn = prepareCallback(fn, 1);
					switch TFunctions.map(t -> decodeType(fn([encodeType(t)])), T.TAnon(a)) {
						case TAnon(a): encodeRef(a, encodeTanon, () -> "<anonymous>");
						case _: Globals.die("", "macroApi.ml map_anon_ref");
					}
				})
			},
			{
				name: "with_imports",
				value: vfun3((imports, usings, f) -> {
					var imports = decodeArray(imports).map(decodeString);
					var imports:Array<Import> = imports.map(s -> (getApi().parse((pctx,
							s) -> @:privateAccess syntax.Grammar.parseImport2(pctx, s, Globals.nullPos), s) : Import));
					var usings = decodeArray(usings).map(decodeString);
					var usings:Array<Vector<PlacedName>> = usings.map(s -> Vector.fromArrayCopy((getApi().parse((pctx,
							s) -> @:privateAccess syntax.Grammar.parseUsing2(pctx, s, Globals.nullPos), s) : Array<PlacedName>)));
					var f = prepareCallback(f, 0);
					(getApi().withImports(imports, usings, () -> f([])) : Value);
				})
			},
			{
				name: "with_options",
				value: vfun2((opts, f) -> {
					var o:CompilerOptions = {
						optInlining: opt(decodeBool, field(opts, "allowInlining")),
						optTransform: opt(decodeBool, field(opts, "allowTransform")),
					};
					var f = prepareCallback(f, 0);
					(getApi().withOptions(o, () -> f([])) : Value);
				})
			},
			{
				name: "set_var_name",
				value: vfun2((v, name) -> {
					var v = decodeTvar(v);
					var name = decodeString(name);
					v.vName = name;
					vnull;
				})
			},
			{
				name: "get_hxb_writer_config",
				value: vfun0(() -> {
					getApi().getHxbWriterConfig();
				})
			},
			{
				name: "set_hxb_writer_config",
				value: vfun1(v -> {
					getApi().setHxbWriterConfig(v);
					vnull;
				})
			},
			{
				name: "associate_enum_value_pos",
				value: vfun2((ve, vp) -> {
					var p = decodePos(vp);
					associateEnumValuePos(ve, p);
					vnull;
				})
			},
		];
	}
}

// port: hook (not upstream): the values of a macro engine whose code is the
// compiler's own kind of code, sharing its heap (hxmc's -D hxmc.macros=mir,
// hxmc/src/hxmc/interp/MirMacros.hx): MacroApiImpl's bindings use these when
// `MacroApiImpl.nativeValues` is set. The values are the compiler's Haxe
// values: Int, Float, Bool, String, Array, Bytes, anonymous objects, the
// macro context's haxe.macro enums, closures; positions, module types and the
// objects behind references are the compiler's own (opaque to macro code).
// (std.Int, std.String...: core.Ast's Constant has constructors of those names)
class MacroNativeValues {
	// the macro context's enum of a kind (set by the engine once its types are loaded)
	public static var resolveEnum:String->Null<Enum<Dynamic>> = name -> Type.resolveEnum(name);
	// a class of the macro context (haxe.macro.Error)
	public static var resolveClass:String->Null<Class<Dynamic>> = name -> Type.resolveClass(name);
	// the position of the macro API call being made
	public static var apiCallPos:Void->Pos = () -> Globals.nullPos;

	static var enums = new Map<String, Enum<Dynamic>>();
	static var enumPos = new haxe.ds.ObjectMap<Dynamic, Pos>();
	static var lazyTypes = new haxe.ds.ObjectMap<Dynamic, TLazy>();

	// (the enums found so far: again after more types are loaded)
	public static function reset() {
		enums = new Map();
	}

	// (the engine's values so far are no longer used: its code is compiled again,
	// MirMacros.newGeneration; the positions and types they map to are dropped)
	public static function dropValues() {
		enumPos = new haxe.ds.ObjectMap();
		lazyTypes = new haxe.ds.ObjectMap();
	}

	static function enumOf(k:EnumType):Enum<Dynamic> {
		var name = "haxe.macro." + Std.string(k).substr(1);
		name = switch k {
			case IExpr: "haxe.macro.ExprDef";
			case IEFieldKind: "haxe.macro.EFieldKind";
			case IConst: "haxe.macro.Constant";
			case ITParam: "haxe.macro.TypeParam";
			case ICType: "haxe.macro.ComplexType";
			case IField: "haxe.macro.FieldType";
			case ITypedExpr: "haxe.macro.TypedExprDef";
			case _: name;
		}
		var e = enums.get(name);
		if (e == null) {
			e = resolveEnum(name);
			if (e == null) throw new core.ds.Failure("the macro context has no enum " + name);
			enums.set(name, e);
		}
		return e;
	}

	public static function encodeEnum(k:EnumType, pos:Null<Pos>, index:Int, args:Array<Dynamic>):Dynamic {
		var v:Dynamic = Type.createEnumIndex(enumOf(k), index, args);
		if (pos != null && args.length > 0) enumPos.set(v, pos);
		return v;
	}

	public static function encodeObj(l:Array<{name:String, value:Dynamic}>):Dynamic {
		var o:Dynamic = {};
		for (f in l)
			Reflect.setField(o, f.name, f.value);
		return o;
	}

	public static function encodeStringMap<A>(convert:A->Dynamic, m:StringMap<A>):Dynamic {
		var r = new StringMap<Dynamic>();
		for (k => v in m)
			r.set(k, convert(v));
		return r;
	}

	public static function encodeLazytype(t:TLazy, f:Void->Dynamic):Dynamic {
		var v:Dynamic = f;
		lazyTypes.set(v, t);
		return v;
	}

	public static function decodeLazytype(v:Dynamic):TLazy {
		var t = lazyTypes.get(v);
		if (t == null) throw InvalidExpr.raise();
		return t;
	}

	public static function decodeBool(v:Dynamic):Bool {
		if (!Std.isOfType(v, StdTypes.Bool)) throw InvalidExpr.raise();
		return v;
	}

	public static function decodeInt(v:Dynamic):Int {
		if (!Std.isOfType(v, StdTypes.Int)) throw InvalidExpr.raise();
		return v;
	}

	public static function decodeString(v:Dynamic):String {
		if (!Std.isOfType(v, std.String)) throw InvalidExpr.raise();
		return v;
	}

	public static function decodeArray(v:Dynamic):Array<Dynamic> {
		if (!Std.isOfType(v, std.Array)) throw InvalidExpr.raise();
		return v;
	}

	public static function decodePos(v:Dynamic):Pos {
		if (!Std.isOfType(v, Pos)) throw InvalidExpr.raise();
		return v;
	}

	public static function decodeEnum(v:Dynamic):{index:Int, args:Array<Dynamic>} {
		if (!Reflect.isEnumValue(v)) throw InvalidExpr.raise();
		return {index: Type.enumIndex(v), args: Type.enumParameters(v)};
	}

	public static function decodeEnumWithPos(v:Dynamic):{index:Int, args:Array<Dynamic>, pos:Pos} {
		var d = decodeEnum(v);
		var p = enumPos.get(v);
		return {index: d.index, args: d.args, pos: p == null ? Globals.nullPos : p};
	}

	public static function associateEnumValuePos(v:Dynamic, p:Pos)
		if (Reflect.isEnumValue(v) && Type.enumParameters(v).length > 0) enumPos.set(v, p);

	public static function encodeRef<A>(v:A, convert:A->Dynamic, tostr:Void->String):Dynamic
		return new NativeRef(v, () -> convert(v), tostr);

	public static function decodeRef(v:Dynamic):Dynamic {
		if (!Std.isOfType(v, NativeRef)) throw InvalidExpr.raise();
		return (v : NativeRef).value;
	}

	// a haxe.macro.Error thrown into the macro code, as Eval raises it (EvalMain.compilerError)
	public static function compilerError(err:core.Error.CompilerError):Dynamic {
		var c = resolveClass("haxe.macro.Error");
		if (c == null) throw new core.Error.TypingError(err);
		function make(err:core.Error.CompilerError):Dynamic
			return Type.createInstance(c, [core.Error.errorMsg(err.errMessage), err.errPos]);
		var e = make(err);
		if (err.errSub.length > 0) {
			// port: the sub-errors, each with its own, in EvalMain.compilerError's order
			var stack:Array<Dynamic> = [];
			var subs = err.errSub.copy();
			subs.reverse();
			for (sub in subs)
				core.Error.Error.recurseError((_, x) -> stack.unshift(make(x)), sub);
			stack.reverse();
			Reflect.setField(e, "childErrors", stack);
		}
		throw e;
	}

	public static function valueSignature(v:Dynamic):String {
		var s = new haxe.Serializer();
		s.useCache = true;
		s.serialize(v);
		return haxe.crypto.Md5.encode(s.toString());
	}

	// port: what runs a function of the API that macro code calls (the engine's: the compiler's own code)
	public static var apiCall:(Void->Dynamic)->Dynamic = call -> call();

	// port: what runs a macro function the compiler calls back (the engine's, as it runs macro code)
	public static var callback:(Void->Dynamic)->Dynamic = call -> call();

	public static function prepareCallback(v:Dynamic, nargs:Int):Array<Dynamic>->Dynamic
		return args -> callback(() -> Reflect.callMethod(null, v, args));

	public static function valueString(v:Dynamic):String
		return Std.string(v);

	// a constant argument of a macro function, typed (MacroContext.typeMacro:
	// Texpr.typeConstantValue's forms, in the typer's wrapping and casts), as
	// Eval evaluates it (EvalMain.eval_expr)
	public static function evalConstant(e:TExpr):Dynamic {
		return switch e.eexpr {
			case TConst(TInt(i)): i;
			case TConst(TFloat(f)): core.ds.OcamlFloat.ofString(f);
			case TConst(TString(s)): s;
			case TConst(TBool(b)): b;
			case TConst(TNull): null;
			case TParenthesis(e1) | TMeta(_, e1) | TCast(e1, null): evalConstant(e1);
			case TArrayDecl(el): [for (e in el) evalConstant(e)];
			case TObjectDecl(fl): encodeObj([for (f in fl) {name: f.key.name, value: evalConstant(f.expr)}]);
			case TArray(e1, {eexpr: TConst(TInt(i))}):
				var a:Array<Dynamic> = evalConstant(e1);
				a[i];
			case _:
				throw new core.Error.TypingError(core.Error.makeError(core.Error.ErrorMsg.Custom("This macro argument is not a constant the compiler evaluates (-D hxmc.macros=mir)"), e.epos));
		}
	}

	// the path of a type of the macro context as an expression names it (its
	// module's path, then its name when they differ: EvalMain.value_to_expr)
	public static var typePath:String->Array<String> = name -> name.split(".");

	// EvalMain.value_to_expr over these values
	public static function valueToExpr(v:Dynamic, p:Pos):Expr {
		function path(name:String):Expr {
			var l = typePath(name);
			var e:Expr = {expr: EConst(Ident(l[0])), pos: p};
			for (i in 1...l.length)
				e = {expr: EField(e, l[i], EFNormal), pos: p};
			return e;
		}
		function entry(k:Expr, x:Dynamic):Expr
			return {expr: EBinop(OpArrow, k, valueToExpr(x, p)), pos: p};
		if (v == null) return {expr: EConst(Ident("null")), pos: p};
		if (Std.isOfType(v, StdTypes.Bool)) return {expr: EConst(Ident(v ? "true" : "false")), pos: p};
		// port: by the value's kind, as Eval's VInt32 and VFloat (an integral Float is an Int to Std.isOfType)
		switch Type.typeof(v) {
			case TInt: return {expr: EConst(Int(Std.string(v), null)), pos: p};
			case TFloat: return MacroApi.haxeFloat(v, p);
			case _:
		}
		if (Std.isOfType(v, std.String)) return {expr: EConst(String(v, SDoubleQuotes)), pos: p};
		if (Std.isOfType(v, std.Array)) return {expr: EArrayDecl(Vector.fromArrayCopy([for (x in (v : Array<Dynamic>)) valueToExpr(x, p)])), pos: p};
		if (Reflect.isEnumValue(v)) {
			var e = Type.getEnum(v);
			var ep:Expr = {expr: EField(path(Type.getEnumName(e)), Type.enumConstructor(v), EFNormal), pos: p};
			var args = Type.enumParameters(v);
			return args.length == 0 ? ep : {expr: ECall(ep, Vector.fromArrayCopy([for (a in args) valueToExpr(a, p)])), pos: p};
		}
		if (Std.isOfType(v, haxe.ds.StringMap))
			return {expr: EArrayDecl(Vector.fromArrayCopy([for (k => x in (v : StringMap<Dynamic>)) entry({expr: EConst(String(k, SDoubleQuotes)), pos: p}, x)])), pos: p};
		if (Std.isOfType(v, haxe.ds.IntMap))
			return {expr: EArrayDecl(Vector.fromArrayCopy([for (k => x in (v : haxe.ds.IntMap<Dynamic>)) entry({expr: EConst(Int(Std.string(k), null)), pos: p}, x)])), pos: p};
		if (Std.isOfType(v, haxe.ds.ObjectMap))
			return {expr: EArrayDecl(Vector.fromArrayCopy([for (k => x in (v : haxe.ds.ObjectMap<Dynamic, Dynamic>)) entry(valueToExpr(k, p), x)])), pos: p};
		if (Type.getClass(v) == null && Type.typeof(v) == TObject) {
			var fields:Array<ObjectField> = [];
			for (n in Reflect.fields(v)) {
				var x:Dynamic = Reflect.field(v, n);
				// (as Eval: a generated pos field left out, #8261)
				if (n == "pos" && Std.isOfType(x, Pos)) continue;
				fields.push({
					key: {name: n, pos: p, quote: syntax.Lexer.isValidIdentifier(n) ? NoQuotes : DoubleQuotes},
					expr: valueToExpr(x, p)
				});
			}
			return {expr: EObjectDecl(Vector.fromArrayCopy(fields)), pos: p};
		}
		throw "Cannot convert " + Std.string(v) + " to expr";
	}
}

// port: hook (not upstream): a reference (haxe.macro.Type.Ref) of MacroNativeValues: its object, get, toString
class NativeRef {
	public var value:Dynamic;
	var getter:Void->Dynamic;
	var tostr:Void->String;

	public function new(value:Dynamic, getter:Void->Dynamic, tostr:Void->String) {
		this.value = value;
		this.getter = getter;
		this.tostr = tostr;
	}

	public function get():Dynamic
		return getter();

	public function toString():String
		return tostr();
}
