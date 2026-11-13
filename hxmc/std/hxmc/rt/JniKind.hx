package hxmc.rt;

import hxmc.I64;
import hxmc.rt.C;
import hxmc.unsafe.*;

// JNI as two kinds of foreign objects (Foreign; docs/interop.md, "Java
// (JNI)"; docs/plans/jni.md): the entry points generated code calls
// (hxmc.ir.Jni, FnLower), over Foreign's boxes and peers.
//
// - **Java objects** (a reference a call returned) are boxes of the kind
//   "jni": one per object, keyed by System.identityHashCode and told apart
//   by IsSameObject, each holding a global reference (retain: NewGlobalRef),
//   deleted once the box dies (put off: any thread, attached first). A weak
//   field (hxmc.java.Weak) holds a weak global reference.
// - **Haxe objects** of classes implementing Java interfaces are peers of
//   the kind "jni-peer": the Haxe object's record (its hidden field: a weak
//   global reference to its Java proxy, its entry, the number of its live
//   proxies) is the entry's reference. The JVM has no counts, so the toggle
//   is TOGGLE_NOTIFY on what the proxies say: the Java proxy (a class of the
//   glue, org.hxmc.Peer's subclass, made at the object's first use as a Java
//   value) holds the entry's index; while one lives the entry is a root, and
//   Java's collection of the last one (org.hxmc.Peer's phantom reference,
//   drained by its daemon thread: peerRelease) makes it weak again. A cycle
//   through both heaps (a Haxe object holding a Java object that holds its
//   proxy) is never collected: docs/plans/jni.md, the bridge.
// - **Calls** (hxmc.ir.Jni, FnLower.jniCall): enter (the thread's JNIEnv,
//   attached as a daemon thread at its first use and detached as it ends:
//   a pthread key's destructor; a local frame pushed), the class and the
//   member resolved once into their cells (data words: DataGen.jniCells),
//   the arguments made Java values in the frame (arg), the call in a safe
//   region (call), the result made a Haxe value (result), leave (the frame
//   popped; a pending Java exception thrown as hxmc.java.JavaException).
//   Every function after enter skips its work while an exception is
//   pending, so the first failure is the one thrown.
//
// The runtime links no JVM: libjvm is opened by hxmc.java.Jvm.create
// (dlopen), or the library is loaded into a JVM (Jvm.onLoad: JNI_OnLoad's
// JavaVM), or an Android activity's JavaVM is given (Jvm.useActivity).
// POSIX only (Linux in the dynamic glibc mode, Android, macOS): on Windows
// and WebAssembly the lowering makes every Java operation a throw.
@:hxmc.native @:keep @:allow(hxmc.rt) @:allow(hxmc.java) @:access(hxmc.rt.Str)
class JniKind {
	// ---- the jni.h function tables' slots (JNINativeInterface_, JNIInvokeInterface_)
	static inline var GetVersion = 4;
	static inline var FindClass = 6;
	static inline var Throw = 13;
	static inline var ThrowNew = 14;
	static inline var ExceptionOccurred = 15;
	static inline var ExceptionClear = 17;
	static inline var PushLocalFrame = 19;
	static inline var PopLocalFrame = 20;
	static inline var NewGlobalRef = 21;
	static inline var DeleteGlobalRef = 22;
	static inline var DeleteLocalRef = 23;
	static inline var IsSameObject = 24;
	static inline var NewLocalRef = 25;
	static inline var NewObjectA = 30;
	static inline var GetObjectClass = 31;
	static inline var IsInstanceOf = 32;
	static inline var GetMethodID = 33;
	static inline var CallMethodA = 36; // + 3 * the type code (Object 0 ... Void 9)
	static inline var GetFieldID = 94;
	static inline var GetField = 95; // + the type code
	static inline var SetField = 104;
	static inline var GetStaticMethodID = 113;
	static inline var CallStaticMethodA = 116;
	static inline var GetStaticFieldID = 144;
	static inline var GetStaticField = 145;
	static inline var SetStaticField = 154;
	static inline var NewString = 163;
	static inline var GetStringLength = 164;
	static inline var GetArrayLength = 171;
	static inline var NewObjectArray = 172;
	static inline var GetObjectArrayElement = 173;
	static inline var SetObjectArrayElement = 174;
	static inline var NewArray = 174; // + the type code (Boolean 1 ... Double 8)
	static inline var GetArrayRegion = 198;
	static inline var SetArrayRegion = 206;
	static inline var RegisterNatives = 215;
	static inline var GetStringRegion = 220;
	static inline var GetPrimitiveArrayCritical = 222;
	static inline var ReleasePrimitiveArrayCritical = 223;
	static inline var NewWeakGlobalRef = 226;
	static inline var DeleteWeakGlobalRef = 227;
	static inline var ExceptionCheck = 228;
	// (the JavaVM's)
	static inline var AttachCurrentThread = 4;
	static inline var DetachCurrentThread = 5;
	static inline var GetEnv = 6;
	static inline var AttachCurrentThreadAsDaemon = 7;

	public static inline var JNI_VERSION_1_6 = 0x00010006;
	static inline var JNI_EDETACHED = -2;

	// ---- the type codes (hxmc.ir.Jni: the descriptor's letter)
	public static inline var T_OBJECT = 0;
	public static inline var T_BOOLEAN = 1;
	public static inline var T_BYTE = 2;
	public static inline var T_CHAR = 3;
	public static inline var T_SHORT = 4;
	public static inline var T_INT = 5;
	public static inline var T_LONG = 6;
	public static inline var T_FLOAT = 7;
	public static inline var T_DOUBLE = 8;
	public static inline var T_VOID = 9;
	// (a call's `how`: the result's type code, and these)
	public static inline var STATIC = 16;
	public static inline var NEW = 32;

	// ---- what a reference argument or result converts (hxmc.ir.Jni.how)
	public static inline var R_OBJECT = 0; // a Java object (a box) or a Haxe object implementing its interface
	public static inline var R_STRING = 1; // String <-> java.lang.String
	public static inline var R_DYNAMIC = 2; // Dynamic <-> java.lang.Object, boxing numbers
	public static inline var R_INTEGER = 3; // Null<Int> <-> java.lang.Integer
	public static inline var R_DOUBLE = 4; // Null<Float> <-> java.lang.Double
	public static inline var R_BOOLEAN = 5; // Null<Bool> <-> java.lang.Boolean
	public static inline var R_BYTES = 6; // haxe.io.Bytes <-> byte[] (copied)
	public static inline var R_PRIMS = 16; // + a type code: Array<Int>, <Float>, <Bool> <-> int[] ... (copied)
	public static inline var R_STRINGS = 32; // Array<String> <-> String[] (copied)
	public static inline var R_OBJECTS = 33; // Array<C> <-> C[] (copied; the element class `cls`)
	public static inline var R_DYNAMICS = 34; // Array<Dynamic> <-> Object[] (copied, boxed)
	// (a member's kind: rt_jni_member)
	public static inline var M_METHOD = 0;
	public static inline var M_STATIC_METHOD = 1;
	public static inline var M_FIELD = 2;
	public static inline var M_STATIC_FIELD = 3;

	// ---- the JVM
	static var vm:Ptr;
	// the class loader classes are found with (a global reference; null:
	// FindClass): the loader of org.hxmc.Peer or the context class loader
	// of the thread JNI_OnLoad ran on, an Android activity's
	static var loader:Ptr;
	static var loadClass:Ptr;
	// the thread's JNIEnv, found or attached at its first JNI use
	@:hxmc.threadLocal static var tenv:Ptr;
	// a key whose destructor detaches the threads attached here
	static var key:Ptr;
	static var lock:Ptr;
	// the kinds (0: not registered yet; kind published with a release store
	// once both are, read with an acquire load: known)
	@:hxmc.export("rt_jni_kind") static var kind:Int;
	static var peerKind:Int;

	// classes and members the runtime itself uses (cells: a word each)
	static var cells:Ptr;
	static inline var C_SYSTEM = 0;
	static inline var C_IDHASH = 8;
	static inline var C_CLASS = 16;
	static inline var C_GETNAME = 24;
	static inline var C_THROWABLE = 32;
	static inline var C_TOSTRING = 40;
	static inline var C_GETMESSAGE = 48;
	static inline var C_STACK = 56;
	static inline var C_STRING = 64;
	static inline var C_INTEGER = 72;
	static inline var C_INT_OF = 80;
	static inline var C_INT_VALUE = 88;
	static inline var C_DOUBLE = 96;
	static inline var C_DOUBLE_OF = 104;
	static inline var C_DOUBLE_VALUE = 112;
	static inline var C_BOOLEAN = 120;
	static inline var C_BOOLEAN_OF = 128;
	static inline var C_BOOLEAN_VALUE = 136;
	static inline var C_NUMBER = 144;
	static inline var C_NUMBER_DOUBLE = 152;
	static inline var C_OBJECT = 160;
	static inline var C_OBJECT_TOSTRING = 168;
	static inline var C_PEER = 176; // org.hxmc.Peer (null until a proxy is made)
	static inline var C_PEER_HANDLE = 184;
	static inline var C_HAXE_EXCEPTION = 192;
	static inline var C_ILLEGAL_STATE = 200;
	static inline var C_ILLEGAL_ARGUMENT = 208;
	static inline var C_NPE = 216;
	static inline var C_CHARACTER = 224;
	static inline var C_LONG = 232;
	static inline var C_LONG_VALUE = 240;
	static inline var C_STE_TOSTRING = 248;
	static inline var C_CHAR_VALUE = 256;
	static inline var CELLS = 264;

	// ---- the JVM's function tables

	@:hxmc.unsafe static inline function fn(env:Ptr, i:Int):Ptr
		return Mem.getPtr(Mem.getPtr(env, 0), 8 * i);

	@:hxmc.unsafe static inline function vmFn(i:Int):Ptr
		return Mem.getPtr(Mem.getPtr(vm, 0), 8 * i);

	@:hxmc.unsafe static inline function pending(env:Ptr):Bool
		return bool(Ind.p1(fn(env, ExceptionCheck), env));

	@:hxmc.unsafe static inline function int32(p:Ptr):Int
		return p.toI64().toInt();

