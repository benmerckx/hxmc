/*
 * Copyright (C)2005-2019 Haxe Foundation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

package generators;

import haxe.ds.StringMap;
import core.ds.NotFound;
import core.ds.OcamlHashtbl;
import core.ds.OcamlHash;

enum Ttype {
	HVoid;
	HUI8;
	HUI16;
	HI32;
	HI64;
	HF32;
	HF64;
	HBool;
	HBytes;
	HDyn;
	HFun(args:Array<Ttype>, ret:Ttype);
	HObj(p:ClassProto);
	HArray(t:Ttype);
	HType;
	HRef(t:Ttype);
	HVirtual(v:VirtualProto);
	HDynObj;
	// port: `ident` stands for the physical identity of the OCaml name string (the
	// source expression it comes from); only Hl2c's Marshal emulation reads it.
	HAbstract(name:String, idx:Int, ident:Dynamic);
	HEnum(e:EnumProto);
	HNull(t:Ttype); /* for not nullable type only */
	HMethod(args:Array<Ttype>, ret:Ttype);
	HStruct(p:ClassProto);
	HPacked(t:Ttype);
	HGUID;
}

// port: the `(string * string index * ttype)` triples of `pfields`/`vfields`.
typedef HField = {
	var name:String;
	var nid:Int;
	var t:Ttype;
}

// port: the `(string, 'v) PMap.t` fields of the prototypes (pindex, pfunctions,
// vindex): looked up through a StringMap; `keys` holds the keys in first-insertion
// order (a re-added key keeps its place and takes the new key string, as PMap.add
// does), from which Hl2c's Marshal rebuilds the PMap's AVL tree.
class StrPMap<V> {
	final m:StringMap<V> = new StringMap();
	final pos:StringMap<Int> = new StringMap();

	public final keys:Array<String> = [];

	public function new() {}

	public inline function get(k:String):Null<V> return m.get(k);

	public inline function exists(k:String):Bool return m.exists(k);

	public function set(k:String, v:V):Void {
		var i = pos.get(k);
		if (i == null) {
			pos.set(k, keys.length);
			keys.push(k);
		} else {
			keys[i] = k;
		}
		m.set(k, v);
	}
}

class ClassProto {
	public var pname:String;
	public var pid:Int;
	public var pclassglobal:Null<Int>;
	public var psuper:Null<ClassProto>;
	public var pvirtuals:Array<Int>;
	public var pproto:Array<FieldProto>;
	public var pnfields:Int;
	public var pfields:Array<HField>;
	public var pindex:StrPMap<{fid:Int, t:Ttype}>;
	public var pfunctions:StrPMap<Int>;
	public var pinterfaces:TtypeMap<Int>;
	public var pbindings:Array<{fid:Int, fidx:Int}>; // port: (int * int) list, head first

	public function new(pname:String, pid:Int) {
		this.pname = pname;
		this.pid = pid;
		pclassglobal = null;
		psuper = null;
		pvirtuals = [];
		pproto = [];
		pnfields = 0;
		pfields = [];
		pindex = new StrPMap();
		pfunctions = new StrPMap();
		pinterfaces = new TtypeMap();
		pbindings = [];
	}
}

class EnumProto {
	public var ename:String;
	public var eid:Int;
	public var eglobal:Null<Int>;
	public var efields:Array<{name:String, nid:Int, args:Array<Ttype>}>;

	public function new(ename:String, eid:Int, eglobal:Null<Int>, efields:Array<{name:String, nid:Int, args:Array<Ttype>}>) {
		this.ename = ename;
		this.eid = eid;
		this.eglobal = eglobal;
		this.efields = efields;
	}
}

class FieldProto {
	public var fname:String;
	public var fid:Int;
	public var fmethod:Int;
	public var fvirtual:Null<Int>;

	public function new(fname:String, fid:Int, fmethod:Int, fvirtual:Null<Int>) {
		this.fname = fname;
		this.fid = fid;
		this.fmethod = fmethod;
		this.fvirtual = fvirtual;
	}
}

class VirtualProto {
	public var vfields:Array<HField>;
	public var vindex:StrPMap<Int>;

	public function new() {
		vfields = [];
		vindex = new StrPMap();
	}
}

enum Tgroup {
	GInt;
	GFloat;
	GBool;
	GNull;
	GOther;
}

