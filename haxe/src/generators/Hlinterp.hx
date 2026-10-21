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

import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.Int64;
import haxe.ds.IntMap;
import haxe.ds.Vector;
import core.Globals;
import core.ds.Failure;
import core.ds.InvalidArgument;
import core.ds.NotFound;
import core.ds.OcamlHash;
import core.ds.OcamlHashtbl;
import core.ds.OcamlStr;
import core.ds.VectorTools;
import core.ds.VectorTools.vector;
import generators.Hlcode;
import generators.Hlcode.*;

using core.ds.VectorTools;

// port: OCaml values are compared with `==` (physical equality) in a few places; a Haxe
// ... `==` on two `Value`s compares the enum instances by reference, which is the same thing
// ... since every constructor application allocates.
enum Value {
	VNull;
	VInt(i:Int); // port: int32
	VInt64(i:Int64);
	VFloat(f:Float);
	VBool(b:Bool);
	VDyn(v:Value, t:Ttype);
	VObj(o:Vobject);
	VClosure(f:Vfunction, v:Null<Value>); // port: `value option`, None is null
	VBytes(b:Bytes); // port: the (mutated in place) OCaml string
	VArray(a:Vector<Value>, t:Ttype);
	VUndef;
	VType(t:Ttype);
	VRef(r:RefValue, t:Ttype);
	VVirtual(v:Vvirtual);
	VDynObj(d:Vdynobj);
	VEnum(e:EnumProto, i:Int, vals:Vector<Value>);
	VAbstract(a:Vabstract);
	VVarArgs(f:Vfunction, v:Null<Value>);
	VStruct(o:Vobject);
}

class ValueRef {
	public var v:Value;

	public function new(v:Value) this.v = v;
}

enum RefValue {
	RStack(i:Int);
	RValue(r:ValueRef);
	RArray(a:Vector<Value>, i:Int);
}

// port: `(value * value) list ref`, head first
class HashObject {
	public var l:Array<{k:Value, v:Value}> = [];

	public function new() {}
}

enum Vabstract {
	AHashBytes(h:OcamlHashtbl<String, Value>);
	AHashInt(h:OcamlHashtbl<Int, Value>);
	AHashObject(l:HashObject);
	AReg(r:Regexp);
	ARandom;
	APos(p:Pos);
	ATDecl(t:core.TType.ModuleType);
	AUnsafe(o:Dynamic);
	ALazyType(r:{v:Void->core.TType.T}, f:Void->Value);
}

enum Vfunction {
	FFun(f:Fundecl);
	FNativeFun(name:String, f:Array<Value>->Value, t:Ttype);
}

class Vobject {
	public final oproto:Vproto;
	public final ofields:Vector<Value>;

	public function new(oproto, ofields) {
		this.oproto = oproto;
		this.ofields = ofields;
	}
}

class Vproto {
	public final pclass:ClassProto;
	public final pmethods:Vector<Vfunction>;

	public function new(pclass, pmethods) {
		this.pclass = pclass;
		this.pmethods = pmethods;
	}
}

class Vvirtual {
	public final vtype:VirtualProto;
	public var vindexes:Vector<Vfield>;
	public var vtable:Vector<Value>;
	public var vvalue:Value;

	public function new(vtype, vindexes, vtable, vvalue) {
		this.vtype = vtype;
		this.vindexes = vindexes;
		this.vtable = vtable;
		this.vvalue = vvalue;
	}
}

class Vdynobj {
	public final dfields:OcamlHashtbl<String, Int>;
	public var dtypes:Vector<Ttype>;
	public var dvalues:Vector<Value>;
	public var dvirtuals:Array<Vvirtual>; // port: list, head first

	public function new(dfields, dtypes, dvalues, dvirtuals) {
		this.dfields = dfields;
		this.dtypes = dtypes;
		this.dvalues = dvalues;
		this.dvirtuals = dvirtuals;
	}
}

enum Vfield {
	VFNone;
	VFIndex(i:Int);
}

class Regexp {
	public final r:OcamlStrRegexp;
	public var rString:String;
	public var rGroups:Vector<Null<{start:Int, end:Int}>>;

	public function new(r, rString, rGroups) {
		this.r = r;
		this.rString = rString;
		this.rGroups = rGroups;
	}
}

// port: `exception Return of value` is not needed: `interp` returns from its loop.
class RuntimeError extends haxe.Exception {}

class InterpThrow extends haxe.Exception {
	public final v:Value;

	public function new(v:Value) {
		super("InterpThrow");
		this.v = v;
	}
}

class SysExit extends haxe.Exception {
	public final code:Int;

	public function new(code:Int) {
		super("Sys_exit");
		this.code = code;
	}
}

class IntRef {
	public var v:Int;

	public function new(v:Int) this.v = v;
}

// port: a `(fundecl * int ref) list` cell; null is the empty list.
class Frames {
	public final f:Fundecl;
	public final pos:IntRef;
	public final next:Null<Frames>;

	public function new(f, pos, next) {
		this.f = f;
		this.pos = pos;
		this.next = next;
	}

	public static function rev(l:Null<Frames>):Null<Frames> {
		var acc:Null<Frames> = null;
		while (l != null) {
			acc = new Frames(l.f, l.pos, acc);
			l = l.next;
		}
		return acc;
	}

	public static function append(a:Null<Frames>, b:Null<Frames>):Null<Frames> {
		if (a == null) return b;
		var items = toArray(a);
		var acc = b;
		var i = items.length;
		while (i-- > 0) acc = new Frames(items[i].f, items[i].pos, acc);
		return acc;
	}

	public static function toArray(l:Null<Frames>):Array<Frames> {
		var a = [];
		while (l != null) {
			a.push(l);
			l = l.next;
		}
		return a;
	}

	public static function tl(l:Null<Frames>):Null<Frames> {
		if (l == null) throw new Failure("tl");
		return l.next;
	}
}

class ProtoEntry {
	public final proto:Vproto;
	public final fields:Vector<Ttype>;
	public final bindings:Array<{fid:Int, mk:Value->Value}>; // port: list, head first

	public function new(proto, fields, bindings) {
		this.proto = proto;
		this.fields = fields;
		this.bindings = bindings;
	}
}

class InterpContext {
	public var tGlobals:Vector<Value>;
	public var tFunctions:Vector<Vfunction>;
	public var callStack:Null<Frames>;
	public var errorStack:Null<Frames>;
	public var stack:Vector<Value>;
	public var stackPos:Int;
	public var fcall:Vfunction->Array<Value>->Value;
	public var code:Code;
	public var onError:Value->Null<Frames>->Void;
	public final checked:Bool;
	public final cachedProtos:IntMap<ProtoEntry>;
	public final cachedStrings:IntMap<Bytes>;
	public final cachedHashes:IntMap<String>;

	public function new(checked:Bool) {
		this.checked = checked;
		tGlobals = vector();
		tFunctions = vector();
		callStack = null;
		errorStack = null;
		stack = vector();
		stackPos = 0;
		cachedProtos = new IntMap();
		cachedStrings = new IntMap();
		cachedHashes = new IntMap();
	}
}

private enum Cast {
	CNo;
	CDyn(t:Ttype);
	CUnDyn(t:Ttype);
	CCast(t1:Ttype, t2:Ttype);
}

// port: UCharExt.Out_of_range
private class OutOfRange extends haxe.Exception {}

class Hlinterp {
	static inline function die():Dynamic return Globals.die("", "hlinterp.ml");

	// port: OCaml `a.(i)`: Invalid_argument "index out of bounds" outside the array
	static inline function aget<T>(a:Vector<T>, i:Int):T {
		if (i < 0 || i >= a.length) throw new InvalidArgument("index out of bounds");
		return a[i];
	}

	static inline function aset<T>(a:Vector<T>, i:Int, v:T):Void {
		if (i < 0 || i >= a.length) throw new InvalidArgument("index out of bounds");
		a[i] = v;
	}

	// port: OCaml `s.[i]` / `Bytes.get` on the bytes of a string
	static inline function bget(b:Bytes, i:Int):Int {
		if (i < 0 || i >= b.length) throw new InvalidArgument("index out of bounds");
		return b.get(i);
	}

	static inline function bset(b:Bytes, i:Int, v:Int):Void {
		if (i < 0 || i >= b.length) throw new InvalidArgument("index out of bounds");
		b.set(i, v);
	}

	// port: OCaml `String.sub` / `Bytes.sub`
	static function bsub(b:Bytes, pos:Int, len:Int):Bytes {
		if (pos < 0 || len < 0 || pos > b.length - len) throw new InvalidArgument("String.sub / Bytes.sub");
		return b.sub(pos, len);
	}

	// port: OCaml string literals and results are UTF-8 Haxe strings; their OCaml
	// ... `String.length` is their UTF-8 byte length.
	static inline function camlLength(s:String):Int return Bytes.ofString(s).length;

	// port: OCaml `Int32.of_float`: a C cast (out-of-range values and nan give
	// ... 0x80000000 on x86-64)
	static function int32OfFloat(f:Float):Int {
		if (Math.isNaN(f) || f >= 2147483648.0 || f <= -2147483649.0) return 0x80000000;
		return Std.int(f);
	}

	static inline function i32Add(a:Int, b:Int):Int return (a + b) | 0;

	static inline function i32Sub(a:Int, b:Int):Int return (a - b) | 0;

	static inline function i32Mul(a:Int, b:Int):Int return ((a & 0xFFFF) * b + ((((a >>> 16) * b) & 0xFFFF) << 16)) | 0;

	// port: Int32.div (truncated; min_int / -1 = min_int)
	static function i32Div(a:Int, b:Int):Int {
		if (b == 0) throw new haxe.Exception("Division_by_zero");
		if (b == -1) return (-a) | 0;
		return Std.int(a / b);
	}

	// port: Int32.rem (sign of the dividend)
	static function i32Rem(a:Int, b:Int):Int {
		if (b == 0) throw new haxe.Exception("Division_by_zero");
		if (b == -1) return 0;
		return a % b;
	}

	// port: native OCaml shifts of an int32 by `Int32.to_int b`: the count is taken
	// ... modulo 64 on the sign- (or zero-, for lsr) extended 64-bit value.
	static function i32Shl(a:Int, b:Int):Int {
		var n = b & 63;
		return n >= 32 ? 0 : a << n;
	}

	static function i32Shr(a:Int, b:Int):Int {
		var n = b & 63;
		return n >= 32 ? (a < 0 ? -1 : 0) : a >> n;
	}

	static function i32Ushr(a:Int, b:Int):Int {
		var n = b & 63;
		return n >= 32 ? 0 : a >>> n;
	}

	static inline function i32Compare(a:Int, b:Int):Int return a < b ? -1 : (a > b ? 1 : 0);

	// port: OCaml `Hashtbl.hash` of an int32 (a custom block: caml_hash_mix_uint32 of its
	// ... value, then the final mix)
	static function hashInt32(n:Int):Int {
		inline function mul32(a:Int, b:Int):Int return ((a & 0xFFFF) * b + ((((a >>> 16) * b) & 0xFFFF) << 16)) | 0;
		inline function rotl32(x:Int, n:Int):Int return (x << n) | (x >>> (32 - n));
		var d = mul32(n, 0xcc9e2d51);
		d = rotl32(d, 15);
		d = mul32(d, 0x1b873593);
		var h = 0 ^ d;
		h = rotl32(h, 13);
		h = (mul32(h, 5) + 0xe6546b64) | 0;
		h ^= h >>> 16;
		h = mul32(h, 0x85ebca6b);
		h ^= h >>> 13;
		h = mul32(h, 0xc2b2ae35);
		h ^= h >>> 16;
		return h & 0x3FFFFFFF;
	}

	static function newStringHashtbl<V>():OcamlHashtbl<String, V> return new OcamlHashtbl<String, V>(OcamlHash.hashString, (a, b) -> a == b);

	static function newIntHashtbl<V>():OcamlHashtbl<Int, V> return new OcamlHashtbl<Int, V>(hashInt32, (a, b) -> a == b);

	public static function defaultValue(t:Ttype):Value {
		return switch getGroup(t) {
			case GInt:
				if (typeSizeBits(t) <= 2) VInt(0) else VInt64(Int64.ofInt(0));
			case GFloat: VFloat(0.);
			case GBool: VBool(false);
			case _: if (isNullable(t)) VNull else VUndef;
		}
	}

	public static function getType(v:Value):Null<Ttype> {
		return switch v {
			case VDyn(_, t): t;
			case VObj(o): HObj(o.oproto.pclass);
			case VDynObj(_): HDynObj;
			case VVirtual(v): HVirtual(v.vtype);
			case VArray(_, t): HArray(t);
			case VClosure(f, null): switch f {
					case FFun(f): f.ftype;
					case FNativeFun(_, _, t): t;
				}
			case VClosure(f, _):
				var t = switch f {
					case FFun(f): f.ftype;
					case FNativeFun(_, _, t): t;
				}
				switch t {
					case HFun(args, ret) if (args.length > 0): HFun(args.slice(1), ret);
					case _: die();
				}
			case VVarArgs(_): HFun([], HDyn);
			case VEnum(e, _, _): HEnum(e);
			case _: null;
		}
	}

	static function vDynamic(v:Value):Bool {
		return switch v {
			case VNull | VDyn(_) | VObj(_) | VClosure(_) | VArray(_) | VVirtual(_) | VDynObj(_) | VVarArgs(_) | VEnum(_): true;
			case _: false;
		}
	}

	static function isCompatible(v:Value, t:Ttype):Bool {
		var g = getGroup(t);
		switch [v, g] {
			case [VInt(_), GInt]:
				return typeSizeBits(t) <= 2;
			case [VInt64(_), GInt]:
				return typeSizeBits(t) == 3;
			case [VFloat(_), GFloat]:
				return true;
			case [VBool(_), GBool]:
				return true;
			case _:
		}
		if (t.match(HVoid)) return true;
		return switch [v, t] {
			case [VNull, _]: isNullable(t);
			case [VObj(o), HObj(_)]: safeCast(HObj(o.oproto.pclass), t);
			case [VClosure(_), HFun(_)]: safeCast(switch getType(v) {
					case null: die();
					case t: t;
				}, t);
			case [VBytes(_), HBytes]: true;
			case [VDyn(_, t1), HNull(ti)]: tsame(t1, ti);
			case [v, HNull(ti)]: isCompatible(v, ti);
			case [v, HDyn]: vDynamic(v);
			case [VType(_), HType]: true;
			case [VArray(_), HArray(_)]: true;
			case [VDynObj(_), HDynObj]: true;
			case [VVirtual(v), HVirtual(_)]: safeCast(HVirtual(v.vtype), t);
			case [VRef(_, t1), HRef(t2)]: tsame(t1, t2);
			case [VAbstract(_), HAbstract(_)]: true;
			case [VEnum(_), HEnum(_)]: true;
			case [VStruct(v), HStruct(_)]: safeCast(HStruct(v.oproto.pclass), t);
			case _: false;
		}
	}

	static function error(msg:String):Dynamic throw new RuntimeError(msg);

	static inline function getFunction(ctx:InterpContext, f:Int):Vfunction return aget(ctx.tFunctions, f);

	static function getProto(ctx:InterpContext, p:ClassProto):ProtoEntry {
		var cached = ctx.cachedProtos.get(p.pid);
		if (cached != null) return cached;
		var fields:Vector<Ttype>, bindings:Array<{fid:Int, mk:Value->Value}>;
		if (p.psuper == null) {
			fields = vector();
			bindings = [];
		} else {
			var e = getProto(ctx, p.psuper);
			fields = e.fields;
			bindings = e.bindings;
		}
		var meths = p.pvirtuals.map(i -> getFunction(ctx, i));
		var fields = fields.concat(p.pfields.map(f -> f.t));
		var bindings = {
			var acc = bindings;
			for (b in p.pbindings) {
				var fid = b.fid;
				var f = getFunction(ctx, b.fidx);
				var ft = switch f {
					case FFun(f): f.ftype;
					case FNativeFun(_): die();
				}
				var needClosure = switch [ft, aget(fields, fid)] {
					case [HFun(args, _), HFun(args2, _)]: args.length > args2.length;
					case [HFun(_), HDyn]: false;
					case _: die();
				}
				acc = [{fid: fid, mk: (v:Value) -> VClosure(f, if (needClosure) v else null)}].concat(acc.filter(b2 -> b2.fid != fid));
			}
			acc;
		}
		var proto = new ProtoEntry(new Vproto(p, meths), fields, bindings);
		ctx.cachedProtos.set(p.pid, proto);
		return proto;
	}

	static function allocObj(ctx:InterpContext, t:Ttype):Value {
		switch t {
			case HDynObj:
				return VDynObj(new Vdynobj(newStringHashtbl(), vector(), vector(), []));
			case HObj(p):
				var e = getProto(ctx, p);
				var ftable = e.fields.map(t -> defaultValue(t));
				var obj = VObj(new Vobject(e.proto, ftable));
				for (b in e.bindings) aset(ftable, b.fid, b.mk(obj));
				return obj;
			case HStruct(p):
				var e = getProto(ctx, p);
				var ftable = e.fields.map(t -> defaultValue(t));
				return VStruct(new Vobject(e.proto, ftable));
			case HVirtual(v):
				var o = new Vdynobj(newStringHashtbl(), v.vfields.map(f -> f.t), v.vfields.map(f -> defaultValue(f.t)), []);
				for (i in 0...v.vfields.length) o.dfields.add(v.vfields[i].name, i);
				var vv = new Vvirtual(v, v.vfields.mapi((i, _) -> VFIndex(i)), o.dvalues, VDynObj(o));
				o.dvirtuals = [vv];
				return VVirtual(vv);
			case _:
				return die();
		}
	}

	// port: OCaml's `nan` (0x7FF8_0000_0000_0001, positive), unlike the host's 0/0
	static final ocamlNan:Float = haxe.io.FPHelper.i64ToDouble(1, 0x7FF80000);

	// port: OCaml `string_of_float`; printf prints a nan with its sign bit set as "-nan"
	static function stringOfFloat(f:Float):String {
		if (Math.isNaN(f)) return if (haxe.io.FPHelper.doubleToI64(f).high < 0) "-nan" else "nan";
		return core.Numeric.stringOfFloat(f);
	}

	static function floatToString(f:Float):String {
		var s = stringOfFloat(f);
		var len = s.length;
		return if (s.charCodeAt(len - 1) == '.'.code) s.substr(0, len - 1) else s;
	}

	static function getMethod(p:ClassProto, name:String):Null<Int> {
		var m:Null<Int> = null;
		for (p in p.pproto) if (p.fname == name) m = p.fmethod;
		return if (m != null) m else if (p.psuper != null) getMethod(p.psuper, name) else null;
	}

	static function getToString(ctx:InterpContext, p:ClassProto):Null<Vfunction> {
		var f = getMethod(p, "__string");
		if (f == null) return null;
		var fn = getFunction(ctx, f);
		return switch fn {
			case FFun({ftype: HFun([_], HBytes)}): fn;
			case _: null;
		}
	}

	static function setI32(b:Bytes, p:Int, v:Int):Void {
		try {
			bset(b, p, v & 0xFF);
			bset(b, p + 1, (v >>> 8) & 0xFF);
			bset(b, p + 2, (v >>> 16) & 0xFF);
			bset(b, p + 3, v >>> 24);
		} catch (_:Dynamic) {
			error("Set outside of bytes bounds");
		}
	}

	static function setI64(b:Bytes, p:Int, v:Int64):Void {
		setI32(b, p, v.low);
		setI32(b, p + 4, v.high);
	}