	// (a jboolean result: its low byte)
	@:hxmc.unsafe static inline function bool(p:Ptr):Bool
		return p.toI64().toInt() & 0xFF != 0;

	// ---- the kinds' hooks (C functions: any thread the JVM knows or attaches)

	@:hxmc.unsafe static inline function known():Int
		return Atomic.load32(Mem.sym("rt_jni_kind"));

	@:hxmc.unsafe static function k():Int {
		var k = known();
		if (k != 0) return k;
		Os.lock(Foreign.lock);
		if (kind == 0) {
			var d = Mem.stack(128);
			LibC.memset(d, 0, Foreign.KIND_BYTES);
			Mem.setPtr(d, Foreign.K_NAME, Mem.cstr("jni"));
			Mem.setI64(d, Foreign.K_FLAGS, 0);
			Mem.setPtr(d, Foreign.K_RETAIN, Callback.addr(retain));
			Mem.setPtr(d, Foreign.K_RELEASE, Callback.addr(release));
			Mem.setPtr(d, Foreign.K_IDENTITY, Callback.addr(identity));
			Mem.setPtr(d, Foreign.K_SAME, Callback.addr(same));
			Mem.setPtr(d, Foreign.K_PEER, Callback.addr(peerOf));
			Mem.setPtr(d, Foreign.K_WEAK_INIT, Callback.addr(weakInit));
			Mem.setPtr(d, Foreign.K_WEAK_LOAD, Callback.addr(weakLoad));
			Mem.setPtr(d, Foreign.K_WEAK_DESTROY, Callback.addr(weakDestroy));
			Mem.setPtr(d, Foreign.K_BATCH_BEGIN, Callback.addr(batchBegin));
			var jk = Foreign.registerLocked(d);
			LibC.memset(d, 0, Foreign.KIND_BYTES);
			Mem.setPtr(d, Foreign.K_NAME, Mem.cstr("jni-peer"));
			Mem.setI64(d, Foreign.K_FLAGS, Foreign.TOGGLE_NOTIFY);
			Mem.setPtr(d, Foreign.K_RELEASE, Callback.addr(releasePeer));
			Mem.setPtr(d, Foreign.K_BATCH_BEGIN, Callback.addr(batchBegin));
			peerKind = Foreign.registerLocked(d);
			Atomic.store32(Mem.sym("rt_jni_kind"), jk);
		}
		Os.unlock(Foreign.lock);
		return kind;
	}

	@:hxmc.callback @:hxmc.unsafe static function retain(ref:Ptr):Ptr {
		var env = envHere();
		return env.isNull() ? Ptr.nil() : Ind.p2(fn(env, NewGlobalRef), env, ref);
	}

	// (the count left: none, the JVM has no counts)
	@:hxmc.callback @:hxmc.unsafe static function release(ref:Ptr):Ptr {
		var env = envHere();
		if (!env.isNull() && !ref.isNull()) Ind.p2(fn(env, DeleteGlobalRef), env, ref);
		return Ptr.nil();
	}

	// a peer's record died with its Haxe object: its weak reference deleted
	@:hxmc.callback @:hxmc.unsafe static function releasePeer(rec:Ptr):Ptr {
		var env = envHere();
		var w = Mem.getPtr(rec, REC_WEAK);
		if (!env.isNull() && !w.isNull()) Ind.p2(fn(env, DeleteWeakGlobalRef), env, w);
		Os.lock(lock);
		var e = Mem.getI64(rec, REC_ENTRY).toInt();
		if (e > 0 && e < recsCap && Mem.getPtr(recs, 8 * e) == rec) Mem.setPtr(recs, 8 * e, Ptr.nil());
		Os.unlock(lock);
		LibC.free(rec);
		return Ptr.nil();
	}

	// the key of ref's box: System.identityHashCode, made a word that is
	// neither null nor a tombstone (Foreign.boxGone)
	@:hxmc.callback @:hxmc.unsafe static function identity(ref:Ptr):Ptr {
		var env = envHere();
		if (env.isNull()) return ref;
		var sys = Mem.getPtr(cells, C_SYSTEM), m = Mem.getPtr(cells, C_IDHASH);
		if (sys.isNull() || m.isNull()) return Ptr.ofI64(8);
		var a = Mem.stack(8);
		Mem.setPtr(a, 0, ref);
		var h = callIn(env, CallStaticMethodA + 3 * T_INT, sys, m, a).toI64() & 0xFFFFFFFF;
		pending(env);
		return Ptr.ofI64((h << 4) | 8);
	}

	@:hxmc.callback @:hxmc.unsafe static function same(a:Ptr, b:Ptr):Ptr {
		var env = envHere();
		if (env.isNull()) return a == b ? Ptr.ofI64(1) : Ptr.nil();
		return bool(Ind.p3(fn(env, IsSameObject), env, a, b)) ? Ptr.ofI64(1) : Ptr.nil();
	}

	// the peer entry of ref: an org.hxmc.Peer's handle (a proxy of a Haxe
	// object), else -1
	@:hxmc.callback @:hxmc.unsafe static function peerOf(ref:Ptr):Ptr {
		var pc = cells.isNull() ? Ptr.nil() : Mem.getPtr(cells, C_PEER);
		if (pc.isNull()) return Ptr.ofI64(-1);
		var env = envHere();
		if (env.isNull()) return Ptr.ofI64(-1);
		if (!bool(Ind.p3(fn(env, IsInstanceOf), env, ref, pc))) return Ptr.ofI64(-1);
		return Ind.p3(fn(env, GetField + T_LONG), env, ref, Mem.getPtr(cells, C_PEER_HANDLE));
	}

	@:hxmc.callback @:hxmc.unsafe static function weakInit(cell:Ptr, ref:Ptr):Void {
		var env = envHere();
		Mem.setPtr(cell, 0, env.isNull() ? Ptr.nil() : Ind.p2(fn(env, NewWeakGlobalRef), env, ref));
	}

	// (+1: a global reference, null once the object is collected)
	@:hxmc.callback @:hxmc.unsafe static function weakLoad(cell:Ptr):Ptr {
		var env = envHere();
		var w = Mem.getPtr(cell, 0);
		if (env.isNull() || w.isNull()) return Ptr.nil();
		return Ind.p2(fn(env, NewGlobalRef), env, w);
	}

	@:hxmc.callback @:hxmc.unsafe static function weakDestroy(cell:Ptr):Void {
		var env = envHere();
		var w = Mem.getPtr(cell, 0);
		if (!env.isNull() && !w.isNull()) Ind.p2(fn(env, DeleteWeakGlobalRef), env, w);
		Mem.setPtr(cell, 0, Ptr.nil());
	}

	// (the releases put off: this thread attached first, once)
	@:hxmc.callback @:hxmc.unsafe static function batchBegin():Ptr {
		envHere();
		return Ptr.nil();
	}

	// a call into Java (the table's function i: Call...MethodA, NewObjectA)
	// in a safe region, as every call that runs Java code is: a Java thread
	// that calls a native of the program waits for a collection, which this
	// thread, in Java, would otherwise hold up
	@:hxmc.unsafe static function callIn(env:Ptr, i:Int, a:Ptr, b:Ptr, c:Ptr):Ptr {
		var region = Leaf.rt_blocking_enter();
		var r = Ind.p4(fn(env, i), env, a, b, c);
		Regions.end(region);
		return r;
	}

	@:hxmc.unsafe static function callInD(env:Ptr, i:Int, a:Ptr, b:Ptr, c:Ptr):Float {
		var region = Leaf.rt_blocking_enter();
		var r = Ind.d4(fn(env, i), env, a, b, c);
		Regions.end(region);
		return r;
	}

	// ---- threads

	// the calling thread's JNIEnv: the one it had, the JVM's (GetEnv: a Java
	// thread), else attached now as a daemon thread (detached as it ends:
	// the key's destructor); null without a JVM
	@:hxmc.unsafe static function envHere():Ptr {
		var e = tenv;
		if (!e.isNull()) return e;
		if (vm.isNull()) return Ptr.nil();
		var out = Mem.stack(8);
		Mem.setPtr(out, 0, Ptr.nil());
		var r = int32(Ind.p3(vmFn(GetEnv), vm, out, Ptr.ofI64(JNI_VERSION_1_6)));
		if (r == JNI_EDETACHED) {
			var region = Leaf.rt_blocking_enter();
			r = int32(Ind.p3(vmFn(AttachCurrentThreadAsDaemon), vm, out, Ptr.nil()));
			Regions.end(region);
			if (r == 0 && !key.isNull()) P.pthread_setspecific(Mem.getI64(key, 0), Ptr.ofI64(1));
		}
		if (r != 0) return Ptr.nil();
		e = Mem.getPtr(out, 0);
		tenv = e;
		return e;
	}

	// (the key's destructor: a thread attached here ends)
	@:hxmc.callback @:hxmc.unsafe static function threadEnd(v:Ptr):Void {
		tenv = Ptr.nil();
		if (!vm.isNull()) Ind.p1(vmFn(DetachCurrentThread), vm);
	}

	// the lock, the key, the cells (no Haxe code may have run yet: JNI_OnLoad;
	// the kinds are registered at their first use, k)
	@:hxmc.unsafe static function initOnce():Void {
		if (!lock.isNull()) return;
		lock = LibC.malloc(Os.MUTEX_BYTES);
		Os.mutexInit(lock);
		key = LibC.malloc(8);
		Mem.setI64(key, 0, 0);
		P.pthread_key_create(key, Callback.addr(threadEnd));
		cells = LibC.malloc(CELLS);
		LibC.memset(cells, 0, CELLS);
	}

