package core;

import core.Ast.Binop;
import core.Ast.ClassField;
import core.Ast.Documentation;
import core.Ast.Expr;
import core.Ast.Metadata;
import core.Ast.MetadataEntry;
import core.Ast.QuoteStatus;
import core.Ast.Unop;
import core.Ast.UnopFlag;
import core.Ast.WhileFlag;
import core.ds.AtomicLazy;
import core.Globals.GlobalTypePath;
import core.Globals.Pos;
import core.Message.CompilerMessage;
import haxe.ds.IntMap;
import haxe.ds.StringMap;
import haxe.ds.Vector;

// port: the PMap-typed fields (fields of anonymous structures and classes, constraint fields) are
// StringMaps; code that iterates them goes through core.ds.PMap (sorted keys).
typedef TypeMap<T> = StringMap<T>;

enum FieldKind {
	Var(kind:VarKind);
	Method(kind:MethodKind);
}

@:structInit class VarKind {
	public var vRead:VarAccess;
	public var vWrite:VarAccess;

	public inline function new(vRead:VarAccess, vWrite:VarAccess) {
		this.vRead = vRead;
		this.vWrite = vWrite;
	}

	public inline function clone():VarKind return new VarKind(vRead, vWrite);
}

enum VarAccess {
	AccNormal;
	AccNo; /* can't be accessed outside of the class itself and its subclasses */
	AccNever; /* can't be accessed, even in subclasses */
	AccCtor; /* can only be accessed from the constructor */
	AccCall; /* perform a method call when accessed */
	AccPrivateCall; /* perform a method call when accessed, but private like AccNo */
	AccInline; /* similar to Normal but inline when accessed */
	AccRequire(condition:String, message:Null<String>); /* set when @:require(cond) fails */
}

enum MethodKind {
	MethNormal;
	MethInline;
	MethDynamic;
	MethMacro;
}

enum ModuleCheckPolicy {
	NoFileSystemCheck;
	CheckFileModificationTime;
	CheckFileContentModification;
}

enum ModuleTaintingReason {
	CheckDisplayFile;
	DefineType;
	DefineModule;
	ServerInvalidate;
	ServerInvalidateFiles;
	ServerInvalidateModule;
}

enum ModuleSkipReason {
	DependencyDirty(path:GlobalTypePath, reason:ModuleSkipReason);
	Tainted(reason:ModuleTaintingReason);
	FileChanged(file:String);
	Shadowed(file:String);
	LibraryChanged;
}

enum ModuleCacheState {
	MSGood;
	MSBad(reason:ModuleSkipReason);
	MSUnknown;
}

enum TypeParamHost {
	TPHType;
	TPHConstructor;
	TPHMethod;
	TPHEnumConstructor;
	TPHAnonField;
	TPHLocal;
	TPHUnbound;
}

enum CacheBoundObject {
	Resource(name:String, data:haxe.io.Bytes);
	IncludeFile(file:String, contents:String);
	Message(value:CompilerMessage);
}

enum T {
	TMono(mono:TMono);
	TEnum(en:TEnum, params:TParams);
	TInst(cls:TClass, params:TParams);
	TType(def:TDef, params:TParams);
	TFun(signature:TSignature);
	TAnon(anon:TAnon);
	TDynamic(inner:Null<T>);
	TLazy(lazy:TLazy);
	TAbstract(abs:TAbstract, params:TParams);
}

@:structInit class TMono {
	public var tmType:Null<T>;
	/*
		```
		function fn<A,B:A>() {}
		```
		`A` is a down-constraint for `B`
		`B` is an up-constraint for `A`
	*/
	public var tmDownConstraints:Array<TMonoConstraint>;
	public var tmUpConstraints:Array<{var type:T; var name:Null<String>;}>;
	public var tmModifiers:Array<TMonoModifier>;

	public inline function new(tmType:Null<T>, tmDownConstraints:Array<TMonoConstraint>,
			tmUpConstraints:Array<{var type:T; var name:Null<String>;}>, tmModifiers:Array<TMonoModifier>) {
		this.tmType = tmType;
		this.tmDownConstraints = tmDownConstraints;
		this.tmUpConstraints = tmUpConstraints;
		this.tmModifiers = tmModifiers;
	}

	public inline function clone():TMono return new TMono(tmType, tmDownConstraints, tmUpConstraints, tmModifiers);
}

enum TMonoConstraint {
	MMono(mono:TMono, name:Null<String>);
	MField(field:TClassField);
	MType(type:T, name:Null<String>);
	MEmptyStructure;
}

