package hxmc.ir;

import haxe.ds.Vector;
import core.ds.VectorTools.vector;

// The typed IR between the typed AST and hxmc's code generator (MirBuild):
// hxc's IR, copied with its lowering (Lower, FnLower) when hxmc separated
// from hxc (docs/hxmc.md, "Origin"). Statements are
// structured (no gotos); expressions are pure except as the right-hand side
// of SSet/SExpr, so evaluation order and GC points are explicit.

enum Ty {
	TI32;
	TBool; // an i32 at run time; kept apart so boxing and Std.string know it
	TF64;
	TI64; // haxe.Int64 (hxmc.I64): an int64_t, boxed in Dynamic
	TVoid;
	TRef(r:RefTy);
	// a @:hxmc.struct value (docs/plans/lowlevel.md, "Struct values"): the address
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
	public var declNoGc:Bool = false; // declared @:hxmc.noGc: Facts.findNoGc fails the build unless noGc
	public var pos:Null<core.Globals.Pos>; // the declaration (errors)
	public var display:Null<String>; // its Haxe name, pack.Class.field (errors)
	// declared @:hxmc.collects: it runs the collector (the entries of a
	// collector written in Haxe, whose code is otherwise no-GC): never noGc
	public var collects:Bool = false;
	public var cSymbol:Null<String>; // @:hxmc.export: the symbol (the runtime's C code calls it)
	// (Facts) of the runtime's exports: the families hxmc.ir.RuntimeSymbols
	// lists it for, which MirBuild.call checks; -1: not the runtime's
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
	EArrGetU(elem:Ty, a:Ex, i:Ex); // an Array-backed haxe.ds.Vector (WasmGC): no bounds check (out of range is unspecified)
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
	// (-debug: Lower.lines) the code of the statements that follow comes from
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
	public var roots:Array<FuncInfo> = []; // live whatever reaches them (Reach)
	// (Reach) the live functions and the selectors live code dispatches on; null: all
	public var live:Null<Map<FuncInfo, Bool>> = null;
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
			case TI32: "i";
			case TBool: "b";
			case TF64: "f";
			case TI64: "l";
			case TVoid: "v";
			case TRef(_): "p";
			case TStruct(_): "s";
		}

	public static function isRef(t:Ty):Bool
		return t.match(TRef(_));

	public static function isScalar(t:Ty):Bool
		return t == TI32 || t == TBool || t == TF64 || t == TI64;
}