	// the JVM is vm (JNI_CreateJavaVM's, JNI_OnLoad's, an activity's), this
	// thread's env env: the runtime's own classes and members
	@:hxmc.unsafe static function setVm(v:Ptr, env:Ptr):Void {
		initOnce();
		vm = v;
		tenv = env;
		var sys = globalClass(env, Mem.cstr("java/lang/System"));
		Mem.setPtr(cells, C_IDHASH, smethod(env, sys, Mem.cstr("identityHashCode"), Mem.cstr("(Ljava/lang/Object;)I")));
		Mem.setPtr(cells, C_SYSTEM, sys);
		var cls = globalClass(env, Mem.cstr("java/lang/Class"));
		Mem.setPtr(cells, C_CLASS, cls);
		Mem.setPtr(cells, C_GETNAME, method(env, cls, Mem.cstr("getName"), Mem.cstr("()Ljava/lang/String;")));
		var t = globalClass(env, Mem.cstr("java/lang/Throwable"));
		Mem.setPtr(cells, C_THROWABLE, t);
		Mem.setPtr(cells, C_TOSTRING, method(env, t, Mem.cstr("toString"), Mem.cstr("()Ljava/lang/String;")));
		Mem.setPtr(cells, C_GETMESSAGE, method(env, t, Mem.cstr("getMessage"), Mem.cstr("()Ljava/lang/String;")));
		Mem.setPtr(cells, C_STACK, method(env, t, Mem.cstr("getStackTrace"), Mem.cstr("()[Ljava/lang/StackTraceElement;")));
		var ste = globalClass(env, Mem.cstr("java/lang/StackTraceElement"));
		Mem.setPtr(cells, C_STE_TOSTRING, method(env, ste, Mem.cstr("toString"), Mem.cstr("()Ljava/lang/String;")));
		Mem.setPtr(cells, C_STRING, globalClass(env, Mem.cstr("java/lang/String")));
		var i = globalClass(env, Mem.cstr("java/lang/Integer"));
		Mem.setPtr(cells, C_INTEGER, i);
		Mem.setPtr(cells, C_INT_OF, smethod(env, i, Mem.cstr("valueOf"), Mem.cstr("(I)Ljava/lang/Integer;")));
		Mem.setPtr(cells, C_INT_VALUE, method(env, i, Mem.cstr("intValue"), Mem.cstr("()I")));
		var d = globalClass(env, Mem.cstr("java/lang/Double"));
		Mem.setPtr(cells, C_DOUBLE, d);
		Mem.setPtr(cells, C_DOUBLE_OF, smethod(env, d, Mem.cstr("valueOf"), Mem.cstr("(D)Ljava/lang/Double;")));
		Mem.setPtr(cells, C_DOUBLE_VALUE, method(env, d, Mem.cstr("doubleValue"), Mem.cstr("()D")));
		var b = globalClass(env, Mem.cstr("java/lang/Boolean"));
		Mem.setPtr(cells, C_BOOLEAN, b);
		Mem.setPtr(cells, C_BOOLEAN_OF, smethod(env, b, Mem.cstr("valueOf"), Mem.cstr("(Z)Ljava/lang/Boolean;")));
		Mem.setPtr(cells, C_BOOLEAN_VALUE, method(env, b, Mem.cstr("booleanValue"), Mem.cstr("()Z")));
		var n = globalClass(env, Mem.cstr("java/lang/Number"));
		Mem.setPtr(cells, C_NUMBER, n);
		Mem.setPtr(cells, C_NUMBER_DOUBLE, method(env, n, Mem.cstr("doubleValue"), Mem.cstr("()D")));
		var l = globalClass(env, Mem.cstr("java/lang/Long"));
		Mem.setPtr(cells, C_LONG, l);
		Mem.setPtr(cells, C_LONG_VALUE, method(env, l, Mem.cstr("longValue"), Mem.cstr("()J")));
		var ch = globalClass(env, Mem.cstr("java/lang/Character"));
		Mem.setPtr(cells, C_CHARACTER, ch);
		Mem.setPtr(cells, C_CHAR_VALUE, method(env, ch, Mem.cstr("charValue"), Mem.cstr("()C")));
		var o = globalClass(env, Mem.cstr("java/lang/Object"));
		Mem.setPtr(cells, C_OBJECT, o);
		Mem.setPtr(cells, C_OBJECT_TOSTRING, method(env, o, Mem.cstr("toString"), Mem.cstr("()Ljava/lang/String;")));
		Mem.setPtr(cells, C_ILLEGAL_STATE, globalClass(env, Mem.cstr("java/lang/IllegalStateException")));
		Mem.setPtr(cells, C_ILLEGAL_ARGUMENT, globalClass(env, Mem.cstr("java/lang/IllegalArgumentException")));
		Mem.setPtr(cells, C_NPE, globalClass(env, Mem.cstr("java/lang/NullPointerException")));
		if (pending(env)) Ind.p1(fn(env, ExceptionClear), env);
	}

	// a class of the boot class path (FindClass) as a global reference
	@:hxmc.unsafe static function globalClass(env:Ptr, name:Ptr):Ptr {
		var c = Ind.p2(fn(env, FindClass), env, name);
		if (c.isNull() || pending(env)) {
			Ind.p1(fn(env, ExceptionClear), env);
			return Ptr.nil();
		}
		var g = Ind.p2(fn(env, NewGlobalRef), env, c);
		Ind.p2(fn(env, DeleteLocalRef), env, c);
		return g;
	}

	// (a method of the JDK's: null, and nothing pending, when there is none)
	@:hxmc.unsafe static function method(env:Ptr, cls:Ptr, name:Ptr, sig:Ptr):Ptr {
		if (cls.isNull()) return cls;
		var m = Ind.p4(fn(env, GetMethodID), env, cls, name, sig);
		if (pending(env)) {
			Ind.p1(fn(env, ExceptionClear), env);
			return Ptr.nil();
		}
		return m;
	}

	@:hxmc.unsafe static function smethod(env:Ptr, cls:Ptr, name:Ptr, sig:Ptr):Ptr {
		if (cls.isNull()) return cls;
		var m = Ind.p4(fn(env, GetStaticMethodID), env, cls, name, sig);
		if (pending(env)) {
			Ind.p1(fn(env, ExceptionClear), env);
			return Ptr.nil();
		}
		return m;
	}

	// the class loader of the classes the program declares: org.hxmc.Peer's
	// (the glue's), else the context class loader of this thread (a JNI_OnLoad's
	// caller's, an app's main thread's)
	@:hxmc.unsafe static function findLoader(env:Ptr):Void {
		var c = Ind.p2(fn(env, FindClass), env, Mem.cstr("org/hxmc/Peer"));
		var l = Ptr.nil();
		if (c.isNull() || pending(env)) {
			Ind.p1(fn(env, ExceptionClear), env);
			var tc = Ind.p2(fn(env, FindClass), env, Mem.cstr("java/lang/Thread"));
			if (tc.isNull() || pending(env)) {
				Ind.p1(fn(env, ExceptionClear), env);
				return;
			}
			var cur = Ind.p4(fn(env, CallStaticMethodA + 3 * T_OBJECT), env, tc,
				smethod(env, tc, Mem.cstr("currentThread"), Mem.cstr("()Ljava/lang/Thread;")), Ptr.nil());
			if (!pending(env) && !cur.isNull())
				l = Ind.p4(fn(env, CallMethodA + 3 * T_OBJECT), env, cur, method(env, tc, Mem.cstr("getContextClassLoader"), Mem.cstr("()Ljava/lang/ClassLoader;")),
					Ptr.nil());
		} else {
			var cc = Ind.p2(fn(env, GetObjectClass), env, c);
			l = Ind.p4(fn(env, CallMethodA + 3 * T_OBJECT), env, c, method(env, cc, Mem.cstr("getClassLoader"), Mem.cstr("()Ljava/lang/ClassLoader;")), Ptr.nil());
		}
		if (pending(env)) {
			Ind.p1(fn(env, ExceptionClear), env);
			return;
		}
		useLoader(env, l);
	}

	@:hxmc.unsafe static function useLoader(env:Ptr, l:Ptr):Void {
		if (l.isNull()) return;
		var lc = Ind.p2(fn(env, GetObjectClass), env, l);
		var m = method(env, lc, Mem.cstr("loadClass"), Mem.cstr("(Ljava/lang/String;)Ljava/lang/Class;"));
		if (m.isNull() || pending(env)) {
			Ind.p1(fn(env, ExceptionClear), env);
			return;
		}
		if (!loader.isNull()) Ind.p2(fn(env, DeleteGlobalRef), env, loader);
		loader = Ind.p2(fn(env, NewGlobalRef), env, l);
		loadClass = m;
	}

	// JNI_OnLoad (hxmc.java.Jvm.onLoad: no Haxe code has run, on the Java
	// thread loading the library): the JVM, its loader, then the program's
	// main on a thread of its own, waited for
	@:hxmc.unsafe static function onLoad(v:Ptr):Int {
		var out = Mem.stack(8);
		Mem.setPtr(out, 0, Ptr.nil());
		if (int32(Ind.p3(Mem.getPtr(Mem.getPtr(v, 0), 8 * GetEnv), v, out, Ptr.ofI64(JNI_VERSION_1_6))) != 0) return -1;
		var env = Mem.getPtr(out, 0);
		setVm(v, env);
		findLoader(env);
		// (this thread's env is the JVM's: the program's thread finds its own)
		tenv = Ptr.nil();
		var t = Mem.stack(16);
		if (P.pthread_create(t, Ptr.nil(), Callback.addr(mainThread), Ptr.nil()) != 0) return -1;
		P.pthread_join(Mem.getI64(t, 0), Ptr.nil());
		return JNI_VERSION_1_6;
	}

	@:hxmc.callback @:hxmc.unsafe static function mainThread(arg:Ptr):Ptr {
		var argv = Mem.stack(16);
		Mem.setPtr(argv, 0, Mem.cstr("hxmc"));
		Mem.setPtr(argv, 8, Ptr.nil());
		P.main(1, argv);
		// (its program ended, the thread ends: its record stays, in a safe
		// region, so that the collections Java's calls make do not wait for it)
		Leaf.rt_blocking_enter();
		return Ptr.nil();
	}

	// an Android activity's JVM (ANativeActivity: vm at 8, clazz at 24): its
	// class loader (the app's, which knows classes.dex's)
	@:hxmc.unsafe static function useActivity(activity:Ptr):Void {
		var v = Mem.getPtr(activity, 8);
		initOnce();
		vm = v;
		tenv = Ptr.nil();
		var env = envHere();
		if (env.isNull()) return;
		setVm(v, env);
		var clazz = Mem.getPtr(activity, 24);
		var ac = Ind.p2(fn(env, GetObjectClass), env, clazz);
		var l = Ind.p4(fn(env, CallMethodA + 3 * T_OBJECT), env, clazz, method(env, ac, Mem.cstr("getClassLoader"), Mem.cstr("()Ljava/lang/ClassLoader;")), Ptr.nil());
		if (pending(env)) Ind.p1(fn(env, ExceptionClear), env) else useLoader(env, l);
	}