enum TMonoConstraintKind {
	CUnknown;
	CStructural(fields:TypeMap<TClassField>, open:Bool);
	CMixed(kinds:Array<TMonoConstraintKind>);
	CTypes(types:Array<{var type:T; var name:Null<String>;}>);
}

enum TMonoModifier {
	MNullable(callback:T->T);
	MOpenStructure;
	MDynamic; /* There was a unificaiton against Dynamic, which didn't bind the mono */
}

enum TLazyState {
	LAvailable(type:T);
	LProcessing(type:T);
	LWait(callback:Void->T);
}

// port: tlazy ref: forcing a lazy type updates the cell that every TLazy sharing it sees.
class TLazy {
	public var value:TLazyState;

	public function new(value:TLazyState) this.value = value;
}

@:structInit class TSignature {
	public var args:Vector<{var name:String; var optional:Bool; var type:T;}>;
	public var ret:T;

	public inline function new(args:Vector<{var name:String; var optional:Bool; var type:T;}>, ret:T) {
		this.args = args;
		this.ret = ret;
	}

	public inline function clone():TSignature return new TSignature(args, ret);
}

typedef TParams = Vector<T>;
// port: `(tclass * tparams)`, as in `cl_super`/`cl_implements`.
typedef ClassAndParams = {var cls:TClass; var params:TParams;};

// port: an `a_from_field`/`a_to_field` entry: `(t * tclass_field)`.
typedef CastField = {var type:T; var field:TClassField;};

// port: `Abstract.find_to_from` result: `(tabstract * tparams * (t * tclass_field))`.
typedef AbstractCastField = {var abs:TAbstract; var params:TParams; var field:CastField;};

@:structInit class TypedTypeParam {
	public var ttpName:String;
	public var ttpClass:TClass;
	public var ttpHost:TypeParamHost;
	public var ttpType:T;
	public var ttpConstraints:Null<AtomicLazy<TParams>>;
	public var ttpDefault:Null<T>;

	public inline function new(ttpName:String, ttpClass:TClass, ttpHost:TypeParamHost, ttpType:T,
			ttpConstraints:Null<AtomicLazy<TParams>>, ttpDefault:Null<T>) {
		this.ttpName = ttpName;
		this.ttpClass = ttpClass;
		this.ttpHost = ttpHost;
		this.ttpType = ttpType;
		this.ttpConstraints = ttpConstraints;
		this.ttpDefault = ttpDefault;
	}

	public inline function clone():TypedTypeParam return new TypedTypeParam(ttpName, ttpClass, ttpHost, ttpType, ttpConstraints,
		ttpDefault);
}

typedef TypeParams = Vector<TypedTypeParam>;

enum TConstant {
	TInt(value:Int);
	TFloat(value:String);
	TString(value:String);
	TBool(value:Bool);
	TNull;
	TThis;
	TSuper;
}

@:structInit class TVarExtra {
	public var vParams:TypeParams;
	public var vExpr:Null<TExpr>;

	public inline function new(vParams:TypeParams, vExpr:Null<TExpr>) {
		this.vParams = vParams;
		this.vExpr = vExpr;
	}

	public inline function clone():TVarExtra return new TVarExtra(vParams, vExpr);
}

enum TVarOrigin {
	TVOLocalVariable;
	TVOArgument;
	TVOForVariable;
	TVOPatternVariable;
	TVOCatchVariable;
	TVOLocalFunction;
}

enum TVarKind {
	VUser(origin:TVarOrigin);
	VGenerated;
	VInlined;
	VInlinedConstructorVariable(fields:Array<String>);
	VExtractorVariable;
	VAbstractThis;
}

@:structInit class TVar {
	public var vId:Int;
	public var vName:String;
	public var vType:T;
	public var vKind:TVarKind;
	public var vExtra:Null<TVarExtra>;
	public var vMeta:Metadata;
	public var vFlags:Int;
	public var vPos:Pos;

	public inline function new(vId:Int, vName:String, vType:T, vKind:TVarKind, vExtra:Null<TVarExtra>, vMeta:Metadata, vFlags:Int,
			vPos:Pos) {
		this.vId = vId;
		this.vName = vName;
		this.vType = vType;
		this.vKind = vKind;
		this.vExtra = vExtra;
		this.vMeta = vMeta;
		this.vFlags = vFlags;
		this.vPos = vPos;
	}

	public inline function clone():TVar return new TVar(vId, vName, vType, vKind, vExtra, vMeta, vFlags, vPos);
}