// port: the declaration order gives the opcode ids (`Obj.tag`) written to the bytecode.
enum Opcode {
	/* register storing */
	OMov(a:Int, b:Int);
	OInt(r:Int, i:Int);
	OFloat(r:Int, i:Int);
	OBool(r:Int, b:Bool);
	OBytes(r:Int, s:Int);
	OString(r:Int, s:Int);
	ONull(r:Int);
	/* binops */
	OAdd(r:Int, a:Int, b:Int);
	OSub(r:Int, a:Int, b:Int);
	OMul(r:Int, a:Int, b:Int);
	OSDiv(r:Int, a:Int, b:Int);
	OUDiv(r:Int, a:Int, b:Int);
	OSMod(r:Int, a:Int, b:Int);
	OUMod(r:Int, a:Int, b:Int);
	OShl(r:Int, a:Int, b:Int);
	OSShr(r:Int, a:Int, b:Int);
	OUShr(r:Int, a:Int, b:Int);
	OAnd(r:Int, a:Int, b:Int);
	OOr(r:Int, a:Int, b:Int);
	OXor(r:Int, a:Int, b:Int);
	/* unops */
	ONeg(r:Int, v:Int);
	ONot(r:Int, v:Int);
	OIncr(r:Int);
	ODecr(r:Int);
	/* calls */
	OCall0(r:Int, f:Int);
	OCall1(r:Int, f:Int, a:Int);
	OCall2(r:Int, f:Int, a:Int, b:Int);
	OCall3(r:Int, f:Int, a:Int, b:Int, c:Int);
	OCall4(r:Int, f:Int, a:Int, b:Int, c:Int, d:Int);
	OCallN(r:Int, f:Int, rl:Array<Int>);
	OCallMethod(r:Int, f:Int, rl:Array<Int>);
	OCallThis(r:Int, f:Int, rl:Array<Int>);
	OCallClosure(r:Int, f:Int, rl:Array<Int>);
	/* closures */
	OStaticClosure(r:Int, f:Int); /* Class.method */
	OInstanceClosure(r:Int, f:Int, v:Int); /* instance.method */
	OVirtualClosure(r:Int, o:Int, f:Int); /* instance.overriddenMethod */
	/* field access */
	OGetGlobal(r:Int, g:Int);
	OSetGlobal(g:Int, r:Int);
	OField(r:Int, o:Int, f:Int);
	OSetField(o:Int, f:Int, r:Int);
	OGetThis(r:Int, f:Int);
	OSetThis(f:Int, r:Int);
	ODynGet(r:Int, o:Int, s:Int);
	ODynSet(o:Int, s:Int, r:Int);
	/* jumps */
	OJTrue(r:Int, d:Int);
	OJFalse(r:Int, d:Int);
	OJNull(r:Int, d:Int);
	OJNotNull(r:Int, d:Int);
	OJSLt(a:Int, b:Int, d:Int);
	OJSGte(a:Int, b:Int, d:Int);
	OJSGt(a:Int, b:Int, d:Int);
	OJSLte(a:Int, b:Int, d:Int);
	OJULt(a:Int, b:Int, d:Int);
	OJUGte(a:Int, b:Int, d:Int);
	OJNotLt(a:Int, b:Int, d:Int);
	OJNotGte(a:Int, b:Int, d:Int);
	OJEq(a:Int, b:Int, d:Int);
	OJNotEq(a:Int, b:Int, d:Int);
	OJAlways(d:Int);
	/* coerce */
	OToDyn(r:Int, a:Int);
	OToSFloat(r:Int, a:Int);
	OToUFloat(r:Int, a:Int);
	OToInt(r:Int, a:Int);
	OSafeCast(r:Int, a:Int);
	OUnsafeCast(r:Int, a:Int);
	OToVirtual(r:Int, a:Int);
	/* control flow */
	OLabel(u:Int);
	ORet(r:Int);
	OThrow(r:Int);
	ORethrow(r:Int);
	OSwitch(r:Int, idx:Array<Int>, eend:Int);
	ONullCheck(r:Int);
	OTrap(r:Int, d:Int);
	OEndTrap(b:Bool);
	/* memory access */
	OGetUI8(r:Int, b:Int, p:Int);
	OGetUI16(r:Int, b:Int, p:Int);
	OGetMem(r:Int, b:Int, p:Int);
	OGetArray(r:Int, a:Int, i:Int);
	OSetUI8(b:Int, p:Int, v:Int);
	OSetUI16(b:Int, p:Int, v:Int);
	OSetMem(b:Int, p:Int, v:Int);
	OSetArray(a:Int, i:Int, v:Int);
	/* type operations */
	ONew(r:Int);
	OArraySize(r:Int, a:Int);
	OType(r:Int, t:Ttype);
	OGetType(r:Int, v:Int);
	OGetTID(r:Int, v:Int);
	/* references */
	ORef(r:Int, v:Int);
	OUnref(r:Int, v:Int);
	OSetref(r:Int, v:Int);
	/* enums */
	OMakeEnum(r:Int, e:Int, rl:Array<Int>);
	OEnumAlloc(r:Int, e:Int);
	OEnumIndex(r:Int, e:Int);
	OEnumField(r:Int, e:Int, i:Int, n:Int);
	OSetEnumField(e:Int, i:Int, r:Int);
	/* misc */
	OAssert(u:Int);
	ORefData(r:Int, d:Int);
	ORefOffset(r:Int, r2:Int, off:Int);
	ONop(s:String);
	OPrefetch(r:Int, f:Int, mode:Int);
	OAsm(mode:Int, value:Int, reg:Int);
	OCatch(g:Int);
}

// port: the `(int * int * Globals.pos)` debug triples.
typedef DebugInfo = {
	var file:Int;
	var line:Int;
	var pos:core.Globals.Pos;
}

// port: the `(string index * int * int)` assign triples.
typedef Assign = {
	var name:Int;
	var pos:Int;
	var scopeEnd:Int;
}

// port: `string * string`
typedef FPath = {
	var fst:String;
	var snd:String;
}

class Fundecl {
	public var fpath:FPath;
	public var findex:Int;
	public var ftype:Ttype;
	public var regs:Array<Ttype>;
	public var code:Array<Opcode>;
	public var debug:Array<DebugInfo>;
	public var assigns:Array<Assign>;
	public var needOpt:Bool;

	public function new(fpath:FPath, findex:Int, ftype:Ttype, regs:Array<Ttype>, code:Array<Opcode>, debug:Array<DebugInfo>, assigns:Array<Assign>,
			needOpt:Bool) {
		this.fpath = fpath;
		this.findex = findex;
		this.ftype = ftype;
		this.regs = regs;
		this.code = code;
		this.debug = debug;
		this.assigns = assigns;
		this.needOpt = needOpt;
	}

	// port: `{ f with ... }`
	public function with(code:Array<Opcode>, regs:Array<Ttype>, debug:Array<DebugInfo>, assigns:Array<Assign>):Fundecl
		return new Fundecl(fpath, findex, ftype, regs, code, debug, assigns, needOpt);
}

// port: the `(string index * string index * ttype * functable index)` natives.
typedef Native = {
	var lib:Int;
	var name:Int;
	var t:Ttype;
	var findex:Int;
}

class Code {
	public var version:Int;
	public var entrypoint:Int;
	public var strings:Array<String>;
	public var ints:Array<Int>;
	public var floats:Array<Float>;
	public var bytes:Array<haxe.io.Bytes>;
	/* types : ttype array // only in bytecode, rebuilt on save() */
	public var globals:Array<Ttype>;
	public var natives:Array<Native>;
	public var functions:Array<Fundecl>;
	public var debugfiles:Array<String>;
	public var constants:Array<{g:Int, fields:Array<Int>}>;

	public function new(version:Int, entrypoint:Int, strings:Array<String>, ints:Array<Int>, floats:Array<Float>, bytes:Array<haxe.io.Bytes>,
			globals:Array<Ttype>, natives:Array<Native>, functions:Array<Fundecl>, debugfiles:Array<String>, constants:Array<{g:Int, fields:Array<Int>}>) {
		this.version = version;
		this.entrypoint = entrypoint;
		this.strings = strings;
		this.ints = ints;
		this.floats = floats;
		this.bytes = bytes;
		this.globals = globals;
		this.natives = natives;
		this.functions = functions;
		this.debugfiles = debugfiles;
		this.constants = constants;
	}
}

class Hlcode {
	public static final nullProto:ClassProto = new ClassProto("", 0);

	public static inline function listIteri<T>(f:Int->T->Void, l:Array<T>):Void
		for (i in 0...l.length) f(i, l[i]);

	public static inline function listMapi<T, R>(f:Int->T->R, l:Array<T>):Array<R>
		return [for (i in 0...l.length) f(i, l[i])];

	/*
		does the runtime value can be set to null
	 */
	public static function isNullable(t:Ttype):Bool {
		return switch t {
			case HBytes | HDyn | HFun(_) | HObj(_) | HArray(_) | HVirtual(_) | HDynObj | HAbstract(_) | HEnum(_) | HNull(_) | HRef(_) | HType | HMethod(_) |
				HStruct(_): true;
			case HUI8 | HUI16 | HI32 | HI64 | HF32 | HF64 | HBool | HVoid | HPacked(_) | HGUID: false;
		}
	}

