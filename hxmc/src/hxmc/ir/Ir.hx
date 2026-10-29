package hxmc.ir;

import haxe.ds.Vector;
import core.ds.VectorTools.vector;

// The typed IR between the typed AST and hxmc's code generator (MirBuild):
// hxc's IR, copied with its lowering (Lower, FnLower) when hxmc separated
// from hxc (docs/hxmc.md, "Pipeline"). Statements are
// structured (no gotos); expressions are pure except as the right-hand side
// of SSet/SExpr, so evaluation order and GC points are explicit.

enum Ty {
	TI32;
	TBool; // an i32 at run time; kept apart so boxing and Std.string know it
	// hxmc.Byte as the element of a NativeArray (RNativeArr's only): one
	// byte of storage, its values TI32s from 0 to 255; elsewhere a Byte is TI32
	TU8;
	TF64;
	TI64; // haxe.Int64 (hxmc.I64): an int64_t, boxed in Dynamic
	// an Objective-C object (ObjC): an i64 at run time, its id; kept apart so
	// that storage holds a reference to it (fields, statics, elements,
	// captures) and Dynamic boxes it in an object that does
	TId;
	TVoid;
	TRef(r:RefTy);
	// a @:hxmc.struct value (docs/interop.md, "Struct values"): the address
	// of its memory (an I64), which the lowering copies on assignment;
	// the class's dot path and its size in bytes
	TStruct(name:String, size:Int);
}

enum RefTy {
	RObj(c:ClassInfo); // class instance (interfaces use the root object type)
	REnum(e:Null<EnumInfo>); // enum value; null: any enum (EnumValue)
	RCtor(c:CtorInfo); // a specific enum constructor (after a tag test)
	RArr(elem:Ty); // the runtime array also records its element kind (Boxes.hx, arrays)
	RNativeArr(elem:Ty); // fixed-size storage; a Dynamic element (Dynamic, an erased type parameter): any kind, through the runtime (rt/NArray)
	RClos(s:SigInfo);
	RBox(t:Ty); // captured mutable local
	RNull(t:Ty); // Null<Int>, Null<Float>, Null<Bool>: a Dynamic box or null
	RStr;
	RAnon; // anonymous structure, any shape: fields found through the type's field table
	RAny; // Dynamic, type parameters, Any
	RType; // Class<T> / Enum<T>: a runtime type descriptor
	RNative(path:String); // instance of an extern class, implemented by the runtime
}

class ClassInfo {
	public var id:Int; // preorder number: subclasses are in [id, lastDescendant]
	public var lastDescendant:Int;
	public var name:String; // Haxe dot path
	public var ident:String; // the prefix of its symbols
	public var sup:Null<ClassInfo>;
	public var fields:Array<{name:String, ty:Ty}> = []; // including inherited (the class is the header's type index)
	// properties without storage that Dynamic access and reflection read as
	// fields (@:hxmc.lengthOf("f"): the length of the NativeArray field f;
	// Facts gives them a field entry of kind L), including inherited ones
	public var derived:Array<{name:String, of:String}> = [];
	public var locs:Vector<Int>; // per field: its slot, or for Int/Bool its 4-byte index (packed two per slot; Facts.layout)
	public var nslots:Int;
	public var methods:Map<String, FuncInfo> = new Map(); // own implementations
	public var ctor:Null<FuncInfo>;
	public var tindex:Int = -1;
	public var isInterface = false;
	public var ifaces:Array<ClassInfo> = []; // implemented interfaces, including inherited ones
	// statics reachable through the class value (Dynamic access, Reflect): set once
	// the class is used as a value, in the order Type.getClassFields lists them
	// (Lower.reflectStatics); Reach keeps those live code can reach (null: no
	// live code has the class value)
	public var statics:Null<Array<StaticEntry>> = null;
	// what Type.createInstance calls on a new instance of the class, with the
	// arguments: its constructor (a superclass's when it has none), or that
	// constructor's entry for dynamic calls (numbers and Bools with default
	// values nullable: Lower.defaultsEntry); fn null: no constructor at all
	// (the call throws, as Eval's fails). Set for every class once the program
	// can call Type.createInstance (Lower.makers); Reach keeps it where live
	// code can have the class value (null: none)
	public var maker:Null<{fn:Null<FuncInfo>}> = null;
	// a class extending an Objective-C one (ObjC): the name it is registered
	// as, and its methods Objective-C can call (ObjC.imps)
	public var objc:Null<{name:String, methods:Array<{sel:String, sym:String, types:String}>}> = null;
	// its own fields holding ids (ObjC: their stores retain, its death releases them)
	public var idFields:Array<String> = [];