@:structInit class TFunc {
	public var tfArgs:Vector<{var variable:TVar; var defaultValue:Null<TExpr>;}>;
	public var tfType:T;
	public var tfExpr:TExpr;

	public inline function new(tfArgs:Vector<{var variable:TVar; var defaultValue:Null<TExpr>;}>, tfType:T, tfExpr:TExpr) {
		this.tfArgs = tfArgs;
		this.tfType = tfType;
		this.tfExpr = tfExpr;
	}

	public inline function clone():TFunc return new TFunc(tfArgs, tfType, tfExpr);
}

enum AnonStatus {
	Closed;
	Const;
	Extend(types:TParams);
	ClassStatics(cls:TClass);
	EnumStatics(en:TEnum);
	AbstractStatics(abs:TAbstract);
}

// port: OCaml's `anon_status ref`. `map` (and so apply_params) and tanon_identification build
// ...new anons sharing the ref of the original, so a later `:=` (e.g. closing the object
// ...declarations of a function in TypeloadFunction) reaches every copy.
class AnonStatusRef {
	public var v:AnonStatus;

	public inline function new(v:AnonStatus) this.v = v;
}

@:structInit class TAnon {
	public var aFields:TypeMap<TClassField>;
	public var aStatusRef:AnonStatusRef;
	public var aStatus(get, set):AnonStatus;

	inline function get_aStatus():AnonStatus return aStatusRef.v;

	inline function set_aStatus(v:AnonStatus):AnonStatus return aStatusRef.v = v;

	public inline function new(aFields:TypeMap<TClassField>, aStatus:AnonStatus) {
		this.aFields = aFields;
		this.aStatusRef = new AnonStatusRef(aStatus);
	}

	// port: `{ a_fields = fields; a_status = a.a_status }`: shares the status ref.
	public static inline function withStatusRef(aFields:TypeMap<TClassField>, r:AnonStatusRef):TAnon {
		var a = new TAnon(aFields, null);
		a.aStatusRef = r;
		return a;
	}

	// port: an OCaml record copy shares the status ref.
	public inline function clone():TAnon return withStatusRef(aFields, aStatusRef);
}

enum TExprDef {
	TConst(value:TConstant);
	TLocal(variable:TVar);
	TArray(array:TExpr, index:TExpr);
	TBinop(op:Binop, left:TExpr, right:TExpr);
	TField(expr:TExpr, access:TFieldAccess);
	TTypeExpr(type:ModuleType);
	TParenthesis(expr:TExpr);
	TObjectDecl(fields:Vector<{var key:{var name:String; var pos:Pos; var quote:QuoteStatus;}; var expr:TExpr;}>);
	TArrayDecl(values:Vector<TExpr>);
	TCall(expr:TExpr, args:Vector<TExpr>);
	TNew(cls:TClass, params:TParams, args:Vector<TExpr>);
	TUnop(op:Unop, flag:UnopFlag, expr:TExpr);
	TFunction(func:TFunc);
	TVar(variable:TVar, expr:Null<TExpr>);
	TBlock(exprs:Vector<TExpr>);
	TIf(condition:TExpr, thenExpr:TExpr, elseExpr:Null<TExpr>);
	TWhile(condition:TExpr, body:TExpr, flag:WhileFlag);
	TSwitch(switchExpr:TSwitch);
	TTry(expr:TExpr, catches:Vector<{var variable:TVar; var expr:TExpr;}>);
	TReturn(expr:Null<TExpr>);
	TBreak;
	TContinue;
	TThrow(expr:TExpr);
	TCast(expr:TExpr, type:Null<ModuleType>);
	TMeta(meta:MetadataEntry, expr:TExpr);
	TEnumParameter(expr:TExpr, field:TEnumField, index:Int);
	TEnumIndex(expr:TExpr);
	TIdent(name:String);
}

@:structInit class TSwitch {
	public var switchSubject:TExpr;
	public var switchCases:Vector<TSwitchCase>;
	public var switchDefault:Null<TExpr>;
	public var switchExhaustive:Bool;

	public inline function new(switchSubject:TExpr, switchCases:Vector<TSwitchCase>, switchDefault:Null<TExpr>, switchExhaustive:Bool) {
		this.switchSubject = switchSubject;
		this.switchCases = switchCases;
		this.switchDefault = switchDefault;
		this.switchExhaustive = switchExhaustive;
	}

	public inline function clone():TSwitch return new TSwitch(switchSubject, switchCases, switchDefault, switchExhaustive);
}

