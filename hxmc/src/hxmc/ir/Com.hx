package hxmc.ir;

import core.TType;
import hxmc.ir.CInterop;
import hxmc.ir.Lower.LowerError;
import hxmc.ir.Ir;
import haxe.ds.Vector;
import core.ds.VectorTools.vector;

using core.TFunctions;

// COM interop (docs/interop.md, "COM"): an extern interface declared
// @:hxmc.com("{IID}") (or extending one; hxmc.com.IUnknown is the root) is a
// COM interface. Its methods are vtable slots in declaration order, after
// its bases' (IUnknown's three first). Its values are Haxe references: a
// foreign object's box (hxmc.rt.ComKind: one per interface pointer, holding
// a reference) or a Haxe object implementing the interface.
//
// A call of one of its methods (FnLower.comCall) gets the interface pointer
// (rt_com_ptr), loads the slot's function from the vtable and calls it in
// the C convention with the pointer first, in a safe region, its C
// signature an indirect C function of its own (one per signature, as
// Objective-C's messages: ObjC.declare). What the C function returns
// depends on the method (mode):
//
// - an HRESULT (the default): one below zero thrown as a
//   hxmc.com.ComException (rt_com_fail); a Haxe result other than Void is
//   the C function's last parameter, a pointer to it ([out, retval]);
// - an HRESULT returned as the Haxe result, an Int (@:hxmc.com.hresult);
// - its own result (@:hxmc.com.direct: `STDMETHOD_(FLOAT, GetFontSize)()`),
//   a struct one through a pointer after `this`, as MSVC returns them from
//   C++ methods on x86-64 and arm64.
//
// A Haxe class implementing COM interfaces (Lower.classInfo; Windows only)
// gets a descriptor function (descBody) and a thunk per method slot (a C
// entry, thunkBody): the runtime makes the object's COM object at its first
// use as a pointer (its block, ComKind) with the class's vtables, whose
// QueryInterface, AddRef and Release are the runtime's.
@:access(hxmc.ir.Lower)
class Com {
	// the hidden field of a Haxe object holding its block (0: none made yet)
	public static inline var FIELD = Lower.HIDDEN_FIELD + "com";
	// the prefix of a class's descriptor function and of its thunks
	public static inline var DESC = "hxmc_com_desc_";
	public static inline var THUNK = "hxmc_com_";

	// HRESULTs the thunks return
	public static inline var E_UNEXPECTED = 0x8000FFFF;
	public static inline var E_POINTER = 0x80004003;

	public static function isUnknown(c:TClass):Bool
		return c.clPath.name == "IUnknown" && c.clPath.pack.join(".") == "hxmc.com";

	// a COM interface: an extern interface declared @:hxmc.com, or extending one
	public static function isCom(c:TClass):Bool {
		if (!c.hasClassFlag(CInterface) || !c.hasClassFlag(CExtern)) return false;
		if (Lower.hasMeta(":hxmc.com", c.clMeta)) return true;
		for (i in c.clImplements)
			if (isCom(i.cls)) return true;
		return false;
	}

	// the COM interface of a type (Null<I> too), else null
	public static function ifaceOf(t:T):Null<TClass>
		return switch TFunctions.follow(t) {
			case TInst(c, _) if (isCom(c)): c;
			case _: null;
		}

	public static function isComType(t:T):Bool
		return ifaceOf(t) != null;

	// the interface c extends (one; IUnknown's base is none)
	public static function base(c:TClass):Null<TClass> {
		var r = null;
		for (i in c.clImplements)
			if (isCom(i.cls)) {
				if (r != null)
					throw new LowerError('COM interface ${c.clPath.name} extends ${r.clPath.name} and ${i.cls.clPath.name}: a COM interface has one base (its vtable extends one)',
						CInterop.posOf(c.clPos));
				r = i.cls;
			}
		if (r == null && !isUnknown(c))
			throw new LowerError('COM interface ${c.clPath.name} extends no COM interface: extend hxmc.com.IUnknown', CInterop.posOf(c.clPos));
		return r;
	}