	public function new(name, ident, sup) {
		this.name = name;
		this.ident = ident;
		this.sup = sup;
	}

	public function fieldIndex(n:String):Int {
		for (i in 0...fields.length)
			if (fields[i].name == n) return i;
		throw 'no field $n in $name';
	}

	public function findMethod(n:String):Null<FuncInfo> {
		var c = this;
		while (c != null) {
			var m = c.methods.get(n);
			if (m != null) return m;
			c = c.sup;
		}
		return null;
	}
}

// a static reached through its class value (ClassInfo.statics): a function
// (fn), as the closure calling it (clos), or a variable (its global)
typedef StaticEntry = {name:String, clos:Null<LambdaInfo>, fn:Null<FuncInfo>, global:Int};

class EnumInfo {
	public var name:String;
	public var ident:String;
	public var ctors:Vector<CtorInfo> = vector(); // by tag
	public var tindex:Int = -1; // the enum's own descriptor (Enum<T> values)
	// haxe.rtti.Meta's __meta__ through the enum's value, once the enum is used
	// as a value and has metadata (Lower.reflectEnum), as a class's statics
	public var statics:Null<Array<StaticEntry>> = null;

	public function new(name, ident) {
		this.name = name;
		this.ident = ident;
	}
}

class CtorInfo {
	public var en:EnumInfo;
	public var name:String;
	public var tag:Int;
	public var params:Vector<Ty>; // from slot 0: the tag is the header's type index (Gc.hx)
	public var paramNames:Vector<String> = vector();
	public var global:Int = -1; // singleton for constructors without arguments
	public var tindex:Int = -1;

	public function new(en, name, tag, params) {
		this.en = en;
		this.name = name;
		this.tag = tag;
		this.params = params;
	}
}

// An anonymous structure layout: the fields of an object literal, sorted by name.
class ShapeInfo {
	public var id:Int;
	public var fields:Vector<{name:String, ty:Ty}>; // slot 0 = dynamic overflow fields, then these
	public var tindex:Int = -1;
	public var locs:Vector<Int>; // as ClassInfo.locs
	public var nslots:Int;

	public function new(id, fields) {
		this.id = id;
		this.fields = fields;
	}

	public function slot(name:String):Int {
		for (i in 0...fields.length)
			if (fields[i].name == name) return i + 1;
		return -1;
	}
}

// A function signature by C representation: i (Int), b (Bool), f (Float),
// p (any reference), v (Void). Closures of the same representation are
// interchangeable; others need an adapter (FnLower.coerce).
class SigInfo {
	public var id:Int;
	public var args:Vector<Ty>;
	public var ret:Ty;
	public var key:String;

	public function new(id, args, ret, key) {
		this.id = id;
		this.args = args;
		this.ret = ret;
		this.key = key;
	}
}

// A closure environment type: the captured values after the code pointer.
class LambdaInfo {
	public var id:Int;
	public var sig:SigInfo;
	public var captures:Vector<Local>;
	public var fn:FuncInfo;
	public var tindex:Int = -1;

	public function new(id, sig, captures, fn) {
		this.id = id;
		this.sig = sig;
		this.captures = captures;
		this.fn = fn;
	}
}

class Local {
	public var id:Int;
	public var name:String;
	public var ty:Ty;

	public function new(id, name, ty) {
		this.id = id;
		this.name = name;
		this.ty = ty;
	}
}