@:structInit class TSwitchCase {
	public var casePatterns:Vector<TExpr>;
	public var caseExpr:TExpr;

	public inline function new(casePatterns:Vector<TExpr>, caseExpr:TExpr) {
		this.casePatterns = casePatterns;
		this.caseExpr = caseExpr;
	}

	public inline function clone():TSwitchCase return new TSwitchCase(casePatterns, caseExpr);
}

enum TFieldAccess {
	FInstance(cls:TClass, params:TParams, field:TClassField);
	FStatic(cls:TClass, field:TClassField);
	FAnon(field:TClassField);
	FDynamic(name:String);
	FClosure(cls:Null<{var cls:TClass; var params:TParams;}>, field:TClassField); /* None class = TAnon */
	FEnum(en:TEnum, field:TEnumField);
}

// port: a class rather than a structure so static targets access fields directly;
// @:structInit keeps `{eexpr:..., etype:..., epos:...}` literals working.
@:structInit class TExpr {
	public var eexpr:TExprDef;
	public var etype:T;
	public var epos:Pos;

	public inline function new(eexpr:TExprDef, etype:T, epos:Pos) {
		this.eexpr = eexpr;
		this.etype = etype;
		this.epos = epos;
	}

	public inline function clone():TExpr return new TExpr(eexpr, etype, epos);
}

@:structInit class TClassField {
	public var cfName:String;
	public var cfType:T;
	public var cfPos:Pos;
	public var cfNamePos:Pos;
	public var cfDoc:Documentation;
	public var cfMeta:Metadata;
	public var cfKind:FieldKind;
	public var cfParams:TypeParams;
	public var cfExpr:Null<TExpr>;
	public var cfExprUnoptimized:Null<TExpr>;
	public var cfOverloads:Array<TClassField>;
	public var cfFlags:Int;

	public inline function new(cfName:String, cfType:T, cfPos:Pos, cfNamePos:Pos, cfDoc:Documentation, cfMeta:Metadata, cfKind:FieldKind,
			cfParams:TypeParams, cfExpr:Null<TExpr>, cfExprUnoptimized:Null<TExpr>, cfOverloads:Array<TClassField>, cfFlags:Int) {
		this.cfName = cfName;
		this.cfType = cfType;
		this.cfPos = cfPos;
		this.cfNamePos = cfNamePos;
		this.cfDoc = cfDoc;
		this.cfMeta = cfMeta;
		this.cfKind = cfKind;
		this.cfParams = cfParams;
		this.cfExpr = cfExpr;
		this.cfExprUnoptimized = cfExprUnoptimized;
		this.cfOverloads = cfOverloads;
		this.cfFlags = cfFlags;
	}

	public inline function clone():TClassField return new TClassField(cfName, cfType, cfPos, cfNamePos, cfDoc, cfMeta, cfKind, cfParams,
		cfExpr, cfExprUnoptimized, cfOverloads, cfFlags);
}

enum TClassKind {
	KNormal;
	KTypeParameter(param:TypedTypeParam);
	KExpr(expr:Expr);
	KGeneric;
	KGenericInstance(cls:TClass, params:TParams);
	KMacroType;
	KGenericBuild(fields:Vector<ClassField>);
	KAbstractImpl(abs:TAbstract);
	KModuleFields(module:ModuleDef);
}

typedef TInfos = {
	var mtPath:GlobalTypePath;
	var mtModule:ModuleDef;
	var mtPos:Pos;
	var mtNamePos:Pos;
	var mtPrivate:Bool;
	var mtDoc:Documentation;
	var mtMeta:Metadata;
	var mtParams:TypeParams;
	var mtUsing:Array<{var cls:TClass; var pos:Pos;}>;
	var mtRestore:Void->Void;
}