	// ---- embedding: libjvm opened, JNI_CreateJavaVM (hxmc.java.Jvm.create)

	@:hxmc.unsafe(gc) static function create(lib:String, options:Array<String>):Null<String> {
		if (!vm.isNull()) return null;
		var path = Str.toUtf8(lib);
		var h = Posix.dlopen(path, 2);
		LibC.free(path);
		if (h.isNull()) return "cannot load " + lib + ": " + cstring(Posix.dlerror());
		// (one made already: JNI_GetCreatedJavaVMs)
		var got = Posix.dlsym(h, Mem.cstr("JNI_GetCreatedJavaVMs"));
		var out = Mem.stack(16);
		Mem.setPtr(out, 0, Ptr.nil());
		Mem.setPtr(out, 8, Ptr.nil());
		if (!got.isNull() && int32(Ind.p3(got, out, Ptr.ofI64(1), out.add(8))) == 0 && !Mem.getPtr(out, 0).isNull()) {
			var v = Mem.getPtr(out, 0);
			vm = v;
			var env = envHere();
			if (env.isNull()) return "cannot attach to the Java VM";
			setVm(v, env);
			findLoader(env);
			return null;
		}
		var f = Posix.dlsym(h, Mem.cstr("JNI_CreateJavaVM"));
		if (f.isNull()) return lib + " has no JNI_CreateJavaVM";
		var n = options.length;
		var opts = LibC.malloc((16 * (n + 1) : I64));
		for (i in 0...n) {
			Mem.setPtr(opts, 16 * i, Str.toUtf8(options[i]));
			Mem.setPtr(opts, 16 * i + 8, Ptr.nil());
		}
		var args = Mem.stack(24);
		Mem.setI32(args, 0, JNI_VERSION_1_6);
		Mem.setI32(args, 4, n);
		Mem.setPtr(args, 8, opts);
		Mem.setI64(args, 16, 0); // (ignoreUnrecognized: false)
		var pvm = Mem.stack(16);
		Mem.setPtr(pvm, 0, Ptr.nil());
		Mem.setPtr(pvm, 8, Ptr.nil());
		var region = Leaf.rt_blocking_enter();
		var r = int32(Ind.p3(f, pvm, pvm.add(8), args));
		Regions.end(region);
		for (i in 0...n)
			LibC.free(Mem.getPtr(opts, 16 * i));
		LibC.free(opts);
		if (r != 0) return "JNI_CreateJavaVM failed (" + r + ")";
		setVm(Mem.getPtr(pvm, 0), Mem.getPtr(pvm, 8));
		findLoader(Mem.getPtr(pvm, 8));
		Os.exitHook = Callback.addr(javaExit);
		return null;
	}

	// the end of a program that made its JVM (Os.exitHook): Java's
	// System.exit, which stops the JVM's threads before the C library's exit
	// (as the java launcher's end does). Otherwise exit runs libjvm's
	// destructors while they run: -Xcheck:jni's check of the signal handlers
	// (every 10 ms) then reads the handlers it saved, freed, and reports
	// every one modified. Its shutdown hooks run; nothing waits for its
	// other threads. Not on the way back (a pending exception: exit as before)
	@:hxmc.callback @:hxmc.unsafe static function javaExit(code:Int):Void {
		var env = envHere();
		if (env.isNull()) return;
		var sys = Mem.getPtr(cells, C_SYSTEM);
		var m = smethod(env, sys, Mem.cstr("exit"), Mem.cstr("(I)V"));
		if (!m.isNull()) {
			var a = Mem.stack(8);
			Mem.setI64(a, 0, 0);
			Mem.setI32(a, 0, code);
			callIn(env, CallStaticMethodA + 3 * T_VOID, sys, m, a);
		}
		if (pending(env)) Ind.p1(fn(env, ExceptionClear), env);
	}

	@:hxmc.unsafe(gc) static function hasVm():Bool
		return !vm.isNull();

	@:hxmc.unsafe(gc) static function cstring(p:Ptr):String
		return p.isNull() ? "" : Str.ofUtf8(p, LibC.strlen(p).toInt());

	// ---- calls (FnLower.jniCall: enter, class, member, arguments, call, result, leave)

	// the calling thread's JNIEnv, a local frame pushed for the call
	@:hxmc.unsafe(gc) @:hxmc.host("rt_jni_enter") static function enter():Ptr {
		var env = envHere();
		if (env.isNull())
			throw new hxmc.java.JavaException("java.lang.IllegalStateException",
				vm.isNull() ? "no Java VM: call hxmc.java.Jvm.create, or load the library into a JVM (hxmc.java.Jvm.onLoad)" : "cannot attach this thread to the Java VM", "", null);
		Ind.p2(fn(env, PushLocalFrame), env, Ptr.ofI64(16));
		return env;
	}

	// the frame popped; a pending exception thrown as a JavaException
	@:hxmc.unsafe(gc) @:hxmc.host("rt_jni_leave") static function leave(env:Ptr):Void {
		if (pending(env)) {
			var x = caught(env);
			Ind.p2(fn(env, PopLocalFrame), env, Ptr.nil());
			throw x;
		}
		Ind.p2(fn(env, PopLocalFrame), env, Ptr.nil());
	}

	// the class `name` (java/lang/String) of a cell: resolved once, a global
	// reference (the program's loader's, else FindClass's)
	@:hxmc.unsafe(gc) @:hxmc.host("rt_jni_class") static function cls(env:Ptr, cell:Ptr, name:String):Ptr {
		var c = Mem.getPtr(cell, 0);
		if (!c.isNull() || pending(env)) return c;
		c = classNamed(env, name);
		if (c.isNull()) return c;
		if (!Ptr.ofI64(Atomic.cas64(cell, 0, c.toI64())).isNull()) {
			Ind.p2(fn(env, DeleteGlobalRef), env, c);
			c = Mem.getPtr(cell, 0);
		}
		return c;
	}

	// (a new global reference; null and an exception pending when there is none)
	@:hxmc.unsafe(gc) static function classNamed(env:Ptr, name:String):Ptr {
		var local = Ptr.nil();
		// (loading a class may run its static initializer: Java code)
		if (!loader.isNull() && Str.unit(name, 0) != "[".code) {
			var a = Mem.stack(8);
			var js = newString(env, StringTools.replace(name, "/", "."));
			Mem.setPtr(a, 0, js);
			var region = Leaf.rt_blocking_enter();
			local = Ind.p4(fn(env, CallMethodA + 3 * T_OBJECT), env, loader, loadClass, a);
			Regions.end(region);
			if (pending(env)) local = Ptr.nil();
			Ind.p2(fn(env, DeleteLocalRef), env, js);
		} else {
			var p = Str.toUtf8(name);
			var region = Leaf.rt_blocking_enter();
			local = Ind.p2(fn(env, FindClass), env, p);
			Regions.end(region);
			if (pending(env)) local = Ptr.nil();
			LibC.free(p);
		}
		if (local.isNull()) return local;
		var g = Ind.p2(fn(env, NewGlobalRef), env, local);
		Ind.p2(fn(env, DeleteLocalRef), env, local);
		return g;
	}

	// a method or field ID of a cell, resolved once (null and an exception
	// pending: NoSuchMethodError, NoSuchFieldError)
	@:hxmc.unsafe(gc) @:hxmc.host("rt_jni_member") static function member(env:Ptr, cell:Ptr, cls:Ptr, name:String, sig:String, what:Int):Ptr {
		var m = Mem.getPtr(cell, 0);
		if (!m.isNull() || cls.isNull() || pending(env)) return m;
		var n = Str.toUtf8(name), s = Str.toUtf8(sig);
		var i = what == M_METHOD ? GetMethodID : what == M_STATIC_METHOD ? GetStaticMethodID : what == M_FIELD ? GetFieldID : GetStaticFieldID;
		// (a static member's resolution initializes its class: Java code)
		var region = Leaf.rt_blocking_enter();
		m = Ind.p4(fn(env, i), env, cls, n, s);
		Regions.end(region);
		LibC.free(n);
		LibC.free(s);
		if (!m.isNull()) Mem.setPtr(cell, 0, m);
		return m;
	}

	// a call: an instance method's (target the receiver), a static one's
	// (STATIC: the class), a constructor's (NEW); how's low bits the result's
	// type code (any but float and double: callF); the arguments a jvalue array
	@:hxmc.unsafe(gc) @:hxmc.host("rt_jni_call") static function call(env:Ptr, how:Int, target:Ptr, cls:Ptr, mid:Ptr, args:Ptr):I64 {
		if (mid.isNull() || pending(env)) return 0;
		if (how & (STATIC | NEW) == 0 && target.isNull()) {
			throwNew(env, C_NPE, "a Java method called on null");
			return 0;
		}
		var t = how & 15;
		var region = Leaf.rt_blocking_enter();
		var r = how & NEW != 0 ? Ind.p4(fn(env, NewObjectA), env, cls, mid, args) : how & STATIC != 0 ? Ind.p4(fn(env, CallStaticMethodA + 3 * t), env, cls,
			mid, args) : Ind.p4(fn(env, CallMethodA + 3 * t), env, target, mid, args);
		Regions.end(region);
		return how & NEW != 0 ? r.toI64() : widen(r.toI64(), t);
	}

	@:hxmc.unsafe(gc) @:hxmc.host("rt_jni_call_f") static function callF(env:Ptr, how:Int, target:Ptr, cls:Ptr, mid:Ptr, args:Ptr):Float {
		if (mid.isNull() || pending(env)) return 0;
		if (how & STATIC == 0 && target.isNull()) {
			throwNew(env, C_NPE, "a Java method called on null");
			return 0;
		}
		var t = how & 15;
		var i = (how & STATIC != 0 ? CallStaticMethodA : CallMethodA) + 3 * t;
		var o = how & STATIC != 0 ? cls : target;
		var region = Leaf.rt_blocking_enter();
		var r:Float = t == T_FLOAT ? (Ind.f4(fn(env, i), env, o, mid, args) : Float) : Ind.d4(fn(env, i), env, o, mid, args);
		Regions.end(region);
		return r;
	}

