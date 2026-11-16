package generators.cpp;

import core.Globals;
import core.TType;
import core.Ast.Binop;
import core.Ast.UnopFlag;
import core.Ast.WhileFlag;
import core.ds.NotFound;
import haxe.ds.StringMap;

// port: `Map.Make(struct type t = path let compare i1 i2 = String.compare (s_type_path i2) (s_type_path i1) end)`.
// Persistent: `add` copies. Keys that print alike are the same key, as with the
// upstream comparison; `bindings` follow the (reversed) key order.
class PathMap<V> {
	final entries:StringMap<{path:GlobalTypePath, value:V}>;

	public function new(?entries:StringMap<{path:GlobalTypePath, value:V}>) this.entries = entries == null ? new StringMap() : entries;

	public static function empty<V>():PathMap<V> return new PathMap();

	public function add(path:GlobalTypePath, value:V):PathMap<V> {
		var copy = entries.copy();
		copy.set(Globals.sTypePath(path), {path: path, value: value});
		return new PathMap(copy);
	}

	public function find(path:GlobalTypePath):V {
		var e = entries.get(Globals.sTypePath(path));
		if (e == null) throw NotFound.raise();
		return e.value;
	}

	public function findOpt(path:GlobalTypePath):Null<V> {
		var e = entries.get(Globals.sTypePath(path));
		return e == null ? null : e.value;
	}

	public function mem(path:GlobalTypePath):Bool return entries.exists(Globals.sTypePath(path));

	public function bindings():Array<{path:GlobalTypePath, value:V}> {
		var keys = [for (k in entries.keys()) k];
		keys.sort(function(a, b) return CppAstTools.stringCompare(b, a));
		return [for (k in keys) entries.get(k)];
	}
}

// port: Globals.IntMap (`compare i1 i2 = i2 - i1`): persistent (`add`/`remove` copy), `bindings` in decreasing key order.
class IntPMap<V> {
	final entries:haxe.ds.IntMap<V>;

	public function new(?entries:haxe.ds.IntMap<V>) this.entries = entries == null ? new haxe.ds.IntMap() : entries;

	public static function empty<V>():IntPMap<V> return new IntPMap();

	public static function ofList<V>(l:Array<{key:Int, value:V}>):IntPMap<V> {
		var m = new haxe.ds.IntMap();
		for (b in l) m.set(b.key, b.value);
		return new IntPMap(m);
	}

	public function add(key:Int, value:V):IntPMap<V> {
		var copy = entries.copy();
		copy.set(key, value);
		return new IntPMap(copy);
	}

	public function remove(key:Int):IntPMap<V> {
		var copy = entries.copy();
		copy.remove(key);
		return new IntPMap(copy);
	}

	public function findOpt(key:Int):Null<V> return entries.get(key);

	public function mem(key:Int):Bool return entries.exists(key);

	public function bindings():Array<{key:Int, value:V}> {
		var keys = [for (k in entries.keys()) k];
		keys.sort(function(a, b) return b - a);
		return [for (k in keys) {key: k, value: entries.get(k)}];
	}
}

@:structInit class ObjectIds {
	public var ids:PathMap<Int>;
	public var cache:haxe.ds.IntMap<Bool>;

	public static function empty():ObjectIds return {ids: PathMap.empty(), cache: new haxe.ds.IntMap()};

	public static function add(path:GlobalTypePath, id:Int, store:ObjectIds):ObjectIds {
		var cache = store.cache.copy();
		cache.set(id, true);
		return {ids: store.ids.add(path, id), cache: cache};
	}

	public static function findOpt(path:GlobalTypePath, store:ObjectIds):Null<Int> return store.ids.findOpt(path);

	public static function collision(id:Int, store:ObjectIds):Bool return store.cache.exists(id);
}

@:structInit class InterfaceSlots {
	public var hash:core.ds.PMap<Int>;
	public var next:Int;

	public static function empty():InterfaceSlots return {hash: core.ds.PMap.empty(), next: 2};

	public static function add(name:String, slots:InterfaceSlots):InterfaceSlots {
		return switch slots.hash.get(name) {
			case null:
				{hash: slots.hash.add(name, slots.next), next: slots.next + 1};
			case slot:
				slots;
		}
	}

	public static function findOpt(name:String, slots:InterfaceSlots):Null<Int> return slots.hash.get(name);
}

enum MarshalTypeState {
	Stack;
	Promoted;
	Reference;
}