@:structInit class TClass {
	public var clPath:GlobalTypePath;
	public var clModule:ModuleDef;
	public var clPos:Pos;
	public var clNamePos:Pos;
	public var clPrivate:Bool;
	public var clDoc:Documentation;
	public var clMeta:Metadata;
	public var clParams:TypeParams;
	public var clUsing:Array<{var cls:TClass; var pos:Pos;}>;
	public var clRestore:Void->Void;
	/* do not insert any fields above */
	public var clType:T;
	public var clKind:TClassKind;
	public var clFlags:Int;
	public var clSuper:Null<ClassAndParams>;
	public var clImplements:Array<ClassAndParams>;
	public var clFields:TypeMap<TClassField>;
	public var clStatics:TypeMap<TClassField>;
	public var clOrderedStatics:Array<TClassField>;
	public var clOrderedFields:Array<TClassField>;
	public var clDynamic:Null<T>;
	public var clArrayAccess:Null<T>;
	public var clConstructor:Null<TClassField>;
	public var clInit:Null<TClassField>;
	public var clBuild:Void->BuildState;

	/*
		These are classes which directly extend or directly implement this class.
		Populated automatically in post-processing step (Filters.run)
	*/
	public var clDescendants:Array<TClass>;

	// port: no explicit constructor: 25 arguments exceed the HashLink JIT limit.
	public function clone():TClass return {
		clPath: clPath,
		clModule: clModule,
		clPos: clPos,
		clNamePos: clNamePos,
		clPrivate: clPrivate,
		clDoc: clDoc,
		clMeta: clMeta,
		clParams: clParams,
		clUsing: clUsing,
		clRestore: clRestore,
		clType: clType,
		clKind: clKind,
		clFlags: clFlags,
		clSuper: clSuper,
		clImplements: clImplements,
		clFields: clFields,
		clStatics: clStatics,
		clOrderedStatics: clOrderedStatics,
		clOrderedFields: clOrderedFields,
		clDynamic: clDynamic,
		clArrayAccess: clArrayAccess,
		clConstructor: clConstructor,
		clInit: clInit,
		clBuild: clBuild,
		clDescendants: clDescendants
	};
}

@:structInit class TEnumField {
	public var efName:String;
	public var efType:T;
	public var efPos:Pos;
	public var efNamePos:Pos;
	public var efDoc:Documentation;
	public var efIndex:Int;
	public var efParams:TypeParams;
	public var efMeta:Metadata;

	public inline function new(efName:String, efType:T, efPos:Pos, efNamePos:Pos, efDoc:Documentation, efIndex:Int, efParams:TypeParams,
			efMeta:Metadata) {
		this.efName = efName;
		this.efType = efType;
		this.efPos = efPos;
		this.efNamePos = efNamePos;
		this.efDoc = efDoc;
		this.efIndex = efIndex;
		this.efParams = efParams;
		this.efMeta = efMeta;
	}

	public inline function clone():TEnumField return new TEnumField(efName, efType, efPos, efNamePos, efDoc, efIndex, efParams, efMeta);
}

@:structInit class TEnum {
	public var ePath:GlobalTypePath;
	public var eModule:ModuleDef;
	public var ePos:Pos;
	public var eNamePos:Pos;
	public var ePrivate:Bool;
	public var eDoc:Documentation;
	public var eMeta:Metadata;
	public var eParams:TypeParams;
	public var eUsing:Array<{var cls:TClass; var pos:Pos;}>;
	public var eRestore:Void->Void;
	/* do not insert any fields above */
	public var eType:T;
	public var eFlags:Int;
	public var eConstrs:TypeMap<TEnumField>;
	public var eNames:Array<String>;

	public inline function new(ePath:GlobalTypePath, eModule:ModuleDef, ePos:Pos, eNamePos:Pos, ePrivate:Bool, eDoc:Documentation,
			eMeta:Metadata, eParams:TypeParams, eUsing:Array<{
			var cls:TClass;
			var pos:Pos;
		}>, eRestore:Void->Void, eType:T, eFlags:Int,
			eConstrs:TypeMap<TEnumField>, eNames:Array<String>) {
		this.ePath = ePath;
		this.eModule = eModule;
		this.ePos = ePos;
		this.eNamePos = eNamePos;
		this.ePrivate = ePrivate;
		this.eDoc = eDoc;
		this.eMeta = eMeta;
		this.eParams = eParams;
		this.eUsing = eUsing;
		this.eRestore = eRestore;
		this.eType = eType;
		this.eFlags = eFlags;
		this.eConstrs = eConstrs;
		this.eNames = eNames;
	}

	public inline function clone():TEnum return new TEnum(ePath, eModule, ePos, eNamePos, ePrivate, eDoc, eMeta, eParams, eUsing,
		eRestore, eType, eFlags, eConstrs, eNames);
}

@:structInit class TDef {
	public var tPath:GlobalTypePath;
	public var tModule:ModuleDef;
	public var tPos:Pos;
	public var tNamePos:Pos;
	public var tPrivate:Bool;
	public var tDoc:Documentation;
	public var tMeta:Metadata;
	public var tParams:TypeParams;
	public var tUsing:Array<{var cls:TClass; var pos:Pos;}>;
	public var tRestore:Void->Void;
	/* do not insert any fields above */
	public var tType:T;

	public inline function new(tPath:GlobalTypePath, tModule:ModuleDef, tPos:Pos, tNamePos:Pos, tPrivate:Bool, tDoc:Documentation,
			tMeta:Metadata, tParams:TypeParams, tUsing:Array<{
			var cls:TClass;
			var pos:Pos;
		}>, tRestore:Void->Void, tType:T) {
		this.tPath = tPath;
		this.tModule = tModule;
		this.tPos = tPos;
		this.tNamePos = tNamePos;
		this.tPrivate = tPrivate;
		this.tDoc = tDoc;
		this.tMeta = tMeta;
		this.tParams = tParams;
		this.tUsing = tUsing;
		this.tRestore = tRestore;
		this.tType = tType;
		}

	public inline function clone():TDef return new TDef(tPath, tModule, tPos, tNamePos, tPrivate, tDoc, tMeta, tParams, tUsing, tRestore,
		tType);
}