	static function getI32(b:Bytes, p:Int):Int {
		var i = bget(b, p);
		var j = bget(b, p + 1);
		var k = bget(b, p + 2);
		var l = bget(b, p + 3);
		return i | (j << 8) | (k << 16) | (l << 24);
	}

	static function getI64(b:Bytes, p:Int):Int64 {
		var low = getI32(b, p);
		var high = getI32(b, p + 4);
		return Int64.make(high, low);
	}

	static function makeDyn(v:Value, t:Ttype):Value {
		return if (v.match(VNull) || isDynamic(t)) v else VDyn(v, t);
	}

	static function getRef(ctx:InterpContext, r:RefValue):Value {
		return switch r {
			case RStack(i): aget(ctx.stack, i);
			case RValue(r): r.v;
			case RArray(a, i): aget(a, i);
		}
	}

	static function setRef(ctx:InterpContext, r:RefValue, v:Value):Void {
		switch r {
			case RStack(i):
				aset(ctx.stack, i, v);
			case RValue(r):
				r.v = v;
			case RArray(a, i):
				aset(a, i, v);
		}
	}

	static function fstr(f:Vfunction):String {
		return switch f {
			case FFun(f): "function@" + f.findex;
			case FNativeFun(s, _, _): "native[" + s + "]";
		}
	}

	// port: StringHelper.utf16_add, into a byte buffer
	static function utf16Add(buf:BytesBuffer, c:Int):Void {
		inline function add(c:Int) {
			buf.addByte(c & 0xFF);
			buf.addByte((c >> 8) & 0xFF);
		}
		if (c >= 0 && c < 0x10000) {
			if (c >= 0xD800 && c <= 0xDFFF) throw new Failure("Invalid unicode char " + c);
			add(c);
		} else if (c < 0x110000) {
			var c = c - 0x10000;
			add((c >> 10) + 0xD800);
			add((c & 1023) + 0xDC00);
		} else throw new Failure("Invalid unicode char " + c);
	}

	// port: UTF8.look (ExtLib), on bytes
	static function utf8Look(s:Bytes, i:Int):Int {
		var n = bget(s, i);
		if (n < 0x80) return n;
		if (n <= 0xdf) return ((n - 0xc0) << 6) | (0x7f & bget(s, i + 1));
		if (n <= 0xef) {
			var m0 = bget(s, i + 2);
			var m = s.get(i + 1);
			var n2 = ((n - 0xe0) << 6) | (0x7f & m);
			return (n2 << 6) | (0x7f & m0);
		}
		if (n <= 0xf7) {
			var m0 = bget(s, i + 3);
			var n2 = ((n - 0xf0) << 6) | (0x7f & s.get(i + 1));
			n2 = (n2 << 6) | (0x7f & s.get(i + 2));
			return (n2 << 6) | (0x7f & m0);
		}
		if (n <= 0xfb) {
			var m0 = bget(s, i + 4);
			var n2 = ((n - 0xf8) << 6) | (0x7f & s.get(i + 1));
			n2 = (n2 << 6) | (0x7f & s.get(i + 2));
			n2 = (n2 << 6) | (0x7f & s.get(i + 3));
			return (n2 << 6) | (0x7f & m0);
		}
		if (n <= 0xfd) {
			var m0 = bget(s, i + 5);
			var n2 = ((n - 0xfc) << 6) | (0x7f & s.get(i + 1));
			n2 = (n2 << 6) | (0x7f & s.get(i + 2));
			n2 = (n2 << 6) | (0x7f & s.get(i + 3));
			n2 = (n2 << 6) | (0x7f & s.get(i + 4));
			return (n2 << 6) | (0x7f & m0);
		}
		throw new InvalidArgument("UTF8.look");
	}

	// port: UTF8.next (ExtLib), on bytes
	static function utf8Next(s:Bytes, i:Int):Int {
		var n = bget(s, i);
		if (n < 0x80) return i + 1;
		if (n < 0xc0) {
			var i = i + 1;
			while (i < s.length) {
				var n = s.get(i);
				if (n < 0x80 || n >= 0xc2) return i;
				i++;
			}
			return i;
		}
		if (n <= 0xdf) return i + 2;
		if (n <= 0xef) return i + 3;
		if (n <= 0xf7) return i + 4;
		if (n <= 0xfb) return i + 5;
		if (n <= 0xfd) return i + 6;
		throw new InvalidArgument("UTF8.next");
	}

	// port: StringHelper.utf8_to_utf16, on the bytes of an OCaml string
	static function utf8ToUtf16(s:Bytes, zt:Bool):Bytes {
		var b = new BytesBuffer();
		try {
			var i = 0;
			while (i < s.length) {
				var u = utf8Look(s, i);
				// port: UCharExt.code
				if (u < 0) throw new OutOfRange("Out_of_range");
				utf16Add(b, u);
				i = utf8Next(s, i);
			}
		} catch (_:InvalidArgument) {} catch (_:OutOfRange) {} /* if malformed */
		if (zt) utf16Add(b, 0);
		return b.getBytes();
	}

	static function camlToHl(str:String):Bytes return utf8ToUtf16(Bytes.ofString(str), true);

	static function camlBytesToHl(str:Bytes):Bytes return utf8ToUtf16(str, true);

	static function hash(ctx:InterpContext, str:String):Int {
		var h = hlHash(str);
		if (!ctx.cachedHashes.exists(h)) {
			var i = str.indexOf("\x00");
			ctx.cachedHashes.set(h, if (i < 0) str else str.substr(0, i));
		}
		return h;
	}

	static function utf16Iter(f:Int->Void, s:Bytes):Void {
		inline function get(v:Int) return bget(s, v);
		var p = 0;
		while (p != s.length) {
			var c = get(p) | (get(p + 1) << 8);
			if (c >= 0xD800 && c <= 0xDFFF) {
				var c = c - 0xD800;
				var c2 = (get(p + 2) | (get(p + 3) << 8)) - 0xDC00;
				f((c2 | (c << 10)) + 0x10000);
				p += 4;
			} else {
				f(c);
				p += 2;
			}
		}
	}

	// port: UTF8.add_uchar (ExtLib)
	static function utf8AddUchar(buf:BytesBuffer, k:Int):Void {
		var masq = 63;
		if (k < 0 || k >= 0x4000000) {
			buf.addByte(0xfc + (k >>> 30));
			buf.addByte(0x80 | ((k >> 24) & masq));
			buf.addByte(0x80 | ((k >> 18) & masq));
			buf.addByte(0x80 | ((k >> 12) & masq));
			buf.addByte(0x80 | ((k >> 6) & masq));
			buf.addByte(0x80 | (k & masq));
		} else if (k <= 0x7f) buf.addByte(k);
		else if (k <= 0x7ff) {
			buf.addByte(0xc0 | (k >> 6));
			buf.addByte(0x80 | (k & masq));
		} else if (k <= 0xffff) {
			buf.addByte(0xe0 | (k >> 12));
			buf.addByte(0x80 | ((k >> 6) & masq));
			buf.addByte(0x80 | (k & masq));
		} else if (k <= 0x1fffff) {
			buf.addByte(0xf0 + (k >> 18));
			buf.addByte(0x80 | ((k >> 12) & masq));
			buf.addByte(0x80 | ((k >> 6) & masq));
			buf.addByte(0x80 | (k & masq));
		} else {
			buf.addByte(0xf8 + (k >> 24));
			buf.addByte(0x80 | ((k >> 18) & masq));
			buf.addByte(0x80 | ((k >> 12) & masq));
			buf.addByte(0x80 | ((k >> 6) & masq));
			buf.addByte(0x80 | (k & masq));
		}
	}

	// port: hl_to_caml, producing the bytes of the OCaml string
	static function hlToCamlBytes(str:Bytes):Bytes {
		function utf16Eof(s:Bytes):Bytes {
			inline function get(v:Int) return bget(s, v);
			var p = 0;
			while (true) {
				var c = get(p) | (get(p + 1) << 8);
				if (c == 0) return s.sub(0, p);
				p += 2;
			}
		}
		var b = new BytesBuffer();
		utf16Iter(c -> {
			// port: UCharExt.chr
			if (c < 0 || (c >>> 31) != 0) throw new InvalidArgument("UChar.chr");
			utf8AddUchar(b, c);
		}, utf16Eof(str));
		return b.getBytes();
	}

	// port: the OCaml string as a Haxe string (UTF-8; an ill-formed result, which only
	// ... unpaired surrogates produce, depends on the host's decoding)
	static function hlToCaml(str:Bytes):String {
		var b = hlToCamlBytes(str);
		return b.getString(0, b.length);
	}

	static function nullAccess():Dynamic {
		return error("Null value bypass null pointer check");
	}

	static function throw_(ctx:InterpContext, v:Value):Dynamic {
		ctx.errorStack = null;
		throw new InterpThrow(v);
	}

	static function throwMsg(ctx:InterpContext, msg:String):Dynamic {
		return throw_(ctx, VDyn(VBytes(camlToHl(msg)), HBytes));
	}

