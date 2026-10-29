package hxmc.ir;

import core.TType;
import hxmc.ir.CInterop;
import hxmc.ir.Lower.LowerError;
import hxmc.ir.Ir;
import haxe.ds.Vector;
import core.ds.VectorTools.vector;

using core.TFunctions;

// Objective-C interop (docs/interop.md, "Objective-C"): an extern class
// declared @:hxmc.objc (or extending one) is an Objective-C class, its
// values `id`s (addresses, outside the heap). A call of one of its methods
// is a message: objc_msgSend(receiver, selector, arguments...) called in
// the C type of the method (each signature its own indirect C function,
// CInterop), a static method's receiver the class object.
//
// A Haxe class extending one (a peer class) is a Haxe class whose instances
// each have an Objective-C object too, of a class registered at run time
// (its first construction: FnLower.objcSuperInit) with the Haxe class's
// methods (their entries: imp), the id in the hidden field ID_FIELD, and
// the Haxe object found from the id through the runtime's peers
// (hxmc.rt.Gc: the index in the instance variable PEER_IVAR).
@:access(hxmc.ir.Lower)
class ObjC {
	public static inline var LIB = "/usr/lib/libobjc.A.dylib";
	public static inline var ID_FIELD = Lower.HIDDEN_FIELD + "objc";
	public static inline var PEER_IVAR = "hxmc_peer";
	// the hidden field holding the address of the class cell (CLASS_CELL) of
	// the instance's own class: set by the first constructor that runs (the
	// most derived class's), read by the initializer, which allocates that class
	public static inline var CELL_FIELD = Lower.HIDDEN_FIELD + "objccell";
	// the prefix of the functions registering the classes (Lower.classInfo)
	public static inline var REGISTER = "hxmc_objc_reg_";

	// an extern Objective-C class (or a class extending one, extern too)
	public static function isObjC(c:TClass):Bool {
		if (!c.hasClassFlag(CExtern)) return false;
		var k = c;
		while (k != null) {
			if (Lower.hasMeta(":hxmc.objc", k.clMeta)) return true;
			k = k.clSuper != null ? k.clSuper.cls : null;
		}
		return false;
	}

	// a Haxe class extending an Objective-C class: its superclass, else null
	public static function peerBase(c:TClass):Null<TClass> {
		if (c.hasClassFlag(CExtern)) return null;
		var k = c.clSuper != null ? c.clSuper.cls : null;
		while (k != null) {
			if (isObjC(k)) return k;
			k = k.clSuper != null ? k.clSuper.cls : null;
		}
		return null;
	}

	// an Objective-C object in C: an id (a peer class's instance passed as its id)
	public static function isObjCType(t:T):Bool
		return switch TFunctions.follow(t) {
			case TInst(c, _): isObjC(c) || peerBase(c) != null;
			case _: false;
		}

	// a type whose values are ids
	public static function isIdType(t:T):Bool
		return switch TFunctions.follow(t) {
			case TInst(c, _): isObjC(c);
			case _: false;
		}

	// the runtime's name of the class: @:hxmc.objc("Name"), @:native, or the
	// Haxe name (a peer class's: its path with underscores)
	public static function className(c:TClass):String {
		var n = Lower.metaArg(core.Meta.getOpt(Custom(":hxmc.objc"), c.clMeta));
		if (n != null) return n;
		n = Lower.metaArg(core.Meta.getOpt(Native, c.clMeta));
		if (n != null) return n;
		return c.hasClassFlag(CExtern) ? c.clPath.name : c.clPath.pack.concat([c.clPath.name]).join("_");
	}

	// a peer class's words in the program's data (DataGen.objcRefs): its class
	// cell (its class once registered, zero before; the address of its
	// registering function), the offset of the first such class's PEER_IVAR
	public static inline var CLASS_CELL = "hxmc$objccls$";
	public static inline var IVAR_CELL = "hxmc$objcivar$";

	// the type encoding of a C type, as @encode's (class_addMethod)
	public static function encoding(ct:CTy):String
		return switch ct {
			case CVoid: "v";
			case CBool: "B";
			case CI8: "c";
			case CU8: "C";
			case CI16: "s";
			case CU16: "S";
			case CI32: "i";
			case CI64: "q";
			case CF32: "f";
			case CF64: "d";
			case CPtr: "^v";
			case CStruct(c): "{" + c.clPath.name + "=" + [for (f in CInterop.layout(c).fields) encoding(f.ty)].join("") + "}";
			case COpaque(_) | CNone: "?";
		}