	// c and its bases, the root (IUnknown) first
	public static function chain(c:TClass):Array<TClass> {
		var r = [];
		var k = c;
		while (k != null) {
			r.unshift(k);
			k = base(k);
		}
		return r;
	}

	// c's own methods, in declaration order (its slots after its bases')
	static function own(c:TClass):Array<TClassField>
		return [for (cf in c.clOrderedFields) if (cf.cfKind.match(Method(_))) cf];

	// every method's slot (IUnknown's three: 0 to 2, not declared)
	public static function slots(c:TClass):Array<{cf:TClassField, slot:Int, owner:TClass}> {
		var r = [];
		var n = 3;
		for (k in chain(c)) {
			if (isUnknown(k)) continue;
			for (cf in own(k)) {
				if (!cf.cfKind.match(Method(MethNormal))) throw new LowerError('COM method ${k.clPath.name}.${cf.cfName}: a plain method', CInterop.posOf(cf.cfPos));
				r.push({cf: cf, slot: n++, owner: k});
			}
		}
		return r;
	}

	public static function nslots(c:TClass):Int
		return 3 + slots(c).length;

	// the slot of method cf of c (declared by c or a base)
	public static function slotOf(c:TClass, cf:TClassField):Int {
		for (s in slots(c))
			if (s.cf == cf || (s.cf.cfName == cf.cfName && s.owner.clFields.get(cf.cfName) == cf)) return s.slot;
		throw new LowerError('${cf.cfName} is no method of the COM interface ${c.clPath.name}', CInterop.posOf(cf.cfPos));
	}

	// the IID of c (@:hxmc.com("{...}")) as the GUID struct's four 32-bit words
	public static function iid(c:TClass):Array<Int> {
		var s = Lower.metaString(":hxmc.com", c.clMeta);
		if (s == null)
			throw new LowerError('COM interface ${c.clPath.name} has no IID: declare it @:hxmc.com("{xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}")', CInterop.posOf(c.clPos));
		var h = StringTools.replace(StringTools.replace(StringTools.replace(s, "{", ""), "}", ""), "-", "");
		var ok = h.length == 32;
		for (i in 0...h.length)
			if ("0123456789abcdefABCDEF".indexOf(h.charAt(i)) < 0) ok = false;
		if (!ok) throw new LowerError('COM interface ${c.clPath.name}: "$s" is no IID ("{xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}")', CInterop.posOf(c.clPos));
		function hex(i:Int, n:Int):Int
			return Std.parseInt("0x" + h.substr(i, n));
		function byte(i:Int):Int
			return hex(16 + 2 * i, 2);
		return [
			hex(0, 8),
			hex(8, 4) | (hex(12, 4) << 16),
			byte(0) | (byte(1) << 8) | (byte(2) << 16) | (byte(3) << 24),
			byte(4) | (byte(5) << 8) | (byte(6) << 16) | (byte(7) << 24)
		];
	}

	public static function iidArgs(c:TClass):Array<Ex>
		return [for (w in iid(c)) EInt(w)];

	// an IID's four words as Mem.words' literal of two 64-bit words (the GUID
	// struct's 16 bytes, little-endian): the program's data, one address per IID
	public static function iidHex(w:Array<Int>):String {
		inline function h(v:Int):String
			return StringTools.hex(v, 8).toLowerCase().substr(-8);
		return h(w[1]) + h(w[0]) + h(w[3]) + h(w[2]);
	}

	// ---- what a method passes and returns

	// how a call's C function returns
	public static inline var CHECKED = 0; // an HRESULT, thrown below zero (the default)
	public static inline var RAW = 1; // an HRESULT, the Haxe result (@:hxmc.com.hresult)
	public static inline var DIRECT = 2; // the Haxe result itself (@:hxmc.com.direct)