	// (a C result of type code t, as the call's register left it: its bits)
	static inline function widen(r:I64, t:Int):I64
		return switch t {
			case T_BOOLEAN: r & 0xFF;
			case T_BYTE: (r << 56) >> 56;
			case T_CHAR: r & 0xFFFF;
			case T_SHORT: (r << 48) >> 48;
			case T_INT: (r << 32) >> 32;
			case T_VOID: 0;
			case _: r;
		}

	// a field read (STATIC: of the class)
	@:hxmc.unsafe(gc) @:hxmc.host("rt_jni_get") static function get(env:Ptr, how:Int, target:Ptr, fid:Ptr):I64 {
		if (fid.isNull() || pending(env)) return 0;
		if (how & STATIC == 0 && target.isNull()) {
			throwNew(env, C_NPE, "a Java field read of null");
			return 0;
		}
		var t = how & 15;
		return widen(Ind.p3(fn(env, (how & STATIC != 0 ? GetStaticField : GetField) + t), env, target, fid).toI64(), t);
	}

	@:hxmc.unsafe(gc) @:hxmc.host("rt_jni_get_f") static function getF(env:Ptr, how:Int, target:Ptr, fid:Ptr):Float {
		if (fid.isNull() || pending(env)) return 0;
		if (how & STATIC == 0 && target.isNull()) {
			throwNew(env, C_NPE, "a Java field read of null");
			return 0;
		}
		var t = how & 15;
		var i = (how & STATIC != 0 ? GetStaticField : GetField) + t;
		return t == T_FLOAT ? (Ind.f3(fn(env, i), env, target, fid) : Float) : Ind.d3(fn(env, i), env, target, fid);
	}

	@:hxmc.unsafe(gc) @:hxmc.host("rt_jni_set") static function set(env:Ptr, how:Int, target:Ptr, fid:Ptr, v:I64):Void {
		if (fid.isNull() || pending(env)) return;
		if (how & STATIC == 0 && target.isNull()) {
			throwNew(env, C_NPE, "a Java field written of null");
			return;
		}
		Ind.p4(fn(env, (how & STATIC != 0 ? SetStaticField : SetField) + (how & 15)), env, target, fid, Ptr.ofI64(v));
	}

	@:hxmc.unsafe(gc) @:hxmc.host("rt_jni_set_f") static function setF(env:Ptr, how:Int, target:Ptr, fid:Ptr, v:Float):Void {
		if (fid.isNull() || pending(env)) return;
		if (how & STATIC == 0 && target.isNull()) {
			throwNew(env, C_NPE, "a Java field written of null");
			return;
		}
		var t = how & 15;
		var i = (how & STATIC != 0 ? SetStaticField : SetField) + t;
		if (t == T_FLOAT) Ind.vf(fn(env, i), env, target, fid, v) else Ind.vd(fn(env, i), env, target, fid, v);
	}

	// an exception of the runtime's own classes (a cell) made pending
	@:hxmc.unsafe(gc) static function throwNew(env:Ptr, c:Int, msg:String):Void {
		var cl = Mem.getPtr(cells, c);
		if (cl.isNull() || pending(env)) return;
		var p = Str.toUtf8(msg);
		var region = Leaf.rt_blocking_enter();
		Ind.p3(fn(env, ThrowNew), env, cl, p);
		Regions.end(region);
		LibC.free(p);
	}

	// ---- values: Haxe's as Java's (a local reference of the call's frame)

	@:hxmc.unsafe(gc) @:hxmc.host("rt_jni_arg") static function arg(env:Ptr, v:Dynamic, how:Int, cls:String):Ptr {
		if (pending(env) || v == null) return Ptr.nil();
		switch how {
			case R_OBJECT:
				return objectRef(env, v);
			case R_STRING:
				return newString(env, (v : String));
			case R_DYNAMIC:
				return boxed(env, v);
			case R_INTEGER:
				return valueOf(env, C_INTEGER, C_INT_OF, (v : Int));
			case R_DOUBLE:
				var a = Mem.stack(8);
				Mem.setF64(a, 0, (v : Float));
				return callIn(env, CallStaticMethodA + 3 * T_OBJECT, Mem.getPtr(cells, C_DOUBLE), Mem.getPtr(cells, C_DOUBLE_OF), a);
			case R_BOOLEAN:
				return valueOf(env, C_BOOLEAN, C_BOOLEAN_OF, (v : Bool) ? 1 : 0);
			case R_BYTES:
				return bytesArray(env, v);
			case R_STRINGS | R_OBJECTS | R_DYNAMICS:
				var xs:Array<Dynamic> = v;
				var ec = how == R_STRINGS ? Mem.getPtr(cells, C_STRING) : how == R_DYNAMICS ? Mem.getPtr(cells, C_OBJECT) : elementClass(env, cls);
				if (ec.isNull()) return Ptr.nil();
				var a = Ind.p4(fn(env, NewObjectArray), env, Ptr.ofI64(xs.length), ec, Ptr.nil());
				if (a.isNull()) return a;
				for (i in 0...xs.length) {
					var x = arg(env, xs[i], how == R_STRINGS ? R_STRING : how == R_DYNAMICS ? R_DYNAMIC : R_OBJECT, null);
					if (pending(env)) return Ptr.nil();
					Ind.p4(fn(env, SetObjectArrayElement), env, a, Ptr.ofI64(i), x);
					if (!x.isNull()) Ind.p2(fn(env, DeleteLocalRef), env, x);
				}
				return a;
			case _:
				return primArray(env, v, how - R_PRIMS);
		}
	}

	// Bytes as a new byte[] (copied: SetByteArrayRegion, which runs no Java
	// code, so the Bytes stays where it is)
	@:hxmc.unsafe(gc) static function bytesArray(env:Ptr, b:haxe.io.Bytes):Ptr {
		var a = Ind.p2(fn(env, NewArray + T_BYTE), env, Ptr.ofI64(b.length));
		if (!a.isNull() && !pending(env) && b.length > 0) Ind.p5(fn(env, SetArrayRegion + T_BYTE), env, a, Ptr.nil(), Ptr.ofI64(b.length), hxmc.Span.SpanSupport.bytesAddr(b, 0));
		return a;
	}

	@:hxmc.unsafe(gc) static function bytesOf(env:Ptr, ref:Ptr):haxe.io.Bytes {
		var n = int32(Ind.p2(fn(env, GetArrayLength), env, ref));
		var b = haxe.io.Bytes.alloc(n);
		if (n > 0) Ind.p5(fn(env, GetArrayRegion + T_BYTE), env, ref, Ptr.nil(), Ptr.ofI64(n), hxmc.Span.SpanSupport.bytesAddr(b, 0));
		return b;
	}

	// the element class of an object array (an element type's name)
	@:hxmc.unsafe(gc) static function elementClass(env:Ptr, name:String):Ptr {
		var c = classNamed(env, name);
		if (c.isNull()) return c;
		var l = Ind.p2(fn(env, NewLocalRef), env, c);
		Ind.p2(fn(env, DeleteGlobalRef), env, c);
		return l;
	}

	@:hxmc.unsafe(gc) static function valueOf(env:Ptr, c:Int, m:Int, x:Int):Ptr {
		var a = Mem.stack(8);
		Mem.setI64(a, 0, 0);
		Mem.setI32(a, 0, x);
		return callIn(env, CallStaticMethodA + 3 * T_OBJECT, Mem.getPtr(cells, c), Mem.getPtr(cells, m), a);
	}

	// a Java object's local reference: a box's (its global reference), or a
	// Haxe object's proxy (made at its first use)
	@:hxmc.unsafe(gc) static function objectRef(env:Ptr, v:Dynamic):Ptr {
		if (Types.tindex(v) == Types.T_NATIVE) {
			// (a box of this kind's, not any native handle: Foreign.isBox)
			if (!Foreign.isBox(k(), Mem.addr(v))) {
				throwNew(env, C_ILLEGAL_ARGUMENT, describe(v) + " is no Java object");
				return Ptr.nil();
			}
			var r = Mem.getPtr(Mem.addr(v), 0);
			if (r.isNull()) {
				throwNew(env, C_ILLEGAL_STATE, "a Java object used after hxmc.java.Java.detach");
				return r;
			}
			return Ind.p2(fn(env, NewLocalRef), env, r);
		}
		var d = descOf(v);
		if (d.isNull()) {
			throwNew(env, C_ILLEGAL_ARGUMENT, describe(v) + " is no Java object");
			return Ptr.nil();
		}
		return proxyOf(env, v, d);
	}

	// v for a conversion's message: its class's name, or its type's (no code
	// of the program's runs: its toString may throw, which would leave the
	// call's frame pushed: FnLower.jniInvoke)
	static function describe(v:Dynamic):String {
		var c = Type.getClass(v);
		if (c != null) return "an instance of " + Type.getClassName(c);
		return switch Type.typeof(v) {
			case TObject: "an object";
			case TFunction: "a function";
			case TEnum(e): "a value of " + Type.getEnumName(e);
			case _: "a native handle";
		}
	}

	// Dynamic as java.lang.Object: numbers and Bools boxed (Integer, Double,
	// Boolean), a String a java.lang.String, a Java object or Haxe peer itself
	@:hxmc.unsafe(gc) static function boxed(env:Ptr, v:Dynamic):Ptr {
		switch Type.typeof(v) {
			case TInt:
				return valueOf(env, C_INTEGER, C_INT_OF, (v : Int));
			case TFloat:
				var a = Mem.stack(8);
				Mem.setF64(a, 0, (v : Float));
				return callIn(env, CallStaticMethodA + 3 * T_OBJECT, Mem.getPtr(cells, C_DOUBLE), Mem.getPtr(cells, C_DOUBLE_OF), a);
			case TBool:
				return valueOf(env, C_BOOLEAN, C_BOOLEAN_OF, (v : Bool) ? 1 : 0);
			case TClass(c) if (c == String):
				return newString(env, (v : String));
			case _:
		}
		if (Types.tindex(v) == Types.T_NATIVE) {
			var r = Foreign.refOf(k(), v);
			if (!r.isNull()) return Ind.p2(fn(env, NewLocalRef), env, r);
		} else {
			var d = descOf(v);
			if (!d.isNull()) return proxyOf(env, v, d);
		}
		throwNew(env, C_ILLEGAL_ARGUMENT, "a Haxe value Java cannot hold: " + describe(v));
		return Ptr.nil();
	}