enum NativeType {
	ValueClass(cls:TClass, params:Array<Tcpp>);
	ValueEnum(abs:TAbstract);
	Pointer(cls:TClass, params:Array<Tcpp>);
}

enum Tcpp {
	TCppDynamic;
	TCppUnchanged;
	TCppObject;
	TCppObjectPtr;
	TCppVoid;
	TCppNull;
	TCppEnum(enumDef:TEnum);
	TCppScalar(scalar:String);
	TCppString;
	TCppFastIterator(t:Tcpp);
	TCppPointer(ptrType:String, t:Tcpp);
	TCppRawPointer(constName:String, t:Tcpp);
	TCppFunction(args:Array<Tcpp>, ret:Tcpp, abi:String);
	TCppObjCBlock(args:Array<Tcpp>, ret:Tcpp);
	TCppRest(t:Tcpp);
	TCppReference(t:Tcpp);
	TCppStruct(t:Tcpp);
	TCppMarshalNativeType(nativeType:NativeType, state:MarshalTypeState);
	TCppMarshalManagedType(cls:TClass, params:Array<Tcpp>);
	TCppStar(t:Tcpp, isConst:Bool);
	TCppVoidStar;
	TCppVarArg;
	TCppAutoCast;
	TCppDynamicArray;
	TCppObjectArray(t:Tcpp);
	TCppScalarArray(t:Tcpp);
	TCppObjC(cls:TClass);
	TCppNativePointer(cls:TClass);
	TCppVariant(t:Null<Tcpp>);
	TCppCode(t:Tcpp);
	TCppInst(cls:TClass, params:Array<Tcpp>);
	TCppInterface(cls:TClass);
	TCppProtocol(cls:TClass);
	TCppClass;
	TCppGlobal;
	TCppCallable(args:Array<Tcpp>, ret:Tcpp);
}

@:structInit class TcppExpr {
	public var cppexpr:TcppExprExpr;
	public var cpptype:Tcpp;
	public var cpppos:Pos;

	public inline function new(cppexpr:TcppExprExpr, cpptype:Tcpp, cpppos:Pos) {
		this.cppexpr = cppexpr;
		this.cpptype = cpptype;
		this.cpppos = cpppos;
	}
}

@:structInit class TcppVar {
	public var tcppvType:Tcpp;
	public var tcppvVar:TVar;
	public var tcppvName:String;
	public var tcppvDebugName:String;

	public inline function new(tcppvType:Tcpp, tcppvVar:TVar, tcppvName:String, tcppvDebugName:String) {
		this.tcppvType = tcppvType;
		this.tcppvVar = tcppvVar;
		this.tcppvName = tcppvName;
		this.tcppvDebugName = tcppvDebugName;
	}
}

// port: `(tcppvar * texpr option)`.
typedef TcppArg = {v:TcppVar, o:Null<TExpr>};

@:structInit class TcppClosure {
	public var closeType:Tcpp;
	public var closeArgs:Array<TcppArg>;
	public var closeExpr:TcppExpr;
	public var closeId:Int;
	public var closeUndeclared:IntPMap<TcppVar>;
	public var closeThis:Null<TcppThis>;
}

enum TcppCrementOp {
	CppIncrement;
	CppDecrement;
}

enum TcppUnop {
	CppNeg;
	CppNegBits;
	CppNot;
}

enum TcppThis {
	ThisReal;
	ThisFake;
	ThisDynamic;
}

enum TcppVarLoc {
	VarLocal(v:TcppVar);
	VarClosure(v:TcppVar);
	VarThis(field:TClassField, t:Tcpp);
	VarInstance(obj:TcppExpr, field:TClassField, clazz:String, op:String);
	VarInterface(obj:TcppExpr, field:TClassField);
	VarStatic(cls:TClass, objc:Bool, field:TClassField);
	VarInternal(obj:TcppExpr, op:String, name:String);
}

enum TcppInst {
	InstPtr(t:Tcpp);
	InstObjC;
	InstStruct;
}

enum TcppFuncLoc {
	FuncThis(field:TClassField, t:Tcpp);
	FuncInstance(obj:TcppExpr, inst:TcppInst, field:TClassField, templateTypes:Array<Tcpp>);
	FuncStatic(cls:TClass, objc:Bool, field:TClassField, templateTypes:Array<Tcpp>);
	FuncTemplate(cls:TClass, field:TClassField, path:GlobalTypePath, native:Bool);
	FuncInterface(obj:TcppExpr, cls:TClass, field:TClassField);
	FuncEnumConstruct(enumDef:TEnum, field:TEnumField);
	FuncSuperConstruct(t:Tcpp);
	FuncSuper(thisKind:TcppThis, t:Tcpp, field:TClassField);
	FuncNew(t:Tcpp);
	FuncExpression(e:TcppExpr);
	FuncInternal(obj:TcppExpr, name:String, join:String);
	FuncExtern(name:String, isGlobal:Bool);
	FuncFromStaticFunction;
}