	public static function mode(cf:TClassField):Int {
		var raw = Lower.hasMeta(":hxmc.com.hresult", cf.cfMeta), direct = Lower.hasMeta(":hxmc.com.direct", cf.cfMeta);
		if (raw && direct) throw new LowerError('COM method ${cf.cfName} is both @:hxmc.com.hresult and @:hxmc.com.direct', CInterop.posOf(cf.cfPos));
		return raw ? RAW : direct ? DIRECT : CHECKED;
	}

	// a value's C form in a COM signature
	public static function value(t:T):ComValue {
		var i = ifaceOf(t);
		if (i != null) return VIface(i);
		switch TFunctions.follow(t) {
			case TAbstract(a, [p]) if (a.aPath.name == "Null" && a.aPath.pack.length == 0):
				return value(p);
			case TAbstract(a, _) if (a.aPath.name == "BStr" && a.aPath.pack.join(".") == "hxmc.com"):
				return VBStr;
			case TInst(c, _) if (c.clPath.name == "String" && c.clPath.pack.length == 0):
				return VWStr;
			case _:
		}
		var ct = CInterop.ctype(t);
		// (a Bool is Win32's BOOL, a 32-bit int: C's one-byte bool is no COM type)
		if (ct.match(CBool)) return VC(CI32);
		return CInterop.isScalar(ct) || ct.match(CStruct(_)) || ct == CVoid ? VC(ct) : VNone;
	}

	// the C type of a value's form
	public static function ctypeOf(v:ComValue):CTy
		return switch v {
			case VIface(_) | VWStr | VBStr: CPtr;
			case VC(ct): ct;
			case VNone: CNone;
		}

	// the C signature of method cf (of type s) after `this`: its parameters,
	// a retval's pointer or a struct result's (first), and the C result
	public static function csig(cf:TClassField, s:TSignature):{args:Array<CTy>, ret:CTy, retval:Null<ComValue>, sretFirst:Bool} {
		var where = CInterop.posOf(cf.cfPos);
		var args = [];
		for (a in s.args) {
			var v = value(a.type);
			switch v {
				case VNone | VC(CVoid):
					throw new LowerError('COM method ${cf.cfName}: the parameter ${a.name} has no C type a call can pass (numbers, Ptr, structs, COM interfaces, String, BStr)', where);
				case _:
			}
			args.push(ctypeOf(v));
		}
		var r = value(s.ret);
		var isVoid = switch TFunctions.follow(s.ret) {
			case TAbstract(a, _) if (a.aPath.name == "Void" && a.aPath.pack.length == 0): true;
			case _: false;
		}
		switch mode(cf) {
			case RAW:
				if (!r.match(VC(CI32)) || isVoid) throw new LowerError('COM method ${cf.cfName} is @:hxmc.com.hresult: it returns the HRESULT, an Int', where);
				return {args: args, ret: CI32, retval: null, sretFirst: false};
			case DIRECT:
				return switch r {
					case VC(CStruct(_)): {args: [CPtr].concat(args), ret: CPtr, retval: r, sretFirst: true};
					case VC(ct): {args: args, ret: ct, retval: null, sretFirst: false};
					case _: throw new LowerError('COM method ${cf.cfName} is @:hxmc.com.direct: its result is a number, a Ptr, a struct or Void', where);
				}
			case _:
				if (isVoid) return {args: args, ret: CI32, retval: null, sretFirst: false};
				if (r == VNone) throw new LowerError('COM method ${cf.cfName}: the result has no C type an [out, retval] parameter holds', where);
				return {args: args.concat([CPtr]), ret: CI32, retval: r, sretFirst: false};
		}
	}

	// the indirect C function a call of these C types goes through (the
	// function's address and `this` first), named by its types; in a safe
	// region unless @:hxmc.fast
	public static function declare(l:LowerQueries, args:Array<CTy>, ret:CTy, fast:Bool):String {
		var cargs = [CPtr, CPtr].concat(args);
		var key = CInterop.INDIRECT + "com(" + [for (a in cargs) CInterop.shape(a)].join(",") + ")" + CInterop.shape(ret) + (fast ? "!fast" : "");
		l.objcDeclare(fast ? FastFunc(key, {args: cargs, ret: ret}) : Func(key, {args: cargs, ret: ret}));
		return key;
	}