	public static function isStruct(t:Ttype):Bool {
		return switch t {
			case HStruct(_) | HPacked(_): true;
			case _: false;
		}
	}

	public static function getGroup(t:Ttype):Tgroup {
		return switch t {
			case HUI8 | HUI16 | HI32 | HI64 | HGUID: GInt;
			case HF32 | HF64: GFloat;
			case HBool: GBool;
			case HNull(HUI8 | HUI16 | HI32 | HI64 | HGUID): GNull;
			case HNull(HF32 | HF64): GNull;
			case HNull(HBool): GNull;
			case HNull(_): core.Globals.die("", "hlcode.ml");
			case _: GOther;
		}
	}

	public static function getInnerType(t:Ttype):Ttype {
		return switch t {
			case HNull(t): t;
			case _: t;
		}
	}

	public static function typeSizeBits(t:Ttype):Int {
		return switch t {
			case HUI8 | HBool: 0;
			case HUI16: 1;
			case HI32 | HF32: 2;
			case HI64 | HGUID | HF64: 3;
			case _: core.Globals.die("", "hlcode.ml");
		}
	}

	public static function commonTypeNumber(t1:Ttype, t2:Ttype):Ttype {
		if (t1 == t2) return t1;
		return switch [getGroup(t1), getGroup(t2)] {
			case [GInt, GInt]: if (typeSizeBits(t1) > typeSizeBits(t2)) t1 else t2;
			case [GInt, GFloat]: t2; /* possible loss of precision */
			case [GFloat, GInt]: t1;
			case [GFloat, GFloat]: if (typeSizeBits(t1) > typeSizeBits(t2)) t1 else t2;
			case _: core.Globals.die("", "hlcode.ml");
		}
	}

	public static function isInt(t:Ttype):Bool return getGroup(t) == GInt;

	public static function isFloat(t:Ttype):Bool return getGroup(t) == GFloat;

	public static function isNumber(t:Ttype):Bool {
		return switch getGroup(t) {
			case GInt | GFloat: true;
			case _: false;
		}
	}

	public static function isNullt(t:Ttype):Bool return getGroup(t) == GNull;

	/*
		does the runtime value carry its type
	 */
	public static function isDynamic(t:Ttype):Bool {
		return switch t {
			case HDyn | HFun(_) | HObj(_) | HArray(_) | HVirtual(_) | HDynObj | HNull(_) | HEnum(_): true;
			case _: false;
		}
	}

	public static function tsame(t1:Ttype, t2:Ttype):Bool {
		if (t1 == t2) return true;
		return switch [t1, t2] {
			case [HFun(args1, ret1), HFun(args2, ret2)] if (args1.length == args2.length): forAll2(tsame, args1, args2) && tsame(ret2, ret1);
			case [HMethod(args1, ret1), HMethod(args2, ret2)] if (args1.length == args2.length): forAll2(tsame, args1, args2) && tsame(ret2, ret1);
			case [HObj(p1), HObj(p2)]: p1 == p2;
			case [HEnum(e1), HEnum(e2)]: e1 == e2;
			case [HStruct(p1), HStruct(p2)]: p1 == p2;
			case [HAbstract(_, a1, _), HAbstract(_, a2, _)]: a1 == a2;
			case [HVirtual(v1), HVirtual(v2)]:
				if (v1 == v2) true else if (v1.vfields.length != v2.vfields.length) false else {
					var i = 0;
					var ok = true;
					while (i < v1.vfields.length) {
						var f1 = v1.vfields[i];
						var f2 = v2.vfields[i];
						if (f1.nid == f2.nid && tsame(f1.t, f2.t)) i++ else {
							ok = false;
							break;
						}
					}
					ok;
				}
			case [HNull(t1), HNull(t2)]: tsame(t1, t2);
			case [HRef(t1), HRef(t2)]: tsame(t1, t2);
			case _: false;
		}
	}

	public static function compatibleElementTypes(t1:Ttype, t2:Ttype):Bool {
		if (t1 == t2) return true; /* equal types are always compatible */
		return switch [getGroup(t1), getGroup(t2)] {
			case [GInt | GFloat, GInt | GFloat]:
				typeSizeBits(t1) == typeSizeBits(t2); /* same size numbers are also compatible */
			case _:
				/* no other number combinations are compatible, but everything else is */
				true;
		}
	}

	/*
		can we use a value of t1 as t2
	 */
	public static function safeCast(t1:Ttype, t2:Ttype):Bool {
		if (t1 == t2) return true;
		return switch [t1, t2] {
			case [_, HDyn]: isDynamic(t1);
			case [HVirtual(v1), HVirtual(v2)] if (v2.vfields.length < v1.vfields.length):
				var ok = true;
				for (i in 0...v2.vfields.length) {
					var f1 = v1.vfields[i];
					var f2 = v2.vfields[i];
					if (!(f1.name == f2.name && tsame(f1.t, f2.t))) {
						ok = false;
						break;
					}
				}
				ok;
			case [HObj(p1), HObj(p2)]:
				/* allow subtyping */
				var p = p1;
				var found = false;
				while (true) {
					if (p.pname == p2.pname) {
						found = true;
						break;
					}
					if (p.psuper == null) break;
					p = p.psuper;
				}
				found;
			case [HStruct(p1), HStruct(p2)]:
				/* allow subtyping */
				var p = p1;
				var found = false;
				while (true) {
					if (p.pname == p2.pname) {
						found = true;
						break;
					}
					if (p.psuper == null) break;
					p = p.psuper;
				}
				found;
			case [HPacked(t1), HStruct(_)]:
				safeCast(t1, t2);
			case [HStruct(_), HPacked(t2)]:
				safeCast(t1, t2);
			case [HFun(args1, t1), HFun(args2, t2)] if (args1.length == args2.length):
				forAll2(function(t1, t2) return safeCast(t2, t1) || (tEq(t1, HDyn) && isDynamic(t2)), args1, args2) && safeCast(t1, t2);
			case [HArray(t1), HArray(t2)]:
				compatibleElementTypes(t1, t2);
			case _:
				tsame(t1, t2);
		}
	}

	public static function hlHash(b:String):Int {
		var bytes = haxe.io.Bytes.ofString(b);
		var h = 0;
		var i = 0;
		while (true) {
			var c = if (i == bytes.length) 0 else bytes.get(i);
			if (c != 0) {
				h = (mul32(h, 223) + c) | 0;
				i++;
			} else return h % 0x1FFFFF7B;
		}
	}

	public static function getIndex(name:String, p:ClassProto):{fid:Int, t:Ttype} {
		var v = p.pindex.get(name);
		if (v != null) return v;
		if (p.psuper == null) throw NotFound.raise();
		return getIndex(name, p.psuper);
	}