enum TcppArrayLoc {
	ArrayTyped(arrayObj:TcppExpr, index:TcppExpr, t:Tcpp);
	ArrayPointer(arrayObj:TcppExpr, index:TcppExpr);
	ArrayRawPointer(arrayObj:TcppExpr, index:TcppExpr);
	ArrayObject(arrayObj:TcppExpr, index:TcppExpr, t:Tcpp);
	ArrayVirtual(arrayObj:TcppExpr, index:TcppExpr);
	ArrayImplements(cls:TClass, arrayObj:TcppExpr, index:TcppExpr);
	ArrayDynamic(arrayObj:TcppExpr, index:TcppExpr);
}

enum TcppLValue {
	CppVarRef(loc:TcppVarLoc);
	CppArrayRef(loc:TcppArrayLoc);
	CppDynamicRef(e:TcppExpr, name:String);
	CppExternRef(name:String, isGlobal:Bool);
}

enum TcppExprExpr {
	CppInt(i:Int);
	CppFloat(f:String);
	CppString(s:String);
	CppBool(b:Bool);
	CppNull;
	CppNullAccess;
	CppNil;
	CppThis(t:TcppThis);
	CppSuper(t:TcppThis);
	CppCode(code:String, args:Array<TcppExpr>);
	CppCallable(closure:TcppClosure);
	CppVar(loc:TcppVarLoc);
	CppExtern(name:String, isGlobal:Bool);
	CppDynamicField(obj:TcppExpr, name:String);
	CppFunction(func:TcppFuncLoc, t:Tcpp);
	CppEnumIndex(obj:TcppExpr);
	CppEnumField(enumDef:TEnum, field:TEnumField);
	CppCall(func:TcppFuncLoc, args:Array<TcppExpr>);
	CppFunctionAddress(cls:TClass, field:TClassField);
	CppNewNative(e:TcppExpr);
	CppAddressOf(e:TcppExpr);
	CppDereference(e:TcppExpr);
	CppArray(loc:TcppArrayLoc);
	CppCrement(op:TcppCrementOp, flag:UnopFlag, lvalue:TcppLValue);
	CppSet(lvalue:TcppLValue, e:TcppExpr);
	CppModify(op:Binop, lvalue:TcppLValue, e:TcppExpr);
	CppBinop(op:Binop, e1:TcppExpr, e2:TcppExpr);
	CppCompare(name:String, e1:TcppExpr, e2:TcppExpr, op:Binop);
	CppNullCompare(name:String, e:TcppExpr);
	CppObjectDecl(fields:Array<{name:String, e:TcppExpr}>, isStruct:Bool);
	CppPosition(file:String, line:Int, className:String, meth:String);
	CppArrayDecl(el:Array<TcppExpr>);
	CppUnop(op:TcppUnop, e:TcppExpr);
	CppVarDecl(v:TcppVar, init:Null<TcppExpr>);
	CppBlock(el:Array<TcppExpr>, closures:Array<TcppClosure>, gcStack:Bool);
	CppFor(v:TcppVar, init:TcppExpr, loop:TcppExpr);
	CppIf(cond:TcppExpr, e1:TcppExpr, e2:Null<TcppExpr>);
	CppWhile(cond:TcppExpr, body:TcppExpr, flag:WhileFlag, loopId:Int);
	CppIntSwitch(cond:TcppExpr, cases:Array<{values:Array<Int>, e:TcppExpr}>, def:Null<TcppExpr>);
	CppSwitch(cond:TcppExpr, t:Tcpp, cases:Array<{values:Array<TcppExpr>, e:TcppExpr}>, def:Null<TcppExpr>, label:Int);
	CppTry(e:TcppExpr, catches:Array<{v:TcppVar, e:TcppExpr}>);
	CppBreak;
	CppContinue;
	CppClassOf(path:GlobalTypePath, native:Bool);
	CppGoto(label:Int);
	CppReturn(e:Null<TcppExpr>);
	CppThrow(e:TcppExpr);
	CppEnumParameter(obj:TcppExpr, field:TEnumField, index:Int);
	CppTCast(e:TcppExpr, t:Tcpp);
	CppCast(e:TcppExpr, t:Tcpp);
	CppCastStatic(e:TcppExpr, t:Tcpp);
	CppCastScalar(e:TcppExpr, scalar:String);
	CppCastVariant(e:TcppExpr);
	CppCastObjC(e:TcppExpr, cls:TClass);
	CppCastObjCBlock(e:TcppExpr, args:Array<Tcpp>, ret:Tcpp);
	CppCastProtocol(e:TcppExpr, cls:TClass);
	CppCastNative(e:TcppExpr);
}