	// a java.lang.String of s's UTF-16 units
	@:hxmc.unsafe(gc) static function newString(env:Ptr, s:String):Ptr {
		var n = Str.len(s);
		if (!Str.isOne(s)) return Ind.p3(fn(env, NewString), env, Str.chars2(s), Ptr.ofI64(n));
		var buf = n <= 128 ? Mem.stack(256) : LibC.malloc((2 * n : I64));
		var c:Ptr = Str.chars1(s);
		for (i in 0...n)
			Mem.setI16(buf, 2 * i, Mem.getU8(c, i));
		var r = Ind.p3(fn(env, NewString), env, buf, Ptr.ofI64(n));
		if (n > 128) LibC.free(buf);
		return r;
	}

	// an Array of numbers or Bools as a new Java array of type code t (copied)
	@:hxmc.unsafe(gc) static function primArray(env:Ptr, v:Dynamic, t:Int):Ptr {
		var n:Int = (v : Array<Dynamic>).length;
		var a = Ind.p2(fn(env, NewArray + t), env, Ptr.ofI64(n));
		if (a.isNull() || pending(env) || n == 0) return a;
		var w = width(t);
		var buf = LibC.malloc((w * n : I64));
		switch t {
			case T_BOOLEAN:
				var xs:Array<Bool> = v;
				for (i in 0...n)
					Mem.setI8(buf, i, xs[i] ? 1 : 0);
			case T_FLOAT | T_DOUBLE:
				var xs:Array<Float> = v;
				for (i in 0...n)
					if (t == T_FLOAT) Mem.setF32(buf, 4 * i, xs[i]) else Mem.setF64(buf, 8 * i, xs[i]);
			case T_LONG:
				var xs:Array<I64> = v;
				for (i in 0...n)
					Mem.setI64(buf, 8 * i, xs[i]);
			case _:
				var xs:Array<Int> = v;
				for (i in 0...n)
					switch w {
						case 1: Mem.setI8(buf, i, xs[i]);
						case 2: Mem.setI16(buf, 2 * i, xs[i]);
						case _: Mem.setI32(buf, 4 * i, xs[i]);
					}
		}
		Ind.p5(fn(env, SetArrayRegion + t), env, a, Ptr.nil(), Ptr.ofI64(n), buf);
		LibC.free(buf);
		return a;
	}

	static inline function width(t:Int):Int
		return switch t {
			case T_BOOLEAN | T_BYTE: 1;
			case T_CHAR | T_SHORT: 2;
			case T_INT | T_FLOAT: 4;
			case _: 8;
		}

	// ---- values: Java's as Haxe's

	@:hxmc.unsafe(gc) @:hxmc.host("rt_jni_result") static function result(env:Ptr, ref:Ptr, how:Int, cls:String):Dynamic {
		if (pending(env) || ref.isNull()) return null;
		switch how {
			case R_OBJECT:
				return Foreign.box(k(), ref);
			case R_STRING:
				return stringOf(env, ref);
			case R_DYNAMIC:
				return unboxed(env, ref);
			case R_INTEGER:
				return int32(callIn(env, CallMethodA + 3 * T_INT, ref, Mem.getPtr(cells, C_INT_VALUE), Ptr.nil()));
			case R_DOUBLE:
				return callInD(env, CallMethodA + 3 * T_DOUBLE, ref, Mem.getPtr(cells, C_NUMBER_DOUBLE), Ptr.nil());
			case R_BOOLEAN:
				return bool(callIn(env, CallMethodA + 3 * T_BOOLEAN, ref, Mem.getPtr(cells, C_BOOLEAN_VALUE), Ptr.nil()));
			case R_BYTES:
				return bytesOf(env, ref);
			case R_STRINGS | R_OBJECTS | R_DYNAMICS:
				var n = int32(Ind.p2(fn(env, GetArrayLength), env, ref));
				var r:Array<Dynamic> = [];
				for (i in 0...n) {
					var x = Ind.p3(fn(env, GetObjectArrayElement), env, ref, Ptr.ofI64(i));
					r.push(result(env, x, how == R_STRINGS ? R_STRING : how == R_DYNAMICS ? R_DYNAMIC : R_OBJECT, null));
					if (pending(env)) return null;
					if (!x.isNull()) Ind.p2(fn(env, DeleteLocalRef), env, x);
				}
				if (how == R_STRINGS) {
					var s:Array<String> = [for (x in r) x];
					return s;
				}
				return r;
			case _:
				return primsOf(env, ref, how - R_PRIMS);
		}
	}

	@:hxmc.unsafe(gc) static function primsOf(env:Ptr, ref:Ptr, t:Int):Dynamic {
		var n = int32(Ind.p2(fn(env, GetArrayLength), env, ref));
		var w = width(t);
		var buf = LibC.malloc((w * n + 8 : I64));
		if (n > 0) Ind.p5(fn(env, GetArrayRegion + t), env, ref, Ptr.nil(), Ptr.ofI64(n), buf);
		var r:Dynamic = switch t {
			case T_BOOLEAN:
				var xs:Array<Bool> = [for (i in 0...n) Mem.getU8(buf, i) != 0];
				xs;
			case T_FLOAT:
				var xs:Array<Float> = [for (i in 0...n) Mem.getF32(buf, 4 * i)];
				xs;
			case T_DOUBLE:
				var xs:Array<Float> = [for (i in 0...n) Mem.getF64(buf, 8 * i)];
				xs;
			case T_LONG:
				var xs:Array<I64> = [for (i in 0...n) Mem.getI64(buf, 8 * i)];
				xs;
			case T_BYTE:
				var xs:Array<Int> = [for (i in 0...n) Mem.getI8(buf, i)];
				xs;
			case T_CHAR:
				var xs:Array<Int> = [for (i in 0...n) Mem.getU16(buf, 2 * i)];
				xs;
			case T_SHORT:
				var xs:Array<Int> = [for (i in 0...n) Mem.getI16(buf, 2 * i)];
				xs;
			case _:
				var xs:Array<Int> = [for (i in 0...n) Mem.getI32(buf, 4 * i)];
				xs;
		}
		LibC.free(buf);
		return r;
	}

	// a java.lang.String's units (GetStringRegion: UTF-16, not modified UTF-8)
	@:hxmc.unsafe(gc) static function stringOf(env:Ptr, ref:Ptr):String {
		var n = int32(Ind.p2(fn(env, GetStringLength), env, ref));
		var r = Str.make2(n);
		if (n > 0) Ind.p5(fn(env, GetStringRegion), env, ref, Ptr.nil(), Ptr.ofI64(n), Str.chars2(r));
		return Repr.fitsOne(Str.chars2(r), 0, n) ? Str.range(r, 0, n) : r;
	}

	// java.lang.Object as Dynamic: a String, a number (Integer, Short, Byte
	// as Int; Double, Float, Long as Float), a Boolean, a Character's code;
	// a proxy its Haxe object; any other object its box
	@:hxmc.unsafe(gc) static function unboxed(env:Ptr, ref:Ptr):Dynamic {
		inline function is(c:Int):Bool
			return bool(Ind.p3(fn(env, IsInstanceOf), env, ref, Mem.getPtr(cells, c)));
		if (is(C_STRING)) return stringOf(env, ref);
		if (is(C_INTEGER)) return int32(callIn(env, CallMethodA + 3 * T_INT, ref, Mem.getPtr(cells, C_INT_VALUE), Ptr.nil()));
		if (is(C_CHARACTER)) return int32(callIn(env, CallMethodA + 3 * T_CHAR, ref, Mem.getPtr(cells, C_CHAR_VALUE), Ptr.nil())) & 0xFFFF;
		if (is(C_BOOLEAN)) return bool(callIn(env, CallMethodA + 3 * T_BOOLEAN, ref, Mem.getPtr(cells, C_BOOLEAN_VALUE), Ptr.nil()));
		if (is(C_NUMBER)) {
			var d:Float = callInD(env, CallMethodA + 3 * T_DOUBLE, ref, Mem.getPtr(cells, C_NUMBER_DOUBLE), Ptr.nil());
			if (pending(env)) return null;
			if (!is(C_DOUBLE) && !is(C_LONG) && d == Std.int(d) && Math.abs(d) < 2147483648.0) return Std.int(d);
			return d;
		}
		return Foreign.box(k(), ref);
	}

	// ---- exceptions

	// the pending exception as a JavaException (cleared): its class's name,
	// its message, its stack as Throwable.toString and getStackTrace print them
	@:hxmc.unsafe(gc) static function caught(env:Ptr):hxmc.java.JavaException {
		var t = Ind.p1(fn(env, ExceptionOccurred), env);
		Ind.p1(fn(env, ExceptionClear), env);
		var cl = Ind.p2(fn(env, GetObjectClass), env, t);
		var name = stringResult(env, callIn(env, CallMethodA + 3 * T_OBJECT, cl, Mem.getPtr(cells, C_GETNAME), Ptr.nil()));
		var msg = stringResult(env, callIn(env, CallMethodA + 3 * T_OBJECT, t, Mem.getPtr(cells, C_GETMESSAGE), Ptr.nil()));
		var text = stringResult(env, callIn(env, CallMethodA + 3 * T_OBJECT, t, Mem.getPtr(cells, C_TOSTRING), Ptr.nil()));
		var b = new StringBuf();
		b.add(text != null ? text : name);
		var st = callIn(env, CallMethodA + 3 * T_OBJECT, t, Mem.getPtr(cells, C_STACK), Ptr.nil());
		if (pending(env)) Ind.p1(fn(env, ExceptionClear), env) else if (!st.isNull()) {
			var n = int32(Ind.p2(fn(env, GetArrayLength), env, st));
			for (i in 0...n) {
				var e = Ind.p3(fn(env, GetObjectArrayElement), env, st, Ptr.ofI64(i));
				if (pending(env)) {
					Ind.p1(fn(env, ExceptionClear), env);
					break;
				}
				var s = stringResult(env, callIn(env, CallMethodA + 3 * T_OBJECT, e, Mem.getPtr(cells, C_STE_TOSTRING), Ptr.nil()));
				Ind.p2(fn(env, DeleteLocalRef), env, e);
				if (s != null) {
					b.add("\n\tat ");
					b.add(s);
				}
			}
		}
		return new hxmc.java.JavaException(name != null ? name : "java.lang.Throwable", msg, b.toString(), Foreign.box(k(), t));
	}