class FuncInfo {
	public var name:String;
	public var args:Array<Local> = [];
	public var ret:Ty = TVoid;
	// it returns a struct (ret, TStruct): the last argument is the address
	// the caller wants it at, which it also returns
	public var sret = false;
	// entered from C with these C types (a @:hxmc.callback's wrapper taking
	// or returning structs by value, Lower.callback): MirBuild receives the
	// arguments and returns the result by the ABI's rules (CAbi); a struct
	// argument is then the address of its memory, as is the result
	public var cAbi:Null<hxmc.ir.CInterop.CSig>;
	public var locals:Array<Local> = [];
	public var body:Vector<Stmt> = vector();
	public var selfClass:Null<ClassInfo>; // instance method: args[0] is `this`, typed as the root object
	public var lambda:Null<LambdaInfo>; // closure body: args[0] is the closure
	public var dispatchSel:Int = -1;
	// an instance method with default values for numbers or Bools: its entry
	// in the method table (dynamic and structural calls, DataGen.types),
	// those arguments nullable and filled in when null (Lower.defaultsEntry)
	public var dfltEntry:Null<FuncInfo>;
	public var hasTry:Bool = false;
	public var noGc:Bool = false; // never reaches a GC point (Facts.findNoGc): calls to it are not GC points
	// it calls rt_blocking_enter (blocksHere), or a function that does
	// (blocks): another thread may collect while it runs (Facts.findNoGc)
	public var blocks:Bool = false;
	public var blocksHere:Bool = false;
	// (Facts: what a scan of its body found, made once: a program lowered in
	// steps, interp.MirMacros, makes its facts again at each step)
	public var gcScan:Null<{gc:Bool, here:Bool, addr:Bool, callees:Array<FuncInfo>, names:Array<String>}> = null;
	// the native code of the compiler lowering it runs it, and its body was
	// not typed (@:hxmc.hostCode, Lower.hostCode): no body here, never
	// compiled nor inlined; its gcScan says what that code does
	public var hostCode:Bool = false;
	public var rawChecked:Bool = false;
	public var coldMarked:Bool = false;
	// declared @:hxmc.unsafe, @:hxmc.kernel or @:hxmc.blocking: Facts.findNoGc
	// fails the build unless noGc
	public var declNoGc:Bool = false;
	public var declUnsafe:Bool = false; // declared @:hxmc.unsafe (errors name the attribute written)
	// declared @:hxmc.kernel or @:hxmc.blocking: its body touches no GC value
	// and calls only such functions (Facts.kernelCulprit)
	public var declKernel:Bool = false;
	// declared @:hxmc.blocking (GC-free): its calls run in a safe region
	// (FnLower.inRegion)
	public var declBlocking:Bool = false;
	// the constructor of a @:hxmc.struct class (Lower.structCtor): a kernel
	// may call it when its body is GC-free (Facts.kernelCulprit)
	public var structCtor:Bool = false;
	// @:hxmc.withStacks: live only where the program reads stacks (Reach: its calls are dropped otherwise)
	public var withStacks:Bool = false;
	public var pos:Null<core.Globals.Pos>; // the declaration (errors)
	public var display:Null<String>; // its Haxe name, pack.Class.field (errors)
	// declared @:hxmc.collects: it runs the collector (the entries of a
	// collector written in Haxe, whose code is otherwise no-GC): never noGc
	public var collects:Bool = false;
	public var cSymbol:Null<String>; // @:hxmc.export: the symbol (the runtime's C code calls it)
	// (Facts) of the runtime's exports: the families hxmc.ir.RuntimeSymbols
	// lists it for, which MirWriter.call checks; -1: not the runtime's
	public var rtFamilies:Int = -1;
	// the Haxe module the function comes from (dot path): hxmc compiles the
	// functions of a module into one object
	public var module:String;
	public var nlambdas = 0; // closures created in this function (their names: <name>__lambda<k>)

	public function new(name, module) {
		this.name = name;
		this.module = module;
	}
}