@:structInit class TAbstract {
	public var aPath:GlobalTypePath;
	public var aModule:ModuleDef;
	public var aPos:Pos;
	public var aNamePos:Pos;
	public var aPrivate:Bool;
	public var aDoc:Documentation;
	public var aMeta:Metadata;
	public var aParams:TypeParams;
	public var aUsing:Array<{var cls:TClass; var pos:Pos;}>;
	public var aRestore:Void->Void;
	/* do not insert any fields above */
	public var aOps:Array<{var op:Binop; var field:TClassField;}>;
	public var aUnops:Array<{var op:Unop; var flag:UnopFlag; var field:TClassField;}>;
	public var aImpl:Null<TClass>;
	public var aThis:T;
	public var aFrom:Array<T>;
	public var aFromField:Array<CastField>;
	public var aTo:Array<T>;
	public var aToField:Array<CastField>;
	public var aArray:Array<TClassField>;
	public var aRead:Null<TClassField>;
	public var aWrite:Null<TClassField>;
	public var aCall:Null<TClassField>;
	public var aConstructor:Null<TClassField>;
	public var aExtern:Bool;
	public var aEnum:Bool;

	// port: no explicit constructor: 25 arguments exceed the HashLink JIT limit.
	public function clone():TAbstract return {
		aPath: aPath,
		aModule: aModule,
		aPos: aPos,
		aNamePos: aNamePos,
		aPrivate: aPrivate,
		aDoc: aDoc,
		aMeta: aMeta,
		aParams: aParams,
		aUsing: aUsing,
		aRestore: aRestore,
		aOps: aOps,
		aUnops: aUnops,
		aImpl: aImpl,
		aThis: aThis,
		aFrom: aFrom,
		aFromField: aFromField,
		aTo: aTo,
		aToField: aToField,
		aArray: aArray,
		aRead: aRead,
		aWrite: aWrite,
		aCall: aCall,
		aConstructor: aConstructor,
		aExtern: aExtern,
		aEnum: aEnum
	};
}

enum ModuleType {
	TClassDecl(cls:TClass);
	TEnumDecl(en:TEnum);
	TTypeDecl(def:TDef);
	TAbstractDecl(abs:TAbstract);
}

@:structInit class ModuleDef {
	public var mId:Int;
	public var mPath:GlobalTypePath;
	public var mTypes:Array<ModuleType>;
	public var mStatics:Null<TClass>;
	public var mExtra:ModuleDefExtra;

	public inline function new(mId:Int, mPath:GlobalTypePath, mTypes:Array<ModuleType>, mStatics:Null<TClass>, mExtra:ModuleDefExtra) {
		this.mId = mId;
		this.mPath = mPath;
		this.mTypes = mTypes;
		this.mStatics = mStatics;
		this.mExtra = mExtra;
	}

	public inline function clone():ModuleDef return new ModuleDef(mId, mPath, mTypes, mStatics, mExtra);
}

@:structInit class ModuleDefDisplay {
	// port: mInlineCalls and mTypeHints in push order (`x :: l` as a push): read from the end
	public var mInlineCalls:Array<{var callPos:Pos; var definitionPos:Pos;}>; /* calls whatever is at pos1 from pos2 */
	public var mTypeHints:Array<{var hintPos:Pos; var typePos:Pos;}>;
	public var mImportPositions:Map<String, Bool>;

	public inline function new(mInlineCalls:Array<{var callPos:Pos; var definitionPos:Pos;}>,
			mTypeHints:Array<{var hintPos:Pos; var typePos:Pos;}>, mImportPositions:Map<String, Bool>) {
		this.mInlineCalls = mInlineCalls;
		this.mTypeHints = mTypeHints;
		this.mImportPositions = mImportPositions;
	}

	public inline function clone():ModuleDefDisplay return new ModuleDefDisplay(mInlineCalls, mTypeHints, mImportPositions);
}