	// ---- Haxe classes implementing COM interfaces

	// the COM interfaces c implements (its superclasses' too), each one's
	// vtable's: those no other one extends, in declaration order
	public static function implemented(c:TClass):Array<TClass> {
		var all:Array<TClass> = [];
		function add(i:TClass) {
			if (isCom(i)) {
				if (!all.contains(i)) all.push(i);
				return;
			}
			// (a Haxe interface extending a COM one)
			for (j in i.clImplements)
				add(j.cls);
		}
		var chainOf = [];
		var k = c;
		while (k != null) {
			chainOf.unshift(k);
			k = k.clSuper != null ? k.clSuper.cls : null;
		}
		for (k in chainOf)
			for (i in k.clImplements)
				add(i.cls);
		return [for (i in all) if (!Lambda.exists(all, j -> j != i && chain(j).contains(i)) && !isUnknown(i)) i];
	}

	// whether c implements a COM interface its superclasses do not
	public static function addsInterfaces(c:TClass):Bool {
		var sup = c.clSuper != null ? implemented(c.clSuper.cls) : [];
		for (i in implemented(c))
			if (!Lambda.exists(sup, j -> chain(j).contains(i))) return true;
		return false;
	}

	// the method of class c implementing slot s's method (its own or inherited)
	public static function implOf(c:TClass, cf:TClassField):Null<TClassField> {
		var k = c;
		while (k != null) {
			var f = k.clFields.get(cf.cfName);
			if (f != null && f.cfKind.match(Method(_))) return f;
			k = k.clSuper != null ? k.clSuper.cls : null;
		}
		return null;
	}

	// the thunk's C entry (C types abi) of work function f: attaches a
	// thread the runtime did not start, leaves the caller's safe region,
	// calls f (which catches every exception: an HRESULT goes back), runs
	// what was put off for the thread (rt_foreign_leave: an attached thread
	// may never come back) and takes the caller's state back, as an
	// Objective-C method's entry (ObjC.entry)
	public static function entry(name:String, symbol:String, module:String, f:FuncInfo, abi:CSig):FuncInfo {
		var w = new FuncInfo(name, module);
		w.cSymbol = symbol;
		w.display = f.display;
		w.cAbi = abi;
		w.args = [for (i in 0...f.args.length) new Local(i, f.args[i].name, f.args[i].ty)];
		w.ret = f.ret;
		var ys = [for (a in w.args) (ELocal(a) : Ex)];
		var prev = new Local(w.args.length + 1, "prev", TI32);
		w.locals.push(prev);
		var body:Array<Stmt> = [];
		body.push(SExpr(ECallHost("rt_foreign_attach", vector(), TVoid)));
		body.push(SSet(prev, ECallHost("rt_callback_begin", vector(), TI32)));
		var r = new Local(w.args.length, "r", f.ret == TVoid ? TI32 : f.ret);
		if (f.ret != TVoid) {
			w.locals.push(r);
			body.push(SSet(r, ECall(f, Vector.fromArrayCopy(ys))));
		} else body.push(SExpr(ECall(f, Vector.fromArrayCopy(ys))));
		body.push(SExpr(ECallHost("rt_foreign_leave", vector(), TVoid)));
		body.push(SExpr(ECallHost("rt_callback_end", vector(ELocal(prev)), TVoid)));
		body.push(SReturn(f.ret == TVoid ? null : ELocal(r)));
		w.body = Vector.fromArrayCopy(body);
		return w;
	}
}

// a value's C form in a COM method's signature
enum ComValue {
	VIface(c:TClass); // an interface pointer (a COM value: box or Haxe object)
	VWStr; // a String as an LPCWSTR (an [out] one: an LPWSTR of CoTaskMemAlloc)
	VBStr; // hxmc.com.BStr: a BSTR
	VC(ct:CTy); // a C value as C interop passes it
	VNone;
}
