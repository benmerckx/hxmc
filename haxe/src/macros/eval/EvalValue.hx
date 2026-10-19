/*
	The Haxe Compiler
	Copyright (C) 2005-2019  Haxe Foundation

	This program is free software; you can redistribute it and/or
	modify it under the terms of the GNU General Public License
	as published by the Free Software Foundation; either version 2
	of the License, or (at your option) any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with this program; if not, write to the Free Software
	Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

package macros.eval;

import core.Globals.Pos;
import core.ds.AtomicLazy;
import core.ds.GlobalsIntMap;
import core.ds.OcamlHashtbl;
import haxe.io.Bytes;

// port: deviations:
// - Strings (`Vstring`) hold a native string. Their length and indices are in
//   code points, as Eval's UTF-8 strings, see `EvalString`.
// - libuv handles (`Vhandle`) and mbedtls instances hold host objects; they
//   only exist on hosts implementing them (see `EvalLuv`, `EvalSsl`).
// - `IObjectMap` cannot reproduce OCaml's structural hash of runtime values,
//   so its iteration order is that of a single bucket (newest first).
enum Cmp {
	CEq;
	CSup;
	CInf;
	CUndef;
}

class Vstring {
	public final sstring:String;
	// The length of the string.
	// port: in code points
	public final slength:Int;
	// port: sstring has no surrogate pairs: code point indices are string indices
	public final sbmp:Bool;

	public function new(sstring:String, slength:Int, sbmp:Bool) {
		this.sstring = sstring;
		this.slength = slength;
		this.sbmp = sbmp;
	}
}

class VstringBuffer {
	public var bbuffer:StringBuf = new StringBuf();
	public var blength:Int = 0;

	public function new() {}
}

// port: `RuntimeStringHashtbl`: a mutable reference to a string map, iterated in key order.
class RuntimeStringHashtbl<V> {
	var map:Map<String, {key:Vstring, value:V}>;

	public function new(?map:Map<String, {key:Vstring, value:V}>) this.map = map == null ? new Map() : map;

	public function add(key:Vstring, v:V):Void map.set(key.sstring, {key: key, value: v});

	public function copy():RuntimeStringHashtbl<V> return new RuntimeStringHashtbl(map.copy());

	public function find(key:Vstring):{key:Vstring, value:V} {
		var e = map.get(key.sstring);
		if (e == null) throw core.ds.NotFound.raise();
		return e;
	}

	public function findOpt(key:Vstring):Null<{key:Vstring, value:V}> return map.get(key.sstring);

	// port: StringMap order: OCaml's String.compare on the UTF-8 bytes, i.e. code point order
	public function sortedKeys():Array<String> {
		var keys = [for (k in map.keys()) k];
		keys.sort(EvalString.compareCodePoints);
		return keys;
	}

	public function fold<A>(f:String->{key:Vstring, value:V}->A->A, acc:A):A {
		for (k in sortedKeys()) acc = f(k, map.get(k), acc);
		return acc;
	}

	public function isEmpty():Bool return !map.keys().hasNext();

	public function iter(f:String->{key:Vstring, value:V}->Void):Void for (k in sortedKeys()) f(k, map.get(k));

	public function mem(key:Vstring):Bool return map.exists(key.sstring);

	public function remove(key:Vstring):Void map.remove(key.sstring);

	public function clear():Void map = new Map();

	public function size():Int {
		var n = 0;
		for (_ in map.keys()) n++;
		return n;
	}
}

// port: `RuntimeIntHashtbl`: `IntHashtbl` (an OCaml `Hashtbl` with `Int.hash`).
class RuntimeIntHashtbl<V> {
	public final h:OcamlHashtbl<Int, V>;

	public function new(?h:OcamlHashtbl<Int, V>) this.h = h == null ? new OcamlHashtbl(OcamlHashtbl.hashInt, (a, b) -> a == b, 0) : h;

	public function add(key:Int, v:V):Void h.replace(key, v);

	public function copy():RuntimeIntHashtbl<V> return new RuntimeIntHashtbl(h.copy());

	public function find(key:Int):V return h.find(key);

	public function fold<A>(f:Int->V->A->A, acc:A):A return h.fold(f, acc);

	public function isEmpty():Bool return h.length() == 0;

	public function iter(f:Int->V->Void):Void h.iter(f);

	public function mem(key:Int):Bool return h.mem(key);

	public function remove(key:Int):Void h.remove(key);

	public function clear():Void h.clear();

	public function size():Int return h.length();
}

// port: `RuntimeInt64Hashtbl`: `Int64Hashtbl`, hashed with OCaml's polymorphic hash on
// boxed int64s (custom block), which is not reproduced: one bucket, newest first.
class RuntimeInt64Hashtbl<V> {
	public final h:OcamlHashtbl<haxe.Int64, V>;

	public function new(?h:OcamlHashtbl<haxe.Int64, V>) this.h = h == null ? new OcamlHashtbl(_ -> 0,
		(a:haxe.Int64, b:haxe.Int64) -> a == b, 0) : h; // port: typed: Int64 equality, not physical (hxmc boxes Int64)

	public function add(key:haxe.Int64, v:V):Void h.replace(key, v);

	public function copy():RuntimeInt64Hashtbl<V> return new RuntimeInt64Hashtbl(h.copy());

	public function find(key:haxe.Int64):V return h.find(key);

	public function fold<A>(f:haxe.Int64->V->A->A, acc:A):A return h.fold(f, acc);

	public function isEmpty():Bool return h.length() == 0;

	public function iter(f:haxe.Int64->V->Void):Void h.iter(f);

	public function mem(key:haxe.Int64):Bool return h.mem(key);

	public function remove(key:haxe.Int64):Void h.remove(key);

	public function clear():Void h.clear();

	public function size():Int return h.length();
}

// port: regular expression state. Upstream keeps PCRE2 handles; this uses the host EReg.
class Vregex {
	public final r:EReg;
	public final rRexString:Vstring;
	public final rGlobal:Bool;
	public var rString:String = "";
	// port: `r_groups`: snapshots of the last match (empty when no match was made)
	public var rGroups:Array<VregexMatch> = [];

	public function new(r:EReg, rRexString:Vstring, rGlobal:Bool) {
		this.r = r;
		this.rRexString = rRexString;
		this.rGlobal = rGlobal;
	}
}

// port: one PCRE2 `substrings` value: native offsets of group 0 and the group
// substrings (`null` for unset groups), taken from the host EReg right after
// the match so that later host matches do not affect it.
class VregexMatch {
	public final first:Int;
	public final last:Int;
	public final groups:Array<Null<String>>;

	public function new(first:Int, last:Int, groups:Array<Null<String>>) {
		this.first = first;
		this.last = last;
		this.groups = groups;
	}
}

// port: zlib stream for haxe.zip.Compress/Uncompress (state kept by the std natives).
class Vzlib {
	public var z:Dynamic;
	public var zFlush:Int;

	public function new(z:Dynamic, zFlush:Int) {
		this.z = z;
		this.zFlush = zFlush;
	}
}

enum VprototypeKind {
	PClass(interfaces:Array<Int>);
	PEnum(names:Array<{name:String, params:Array<Int>}>);
	PInstance;
	PObject;
}

// port: libuv handles (eval.luv). The payloads are host objects (see `EvalLuv`):
// integer ids of the host's libuv objects, `EvalLuv.LuvBuffer` for buffers,
// Bytes for socket addresses, `EvalLuv.LuvRedirection` for redirections.
enum Vhandle {
	HLoop(h:Dynamic);
	HIdle(h:Dynamic);
	HTimer(h:Dynamic);
	HAsync(h:Dynamic);
	HBuffer(h:Dynamic);
	HSockAddr(h:Dynamic);
	HTcp(h:Dynamic);
	HUdp(h:Dynamic);
	HPipe(h:Dynamic);
	HTty(h:Dynamic);
	HFile(h:Dynamic);
	HDir(h:Dynamic);
	HSignal(h:Dynamic);
	HProcess(h:Dynamic);
	HRedirection(h:Dynamic);
	HAddrRequest(h:Dynamic);
	HNameRequest(h:Dynamic);
	HFileRequest(h:Dynamic);
	HRandomRequest(h:Dynamic);
	HThreadPoolRequest(h:Dynamic);
	HFileModeNumeric(h:Dynamic);
	HFsEvent(h:Dynamic);
	HThread(h:Dynamic);
	HOnce(h:Dynamic);
	HMutex(h:Dynamic);
	HRwLock(h:Dynamic);
	HSemaphore(h:Dynamic);
	HCondition(h:Dynamic);
	HBarrier(h:Dynamic);
	HFsPoll(h:Dynamic);
	HPrepare(h:Dynamic);
	HCheck(h:Dynamic);
}

enum Value {
	VNull;
	VTrue;
	VFalse;
	VInt32(i:Int);
	VFloat(f:Float);
	VEnumValue(e:VenumValue);
	VObject(o:Vobject);
	VInstance(i:Vinstance);
	VString(s:Vstring);
	VArray(a:Varray);
	VVector(v:Vvector);
	VPrototype(p:Vprototype);
	VFunction(f:Vfunc, isStatic:Bool);
	VFieldClosure(v:Value, f:Vfunc);
	VLazy(l:AtomicLazy<Value>);
	VNativeString(s:Bytes);
	VHandle(h:Vhandle);
	VInt64(i:haxe.Int64);
	VUInt64(i:haxe.Int64);
}

typedef Vfunc = Array<Value>->Value;
typedef Vvector = Array<Value>;

class Vobject {
	// The fields of the object known when it is created.
	public var ofields:Array<Value>;
	// The prototype of the object.
	public var oproto:VobjectProto;

	public function new(ofields:Array<Value>, oproto:VobjectProto) {
		this.ofields = ofields;
		this.oproto = oproto;
	}
}

enum VobjectProto {
	OProto(p:Vprototype);
	ODictionary(d:GlobalsIntMap<Value>);
}

class Vprototype {
	// The path of the prototype. Using revHash on this gives the original dot path.
	public final ppath:Int;
	// The fields of the prototype itself (static fields).
	public final pfields:Array<Value>;
	// Map from hashed name to field offset (in pfields).
	public final pnames:GlobalsIntMap<Int>;
	// The fields of instances of this prototype (non-static fields).
	public final pinstanceFields:Array<Value>;
	// Map from hashed name to field offset (in pinstanceFields).
	public final pinstanceNames:GlobalsIntMap<Int>;
	// The parent prototype in case of inheritance. Static inheritance is reflected here
	// as well because that information is requires for Type.getSuperClass.
	public final pparent:Null<Vprototype>;
	// The [vprototype_kind].
	public final pkind:VprototypeKind;
	// The value of this prototype, i.e. VPrototype(this).
	public var pvalue:Value;

	public function new(ppath:Int, pfields:Array<Value>, pnames:GlobalsIntMap<Int>, pinstanceFields:Array<Value>,
			pinstanceNames:GlobalsIntMap<Int>, pparent:Null<Vprototype>, pkind:VprototypeKind, pvalue:Value) {
		this.ppath = ppath;
		this.pfields = pfields;
		this.pnames = pnames;
		this.pinstanceFields = pinstanceFields;
		this.pinstanceNames = pinstanceNames;
		this.pparent = pparent;
		this.pkind = pkind;
		this.pvalue = pvalue;
	}
}

enum VinstanceKind {
	IBytes(b:Bytes);
	IRegex(r:Vregex);
	IDate(f:Float);
	IStringMap(h:RuntimeStringHashtbl<Value>);
	IIntMap(h:RuntimeIntHashtbl<Value>);
	IInt64Map(h:RuntimeInt64Hashtbl<Value>);
	IObjectMap(h:OcamlHashtbl<Value, Value>);
	IOutput(b:haxe.io.BytesBuffer); // BytesBuffer
	IBuffer(b:VstringBuffer); // StringBuf
	IPos(p:Pos);
	IUtf8(b:StringBuf);
	IProcess(p:EvalProcess);
	IInChannel(i:haxe.io.Input, eof:{v:Bool}); // FileInput
	IOutChannel(o:haxe.io.Output); // FileOutput
	ISocket(s:Vsocket);
	IThread(t:Vthread);
	IMutex(m:DomainMutex);
	ISemaphore(s:sys.thread.Semaphore);
	ICondition(c:Vcondition);
	ILock(l:Vlock);
	ITls(i:Int);
	IDeque(d:Vdeque);
	IZip(z:Vzlib); // Compress/Uncompress
	ITypeDecl(m:core.TType.ModuleType);
	ILazyType(l:core.TType.TLazy, f:Void->Value);
	IRef(o:Dynamic);
	// SSL
	// port: contexts are host handles (hxmc.NativeSsl on the hxmc host)
	IMbedtlsConfig(c:Dynamic);
	IMbedtlsCtrDrbg(c:Dynamic);
	IMbedtlsEntropy(c:Dynamic);
	IMbedtlsPkContext(c:Dynamic);
	IMbedtlsSsl(c:Dynamic);
	IMbedtlsX509Crt(c:Dynamic);
	INormal;
	IAtomicBool(b:{v:Bool});
	IAtomicInt(i:{v:Int});
	IAtomicObject(o:{v:Value});
}

class Vinstance {
	// The fields of this instance.
	public final ifields:Array<Value>;
	// The prototype of this instance. Field offsets for ifields can be found using
	// iproto.pinstance_names.
	public final iproto:Vprototype;
	// The [vinstance_kind].
	public var ikind:VinstanceKind;

	public function new(ifields:Array<Value>, iproto:Vprototype, ikind:VinstanceKind) {
		this.ifields = ifields;
		this.iproto = iproto;
		this.ikind = ikind;
	}
}

class Varray {
	public var avalues:Array<Value>;
	public var alength:Int;

	public function new(avalues:Array<Value>, alength:Int) {
		this.avalues = avalues;
		this.alength = alength;
	}
}

class VenumValue {
	public final eindex:Int;
	public final eargs:Array<Value>;
	public final epath:Int;
	public var enpos:Null<Pos>;

	public function new(eindex:Int, eargs:Array<Value>, epath:Int, enpos:Null<Pos>) {
		this.eindex = eindex;
		this.eargs = eargs;
		this.epath = epath;
		this.enpos = enpos;
	}
}

// port: all run on host threads. `finished` is released when the thread's function returns;
// the host has no Thread.join (deviation: upstream joins the OCaml thread/domain).
// `LuvThread`: an eval.luv thread or thread pool worker (EvalLuv.hx).
enum VthreadMode {
	Thread(t:sys.thread.Thread, finished:sys.thread.Lock);
	Domain(t:sys.thread.Thread, finished:sys.thread.Lock);
	LuvThread(t:macros.eval.EvalLuv.LuvThreadHandle);
}

class Vthread {
	public final threadId:Int;
	public var threadMode:Null<VthreadMode>;
	public final threadDeque:Vdeque;

	public function new(threadId:Int, threadMode:Null<VthreadMode>, threadDeque:Vdeque) {
		this.threadId = threadId;
		this.threadMode = threadMode;
		this.threadDeque = threadDeque;
	}
}

class Vdeque {
	public var dvalues:Array<Value> = [];
	public final dmutex:sys.thread.Mutex = new sys.thread.Mutex();
	public final dcond:sys.thread.Condition = new sys.thread.Condition();

	public function new() {}
}

class Vlock {
	public final lmutex:sys.thread.Mutex = new sys.thread.Mutex();
	public final lcond:sys.thread.Condition = new sys.thread.Condition();
	public var lcount:Int = 0;

	public function new() {}
}

class Vcondition {
	public final cond:sys.thread.Condition = new sys.thread.Condition();
	public final cmutex:sys.thread.Mutex = new sys.thread.Mutex();

	public function new() {}
}

// port: a reentrant mutex owned by a thread id.
class DomainMutex {
	final dmutex = new sys.thread.Mutex();
	var downer = -1; // owner domain_id, or -1 if unlocked
	var ddepth = 0; // reentrant depth, only accessed by owner

	public function new() {}

	// port: Atomic.get mutex.downer
	public function owner():Int return downer;

	public function lock(id:Int):Void {
		if (downer == id) ddepth++
		else {
			EvalLock.acquireMutex(dmutex);
			downer = id;
			ddepth = 1;
		}
	}

	public function tryLock(id:Int):Bool {
		if (downer == id) {
			ddepth++;
			return true;
		}
		if (dmutex.tryAcquire()) {
			downer = id;
			ddepth = 1;
			return true;
		}
		return false;
	}

	public function unlock():Void {
		if (ddepth > 1) ddepth--
		else {
			downer = -1;
			dmutex.release();
		}
	}
}

class EvalValueTools {
	public static function vstringEqual(s1:Vstring, s2:Vstring):Bool return s1 == s2 || s1.sstring == s2.sstring;

	// port: the host objects compare physically (ids by value).
	public static function sameHandle(h1:Vhandle, h2:Vhandle):Bool {
		return switch [h1, h2] {
			case [HLoop(h1), HLoop(h2)] | [HIdle(h1), HIdle(h2)] | [HTimer(h1), HTimer(h2)] | [HAsync(h1), HAsync(h2)] |
				[HBuffer(h1), HBuffer(h2)] | [HSockAddr(h1), HSockAddr(h2)] | [HTcp(h1), HTcp(h2)] | [HPipe(h1), HPipe(h2)] |
				[HTty(h1), HTty(h2)] | [HFile(h1), HFile(h2)] | [HDir(h1), HDir(h2)] | [HUdp(h1), HUdp(h2)] | [HSignal(h1), HSignal(h2)] |
				[HProcess(h1), HProcess(h2)] | [HRedirection(h1), HRedirection(h2)] | [HFileRequest(h1), HFileRequest(h2)] |
				[HNameRequest(h1), HNameRequest(h2)] | [HAddrRequest(h1), HAddrRequest(h2)] | [HRandomRequest(h1), HRandomRequest(h2)] |
				[HThreadPoolRequest(h1), HThreadPoolRequest(h2)] | [HFileModeNumeric(h1), HFileModeNumeric(h2)] |
				[HFsEvent(h1), HFsEvent(h2)] | [HOnce(h1), HOnce(h2)] | [HMutex(h1), HMutex(h2)] | [HRwLock(h1), HRwLock(h2)] |
				[HSemaphore(h1), HSemaphore(h2)] | [HCondition(h1), HCondition(h2)] | [HBarrier(h1), HBarrier(h2)] |
				[HFsPoll(h1), HFsPoll(h2)] | [HPrepare(h1), HPrepare(h2)] | [HCheck(h1), HCheck(h2)] | [HThread(h1), HThread(h2)]: // port: Luv.Thread.equal: one EvalLuv.LuvThread per host thread
				h1 == h2;
			case _: false;
		}
	}

	public static function equals(a:Value, b:Value):Bool {
		return switch [a, b] {
			case [VTrue, VTrue] | [VFalse, VFalse] | [VNull, VNull]: true;
			case [VInt32(a), VInt32(b)]: a == b;
			case [VFloat(a), VFloat(b)]: a == b;
			case [VFloat(a), VInt32(b)]: a == (b : Float);
			case [VInt32(a), VFloat(b)]: (a : Float) == b;
			case [VEnumValue(a), VEnumValue(b)]: a == b || (a.eindex == b.eindex && a.eargs.length == 0 && b.eargs.length == 0
					&& a.epath == b.epath);
			case [VObject(vo1), VObject(vo2)]: vo1 == vo2;
			case [VInstance(vi1), VInstance(vi2)]: vi1 == vi2;
			case [VString(s1), VString(s2)]: vstringEqual(s1, s2);
			case [VArray(va1), VArray(va2)]: va1 == va2;
			case [VVector(vv1), VVector(vv2)]: vv1 == vv2;
			case [VFunction(vf1, _), VFunction(vf2, _)]: Reflect.compareMethods(vf1, vf2);
			case [VPrototype(proto1), VPrototype(proto2)]: proto1.ppath == proto2.ppath;
			case [VFieldClosure(v1, f1), VFieldClosure(v2, f2)]: Reflect.compareMethods(f1, f2) && equals(v1, v2);
			case [VNativeString(s1), VNativeString(s2)]: s1.compare(s2) == 0;
			case [VHandle(h1), VHandle(h2)]: sameHandle(h1, h2);
			case [VLazy(f1), _]: equals(f1.force(), b);
			case [_, VLazy(f2)]: equals(a, f2.force());
			// port: upstream's `a == b` (physical) on the remaining values; Int64s compare by value here
			case [VInt64(a), VInt64(b)]: a == b;
			case [VUInt64(a), VUInt64(b)]: a == b;
			case _: false;
		}
	}

	// port: `ValueHashtbl`: Hashtbl.Make with `equals` and a constant hash.
	public static function createValueHashtbl<V>():OcamlHashtbl<Value, V> return new OcamlHashtbl(_ -> 0, equals, 0);

	public static final vnull = VNull;
	public static final vtrue = VTrue;
	public static final vfalse = VFalse;

	public static inline function vbool(b:Bool):Value return b ? VTrue : VFalse;

	public static inline function vprototype(proto:Vprototype):Value return VPrototype(proto);

	public static inline function vinstance(i:Vinstance):Value return VInstance(i);

	public static inline function vfunction(f:Vfunc):Value return VFunction(f, false);

	public static inline function vstaticFunction(f:Vfunc):Value return VFunction(f, true);

	public static inline function vfieldClosure(v:Value, f:Vfunc):Value return VFieldClosure(v, f);

	public static inline function vobject(o:Vobject):Value return VObject(o);

	// port: small ints are shared: values are immutable and identity is not observable,
	// and HashLink allocations cost more than OCaml's (deviation: upstream boxes each).
	static final smallInts:Array<Value> = [for (i in -128...1024) VInt32(i)];

	public static inline function vint(i:Int):Value return vint32(i);

	public static inline function vint32(i:Int):Value return i >= -128 && i < 1024 ? smallInts[i + 128] : VInt32(i);

	public static inline function vint64(i:haxe.Int64):Value return VInt64(i);

	public static inline function vfloat(f:Float):Value return VFloat(f);

	public static inline function venumValue(e:VenumValue):Value return VEnumValue(e);

	public static inline function vnativeString(s:Bytes):Value return VNativeString(s);

	public static function sExprPretty(e:core.TType.TExpr):String {
		var ctx = core.TPrinting.printContext();
		return core.TPrinting.sExprPretty(false, "", false, core.TPrinting.sType.bind(ctx), e);
	}

	public static function vresolve(v:Value):Value {
		return switch v {
			case VLazy(f): vresolve(f.force());
			case _: v;
		}
	}

	public static function associateEnumValuePos(ve:Value, p:Pos):Void {
		switch ve {
			case VEnumValue(ve):
				ve.enpos = p;
			case _:
		}
	}
}

// port: an Eval socket (upstream: its Unix.file_descr): the host descriptor and
// whether it was closed, after which its number is no longer used (it may belong
// to another descriptor of the host by then: upstream would close or read that one)
class Vsocket {
	public final fd:Dynamic;
	public var closed = false;

	public function new(fd:Dynamic) {
		this.fd = fd;
	}
}