enum TcppClassContainer {
	Current; /* If the current class holds GC variables */
	Parent; /* If one of the current classes parents holds GC variables */
}

enum TcppClassFlags {
	QuickAlloc;
	Scriptable;
	MemberGet;
	MemberSet;
	StaticGet;
	StaticSet;
	GetFields;
	Compare;
	Boot;
}

@:structInit class TcppClassFunction {
	public var tcfField:TClassField;
	public var tcfName:String;
	public var tcfFunc:TFunc;
	public var tcfArgs:Array<TcppArg>;
	public var tcfReturn:Tcpp;
	public var tcfIsVirtual:Bool;
	public var tcfIsReflective:Bool;
	public var tcfIsExternal:Bool;
	public var tcfIsScriptable:Bool;
	public var tcfIsOverriding:Bool;
}

@:structInit class TcppClassVariable {
	public var tcvField:TClassField;
	public var tcvName:String;
	public var tcvType:Tcpp;
	public var tcvDefault:Null<TExpr>;
	public var tcvHasGetter:Bool;
	public var tcvIsStackonly:Bool;
	public var tcvIsGcElement:Bool;
	public var tcvIsReflective:Bool;
}

@:structInit class TcppClass {
	public var tclClass:TClass;
	public var tclParams:TParams;
	public var tclName:String;
	public var tclId:Int;
	public var tclFlags:Int;
	public var tclDebugLevel:Int;
	public var tclSuper:Null<TcppClass>;
	public var tclContainer:Null<TcppClassContainer>;
	public var tclConstructor:Null<TcppClassFunction>;
	public var tclHaxeInterfaces:Array<TcppInterface>;
	public var tclNativeInterfaces:Array<TcppInterface>;
	public var tclStaticVariables:Array<TcppClassVariable>;
	public var tclStaticProperties:Array<TcppClassVariable>;
	public var tclStaticFunctions:Array<TcppClassFunction>;
	public var tclStaticDynamicFunctions:Array<TcppClassFunction>;
	public var tclVariables:Array<TcppClassVariable>;
	public var tclProperties:Array<TcppClassVariable>;
	public var tclFunctions:Array<TcppClassFunction>;
	public var tclDynamicFunctions:Array<TcppClassFunction>;
	public var tclMeta:Null<TExpr>;
	public var tclRtti:Null<TExpr>;
	public var tclInit:Null<TExpr>;
}

@:structInit class TcppInterfaceFunction {
	public var iffField:TClassField;
	public var iffName:String;
	public var iffArgs:Array<TcppTfunArg>;
	public var iffReturn:Tcpp;
	public var iffScriptSlot:Null<Int>;
}

@:structInit class TcppInterface {
	public var ifClass:TClass;
	public var ifName:String;
	public var ifHash:String;
	public var ifDebugLevel:Int;
	public var ifFunctions:Array<TcppInterfaceFunction>;
	public var ifVariables:Array<TClassField>;
	public var ifExtends:Null<TcppInterface>;
	public var ifMeta:Null<TExpr>;
	public var ifRtti:Null<TExpr>;
	public var ifScriptable:Bool;
}

@:structInit class TcppTfunArg {
	public var tfaName:String;
	public var tfaType:Tcpp;
	public var tfaOptional:Bool;
}

@:structInit class TcppEnumField {
	public var tefField:TEnumField;
	public var tefName:String;
	public var tefArgs:Null<Array<TcppTfunArg>>;
	public var tefHash:String;
}

@:structInit class TcppEnum {
	public var teEnum:TEnum;
	public var teId:Int;
	public var teConstructors:Array<TcppEnumField>;
}

enum TcppDecl {
	ManagedClass(cls:TcppClass);
	NativeClass(cls:TcppClass);
	ManagedInterface(iface:TcppInterface);
	NativeInterface(iface:TcppInterface);
	Enum(enumDef:TcppEnum);
}