enum Ex {
	EInt(v:Int);
	EF64(v:Float);
	EStr(s:String); // a literal, statically allocated
	ENull(t:Ty);
	ELocal(l:Local);
	EGlobal(g:Int, t:Ty);
	EBin(op:BinOp, a:Ex, b:Ex);
	ENot(a:Ex);
	EConv(op:ConvOp, a:Ex);
	EBox(t:Ty, a:Ex); // scalar -> Dynamic box (cached for small ints)
	EUnbox(t:Ty, a:Ex); // Dynamic or Null<T> -> scalar (null gives 0)
	EField(c:ClassInfo, idx:Int, obj:Ex);
	// the address of a struct field's memory in an object (a raw heap
	// address: valid until the next GC point, Facts.checkRawAddresses)
	EFieldAddr(c:ClassInfo, idx:Int, obj:Ex);
	// structural field read, converted to t; hint: the layout of an object
	// literal of the static type (read directly when the object has it)
	EAnonGet(name:String, t:Ty, obj:Ex, hint:Null<ShapeInfo>);
	ECast(t:Ty, e:Ex); // unchecked
	EInstOf(c:ClassInfo, e:Ex);
	EEnumTag(e:Ex, en:Null<EnumInfo>); // en: the value's enum when known
	EEnumParam(c:CtorInfo, idx:Int, e:Ex);
	EArrLen(a:Ex);
	EArrGet(elem:Ty, a:Ex, i:Ex);
	EArrGetU(elem:Ty, a:Ex, i:Ex); // an Array-backed haxe.ds.Vector: no bounds check (out of range is unspecified)
	EBoxGet(t:Ty, b:Ex);
	ECapture(l:LambdaInfo, idx:Int, clos:Ex);
	EType(t:TypeRef); // runtime type descriptor (Class<T>, Enum<T> values)
	// impure: only as the value of SSet / SExpr
	ECall(f:FuncInfo, args:Vector<Ex>);
	ECallDispatch(sel:Int, sig:SigInfo, args:Vector<Ex>); // virtual and interface calls
	ECallClos(s:SigInfo, clos:Ex, args:Vector<Ex>);
	ECallAnon(name:String, s:SigInfo, obj:Ex, args:Vector<Ex>); // obj.name(args) through a structural type: a method or a closure field
	ECallHost(name:String, args:Vector<Ex>, ret:Ty); // runtime function (hxmc.rt)
	ENewObj(c:ClassInfo); // zeroed instance; the constructor is called separately
	ENewEnum(c:CtorInfo, args:Vector<Ex>);
	ENewArr(elem:Ty, values:Vector<Ex>);
	ENewClos(l:LambdaInfo, captures:Vector<Ex>);
	ENewBox(t:Ty, v:Ex);
	ENewAnon(s:ShapeInfo, values:Vector<Ex>);
}

enum TypeRef {
	TRClass(c:ClassInfo);
	TREnum(e:EnumInfo);
	TRBuiltin(name:String); // String, Int, Float, Bool, Array, Dynamic, ...
}

enum ConvOp {
	I2F; // Int -> Float
	F2I; // Float -> Int, truncating (Std.int)
	FNeg;
	I2L; // Int -> Int64
	L2I; // Int64 -> Int, the low 32 bits
	L2F;
	F2L; // truncating
	LNeg;
}

enum BinOp {
	Add;
	Sub;
	Mul;
	Mod;
	And;
	Or;
	Xor;
	Shl;
	Shr;
	UShr;
	Eq;
	Ne;
	Lt;
	Le;
	Gt;
	Ge;
	RefEq;
	RefNe;
	FAdd;
	FSub;
	FMul;
	FDiv;
	FMod;
	FEq;
	FNe;
	FLt;
	FLe;
	FGt;
	FGe;
	// Int64 (wrapping; shift counts are Int)
	LAdd;
	LSub;
	LMul;
	LDiv;
	LMod;
	LAnd;
	LOr;
	LXor;
	LShl;
	LShr;
	LUShr;
	LEq;
	LNe;
	LLt;
	LLe;
	LGt;
	LGe;
	// Std.int(a / b) of Ints, truncating: b == 0 gives 0, b == -1 gives -a
	// (wrapping), as the Float quotient converted does (FnLower.intrinsicStatic:
	// b a constant)
	Div;
}