	// the library defining the class: @:hxmc.framework("Name") (a system
	// framework) or @:hxmc.lib (not inherited: a subclass is often another
	// library's); null: looked up by name at run time (a class made at run
	// time, or of a library already loaded)
	public static function library(c:TClass):Null<String> {
		var fw = Lower.metaArg(core.Meta.getOpt(Custom(":hxmc.framework"), c.clMeta));
		if (fw != null) return '/System/Library/Frameworks/$fw.framework/$fw';
		return Lower.metaArg(core.Meta.getOpt(Custom(":hxmc.lib"), c.clMeta));
	}

	// a class object's symbol (its library's), and the word in the program's
	// data that holds its address, bound by the loader (DataGen.objcRefs): a
	// classref, as clang's __objc_classrefs (an imported datum is no
	// function a stub can stand for)
	public static inline var CLASS_SYM = "OBJC_CLASS_$_";
	public static inline var CLASSREF = "hxmc$classref$";

	// the library of a member that a category of another library declares
	// (Foundation's -description on libobjc's NSObject): @:hxmc.framework or
	// @:hxmc.lib on the field, loaded whenever the member is sent
	// (CInterop.LOADS: the class's classref loads only its own)
	public static function memberLibrary(cf:TClassField):Null<String> {
		var fw = Lower.metaArg(core.Meta.getOpt(Custom(":hxmc.framework"), cf.cfMeta));
		if (fw != null) return '/System/Library/Frameworks/$fw.framework/$fw';
		return Lower.metaArg(core.Meta.getOpt(Custom(":hxmc.lib"), cf.cfMeta));
	}

	// a property's set accessor (`set_x` of a property `var x(get, set)` of c
	// or a superclass): Haxe's returns the value it sets, Objective-C's setter
	// nothing, so its message returns nothing and its call the argument, and a
	// Haxe override's entry (imps) nothing
	public static function isSetter(c:TClass, cf:TClassField):Bool {
		if (!StringTools.startsWith(cf.cfName, "set_")) return false;
		var name = cf.cfName.substr(4), k = c;
		while (k != null) {
			var f = k.clFields.get(name);
			if (f == null) f = k.clStatics.get(name);
			if (f != null)
				return switch f.cfKind {
					case Var(v): v.vWrite == AccCall;
					case _: false;
				}
			k = k.clSuper != null ? k.clSuper.cls : null;
		}
		return false;
	}

	// a selector's word (DataGen.objcRefs): its name in hexadecimal after SELREF
	public static inline var SELREF = "hxmc$selref$";

	public static function selRef(sel:String):String
		return SELREF + haxe.io.Bytes.ofString(sel).toHex();

	// the classref of c, or null (library: no library declared)
	public static function classRef(c:TClass):Null<String> {
		var lib = library(c);
		if (lib == null) return null;
		var name = className(c);
		CInterop.LIBS.set(CLASS_SYM + name, lib);
		CInterop.USER.set(CLASS_SYM + name, true);
		return CLASSREF + name;
	}

	// the selector of a method: @:selector("a:b:"), or the method's name
	// followed by its parameters' names after the first one, each with a
	// colon (`initWithFrame(frame)`: "initWithFrame:"; `setObject(o, forKey)`:
	// "setObject:forKey:"); a property's accessors, as Objective-C's are named:
	// `get_frame()` "frame", `set_frame(v)` "setFrame:"
	public static function selector(cf:TClassField, s:TSignature):String {
		var n = Lower.metaArg(core.Meta.getOpt(Custom(":selector"), cf.cfMeta));
		if (n != null) return n;
		n = Lower.metaArg(core.Meta.getOpt(Native, cf.cfMeta));
		var name = n != null ? n : cf.cfName;
		if (StringTools.startsWith(name, "get_") && s.args.length == 0) return name.substr(4);
		if (StringTools.startsWith(name, "set_") && s.args.length == 1 && name.length > 4)
			return "set" + name.charAt(4).toUpperCase() + name.substr(5) + ":";
		if (s.args.length == 0) return name;
		var b = new StringBuf();
		b.add(name);
		b.add(":");
		for (i in 1...s.args.length) {
			b.add(s.args[i].name);
			b.add(":");
		}
		return b.toString();
	}

	// a property's accessors: @:getter("isEnabled") and @:setter("setEnabled:")
	// (Haxe's own metadata, core.Meta's Getter and Setter), or the name and
	// "set" with it capitalized
	public static function getter(cf:TClassField):String {
		var n = Lower.metaArg(core.Meta.getOpt(Getter, cf.cfMeta));
		return n != null ? n : cf.cfName;
	}