	public static function resolveField(p:ClassProto, fid:Int):{name:String, t:Ttype} {
		var pl:Array<ClassProto> = [];
		var cur = p;
		while (true) {
			pl.unshift(cur);
			if (cur.psuper == null) break;
			cur = cur.psuper;
		}
		var id = fid;
		for (p in pl) {
			var d = id - p.pfields.length;
			if (d < 0) {
				var f = p.pfields[id];
				return {name: f.name, t: f.t};
			} else id = d;
		}
		throw NotFound.raise();
	}

	public static function gatherTypes(code:Code):{all:Array<Ttype>, types:TtypeMap<Int>} {
		var types = new TtypeMap<Int>();
		var arr:Array<Ttype> = [];
		function getType(t:Ttype):Void {
			switch t {
				case HObj({psuper: p}) if (p != null): getType(HObj(p));
				case HStruct({psuper: p}) if (p != null): getType(HStruct(p));
				case HNull(t) | HRef(t): getType(t);
				case _:
			}
			if (types.exists(t)) return;
			var index = arr.length;
			arr.push(t);
			types.set(t, index);
			switch t {
				case HFun(args, ret) | HMethod(args, ret):
					for (a in args) getType(a);
					getType(ret);
				case HObj(p) | HStruct(p):
					for (f in p.pfields) getType(f.t);
				case HVirtual(v):
					for (f in v.vfields) getType(f.t);
				case HEnum(e):
					for (f in e.efields) for (t in f.args) getType(t);
				case _:
			}
		}
		for (t in [HVoid, HUI8, HUI16, HI32, HI64, HF32, HF64, HBool, HType, HDyn]) getType(t); /* make sure all basic types get lower indexes */
		for (g in code.globals) getType(g);
		for (n in code.natives) getType(n.t);
		for (f in code.functions) {
			getType(f.ftype);
			for (r in f.regs) getType(r);
			for (op in f.code) switch op {
				case OType(_, t): getType(t);
				case _:
			}
		}
		return {all: arr, types: types};
	}

	public static function lookupType(types:TtypeMap<Int>, t:Ttype):Int {
		var v = types.get(t);
		if (v == null) return core.Globals.die("", "hlcode.ml");
		return v;
	}

	/* --------------------------------------------------------------------------------------------------------------------- */
	/* DUMP */

	public static function tstr(t:Ttype, ?stack:Array<VirtualProto>, detailed:Bool = false):String {
		if (stack == null) stack = [];
		inline function sub(t:Ttype):String return tstr(t, stack, detailed);
		return switch t {
			case HVoid: "void";
			case HUI8: "ui8";
			case HUI16: "ui16";
			case HI32: "i32";
			case HI64: "i64";
			case HF32: "f32";
			case HF64: "f64";
			case HBool: "bool";
			case HBytes: "bytes";
			case HDyn: "dyn";
			case HFun(args, ret): "(" + [for (a in args) sub(a)].join(",") + "):" + sub(ret);
			case HMethod(args, ret): "method:(" + [for (a in args) sub(a)].join(",") + "):" + sub(ret);
			case HObj(o) if (!detailed): o.pname;
			case HStruct(s) if (!detailed): "@" + s.pname;
			case HObj(o) | HStruct(o):
				var fields = "{" + [for (f in o.pfields) f.name + " : " + tstr(f.t, null, false)].join(",") + "}";
				var proto = "{" + [
					for (p in o.pproto) (p.fvirtual == null ? "" : "virtual ") + p.fname + "@" + p.fmethod
				].join(",") + "}";
				var str = o.pname + "[" + (o.psuper == null ? "" : ">" + o.psuper.pname + " ") + "fields=" + fields + " proto=" + proto + "]";
				switch t {
					case HObj(_): str;
					case _: "@" + str;
				}
			case HArray(t):
				"array(" + sub(t) + ")";
			case HType:
				"type";
			case HRef(t):
				"ref(" + tstr(t) + ")";
			case HVirtual(v) if (stack.indexOf(v) >= 0):
				"...";
			case HVirtual(v):
				"virtual(" + [for (f in v.vfields) f.name + ":" + tstr(f.t, [v].concat(stack))].join(",") + ")";
			case HDynObj:
				"dynobj";
			case HAbstract(s, _, _):
				"abstract(" + s + ")";
			case HEnum(e) if (e.eid == 0):
				var fl = e.efields[0].args;
				"enum(" + [for (t in fl) tstr(t)].join(",") + ")";
			case HEnum(e):
				"enum(" + e.ename + ")";
			case HNull(t): "null(" + tstr(t) + ")";
			case HPacked(t): "packed(" + tstr(t) + ")";
			case HGUID: "guid";
		}
	}