enum Stmt {
	SSet(l:Local, e:Ex);
	SExpr(e:Ex);
	SSetField(c:ClassInfo, idx:Int, obj:Ex, v:Ex);
	SAnonSet(name:String, t:Ty, obj:Ex, v:Ex);
	SArrSet(elem:Ty, a:Local, i:Ex, v:Ex);
	SArrPush(elem:Ty, a:Local, v:Ex);
	SBoxSet(t:Ty, b:Ex, v:Ex);
	SSetGlobal(g:Int, v:Ex);
	SIf(c:Ex, a:Vector<Stmt>, b:Vector<Stmt>);
	SLoop(body:Vector<Stmt>); // infinite; left with SBreak
	SBreak;
	SContinue;
	SSwitch(e:Ex, cases:Vector<IrCase>, def:Vector<Stmt>);
	SReturn(e:Null<Ex>);
	SThrow(e:Ex);
	STry(body:Vector<Stmt>, catches:Vector<IrCatch>);
	// (Facts.markCold) a statement whose only GC point is the slow path of an
	// allocation or array store: the references live across it are stored in
	// the shadow stack only on that path (hxmc.Roots)
	SCold(id:Int, s:Stmt);
	// (Lower.lines) the code of the statements that follow comes from
	// this line of the source (the typed AST's position); nothing else: every
	// pass steps over it, so the code is the same as without it
	SPos(file:String, line:Int);
}

// a case of SSwitch: its values and its body
typedef IrCase = {values:Vector<Int>, body:Vector<Stmt>};

// a catch of STry: its test of the exception (null: any), the local it is
// bound to, its body
typedef IrCatch = {test:Null<Ex->Ex>, l:Local, body:Vector<Stmt>};

class Program {
	public var classes:Array<ClassInfo> = [];
	public var interfaces:Array<ClassInfo> = [];
	public var enums:Array<EnumInfo> = [];
	public var shapes:Array<ShapeInfo> = [];
	public var funcs:Array<FuncInfo> = [];
	public var sigs:Array<SigInfo> = [];
	public var lambdas:Array<LambdaInfo> = [];
	public var selectors:Array<{name:String, sig:SigInfo}> = [];
	// (tls: a @:hxmc.threadLocal static, its symbol: one per thread, outside rt_globals)
	// (bss: a @:hxmc.bss static, its block's size and symbol: the value is the block's address)
	// (exp: a scalar static's symbol, @:hxmc.export: data that generated code and the runtime read by name)
	public var globals:Array<{ty:Ty, init:Null<CtorInfo>, name:String, ?tls:String, ?bss:Int, ?sym:String, ?exp:String}> = [];
	public var inits:Array<FuncInfo> = []; // static initializers, run before main
	public var main:FuncInfo;
	// haxe.EntryPoint.run, run after main when the program keeps it (the event
	// loop: Finalization.maybeAddEntrypoint puts it in com.main.mainExpr, which
	// hxmc does not lower)
	public var entryRun:Null<FuncInfo> = null;
	public var roots:Array<FuncInfo> = []; // live whatever reaches them (Reach)
	// (Reach) the live functions and the selectors live code dispatches on; null: all
	public var live:Null<Map<FuncInfo, Bool>> = null;
	// (Reach) whether the program reads stacks (haxe.NativeStackTrace.toHaxe live, or -D hxmc.stacks): the table of its functions and lines (hxmc.StackTable)
	public var stacks = false;
	public var liveSelectors:Null<Vector<Bool>> = null;

	public function new() {}

	public inline function isLive(f:FuncInfo):Bool
		return live == null || live.exists(f);

	var sigKeys = new Map<String, SigInfo>();