	public static function setter(cf:TClassField):String {
		var n = Lower.metaArg(core.Meta.getOpt(Setter, cf.cfMeta));
		return n != null ? n : "set" + cf.cfName.charAt(0).toUpperCase() + cf.cfName.substr(1) + ":";
	}

	// declares the indirect C function a message of signature s is sent
	// through: (objc_msgSend's address, receiver, selector, arguments...),
	// named by its C types so that every message of the same types shares
	// it; called in a safe region (Cocoa calls back into Haxe from inside
	// many messages)
	public static function declare(cf:Null<TClassField>, types:Array<T>, result:Null<T>):String {
		var where = cf != null ? CInterop.posOf(cf.cfPos) : "";
		var name = cf != null ? cf.cfName : "init";
		var args = [CPtr, CPtr, CPtr];
		for (i in 0...types.length) {
			var ct = CInterop.ctype(types[i]);
			if (!CInterop.isScalar(ct) && !ct.match(CStruct(_)))
				throw new LowerError('Objective-C method $name: parameter ${i + 1} has no C type a message can pass', where);
			args.push(ct);
		}
		var ret = result == null ? CVoid : CInterop.ctype(result);
		if (ret != CVoid && !CInterop.isScalar(ret) && !ret.match(CStruct(_)))
			throw new LowerError('Objective-C method $name: the result has no C type a message can return', where);
		var key = CInterop.INDIRECT + "objc_msgSend(" + [for (a in args) CInterop.shape(a)].join(",") + ")" + CInterop.shape(ret);
		if (!CInterop.SIGS.exists(key)) {
			CInterop.SIGS.set(key, {args: args, ret: ret});
			CInterop.BLOCKING.set(key, true);
		}
		return key;
	}

	// libobjc's functions the lowering calls, declared once per program as an
	// extern without @:hxmc.fast would be (the program may declare them so too)
	public static function runtime(name:String, args:Array<CTy>, ret:CTy):String {
		if (!CInterop.SIGS.exists(name)) {
			CInterop.SIGS.set(name, {args: args, ret: ret});
			CInterop.BLOCKING.set(name, true);
		}
		return symbol(name);
	}

	// a symbol of libobjc (a function only its address is taken of)
	public static function symbol(name:String):String {
		CInterop.LIBS.set(name, LIB);
		CInterop.USER.set(name, true);
		return name;
	}