	public static function ostr(fstr:Int->String, o:Opcode):String {
		inline function rl(l:Array<Int>):String return [for (r in l) Std.string(r)].join(",");
		return switch o {
			case OMov(a, b): 'mov $a,$b';
			case OInt(r, i): 'int $r,@$i';
			case OFloat(r, i): 'float $r,@$i';
			case OString(r, s): 'string $r,@$s';
			case OBytes(r, s): 'bytes $r,@$s';
			case OBool(r, b): if (b) 'true $r' else 'false $r';
			case ONull(r): 'null $r';
			case OAdd(r, a, b): 'add $r,$a,$b';
			case OSub(r, a, b): 'sub $r,$a,$b';
			case OMul(r, a, b): 'mul $r,$a,$b';
			case OSDiv(r, a, b): 'sdiv $r,$a,$b';
			case OUDiv(r, a, b): 'udiv $r,$a,$b';
			case OSMod(r, a, b): 'smod $r,$a,$b';
			case OUMod(r, a, b): 'umod $r,$a,$b';
			case OShl(r, a, b): 'shl $r,$a,$b';
			case OSShr(r, a, b): 'sshr $r,$a,$b';
			case OUShr(r, a, b): 'ushr $r,$a,$b';
			case OAnd(r, a, b): 'and $r,$a,$b';
			case OOr(r, a, b): 'or $r,$a,$b';
			case OXor(r, a, b): 'xor $r,$a,$b';
			case ONeg(r, v): 'neg $r,$v';
			case ONot(r, v): 'not $r,$v';
			case OIncr(r): 'incr $r';
			case ODecr(r): 'decr $r';
			case OCall0(r, g): 'call $r, ${fstr(g)}()';
			case OCall1(r, g, a): 'call $r, ${fstr(g)}($a)';
			case OCall2(r, g, a, b): 'call $r, ${fstr(g)}($a,$b)';
			case OCall3(r, g, a, b, c): 'call $r, ${fstr(g)}($a,$b,$c)';
			case OCall4(r, g, a, b, c, d): 'call $r, ${fstr(g)}($a,$b,$c,$d)';
			case OCallN(r, g, l): 'call $r, ${fstr(g)}(${rl(l)})';
			case OCallMethod(r, f, l) if (l.length == 0): "callmethod ???";
			case OCallMethod(r, f, l): 'callmethod $r, ${l[0]}[$f](${rl(l.slice(1))})';
			case OCallClosure(r, f, l): 'callclosure $r, $f(${rl(l)})';
			case OCallThis(r, f, l): 'callthis $r, [$f](${rl(l)})';
			case OStaticClosure(r, f): 'staticclosure $r, ${fstr(f)}';
			case OInstanceClosure(r, f, v): 'instanceclosure $r, ${fstr(f)}($v)';
			case OGetGlobal(r, g): 'global $r, $g';
			case OSetGlobal(g, r): 'setglobal $g, $r';
			case ORet(r): 'ret $r';
			case OJTrue(r, d): 'jtrue $r,$d';
			case OJFalse(r, d): 'jfalse $r,$d';
			case OJNull(r, d): 'jnull $r,$d';
			case OJNotNull(r, d): 'jnotnull $r,$d';
			case OJSLt(a, b, i): 'jslt $a,$b,$i';
			case OJSGte(a, b, i): 'jsgte $a,$b,$i';
			case OJSGt(r, a, b): 'jsgt $r,$a,$b';
			case OJSLte(r, a, b): 'jslte $r,$a,$b';
			case OJULt(a, b, i): 'jult $a,$b,$i';
			case OJUGte(a, b, i): 'jugte $a,$b,$i';
			case OJNotLt(a, b, i): 'jnotlt $a,$b,$i';
			case OJNotGte(a, b, i): 'jnotgte $a,$b,$i';
			case OJEq(a, b, i): 'jeq $a,$b,$i';
			case OJNotEq(a, b, i): 'jnoteq $a,$b,$i';
			case OJAlways(d): 'jalways $d';
			case OToDyn(r, a): 'todyn $r,$a';
			case OToSFloat(r, a): 'tosfloat $r,$a';
			case OToUFloat(r, a): 'toufloat $r,$a';
			case OToInt(r, a): 'toint $r,$a';
			case OLabel(_): "label";
			case ONew(r): 'new $r';
			case OField(r, o, i): 'field $r,$o[$i]';
			case OVirtualClosure(r, o, m): 'virtualclosure $r,$o[$m]';
			case OSetField(o, i, r): 'setfield $o[$i],$r';
			case OGetThis(r, i): 'getthis $r,[$i]';
			case OSetThis(i, r): 'setthis [$i],$r';
			case OThrow(r): 'throw $r';
			case ORethrow(r): 'rethrow $r';
			case OGetUI8(r, b, p): 'getui8 $r,$b[$p]';
			case OGetUI16(r, b, p): 'getui16 $r,$b[$p]';
			case OGetMem(r, b, p): 'getmem $r,$b[$p]';
			case OGetArray(r, a, i): 'getarray $r,$a[$i]';
			case OSetUI8(r, p, v): 'setui8 $r,$p,$v';
			case OSetUI16(r, p, v): 'setui16 $r,$p,$v';
			case OSetMem(r, p, v): 'setmem $r,$p,$v';
			case OSetArray(a, i, v): 'setarray $a[$i],$v';
			case OSafeCast(r, v): 'safecast $r,$v';
			case OUnsafeCast(r, v): 'unsafecast $r,$v';
			case OArraySize(r, a): 'arraysize $r,$a';
			case OType(r, t): 'type $r,${tstr(t)}';
			case OGetType(r, v): 'gettype $r,$v';
			case OGetTID(r, v): 'gettid $r,$v';
			case ORef(r, v): 'ref $r,&$v';
			case OUnref(v, r): 'unref $v,*$r';
			case OSetref(r, v): 'setref *$r,$v';
			case OToVirtual(r, v): 'tovirtual $r,$v';
			case ODynGet(r, o, f): 'dynget $r,$o[@$f]';
			case ODynSet(o, f, v): 'dynset $o[@$f],$v';
			case OMakeEnum(r, e, pl): 'makeenum $r, $e(${rl(pl)})';
			case OEnumAlloc(r, e): 'enumalloc $r, $e';
			case OEnumIndex(r, e): 'enumindex $r, $e';
			case OEnumField(r, e, i, n): 'enumfield $r, $e[$i:$n]';
			case OSetEnumField(e, i, r): 'setenumfield $e[$i], $r';
			case OSwitch(r, idx, eend): 'switch $r [${rl(idx)}] $eend';
			case ONullCheck(r): 'nullcheck $r';
			case OTrap(r, i): 'trap $r, $i';
			case OEndTrap(b): 'endtrap ${b ? "true" : "false"}';
			case OAssert(_): "assert";
			case ORefData(r, d): 'refdata $r, $d';
			case ORefOffset(r, r2, off): 'refoffset $r, $r2, $off';
			case ONop(s): if (s == "") "nop" else "nop " + s;
			case OPrefetch(r, f, mode): 'prefetch $r[$f] $mode';
			case OAsm(mode, value, reg):
				if (mode == 0 && reg == 0) "asm " + hex(value, 2) else if (mode == 1 && reg == 0) 'asm scratch R$value' else if (mode == 2)
					'asm R$value := ${reg - 1}' else if (mode == 3) 'asm ${reg - 1} := R$value' else
					'asm[$mode] $value' + (reg == 0 ? "" : ", " + Std.string(reg - 1));
			case OCatch(g): 'catch $g';
		}
	}

	public static function fundeclName(f:Fundecl):String return if (f.fpath.snd == "") "fun$" + f.findex else f.fpath.fst + "." + f.fpath.snd;

