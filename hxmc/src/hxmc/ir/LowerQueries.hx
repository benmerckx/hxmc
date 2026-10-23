package hxmc.ir;

import hxmc.ir.Ir;
import core.TType;
import haxe.ds.Vector;

// What lowering a function body (FnLower) may ask of the lowering of the
// program (Lower), and all of it: FnLower holds this interface, not Lower,
// so a body reads nothing of the program's lowering but these answers.
//
// The compilation server reuses a body lowered in an earlier build
// (hxmc/src/hxmc/LowerCache.hx): it replays the queries the body made, in
// their order, and copies the body when every answer is what it was. That
// is sound when the body depends only on its own typed expression and on
// the answers it was given. Each query below says why its answer is
// covered, by one of these tags (checked by hxmc/test/LowerQueriesCheck.hx,
// a lane of `make quick`: every query has one, and each @:logged one is
// overridden in LowerCache.hx):
//
//   @:logged   recorded with its arguments and answer by CachedLower
//              (CachedProgram for sig and shape) and asked again on replay:
//              the new answer is bound to the old one, or compared with it,
//              and a difference lowers the body again
//   @:derived  a function of the answer of a logged query (named), whose
//              binding checks what this one reads
//   @:declared what the declarations of the types the body refers to say: a
//              body is replayed only when its module was not typed again,
//              and the server types a module again when any module it
//              depends on changed (no early cutoff there: the module cache
//              is not open in the server, ModuleCache.hx), so the
//              declarations a body reaches by its own types and calls are
//              those it was lowered with. Never for what is found below a
//              class (its subclasses, an interface's implementations): no
//              dependency covers those, so such a query is @:logged
//   @:pure     a function of its arguments alone (objects of the body's own
//              typed expression), or a diagnostic with no effect on the
//              output
//
// Outside this interface, FnLower reads only Lower's static settings,
// which are the build's: the target and platform (Lower.targetConst),
// lines, bounds, nullChecks, wasmGc and the resources' names are compared by
// LowerCache.lower, which drops every body when one changes; survey comes
// from the environment, fixed for a process. The fields of the IR objects
// the queries give (a ClassInfo's fields, a FuncInfo's arguments and result,
// a CtorInfo's parameters) are bound to the old ones field by field
// (CachedLower.bindClass, bindFunc...).
interface LowerQueries {
	// ---- types and declarations made IR objects (their effects: what they make reachable)

	@:logged function ty(t:T):Ty;
	@:logged function classInfo(c:TClass):ClassInfo;
	@:logged function enumInfo(e:TEnum):EnumInfo;
	@:logged function ctorInfo(ef:TEnumField, en:TEnum):CtorInfo;
	@:logged function staticFunc(c:TClass, cf:TClassField):FuncInfo;
	@:logged function method(c:TClass, cf:TClassField):FuncInfo;
	@:logged function ctor(c:TClass):FuncInfo;
	@:logged function structCtor(c:TClass):FuncInfo;
	@:logged function structBox(name:String):ClassInfo;
	@:logged function staticVar(c:TClass, cf:TClassField):Int;
	@:logged function reflectStatics(c:TClass):Void;
	@:logged function reflectEnum(e:TEnum):Void;
	@:logged function rootClass():ClassInfo;
	@:logged function superOf(ci:ClassInfo):TClass;

	// ---- closures

	@:logged function staticClosure(f:FuncInfo):LambdaInfo;
	@:logged function hostClosure(name:String, sig:SigInfo, ?self:Ty):LambdaInfo;
	@:logged function ctorClosure(ci:CtorInfo, sig:SigInfo):LambdaInfo;
	@:logged function boundClosure(f:Null<FuncInfo>, dispatch:Null<{sel:Int, sig:SigInfo, args:Array<Ty>, ?cls:TClass}>, owner:FuncInfo):LambdaInfo;
	@:logged function adapter(from:SigInfo, to:SigInfo):LambdaInfo;
	@:logged function dynAdapter(to:SigInfo):LambdaInfo;
	// (a closure written in the body: its own body is recorded by its own entry)
	@:logged function newLambda(sig:SigInfo, captures:Vector<Local>, body:FnLower->Void, name:String, module:String):LambdaInfo;

	// ---- the program's numbers and shapes

	@:logged function selector(name:String, sig:SigInfo):Int;
	@:logged function sig(args:Array<Ty>, ret:Ty):SigInfo;
	@:logged function shape(fields:Array<{name:String, ty:Ty}>):ShapeInfo;
	// the type of global g (staticVar's, or an enum constructor's singleton)
	@:logged function globalTy(g:Int):Ty;
	// the name of selector s
	@:logged function selectorName(s:Int):String;

	// ---- dispatch: what the classes under a class do

	@:logged function needsDispatch(c:TClass, name:String):Bool;
	@:logged function lookupMethod(c:TClass, name:String):Null<{cls:TClass, field:TClassField}>;
	@:logged function implementors(c:TClass, name:String):Array<{cls:TClass, field:TClassField}>;
	@:logged function rootDecl(c:TClass, name:String):TClassField;

	// ---- default values of arguments

	// a function's (from staticFunc, method, ctor or structCtor), from its
	// declaration (logged by their text: the objects are new when its module
	// is typed again, the values the same)
	@:logged function argDefaults(f:FuncInfo):Null<ArgDefaults>;
	// a method's own, as declared by field cf of class c, for a dispatched
	// call's implementations (implementors: modules the body does not depend on)
	@:logged function fieldDefaults(c:TClass, cf:TClassField):Null<ArgDefaults>;

	// ---- C interop

	// declares C function sym, the extern field cf of class c, for this
	// build (CInterop.declare: its signature, @:hxmc.fast, its library; and
	// @:hxmc.varargs): a replayed body declares its C functions again
	@:logged function cExtern(sym:String, c:TClass, cf:TClassField):CInterop.CSig;
	// the symbol of a @:hxmc.callback function: of its name (staticFunc)
	@:derived function callbackSym(f:FuncInfo):String;
	// the @:hxmc.struct class of a struct type's name (ty's TStruct)
	@:declared function structClass(name:String):TClass;
	// the @:hxmc.struct class of a struct value of type t, or null
	@:declared function structOf(t:T):Null<TClass>;

	// ---- representation

	// t, or the reference to its box for a struct (structBox)
	@:derived function boxed(t:Ty):Ty;
	// the field names of a structural type, sorted
	@:pure function anonNames(an:TAnon):Array<String>;
	// a runtime function's name, counted for the survey (HXMC_SURVEY)
	@:pure function native(name:String):String;
	// an unsupported construct, for the survey
	@:pure function record(e:Lower.LowerError, fn:String):Void;
}

// The default values of a function's arguments (from 0, the receiver
// first for a method: null there), and the variables they belong to (a
// default value may read the arguments before it: FnLower.defaultValue)
class ArgDefaults {
	public final values:Array<Null<TExpr>>;
	public final vars:Array<Null<TVar>>;

	public function new(values, vars) {
		this.values = values;
		this.vars = vars;
	}
}