	// port: OCaml `String.escaped` of raw bytes
	static function escapedBytes(b:Bytes):String {
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

	static function vstrD(ctx:InterpContext, v:Value):String {
		return switch v {
			case VNull: "null";
			case VInt(i): Std.string(i) + "i";
			case VInt64(i): Int64.toStr(i) + "l";
			case VFloat(f): stringOfFloat(f) + "f";
			case VBool(b): if (b) "true" else "false";
			case VDyn(v, t): "dyn(" + vstrD(ctx, v) + ":" + tstr(t) + ")";
			case VObj(o):
				var p = o.oproto.pclass.pname;
				switch getToString(ctx, o.oproto.pclass) {
					case null: p;
					case f: p + ":" + vstrD(ctx, ctx.fcall(f, [v]));
				}
			case VBytes(b): "bytes(" + escapedBytes(b) + ")";
			case VClosure(f, o):
				if (o == null) fstr(f) else fstr(f) + "[" + vstrD(ctx, o) + "]";
			case VArray(a, t):
				var items = [for (v in a) vstrD(ctx, v)];
				"array<" + tstr(t) + ">(" + items.join(",") + ")";
			case VUndef: "undef";
			case VType(t): "type(" + tstr(t) + ")";
			case VRef(r, _): "ref(" + vstrD(ctx, getRef(ctx, r)) + ")";
			case VVirtual(v): "virtual(" + vstrD(ctx, v.vvalue) + ")";
			case VDynObj(d):
				"dynobj(" + d.dfields.fold((f, i, acc:Array<String>) -> {
					acc.unshift(f + ":" + vstrD(ctx, aget(d.dvalues, i)));
					acc;
				}, []).join(",") + ")";
			case VEnum(e, i, vals):
				var n = aget(e.efields, i).name;
				if (vals.length == 0) n else {
					var items = [for (v in vals) vstrD(ctx, v)];
					n + "(" + items.join(",") + ")";
				}
			case VAbstract(_): "abstract";
			case VVarArgs(_): "varargs";
			case VStruct(v): "@" + v.oproto.pclass.pname;
		}
	}

	static function toVirtual(ctx:InterpContext, v:Value, vp:VirtualProto):Value {
		switch v {
			case VNull:
				return VNull;
			case VObj(o):
				var indexes = vp.vfields.map(f -> {
					try {
						var r = getIndex(f.name, o.oproto.pclass);
						if (r.fid < 0 || !tsame(f.t, r.t)) throw NotFound.raise();
						VFIndex(r.fid);
					} catch (_:NotFound) {
						VFNone; /* most likely a method */
					}
				});
				return VVirtual(new Vvirtual(vp, indexes, o.ofields, v));
			case VDynObj(d):
				for (v in d.dvirtuals) if (v.vtype == vp) return VVirtual(v);
				var indexes = vp.vfields.map(f -> {
					var idx = d.dfields.findOpt(f.name);
					if (idx == null || !tsame(f.t, aget(d.dtypes, idx))) VFNone else VFIndex(idx);
				});
				var vv = new Vvirtual(vp, indexes, d.dvalues, v);
				d.dvirtuals.unshift(vv);
				return VVirtual(vv);
			case VVirtual(vd):
				if (vd.vtype == vp) return v;
				else if (vd.vvalue.match(VNull)) return die();
				else return toVirtual(ctx, vd.vvalue, vp);
			case _:
				return throwMsg(ctx, "Invalid ToVirtual " + vstrD(ctx, v) + " : " + tstr(HVirtual(vp)));
		}
	}

	static function getTypeOrDie(v:Value):Ttype {
		var t = getType(v);
		return if (t == null) die() else t;
	}

	static function dynCast(ctx:InterpContext, v:Value, t:Ttype, rt:Ttype):Value {
		function invalid():Dynamic {
			return throwMsg(ctx, "Can't cast " + vstrD(ctx, v) + ":" + tstr(t) + " to " + tstr(rt));
		}
		function default_():Value {
			var v = defaultValue(rt);
			if (v.match(VUndef)) invalid();
			return v;
		}
		if (safeCast(t, rt)) return v;
		if (v.match(VNull)) return default_();
		switch [t, rt] {
			case [HUI8 | HUI16 | HI32, HF32 | HF64]:
				return switch v {
					case VInt(i): VFloat(i);
					case _: die();
				}
			case [HF32 | HF64, HUI8 | HUI16 | HI32]:
				return switch v {
					case VFloat(f): VInt(int32OfFloat(f));
					case _: die();
				}
			case [HUI8 | HUI16 | HI32 | HF32 | HF64, HNull(rt = HUI8 | HUI16 | HI32 | HF32 | HF64)]:
				var v = dynCast(ctx, v, t, rt);
				return VDyn(v, rt);
			case [HBool, HNull(HBool)]:
				return VDyn(v, HBool);
			case [_, HDyn]:
				return makeDyn(v, t);
			case [_, HRef(t2)] if (tEq(t, t2)):
				return VRef(RValue(new ValueRef(v)), t);
			case [HFun(args1, t1), HFun(args2, t2)] if (args1.length == args2.length):
				switch v {
					case VClosure(fn, farg):
						function getConv(t1:Ttype, t2:Ttype):Cast {
							return if (safeCast(t1, t2) || (t2.match(HDyn) && isDynamic(t1))) CNo else if (t2.match(HDyn)) CDyn(t1) else
								if (t1.match(HDyn)) CUnDyn(t2) else CCast(t1, t2);
						}
						var conv = core.ds.List.map2(getConv, args2, args1);
						var rconv = getConv(t1, t2);
						function convert(v:Value, c:Cast):Value {
							return switch c {
								case CNo: v;
								case CDyn(t): makeDyn(v, t);
								case CUnDyn(t): dynCast(ctx, v, HDyn, t);
								case CCast(t1, t2): dynCast(ctx, v, t1, t2);
							}
						}
						return VClosure(FNativeFun("~convert", (args:Array<Value>) -> {
							if (args.length != conv.length) throw new InvalidArgument("List.map2");
							var args = [for (i in 0...args.length) convert(args[i], conv[i])];
							var ret = ctx.fcall(fn, if (farg == null) args else [farg].concat(args));
							return convert(ret, rconv);
						}, rt), null);
					case _:
						return die();
				}
			case [HDyn, HFun(targs, tret)] if (v.match(VVarArgs(_))):
				return VClosure(FNativeFun("~varargs", (args:Array<Value>) -> {
					if (args.length != targs.length) throw new InvalidArgument("List.map2");
					return dynCall(ctx, v, [for (i in 0...args.length) {v: args[i], t: targs[i]}], tret);
				}, rt), null);
			case [HDyn, _]:
				var t = getTypeOrDie(v);
				return dynCast(ctx, switch v {
					case VDyn(v, _): v;
					case _: v;
				}, t, rt);
			case [HNull(t), _]:
				return switch v {
					case VDyn(v, t): dynCast(ctx, v, t, rt);
					case _: die();
				}
			case [HObj(_), HObj(b)] if (safeCast(rt, t) && safeCast(getTypeOrDie(v), rt)):
				/* downcast */
				return v;
			case [HObj(_) | HDynObj | HVirtual(_), HVirtual(vp)]:
				return toVirtual(ctx, v, vp);
			case [HVirtual(_), _]:
				return switch v {
					case VVirtual(v): dynCast(ctx, v.vvalue, getTypeOrDie(v.vvalue), rt);
					case _: die();
				}
			case [HObj(p), _]:
				var f = getMethod(p, "__cast");
				if (f == null) return invalid();
				if (v.match(VNull)) return VNull;
				var ret = ctx.fcall(getFunction(ctx, f), [v, VType(rt)]);
				return if (!ret.match(VNull) && safeCast(getTypeOrDie(ret), rt)) ret else invalid();
			case _:
				return invalid();
		}
	}

	static function dynCall(ctx:InterpContext, v:Value, args:Array<{v:Value, t:Ttype}>, tret:Ttype):Value {
		switch v {
			case VClosure(f, a):
				var ft = switch f {
					case FFun(f): f.ftype;
					case FNativeFun(_, _, t): t;
				}
				var fargs, fret;
				switch ft {
					case HFun(a, t):
						fargs = a;
						fret = t;
					case _:
						fargs = die();
						fret = null;
				}
				var fullArgs = args;
				var fullFargs = if (a == null) fargs else {
					if (fargs.length == 0) throw new Failure("tl");
					fargs.slice(1);
				}
				// port: `dyn_cast ... :: loop args fargs`: OCaml evaluates the tail first, so the
				// ... arity error comes before any conversion, and arguments convert last to first.
				if (args.length > fullFargs.length)
					throwMsg(ctx, 'Too many arguments (${[for (a in fullArgs) vstrD(ctx, a.v)].join(",")}) != (${[for (t in fullFargs) tstr(t)].join(",")})');
				var vargs = [for (_ in 0...fullFargs.length) VNull];
				var i = fullFargs.length;
				while (i-- > 0) {
					vargs[i] = if (i < args.length) dynCast(ctx, args[i].v, args[i].t, fullFargs[i]) else defaultValue(ft);
				}
				var v = ctx.fcall(f, if (a == null) vargs else [a].concat(vargs));
				return dynCast(ctx, v, fret, tret);
			case VNull:
				return nullAccess();
			case VVarArgs(f, a):
				var arr = VArray(args.mapToVector(a -> makeDyn(a.v, a.t)), HDyn);
				return dynCall(ctx, VClosure(f, a), [{v: arr, t: HArray(HDyn)}], tret);
			case _:
				return throwMsg(ctx, vstrD(ctx, v) + " cannot be called");
		}
	}

	static inline var invalidComparison = 255;

	static function dynCompare(ctx:InterpContext, a:Value, at:Ttype, b:Value, bt:Ttype):Int {
		if (a == b && !at.match(HF32 | HF64)) return 0;
		function fcompare(a:Float, b:Float):Int return if (a == b) 0 else if (a > b) 1 else if (a < b) -1 else invalidComparison;
		return switch [a, b] {
			case [VInt(a), VInt(b)]: i32Compare(a, b);
			case [VInt(a), VFloat(b)]: fcompare(a, b);
			case [VFloat(a), VInt(b)]: fcompare(a, b);
			case [VFloat(a), VFloat(b)]: fcompare(a, b);
			case [VBool(a), VBool(b)]: if (a == b) 0 else if (a) 1 else -1;
			case [VNull, VNull]: 0;
			case [VType(t1), VType(t2)]: if (tsame(t1, t2)) 0 else 1;
			case [VNull, _]: 1;
			case [_, VNull]: -1;
			case [VObj(oa), VObj(ob)]:
				if (oa == ob) 0 else switch getMethod(oa.oproto.pclass, "__compare") {
					case null: invalidComparison;
					case f: switch ctx.fcall(getFunction(ctx, f), [a, b]) {
							case VInt(i): i;
							case _: die();
						}
				}
			case [VDyn(v, t), _]:
				dynCompare(ctx, v, t, b, bt);
			case [_, VDyn(v, t)]:
				dynCompare(ctx, a, at, v, t);
			case [VVirtual(v), _]:
				dynCompare(ctx, v.vvalue, HDyn, b, bt);
			case [_, VVirtual(v)]:
				dynCompare(ctx, a, at, v.vvalue, HDyn);
			case _:
				invalidComparison;
		}
	}

	static function dynGetField(ctx:InterpContext, obj:Value, field:String, rt:Ttype):Value {
		function getWith(v:Value, t:Ttype):Value return dynCast(ctx, v, t, rt);
		switch obj {
			case VDynObj(d):
				var idx = d.dfields.findOpt(field);
				if (idx == null) return defaultValue(rt);
				return getWith(aget(d.dvalues, idx), aget(d.dtypes, idx));
			case VObj(o) | VDyn(VStruct(o), HStruct(_)):
				function default_(rt:Ttype):Value {
					return switch getMethod(o.oproto.pclass, "__get_field") {
						case null: defaultValue(rt);
						case f: getWith(ctx.fcall(getFunction(ctx, f), [obj, VInt(hash(ctx, field))]), HDyn);
					}
				}
				function loop(p:ClassProto):Value {
					var fid = p.pfunctions.get(field);
					if (fid != null) {
						return switch getFunction(ctx, fid) {
							case f = FFun(fd): getWith(VClosure(f, obj), switch fd.ftype {
									case HFun(args, t) if (args.length > 0): HFun(args.slice(1), t);
									case _: die();
								});
							case FNativeFun(_): die();
						}
					}
					return if (p.psuper == null) default_(rt) else loop(p.psuper);
				}
				var r = try getIndex(field, o.oproto.pclass) catch (_:NotFound) null;
				if (r == null || r.fid < 0) return loop(o.oproto.pclass);
				return getWith(aget(o.ofields, r.fid), r.t);
			case VVirtual(vp):
				switch vp.vvalue {
					case VNull:
						var idx = vp.vtype.vindex.get(field);
						if (idx == null) return VNull;
						return switch aget(vp.vindexes, idx) {
							case VFNone: VNull;
							case VFIndex(i): aget(vp.vtable, i);
						}
					case v:
						return dynGetField(ctx, v, field, rt);
				}
			case VNull:
				return nullAccess();
			case _:
				return throwMsg(ctx, "Invalid object access");
		}
	}

	static function rebuildVirtuals(ctx:InterpContext, d:Vdynobj):Void {
		var old = d.dvirtuals;
		d.dvirtuals = [];
		for (v in old) {
			var v2 = switch toVirtual(ctx, VDynObj(d), v.vtype) {
				case VVirtual(v): v;
				case _: die();
			}
			v.vindexes = v2.vindexes;
			v.vtable = d.dvalues;
		}
		d.dvirtuals = old;
	}

	static function dynSetField(ctx:InterpContext, obj:Value, field:String, v:Value, vt:Ttype):Void {
		switch vt {
			case HDyn:
				switch getType(v) {
					case null:
						if (v.match(VNull)) {
							v = VNull;
							vt = HDyn;
						} else die();
					case t:
						v = switch v {
							case VDyn(v, _): v;
							case _: v;
						}
						vt = t;
				}
			case _:
		}
		switch obj {
			case VDynObj(d):
				var idx = d.dfields.findOpt(field);
				if (idx != null) {
					aset(d.dvalues, idx, v);
					if (!tsame(aget(d.dtypes, idx), vt)) {
						d.dtypes[idx] = vt;
						rebuildVirtuals(ctx, d);
					}
				} else {
					var idx = d.dvalues.length;
					d.dfields.add(field, idx);
					d.dvalues = d.dvalues.snoc(v);
					d.dtypes = d.dtypes.snoc(vt);
					rebuildVirtuals(ctx, d);
				}
			case VObj(o):
				var r = try getIndex(field, o.oproto.pclass) catch (_:NotFound) null;
				if (r == null || r.fid < 0) throwMsg(ctx, o.oproto.pclass.pname + " has no field " + field);
				aset(o.ofields, r.fid, dynCast(ctx, v, vt, r.t));
			case VVirtual(vp):
				dynSetField(ctx, vp.vvalue, field, v, vt);
			case VNull:
				nullAccess();
			case _:
				throwMsg(ctx, "Invalid object access");
		}
	}

	static function makeStack(ctx:InterpContext, f:Fundecl, pos:IntRef):{file:String, line:Int} {
		var pos = pos.v - 1;
		return if (pos >= 0 && pos < f.debug.length && f.debug[pos].file >= 0 && f.debug[pos].file < ctx.code.debugfiles.length)
			{file: ctx.code.debugfiles[f.debug[pos].file], line: f.debug[pos].line} else {file: "???", line: 0};
	}

	// port: Printf "%X" of an OCaml (63-bit) int
	static function hexInt(v:Int):String {
		if (v >= 0) return StringTools.hex(v);
		var s = StringTools.hex(v);
		while (s.length < 8) s = "F" + s;
		return "7FFFFFFF" + s;
	}

	static function stackFrame(ctx:InterpContext, e:Frames):String {
		var fl = makeStack(ctx, e.f, e.pos);
		return fl.file + ":" + fl.line + ": Called from fun@" + e.f.findex + " @x" + hexInt(e.pos.v - 1);
	}

	static function cachedString(ctx:InterpContext, idx:Int):Bytes {
		var s = ctx.cachedStrings.get(idx);
		if (s != null) return s;
		var s = camlToHl(aget(ctx.code.strings, idx));
		ctx.cachedStrings.set(idx, s);
		return s;
	}

	static function virtMakeVal(v:Vvirtual):Value {
		var hfields = newStringHashtbl();
		var ftypes:Array<Ttype> = [];
		var values:Array<Value> = [];
		for (i in 0...v.vindexes.length) {
			switch v.vindexes[i] {
				case VFNone:
				case VFIndex(k):
					var f = aget(v.vtype.vfields, i);
					hfields.add(f.name, values.length);
					values.push(aget(v.vtable, k));
					ftypes.push(f.t);
			}
		}
		return VDynObj(new Vdynobj(hfields, Vector.fromArrayCopy(ftypes), Vector.fromArrayCopy(values), [v]));
	}

	static function vstr(ctx:InterpContext, v:Value, t:Ttype):String {
		return switch v {
			case VNull: "null";
			case VInt(i): Std.string(i);
			case VInt64(i): Int64.toStr(i);
			case VFloat(f): floatToString(f);
			case VBool(b): if (b) "true" else "false";
			case VDyn(v, t):
				vstr(ctx, v, t);
			case VObj(o):
				switch getToString(ctx, o.oproto.pclass) {
					case null: o.oproto.pclass.pname;
					case f: vstr(ctx, ctx.fcall(f, [v]), HBytes);
				}
			case VBytes(b): try hlToCaml(b) catch (_:Dynamic) "?" + escapedBytes(b);
			case VClosure(f, _): fstr(f);
			case VArray(a, t):
				var items = [for (v in a) vstr(ctx, v, t)];
				"[" + items.join(", ") + "]";
			case VUndef: "undef";
			case VType(t): tstr(t);
			case VRef(r, t): "*" + vstr(ctx, getRef(ctx, r), t);
			case VVirtual(v):
				switch v.vvalue {
					case VNull:
						vstr(ctx, virtMakeVal(v), HDyn);
					case _:
						vstr(ctx, v.vvalue, HDyn);
				}
			case VDynObj(d):
				var fid = d.dfields.findOpt("__string");
				if (fid != null && aget(d.dtypes, fid).match(HFun([], HBytes))) vstr(ctx, dynCall(ctx, d.dvalues[fid], [], HBytes), HBytes) else
					"{" + d.dfields.fold((f, i, acc:Array<String>) -> {
						acc.unshift(f + ":" + vstr(ctx, aget(d.dvalues, i), aget(d.dtypes, i)));
						acc;
					}, []).join(", ") + "}";
			case VAbstract(_): "abstract";
			case VEnum(e, i, vals):
				var ef = aget(e.efields, i);
				var n = ef.name, pl = ef.args;
				if (pl.length == 0) n else {
					var items = [for (i in 0...pl.length) vstr(ctx, aget(vals, i), pl[i])];
					n + "(" + items.join(",") + ")";
				}
			case VVarArgs(_): "varargs";
			case VStruct(s): "@" + s.oproto.pclass.pname;
		}
	}

	// port: the `check` closure of `interp` once the value is not compatible: OCaml
	// ... evaluates the `sprintf` arguments right to left, so `vstr_d` (which may run code) first.
	static function checkFailed(ctx:InterpContext, v:Value, t:Ttype, id:String):Dynamic {
		var vs = vstrD(ctx, v);
		var ts = tstr(t);
		return error("Can't set " + id + "(" + ts + ") with " + vs);
	}

	static inline function ufloat(v:Int):Float {
		return if (v < 0) v + 4294967296. else v;
	}

	public static function interp(ctx:InterpContext, f:Fundecl, args:Array<Value>):Value {
		var spos = ctx.stackPos;
		var nregs = f.regs.length;
		if (spos + nregs > ctx.stack.length) {
			var nsize = spos + nregs + 256;
			var nstack = new Vector(nsize, VUndef);
			Vector.blit(ctx.stack, 0, nstack, 0, ctx.stackPos);
			ctx.stack = nstack;
		}
		if (ctx.checked) for (i in 0...nregs) ctx.stack[i + spos] = VUndef;
		ctx.stackPos = spos + nregs;

		var pos = new IntRef(1);
		ctx.callStack = new Frames(f, pos, ctx.callStack);
		var fret = switch f.ftype {
			case HFun(fargs, fret):
				if (ctx.checked && fargs.length != args.length) {
					var ts = [for (t in fargs) tstr(t)].join(",");
					error("Invalid args: (" + [for (a in args) vstrD(ctx, a)].join(",") + ") should be (" + ts + ")");
				}
				fret;
			case _:
				die();
		}
		var fcall = ctx.fcall;
		inline function rtype(i:Int):Ttype return f.regs[i];
		inline function check(v:Value, t:Ttype, id:() -> String):Void {
			if (ctx.checked && !isCompatible(v, t)) checkFailed(ctx, v, t, id());
		}
		function checkObj(v:Value, o:Value, fid:Int):Void {
			if (ctx.checked) switch o {
				case VObj(o):
					var fields = getProto(ctx, o.oproto.pclass).fields;
					check(v, aget(fields, fid), () -> "obj field");
				case VVirtual(vp):
					var t = aget(vp.vtype.vfields, fid).t;
					check(v, t, () -> "virtual field");
				case _:
			}
		}
		inline function set(r:Int, v:Value):Void {
			if (ctx.checked && !isCompatible(v, rtype(r))) checkFailed(ctx, v, rtype(r), "register " + r);
			ctx.stack[r + spos] = v;
		}
		for (i in 0...args.length) set(i, args[i]);
		inline function get(r:Int):Value return ctx.stack[r + spos];
		inline function global(g:Int):Value return ctx.tGlobals[g];
		var traps:Array<{r:Int, target:Int}> = []; // port: list, head = last element
		function numop(iop:(Int, Int) -> Int, fop:(Float, Float) -> Float, a:Int, b:Int):Value {
			return switch rtype(a) {
				// todo : sign-extend and mask after result for HUI8/16
				case HUI8 | HUI16 | HI32:
					switch [get(a), get(b)] {
						case [VInt(a), VInt(b)]: VInt(iop(a, b));
						case _: die();
					}
				case HF32 | HF64:
					switch [get(a), get(b)] {
						case [VFloat(a), VFloat(b)]: VFloat(fop(a, b));
						case _: die();
					}
				case _:
					die();
			}
		}
		function iop(f:(Int, Int) -> Int, a:Int, b:Int):Value {
			return switch rtype(a) {
				// todo : sign-extend and mask after result for HUI8/16
				case HUI8 | HUI16 | HI32:
					switch [get(a), get(b)] {
						case [VInt(a), VInt(b)]: VInt(f(a, b));
						case _: die();
					}
				case _:
					die();
			}
		}
		function iunop(iop:Int->Int, r:Int):Value {
			return switch rtype(r) {
				case HUI8 | HUI16 | HI32:
					switch get(r) {
						case VInt(a): VInt(iop(a));
						case _: die();
					}
				case _:
					die();
			}
		}
		function ucompare(a:Value, b:Value):Int {
			return switch [a, b] {
				case [VInt(a), VInt(b)]:
					var d = (a >>> 16) - (b >>> 16);
					if (d == 0) (a & 0xFFFF) - (b & 0xFFFF) else d;
				case _: die();
			}
		}
		function vcompare(ra:Int, rb:Int, op:Int->Bool):Bool {
			var a = get(ra);
			var b = get(rb);
			var t = rtype(ra);
			var r = dynCompare(ctx, a, t, b, t);
			return if (r == invalidComparison) false else op(r);
		}
		function loop():Value {
			while (true) {
				var op = f.code[pos.v];
				pos.v++;
				switch op {
					case OMov(a, b):
						set(a, get(b));
					case OInt(r, i):
						set(r, VInt(aget(ctx.code.ints, i)));
					case OFloat(r, i):
						set(r, VFloat(ctx.code.floats[i]));
					case OString(r, s):
						set(r, VBytes(cachedString(ctx, s)));
					case OBytes(r, s):
						set(r, VBytes(aget(ctx.code.bytes, s).sub(0, ctx.code.bytes[s].length)));
					case OBool(r, b):
						set(r, VBool(b));
					case ONull(r):
						set(r, VNull);
					case OAdd(r, a, b):
						set(r, numop(i32Add, (a, b) -> a + b, a, b));
					case OSub(r, a, b):
						set(r, numop(i32Sub, (a, b) -> a - b, a, b));
					case OMul(r, a, b):
						set(r, numop(i32Mul, (a, b) -> a * b, a, b));
					case OSDiv(r, a, b):
						set(r, numop((a, b) -> if (b == 0) 0 else i32Div(a, b), (a, b) -> a / b, a, b));
					case OUDiv(r, a, b):
						set(r, iop((a, b) -> if (b == 0) 0 else int32OfFloat((ufloat(a)) / (ufloat(b))), a, b));
					case OSMod(r, a, b):
						set(r, numop((a, b) -> if (b == 0) 0 else i32Rem(a, b), (a, b) -> a % b, a, b));
					case OUMod(r, a, b):
						set(r, iop((a, b) -> if (b == 0) 0 else int32OfFloat(ufloat(a) % ufloat(b)), a, b));
					case OShl(r, a, b):
						set(r, iop(i32Shl, a, b));
					case OSShr(r, a, b):
						set(r, iop(i32Shr, a, b));
					case OUShr(r, a, b):
						set(r, iop(i32Ushr, a, b));
					case OAnd(r, a, b):
						set(r, iop((a, b) -> a & b, a, b));
					case OOr(r, a, b):
						set(r, iop((a, b) -> a | b, a, b));
					case OXor(r, a, b):
						set(r, iop((a, b) -> a ^ b, a, b));
					case ONeg(r, v):
						set(r, switch get(v) {
							case VInt(v): VInt((-v) | 0);
							case VFloat(f): VFloat(-f);
							case _: die();
						});
					case ONot(r, v):
						set(r, switch get(v) {
							case VBool(b): VBool(!b);
							case _: die();
						});
					case OIncr(r):
						set(r, iunop(i -> i32Add(i, 1), r));
					case ODecr(r):
						set(r, iunop(i -> i32Sub(i, 1), r));
					case OCall0(r, f):
						set(r, fcall(getFunction(ctx, f), []));
					case OCall1(r, f, r1):
						set(r, fcall(getFunction(ctx, f), [get(r1)]));
					case OCall2(r, f, r1, r2):
						set(r, fcall(getFunction(ctx, f), [get(r1), get(r2)]));
					case OCall3(r, f, r1, r2, r3):
						set(r, fcall(getFunction(ctx, f), [get(r1), get(r2), get(r3)]));
					case OCall4(r, f, r1, r2, r3, r4):
						set(r, fcall(getFunction(ctx, f), [get(r1), get(r2), get(r3), get(r4)]));
					case OCallN(r, f, rl):
						set(r, fcall(getFunction(ctx, f), [for (r in rl) get(r)]));
					case OGetGlobal(r, g):
						set(r, global(g));
					case OSetGlobal(g, r):
						var v = get(r);
						check(v, aget(ctx.code.globals, g), () -> "global " + g);
						ctx.tGlobals[g] = v;
					case OJTrue(r, i):
						if (get(r).match(VBool(true))) pos.v = pos.v + i;
					case OJFalse(r, i):
						if (get(r).match(VBool(false))) pos.v = pos.v + i;
					case ORet(r):
						return get(r);
					case OJNull(r, i):
						if (get(r).match(VNull)) pos.v = pos.v + i;
					case OJNotNull(r, i):
						if (!get(r).match(VNull)) pos.v = pos.v + i;
					case OJSLt(a, b, i):
						if (vcompare(a, b, r -> r < 0)) pos.v = pos.v + i;
					case OJSGte(a, b, i):
						if (vcompare(a, b, r -> r >= 0)) pos.v = pos.v + i;
					case OJSGt(a, b, i):
						if (vcompare(a, b, r -> r > 0)) pos.v = pos.v + i;
					case OJSLte(a, b, i):
						if (vcompare(a, b, r -> r <= 0)) pos.v = pos.v + i;
					case OJULt(a, b, i):
						if (ucompare(get(a), get(b)) < 0) pos.v = pos.v + i;
					case OJUGte(a, b, i):
						if (ucompare(get(a), get(b)) >= 0) pos.v = pos.v + i;
					case OJNotLt(a, b, i):
						if (!vcompare(a, b, r -> r < 0)) pos.v = pos.v + i;
					case OJNotGte(a, b, i):
						if (!vcompare(a, b, r -> r >= 0)) pos.v = pos.v + i;
					case OJEq(a, b, i):
						if (vcompare(a, b, r -> r == 0)) pos.v = pos.v + i;
					case OJNotEq(a, b, i):
						if (!vcompare(a, b, r -> r == 0)) pos.v = pos.v + i;
					case OJAlways(i):
						pos.v = pos.v + i;
					case OToDyn(r, a):
						set(r, makeDyn(get(a), f.regs[a]));
					case OToSFloat(r, a):
						set(r, switch get(a) {
							case VInt(v): VFloat(v);
							case v = VFloat(_): v;
							case _: die();
						});
					case OToUFloat(r, a):
						set(r, switch get(a) {
							case VInt(v): VFloat(ufloat(v));
							case v = VFloat(_): v;
							case _: die();
						});
					case OToInt(r, a):
						set(r, switch get(a) {
							case VFloat(v): VInt(int32OfFloat(v));
							case VInt(i) if (rtype(r).match(HI64)): VInt64(Int64.ofInt(i));
							case v = VInt(_): v;
							case _: die();
						});
					case OLabel(_):
					case ONew(r):
						set(r, allocObj(ctx, rtype(r)));
					case OField(r, o, fid):
						set(r, switch get(o) {
							case VObj(v) | VStruct(v): aget(v.ofields, fid);
							case obj = VVirtual(v):
								switch aget(v.vindexes, fid) {
									case VFNone: dynGetField(ctx, obj, v.vtype.vfields[fid].name, rtype(r));
									case VFIndex(i): aget(v.vtable, i);
								}
							case VNull: nullAccess();
							case _: die();
						});
					case OSetField(o, fid, r):
						var rv = get(r);
						var o = get(o);
						switch o {
							case VObj(v) | VStruct(v):
								checkObj(rv, o, fid);
								aset(v.ofields, fid, rv);
							case VVirtual(v):
								switch aget(v.vindexes, fid) {
									case VFNone:
										dynSetField(ctx, o, v.vtype.vfields[fid].name, rv, rtype(r));
									case VFIndex(i):
										checkObj(rv, o, fid);
										aset(v.vtable, i, rv);
								}
							case VNull:
								nullAccess();
							case _:
								die();
						}
					case OGetThis(r, fid):
						set(r, switch get(0) {
							case VObj(v) | VStruct(v): aget(v.ofields, fid);
							case _: die();
						});
					case OSetThis(fid, r):
						switch get(0) {
							case o = VObj(v) | VStruct(v):
								var rv = get(r);
								checkObj(rv, o, fid);
								aset(v.ofields, fid, rv);
							case _:
								die();
						}
					case OCallMethod(r, m, rl):
						if (rl.length == 0) throw new Failure("hd");
						switch get(rl[0]) {
							case VObj(v):
								set(r, fcall(aget(v.oproto.pmethods, m), [for (r in rl) get(r)]));
							case VVirtual(v):
								var name = aget(v.vtype.vfields, m).name;
								switch v.vvalue {
									case obj = VObj(o):
										var m = o.oproto.pclass.pfunctions.get(name);
										if (m == null) die();
										set(r, dynCall(ctx, VClosure(getFunction(ctx, m), obj), [for (i in 1...rl.length) {v: get(rl[i]), t: rtype(rl[i])}], rtype(r)));
									case VDynObj(_):
										set(r, dynCall(ctx, v.vvalue, [for (i in 1...rl.length) {v: get(rl[i]), t: rtype(rl[i])}], rtype(r)));
									case _:
										die();
								}
							case VNull:
								nullAccess();
							case _:
								die();
						}
					case OCallThis(r, m, rl):
						switch get(0) {
							case o = VObj(v):
								set(r, fcall(aget(v.oproto.pmethods, m), [o].concat([for (r in rl) get(r)])));
							case _:
								die();
						}
					case OCallClosure(r, v, rl):
						if (rtype(v).match(HDyn)) set(r, dynCall(ctx, get(v), [for (r in rl) {v: get(r), t: rtype(r)}], rtype(r)));
						else switch get(v) {
							case VClosure(f, null):
								set(r, fcall(f, [for (r in rl) get(r)]));
							case VClosure(f, arg):
								set(r, fcall(f, [arg].concat([for (r in rl) get(r)])));
							case VNull:
								nullAccess();
							case _:
								throwMsg(ctx, vstrD(ctx, get(v)));
						}
					case OStaticClosure(r, fid):
						var f = getFunction(ctx, fid);
						set(r, VClosure(f, null));
					case OInstanceClosure(r, fid, v):
						var f = getFunction(ctx, fid);
						set(r, VClosure(f, get(v)));
					case OVirtualClosure(r, o, m):
						var m = switch get(o) {
							case obj = VObj(v): VClosure(aget(v.oproto.pmethods, m), obj);
							case VNull: nullAccess();
							case _: die();
						}
						set(r, if (m.match(VNull)) m else dynCast(ctx, m, getTypeOrDie(m), rtype(r)));
					case OThrow(r):
						throw_(ctx, get(r));
					case ORethrow(r):
						ctx.callStack = Frames.append(Frames.rev(ctx.errorStack), ctx.callStack);
						throw_(ctx, get(r));
					case OGetUI8(r, b, p):
						switch [get(b), get(p)] {
							case [VBytes(b), VInt(p)]: set(r, VInt(bget(b, p)));
							case _: die();
						}
					case OGetUI16(r, b, p):
						switch [get(b), get(p)] {
							case [VBytes(b), VInt(p)]:
								var a = bget(b, p);
								var b = bget(b, p + 1);
								set(r, VInt(a | (b << 8)));
							case _:
								die();
						}
					case OGetMem(r, b, p):
						switch [get(b), get(p)] {
							case [VBytes(b), VInt(p)]:
								set(r, switch rtype(r) {
									case HI32: VInt(getI32(b, p));
									case HI64: VInt64(getI64(b, p));
									case HF32: VFloat(haxe.io.FPHelper.i32ToFloat(getI32(b, p)));
									case HF64: VFloat(haxe.io.FPHelper.i64ToDouble(getI64(b, p).low, getI64(b, p).high));
									case _: die();
								});
							case _:
								die();
						}
					case OGetArray(r, a, i):
						switch [get(a), get(i)] {
							case [VArray(a, _), VInt(i)]: set(r, aget(a, i));
							case _: die();
						}
					case OSetUI8(r, p, v):
						switch [get(r), get(p), get(v)] {
							case [VBytes(b), VInt(p), VInt(v)]: bset(b, p, v & 0xFF);
							case _: die();
						}
					case OSetUI16(r, p, v):
						switch [get(r), get(p), get(v)] {
							case [VBytes(b), VInt(p), VInt(v)]:
								bset(b, p, v & 0xFF);
								bset(b, p + 1, (v >>> 8) & 0xFF);
							case _:
								die();
						}
					case OSetMem(r, p, v):
						switch [get(r), get(p)] {
							case [VBytes(b), VInt(p)]:
								switch [rtype(v), get(v)] {
									case [HI32, VInt(v)]: setI32(b, p, v);
									case [HI64, VInt64(v)]: setI64(b, p, v);
									case [HF32, VFloat(f)]: setI32(b, p, haxe.io.FPHelper.floatToI32(f));
									case [HF64, VFloat(f)]: setI64(b, p, haxe.io.FPHelper.doubleToI64(f));
									case _: die();
								}
							case _:
								die();
						}
					case OSetArray(a, i, v):
						switch [get(a), get(i)] {
							case [VArray(a, t), VInt(i)]:
								var v = get(v);
								check(v, t, () -> "array");
								var idx = i;
								if (ctx.checked && (idx < 0 || idx >= a.length)) error("Can't set array index " + idx + " with " + vstrD(ctx, v));
								aset(a, i, v);
							case _:
								die();
						}
					case OSafeCast(r, v):
						set(r, dynCast(ctx, get(v), rtype(v), rtype(r)));
					case OUnsafeCast(r, v):
						set(r, get(v));
					case OArraySize(r, a):
						switch get(a) {
							case VArray(a, _): set(r, VInt(a.length));
							case _: die();
						}
					case OType(r, t):
						set(r, VType(t));
					case OGetType(r, v):
						var v = get(v);
						var v = switch v {
							case VVirtual({vvalue: VNull}): die();
							case VVirtual(v): v.vvalue;
							case _: v;
						}
						set(r, VType(if (v.match(VNull)) HVoid else getTypeOrDie(v)));
					case OGetTID(r, v):
						set(r, switch get(v) {
							case VType(t):
								VInt(switch t {
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
									case HFun(_): 10;
									case HObj(_): 11;
									case HArray(_): 12;
									case HType: 13;
									case HRef(_): 14;
									case HVirtual(_): 15;
									case HDynObj: 16;
									case HAbstract(_): 17;
									case HEnum(_): 18;
									case HNull(_): 19;
									case HMethod(_): 20;
									case HStruct(_): 21;
									case HPacked(_): 22;
									case HGUID: 23;
								});
							case _:
								die();
						});
					case ORef(r, v):
						set(r, VRef(RStack(v + spos), rtype(v)));
					case OUnref(v, r):
						set(v, switch get(r) {
							case VRef(r, _): getRef(ctx, r);
							case _: die();
						});
					case OSetref(r, v):
						switch get(r) {
							case VRef(r, t):
								var v = get(v);
								check(v, t, () -> "ref");
								setRef(ctx, r, v);
							case _:
								die();
						}
					case OToVirtual(r, rv):
						set(r, toVirtual(ctx, get(rv), switch rtype(r) {
							case HVirtual(vp): vp;
							case _: die();
						}));
					case ODynGet(r, o, f):
						set(r, dynGetField(ctx, get(o), aget(ctx.code.strings, f), rtype(r)));
					case ODynSet(o, fid, vr):
						dynSetField(ctx, get(o), aget(ctx.code.strings, fid), get(vr), rtype(vr));
					case OMakeEnum(r, e, pl):
						set(r, VEnum(switch rtype(r) {
							case HEnum(e): e;
							case _: die();
						}, e, pl.mapToVector(r -> get(r))));
					case OEnumAlloc(r, f):
						switch rtype(r) {
							case HEnum(e):
								var fl = aget(e.efields, f).args;
								var vl = new Vector(fl.length, VUndef);
								set(r, VEnum(e, f, vl));
							case _:
								die();
						}
					case OEnumIndex(r, v):
						switch get(v) {
							case VEnum(_, i, _): set(r, VInt(i));
							case _: die();
						}
					case OEnumField(r, v, _, i):
						switch get(v) {
							case VEnum(_, _, vl): set(r, aget(vl, i));
							case _: die();
						}
					case OSetEnumField(v, i, r):
						switch [get(v), rtype(v)] {
							case [VEnum(_, id, vl), HEnum(e)]:
								var rv = get(r);
								var fields = aget(e.efields, id).args;
								check(rv, aget(fields, i), () -> "enumfield");
								aset(vl, i, rv);
							case _:
								die();
						}
					case OSwitch(r, indexes, _):
						switch get(r) {
							case VInt(i):
								if (i >= 0 && i < indexes.length) pos.v = pos.v + indexes[i];
							case _:
								die();
						}
					case ONullCheck(r):
						if (get(r).match(VNull)) throwMsg(ctx, "Null access");
					case OTrap(r, j):
						var target = pos.v + j;
						traps.push({r: r, target: target});
					case OEndTrap(_):
						if (traps.length == 0) throw new Failure("tl");
						traps.pop();
					case OAssert(_):
						throwMsg(ctx, "Assert");
					case ORefData(r, d):
						switch get(d) {
							case VArray(a, t): set(r, VRef(RArray(a, 0), t));
							case _: die();
						}
					case ORefOffset(r, r2, off):
						switch [get(r2), get(off)] {
							case [VRef(RArray(a, pos), t), VInt(i)]: set(r, VRef(RArray(a, pos + i), t));
							case _: die();
						}
					case OAsm(_):
						throwMsg(ctx, "Unsupported ASM");
					case ONop(_) | OPrefetch(_) | OCatch(_):
				}
			}
		}
		// port: `exec`; the `Return` exception of a `ORet` is the value `loop` returns.
		pos.v = 0;
		while (true) {
			try {
				var v = loop();
				check(v, fret, () -> "return value");
				ctx.callStack = Frames.tl(ctx.callStack);
				ctx.stackPos = spos;
				return v;
			} catch (e:InterpThrow) {
				if (traps.length == 0) {
					if (ctx.callStack == null) throw new Failure("hd");
					ctx.errorStack = new Frames(ctx.callStack.f, ctx.callStack.pos, ctx.errorStack);
					ctx.callStack = Frames.tl(ctx.callStack);
					throw new InterpThrow(e.v);
				}
				var t = traps.pop();
				ctx.errorStack = new Frames(f, new IntRef(pos.v), ctx.errorStack);
				pos.v = t.target;
				ctx.stackPos = spos + nregs;
				set(t.r, e.v);
			}
		}
	}

	public static function callFun(ctx:InterpContext, f:Vfunction, args:Array<Value>):Value {
		switch f {
			case FFun(f):
				return interp(ctx, f, args);
			case FNativeFun(_, f, _):
				try {
					return f(args);
				} catch (e:InterpThrow) {
					throw new InterpThrow(e.v);
				} catch (e:Failure) {
					return throwMsg(ctx, e.message);
				} catch (e:SysExit) {
					throw e;
				}
				/*		| e ->
					throw_msg ctx (Printexc.to_string e)
				 */
		}
	}

	public static function callWrap(ctx:InterpContext, f:Vfunction, args:Array<Value>, ?final_:() -> Void):Value {
		if (final_ == null) final_ = () -> {};
		var oldSt = ctx.callStack;
		var oldPos = ctx.stackPos;
		function restore() {
			ctx.callStack = oldSt;
			ctx.stackPos = oldPos;
		}
		try {
			var v = callFun(ctx, f, args);
			final_();
			return v;
		} catch (e:InterpThrow) {
			restore();
			final_();
			ctx.onError(e.v, Frames.rev(ctx.errorStack));
			return VNull;
		} catch (e:RuntimeError) {
			var stack = ctx.callStack;
			restore();
			final_();
			ctx.onError(VBytes(camlToHl("HL Interp error " + e.message)), stack);
			return VNull;
		}
	}

	/* ------------------------------- HL RUNTIME ---------------------------------------------- */
	// port: `print_string` on OCaml's buffered stdout; the compiler flushes stdout before it
	// ... reports, so the bytes are written to the host's stdout directly.
	static function printBytes(b:Bytes):Void {
		Sys.stdout().write(b);
	}

	// port: Unix.localtime of a time_t, through the host Date (local time)
	static function localtime(t:Float):Date {
		var t = if (t < 0) Math.fceil(t) else Math.ffloor(t);
		return Date.fromTime(t * 1000.);
	}

	// port: Unix.mktime (tm_wday, tm_yday and tm_isdst ignored)
	static function mktime(year:Int, mon:Int, mday:Int, hour:Int, min:Int, sec:Int):Float {
		return new Date(year, mon, mday, hour, min, sec).getTime() / 1000.;
	}

	static function mktimeOf(d:Date):Float {
		return mktime(d.getFullYear(), d.getMonth(), d.getDate(), d.getHours(), d.getMinutes(), d.getSeconds());
	}

	// port: Printf "%.Nd"
	static function padInt(v:Int, n:Int):String {
		var s = Std.string(v < 0 ? -v : v);
		while (s.length < n) s = "0" + s;
		return v < 0 ? "-" + s : s;
	}

	// port: ExtString.String.find
	static function stringFind(str:Bytes, sub:Bytes):Int {
		var sublen = sub.length;
		if (sublen == 0) return 0;
		var len = str.length;
		for (i in 0...len - sublen + 1) {
			var j = 0;
			while (str.get(i + j) == sub.get(j)) {
				j++;
				if (j == sublen) return i;
			}
		}
		return -1; // port: Invalid_string
	}

	// port: OCaml `String.compare` (-1, 0 or 1)
	static function bytesCompare(a:Bytes, b:Bytes):Int {
		var c = a.compare(b);
		return if (c < 0) -1 else if (c > 0) 1 else 0;
	}

	// port: stdlib/array.ml `stable_sort` (a merge sort), whose sequence of comparisons is
	// ... observable through the comparison closure
	static function arrayStableSort<T>(cmp:T->T->Int, a:Array<T>):Void {
		var cutoff = 5;
		function merge(src1ofs:Int, src1len:Int, src2:Array<T>, src2ofs:Int, src2len:Int, dst:Array<T>, dstofs:Int):Void {
			var src1r = src1ofs + src1len, src2r = src2ofs + src2len;
			var i1 = src1ofs, s1 = a[src1ofs], i2 = src2ofs, s2 = src2[src2ofs], d = dstofs;
			while (true) {
				if (cmp(s1, s2) <= 0) {
					dst[d] = s1;
					i1++;
					if (i1 < src1r) {
						s1 = a[i1];
						d++;
					} else {
						for (k in 0...src2r - i2) dst[d + 1 + k] = src2[i2 + k];
						return;
					}
				} else {
					dst[d] = s2;
					i2++;
					if (i2 < src2r) {
						s2 = src2[i2];
						d++;
					} else {
						// port: blit within possibly the same array; a1 and dst do not overlap here
						var tmp = a.slice(i1, src1r);
						for (k in 0...tmp.length) dst[d + 1 + k] = tmp[k];
						return;
					}
				}
			}
		}
		function isortto(srcofs:Int, dst:Array<T>, dstofs:Int, len:Int):Void {
			for (i in 0...len) {
				var e = a[srcofs + i];
				var j = dstofs + i - 1;
				while (j >= dstofs && cmp(dst[j], e) > 0) {
					dst[j + 1] = dst[j];
					j--;
				}
				dst[j + 1] = e;
			}
		}
		function sortto(srcofs:Int, dst:Array<T>, dstofs:Int, len:Int):Void {
			if (len <= cutoff) isortto(srcofs, dst, dstofs, len) else {
				var l1 = Std.int(len / 2);
				var l2 = len - l1;
				sortto(srcofs + l1, dst, dstofs + l1, l2);
				sortto(srcofs, a, srcofs + l2, l1);
				merge(srcofs + l2, l1, dst, dstofs + l1, l2, dst, dstofs);
			}
		}
		var l = a.length;
		if (l <= cutoff) isortto(0, a, 0, l) else {
			var l1 = Std.int(l / 2);
			var l2 = l - l1;
			var t = [for (_ in 0...l2) a[0]];
			sortto(l1, t, 0, l2);
			sortto(0, a, l2, l1);
			merge(l2, l1, t, 0, l2, a, 0);
		}
	}

	static function loadNative(ctx:InterpContext, lib:String, name:String, t:Ttype):Vfunction {
		function unresolved():Array<Value>->Value return (args) -> error("Unresolved native " + lib + "@" + name);
		inline function toInt(i:Int):Value return VInt(i);
		function date(d:Int):Date {
			return localtime(d);
		}
		function toDate(d:Date):Value {
			var t = mktimeOf(d);
			return VInt(int32OfFloat(t));
		}
		function hlToCamlSub(str:Bytes, pos:Int, len:Int):String {
			var b = Bytes.alloc(len + 2);
			b.blit(0, bsub(str, pos, len), 0, len);
			b.set(len, 0);
			b.set(len + 1, 0);
			return hlToCaml(b);
		}
		function noVirtual(v:Value):Value {
			return switch v {
				case VVirtual(v) if (!v.vvalue.match(VNull)): v.vvalue;
				case _: v;
			}
		}
		inline function setRef(r:RefValue, v:Value) Hlinterp.setRef(ctx, r, v);
		var f:Array<Value>->Value = switch lib {
			case "std":
				switch name {
					case "alloc_bytes":
						function(args) return switch args {
							case [VInt(i)]:
								if (i < 0) throw new InvalidArgument("Bytes.create");
								// port: Bytes.create leaves the contents unspecified; zeroed here
								var b = Bytes.alloc(i);
								b.fill(0, i, 0);
								VBytes(b);
							case _: die();
						}
					case "alloc_array":
						function(args) return switch args {
							case [VType(t), VInt(i)]:
								if (i < 0) throw new InvalidArgument("Array.make");
								VArray(new Vector(i, defaultValue(t)), t);
							case _: die();
						}
					case "alloc_obj":
						function(args) return switch args {
							case [VType(t)]: allocObj(ctx, t);
							case _: die();
						}
					case "alloc_enum_dyn":
						function(args) return switch args {
							case [VType(HEnum(e)), VInt(idx), VArray(vl, vt), VInt(len)]:
								var args = aget(e.efields, idx).args;
								if (args.length != len) VNull else {
									if (len < 0 || len > vl.length) throw new InvalidArgument("Array.sub");
									VEnum(e, idx, VectorTools.init(len, i -> dynCast(ctx, vl[i], vt, args[i])));
								}
							case vl:
								die();
						}
					case "array_blit":
						function(args) return switch args {
							case [VArray(dst, _), VInt(dp), VArray(src, _), VInt(sp), VInt(len)]:
								if (len < 0 || sp < 0 || sp > src.length - len || dp < 0 || dp > dst.length - len) throw new InvalidArgument("Array.blit");
								Vector.blit(src, sp, dst, dp, len);
								VUndef;
							case _: die();
						}
					case "bytes_blit":
						function(args) return switch args {
							case [VBytes(dst), VInt(dp), VBytes(src), VInt(sp), VInt(len)]:
								if (len < 0 || sp < 0 || sp > src.length - len || dp < 0 || dp > dst.length - len)
									throw new InvalidArgument("String.blit / Bytes.blit_string");
								dst.blit(dp, src, sp, len);
								VUndef;
							case [VBytes(_) | VNull, VInt(_), VBytes(_) | VNull, VInt(_), VInt(len)]:
								if (len == 0) VUndef else error("bytes_blit to NULL bytes");
							case _: die();
						}
					case "bsort_i32":
						function(args) return switch args {
							case [VBytes(b), VInt(pos), VInt(len), VClosure(f, c)]:
								var a = [for (i in 0...len) getI32(b, pos + i * 4)];
								arrayStableSort((a, b) -> switch ctx.fcall(f, if (c == null) [VInt(a), VInt(b)] else [c, VInt(a), VInt(b)]) {
									case VInt(i): i;
									case _: die();
								}, a);
								for (i in 0...a.length) setI32(b, pos + i * 4, a[i]);
								VUndef;
							case _:
								die();
						}
					case "bsort_f64":
						function(args) return switch args {
							case [VBytes(b), VInt(pos), VInt(len), VClosure(_)]:
								die();
							case _:
								die();
						}
					case "itos":
						function(args) return switch args {
							case [VInt(v), VRef(r, _)]:
								var str = Std.string(v);
								setRef(r, toInt(camlLength(str)));
								VBytes(camlToHl(str));
							case _: die();
						}
					case "ftos":
						function(args) return switch args {
							case [VFloat(f), VRef(r, _)]:
								var str = floatToString(f);
								setRef(r, toInt(camlLength(str)));
								VBytes(camlToHl(str));
							case _: die();
						}
					case "value_to_string":
						function(args) return switch args {
							case [v, VRef(r, _)]:
								var str = camlToHl(vstr(ctx, v, HDyn));
								setRef(r, toInt((str.length >>> 1) - 1));
								VBytes(str);
							case _: die();
						}
					case "math_isnan":
						function(args) return switch args {
							case [VFloat(f)]: VBool(Math.isNaN(f));
							case _: die();
						}
					case "math_isfinite":
						function(args) return switch args {
							case [VFloat(f)]: VBool(Math.isFinite(f));
							case _: die();
						}
					case "math_round":
						function(args) return switch args {
							case [VFloat(f)]: VInt(int32OfFloat(Math.ffloor(f + 0.5)));
							case _: die();
						}
					case "math_floor":
						function(args) return switch args {
							case [VFloat(f)]: VInt(int32OfFloat(Math.ffloor(f)));
							case _: die();
						}
					case "math_ceil":
						function(args) return switch args {
							case [VFloat(f)]: VInt(int32OfFloat(Math.fceil(f)));
							case _: die();
						}
					case "math_ffloor":
						function(args) return switch args {
							case [VFloat(f)]: VFloat(Math.ffloor(f));
							case _: die();
						}
					case "math_fceil":
						function(args) return switch args {
							case [VFloat(f)]: VFloat(Math.fceil(f));
							case _: die();
						}
					case "math_fround":
						function(args) return switch args {
							case [VFloat(f)]: VFloat(Math.ffloor(f + 0.5));
							case _: die();
						}
					case "math_abs":
						function(args) return switch args {
							case [VFloat(f)]: VFloat(Math.abs(f));
							case _: die();
						}
					case "math_sqrt":
						function(args) return switch args {
							case [VFloat(f)]: VFloat(if (f < 0.) ocamlNan else Math.sqrt(f));
							case _: die();
						}
					case "math_cos":
						function(args) return switch args {
							case [VFloat(f)]: VFloat(Math.cos(f));
							case _: die();
						}
					case "math_sin":
						function(args) return switch args {
							case [VFloat(f)]: VFloat(Math.sin(f));
							case _: die();
						}
					case "math_tan":
						function(args) return switch args {
							case [VFloat(f)]: VFloat(Math.tan(f));
							case _: die();
						}
					case "math_acos":
						function(args) return switch args {
							case [VFloat(f)]: VFloat(Math.acos(f));
							case _: die();
						}
					case "math_asin":
						function(args) return switch args {
							case [VFloat(f)]: VFloat(Math.asin(f));
							case _: die();
						}
					case "math_atan":
						function(args) return switch args {
							case [VFloat(f)]: VFloat(Math.atan(f));
							case _: die();
						}
					case "math_atan2":
						function(args) return switch args {
							case [VFloat(a), VFloat(b)]: VFloat(Math.atan2(a, b));
							case _: die();
						}
					case "math_log":
						function(args) return switch args {
							case [VFloat(f)]: VFloat(Math.log(f));
							case _: die();
						}
					case "math_exp":
						function(args) return switch args {
							case [VFloat(f)]: VFloat(Math.exp(f));
							case _: die();
						}
					case "math_pow":
						function(args) return switch args {
							case [VFloat(a), VFloat(b)]: VFloat(Math.pow(a, b));
							case _: die();
						}
					case "parse_int":
						function(args) return switch args {
							case [VBytes(str), VInt(pos), VInt(len)]:
								try {
									VDyn(VInt(core.Numeric.parseInt(hlToCamlSub(str, pos, len))), HI32);
								} catch (_:Dynamic) {
									VNull;
								}
							case l: die();
						}
					case "parse_float":
						function(args) return switch args {
							case [VBytes(str), VInt(pos), VInt(len)]:
								try VFloat(core.Numeric.parseFloat(hlToCamlSub(str, pos, len))) catch (_:Dynamic) VFloat(ocamlNan);
							case _: die();
						}
					case "dyn_compare":
						function(args) return switch args {
							case [a, b]: toInt(dynCompare(ctx, a, HDyn, b, HDyn));
							case _: die();
						}
					case "fun_compare":
						function ocompare(o1:Null<Value>, o2:Null<Value>):Bool {
							return if (o1 == null && o2 == null) true else if (o1 != null && o2 != null) o1 == o2 else false;
						}
						function(args) return switch args {
							case [VClosure(FFun(f1), o1), VClosure(FFun(f2), o2)]: VBool(f1 == f2 && ocompare(o1, o2));
							case [VClosure(FNativeFun(f1, _, _), o1), VClosure(FNativeFun(f2, _, _), o2)]: VBool(f1 == f2 && ocompare(o1, o2));
							case _: VBool(false);
						}
					case "array_type":
						function(args) return switch args {
							case [VArray(_, t)]: VType(t);
							case _: die();
						}
					case "value_cast":
						function(args) return switch args {
							case [v, VType(t)]: if (isCompatible(v, t)) v else throwMsg(ctx, "Cannot cast " + vstrD(ctx, v) + " to " + tstr(t));
							case _: die();
						}
					case "hballoc":
						function(args) return switch args {
							case []: VAbstract(AHashBytes(newStringHashtbl()));
							case _: die();
						}
					case "hbset":
						function(args) return switch args {
							case [VAbstract(AHashBytes(h)), VBytes(b), v]:
								h.replace(hlToCaml(b), v);
								VUndef;
							case _: die();
						}
					case "hbget":
						function(args) return switch args {
							case [VAbstract(AHashBytes(h)), VBytes(b)]:
								var v = h.findOpt(hlToCaml(b));
								if (v == null) VNull else v;
							case _: die();
						}
					case "hbvalues":
						function(args) return switch args {
							case [VAbstract(AHashBytes(h))]:
								var values = h.fold((_, v, acc:Array<Value>) -> {
									acc.unshift(v);
									acc;
								}, []);
								VArray(Vector.fromArrayCopy(values), HDyn);
							case _: die();
						}
					case "hbkeys":
						function(args) return switch args {
							case [VAbstract(AHashBytes(h))]:
								var keys = h.fold((s, _, acc:Array<Value>) -> {
									acc.unshift(VBytes(camlToHl(s)));
									acc;
								}, []);
								VArray(Vector.fromArrayCopy(keys), HBytes);
							case _: die();
						}
					case "hbexists":
						function(args) return switch args {
							case [VAbstract(AHashBytes(h)), VBytes(b)]: VBool(h.mem(hlToCaml(b)));
							case _: die();
						}
					case "hbremove":
						function(args) return switch args {
							case [VAbstract(AHashBytes(h)), VBytes(b)]:
								var m = h.mem(hlToCaml(b));
								if (m) h.remove(hlToCaml(b));
								VBool(m);
							case _: die();
						}
					case "hialloc":
						function(args) return switch args {
							case []: VAbstract(AHashInt(newIntHashtbl()));
							case _: die();
						}
					case "hiset":
						function(args) return switch args {
							case [VAbstract(AHashInt(h)), VInt(i), v]:
								h.replace(i, v);
								VUndef;
							case _: die();
						}
					case "higet":
						function(args) return switch args {
							case [VAbstract(AHashInt(h)), VInt(i)]:
								var v = h.findOpt(i);
								if (v == null) VNull else v;
							case _: die();
						}
					case "hivalues":
						function(args) return switch args {
							case [VAbstract(AHashInt(h))]:
								var values = h.fold((_, v, acc:Array<Value>) -> {
									acc.unshift(v);
									acc;
								}, []);
								VArray(Vector.fromArrayCopy(values), HDyn);
							case _: die();
						}
					case "hikeys":
						function(args) return switch args {
							case [VAbstract(AHashInt(h))]:
								var keys = h.fold((i, _, acc:Array<Value>) -> {
									acc.unshift(VInt(i));
									acc;
								}, []);
								VArray(Vector.fromArrayCopy(keys), HI32);
							case _: die();
						}
					case "hiexists":
						function(args) return switch args {
							case [VAbstract(AHashInt(h)), VInt(i)]: VBool(h.mem(i));
							case _: die();
						}
					case "hiremove":
						function(args) return switch args {
							case [VAbstract(AHashInt(h)), VInt(i)]:
								var m = h.mem(i);
								if (m) h.remove(i);
								VBool(m);
							case _: die();
						}
					case "hoalloc":
						function(args) return switch args {
							case []: VAbstract(AHashObject(new HashObject()));
							case _: die();
						}
					case "hoset":
						function(args) return switch args {
							case [VAbstract(AHashObject(l)), o, v]:
								var o = noVirtual(o);
								var found = false;
								for (i in 0...l.l.length) if (o == l.l[i].k) {
									l.l[i] = {k: o, v: v};
									found = true;
									break;
								}
								if (!found) l.l.push({k: o, v: v});
								VUndef;
							case _: die();
						}
					case "hoget":
						function(args) return switch args {
							case [VAbstract(AHashObject(l)), o]:
								var o = noVirtual(o);
								var r = VNull;
								for (p in l.l) if (p.k == o) {
									r = p.v;
									break;
								}
								r;
							case _: die();
						}
					case "hovalues":
						function(args) return switch args {
							case [VAbstract(AHashObject(l))]:
								VArray(l.l.mapToVector(p -> p.v), HDyn);
							case _: die();
						}
					case "hokeys":
						function(args) return switch args {
							case [VAbstract(AHashObject(l))]:
								VArray(l.l.mapToVector(p -> p.k), HDyn);
							case _: die();
						}
					case "hoexists":
						function(args) return switch args {
							case [VAbstract(AHashObject(l)), o]:
								var o = noVirtual(o);
								VBool(Lambda.exists(l.l, p -> p.k == o));
							case _: die();
						}
					case "horemove":
						function(args) return switch args {
							case [VAbstract(AHashObject(rl)), o]:
								var idx = -1;
								for (i in 0...rl.l.length) if (rl.l[i].k == o) {
									idx = i;
									break;
								}
								if (idx >= 0) {
									rl.l = rl.l.slice(0, idx).concat(rl.l.slice(idx + 1));
									VBool(true);
								} else VBool(false);
							case _: die();
						}
					case "sys_print":
						function(args) return switch args {
							case [VBytes(str)]:
								printBytes(hlToCamlBytes(str));
								VUndef;
							case _: die();
						}
					case "sys_time":
						function(args) return switch args {
							case []: VFloat(Sys.time());
							case _: die();
						}
					case "sys_exit":
						function(args) return switch args {
							case [VInt(code)]: throw new SysExit(code);
							case _: die();
						}
					case "sys_utf8_path":
						function(args) return switch args {
							case []: VBool(true);
							case _: die();
						}
					case "sys_string":
						var cachedSysName:Null<String> = null;
						function(args) return switch args {
							case []:
								// port: Sys.os_type, from the host's system name
								VBytes(camlToHl(switch Sys.systemName() {
									case "Windows": "Windows";
									case _:
										if (cachedSysName != null) cachedSysName else {
											var p = new sys.io.Process("uname", ["uname"].slice(1));
											var uname = switch p.stdout.readLine() {
												case "Darwin": "Mac";
												case n: n;
											}
											p.close();
											cachedSysName = uname;
											uname;
										}
								}));
							case _:
								die();
						}
					case "sys_is64":
						function(args) return switch args {
							// port: Sys.word_size of the 64-bit reference compiler
							case []: VBool(true);
							case _: die();
						}
					case "hash":
						function(args) return switch args {
							case [VBytes(str)]: VInt(hash(ctx, hlToCaml(str)));
							case _: die();
						}
					case "type_safe_cast":
						function(args) return switch args {
							case [VType(a), VType(b)]: VBool(safeCast(a, b));
							case _: die();
						}
					case "type_super":
						function(args) return switch args {
							case [VType(t)]: VType(switch t {
									case HObj({psuper: o}) if (o != null): HObj(o);
									case _: HVoid;
								});
							case _: die();
						}
					case "type_args_count":
						function(args) return switch args {
							case [VType(t)]: toInt(switch t {
									case HFun(args, _): args.length;
									case _: 0;
								});
							case _: die();
						}
					case "type_get_global":
						function(args) return switch args {
							case [VType(t)]:
								switch t {
									case HObj(c): if (c.pclassglobal == null) VNull else aget(ctx.tGlobals, c.pclassglobal);
									case HEnum(e): if (e.eglobal == null) VNull else aget(ctx.tGlobals, e.eglobal);
									case _: VNull;
								}
							case _: die();
						}
					case "type_set_global":
						function(args) return switch args {
							case [VType(t), v]:
								VBool(switch t {
									case HObj(c): if (c.pclassglobal == null) false else {
											aset(ctx.tGlobals, c.pclassglobal, v);
											true;
										}
									case HEnum(e): if (e.eglobal == null) false else {
											aset(ctx.tGlobals, e.eglobal, v);
											true;
										}
									case _: false;
								});
							case _: die();
						}
					case "type_name":
						function(args) return switch args {
							case [VType(t)]:
								VBytes(camlToHl(switch t {
									case HObj(o): o.pname;
									case HEnum(e): e.ename;
									case _: die();
								}));
							case _: die();
						}
					case "obj_fields":
						function getFields(v:Value, isRec:Bool):Value {
							return switch v {
								case VDynObj(o):
									VArray(Vector.fromArrayCopy(o.dfields.fold((n, _, acc:Array<Value>) -> {
										acc.unshift(VBytes(camlToHl(n)));
										acc;
									}, [])), HBytes);
								case VObj(o):
									function loop(p:ClassProto):Array<Array<Value>> {
										var fields = [for (f in p.pfields) VBytes(camlToHl(f.name))];
										return if (p.psuper != null && isRec) [fields].concat(loop(p.psuper)) else [fields];
									}
									var all = [];
									for (a in loop(o.oproto.pclass)) all = all.concat(a);
									VArray(Vector.fromArrayCopy(all), HBytes);
								case VVirtual(v):
									getFields(v.vvalue, isRec);
								case _:
									VNull;
							}
						}
						function(args) return switch args {
							case [v]: getFields(v, true);
							case _: die();
						}
					case "obj_copy":
						function(args) return switch args {
							case [VDynObj(d) | VVirtual({vvalue: VDynObj(d)})]:
								VDynObj(new Vdynobj(d.dfields.copy(), d.dtypes.copy(), d.dvalues.copy(), []));
							case [_]: VNull;
							case _: die();
						}
					case "enum_parameters":
						function(args) return switch args {
							case [VEnum(e, idx, pl)]:
								var ptypes = aget(e.efields, idx).args;
								VArray(pl.mapi((i, v) -> makeDyn(v, aget(ptypes, i))), HDyn);
							case _:
								die();
						}
					case "type_instance_fields":
						function(args) return switch args {
							case [VType(t)]:
								switch t {
									case HObj(o):
										function fields(o:ClassProto):Array<Value> {
											var sup = if (o.psuper == null) [] else fields(o.psuper);
											var protos = [];
											for (f in o.pproto) {
												var isOverride = if (o.psuper == null) false else try {
													getIndex(f.fname, o.psuper);
													true;
												} catch (_:NotFound) false;
												if (!isOverride) protos.unshift(VBytes(camlToHl(f.fname)));
											}
											return sup.concat([for (f in o.pfields) VBytes(camlToHl(f.name))]).concat(protos);
										}
										VArray(Vector.fromArrayCopy(fields(o)), HBytes);
									case _: VNull;
								}
							case _: die();
						}
					case "type_enum_fields":
						function(args) return switch args {
							case [VType(t)]:
								switch t {
									case HEnum(e): VArray(e.efields.map(f -> VBytes(camlToHl(f.name))), HBytes);
									case _: VNull;
								}
							case _: die();
						}
					case "type_enum_values":
						function(args) return switch args {
							case [VType(HEnum(e))]:
								VArray(e.efields.mapi((i, f) -> if (f.args.length != 0) VNull else VEnum(e, i, vector())), HDyn);
							case _: die();
						}
					case "type_enum_eq":
						function(args) return switch args {
							case [VEnum(_), VNull] | [VNull, VEnum(_)]: VBool(false);
							case [VNull, VNull]: VBool(true);
							case [v1 = VEnum(e1, _, _), v2 = VEnum(e2, _, _)]:
								function loop(v1:Value, v2:Value, e:EnumProto):Bool {
									return switch [v1, v2] {
										case [VEnum(_, t1, _), VEnum(_, t2, _)] if (t1 != t2): false;
										case [VEnum(_, t, vl1), VEnum(_, _, vl2)]:
											var pl = aget(e.efields, t).args;
											function chk(i:Int):Bool {
												if (i == pl.length) return true;
												return (switch pl[i] {
													case HEnum(e): loop(aget(vl1, i), aget(vl2, i), e);
													case t: dynCompare(ctx, aget(vl1, i), t, aget(vl2, i), t) == 0;
												}) && chk(i + 1);
											}
											chk(0);
										case _: die();
									}
								}
								VBool(if (e1 != e2) false else loop(v1, v2, e1));
							case _: die();
						}
					case "obj_get_field":
						function(args) return switch args {
							case [o, VInt(hash)]:
								var f = ctx.cachedHashes.get(hash);
								if (f == null) die();
								switch o {
									case VObj(_) | VDynObj(_) | VVirtual(_): dynGetField(ctx, o, f, HDyn);
									case _: VNull;
								}
							case _: die();
						}
					case "obj_set_field":
						function(args) return switch args {
							case [o, VInt(hash), v]:
								var f = ctx.cachedHashes.get(hash);
								if (f == null) die();
								dynSetField(ctx, o, f, v, HDyn);
								VUndef;
							case _: die();
						}
					case "obj_has_field":
						function(args) return switch args {
							case [o, VInt(hash)]:
								var f = ctx.cachedHashes.get(hash);
								if (f == null) die();
								function loop(o:Value):Bool {
									return switch o {
										case VDynObj(d): d.dfields.mem(f);
										case VObj(o):
											function loop(p:ClassProto):Bool {
												var e = p.pindex.get(f);
												return if (e != null) e.fid >= 0 else if (p.psuper == null) false else loop(p.psuper);
											}
											loop(o.oproto.pclass);
										case VVirtual(v): loop(v.vvalue);
										case _: false;
									}
								}
								VBool(loop(o));
							case _: die();
						}
					case "obj_delete_field":
						function(args) return switch args {
							case [o, VInt(hash)]:
								var f = ctx.cachedHashes.get(hash);
								if (f == null) die();
								function loop(o:Value):Bool {
									return switch o {
										case VDynObj(d) if (d.dfields.mem(f)):
											var idx = d.dfields.find(f);
											var count = d.dvalues.length;
											d.dfields.remove(f);
											var fields = d.dfields.fold((name, i, acc:Array<{n:String, i:Int}>) -> {
												acc.unshift({n: name, i: if (i < idx) i else i - 1});
												acc;
											}, []);
											d.dfields.clear();
											for (p in fields) d.dfields.add(p.n, p.i);
											var vals2 = new Vector<Value>(count - 1);
											var types2 = new Vector<Ttype>(count - 1);
											var len = count - idx - 1;
											Vector.blit(d.dvalues, 0, vals2, 0, idx);
											Vector.blit(d.dvalues, idx + 1, vals2, idx, len);
											Vector.blit(d.dtypes, 0, types2, 0, idx);
											Vector.blit(d.dtypes, idx + 1, types2, idx, len);
											d.dvalues = vals2;
											d.dtypes = types2;
											rebuildVirtuals(ctx, d);
											true;
										case VVirtual(v): loop(v.vvalue);
										case _: false;
									}
								}
								VBool(loop(o));
							case _: die();
						}
					case "get_virtual_value":
						function(args) return switch args {
							case [VVirtual(v)]: v.vvalue;
							case _: die();
						}
					case "ucs2length":
						function(args) return switch args {
							case [VBytes(s), VInt(pos)]:
								var delta = pos;
								var p = 0;
								while (true) {
									var c = bget(s, p + delta) | (bget(s, p + delta + 1) << 8);
									if (c == 0) break;
									p += 2;
								}
								toInt(p >>> 1);
							case _: die();
						}
					case "utf8_to_utf16":
						function(args) return switch args {
							case [VBytes(s), VInt(pos), VRef(r, HI32)]:
								var s = bsub(s, pos, s.length - pos);
								var z = -1;
								for (i in 0...s.length) if (s.get(i) == 0) {
									z = i;
									break;
								}
								if (z < 0) die();
								var u16 = camlBytesToHl(s.sub(0, z));
								setRef(r, toInt(u16.length - 2));
								VBytes(u16);
							case _: die();
						}
					case "utf16_to_utf8":
						function(args) return switch args {
							case [VBytes(s), VInt(pos), VRef(r, HI32)]:
								var s = bsub(s, pos, s.length - pos);
								var u8 = hlToCamlBytes(s);
								setRef(r, toInt(u8.length));
								var b = Bytes.alloc(u8.length + 1);
								b.blit(0, u8, 0, u8.length);
								b.set(u8.length, 0);
								VBytes(b);
							case _: die();
						}
					case "ucs2_upper":
						function(args) return switch args {
							case [VBytes(s), VInt(pos), VInt(len)]:
								var buf = new BytesBuffer();
								utf16Iter(c -> {
									var c = if (c >= 'a'.code && c <= 'z'.code) c + 'A'.code - 'a'.code else c;
									utf16Add(buf, c);
								}, bsub(s, pos, len << 1));
								utf16Add(buf, 0);
								VBytes(buf.getBytes());
							case _: die();
						}
					case "ucs2_lower":
						function(args) return switch args {
							case [VBytes(s), VInt(pos), VInt(len)]:
								var buf = new BytesBuffer();
								utf16Iter(c -> {
									var c = if (c >= 'A'.code && c <= 'Z'.code) c + 'a'.code - 'A'.code else c;
									utf16Add(buf, c);
								}, bsub(s, pos, len << 1));
								utf16Add(buf, 0);
								VBytes(buf.getBytes());
							case _: die();
						}
					case "url_encode":
						function(args) return switch args {
							case [VBytes(s), VRef(r, HI32)]:
								var s = hlToCamlBytes(s);
								var buf = new BytesBuffer();
								// port: StringHelper.url_encode over the bytes, each output char through utf16_char
								var hex = "0123456789ABCDEF";
								for (i in 0...s.length) {
									var c = s.get(i);
									if ((c >= 'A'.code && c <= 'Z'.code) || (c >= 'a'.code && c <= 'z'.code) || (c >= '0'.code && c <= '9'.code)
										|| c == '_'.code || c == '-'.code || c == '.'.code) utf16Add(buf, c)
									else {
										utf16Add(buf, '%'.code);
										utf16Add(buf, hex.charCodeAt(c >> 4));
										utf16Add(buf, hex.charCodeAt(c & 0xF));
									}
								}
								utf16Add(buf, 0);
								var str = buf.getBytes();
								setRef(r, toInt((str.length >>> 1) - 1));
								VBytes(str);
							case _: die();
						}
					case "url_decode":
						function(args) return switch args {
							case [VBytes(s), VRef(r, HI32)]:
								var s = hlToCamlBytes(s);
								var b = new BytesBuffer();
								var len = s.length;
								function decode(c:Int):Null<Int> {
									return if (c >= '0'.code && c <= '9'.code) c - '0'.code else if (c >= 'a'.code && c <= 'f'.code) c - 'a'.code + 10 else
										if (c >= 'A'.code && c <= 'F'.code) c - 'A'.code + 10 else null;
								}
								var i = 0;
								while (i != len) {
									var c = s.get(i);
									if (c == '%'.code) {
										var p1 = if (i + 1 < len) decode(s.get(i + 1)) else null;
										var p2 = if (i + 2 < len) decode(s.get(i + 2)) else null;
										if (p1 != null && p2 != null) {
											b.addByte((p1 << 4) | p2);
											i += 3;
										} else i += 1;
									} else if (c == '+'.code) {
										b.addByte(' '.code);
										i += 1;
									} else {
										b.addByte(c);
										i += 1;
									}
								}
								var str = b.getBytes();
								setRef(r, toInt(utf8Length(str)));
								VBytes(camlBytesToHl(str));
							case _: die();
						}
					case "call_method":
						function(args) return switch args {
							case [f, VArray(args, HDyn)]: dynCall(ctx, f, [for (v in args) {v: v, t: HDyn}], HDyn);
							case _: die();
						}
					case "no_closure":
						function(args) return switch args {
							case [VClosure(f, _)]: VClosure(f, null);
							case _: die();
						}
					case "get_closure_value":
						function(args) return switch args {
							case [VClosure(_, null)]: VNull;
							case [VClosure(_, v)]: v;
							case _: die();
						}
					case "make_var_args":
						function(args) return switch args {
							case [VClosure(f, arg)]: VVarArgs(f, arg);
							case _: die();
						}
					case "bytes_find":
						function(args) return switch args {
							case [VBytes(src), VInt(pos), VInt(len), VBytes(chk), VInt(cpos), VInt(clen)]:
								var r = stringFind(bsub(src, pos, len), bsub(chk, cpos, clen));
								toInt(if (r < 0) -1 else pos + r);
							case _: die();
						}
					case "bytes_compare":
						function(args) return switch args {
							case [VBytes(a), VInt(apos), VBytes(b), VInt(bpos), VInt(len)]: toInt(bytesCompare(bsub(a, apos, len), bsub(b, bpos, len)));
							case _: die();
						}
					case "string_compare":
						function(args) return switch args {
							case [VBytes(a), VBytes(b), VInt(len)]: toInt(bytesCompare(bsub(a, 0, len * 2), bsub(b, 0, len * 2)));
							case _: die();
						}
					case "bytes_fill":
						function(args) return switch args {
							case [VBytes(a), VInt(pos), VInt(len), VInt(v)]:
								if (len < 0 || pos < 0 || pos > a.length - len) throw new InvalidArgument("String.fill / Bytes.fill");
								a.fill(pos, len, v & 0xFF);
								VUndef;
							case _: die();
						}
					case "exception_stack":
						function(args) return switch args {
							case []: VArray(Frames.toArray(Frames.rev(ctx.errorStack)).mapToVector(e -> VBytes(camlToHl(stackFrame(ctx, e)))), HBytes);
							case _: die();
						}
					case "date_new":
						function(args) return switch args {
							case [VInt(y), VInt(mo), VInt(d), VInt(h), VInt(m), VInt(s)]:
								VInt(int32OfFloat(mktime(y, mo, d, h, m, s)));
							case _:
								die();
						}
					case "date_now":
						function(args) return switch args {
							case []: toDate(localtime(Date.now().getTime() / 1000.));
							case _: die();
						}
					case "date_get_time":
						function(args) return switch args {
							case [VInt(v)]: VFloat(mktimeOf(date(v)) * 1000.);
							case _: die();
						}
					case "date_from_time":
						function(args) return switch args {
							case [VFloat(f)]: toDate(localtime(f / 1000.));
							case _: die();
						}
					case "date_get_inf":
						function(args) return switch args {
							case [VInt(d), year, month, day, hours, minutes, seconds, wday]:
								var d = date(d);
								function set(r:Value, v:Int):Void {
									switch r {
										case VNull:
										case VRef(r, HI32): setRef(r, toInt(v));
										case _: die();
									}
								}
								set(year, d.getFullYear());
								set(month, d.getMonth());
								set(day, d.getDate());
								set(hours, d.getHours());
								set(minutes, d.getMinutes());
								set(seconds, d.getSeconds());
								set(wday, d.getDay());
								VUndef;
							case _: die();
						}
					case "date_to_string":
						function(args) return switch args {
							case [VInt(d), VRef(r, HI32)]:
								var t = date(d);
								var str = padInt(t.getFullYear(), 4) + "-" + padInt(t.getMonth() + 1, 2) + "-" + padInt(t.getDate(), 2) + " "
									+ padInt(t.getHours(), 2) + ":" + padInt(t.getMinutes(), 2) + ":" + padInt(t.getSeconds(), 2);
								setRef(r, toInt(camlLength(str)));
								VBytes(camlToHl(str));
							case _: die();
						}
					case "rnd_init_system":
						function(args) return switch args {
							// port: Random.self_init; the host's random generator
							case []: VAbstract(ARandom);
							case _: die();
						}
					case "rnd_int":
						function(args) return switch args {
							// port: Random.bits (30 random bits)
							case [VAbstract(ARandom)]: VInt(Std.random(0x40000000));
							case _: die();
						}
					case "rnd_float":
						function(args) return switch args {
							case [VAbstract(ARandom)]: VFloat(Math.random());
							case _: die();
						}
					case "regexp_new_options":
						function(args) return switch args {
							case [VBytes(str), VBytes(opt)]:
								var caseSensitive = true;
								var optb = hlToCamlBytes(opt);
								for (i in 0...optb.length) {
									var c = optb.get(i);
									if (c == 'm'.code) {} /* always ON ? */
									else if (c == 'i'.code) caseSensitive = false;
									else throw new Failure("Unsupported regexp option '" + String.fromCharCode(c) + "'");
								}
								var buf = new BytesBuffer();
								var l = hlToCamlBytes(str);
								var prev = 0, esc = false;
								for (i in 0...l.length) {
									var c = l.get(i);
									if (esc) {
										if (c == 'n'.code) buf.addByte('\n'.code);
										else if (c == 'r'.code) buf.addByte('\r'.code);
										else if (c == 't'.code) buf.addByte('\t'.code);
										else if (c == 's'.code) buf.addString("[ \t\r\n]");
										else if (c == 'd'.code) buf.addString("[0-9]");
										else if (c == '\\'.code) buf.addString("\\\\");
										else if (c == '('.code || c == ')'.code || c == '{'.code || c == '}'.code) buf.addByte(c);
										else if ((c >= '1'.code && c <= '9'.code) || c == '+'.code || c == '$'.code || c == '^'.code || c == '*'.code
											|| c == '?'.code || c == '.'.code || c == '['.code || c == ']'.code) {
											buf.addByte('\\'.code);
											buf.addByte(c);
										} else buf.addByte(c);
										prev = c;
										esc = false;
									} else {
										if (c == '\\'.code) {
											esc = true;
										} else if (c == '('.code || c == '|'.code || c == ')'.code) {
											buf.addByte('\\'.code);
											buf.addByte(c);
											prev = c;
										} else if (c == '?'.code && prev == '('.code && i + 1 < l.length && l.get(i + 1) == ':'.code) {
											throw new Failure("Non capturing groups '(?:' are not supported in macros");
										} else if (c == '?'.code && prev == '*'.code) {
											throw new Failure("Ungreedy *? are not supported in macros");
										} else {
											buf.addByte(c);
											prev = c;
										}
									}
								}
								var str = buf.getBytes();
								var r = new Regexp(if (caseSensitive) OcamlStr.regexp(str) else OcamlStr.regexpCaseFold(str), "", vector());
								VAbstract(AReg(r));
							case _:
								die();
						}
					case "regexp_match":
						function(args) return switch args {
							case [VAbstract(AReg(r)), VBytes(str), VInt(pos), VInt(len)]:
								var str = hlToCamlBytes(str);
								var nstr, npos, delta;
								if (len == str.length - pos) {
									nstr = str;
									npos = pos;
									delta = 0;
								} else {
									nstr = bsub(str, pos, len);
									npos = 0;
									delta = pos;
								}
								try {
									OcamlStr.searchForward(r.r, nstr, npos);
									var groups:Array<Null<{start:Int, end:Int}>> = [];
									var n = 0;
									while (n < 9) {
										try {
											var e = OcamlStr.groupEnd(n) + delta;
											var b = OcamlStr.groupBeginning(n) + delta;
											groups.push({start: b, end: e});
										} catch (_:NotFound) {
											groups.push(null);
										} catch (_:InvalidArgument) {
											break;
										}
										n++;
									}
									r.rString = str.getString(0, str.length);
									r.rGroups = Vector.fromArrayCopy(groups);
									VBool(true);
								} catch (_:NotFound) {
									VBool(false);
								}
							case _: die();
						}
					case "regexp_matched_pos":
						function(args) return switch args {
							case [VAbstract(AReg(r)), VInt(n), VRef(rr, HI32)]:
								if (n < 0 || n >= r.rGroups.length) throw new Failure("Invalid group " + n);
								switch r.rGroups[n] {
									case null: toInt(-1);
									case g:
										setRef(rr, toInt(g.end - g.start));
										toInt(g.start);
								}
							case [VAbstract(AReg(r)), VInt(n), VNull]:
								if (n < 0 || n >= r.rGroups.length) throw new Failure("Invalid group " + n);
								switch r.rGroups[n] {
									case null: toInt(-1);
									case g: toInt(g.start);
								}
							case _: die();
						}
					case "make_macro_pos":
						function(args) return switch args {
							case [VBytes(file), VInt(min), VInt(max)]:
								var f = bsub(file, 0, file.length - 1);
								VAbstract(APos(new Pos(f.getString(0, f.length), min, max)));
							case _: die();
						}
					case "dyn_op":
						var opNames = vector("+", "-", "*", "%", "/", "<<", ">>", ">>>", "&", "|", "^");
						function(args) return switch args {
							case [VInt(op), a, b]:
								function isNumber(v:Value):Bool {
									return switch v {
										case VNull: true;
										case VDyn(_, t): Hlcode.isNumber(t);
										case _: false;
									}
								}
								function error():Dynamic {
									var bs = vstr(ctx, b, HDyn);
									var on = aget(opNames, op);
									var as = vstr(ctx, a, HDyn);
									throw new Failure("Can't perform dyn op " + as + " " + on + " " + bs);
								}
								function fop(op:(Float, Float) -> Float):Value {
									if (isNumber(a) && isNumber(b)) {
										var a = dynCast(ctx, a, HDyn, HF64);
										var b = dynCast(ctx, b, HDyn, HF64);
										return switch [a, b] {
											case [VFloat(a), VFloat(b)]: VDyn(VFloat(op(a, b)), HF64);
											case _: die();
										}
									} else return error();
								}
								function iop(op:(Int, Int) -> Int):Value {
									if (isNumber(a) && isNumber(b)) {
										var a = dynCast(ctx, a, HDyn, HI32);
										var b = dynCast(ctx, b, HDyn, HI32);
										return switch [a, b] {
											case [VInt(a), VInt(b)]: VDyn(VInt(op(a, b)), HI32);
											case _: die();
										}
									} else return error();
								}
								switch op {
									case 0: fop((a, b) -> a + b);
									case 1: fop((a, b) -> a - b);
									case 2: fop((a, b) -> a * b);
									case 3: fop((a, b) -> a % b);
									case 4: fop((a, b) -> a / b);
									case 5: iop(i32Shl);
									case 6: iop(i32Shr);
									case 7: iop(i32Ushr);
									case 8: iop((a, b) -> a & b);
									case 9: iop((a, b) -> a | b);
									case 10: iop((a, b) -> a ^ b);
									case _: die();
								}
							case _: die();
						}
					case _:
						unresolved();
				}
			case _:
				unresolved();
		}
		return FNativeFun(lib + "@" + name, f, t);
	}

	// port: UTF8.length (ExtLib), on bytes
	static function utf8Length(s:Bytes):Int {
		var c = 0, i = 0;
		while (i < s.length) {
			var n = s.get(i);
			var k = if (n < 0x80) 1 else if (n < 0xc0) throw new InvalidArgument("UTF8.length") else if (n < 0xe0) 2 else if (n < 0xf0) 3 else
				if (n < 0xf8) 4 else if (n < 0xfc) 5 else if (n < 0xfe) 6 else throw new InvalidArgument("UTF8.length");
			c++;
			i += k;
		}
		return c;
	}

	public static function create(checked:Bool):InterpContext {
		var ctx = new InterpContext(checked);
		ctx.code = new Code(0, 0, vector(), vector(), vector(), vector(), vector(), vector(), vector(), vector(), vector());
		ctx.fcall = (_, _) -> die();
		ctx.onError = (_, _) -> die();
		ctx.onError = (msg, stack) -> {
			var frames = [for (e in Frames.toArray(stack)) stackFrame(ctx, e)];
			throw new Failure(vstr(ctx, msg, HDyn) + "\n" + frames.join("\n"));
		};
		ctx.fcall = (f, args) -> callFun(ctx, f, args);
		return ctx;
	}

	public static function setErrorHandler(ctx:InterpContext, e:Value->Null<Frames>->Void):Void {
		ctx.onError = e;
	}

	public static function addCode(ctx:InterpContext, code:Code):Void {
		/* expand global table */
		var globals = code.globals.map(t -> defaultValue(t));
		for (i in 0...ctx.tGlobals.length) aset(globals, i, ctx.tGlobals[i]);
		ctx.tGlobals = globals;
		/* expand function table */
		var nfunctions = code.functions.length + code.natives.length;
		var functions = new Vector(nfunctions, FNativeFun("", _ -> die(), HDyn));
		for (i in 0...ctx.tFunctions.length) aset(functions, i, ctx.tFunctions[i]);
		for (i in ctx.code.natives.length...code.natives.length) {
			var n = code.natives[i];
			aset(functions, n.findex, loadNative(ctx, aget(code.strings, n.lib), aget(code.strings, n.name), n.t));
		}
		for (i in ctx.code.functions.length...code.functions.length) {
			var fd = code.functions[i];
			aset(functions, fd.findex, FFun(fd));
		}
		ctx.tFunctions = functions;
		ctx.code = code;
		for (c in code.constants) {
			var g = c.g, fields = c.fields;
			var t = aget(code.globals, g);
			function getConstVal(t:Ttype, idx:Int):Value {
				return switch t {
					case HI32: VInt(aget(code.ints, idx));
					case HBytes: VBytes(cachedString(ctx, idx));
					case _: die();
				}
			}
			var v = switch t {
				case HObj(o):
					if (o.pfields.length != fields.length) die();
					var proto = getProto(ctx, o).proto;
					VObj(new Vobject(proto, o.pfields.mapi((i, f) -> getConstVal(f.t, fields[i]))));
				case _:
					die();
			}
			ctx.tGlobals[g] = v;
		}
		/* call entrypoint */
		callWrap(ctx, aget(functions, code.entrypoint), []);
	}

	/* ------------------------------- CHECK ---------------------------------------------- */
	public static function check(comerror:String->core.Globals.Pos->Void, code:Code):Void {
		var ftypes = new Vector(code.natives.length + code.functions.length, HVoid);
		var isNativeFun = new haxe.ds.IntMap<Bool>();

		function checkFun(f:Fundecl):Void {
			var pos = 0;
			function error(msg:String):Void {
				var dpos = f.debug[pos].pos;
				var msg = "Check failure at fun@" + f.findex + " @" + hex(pos) + " - " + msg;
				comerror(msg, dpos);
			}
			function errorFail(msg:String):Dynamic {
				error(msg);
				throw new Failure(msg);
			}
			var targs, tret;
			switch f.ftype {
				case HFun(args, ret):
					targs = args;
					tret = ret;
				case _:
					targs = core.Globals.die("", "hlinterp.ml");
					tret = null;
			}
			function rtype(i:Int):Ttype {
				if (i >= 0 && i < f.regs.length) return f.regs[i];
				var p = new ClassProto("OUT_OF_BOUNDS:" + i, 0);
				return HObj(p);
			}
			function check(t1:Ttype, t2:Ttype):Void {
				if (!safeCast(t1, t2)) error(tstr(t1) + " should be " + tstr(t2));
			}
			function regInf(r:Int):String return "Register " + r + "(" + tstr(rtype(r)) + ")";
			function reg(r:Int, t:Ttype):Void {
				if (!safeCast(rtype(r), t)) error(regInf(r) + " should be " + tstr(t) + " and not " + tstr(rtype(r)));
			}
			function numeric(r:Int):Void {
				if (!isNumber(rtype(r))) error(regInf(r) + " should be numeric");
			}
			function int(r:Int):Void {
				if (!isInt(rtype(r))) error(regInf(r) + " should be integral");
			}
			function float(r:Int):Void {
				if (!isFloat(rtype(r))) error(regInf(r) + " should be float");
			}
			function call(f:Int, args:Array<Int>, r:Int):Void {
				switch ftypes[f] {
					case HFun(targs, tret):
						if (args.length != targs.length) error(tstr(HFun([for (a in args) rtype(a)], rtype(r))) + " should be " + tstr(ftypes[f]));
						if (args.length != targs.length) throw new core.ds.InvalidArgument("List.iter2");
						for (i in 0...args.length) reg(args[i], targs[i]);
						check(tret, rtype(r));
					case _:
						core.Globals.die("", "hlinterp.ml");
				}
			}
			function canJump(delta:Int):Void {
				if (pos + 1 + delta < 0 || pos + 1 + delta >= f.code.length) error("Jump outside function bounds");
				if (delta < 0 && !f.code[pos + 1 + delta].match(OLabel(0))) error("Jump back without Label");
			}
			function isObj(r:Int):Void {
				switch rtype(r) {
					case HObj(_):
					case _: error(regInf(r) + " should be object");
				}
			}
			function isEnum(r:Int):Void {
				switch rtype(r) {
					case HEnum(_):
					case _: error(regInf(r) + " should be enum");
				}
			}
			function isDyn(r:Int):Void {
				if (!isDynamic(rtype(r))) error(regInf(r) + " should be castable to dynamic");
			}
			function getField(r:Int, p:ClassProto, fid:Int):Ttype {
				return try resolveField(p, fid).t catch (_:core.ds.NotFound) errorFail(regInf(r) + " does not have field " + fid);
			}
			function tfield(o:Int, fid:Int, proto:Bool):Ttype {
				if (fid < 0) error(regInf(o) + " does not have " + (if (proto) "proto " else "") + "field " + fid);
				return switch rtype(o) {
					case HObj(p):
						if (proto) ftypes[p.pvirtuals[fid]] else getField(o, p, fid);
					case HStruct(p) if (!proto):
						getField(o, p, fid);
					case HVirtual(v) if (!proto):
						v.vfields[fid].t;
					case _:
						isObj(o);
						HVoid;
				}
			}
			function iter2(rl:Array<Int>, tl:Array<Ttype>):Void {
				if (rl.length != tl.length) throw new core.ds.InvalidArgument("List.iter2");
				for (i in 0...rl.length) reg(rl[i], tl[i]);
			}
			for (i in 0...targs.length) reg(i, targs[i]);
			for (i in 0...f.code.length) {
				var op = f.code[i];
				pos = i;
				switch op {
					case OMov(a, b):
						reg(b, rtype(a));
					case OInt(r, i):
						if (i < 0 || i >= code.ints.length) throw new core.ds.InvalidArgument("index out of bounds");
						int(r);
					case OFloat(r, i):
						if (!tEq(rtype(r), HF32)) reg(r, HF64);
						if (i < 0 || i >= code.floats.length) error("float outside range");
					case OBool(r, _):
						reg(r, HBool);
					case OString(r, i):
						reg(r, HBytes);
						if (i < 0 || i >= code.strings.length) error("string outside range");
					case OBytes(r, i):
						reg(r, HBytes);
						if (i < 0 || i >= code.bytes.length) error("bytes outside range");
					case ONull(r):
						var t = rtype(r);
						if (!isNullable(t)) error(tstr(t) + " is not nullable");
					case OAdd(r, a, b) | OSub(r, a, b) | OMul(r, a, b) | OSDiv(r, a, b) | OUDiv(r, a, b) | OSMod(r, a, b) | OUMod(r, a, b):
						numeric(r);
						reg(a, rtype(r));
						reg(b, rtype(r));
					case ONeg(r, a):
						numeric(r);
						reg(a, rtype(r));
					case OShl(r, a, b) | OSShr(r, a, b) | OUShr(r, a, b) | OAnd(r, a, b) | OOr(r, a, b) | OXor(r, a, b):
						int(r);
						reg(a, rtype(r));
						reg(b, rtype(r));
					case OIncr(r):
						int(r);
					case ODecr(r):
						int(r);
					case ONot(a, b):
						reg(a, HBool);
						reg(b, HBool);
					case OCall0(r, f):
						call(f, [], r);
					case OCall1(r, f, a):
						call(f, [a], r);
					case OCall2(r, f, a, b):
						call(f, [a, b], r);
					case OCall3(r, f, a, b, c):
						call(f, [a, b, c], r);
					case OCall4(r, f, a, b, c, d):
						call(f, [a, b, c, d], r);
					case OCallN(r, f, rl):
						call(f, rl, r);
					case OCallThis(r, m, rl):
						switch tfield(0, m, true) {
							case HFun(args, tret) if (args.length > 0 && args.length - 1 == rl.length):
								reg(0, args[0]);
								iter2(rl, args.slice(1));
								check(tret, rtype(r));
							case t:
								check(t, HFun([rtype(0)].concat([for (r in rl) rtype(r)]), rtype(r)));
						}
					case OCallMethod(r, m, rl):
						if (rl.length == 0) core.Globals.die("", "hlinterp.ml");
						var obj = rl[0], rl2 = rl.slice(1);
						function checkArgs(targs:Array<Ttype>, tret:Ttype, rl:Array<Int>):Bool {
							if (targs.length != rl.length) return false;
							iter2(rl, targs);
							check(tret, rtype(r));
							return true;
						}
						switch rtype(obj) {
							case HVirtual(v):
								var t = v.vfields[m].t;
								switch t {
									case HMethod(args, ret) if (checkArgs(args, ret, rl2)):
									case _: check(t, HMethod([for (r in rl) rtype(r)], rtype(r)));
								}
							case _:
								var t = tfield(obj, m, true);
								switch t {
									case HFun(args, ret) if (checkArgs(args, ret, rl)):
									case _: check(t, HFun([for (r in rl) rtype(r)], rtype(r)));
								}
						}
					case OCallClosure(r, f, rl):
						switch rtype(f) {
							case HFun(targs, tret) if (targs.length == rl.length):
								iter2(rl, targs);
								check(tret, rtype(r));
							case HDyn:
								for (r in rl) rtype(r);
							case _:
								reg(f, HFun([for (r in rl) rtype(r)], rtype(r)));
						}
					case OGetGlobal(r, g):
						if (!safeCast(code.globals[g], rtype(r))) reg(r, code.globals[g]);
					case OSetGlobal(g, r):
						reg(r, code.globals[g]);
					case ORet(r):
						reg(r, tret);
					case OJTrue(r, delta) | OJFalse(r, delta):
						reg(r, HBool);
						canJump(delta);
					case OJNull(r, delta) | OJNotNull(r, delta):
						if (!isNullable(rtype(r))) reg(r, HDyn);
						canJump(delta);
					case OJUGte(a, b, delta) | OJULt(a, b, delta) | OJSGte(a, b, delta) | OJSLt(a, b, delta) | OJSGt(a, b, delta) | OJSLte(a, b, delta) |
						OJNotLt(a, b, delta) | OJNotGte(a, b, delta):
						if (!safeCast(rtype(a), rtype(b))) reg(b, rtype(a));
						canJump(delta);
					case OJEq(a, b, delta) | OJNotEq(a, b, delta):
						switch [rtype(a), rtype(b)] {
							case [HObj(_) | HVirtual(_), HObj(_) | HVirtual(_)]:
							case [HDyn | HFun(_), HDyn | HFun(_)]:
							case [ta, tb] if (safeCast(tb, ta)):
							case _: reg(a, rtype(b));
						}
						canJump(delta);
					case OJAlways(d):
						canJump(d);
					case OToDyn(r, a):
						/* we can still use OToDyn on nullable if we want to turn them into dynamic */
						if (isDynamic(rtype(a))) reg(a, HI32); /* don't wrap as dynamic types that can safely be cast to it */
						if (!tEq(rtype(r), HDyn)) reg(r, HNull(rtype(a)));
					case OToSFloat(a, b) | OToUFloat(a, b):
						float(a);
						switch rtype(b) {
							case HF32 | HF64:
							case _: int(b);
						}
					case OToInt(a, b):
						int(a);
						switch rtype(b) {
							case HF32 | HF64:
							case _: int(b);
						}
					case OLabel(_):
					case ONew(r):
						switch rtype(r) {
							case HDynObj | HVirtual(_) | HStruct(_):
							case _: isObj(r);
						}
					case OField(r, o, fid):
						check(tfield(o, fid, false), rtype(r));
					case OSetField(o, fid, r):
						reg(r, tfield(o, fid, false));
					case OGetThis(r, fid):
						check(tfield(0, fid, false), rtype(r));
					case OSetThis(fid, r):
						reg(r, tfield(0, fid, false));
					case OStaticClosure(r, f):
						reg(r, ftypes[f]);
					case OVirtualClosure(r, o, fid):
						switch rtype(o) {
							case HObj(_):
								switch tfield(o, fid, true) {
									case HFun(tl, tret) if (tl.length > 0):
										reg(o, tl[0]);
										reg(r, HFun(tl.slice(1), tret));
									case _:
										core.Globals.die("", "hlinterp.ml");
								}
							case _:
								isObj(o);
						}
					case OInstanceClosure(r, f, arg):
						switch ftypes[f] {
							case HFun(tl, tret) if (tl.length > 0):
								var t = tl[0];
								reg(arg, t);
								if (!isNullable(t)) error(regInf(r) + " should be nullable");
								reg(r, HFun(tl.slice(1), tret));
							case _:
								core.Globals.die("", "hlinterp.ml");
						}
					case OThrow(r):
						reg(r, HDyn);
					case ORethrow(r):
						reg(r, HDyn);
					case OGetArray(v, a, i):
						switch rtype(a) {
							case HAbstract("hl_carray", _, _) | HArray(_):
							case _: reg(a, HArray(HDyn));
						}
						reg(i, HI32);
						rtype(v);
					case OGetUI8(r, b, p) | OGetUI16(r, b, p):
						reg(r, HI32);
						reg(b, HBytes);
						reg(p, HI32);
					case OGetMem(r, b, p):
						var t = rtype(r);
						switch getGroup(t) {
							case GInt | GFloat if (typeSizeBits(t) >= 2):
							case _: error(regInf(r) + " should be numeric");
						}
						reg(b, HBytes);
						reg(p, HI32);
					case OSetUI8(r, p, v) | OSetUI16(r, p, v):
						reg(r, HBytes);
						reg(p, HI32);
						reg(v, HI32);
					case OSetMem(r, p, v):
						reg(r, HBytes);
						reg(p, HI32);
						var t = rtype(v);
						switch getGroup(t) {
							case GInt | GFloat if (typeSizeBits(t) >= 2):
							case _: error(regInf(r) + " should be numeric");
						}
					case OSetArray(a, i, v):
						switch rtype(a) {
							case HAbstract("hl_carray", _, _) | HArray(_):
							case _: reg(a, HArray(HDyn));
						}
						reg(i, HI32);
						rtype(v);
					case OUnsafeCast(a, b) | OSafeCast(a, b):
						rtype(a);
						rtype(b);
					case OArraySize(r, a):
						reg(r, HI32);
					case OType(r, _):
						reg(r, HType);
					case OGetType(r, v):
						reg(r, HType);
						isDyn(v);
					case OGetTID(r, v):
						reg(r, HI32);
						reg(v, HType);
					case OUnref(v, r):
						switch rtype(r) {
							case HRef(t): check(t, rtype(v));
							case _: reg(r, HRef(rtype(v)));
						}
					case ORef(r, v) | OSetref(r, v):
						switch rtype(r) {
							case HRef(t): reg(v, t);
							case _: reg(r, HRef(rtype(v)));
						}
					case OToVirtual(r, v):
						switch rtype(r) {
							case HVirtual(_):
							case _: reg(r, HVirtual(new VirtualProto()));
						}
						switch rtype(v) {
							case HObj(_) | HDynObj | HDyn | HVirtual(_):
							case _: reg(v, HDynObj);
						}
					case ODynGet(v, r, f) | ODynSet(r, f, v):
						if (f < 0 || f >= code.strings.length) throw new core.ds.InvalidArgument("index out of bounds");
						rtype(v);
						switch rtype(r) {
							case HObj(_) | HDyn | HDynObj | HVirtual(_):
							case _: reg(r, HDynObj);
						}
					case OMakeEnum(r, index, pl):
						switch rtype(r) {
							case HEnum(e):
								var fl = e.efields[index].args;
								if (fl.length != pl.length) error("MakeEnum has " + pl.length + " params while " + fl.length + " are required");
								iter2(pl, fl.toArray());
							case _:
								isEnum(r);
						}
					case OEnumAlloc(r, index):
						switch rtype(r) {
							case HEnum(e):
								if (index < 0 || index >= e.efields.length) throw new core.ds.InvalidArgument("index out of bounds");
							case _:
								isEnum(r);
						}
					case OEnumIndex(r, v):
						if (!tEq(rtype(v), HDyn)) isEnum(v);
						reg(r, HI32);
					case OEnumField(r, e, f, i):
						switch rtype(e) {
							case HEnum(e):
								var tl = e.efields[f].args;
								check(tl[i], rtype(r));
							case _:
								isEnum(e);
						}
					case OSetEnumField(e, i, r):
						switch rtype(e) {
							case HEnum(e):
								var tl = e.efields[0].args;
								check(rtype(r), tl[i]);
							case _:
								isEnum(e);
						}
					case OSwitch(r, idx, eend):
						reg(r, HI32);
						for (d in idx) canJump(d);
						if (eend + 1 + i != f.code.length) canJump(eend);
					case ONullCheck(r):
						rtype(r);
					case OTrap(r, idx):
						reg(r, HDyn);
						canJump(idx);
					case OEndTrap(_):
					case OAssert(_):
					case ORefData(r, d):
						switch rtype(r) {
							case HRef(t):
								reg(d, HArray(t));
							case _:
								reg(d, HArray(HDyn));
								reg(r, HRef(HDyn));
						}
					case ORefOffset(r, r2, off):
						switch rtype(r2) {
							case HRef(_):
							case _: reg(r2, HRef(HDyn));
						}
						reg(r, rtype(r2));
						reg(off, HI32);
					case ONop(_):
					case OPrefetch(r, f, _):
						if (f == 0) rtype(r) else tfield(r, f - 1, false);
					case OAsm(_, _, r):
						if (r > 0) rtype(r - 1);
					case OCatch(_):
				}
			}
			/* TODO : check that all path correctly initialize NULL values and reach a return */
		}
		for (fd in code.functions) {
			if (fd.findex >= ftypes.length) throw new Failure("Invalid function index " + fd.findex);
			if (!tEq(ftypes[fd.findex], HVoid)) throw new Failure("Duplicate function bind " + fd.findex + " " + fundeclName(fd));
			ftypes[fd.findex] = fd.ftype;
		}
		for (n in code.natives) {
			if (n.findex >= ftypes.length)
				throw new Failure("Invalid native function index " + n.findex + " for " + code.strings[n.lib] + "@" + code.strings[n.name]);
			if (!tEq(ftypes[n.findex], HVoid)) throw new Failure("Duplicate native function bind " + n.findex);
			isNativeFun.set(n.findex, true);
			ftypes[n.findex] = n.t;
		}
		/* TODO : check that no object type has a virtual native in his proto */
		for (f in code.functions) checkFun(f);
	}
}

/* ------------------------------- SPEC ---------------------------------------------- */
/*

open Hlopt

type svalue =
	| SUndef
	| SArg of int
	| SInt of int32
	| SFloat of float
	| SString of string
	| SBytes of int
	| SBool of bool
	| SNull
	| SType of ttype
	| SOp of string * svalue * svalue
	| SUnop of string * svalue
	| SResult of string
	| SFun of int * svalue option
	| SMeth of svalue * int
	| SGlobal of int
	| SField of svalue * int
	| SDField of svalue * string
	| SConv of string * svalue
	| SCast of svalue * ttype
	| SMem of svalue * svalue * ttype
	| SEnum of int * svalue list
	| SEnumField of svalue * int * int
	| SUnion of svalue list
	| SRef of int
	| SRefResult of string
	| SUnreach
	| SExc
	| SDelayed of string * svalue list option ref

type call_spec =
	| SFid of int
	| SMethod of int
	| SClosure of svalue

type spec =
	| SCall of call_spec * svalue list
	| SGlobalSet of int * svalue
	| SFieldSet of svalue * int * svalue
	| SFieldDSet of svalue * string * svalue
	| SJEq of string * svalue
	| SJComp of string * svalue * svalue
	| SJump
	| SRet of svalue
	| SNullCheck of svalue
	| SThrow of svalue
	| SSwitch of svalue
	| SWriteMem of svalue * svalue * svalue * ttype
	| SSetRef of svalue * svalue
	| SSetEnumField of svalue * int * svalue
	| SStoreResult of string * spec
	| SNew of ttype * int
	| SVal of svalue

let rec svalue_string v =
	let sval = svalue_string in
	match v with
	| SUndef -> "undef"
	| SArg i -> "arg" ^ string_of_int i
	| SInt i -> Int32.to_string i
	| SFloat f -> string_of_float f
	| SString s -> "\"" ^ s ^ "\""
	| SBytes i -> "bytes$" ^ string_of_int i
	| SBool b -> if b then "true" else "false"
	| SNull -> "null"
	| SRef _ -> "ref"
	| SRefResult s -> Printf.sprintf "refresult(%s)" s
	| SType t -> tstr t
	| SOp (op,a,b) -> Printf.sprintf "(%s %s %s)" (sval a) op (sval b)
	| SUnop (op,v) -> op ^ sval v
	| SResult i -> i
	| SFun (i,None) -> "fun" ^ string_of_int i
	| SFun (i,Some v) -> Printf.sprintf "fun%d(%s)" i (sval v)
	| SMeth (v,i) -> Printf.sprintf "meth%d(%s)" i (sval v)
	| SGlobal g -> Printf.sprintf "G[%d]" g
	| SField (o,i) -> Printf.sprintf  "%s[%d]" (sval o) i
	| SDField (o,f) -> Printf.sprintf  "%s.%s" (sval o) f
	| SConv (f,v) -> Printf.sprintf "%s(%s)" f (sval v)
	| SCast (v,t) -> Printf.sprintf "cast(%s,%s)" (sval v) (tstr t)
	| SMem (m,idx,t) -> Printf.sprintf "(%s*)%s[%s]" (tstr t) (sval m) (sval idx)
	| SEnum (i,vl) -> Printf.sprintf "enum%d(%s)" i (String.concat "," (List.map sval vl))
	| SEnumField (v,k,i) -> Printf.sprintf "%s[%d:%d]" (sval v) k i
	| SUnion vl -> Printf.sprintf "union(%s)" (String.concat " | " (List.map sval vl))
	| SUnreach -> "unreach"
	| SExc -> "exc"
	| SDelayed (str,_) -> str

let svalue_iter f = function
	| SUndef | SArg _ | SInt _ | SFloat _ | SBytes _ | SString _ | SBool _ | SNull | SType _ | SResult _
	| SFun (_,None) | SGlobal _ | SRef _ | SRefResult _ | SUnreach | SExc | SDelayed _ ->
		()
	| SOp (_,a,b) | SMem (a,b,_) -> f a; f b
	| SUnop (_,a) | SFun (_,Some a) | SMeth (a,_) | SField (a,_) | SDField (a,_) | SConv (_,a) | SCast (a,_) | SEnumField (a,_,_) -> f a
	| SUnion vl | SEnum (_,vl) -> List.iter f vl

let spec_iter fs fv = function
	| SCall (c,vl) ->
		(match c with SClosure v -> fv v | _ -> ());
		List.iter fv vl
	| SVal v
	| SJEq (_,v)
	| SRet v
	| SNullCheck v
	| SThrow v
	| SSwitch v
	| SGlobalSet (_,v) -> fv v
	| SJComp (_,a,b)
	| SSetRef (a,b)
	| SSetEnumField (a,_,b)
	| SFieldDSet (a,_,b) | SFieldSet (a,_,b) -> fv a; fv b
	| SJump ->
		()
	| SWriteMem (m,a,b,_) ->
		fv m; fv a; fv b
	| SStoreResult (_,s) ->
		fs s
	| SNew _ ->
		()

let rec svalue_same a b =
	let vsame = svalue_same in
	match a, b with
	| SType t1, SType t2 -> tsame t1 t2
	| SOp (op1,a1,b1), SOp (op2,a2,b2) -> op1 = op2 && vsame a1 a2 && vsame b1 b2
	| SUnop (op1,v1), SUnop (op2,v2) -> op1 = op2 && vsame v1 v2
	| SFun (f1,Some v1), SFun (f2,Some v2) -> f1 = f2 && vsame v1 v2
	| SMeth (v1,m1), SMeth (v2,m2) -> vsame v1 v2 && m1 = m2
	| SField (v1,f1), SField (v2,f2) -> vsame v1 v2 && f1 = f2
	| SDField (v1,f1), SDField (v2,f2) -> vsame v1 v2 && f1 = f2
	| SConv (op1,v1), SConv (op2,v2) -> op1 = op2 && vsame v1 v2
	| SCast (v1,t1), SCast (v2,t2) -> vsame v1 v2 && tsame t1 t2
	| SMem (m1,i1,t1), SMem (m2,i2,t2) -> vsame m1 m2 && vsame i1 i2 && tsame t1 t2
	| SEnum (i1,vl1), SEnum (i2,vl2) -> i1 = i2 && List.length vl1 = List.length vl2 && List.for_all2 vsame vl1 vl2
	| SEnumField (v1,c1,i1), SEnumField (v2,c2,i2) -> vsame v1 v2 && c1 = c2 && i1 = i2
	| SUnion vl1, SUnion vl2 -> List.length vl1 = List.length vl2 && List.for_all2 vsame vl1 vl2
	| SDelayed (id1,_), SDelayed (id2,_) -> id1 = id2
	| _ -> a = b

let rec spec_string s =
	let sval = svalue_string in
	match s with
	| SCall (c,vl) ->
		let cstr = (match c with
			| SFid i -> Printf.sprintf "fun%d" i
			| SMethod i -> Printf.sprintf "meth%d" i
			| SClosure v -> Printf.sprintf "closure(%s)" (sval v)
		) in
		Printf.sprintf "%s(%s)" cstr (String.concat "," (List.map sval vl))
	| SGlobalSet (i,v) ->
		Printf.sprintf "G[%d] = %s" i (sval v)
	| SFieldSet (o,fid,v) | SSetEnumField (o,fid,v) ->
		Printf.sprintf "%s[%d] = %s" (sval o) fid (sval v)
	| SFieldDSet (o,f,v) ->
		Printf.sprintf "%s.%s = %s" (sval o) f (sval v)
	| SJEq (s,v) ->
		Printf.sprintf "j%s(%s)" s (sval v)
	| SJComp (s,a,b) ->
		Printf.sprintf "jump(%s %s %s)" (sval a) s (sval b)
	| SJump ->
		"jump"
	| SRet v ->
		"ret " ^ sval v
	| SNullCheck v ->
		"nullcheck " ^ sval v
	| SThrow v ->
		"throw " ^ sval v
	| SSwitch v ->
		"switch " ^ sval v
	| SWriteMem (m,idx,v,t) ->
		Printf.sprintf "(%s*)%s[%s] = %s" (tstr t) (sval m) (sval idx) (sval v)
	| SSetRef (r,v) ->
		Printf.sprintf "*%s = %s" (sval r) (sval v)
	| SStoreResult (r,s) ->
		r ^ " <- " ^ spec_string s
	| SNew (t,idx) ->
		Printf.sprintf "new %s(%d)" (tstr t) idx
	| SVal v ->
		sval v

let make_spec (code:code) (f:fundecl) =
	let op = Array.get f.code in
	let out_spec = ref [] in
	let alloc_count = ref (-1) in

	let digest str =
		let d = Digest.to_hex (Digest.string str) in
		String.sub d 0 4
	in

	let rec semit s =
		let rec loop_spec s =
			spec_iter loop_spec loop_val s

		and loop_val v =
			match v with
			| SDelayed (r,used) ->
				(match !used with
				| None -> ()
				| Some vl -> used := None; semit (SStoreResult (r,SVal (SUnion vl))))
			| _ ->
				svalue_iter loop_val v
		in
		loop_spec s;
		out_spec := s :: !out_spec
	in

	let emit (s:spec) =
		let d = digest (spec_string s) in
		semit (SStoreResult (d,s));
		SResult d
	in

	let big_unions = Hashtbl.create 0 in

	let block_args = Hashtbl.create 0 in
	let rec get_args b =
		try
			Hashtbl.find block_args b.bstart
		with Not_found ->
			Globals.die "" __LOC__

	and calc_spec b =
		let bprev = List.filter (fun b2 -> b2.bstart < b.bstart) b.bprev in
		let args = (match bprev with
			| [] ->
				let args = Array.make (Array.length f.regs) SUndef in
				(match f.ftype with
				| HFun (tl,_) -> list_iteri (fun i _ -> args.(i) <- SArg i) tl
				| _ -> Globals.die "" __LOC__);
				args
			| b2 :: l ->
				let args = Array.copy (get_args b2) in
				List.iter (fun b2 ->
					let args2 = get_args b2 in
					for i = 0 to Array.length args - 1 do
						if not (svalue_same args.(i) args2.(i)) then begin
							let l1 = (match args.(i) with SUnion l -> l | v -> [v]) in
							let l2 = (match args2.(i) with SUnion l -> l | v -> [v]) in
							let l = l1 @ List.filter (fun v -> not (List.exists (svalue_same v) l1)) l2 in
							if List.length l > 10 then begin
								(try
									let ident, used = Hashtbl.find big_unions l in
									args.(i) <- SDelayed (ident, used);
								with Not_found ->
									let ident = digest (String.concat "," (List.map svalue_string l)) in
									let used = ref (Some l) in
									Hashtbl.replace big_unions l (ident,used);
									args.(i) <- SDelayed (ident, used))
							end else
								args.(i) <- SUnion l;
						end
					done;
				) l;
				if l = [] then (match op b2.bend with OTrap (r,_) -> args.(r) <- SExc | _ -> ());
				args
		) in
		let make_call c vl =
			let r = emit (SCall (c,vl)) in
			(match r with
			| SResult result -> List.iter (fun v -> match v with SRef r -> args.(r) <- SRefResult result | _ -> ()) vl
			| _ -> Globals.die "" __LOC__);
			r
		in
		for i = b.bstart to b.bend do
			match op i with
			| OMov (d,r) -> args.(d) <- args.(r)
			| OInt (d,i) -> args.(d) <- SInt code.ints.(i)
			| OFloat (d,f) -> args.(d) <- SFloat code.floats.(f)
			| OBool (d,b) -> args.(d) <- SBool b
			| OString (d,s) -> args.(d) <- SString code.strings.(s)
			| OBytes (d,s) -> args.(d) <- SBytes s
			| ONull d -> args.(d) <- SNull
			| OAdd (d,a,b) -> args.(d) <- SOp ("+",args.(a),args.(b))
			| OSub (d,a,b) -> args.(d) <- SOp ("-",args.(a),args.(b))
			| OMul (d,a,b) -> args.(d) <- SOp ("*",args.(a),args.(b))
			| OSDiv (d,a,b) -> args.(d) <- SOp ("/",args.(a),args.(b))
			| OUDiv (d,a,b) -> args.(d) <- SOp ("//",args.(a),args.(b))
			| OSMod (d,a,b) -> args.(d) <- SOp ("%",args.(a),args.(b))
			| OUMod (d,a,b) -> args.(d) <- SOp ("%%",args.(a),args.(b))
			| OShl (d,a,b) -> args.(d) <- SOp ("<<",args.(a),args.(b))
			| OSShr (d,a,b) -> args.(d) <- SOp (">>",args.(a),args.(b))
			| OUShr (d,a,b) -> args.(d) <- SOp (">>>",args.(a),args.(b))
			| OAnd (d,a,b) -> args.(d) <- SOp ("&",args.(a),args.(b))
			| OOr (d,a,b) -> args.(d) <- SOp ("|",args.(a),args.(b))
			| OXor (d,a,b) -> args.(d) <- SOp ("^",args.(a),args.(b))
			| ONeg (d,r) -> args.(d) <- SUnop ("-",args.(r))
			| ONot (d,r) -> args.(d) <- SUnop ("!",args.(r))
			| OIncr r -> args.(r) <- SUnop ("++",args.(r))
			| ODecr r -> args.(r) <- SUnop ("++",args.(r))
			| OCall0 (d,f) -> args.(d) <- make_call (SFid f) []
			| OCall1 (d,f,a) -> args.(d) <- make_call (SFid f) [args.(a)]
			| OCall2 (d,f,a,b) -> args.(d) <- make_call (SFid f) [args.(a);args.(b)]
			| OCall3 (d,f,a,b,c) -> args.(d) <- make_call (SFid f) [args.(a);args.(b);args.(c)]
			| OCall4 (d,f,a,b,c,k) -> args.(d) <- make_call (SFid f) [args.(a);args.(b);args.(c);args.(k)]
			| OCallN (d,f,rl) -> args.(d) <- make_call (SFid f) (List.map (fun r -> args.(r)) rl)
			| OCallMethod (d,fid,rl) -> args.(d) <- make_call (SMethod fid) (List.map (fun r -> args.(r)) rl)
			| OCallThis (d,fid,rl) -> args.(d) <- make_call (SMethod fid) (List.map (fun r -> args.(r)) (0 :: rl))
			| OCallClosure (d,r,rl) -> args.(d) <- make_call (SClosure args.(r)) (List.map (fun r -> args.(r)) rl)
			| OStaticClosure (d,fid) -> args.(d) <- SFun (fid,None)
			| OInstanceClosure (d,fid,r) -> args.(d) <- SFun (fid,Some args.(r))
			| OVirtualClosure (d,r,index) -> args.(d) <- SMeth (args.(r),index)
			| OGetGlobal (d,g) -> args.(d) <- SGlobal g
			| OSetGlobal (g,r) -> semit (SGlobalSet (g,args.(r)))
			| OField (d,r,f) -> args.(d) <- SField (args.(r),f)
			| OSetField (o,f,r) -> semit (SFieldSet (args.(o),f,args.(r)))
			| OGetThis (d,fid) -> args.(d) <- SField (args.(0),fid)
			| OSetThis (f,r) -> semit (SFieldSet (args.(0),f,args.(r)))
			| ODynGet (d,o,f) -> args.(d) <- SDField (args.(o),code.strings.(f))
			| ODynSet (o,f,v) -> semit (SFieldDSet (args.(o),code.strings.(f),args.(v)))
			| OJTrue (r,_) -> semit (SJEq ("true",args.(r)))
			| OJFalse (r,_) -> semit (SJEq ("false",args.(r)))
			| OJNull (r,_) -> semit (SJEq ("null",args.(r)))
			| OJNotNull (r,_) -> semit (SJEq ("not null",args.(r)))
			| OJSLt (a,b,_) -> semit (SJComp ("<",args.(a),args.(b)))
			| OJSGte (a,b,_) -> semit (SJComp (">=",args.(a),args.(b)))
			| OJSGt (a,b,_) -> semit (SJComp (">",args.(a),args.(b)))
			| OJSLte (a,b,_) -> semit (SJComp ("<=",args.(a),args.(b)))
			| OJULt (a,b,_) -> semit (SJComp ("<U",args.(a),args.(b)))
			| OJUGte (a,b,_) -> semit (SJComp (">=U",args.(a),args.(b)))
			| OJNotLt (a,b,_) -> semit (SJComp ("not<",args.(a),args.(b)))
			| OJNotGte (a,b,_) -> semit (SJComp ("not>=",args.(a),args.(b)))
			| OJEq (a,b,_) -> semit (SJComp ("==",args.(a),args.(b)))
			| OJNotEq (a,b,_) -> semit (SJComp ("!=",args.(a),args.(b)))
			| OJAlways _ -> semit SJump
			| OToDyn (d,r) -> args.(d) <- SConv ("dyn",args.(r))
			| OToSFloat (d,r) -> args.(d) <- SConv ("sfloat",args.(r))
			| OToUFloat (d,r) -> args.(d) <- SConv ("ufloat",args.(r))
			| OToInt (d,r) -> args.(d) <- SConv ("int",args.(r))
			| OSafeCast (d,r) -> args.(d) <- SCast (args.(r),f.regs.(d))
			| OUnsafeCast (d,r) -> args.(d) <- SConv ("cast", args.(r))
			| OToVirtual (d,r) -> args.(d) <- SConv ("virtual",args.(r))
			| OLabel _ -> ()
			| ORet r ->
				semit (SRet (if f.regs.(r) = HVoid then SUndef else args.(r)));
				if i < b.bend then for i = 0 to Array.length args - 1 do args.(i) <- SUnreach done
			| OThrow r | ORethrow r ->
				semit (SThrow args.(r));
				if i < b.bend then for i = 0 to Array.length args - 1 do args.(i) <- SUnreach done
			| OSwitch (r,_,_) -> semit (SSwitch args.(r))
			| ONullCheck r -> semit (SNullCheck args.(r))
			| OTrap _ | OEndTrap _ -> ()
			| OGetUI8 (d,b,i) -> args.(d) <- SMem (args.(b),args.(i),HUI8)
			| OGetUI16 (d,b,i) -> args.(d) <- SMem (args.(b),args.(i),HUI16)
			| OGetMem (d,b,i) -> args.(d) <- SMem (args.(b),args.(i),f.regs.(d))
			| OGetArray (d,b,i) -> args.(d) <- SMem (args.(b),args.(i),HArray)
			| OSetUI8 (b,i,v) -> semit (SWriteMem (args.(b),args.(i),args.(v),HUI8))
			| OSetUI16 (b,i,v) -> semit (SWriteMem (args.(b),args.(i),args.(v),HUI16))
			| OSetMem (b,i,v) -> semit (SWriteMem (args.(b),args.(i),args.(v),f.regs.(v)))
			| OSetArray (b,i,v) -> semit (SWriteMem (args.(b),args.(i),args.(v),HArray))
			| ONew d ->
				incr alloc_count;
				args.(d) <- emit (SNew (f.regs.(d),!alloc_count))
			| OArraySize (d,r) -> args.(d) <- SConv ("size",args.(r))
			| OType (d,t) -> args.(d) <- SType t
			| OGetType (d,r) -> args.(d) <- SConv ("type",args.(r))
			| OGetTID (d,r) -> args.(d) <- SConv ("tid",args.(r))
			| ORef (d,r) -> args.(d) <- SRef r
			| OUnref (d,r) ->
				(match args.(r) with
				| SRef r -> args.(d) <- args.(r)
				| _ -> args.(d) <- SConv ("unref",args.(r)))
			| OSetref (r,v) ->
				(match args.(r) with
				| SRef r -> args.(r) <- args.(v)
				| _ -> ());
				semit (SSetRef (args.(r),args.(v)))
			| OMakeEnum (d,fid,rl) -> args.(d) <- SEnum (fid, List.map (fun r -> args.(r)) rl)
			| OEnumAlloc (d,fid) -> args.(d) <- SEnum (fid, [])
			| OEnumIndex (d,r) -> args.(d) <- SConv ("index",args.(r))
			| OEnumField (d,r,fid,cid) -> args.(d) <- SEnumField (args.(r),fid,cid)
			| OSetEnumField (e,fid,r) -> semit (SSetEnumField (args.(e),fid,args.(r)))
			| OAssert _  -> ()
			| ONop _ -> ()
		done;
		Hashtbl.add block_args b.bstart args
	in
	let all_blocks, _ = Hlopt.code_graph f in
	let rec loop i =
		if i = Array.length f.code then () else
		if not (Hashtbl.mem all_blocks i) then loop (i + 1) else (* unreachable code *)
		let b = try Hashtbl.find all_blocks i with Not_found -> failwith (Printf.sprintf "Missing block %s(%d)" (fundecl_name f) i) in
		calc_spec b;
		loop (b.bend + 1)
	in
	loop 0;
	List.rev !out_spec
*/