	public static function dump(pr:String->Void, code:Code):Void {
		var allProtos = new OcamlHashtbl<String, ClassProto>(OcamlHash.hashString, (a, b) -> a == b);
		var funnames = new haxe.ds.IntMap<String>();
		function tstr(t:Ttype):String {
			switch t {
				case HObj(p): allProtos.replace(p.pname, p);
				case _:
			}
			return Hlcode.tstr(t);
		}
		function str(idx:Int):String {
			if (idx >= 0 && idx < code.strings.length) return code.strings[idx];
			return "INVALID:" + idx;
		}
		function fstr(fid:Int):String {
			var n = funnames.get(fid);
			if (n != null) return n;
			return "f@" + hex(fid);
		}
		function debugInfos(d:DebugInfo):String {
			return (if (d.file >= 0 && d.file < code.debugfiles.length) code.debugfiles[d.file] else "???") + ":" + d.line;
		}
		pr("hl v" + code.version);
		pr("entry @" + code.entrypoint);
		pr(code.strings.length + " strings");
		for (i in 0...code.strings.length) pr("\t@" + i + " : " + ocamlEscaped(code.strings[i]));
		pr(code.bytes.length + " bytes");
		for (i in 0...code.bytes.length) pr("\t@" + i + " : " + code.bytes[i].length);
		pr(code.ints.length + " ints");
		for (i in 0...code.ints.length) pr("\t@" + i + " : " + code.ints[i]);
		pr(code.floats.length + " floats");
		for (i in 0...code.floats.length) pr("\t@" + i + " : " + core.Numeric.stringOfFloat(code.floats[i]));
		pr(code.globals.length + " globals");
		for (i in 0...code.globals.length) pr("\t@" + i + " : " + tstr(code.globals[i]));
		pr(code.natives.length + " natives");
		for (n in code.natives) {
			pr("\t@" + n.findex + " native " + str(n.lib) + "@" + str(n.name) + " " + tstr(n.t));
			// port: Hashtbl.add; find returns the most recent binding
			funnames.set(n.findex, str(n.lib) + "@" + str(n.name));
		}
		for (f in code.functions) funnames.set(f.findex, fundeclName(f));
		pr(code.functions.length + " functions");
		for (f in code.functions) {
			pr('\tfun@${f.findex}(${hex(f.findex)}h) ${tstr(f.ftype)}');
			var curFid = f.debug[0].file;
			pr('\t; ${debugInfos(f.debug[0])} (${fundeclName(f)})');
			for (i in 0...f.regs.length) pr("\t\tr" + i + " " + tstr(f.regs[i]));
			for (i in 0...f.code.length) {
				var d = f.debug[i];
				if (d.file != curFid) {
					curFid = d.file;
					pr('\t; ${debugInfos(d)}');
				}
				pr("\t\t." + padRight(Std.string(d.line), 5) + " @" + hex(i) + " " + ostr(fstr, f.code[i]));
			}
		}
		var protos = allProtos.fold((_, p, acc:Array<ClassProto>) -> {
			acc.unshift(p);
			acc;
		}, []);
		pr(protos.length + " objects protos");
		for (p in protos) {
			pr("\t" + p.pname + " " + (p.pclassglobal == null ? "no global" : "@" + p.pclassglobal));
			if (p.psuper != null) pr("\t\textends " + p.psuper.pname);
			pr("\t\t" + p.pfields.length + " fields");
			function loop(p:Null<ClassProto>):Int return p == null ? 0 : p.pfields.length + loop(p.psuper);
			var startField = loop(p.psuper);
			for (i in 0...p.pfields.length) {
				var f = p.pfields[i];
				pr("\t\t  @" + (i + startField) + " " + str(f.nid) + " " + tstr(f.t));
			}
			pr("\t\t" + p.pproto.length + " methods");
			for (i in 0...p.pproto.length) {
				var f = p.pproto[i];
				pr("\t\t  @" + i + " " + str(f.fid) + " fun@" + f.fmethod + (f.fvirtual == null ? "" : "[" + f.fvirtual + "]"));
			}
			pr("\t\t" + p.pbindings.length + " bindings");
			for (b in p.pbindings) pr("\t\t  @" + b.fid + " fun@" + b.fidx);
		}
		pr(code.constants.length + " constant values");
		for (c in code.constants) pr('    @${c.g} ${tstr(code.globals[c.g])} [${[for (f in c.fields) Std.string(f)].join(",")}]');
	}

	// --------------------------------------------------------------------------------------------
	// port: OCaml runtime helpers used by the HL modules.

	public static inline function mul32(a:Int, b:Int):Int return ((a & 0xFFFF) * b + ((((a >>> 16) * b) & 0xFFFF) << 16)) | 0;

	public static function forAll2<A, B>(f:A->B->Bool, a:Array<A>, b:Array<B>):Bool {
		if (a.length != b.length) throw new core.ds.InvalidArgument("List.for_all2");
		for (i in 0...a.length) if (!f(a[i], b[i])) return false;
		return true;
	}

	// port: `Printf "%X"` (with an optional zero-padded width)
	public static function hex(v:Int, width:Int = 0):String {
		var s = StringTools.hex(v);
		while (s.length < width) s = "0" + s;
		return s;
	}

	static function padRight(s:String, n:Int):String {
		while (s.length < n) s += " ";
		return s;
	}

	// port: OCaml `String.escaped`, on the UTF-8 bytes of `s`.
	public static function ocamlEscaped(s:String):String {
		var b = haxe.io.Bytes.ofString(s);
		var buf = new StringBuf();
		for (i in 0...b.length) {
			var c = b.get(i);
			switch c {
				case '"'.code:
					buf.add("\\\"");
				case '\\'.code:
					buf.add("\\\\");
				case '\n'.code:
					buf.add("\\n");
				case '\t'.code:
					buf.add("\\t");
				case '\r'.code:
					buf.add("\\r");
				case 8:
					buf.add("\\b");
				case _ if (c >= 32 && c <= 126):
					buf.addChar(c);
				case _:
					buf.add("\\");
					var d = Std.string(c);
					while (d.length < 3) d = "0" + d;
					buf.add(d);
			}
		}
		return buf.toString();
	}

	// port: the OCaml `ttype` value layout: constant constructors are immediates
	// (their index among constant constructors), the others are blocks (tag = index
	// among non-constant constructors).
	public static function constIndex(t:Ttype):Int {
		return switch t {
			case HVoid: 0;
			case HUI8: 1;
			case HUI16: 2;
			case HI32: 3;
			case HI64: 4;
			case HF32: 5;
			case HF64: 6;
			case HBool: 7;
			case HBytes: 8;
			case HDyn: 9;
			case HType: 10;
			case HDynObj: 11;
			case HGUID: 12;
			case _: -1;
		}
	}

	public static function blockTag(t:Ttype):Int {
		return switch t {
			case HFun(_): 0;
			case HObj(_): 1;
			case HArray(_): 2;
			case HRef(_): 3;
			case HVirtual(_): 4;
			case HAbstract(_): 5;
			case HEnum(_): 6;
			case HNull(_): 7;
			case HMethod(_): 8;
			case HStruct(_): 9;
			case HPacked(_): 10;
			case _: -1;
		}
	}

	// port: OCaml structural equality on ttype (`=`, `compare = 0`, PMap/Hashtbl keys).
	// Pairs already being compared count as equal, where OCaml would not terminate.
	public static function tEq(a:Ttype, b:Ttype):Bool return a == b || new TtypeEq().eq(a, b);

	// port: a hash consistent with tEq, for the port's TtypeMap (never reaches output).
	public static function tHash(t:Ttype):Int return hashRec(t, 4);