	public function sig(args:Array<Ty>, ret:Ty):SigInfo {
		var b = new StringBuf();
		for (a in args)
			b.add(Ir.repr(a));
		b.add("_");
		b.add(Ir.repr(ret));
		var key = b.toString();
		var s = sigKeys.get(key);
		if (s != null) return s;
		var norm = (t:Ty) -> Ir.isRef(t) ? TRef(RAny) : t;
		var nargs = new Vector<Ty>(args.length);
		for (k in 0...args.length)
			nargs[k] = norm(args[k]);
		s = new SigInfo(sigs.length, nargs, norm(ret), key);
		sigs.push(s);
		sigKeys.set(key, s);
		return s;
	}

	var shapeKeys = new Map<String, ShapeInfo>();

	public function shape(fields:Array<{name:String, ty:Ty}>):ShapeInfo {
		// (by name: sorted when they are not already)
		var sorted = true;
		for (i in 1...fields.length)
			if (!(fields[i - 1].name < fields[i].name)) {
				sorted = false;
				break;
			}
		var fs = fields;
		if (!sorted) {
			fs = fields.copy();
			fs.sort((a, b) -> a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
		}
		var b = new StringBuf();
		for (i in 0...fs.length) {
			if (i > 0) b.add(",");
			b.add(fs[i].name);
			b.add(":");
			b.add(Ir.repr(fs[i].ty));
		}
		var key = b.toString();
		var s = shapeKeys.get(key);
		if (s != null) return s;
		s = new ShapeInfo(shapes.length, Vector.fromArrayCopy(fs));
		shapes.push(s);
		shapeKeys.set(key, s);
		return s;
	}
}

class Ir {
	public static function repr(t:Ty):String
		return switch t {
			case TI32 | TU8: "i";
			case TBool: "b";
			case TF64: "f";
			case TI64: "l";
			case TId: "l"; // (an i64: the same signatures and kinds)
			case TVoid: "v";
			case TRef(_): "p";
			case TStruct(_): "s";
		}

	public static function isRef(t:Ty):Bool
		return t.match(TRef(_));

	public static function isScalar(t:Ty):Bool
		return t == TI32 || t == TBool || t == TF64 || t == TI64 || t == TId;

	// the type of an expression's value (what MirBuild gives the Mir value
	// it makes: MIns.vty)
	public static function typeOf(e:Ex):Ty
		return switch e {
			case EInt(_): TI32;
			case EF64(_): TF64;
			case EStr(_): TRef(RStr);
			case ENull(t) | EGlobal(_, t) | EUnbox(t, _) | EAnonGet(_, t, _, _) | ECast(t, _) | EBoxGet(t, _) | ECallHost(_, _, t): t;
			case ELocal(l): l.ty;
			case EBin(op, _, _):
				switch op {
					case Add | Sub | Mul | Mod | Div | And | Or | Xor | Shl | Shr | UShr: TI32;
					case FAdd | FSub | FMul | FDiv | FMod: TF64;
					case LAdd | LSub | LMul | LDiv | LMod | LAnd | LOr | LXor | LShl | LShr | LUShr: TI64;
					case _: TBool;
				}
			case ENot(_) | EInstOf(_): TBool;
			case EConv(op, _):
				switch op {
					case I2F | FNeg | L2F: TF64;
					case F2I | L2I: TI32;
					case I2L | F2L | LNeg: TI64;
				}
			case EBox(_): TRef(RAny);
			case EField(c, idx, _) | EFieldAddr(c, idx, _): c.fields[idx].ty;
			case EEnumTag(_): TI32;
			case EEnumParam(c, idx, _): c.params[idx];
			case EArrLen(_): TI32;
			case EArrGet(elem, _, _) | EArrGetU(elem, _, _): elem;
			case ECapture(l, idx, _): l.captures[idx].ty;
			case EType(_): TRef(RType);
			case ECall(g, _): g.ret;
			case ECallDispatch(_, s, _) | ECallClos(s, _, _) | ECallAnon(_, s, _, _): s.ret;
			case ENewObj(c): TRef(RObj(c));
			case ENewEnum(c, _): TRef(RCtor(c));
			case ENewArr(elem, _): TRef(RArr(elem));
			case ENewClos(l, _): TRef(RClos(l.sig));
			case ENewBox(t, _): TRef(RBox(t));
			case ENewAnon(_): TRef(RAnon);
		}
}