enum ModuleDepOrigin {
	MDepFromTyping;
	MDepFromImport;
	MDepFromMacro;
	/* Compiler.include loads module with this special origin, which tells add_dependency not to add as a proper dependency. */
	MDepFromMacroInclude;
	/* Modules created via Compiler.defineType or Compiler.defineModule will be added as dependency to their "parent" module with this origin. */
	MDepFromMacroDefine;
}

@:structInit class ModuleDep {
	public var mdSign:String;
	public var mdKind:ModuleKind;
	public var mdPath:GlobalTypePath;
	public var mdOrigin:ModuleDepOrigin;

	public inline function new(mdSign:String, mdKind:ModuleKind, mdPath:GlobalTypePath, mdOrigin:ModuleDepOrigin) {
		this.mdSign = mdSign;
		this.mdKind = mdKind;
		this.mdPath = mdPath;
		this.mdOrigin = mdOrigin;
	}

	public inline function clone():ModuleDep return new ModuleDep(mdSign, mdKind, mdPath, mdOrigin);
}

@:structInit class ModuleDefExtra {
	public var mFile:core.Path.LazyUniqueKey;
	public var mSign:String;
	public var mDisplay:ModuleDefDisplay;
	public var mCheckPolicy:Array<ModuleCheckPolicy>;
	public var mTime:Float;
	public var mCacheState:ModuleCacheState;
	public var mAdded:Int;
	public var mChecked:Int;
	public var mProcessed:Int;
	public var mDeps:IntMap<ModuleDep>;
	public var mDisplayDeps:Null<IntMap<ModuleDep>>;
	public var mKind:ModuleKind;
	public var mCacheBoundObjects:Array<CacheBoundObject>;
	public var mFeatures:Map<String, Bool>;

	public inline function new(mFile:core.Path.LazyUniqueKey, mSign:String, mDisplay:ModuleDefDisplay,
			mCheckPolicy:Array<ModuleCheckPolicy>, mTime:Float, mCacheState:ModuleCacheState, mAdded:Int, mChecked:Int, mProcessed:Int,
			mDeps:IntMap<ModuleDep>, mDisplayDeps:Null<IntMap<ModuleDep>>, mKind:ModuleKind, mCacheBoundObjects:Array<CacheBoundObject>,
			mFeatures:Map<String, Bool>) {
		this.mFile = mFile;
		this.mSign = mSign;
		this.mDisplay = mDisplay;
		this.mCheckPolicy = mCheckPolicy;
		this.mTime = mTime;
		this.mCacheState = mCacheState;
		this.mAdded = mAdded;
		this.mChecked = mChecked;
		this.mProcessed = mProcessed;
		this.mDeps = mDeps;
		this.mDisplayDeps = mDisplayDeps;
		this.mKind = mKind;
		this.mCacheBoundObjects = mCacheBoundObjects;
		this.mFeatures = mFeatures;
	}

	public inline function clone():ModuleDefExtra return new ModuleDefExtra(mFile, mSign, mDisplay, mCheckPolicy, mTime, mCacheState,
		mAdded, mChecked, mProcessed, mDeps, mDisplayDeps, mKind, mCacheBoundObjects, mFeatures);
}

enum ClassFieldRefKind {
	CfrStatic;
	CfrMember;
	CfrConstructor;
	CfrInit;
}

@:structInit class ClassFieldRef {
	public var cfrSign:String;
	public var cfrPath:GlobalTypePath;
	public var cfrField:String;
	public var cfrKind:ClassFieldRefKind;
	public var cfrIsMacro:Bool;

	public inline function new(cfrSign:String, cfrPath:GlobalTypePath, cfrField:String, cfrKind:ClassFieldRefKind, cfrIsMacro:Bool) {
		this.cfrSign = cfrSign;
		this.cfrPath = cfrPath;
		this.cfrField = cfrField;
		this.cfrKind = cfrKind;
		this.cfrIsMacro = cfrIsMacro;
	}

	public inline function clone():ClassFieldRef return new ClassFieldRef(cfrSign, cfrPath, cfrField, cfrKind, cfrIsMacro);
}

enum ModuleKind {
	MCode;
	MMacro;
	MFake;
	MExtern;
	MImport;
}

enum BuildState {
	Built;
	Building(classes:Array<TClass>);
	BuildMacro(callbacks:Array<Void->Void>);
}

class TypeException extends haxe.Exception {
	public final type:T;

	public function new(type:T) {
		super("Type_exception");
		this.type = type;
	}
}