	static function hashRec(t:Ttype, depth:Int):Int {
		var c = constIndex(t);
		if (c >= 0) return c;
		var h = 31 + blockTag(t) * 17;
		if (depth == 0) return h;
		inline function mix(x:Int):Void h = (mul32(h, 31) + x) | 0;
		switch t {
			case HFun(args, ret) | HMethod(args, ret):
				mix(args.length);
				for (a in args) mix(hashRec(a, depth - 1));
				mix(hashRec(ret, depth - 1));
			case HObj(p) | HStruct(p):
				mix(strHash(p.pname));
			case HArray(t) | HRef(t) | HNull(t) | HPacked(t):
				mix(hashRec(t, depth - 1));
			case HVirtual(v):
				mix(v.vfields.length);
				for (f in v.vfields) mix(strHash(f.name));
			case HAbstract(name, idx, _):
				mix(strHash(name));
				mix(idx);
			case HEnum(e):
				mix(strHash(e.ename));
				mix(e.efields.length);
				// port: the tuples of Genhl.tupleType (closure contexts) are all
				// named "": their argument types tell them apart (set at creation)
				if (e.ename == "") for (f in e.efields) {
					mix(f.args.length);
					for (a in f.args) mix(hashRec(a, depth - 1));
				}
			case _:
		}
		return h;
	}

	static function strHash(s:String):Int {
		var h = 7;
		for (i in 0...s.length) h = (mul32(h, 31) + StringTools.fastCodeAt(s, i)) | 0;
		return h;
	}

	// port: OCaml `compare` order on strings (bytes, then length); code point order
	// matches the order of the UTF-8 encodings.
	public static function strCompare(a:String, b:String):Int return core.ds.Key.compareStrings(a, b);

	// port: OCaml `compare` order on ttype; records with the same name compare equal
	// beyond their name (protos are unique per name), PMaps are not inspected.
	public static function tCompare(a:Ttype, b:Ttype):Int {
		if (a == b) return 0;
		var c1 = constIndex(a), c2 = constIndex(b);
		if (c1 >= 0 || c2 >= 0) {
			if (c1 >= 0 && c2 >= 0) return c1 < c2 ? -1 : (c1 > c2 ? 1 : 0);
			return c1 >= 0 ? -1 : 1;
		}
		var t1 = blockTag(a), t2 = blockTag(b);
		if (t1 != t2) return t1 < t2 ? -1 : 1;
		inline function icmp(x:Int, y:Int):Int return x < y ? -1 : (x > y ? 1 : 0);
		function listCmp(l1:Array<Ttype>, l2:Array<Ttype>):Int {
			var i = 0;
			while (true) {
				if (i == l1.length && i == l2.length) return 0;
				if (i == l1.length) return -1;
				if (i == l2.length) return 1;
				var c = tCompare(l1[i], l2[i]);
				if (c != 0) return c;
				i++;
			}
		}
		function fieldsCmp(f1:Array<HField>, f2:Array<HField>):Int {
			if (f1.length != f2.length) return icmp(f1.length, f2.length);
			for (i in 0...f1.length) {
				var c = strCompare(f1[i].name, f2[i].name);
				if (c != 0) return c;
				c = icmp(f1[i].nid, f2[i].nid);
				if (c != 0) return c;
				c = tCompare(f1[i].t, f2[i].t);
				if (c != 0) return c;
			}
			return 0;
		}
		return switch [a, b] {
			case [HFun(a1, r1), HFun(a2, r2)] | [HMethod(a1, r1), HMethod(a2, r2)]:
				var c = listCmp(a1, a2);
				c != 0 ? c : tCompare(r1, r2);
			case [HObj(p1), HObj(p2)] | [HStruct(p1), HStruct(p2)]:
				p1 == p2 ? 0 : strCompare(p1.pname, p2.pname);
			case [HArray(x), HArray(y)] | [HRef(x), HRef(y)] | [HNull(x), HNull(y)] | [HPacked(x), HPacked(y)]:
				tCompare(x, y);
			case [HVirtual(v1), HVirtual(v2)]:
				v1 == v2 ? 0 : fieldsCmp(v1.vfields, v2.vfields);
			case [HAbstract(n1, i1, _), HAbstract(n2, i2, _)]:
				var c = strCompare(n1, n2);
				c != 0 ? c : icmp(i1, i2);
			case [HEnum(e1), HEnum(e2)]:
				if (e1 == e2) 0 else {
					var c = strCompare(e1.ename, e2.ename);
					if (c == 0) c = icmp(e1.eid, e2.eid);
					if (c == 0) c = if (e1.eglobal == null) (e2.eglobal == null ? 0 : -1) else if (e2.eglobal == null) 1 else icmp(e1.eglobal, e2.eglobal);
					if (c == 0) c = icmp(e1.efields.length, e2.efields.length);
					var i = 0;
					while (c == 0 && i < e1.efields.length) {
						var f1 = e1.efields[i], f2 = e2.efields[i];
						c = strCompare(f1.name, f2.name);
						if (c == 0) c = icmp(f1.nid, f2.nid);
						if (c == 0) c = icmp(f1.args.length, f2.args.length);
						var j = 0;
						while (c == 0 && j < f1.args.length) {
							c = tCompare(f1.args[j], f2.args[j]);
							j++;
						}
						i++;
					}
					c;
				}
			case _: 0;
		}
	}

	// port: stdlib/array.ml `sort` (heap sort), whose order on ties the output reflects.
	public static function ocamlArraySort<T>(cmp:T->T->Int, a:Array<T>):Void {
		inline function maxson(l:Int, i:Int):Int {
			var i31 = i + i + i + 1;
			var x = i31;
			if (i31 + 2 < l) {
				if (cmp(a[i31], a[i31 + 1]) < 0) x = i31 + 1;
				if (cmp(a[x], a[i31 + 2]) < 0) x = i31 + 2;
				return x;
			} else if (i31 + 1 < l && cmp(a[i31], a[i31 + 1]) < 0) {
				return i31 + 1;
			} else if (i31 < l) {
				return i31;
			} else {
				return -1 - i; // port: `raise (Bottom i)`
			}
		}
		function trickle(l:Int, i:Int, e:T):Void {
			while (true) {
				var j = maxson(l, i);
				if (j < 0) {
					a[-1 - j] = e;
					return;
				}
				if (cmp(a[j], e) > 0) {
					a[i] = a[j];
					i = j;
				} else {
					a[i] = e;
					return;
				}
			}
		}
		function bubble(l:Int, i:Int):Int {
			while (true) {
				var j = maxson(l, i);
				if (j < 0) return -1 - j;
				a[i] = a[j];
				i = j;
			}
		}
		function trickleup(i:Int, e:T):Void {
			while (true) {
				var father = Std.int((i - 1) / 3);
				if (i == father) throw new haxe.Exception("Assert_failure");
				if (cmp(a[father], e) < 0) {
					a[i] = a[father];
					if (father > 0) {
						i = father;
					} else {
						a[0] = e;
						return;
					}
				} else {
					a[i] = e;
					return;
				}
			}
		}
		var l = a.length;
		var i = Std.int((l + 1) / 3) - 1;
		while (i >= 0) {
			trickle(l, i, a[i]);
			i--;
		}
		var i = l - 1;
		while (i >= 2) {
			var e = a[i];
			a[i] = a[0];
			trickleup(bubble(i, 0), e);
			i--;
		}
		if (l > 1) {
			var e = a[1];
			a[1] = a[0];
			a[0] = e;
		}
	}