	// (a String result of a call made while handling an exception: null when it threw)
	@:hxmc.unsafe(gc) static function stringResult(env:Ptr, r:Ptr):Null<String> {
		if (pending(env)) {
			Ind.p1(fn(env, ExceptionClear), env);
			return null;
		}
		return r.isNull() ? null : stringOf(env, r);
	}

	// a Haxe exception reaching Java (a native method's thunk): a
	// JavaException's own Throwable thrown again, any other an
	// org.hxmc.HaxeException (the glue's; else a RuntimeException) of its text
	@:hxmc.unsafe(gc) @:hxmc.host("rt_jni_throw") static function throwHaxe(env:Ptr, e:Dynamic):Void {
		if (pending(env)) return;
		var j = Std.downcast(e, hxmc.java.JavaException);
		if (j != null && j.throwable != null) {
			var r = Mem.getPtr(Mem.addr(j.throwable), 0);
			if (!r.isNull()) {
				Ind.p2(fn(env, Throw), env, r);
				return;
			}
		}
		// (its text: a throw from its toString would leave the native with a Haxe exception)
		var text = try Std.isOfType(e, haxe.Exception) ? (e : haxe.Exception).message : Std.string(e) catch (_:Dynamic) "a Haxe exception";
		var c = Mem.getPtr(cells, C_HAXE_EXCEPTION);
		if (c.isNull()) {
			c = classNamed(env, "org/hxmc/HaxeException");
			if (c.isNull()) {
				Ind.p1(fn(env, ExceptionClear), env);
				c = globalClass(env, Mem.cstr("java/lang/RuntimeException"));
			}
			Mem.setPtr(cells, C_HAXE_EXCEPTION, c);
		}
		var p = Str.toUtf8(text);
		Ind.p3(fn(env, ThrowNew), env, c, p);
		LibC.free(p);
	}

	// ---- Haxe objects implementing Java interfaces: their proxies (the
	// glue's classes, docs/plans/jni.md)

	// a peer's record (its Haxe object's hidden field; the entry's reference)
	static inline var REC_WEAK = 0; // a weak global reference to its latest proxy
	static inline var REC_ENTRY = 8; // its peer entry
	static inline var REC_PROXIES = 16; // its proxies Java has not collected
	static inline var REC_BYTES = 24;
	// the records by entry (for peerRelease, on Java's threads; under lock)
	static var recs:Ptr;
	static var recsCap:Int;

	// a class's descriptor (its generated descriptor function, hxmc.ir.Jni):
	// the proxy class's name, its global reference and constructor once
	// registered, the hidden field's offset, then its natives (name,
	// signature, function: a JNINativeMethod each)
	static inline var D_NAME = 0;
	static inline var D_CLASS = 8;
	static inline var D_CTOR = 16;
	static inline var D_FIELD = 24;
	static inline var D_N = 32;
	static inline var D_NATIVES = 40;
	// (published once filled, each entry once its descriptor is: read lock-free)
	@:hxmc.export("rt_jni_types") static var types:Ptr;

	@:hxmc.host("rt_jni_known") static function typeKnown(o:Dynamic):Int
		return descOf(o).isNull() ? 0 : 1;

	@:hxmc.unsafe(gc) @:hxmc.host("rt_jni_desc") static function desc(proxy:String, n:Int):Ptr {
		var d = LibC.malloc((D_NATIVES + 24 * n : I64));
		LibC.memset(d, 0, (D_NATIVES + 24 * n : I64));
		Mem.setPtr(d, D_NAME, Str.toUtf8(StringTools.replace(proxy, ".", "/")));
		Mem.setI64(d, D_N, n);
		return d;
	}

	@:hxmc.unsafe(gc) @:hxmc.host("rt_jni_native") static function native(d:Ptr, i:Int, name:String, sig:String, f:Ptr):Void {
		var e = d.add(D_NATIVES + 24 * i);
		Mem.setPtr(e, 0, Str.toUtf8(name));
		Mem.setPtr(e, 8, Str.toUtf8(sig));
		Mem.setPtr(e, 16, f);
	}

	@:hxmc.unsafe(gc) @:hxmc.host("rt_jni_register") static function register(o:Dynamic, d:Ptr, off:Int):Void {
		Mem.setI64(d, D_FIELD, off);
		var t = Types.tindex(o);
		Os.lock(Foreign.lock);
		var ts = types;
		if (ts.isNull()) {
			ts = LibC.malloc(8 * 65536);
			LibC.memset(ts, 0, 8 * 65536);
			Atomic.store64(Mem.sym("rt_jni_types"), ts.toI64());
		}
		if (Mem.getPtr(ts, 8 * t).isNull()) Atomic.store64(ts.add(8 * t), d.toI64());
		Os.unlock(Foreign.lock);
	}

	@:hxmc.unsafe static inline function descOf(o:Dynamic):Ptr {
		var ts = Ptr.ofI64(Atomic.load64(Mem.sym("rt_jni_types")));
		return ts.isNull() ? Ptr.nil() : Ptr.ofI64(Atomic.load64(ts.add(8 * Types.tindex(o))));
	}

	// the Haxe object of a proxy's handle (a native method's thunk)
	@:hxmc.host("rt_jni_self") static function self(h:I64):Dynamic
		return Foreign.peerGet(h.toInt());

	// v's proxy (a local reference): its latest while Java has it, else a new
	// one of its class's proxy class (registered at its first use), which
	// keeps v while Java has it (the toggle)
	@:hxmc.unsafe(gc) static function proxyOf(env:Ptr, v:Dynamic, d:Ptr):Ptr {
		var rec = recordOf(v, d);
		if (rec.isNull()) return rec;
		Os.lock(lock);
		var w = Mem.getPtr(rec, REC_WEAK);
		var old = w.isNull() ? Ptr.nil() : Ind.p2(fn(env, NewLocalRef), env, w);
		Os.unlock(lock);
		if (!old.isNull()) return old;
		var cl = proxyClass(env, d);
		if (cl.isNull()) return cl;
		var entry = Mem.getI64(rec, REC_ENTRY);
		var a = Mem.stack(8);
		Mem.setI64(a, 0, entry);
		var region = Leaf.rt_blocking_enter();
		var p = Ind.p4(fn(env, NewObjectA), env, cl, Mem.getPtr(d, D_CTOR), a);
		Regions.end(region);
		if (p.isNull() || pending(env)) return Ptr.nil();
		var nw = Ind.p2(fn(env, NewWeakGlobalRef), env, p);
		Os.lock(lock);
		var prev = Mem.getPtr(rec, REC_WEAK);
		Mem.setPtr(rec, REC_WEAK, nw);
		var n = Mem.getI64(rec, REC_PROXIES) + 1;
		Mem.setI64(rec, REC_PROXIES, n);
		if (n == 1) Foreign.toggle(entry.toInt(), 1);
		Os.unlock(lock);
		if (!prev.isNull()) Ind.p2(fn(env, DeleteWeakGlobalRef), env, prev);
		return p;
	}

	// v's record, made and paired at its first use as a Java value
	@:hxmc.unsafe(gc) static function recordOf(v:Dynamic, d:Ptr):Ptr {
		var off = Mem.getI64(d, D_FIELD).toInt();
		var rec = Mem.getPtr(Mem.addr(v), off);
		if (!rec.isNull()) return rec;
		k();
		Os.lock(lock);
		rec = Mem.getPtr(Mem.addr(v), off);
		if (rec.isNull()) {
			rec = LibC.malloc(REC_BYTES);
			LibC.memset(rec, 0, REC_BYTES);
			var e = Foreign.pair(peerKind, v, rec, false);
			Mem.setI64(rec, REC_ENTRY, e);
			if (e >= recsCap) {
				var cap = recsCap == 0 ? 64 : recsCap;
				while (cap <= e)
					cap *= 2;
				recs = LibC.realloc(recs, (8 * cap : I64));
				LibC.memset(recs.add(8 * recsCap), 0, (8 * (cap - recsCap) : I64));
				recsCap = cap;
			}
			Mem.setPtr(recs, 8 * e, rec);
			Mem.setPtr(Mem.addr(v), off, rec);
		}
		Os.unlock(lock);
		return rec;
	}

	// a proxy class, registered once: found by the program's loader, its
	// natives registered (RegisterNatives), and org.hxmc.Peer's
	@:hxmc.unsafe(gc) static function proxyClass(env:Ptr, d:Ptr):Ptr {
		var c = Mem.getPtr(d, D_CLASS);
		if (!c.isNull()) return c;
		if (Mem.getPtr(cells, C_PEER).isNull()) {
			var pc = classNamed(env, "org/hxmc/Peer");
			if (pc.isNull()) return pc;
			var nat = Mem.stack(24);
			Mem.setPtr(nat, 0, Mem.cstr("hxmcRelease"));
			Mem.setPtr(nat, 8, Mem.cstr("(J)V"));
			Mem.setPtr(nat, 16, Callback.addr(peerRelease));
			Ind.p4(fn(env, RegisterNatives), env, pc, nat, Ptr.ofI64(1));
			if (pending(env)) return Ptr.nil();
			var h = Ind.p4(fn(env, GetFieldID), env, pc, Mem.cstr("hxmcHandle"), Mem.cstr("J"));
			if (h.isNull() || pending(env)) return Ptr.nil();
			Mem.setPtr(cells, C_PEER_HANDLE, h);
			Mem.setPtr(cells, C_PEER, pc);
		}
		var p:Ptr = Mem.getPtr(d, D_NAME);
		var name = cstring(p);
		var cl = classNamed(env, name);
		if (cl.isNull()) return cl;
		var n = Mem.getI64(d, D_N).toInt();
		var region = Leaf.rt_blocking_enter();
		var r = int32(Ind.p4(fn(env, RegisterNatives), env, cl, d.add(D_NATIVES), Ptr.ofI64(n)));
		Regions.end(region);
		if (r != 0 || pending(env)) return Ptr.nil();
		var ctor = Ind.p4(fn(env, GetMethodID), env, cl, Mem.cstr("<init>"), Mem.cstr("(J)V"));
		if (ctor.isNull()) return ctor;
		Mem.setPtr(d, D_CTOR, ctor);
		Mem.setPtr(d, D_CLASS, cl);
		return cl;
	}

