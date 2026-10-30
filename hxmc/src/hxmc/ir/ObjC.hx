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
//
// What a body needs of the link beyond its own code (a message's C function,
// libobjc's functions, a class's library, a category's) it declares through
// LowerQueries.objcDeclare (a Decl), which the compilation server replays
// when it reuses the body.
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

	// an object of C without an Objective-C class (Core Foundation's types,
	// CGColorRef: Objective-C objects at run time, of the class __NSCFType): an
	// extern class implementing hxmc.objc.Id with @:hxmc.objc nowhere in its
	// chain. Its values are ids; it has no class object, so no messages to
	// it, no type tests and no Haxe subclasses (Lower.classInfo)
	public static function isCF(c:TClass):Bool {
		if (!c.hasClassFlag(CExtern) || c.hasClassFlag(CInterface) || isObjC(c)) return false;
		function extendsId(i:TClass):Bool
			return isId(i) || Lambda.exists(i.clImplements, j -> extendsId(j.cls));
		var k = c;
		while (k != null) {
			if (Lambda.exists(k.clImplements, i -> extendsId(i.cls))) return true;
			k = k.clSuper != null ? k.clSuper.cls : null;
		}
		return false;
	}

	// a type parameter bound to Objective-C objects (`ObjectType:NSObject`, a
	// lightweight generic's): its values are ids, as the bound's
	public static function isObjCParam(c:TClass):Bool
		return switch c.clKind {
			case KTypeParameter(ttp):
				core.ds.ArrayTools.exists(TFunctions.getConstraints(ttp), t -> switch TFunctions.follow(t) {
					case TInst(k, _): isObjC(k) || isCF(k) || isObjCParam(k);
					case _: false;
				});
			case _: false;
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

	// a protocol: an extern interface declared @:hxmc.objc (its optional
	// methods @:optional: a class implementing it may leave them out, as a
	// Java interface's default ones, TypeloadFields)
	public static function isProtocol(c:TClass):Bool
		return c.hasClassFlag(CInterface) && isObjC(c) && !isId(c);

	// hxmc.objc.Id, any Objective-C object: no protocol of the runtime's
	public static function isId(c:TClass):Bool
		return c.clPath.name == "Id" && c.clPath.pack.join(".") == "hxmc.objc";

	// the protocols c conforms to by its own declaration: those it implements
	// and those they extend (its superclasses' not included)
	public static function protocols(c:TClass):Array<TClass> {
		var r = [];
		function add(i:TClass) {
			if (!isProtocol(i) || r.contains(i)) return;
			r.push(i);
			for (j in i.clImplements)
				add(j.cls);
		}
		for (i in c.clImplements)
			add(i.cls);
		return r;
	}

	// the declaration of the class method a peer class's static cf implements
	// (Objective-C's `+`): one of an Objective-C superclass (+cellClass,
	// +automaticallyNotifiesObserversForKey:), else of a protocol the class or
	// a superclass conforms to (a static of its extern interface:
	// +supportsSecureCoding, +readableTypesForPasteboard:), else the one a
	// Haxe superclass's static of the name implements; null: a static of
	// Haxe's only, which Objective-C does not see
	public static function classDeclOf(c:TClass, cf:TClassField):Null<TClassField> {
		var k = c.clSuper != null ? c.clSuper.cls : null;
		while (k != null) {
			var f = k.clStatics.get(cf.cfName);
			if (f != null) return isObjC(k) ? f : classDeclOf(k, f);
			k = k.clSuper != null ? k.clSuper.cls : null;
		}
		k = c;
		while (k != null) {
			for (p in protocols(k)) {
				var f = p.clStatics.get(cf.cfName);
				if (f != null) return f;
			}
			k = k.clSuper != null ? k.clSuper.cls : null;
		}
		return null;
	}

	// the declaration of the method a peer class's method cf implements: the
	// Objective-C method of a superclass it overrides, else that of a
	// protocol the class (or a superclass) conforms to, else null
	public static function declOf(c:TClass, cf:TClassField):Null<TClassField> {
		var k = c.clSuper != null ? c.clSuper.cls : null;
		while (k != null) {
			var f = k.clFields.get(cf.cfName);
			if (f != null && isObjC(k)) return f;
			k = k.clSuper != null ? k.clSuper.cls : null;
		}
		k = c;
		while (k != null) {
			for (p in protocols(k)) {
				var f = p.clFields.get(cf.cfName);
				if (f != null) return f;
			}
			k = k.clSuper != null ? k.clSuper.cls : null;
		}
		return null;
	}

	// a protocol's word in the program's data (DataGen.objcRefs): its Protocol
	// object once looked up (FnLower.objcProtocol), zero before
	public static inline var PROTOREF = "hxmc$protoref$";

	// an Objective-C object in C: an id (a peer class's instance passed as its id)
	public static function isObjCType(t:T):Bool
		return switch TFunctions.follow(t) {
			case TInst(c, _): isObjC(c) || isCF(c) || isObjCParam(c) || peerBase(c) != null;
			case _: false;
		}

	// a type whose values are ids (a block too: hxmc.objc.Block<F>)
	public static function isIdType(t:T):Bool
		return switch TFunctions.follow(t) {
			case TInst(c, _): isObjC(c) || isCF(c) || isObjCParam(c);
			case _: blockOfType(t) != null;
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
	public static function classRef(l:LowerQueries, c:TClass):Null<String> {
		var lib = library(c);
		if (lib == null) return null;
		var name = className(c);
		l.objcDeclare(Symbol(CLASS_SYM + name, lib));
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
	public static function declare(l:LowerQueries, cf:Null<TClassField>, types:Array<T>, result:Null<T>):String {
		var where = cf != null ? CInterop.posOf(cf.cfPos) : "";
		var name = cf != null ? cf.cfName : "init";
		var args = [CPtr, CPtr, CPtr];
		for (i in 0...types.length) {
			var ct = ctype(types[i]);
			if (!CInterop.isScalar(ct) && !ct.match(CStruct(_)))
				throw new LowerError('Objective-C method $name: parameter ${i + 1} has no C type a message can pass', where);
			args.push(ct);
		}
		var ret = result == null ? CVoid : ctype(result);
		if (ret != CVoid && !CInterop.isScalar(ret) && !ret.match(CStruct(_)))
			throw new LowerError('Objective-C method $name: the result has no C type a message can return', where);
		return declareC(l, args.slice(3), ret);
	}

	// the same of a message of C types (args after the receiver and selector)
	public static function declareC(l:LowerQueries, args:Array<CTy>, ret:CTy):String {
		var cargs = [CPtr, CPtr, CPtr].concat(args);
		var key = CInterop.INDIRECT + "objc_msgSend(" + [for (a in cargs) CInterop.shape(a)].join(",") + ")" + CInterop.shape(ret);
		l.objcDeclare(Func(key, {args: cargs, ret: ret}));
		return key;
	}

	// libobjc's functions the lowering calls, declared once per program as an
	// extern without @:hxmc.fast would be (the program may declare them so too)
	public static function runtime(l:LowerQueries, name:String, args:Array<CTy>, ret:CTy):String {
		l.objcDeclare(Func(name, {args: args, ret: ret}));
		return symbol(l, name);
	}

	// a symbol of libobjc (a function only its address is taken of)
	public static function symbol(l:LowerQueries, name:String):String {
		l.objcDeclare(Symbol(name, LIB));
		return name;
	}

	// d, declared for this program (Lower.objcDeclare)
	public static function define(d:Decl)
		switch d {
			case Func(sym, sig):
				if (!CInterop.SIGS.exists(sym)) {
					CInterop.SIGS.set(sym, sig);
					CInterop.BLOCKING.set(sym, true);
				}
			case Symbol(sym, lib):
				CInterop.LIBS.set(sym, lib);
				CInterop.USER.set(sym, true);
			case Load(lib):
				CInterop.LOADS.set(lib, true);
		}

	// the methods of a peer class c (registered as `name`) that Objective-C
	// can call: its own instance methods whose types C has, each by the
	// selector and types of the Objective-C method it overrides, else by
	// its own (selector), and their entries (Lower.classInfo makes them): a C function
	// (self, _cmd, arguments...; entry: on any thread, out of the safe region
	// the caller is in) whose work finds the Haxe object (the index in the
	// instance variable, rt_objc_peer_get) and calls the method. `statics`:
	// its class methods instead (on its metaclass), the statics that
	// implement a declared one (classDeclOf), their entries calling them
	public static function imps(l:Lower, c:TClass, name:String, root:String, statics = false):Array<{sel:String, sym:String, types:String}> {
		var r = [];
		// (the receiver: the method's first argument, a static has none)
		var first = statics ? 0 : 1;
		for (cf in (statics ? c.clOrderedStatics : c.clOrderedFields)) {
			if (!cf.cfKind.match(Method(MethNormal | MethDynamic))) continue;
			// (a protocol's optional method the class leaves out: none, TypeloadCheck's
			// stand-in, extern and without a body)
			if (cf.hasClassFieldFlag(CfExtern)) continue;
			var decl = statics ? classDeclOf(c, cf) : declOf(c, cf);
			if (decl == null && statics) continue;
			if (decl == null) decl = cf;
			else if (decl != cf && core.Meta.has(Custom(":selector"), cf.cfMeta)) {
				var own = Lower.metaArg(core.Meta.getOpt(Custom(":selector"), cf.cfMeta)), theirs = switch TFunctions.follow(decl.cfType) {
					case TFun(ds): selector(decl, ds);
					case _: null;
				};
				if (own != theirs)
					throw new LowerError('${cf.cfName} implements the Objective-C method $theirs, but its @:selector says $own', CInterop.posOf(cf.cfPos));
			}
			var s = switch TFunctions.follow(decl.cfType) {
				case TFun(s): s;
				case _: continue;
			};
			var cts = [for (a in s.args) ctype(a.type)];
			// (an override of a property's set_x: Objective-C's setter returns nothing)
			var setter = decl != cf && isSetter(c, cf);
			var ret = setter ? CVoid : ctype(s.ret);
			function ok(ct:CTy)
				return CInterop.isScalar(ct) || ct.match(CStruct(_));
			if (!Lambda.foreach(cts, ok) || !(ret == CVoid || ok(ret))) {
				if (decl != cf) throw new LowerError('${cf.cfName} overrides an Objective-C method, which has types C has not', CInterop.posOf(cf.cfPos));
				continue;
			}
			// (a block: an id in the entry, the function it is (blockFunction) for
			// the method; one of types a block has not: a method Objective-C does not see)
			var blocks, blockRet;
			try {
				blocks = [for (a in s.args) isBlockType(a.type) ? blockSig(l, a.type, CInterop.posOf(cf.cfPos)) : null];
				blockRet = !setter && isBlockType(s.ret) ? blockSig(l, s.ret, CInterop.posOf(cf.cfPos)) : null;
			} catch (e:LowerError) {
				if (decl != cf) throw e;
				continue;
			}
			var fi = statics ? l.staticFunc(c, cf) : l.method(c, cf);
			// (w: the entry's work, called by the entry imp makes below)
			var w = new FuncInfo(fi.name + "__imp_call", fi.module);
			w.display = fi.display;
			w.pos = fi.pos;
			var self = new Local(0, "self", TI64);
			w.args = [self, new Local(1, "_cmd", TI64)];
			var n = fi.sret ? fi.args.length - 1 : fi.args.length;
			for (i in first...n)
				w.args.push(new Local(i + 2 - first, fi.args[i].name, blocks[i - first] != null ? TId : fi.args[i].ty));
			w.ret = setter ? TVoid : blockRet != null ? TId : fi.ret;
			// (a struct result: the method's sret, the entry's slot; a setter's,
			// which Objective-C does not see, a slot of w's frame)
			var nargs = w.args.length;
			var sretArg = null;
			if (fi.sret && !setter) {
				sretArg = new Local(nargs, "sret", TI64);
				w.args.push(sretArg);
				w.sret = true;
			}
			var peer = new Local(w.args.length, "peer", TRef(RAny));
			w.locals.push(peer);
			var next = w.args.length + 3;
			function local(name:String, t:Ty) {
				var lo = new Local(next++, name, t);
				w.locals.push(lo);
				return lo;
			}
			var sym = (s:String) -> ECallHost("hxmc_unsafe_Mem_sym", vector(EStr(s)), TI64);
			var off = ECallHost("hxmc_unsafe_Mem_getI64", vector(sym(IVAR_CELL + root), EInt(0)), TI64);
			var index = ECallHost("hxmc_unsafe_Mem_getI32", vector(EBin(LAdd, ELocal(self), off), EInt(0)), TI32);
			var body:Array<Stmt> = statics ? [] : [SSet(peer, ECallHost("rt_objc_peer_get", vector(index), TRef(RAny)))];
			var xs = statics ? [] : [ECast(fi.args[0].ty, ELocal(peer))];
			for (i in 2...nargs) {
				var b = blocks[i - 2];
				if (b == null) {
					xs.push(ELocal(w.args[i]));
					continue;
				}
				var fn = local("fn", fi.args[i - 2 + first].ty);
				body.push(blockFunction(l, ELocal(w.args[i]), b, local("heap", TId), local("same", TRef(RAny)), local("box", TRef(RAny)), fn));
				xs.push(ELocal(fn));
			}
			// the call, in a try: an exception leaving it would unwind through
			// Objective-C's frames, which skips their cleanup (rt_objc_uncaught
			// reports it and ends the program, as an uncaught one)
			var call:Array<Stmt> = [];
			var res:Null<Local> = null;
			if (fi.sret) {
				res = new Local(w.args.length + 1, "r", fi.ret);
				w.locals.push(res);
				body.push(SSet(res, sretArg != null ? ELocal(sretArg) : ECallHost("hxmc_unsafe_Mem_structSlot", vector(EInt(switch fi.ret {
					case TStruct(_, size): size;
					case _: 8;
				}), EInt(8)), TI64)));
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
			if (blockRet != null) {
				// (a function result: a block)
				var id = local("block", TId);
				body.push(SIf(EBin(RefEq, ELocal(res), ENull(res.ty)), vector(SSet(id, EConv(I2L, EInt(0)))), vector(SSet(id, blockNew(l, ELocal(res), blockRet)))));
				res = id;
			}
			// (a method of the copy, mutableCopy or new family: its result the
			// caller's, retained, as ARC returns it; init is the constructor's)
			var sel = decl != cf ? selector(decl, s) : selector(cf, s);
			if (res != null && w.ret == TId && returnsRetained(sel) && family(sel) != "init")
				body.push(SSet(res, ECallHost(runtime(l, "objc_retain", [CPtr], CPtr), vector(ELocal(res)), TId)));
			body.push(SReturn(res == null ? null : ELocal(res)));
			w.body = Vector.fromArrayCopy(body);
			l.prog.funcs.push(w);
			var e = entry(fi.name + "__imp", "hxmc_imp_" + fi.name, fi.module, w, nargs, {args: [CPtr, CPtr].concat(cts), ret: ret});
			e.pos = fi.pos;
			l.prog.funcs.push(e);
			r.push({
				sel: sel,
				sym: e.cSymbol,
				types: (blockRet != null ? "@?" : encoding(ret)) + "@:" + [for (i in 0...cts.length) blocks[i] != null ? "@?" : encoding(cts[i])].join("")
			});
		}
		return r;
	}

	// ---- blocks: a function type in a message's signature (or of a Haxe
	// method Objective-C calls) is a block, as hxmc.objc.Block<F> is
	// anywhere else. A Haxe function becomes a heap block (rt_objc_block_new:
	// _Block_copy of one built in the runtime's frame, autoreleased) whose
	// capture is the index of the closure's entry in the runtime's table
	// (hxmc.rt.Gc: a root while a heap block refers to it, counted by the
	// block's copy and dispose helpers), and whose invoke (one per signature)
	// finds the closure by it. A block becomes a closure holding the block's
	// box (a reference: FnLower.blockCall), or the function it was made of.

	// the program's word holding the descriptor of the blocks of a signature
	// (made by the first block: hxmc.rt.Gc.blockNew; DataGen.objcRefs), and
	// the prefix of the invokes' symbols
	public static inline var BLOCK_DESC = "hxmc$objcblk$";
	public static inline var INVOKE = "hxmc_block_";
	// a closure capturing nothing made a block (static closures: MirBuild
	// makes rt_objc_block_new of one this symbol): a global block in the data
	// (DataGen.objcRefs: isa _NSConcreteGlobalBlock, never copied nor freed),
	// its capture the closure's address; named by its types, flags, invoke
	// and closure (hex: GLOBAL_BLOCK + types _ flags _ invoke _ closure), and
	// its descriptor's (GLOBAL_DESC + types: no copy and dispose helpers)
	public static inline var GLOBAL_BLOCK = "hxmc$objcgblk$";
	public static inline var GLOBAL_DESC = "hxmc$objcgdesc$";
	public static inline var BLOCK_IS_GLOBAL = 1 << 28;
	static inline var BLOCK_NEEDS_FREE = 1 << 24;
	// (the global block's address, which MirBuild makes: the closure, the
	// invoke's address, the types as a C string, the flags)
	public static inline var GLOBAL_BLOCK_HOST = "hxmc_objc_global_block";
	static inline var BLOCK_HAS_SIGNATURE = 1 << 30;
	static inline var BLOCK_USE_STRET = 1 << 29;

	// a function type, where it is a block (a message's parameter or result)
	public static function isBlockType(t:T):Bool
		return TFunctions.follow(t).match(TFun(_));

	// hxmc.objc.Block<F>: its F, else null
	public static function blockOfType(t:T):Null<T>
		return switch TFunctions.follow(t) {
			case TAbstract(a, [f]) if (a.aPath.name == "Block" && a.aPath.pack.join(".") == "hxmc.objc"): f;
			case _: null;
		}

	// the C type of a message's (or a method's entry's) parameter or result:
	// a function's is a block's
	public static function ctype(t:T):CTy
		return isBlockType(t) ? CPtr : CInterop.ctype(t);

	// a block of function type ft: the closures' signature, the C types of
	// its invoke's parameters (after the block) and result, its type encoding
	// (the descriptor's signature: @? the block itself), and the blocks of its
	// parameters and result of function type (a pointer in C: a block taking
	// or returning a block converts them as a method does)
	public static function blockSig(l:LowerQueries, ft:T, where:String):BlockSig {
		var s = switch TFunctions.follow(ft) {
			case TFun(s): s;
			case _: throw new LowerError("a block of a type that is no function", where);
		};
		var sig = switch l.ty(ft) {
			case TRef(RClos(sig)): sig;
			case _: throw new LowerError("a block of a type that is no function", where);
		};
		function ok(ct:CTy)
			return CInterop.isScalar(ct) || ct.match(CStruct(_));
		var blocks = [for (a in s.args) isBlockType(a.type) ? blockSig(l, a.type, where) : null];
		var args = [for (i in 0...s.args.length) blocks[i] != null ? CPtr : CInterop.ctype(s.args[i].type)];
		for (i in 0...args.length)
			if (!ok(args[i])) throw new LowerError('a block\'s parameter ${i + 1} has no C type a block can take', where);
		var retBlock = isBlockType(s.ret) ? blockSig(l, s.ret, where) : null;
		var ret = retBlock != null ? CPtr : CInterop.ctype(s.ret);
		if (ret != CVoid && !ok(ret)) throw new LowerError("a block's result has no C type a block can return", where);
		return {
			sig: sig,
			args: args,
			ret: ret,
			types: (retBlock != null ? "@?" : encoding(ret)) + "@?" + [for (i in 0...args.length) blocks[i] != null ? "@?" : encoding(args[i])].join(""),
			blocks: blocks,
			retBlock: retBlock
		};
	}

	// the key of a block's invoke (and of its caller, Lower.blockCaller): the
	// closures' signature and the C types, a block's its key
	public static function blockKey(b:BlockSig):String {
		function shape(ct:CTy, nb:Null<BlockSig>)
			return nb != null ? "B(" + blockKey(nb) + ")" : CInterop.shape(ct);
		return b.sig.key + "|" + [for (i in 0...b.args.length) shape(b.args[i], b.blocks[i])].join(",") + ">" + shape(b.ret, b.retBlock);
	}

	// the invoke of the blocks of closures of signature b.sig (Lower.blockInvoke,
	// once per signature): sym, a C function (block, arguments...) that
	// attaches the thread when the runtime did not start it (GCD's workers),
	// leaves the safe region the caller is in, calls sym__call, and enters
	// it again; sym__call finds the closure (rt_objc_block_get: the index in
	// the block) and calls it, in a try as a method's entry (imps), its
	// arguments that are blocks made functions and a function result a
	// block. Two functions: the first has no frame, which a thread not yet
	// attached could not push
	public static function invoke(l:Lower, sym:String, b:BlockSig) {
		var sig = b.sig;
		var sret = sig.ret.match(TStruct(_));
		var fi = new FuncInfo(sym + "__call", "_closures");
		fi.display = "(a block's invoke)";
		var block = new Local(0, "block", TI64);
		fi.args = [block];
		for (i in 0...sig.args.length)
			fi.args.push(new Local(i + 1, "a" + i, b.blocks[i] != null ? TId : sig.args[i]));
		fi.ret = b.retBlock != null ? TId : sig.ret;
		var sretLocal = null;
		if (sret) {
			sretLocal = new Local(fi.args.length, "sret", TI64);
			fi.args.push(sretLocal);
			fi.sret = true;
		}
		var n = fi.args.length;
		var clos = new Local(n, "clos", TRef(RClos(sig)));
		var exn = new Local(n + 1, "e", TRef(RAny));
		fi.locals = [clos, exn];
		var next = n + 2;
		function local(name:String, t:Ty) {
			var lo = new Local(next++, name, t);
			fi.locals.push(lo);
			return lo;
		}
		var res = sig.ret == TVoid || sret ? null : local("r", sig.ret);
		var body:Array<Stmt> = [SSet(clos, ECast(TRef(RClos(sig)), ECallHost("rt_objc_block_get", vector(ELocal(block)), TRef(RAny))))];
		var xs:Array<Ex> = [];
		for (i in 0...sig.args.length) {
			var nb = b.blocks[i];
			if (nb == null) {
				xs.push(ELocal(fi.args[i + 1]));
				continue;
			}
			var fn = local("fn", sig.args[i]);
			body.push(blockFunction(l, ELocal(fi.args[i + 1]), nb, local("heap", TId), local("same", TRef(RAny)), local("box", TRef(RAny)), fn));
			xs.push(ELocal(fn));
		}
		var call = ECallClos(sig, ELocal(clos), Vector.fromArrayCopy(xs));
		body.push(STry(vector(res == null ? SExpr(call) : SSet(res, call)), vector({
			test: null,
			l: exn,
			body: vector(SExpr(ECallHost("rt_objc_uncaught", vector(ELocal(exn)), TVoid)))
		})));
		if (b.retBlock != null) {
			// (a function result: a block)
			var id = local("rb", TId);
			body.push(SIf(EBin(RefEq, ELocal(res), ENull(res.ty)), vector(SSet(id, EConv(I2L, EInt(0)))), vector(SSet(id, blockNew(l, ELocal(res), b.retBlock)))));
			res = id;
		}
		body.push(SReturn(sret ? ELocal(sretLocal) : res == null ? null : ELocal(res)));
		fi.body = Vector.fromArrayCopy(body);
		fi.hasTry = true;
		l.prog.funcs.push(fi);
		var w = entry(sym, sym, "_closures", fi, sig.args.length + 1, {args: [CPtr].concat(b.args), ret: b.ret});
		w.display = fi.display;
		l.prog.funcs.push(w);
	}

	// the C function symbol (C types abi) Objective-C calls, a method's entry
	// (imps) or a block's invoke, on any thread: it attaches the thread when
	// the runtime did not start it (GCD's workers), leaves the safe region
	// the caller is in, calls f (its first nargs arguments; a struct result:
	// a slot of this frame, returned by the C ABI's rules) and enters the
	// region again. No frame of its own, which a thread not yet attached
	// could not push: f has one (its try keeps it from being inlined)
	static function entry(name:String, symbol:String, module:String, f:FuncInfo, nargs:Int, abi:CSig):FuncInfo {
		var w = new FuncInfo(name, module);
		w.cSymbol = symbol;
		w.display = f.display;
		w.cAbi = abi;
		w.args = [for (i in 0...nargs) new Local(i, f.args[i].name, f.args[i].ty)];
		w.ret = f.ret;
		var ys = [for (a in w.args) (ELocal(a) : Ex)];
		var body:Array<Stmt> = [
			SExpr(ECallHost("rt_objc_attach", vector(), TVoid)),
			SExpr(ECallHost("rt_blocking_leave", vector(), TVoid))
		];
		var r = new Local(w.args.length, "r", f.ret == TVoid ? TI32 : f.ret);
		if (f.sret) {
			w.locals.push(r);
			var size = switch f.ret {
				case TStruct(_, size): size;
				case _: 8;
			};
			body.push(SSet(r, ECallHost("hxmc_unsafe_Mem_structSlot", vector(EInt(size), EInt(8)), TI64)));
			body.push(SExpr(ECall(f, Vector.fromArrayCopy(ys.concat([ELocal(r)])))));
		} else if (f.ret != TVoid) {
			w.locals.push(r);
			body.push(SSet(r, ECall(f, Vector.fromArrayCopy(ys))));
		} else body.push(SExpr(ECall(f, Vector.fromArrayCopy(ys))));
		body.push(SExpr(ECallHost("rt_blocking_enter", vector(), TVoid)));
		body.push(SReturn(f.ret == TVoid ? null : ELocal(r)));
		w.body = Vector.fromArrayCopy(body);
		return w;
	}

	// a heap block calling closure c (not null) of the block's signature b:
	// autoreleased, as every id a value is
	public static function blockNew(l:LowerQueries, c:Ex, b:BlockSig):Ex {
		var sym = (s:String) -> ECallHost("hxmc_unsafe_Mem_sym", vector(EStr(s)), TI64);
		var flags = BLOCK_HAS_SIGNATURE;
		// (x86-64: a struct result over 16 bytes comes back through memory)
		if (Lower.targetArm == 0 && CInterop.sizeOf(b.ret) > 16) flags |= BLOCK_USE_STRET;
		// (a closure capturing nothing, an object in the data with static
		// closures, which a Mir host has not: a global block, GLOBAL_BLOCK)
		if (Lower.mirHost == 0 && c.match(ENewClos(_, [])))
			return ECallHost(GLOBAL_BLOCK_HOST, vector(c, sym(l.blockInvoke(b)), ECallHost("hxmc_unsafe_Mem_cstr", vector(EStr(b.types)), TI64),
				EInt(flags)), TId);
		return ECallHost("rt_objc_block_new", vector(ECast(TRef(RAny), c), sym(l.blockInvoke(b)),
			sym(BLOCK_DESC + haxe.io.Bytes.ofString(b.types).toHex()), ECallHost("hxmc_unsafe_Mem_cstr", vector(EStr(b.types)), TI64), EInt(flags),
			sym("_NSConcreteStackBlock"), sym("_Block_copy"), sym(symbol(l, "objc_autorelease"))), TId);
	}

	// block id as a closure of b's signature, into r: null for nil, the
	// function a block made of one is (same: rt_objc_block_fn, when its
	// invoke is this signature's), else a closure calling it (Lower.blockCaller)
	// holding its box (box: a reference to the block, released once the
	// closure dies). A block on its caller's stack (neither a heap block nor
	// a global one: an argument, which the callee copies to keep) is copied
	// first (heap: objc_retainBlock's copy, autoreleased)
	public static function blockFunction(l:LowerQueries, id:Ex, b:BlockSig, heap:Local, same:Local, box:Local, r:Local):Stmt {
		var fn = (s:String) -> ECallHost("hxmc_unsafe_Mem_sym", vector(EStr(symbol(l, s))), TI64);
		var flags = ECallHost("hxmc_unsafe_Mem_getI32", vector(ELocal(heap), EInt(8)), TI32);
		var copy = ECallHost(runtime(l, "objc_retainBlock", [CPtr], CPtr), vector(ELocal(heap)), TId);
		return SIf(EBin(LEq, id, EConv(I2L, EInt(0))), vector(SSet(r, ENull(r.ty))), vector(
			SSet(heap, id),
			SIf(EBin(Eq, EBin(And, flags, EInt(BLOCK_NEEDS_FREE | BLOCK_IS_GLOBAL)), EInt(0)),
				vector(SSet(heap, ECallHost(runtime(l, "objc_autorelease", [CPtr], CPtr), vector(copy), TId))), vector()),
			SSet(same, ECallHost("rt_objc_block_fn", vector(ELocal(heap), ECallHost("hxmc_unsafe_Mem_sym", vector(EStr(l.blockInvoke(b))), TI64)), TRef(RAny))),
			SIf(EBin(RefEq, ELocal(same), ENull(TRef(RAny))), vector(
				SSet(box, ECallHost("rt_objc_box", vector(ELocal(heap), fn("objc_retain"), fn("objc_release"), fn("object_getClass"), fn("class_getInstanceVariable"),
					fn("ivar_getOffset")), TRef(RAny))),
				SSet(r, ENewClos(l.blockCaller(b), vector(ELocal(box))))
			), vector(SSet(r, ECast(r.ty, ELocal(same)))))
		));
	}

	// the indirect C function a block of C types (args, ret) is called
	// through (FnLower.blockCall): (its invoke's address, the block, arguments...),
	// in a safe region as a message
	public static function declareBlockCall(l:LowerQueries, args:Array<CTy>, ret:CTy):String {
		var cargs = [CPtr, CPtr].concat(args);
		var key = CInterop.INDIRECT + "block(" + [for (a in cargs) CInterop.shape(a)].join(",") + ")" + CInterop.shape(ret);
		l.objcDeclare(Func(key, {args: cargs, ret: ret}));
		return key;
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

// a block's types (ObjC.blockSig)
// (blocks, retBlock: of the parameters and result of function type, else null)
typedef BlockSig = {
	sig:SigInfo,
	args:Array<CTy>,
	ret:CTy,
	types:String,
	blocks:Array<Null<BlockSig>>,
	retBlock:Null<BlockSig>
};

// what a body declares for the program's link (LowerQueries.objcDeclare)
enum Decl {
	// C function sym (a message's, ObjC.declare; libobjc's, runtime), called in a safe region
	Func(sym:String, sig:CSig);
	// symbol sym, of library lib (libobjc's; a class object, classRef)
	Symbol(sym:String, lib:String);
	// library lib, loaded though nothing is imported of it (a category's: memberLibrary)
	Load(lib:String);
}