	// the methods of a peer class c (registered as `name`) that Objective-C
	// can call: its own instance methods whose types C has, each by the
	// selector and types of the Objective-C method it overrides, else by
	// its own (selector), and their entries (Lower.classInfo makes them): a C function
	// (self, _cmd, arguments...) that leaves the safe region the caller is in
	// (a message is sent in one), finds the Haxe object (the index in the
	// instance variable, rt_objc_peer_get), calls the method and enters the
	// region again
	public static function imps(l:Lower, c:TClass, name:String, root:String):Array<{sel:String, sym:String, types:String}> {
		var r = [];
		for (cf in c.clOrderedFields) {
			if (!cf.cfKind.match(Method(MethNormal | MethDynamic))) continue;
			var decl = cf, k = c.clSuper != null ? c.clSuper.cls : null;
			while (k != null) {
				var f = k.clFields.get(cf.cfName);
				if (f != null && isObjC(k)) {
					decl = f;
					break;
				}
				k = k.clSuper != null ? k.clSuper.cls : null;
			}
			var s = switch TFunctions.follow(decl.cfType) {
				case TFun(s): s;
				case _: continue;
			};
			var cts = [for (a in s.args) CInterop.ctype(a.type)];
			// (an override of a property's set_x: Objective-C's setter returns nothing)
			var setter = decl != cf && isSetter(c, cf);
			var ret = setter ? CVoid : CInterop.ctype(s.ret);
			function ok(ct:CTy)
				return CInterop.isScalar(ct) || ct.match(CStruct(_));
			if (!Lambda.foreach(cts, ok) || !(ret == CVoid || ok(ret))) {
				if (decl != cf) throw new LowerError('${cf.cfName} overrides an Objective-C method, which has types C has not', CInterop.posOf(cf.cfPos));
				continue;
			}
			var fi = l.method(c, cf);
			var w = new FuncInfo(fi.name + "__imp", fi.module);
			w.cSymbol = "hxmc_imp_" + fi.name;
			w.display = fi.display;
			w.pos = fi.pos;
			w.cAbi = {args: [CPtr, CPtr].concat(cts), ret: ret};
			var self = new Local(0, "self", TI64);
			w.args = [self, new Local(1, "_cmd", TI64)];
			// (a struct result: the method's sret, a slot of this frame; MirBuild.cEntry
			// returns it by the C ABI's rules)
			var n = fi.sret ? fi.args.length - 1 : fi.args.length;
			for (i in 1...n)
				w.args.push(new Local(i + 1, fi.args[i].name, fi.args[i].ty));
			w.ret = setter ? TVoid : fi.ret;
			var peer = new Local(w.args.length, "peer", TRef(RAny));
			w.locals.push(peer);
			var sym = (s:String) -> ECallHost("hxmc_unsafe_Mem_sym", vector(EStr(s)), TI64);
			var off = ECallHost("hxmc_unsafe_Mem_getI64", vector(sym(IVAR_CELL + root), EInt(0)), TI64);
			var index = ECallHost("hxmc_unsafe_Mem_getI32", vector(EBin(LAdd, ELocal(self), off), EInt(0)), TI32);
			var body:Array<Stmt> = [
				SExpr(ECallHost("rt_blocking_leave", vector(), TVoid)),
				SSet(peer, ECallHost("rt_objc_peer_get", vector(index), TRef(RAny)))
			];
			var xs = [ECast(fi.args[0].ty, ELocal(peer))].concat([for (i in 2...w.args.length) (ELocal(w.args[i]) : Ex)]);
			// the call, in a try: an exception leaving it would unwind through
			// Objective-C's frames, which skips their cleanup (rt_objc_uncaught
			// reports it and ends the program, as an uncaught one)
			var call:Array<Stmt> = [];
			var res:Null<Local> = null;
			if (fi.sret) {
				// (a struct result: the method's sret, a slot of this frame)
				res = new Local(w.args.length + 1, "r", fi.ret);
				w.locals.push(res);
				var size = switch fi.ret {
					case TStruct(_, size): size;
					case _: 8;
				};
				body.push(SSet(res, ECallHost("hxmc_unsafe_Mem_structSlot", vector(EInt(size), EInt(8)), TI64)));
				call.push(SExpr(ECall(fi, Vector.fromArrayCopy(xs.concat([ELocal(res)])))));
			} else if (w.ret == TVoid) {
				call.push(SExpr(ECall(fi, Vector.fromArrayCopy(xs))));
			} else {
				res = new Local(w.args.length + 1, "r", fi.ret);
				w.locals.push(res);
				call.push(SSet(res, ECall(fi, Vector.fromArrayCopy(xs))));
			}
			var exn = new Local(w.args.length + 2, "e", TRef(RAny));
			w.locals.push(exn);
			body.push(STry(Vector.fromArrayCopy(call), vector({
				test: null,
				l: exn,
				body: vector(SExpr(ECallHost("rt_objc_uncaught", vector(ELocal(exn)), TVoid)))
			})));
			w.hasTry = true;
			body.push(SExpr(ECallHost("rt_blocking_enter", vector(), TVoid)));
			body.push(SReturn(res == null ? null : ELocal(res)));
			w.body = Vector.fromArrayCopy(body);
			l.prog.funcs.push(w);
			r.push({
				sel: decl != cf ? selector(decl, s) : selector(cf, s),
				sym: w.cSymbol,
				types: encoding(ret) + "@:" + [for (ct in cts) encoding(ct)].join("")
			});
		}
		return r;
	}

	// a selector's method family, as ARC names them: the first word
	// (leading underscores skipped) when it is alloc, copy, init,
	// mutableCopy or new, followed by the end or a character that is no
	// lowercase letter (initWithFrame:, copy; not newline, initialize)
	public static function family(sel:String):Null<String> {
		var s = sel;
		while (StringTools.startsWith(s, "_"))
			s = s.substr(1);
		for (f in ["alloc", "copy", "init", "mutableCopy", "new"])
			if (StringTools.startsWith(s, f)) {
				var c = s.charCodeAt(f.length);
				if (c == null || c < "a".code || c > "z".code) return f;
			}
		return null;
	}

	// whose result comes retained (+1): alloc, copy, init, mutableCopy and
	// new (init consumes its receiver, alloc's result: the lowering keeps
	// alloc's for the init that follows, and autoreleases the others')
	public static function returnsRetained(sel:String):Bool
		return switch family(sel) {
			case "copy" | "init" | "mutableCopy" | "new": true;
			case _: false;
		}

	// an initializer: an instance method of the init family
	public static function isInit(cf:TClassField):Bool
		return cf.cfKind.match(Method(_)) && switch TFunctions.follow(cf.cfType) {
			case TFun(s): family(selector(cf, s)) == "init";
			case _: false;
		}
}