	// org.hxmc.Peer.hxmcRelease (its daemon thread, a proxy Java collected):
	// one proxy fewer; none left, the Haxe object is no root
	@:hxmc.callback @:hxmc.unsafe static function peerRelease(env:Ptr, cls:Ptr, h:Ptr):Void {
		var e = h.toI64().toInt();
		Os.lock(lock);
		var rec = e > 0 && e < recsCap ? Mem.getPtr(recs, 8 * e) : Ptr.nil();
		if (!rec.isNull()) {
			var n = Mem.getI64(rec, REC_PROXIES) - 1;
			Mem.setI64(rec, REC_PROXIES, n);
			if (n == 0) Foreign.toggle(e, 0);
		}
		Os.unlock(lock);
	}

	// the number of v's proxies Java holds (a diagnostic: hxmc.java.Jvm.proxies)
	@:hxmc.unsafe(gc) static function proxies(v:Dynamic):Int {
		var d = descOf(v);
		if (d.isNull()) return 0;
		var rec = Mem.getPtr(Mem.addr(v), Mem.getI64(d, D_FIELD).toInt());
		return rec.isNull() ? 0 : Mem.getI64(rec, REC_PROXIES).toInt();
	}

	// ---- for hxmc.java

	// whether a and b are one Java object (null: both null)
	@:hxmc.unsafe(gc) static function same2(a:Dynamic, b:Dynamic):Bool {
		if (a == null || b == null) return a == b;
		var env = enter();
		var x = arg(env, a, R_DYNAMIC, null), y = arg(env, b, R_DYNAMIC, null);
		var r = !pending(env) && bool(Ind.p3(fn(env, IsSameObject), env, x, y));
		leave(env);
		return r;
	}

	// whether v is an instance of the class `name` (java/lang/String)
	@:hxmc.unsafe(gc) static function instanceOf(v:Dynamic, name:String):Bool {
		if (v == null) return false;
		var env = enter();
		var x = arg(env, v, R_DYNAMIC, null);
		var c = classNamed(env, name);
		var r = !pending(env) && !c.isNull() && bool(Ind.p3(fn(env, IsInstanceOf), env, x, c));
		if (!c.isNull()) Ind.p2(fn(env, DeleteGlobalRef), env, c);
		leave(env);
		return r;
	}

	// java.lang.Object.toString of v
	@:hxmc.unsafe(gc) static function toString(v:Dynamic):String {
		if (v == null) return "null";
		var env = enter();
		var x = arg(env, v, R_DYNAMIC, null);
		var s = x.isNull() ? null : callIn(env, CallMethodA + 3 * T_OBJECT, x, Mem.getPtr(cells, C_OBJECT_TOSTRING), Ptr.nil());
		var r = pending(env) || s.isNull() ? null : stringOf(env, s);
		leave(env);
		return r;
	}

	// v (a box) gives up its global reference now (Foreign.detach)
	static function detach(v:Dynamic):Void {
		var k = known();
		if (k != 0 && v != null) Foreign.detach(k, v);
	}

	// ---- weak references (hxmc.java.Weak)

	@:hxmc.unsafe(gc) static function weakNew(v:Dynamic):Ptr {
		if (v == null) return Ptr.nil();
		var r = Types.tindex(v) == Types.T_NATIVE ? Foreign.refOf(k(), v) : Ptr.nil();
		if (r.isNull()) throw new hxmc.java.JavaException("java.lang.IllegalArgumentException", "hxmc.java.Weak holds Java objects", "", null);
		var cell = Foreign.weakCell();
		weakInit(cell, r);
		return cell;
	}

	@:hxmc.unsafe(gc) static function weakGet(cell:Ptr):Dynamic {
		if (cell.isNull()) return null;
		var g = weakLoad(cell);
		if (g.isNull()) return null;
		var b = Foreign.box(k(), g);
		release(g);
		return b;
	}

	// ---- arrays (hxmc.java.JavaArray)

	@:hxmc.unsafe(gc) static function arrayLength(v:Dynamic):Int {
		var env = enter();
		var a = arg(env, v, R_OBJECT, null);
		var n = a.isNull() || pending(env) ? 0 : int32(Ind.p2(fn(env, GetArrayLength), env, a));
		leave(env);
		return n;
	}

	// a new Java array of type code t (null: of objects of the class `cls`)
	@:hxmc.unsafe(gc) static function arrayNew(t:Int, n:Int, cls:String):Dynamic {
		var env = enter();
		var a = t == T_OBJECT ? {
			var ec = elementClass(env, cls);
			ec.isNull() ? ec : Ind.p4(fn(env, NewObjectArray), env, Ptr.ofI64(n), ec, Ptr.nil());
		} : Ind.p2(fn(env, NewArray + t), env, Ptr.ofI64(n));
		var r = result(env, a, R_OBJECT, null);
		leave(env);
		return r;
	}

	// elements [pos, pos + n) of a primitive array (type code t) copied to or from p
	@:hxmc.unsafe(gc) static function arrayRegion(v:Dynamic, t:Int, pos:Int, n:Int, p:Ptr, write:Bool):Void {
		var env = enter();
		var a = arg(env, v, R_OBJECT, null);
		if (!a.isNull() && !pending(env)) Ind.p5(fn(env, (write ? SetArrayRegion : GetArrayRegion) + t), env, a, Ptr.ofI64(pos), Ptr.ofI64(n), p);
		leave(env);
	}

	// f(address, length) with the array's elements pinned
	// (GetPrimitiveArrayCritical: no JNI call and no blocking on Java until
	// it returns; the JVM may give a copy, written back after). f may
	// allocate: the runtime makes no JNI call of its own meanwhile (its calls
	// put off wait, Foreign.holdDeferred); f must call no Java itself
	@:hxmc.unsafe(gc) static function arrayCritical(v:Dynamic, f:(Ptr, Int) -> Void):Void {
		var env = enter();
		var a = arg(env, v, R_OBJECT, null);
		if (a.isNull() || pending(env)) {
			leave(env);
			return;
		}
		var n = int32(Ind.p2(fn(env, GetArrayLength), env, a));
		var p = Ind.p3(fn(env, GetPrimitiveArrayCritical), env, a, Ptr.nil());
		if (p.isNull()) {
			leave(env);
			return;
		}
		var err:Dynamic = null;
		Foreign.holdDeferred++;
		try
			f(p, n)
		catch (e:Dynamic)
			err = e;
		Foreign.holdDeferred--;
		Ind.p4(fn(env, ReleasePrimitiveArrayCritical), env, a, p, Ptr.nil());
		leave(env);
		if (err != null) throw err;
	}

	@:hxmc.unsafe(gc) static function arrayGet(v:Dynamic, i:Int):Dynamic {
		var env = enter();
		var a = arg(env, v, R_OBJECT, null);
		var x = a.isNull() || pending(env) ? Ptr.nil() : Ind.p3(fn(env, GetObjectArrayElement), env, a, Ptr.ofI64(i));
		var r = result(env, x, R_DYNAMIC, null);
		leave(env);
		return r;
	}

	@:hxmc.unsafe(gc) static function arraySet(v:Dynamic, i:Int, x:Dynamic):Void {
		var env = enter();
		var a = arg(env, v, R_OBJECT, null);
		var y = arg(env, x, R_DYNAMIC, null);
		if (!a.isNull() && !pending(env)) Ind.p4(fn(env, SetObjectArrayElement), env, a, Ptr.ofI64(i), y);
		leave(env);
	}
}

// calls through C function pointers (the JNIEnv's and the JavaVM's tables)
@:hxmc.c @:hxmc.fast private extern class Ind {
	@:hxmc.indirect static function p1(f:Ptr, a:Ptr):Ptr;
	@:hxmc.indirect static function p2(f:Ptr, a:Ptr, b:Ptr):Ptr;
	@:hxmc.indirect static function p3(f:Ptr, a:Ptr, b:Ptr, c:Ptr):Ptr;
	@:hxmc.indirect static function p4(f:Ptr, a:Ptr, b:Ptr, c:Ptr, d:Ptr):Ptr;
	@:hxmc.indirect static function p5(f:Ptr, a:Ptr, b:Ptr, c:Ptr, d:Ptr, e:Ptr):Ptr;
	@:hxmc.indirect static function f3(f:Ptr, a:Ptr, b:Ptr, c:Ptr):Float32;
	@:hxmc.indirect static function f4(f:Ptr, a:Ptr, b:Ptr, c:Ptr, d:Ptr):Float32;
	@:hxmc.indirect static function d3(f:Ptr, a:Ptr, b:Ptr, c:Ptr):Float;
	@:hxmc.indirect static function d4(f:Ptr, a:Ptr, b:Ptr, c:Ptr, d:Ptr):Float;
	@:hxmc.indirect static function vf(f:Ptr, a:Ptr, b:Ptr, c:Ptr, v:Float32):Void;
	@:hxmc.indirect static function vd(f:Ptr, a:Ptr, b:Ptr, c:Ptr, v:Float):Void;
}

@:hxmc.c @:hxmc.fast private extern class P {
	static function pthread_key_create(key:Ptr, destructor:Ptr):Int;
	static function pthread_setspecific(key:I64, v:Ptr):Int;
	static function pthread_create(t:Ptr, attr:Ptr, fn:Ptr, arg:Ptr):Int;
	static function pthread_join(t:I64, ret:Ptr):Int;
	// the program's main (DataGen), C's convention
	static function main(argc:Int, argv:Ptr):Int;
}