@:structInit class CoroTypes {
	public var tcoro:AtomicLazy<TSignature->T>;
	public var continuation:AtomicLazy<T>;
	public var suspensionResultClass:AtomicLazy<TClass>;
	public var tasyncIterator:AtomicLazy<T->T>;

	public inline function new(tcoro:AtomicLazy<TSignature->T>, continuation:AtomicLazy<T>, suspensionResultClass:AtomicLazy<TClass>,
			tasyncIterator:AtomicLazy<T->T>) {
		this.tcoro = tcoro;
		this.continuation = continuation;
		this.suspensionResultClass = suspensionResultClass;
		this.tasyncIterator = tasyncIterator;
	}

	public inline function clone():CoroTypes return new CoroTypes(tcoro, continuation, suspensionResultClass, tasyncIterator);
}

@:structInit class BasicTypes {
	public var tvoid:T;
	public var tany:T;
	public var tint:T;
	public var tfloat:T;
	public var tbool:T;
	public var tnull:T->T;
	public var tstring:T;
	public var tarray:T->T;
	public var texception:T;
	public var titerator:T->T;
	public var tunit:T;
	public var tcoro:CoroTypes;

	public inline function new(tvoid:T, tany:T, tint:T, tfloat:T, tbool:T, tnull:T->T, tstring:T, tarray:T->T, texception:T,
			titerator:T->T, tunit:T, tcoro:CoroTypes) {
		this.tvoid = tvoid;
		this.tany = tany;
		this.tint = tint;
		this.tfloat = tfloat;
		this.tbool = tbool;
		this.tnull = tnull;
		this.tstring = tstring;
		this.tarray = tarray;
		this.texception = texception;
		this.titerator = titerator;
		this.tunit = tunit;
		this.tcoro = tcoro;
	}

	public inline function clone():BasicTypes return new BasicTypes(tvoid, tany, tint, tfloat, tbool, tnull, tstring, tarray, texception,
		titerator, tunit, tcoro);
}

enum ClassFieldScope {
	CFSStatic;
	CFSMember;
	CFSConstructor;
}

enum FlagTClass {
	CExtern;
	CFinal;
	CInterface;
	CAbstract;
	CFunctionalInterface;
	CUsed; /* Marker for DCE */
	CExcluded; /* Marker for exclude macro, turned into CExtern during filters */
}

enum FlagTClassField {
	CfPublic;
	CfStatic;
	CfExtern; /* This is only set if the field itself is extern, not just the class. */
	CfFinal;
	CfModifiesThis; /* This is set for methods which reassign `this`. E.g. `this = value` */
	CfOverride;
	CfAbstract;
	CfOverload;
	CfImpl;
	CfEnum;
	CfGeneric;
	CfDefault; /* Interface field with default implementation (only valid on Java) */
	CfPostProcessed; /* Marker to indicate the field has been post-processed */
	CfUsed; /* Marker for DCE */
	CfMaybeUsed; /* Marker for DCE */
	CfNoLookup; /* Field cannot be accessed by-name. */
	CfAbstractConstructor;
}

enum FlagTEnum {
	EnExtern;
	EnExcluded; /* Marker for exclude macro, turned into EnExtern during filters */
}

enum FlagTVar {
	VCaptured;
	VFinal;
	VAnalyzed;
	VAssigned;
	VCaught;
	VStatic;
	VUsedByTyper; /* Set if the typer looked up this variable */
	VHxb; /* Flag used by hxb */
	VCoroCaptured;
	VCoroScope;
	VCoroRestrictedSuspension;
}

class TType {
	public static final flagTClassNames = [
		"CExtern",
		"CFinal",
		"CInterface",
		"CAbstract",
		"CFunctionalInterface",
		"CUsed",
		"CExcluded"
	];
	/* Order has to match declaration for printing*/
	public static final flagTClassFieldNames = [
		"CfPublic",
		"CfStatic",
		"CfExtern",
		"CfFinal",
		"CfModifiesThis",
		"CfOverride",
		"CfAbstract",
		"CfOverload",
		"CfImpl",
		"CfEnum",
		"CfGeneric",
		"CfDefault",
		"CfPostProcessed",
		"CfUsed",
		"CfMaybeUsed",
		"CfNoLookup",
		"CfAbstractConstructor"
	];
	public static final flagTVarNames = [
		"VCaptured",
		"VFinal",
		"VAnalyzed",
		"VAssigned",
		"VCaught",
		"VStatic",
		"VUsedByTyper",
		"VHxb",
		"VCoroCaptured",
		"VCoroScope",
		"VRestrictedSuspension"
	];
}