	// port: `List.sort`/`List.stable_sort` (a stable merge sort) on a copy.
	public static function listSort<T>(cmp:T->T->Int, l:Array<T>):Array<T> {
		var a = l.copy();
		haxe.ds.ArraySort.sort(a, cmp);
		return a;
	}
}

// port: OCaml structural equality with a guard against cycles.
private class TtypeEq {
	var stack:Array<Dynamic> = [];

	public function new() {}

	function inStack(a:Dynamic, b:Dynamic):Bool {
		var i = 0;
		while (i < stack.length) {
			if (stack[i] == a && stack[i + 1] == b) return true;
			i += 2;
		}
		return false;
	}

	public function eq(a:Ttype, b:Ttype):Bool {
		if (a == b) return true;
		return switch [a, b] {
			case [HFun(a1, r1), HFun(a2, r2)] | [HMethod(a1, r1), HMethod(a2, r2)]:
				if (a1.length != a2.length) false else {
					var ok = true;
					for (i in 0...a1.length) if (!eq(a1[i], a2[i])) {
						ok = false;
						break;
					}
					ok && eq(r1, r2);
				}
			case [HObj(p1), HObj(p2)] | [HStruct(p1), HStruct(p2)]: protoEq(p1, p2);
			case [HArray(x), HArray(y)] | [HRef(x), HRef(y)] | [HNull(x), HNull(y)] | [HPacked(x), HPacked(y)]: eq(x, y);
			case [HVirtual(v1), HVirtual(v2)]:
				if (v1 == v2) true else if (inStack(v1, v2)) true else {
					stack.push(v1);
					stack.push(v2);
					var r = fieldsEq(v1.vfields, v2.vfields);
					stack.pop();
					stack.pop();
					r;
				}
			case [HAbstract(n1, i1, _), HAbstract(n2, i2, _)]: n1 == n2 && i1 == i2;
			case [HEnum(e1), HEnum(e2)]:
				if (e1 == e2) true else if (e1.ename != e2.ename || e1.eid != e2.eid || e1.eglobal != e2.eglobal
					|| e1.efields.length != e2.efields.length) false else if (inStack(e1, e2)) true else {
					stack.push(e1);
					stack.push(e2);
					var ok = true;
					for (i in 0...e1.efields.length) {
						var f1 = e1.efields[i], f2 = e2.efields[i];
						if (f1.name != f2.name || f1.nid != f2.nid || f1.args.length != f2.args.length) {
							ok = false;
							break;
						}
						for (j in 0...f1.args.length) if (!eq(f1.args[j], f2.args[j])) {
							ok = false;
							break;
						}
						if (!ok) break;
					}
					stack.pop();
					stack.pop();
					ok;
				}
			case _: Hlcode.constIndex(a) >= 0 && Hlcode.constIndex(a) == Hlcode.constIndex(b);
		}
	}

	function fieldsEq(f1:Array<HField>, f2:Array<HField>):Bool {
		if (f1.length != f2.length) return false;
		for (i in 0...f1.length) if (f1[i].name != f2[i].name || f1[i].nid != f2[i].nid || !eq(f1[i].t, f2[i].t)) return false;
		return true;
	}

	function protoEq(p1:ClassProto, p2:ClassProto):Bool {
		if (p1 == p2) return true;
		if (p1.pname != p2.pname || p1.pid != p2.pid || p1.pclassglobal != p2.pclassglobal || p1.pnfields != p2.pnfields) return false;
		if (inStack(p1, p2)) return true;
		stack.push(p1);
		stack.push(p2);
		var r = if (p1.psuper == null) p2.psuper == null else p2.psuper != null && protoEq(p1.psuper, p2.psuper);
		if (r && p1.pvirtuals.length != p2.pvirtuals.length) r = false;
		if (r) for (i in 0...p1.pvirtuals.length)
			if (p1.pvirtuals[i] != p2.pvirtuals[i]) {
				r = false;
				break;
			}
		if (r && p1.pproto.length != p2.pproto.length) r = false;
		if (r) for (i in 0...p1.pproto.length) {
			var a = p1.pproto[i], b = p2.pproto[i];
			if (a.fname != b.fname || a.fid != b.fid || a.fmethod != b.fmethod || a.fvirtual != b.fvirtual) {
				r = false;
				break;
			}
		}
		if (r && !fieldsEq(p1.pfields, p2.pfields)) r = false;
		if (r && p1.pbindings.length != p2.pbindings.length) r = false;
		if (r) for (i in 0...p1.pbindings.length)
			if (p1.pbindings[i].fid != p2.pbindings[i].fid || p1.pbindings[i].fidx != p2.pbindings[i].fidx) {
				r = false;
				break;
			}
		stack.pop();
		stack.pop();
		return r;
	}
}

// port: a map keyed by ttype under OCaml structural equality (PMap/Hashtbl keys
// whose iteration order never reaches the output). `keys` lists insertion order.
class TtypeMap<V> {
	final buckets:haxe.ds.IntMap<Array<{k:Ttype, v:V}>> = new haxe.ds.IntMap();

	public final keys:Array<Ttype> = [];

	public function new() {}

	function find(t:Ttype):Null<{k:Ttype, v:V}> {
		var b = buckets.get(Hlcode.tHash(t));
		if (b == null) return null;
		for (e in b) if (Hlcode.tEq(e.k, t)) return e;
		return null;
	}

	public function get(t:Ttype):Null<V> {
		var e = find(t);
		return e == null ? null : e.v;
	}

	public function exists(t:Ttype):Bool return find(t) != null;

	// port: the key a binding holds (PMap.add stores the key of the latest add).
	public function keyOf(t:Ttype):Null<Ttype> {
		var e = find(t);
		return e == null ? null : e.k;
	}

	public function set(t:Ttype, v:V):Void {
		var e = find(t);
		if (e != null) {
			e.k = t;
			e.v = v;
			return;
		}
		var h = Hlcode.tHash(t);
		var b = buckets.get(h);
		if (b == null) {
			b = [];
			buckets.set(h, b);
		}
		b.push({k: t, v: v});
		keys.push(t);
	}
}
