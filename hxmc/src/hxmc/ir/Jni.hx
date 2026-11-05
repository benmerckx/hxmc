package hxmc.ir;

import core.TType;
import hxmc.ir.CInterop;
import hxmc.ir.Lower.LowerError;
import hxmc.ir.Ir;
import haxe.ds.Vector;
import core.ds.VectorTools.vector;

using core.TFunctions;

// Java interop through JNI (docs/interop.md, "Java (JNI)"; docs/plans/jni.md):
// an extern class or interface declared @:hxmc.java("pkg.Class") is a Java
// class. Its values are Haxe references: a Java object's box (hxmc.rt.JniKind:
// one per object, holding a global reference) or a Haxe object implementing
// the interface (its proxy, a Java object of the glue's, made at its first
// use as a Java value).
//
// A call (FnLower.jniCall) enters (the thread's JNIEnv, a local frame
// pushed), resolves the class and the member once into their cells (data
// words named by what they hold: DataGen.jniCells), makes the arguments Java
// values in a jvalue array (numbers stored as their C types; references as
// local references, rt_jni_arg), calls the Call<Type>MethodA, NewObjectA or
// field function of the member's JNI signature (made here from the Haxe
// types, or @:hxmc.java.signature's), makes the result a Haxe value
// (rt_jni_result) and leaves (the frame popped; a pending Java exception
// thrown as a hxmc.java.JavaException).
//
// A Haxe class implementing Java interfaces (Lower.jniSide) gets a native
// method per interface method (a C entry, Com.entry, over a work function,
// FnLower.jniThunkBody) and a descriptor function (FnLower.jniDescBody) that
// its constructors call once per type: the proxy class's name and its
// natives, which the runtime registers (RegisterNatives) when it makes the
// first proxy. The proxy class itself is the glue's (helder.pack generates
// it from the manifest, Jni.manifest, written next to the output).
@:access(hxmc.ir.Lower)
class Jni {
	// the hidden field of a Haxe object holding its peer record (0: none yet)
	public static inline var FIELD = Lower.HIDDEN_FIELD + "jni";
	// the prefix of a class's descriptor function and of its natives' C entries
	public static inline var DESC = "hxmc_jni_desc_";
	public static inline var THUNK = "hxmc_jni_";
	// a cell's symbol: what it caches, in hexadecimal (DataGen.jniCells: a word, zero until resolved)
	public static inline var CELL = "hxmc$jni$";
	// the proxy classes' package, unless @:hxmc.java.proxy names the class
	public static inline var PROXY_PACKAGE = "org.hxmc.proxy.";

	// the type codes (hxmc.rt.JniKind.T_*: Call<Type>MethodA's order)
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
	public static inline var STATIC = 16;
	public static inline var NEW = 32;
	// what a reference converts (hxmc.rt.JniKind.R_*)
	public static inline var R_OBJECT = 0;
	public static inline var R_STRING = 1;
	public static inline var R_DYNAMIC = 2;
	public static inline var R_INTEGER = 3;
	public static inline var R_DOUBLE = 4;
	public static inline var R_BOOLEAN = 5;
	public static inline var R_BYTES = 6;
	public static inline var R_PRIMS = 16;
	public static inline var R_STRINGS = 32;
	public static inline var R_OBJECTS = 33;
	public static inline var R_DYNAMICS = 34;
	public static inline var M_METHOD = 0;
	public static inline var M_STATIC_METHOD = 1;
	public static inline var M_FIELD = 2;
	public static inline var M_STATIC_FIELD = 3;

	// whether JNI is there on the target: Linux (and Android), macOS; elsewhere
	// every Java operation throws (rt_jni_unavailable), as COM's do off Windows
	public static function available():Bool
		return Lower.targetOs == 0 || Lower.targetOs == 1;

	// a Java class or interface: an extern declared @:hxmc.java("pkg.Class")
	public static function isJava(c:TClass):Bool
		return c.hasClassFlag(CExtern) && Lower.hasMeta(":hxmc.java", c.clMeta);

	public static function javaOf(t:T):Null<TClass>
		return switch TFunctions.follow(t) {
			case TInst(c, _) if (isJava(c)): c;
			case _: null;
		}

	// the class's JNI name: java/lang/String (nested classes: java/util/Map$Entry)
	public static function className(c:TClass):String {
		var s = Lower.metaString(":hxmc.java", c.clMeta);
		if (s == null || s == "")
			throw new LowerError('Java class ${c.clPath.name} has no name: declare it @:hxmc.java("pkg.Class")', CInterop.posOf(c.clPos));
		return StringTools.replace(s, ".", "/");
	}

	// a member's Java name: @:hxmc.java.name or @:native, else its own
	public static function memberName(cf:TClassField):String {
		var n = Lower.metaString(":hxmc.java.name", cf.cfMeta);
		if (n == null) n = Lower.metaString(":native", cf.cfMeta);
		return n != null ? n : cf.cfName;
	}

	static function isPath(t:T, pack:String, name:String):Bool
		return switch t {
			case TInst(c, _): c.clPath.name == name && c.clPath.pack.join(".") == pack;
			case TAbstract(a, _): a.aPath.name == name && a.aPath.pack.join(".") == pack;
			case _: false;
		}

	// how a Haxe type crosses to Java: a primitive (its type code, its C type
	// in a jvalue), a reference (what converts it, and an object array's
	// element class), nothing (Void), or no Java type
	public static function value(t:T):JniValue {
		var f = TFunctions.followWithoutNull(t);
		switch f {
			case TAbstract(a, [p]) if (a.aPath.name == "Null" && a.aPath.pack.length == 0):
				return switch value(p) {
					case JPrim(T_INT, _): JRef(R_INTEGER, null, "Ljava/lang/Integer;");
					case JPrim(T_DOUBLE, _): JRef(R_DOUBLE, null, "Ljava/lang/Double;");
					case JPrim(T_BOOLEAN, _): JRef(R_BOOLEAN, null, "Ljava/lang/Boolean;");
					case JPrim(_, _): JNone("Null<" + core.TPrinting.sTypes(vector(p)) + ">: only Null<Int>, Null<Float> and Null<Bool> are boxed (Integer, Double, Boolean)");
					case v: v;
				}
			case TAbstract(a, _) if (a.aPath.name == "Void" && a.aPath.pack.length == 0):
				return JVoid;
			case TInst(c, _) if (isJava(c)):
				return JRef(R_OBJECT, null, "L" + className(c) + ";");
			case TInst(c, _) if (c.clPath.name == "String" && c.clPath.pack.length == 0):
				return JRef(R_STRING, null, "Ljava/lang/String;");
			case TInst(c, _) if (c.clPath.name == "Bytes" && c.clPath.pack.join(".") == "haxe.io"):
				return JRef(R_BYTES, null, "[B");
			case TInst(c, [e]) if (c.clPath.name == "Array" && c.clPath.pack.length == 0):
				return switch value(e) {
					case JPrim(code, _): JRef(R_PRIMS + code, null, "[" + primDesc(code));
					case JRef(R_STRING, _, d): JRef(R_STRINGS, null, "[" + d);
					case JRef(R_OBJECT, _, d) if (StringTools.startsWith(d, "L")): JRef(R_OBJECTS, d.substr(1, d.length - 2), "[" + d);
					case JRef(R_DYNAMIC, _, d): JRef(R_DYNAMICS, null, "[" + d);
					case _: JNone("Array<" + core.TPrinting.sTypes(vector(e)) + ">: arrays of numbers, Bools, Strings, Java objects and Dynamic cross to Java");
				}
			case TAbstract(a, [e]) if (a.aPath.name == "JavaArray" && a.aPath.pack.join(".") == "hxmc.java"):
				return switch value(e) {
					case JPrim(code, _): JRef(R_OBJECT, null, "[" + primDesc(code));
					case JRef(R_OBJECT | R_STRING | R_DYNAMIC | R_INTEGER | R_DOUBLE | R_BOOLEAN, _, d): JRef(R_OBJECT, null, "[" + d);
					case JRef(_, _, d): JRef(R_OBJECT, null, "[" + d);
					case _: JNone("JavaArray<" + core.TPrinting.sTypes(vector(e)) + ">: no Java element type");
				}
			case TDynamic(_):
				return JRef(R_DYNAMIC, null, "Ljava/lang/Object;");
			case TAbstract(a, _) if (a.aPath.name == "Any" && a.aPath.pack.length == 0):
				return JRef(R_DYNAMIC, null, "Ljava/lang/Object;");
			case _:
		}
		return switch CInterop.ctype(t) {
			case CI32: JPrim(T_INT, CI32);
			case CBool: JPrim(T_BOOLEAN, CBool);
			case CF64: JPrim(T_DOUBLE, CF64);
			case CF32: JPrim(T_FLOAT, CF32);
			case CI8: JPrim(T_BYTE, CI8);
			case CU8: JPrim(T_BYTE, CU8);
			case CI16: JPrim(T_SHORT, CI16);
			case CU16: JPrim(T_CHAR, CU16);
			case CI64: JPrim(T_LONG, CI64);
			case CVoid: JVoid;
			case _: JNone(core.TPrinting.sTypes(vector(t)) + " has no Java type (numbers, Bool, String, Bytes, Arrays, Java classes, Dynamic)");
		}
	}

	public static function primDesc(code:Int):String
		return "LZBCSIJFDV".charAt(code);

	public static function descriptor(v:JniValue):String
		return switch v {
			case JPrim(code, _): primDesc(code);
			case JRef(_, _, d): d;
			case JVoid: "V";
			case JNone(_): "?";
		}

	// the Java type of t, or the reason it has none
	public static function check(v:JniValue, what:String, where:String):JniValue
		return switch v {
			case JNone(why): throw new LowerError(what + ": " + why, where);
			case _: v;
		}

	// the JNI signature of method cf (s its type; a constructor's result is
	// Void): @:hxmc.java.signature's, else made from the Haxe types
	public static function signature(cf:TClassField, s:TSignature, ctor:Bool):String {
		var given = Lower.metaString(":hxmc.java.signature", cf.cfMeta);
		if (given != null) return given;
		var where = CInterop.posOf(cf.cfPos);
		var b = new StringBuf();
		b.add("(");
		for (a in s.args)
			b.add(descriptor(check(value(a.type), 'Java method ${cf.cfName}: the parameter ${a.name}', where)));
		b.add(")");
		b.add(ctor ? "V" : descriptor(check(value(s.ret), 'Java method ${cf.cfName}: the result', where)));
		return b.toString();
	}

	// a cell's symbol: the class's (its global reference) or a member's (its ID)
	public static function classCell(cls:String):String
		return CELL + haxe.io.Bytes.ofString("c " + cls).toHex();

	public static function memberCell(cls:String, name:String, sig:String, what:Int):String
		return CELL + haxe.io.Bytes.ofString(what + " " + cls + " " + name + " " + sig).toHex();

	// the constructor of Java class c a `new` with these arguments calls: of
	// c's constructor and its @:overload's, the one whose parameters take the
	// arguments' types (a constructor's call does not name its overload)
	public static function ctorFor(c:TClass, cargs:Vector<TExpr>):Null<TClassField> {
		var ctor = c.clConstructor;
		if (ctor == null) return null;
		var all = [ctor].concat([for (o in ctor.cfOverloads) o]);
		var best = null;
		for (cf in all) {
			var s = switch TFunctions.follow(cf.cfType) {
				case TFun(s): s;
				case _: continue;
			};
			if (s.args.length < cargs.length) continue;
			var ok = true;
			for (i in 0...s.args.length)
				if (i >= cargs.length) {
					if (!s.args[i].optional) ok = false;
				} else if (!accepts(s.args[i].type, cargs[i].etype)) ok = false;
			if (ok && best == null) best = cf;
		}
		return best != null ? best : all.length == 1 ? ctor : null;
	}

	static function accepts(param:T, arg:T):Bool {
		var p = value(param), a = value(arg);
		return switch [p, a] {
			case [JPrim(x, _), JPrim(y, _)]: x == y || (x == T_DOUBLE && y == T_INT) || (x == T_LONG && y == T_INT);
			case [JRef(R_DYNAMIC, _, _), _]: true;
			case [JRef(_, _, x), JRef(_, _, y)]: x == y || (StringTools.startsWith(x, "L") && StringTools.startsWith(y, "L"));
			case [JRef(_, _, _), JNone(_)]: true; // (null, a Haxe object implementing the interface)
			case _: false;
		}
	}

	// ---- Haxe classes implementing Java interfaces

	// the Java interfaces c implements (its superclasses' too), and theirs
	public static function implemented(c:TClass):Array<TClass> {
		var all:Array<TClass> = [];
		function add(i:TClass) {
			if (isJava(i) && i.hasClassFlag(CInterface)) {
				if (!all.contains(i)) all.push(i);
			}
			for (j in i.clImplements)
				add(j.cls);
		}
		var k = c;
		while (k != null) {
			for (i in k.clImplements)
				add(i.cls);
			k = k.clSuper != null ? k.clSuper.cls : null;
		}
		return all;
	}

	// whether c implements a Java interface its superclasses do not
	public static function addsInterfaces(c:TClass):Bool {
		var sup = c.clSuper != null ? implemented(c.clSuper.cls) : [];
		for (i in implemented(c))
			if (!sup.contains(i)) return true;
		return false;
	}

	// the proxy class of a Haxe class: @:hxmc.java.proxy("pkg.Name"), else org.hxmc.proxy.<its path>
	public static function proxyName(c:TClass):String {
		var n = Lower.metaString(":hxmc.java.proxy", c.clMeta);
		return n != null ? n : PROXY_PACKAGE + core.Globals.sTypePath(c.clPath);
	}

	// the methods of interfaces is a proxy implements, each once (by its
	// Java name and signature), in declaration order
	public static function methods(is:Array<TClass>):Array<{iface:TClass, cf:TClassField, s:TSignature, name:String, sig:String}> {
		var r = [];
		var seen = new Map<String, Bool>();
		for (i in is)
			for (cf in i.clOrderedFields) {
				if (!cf.cfKind.match(Method(_))) continue;
				var s = switch TFunctions.follow(cf.cfType) {
					case TFun(s): s;
					case _: continue;
				};
				var name = memberName(cf), sig = signature(cf, s, false);
				if (seen.exists(name + sig)) continue;
				seen.set(name + sig, true);
				r.push({iface: i, cf: cf, s: s, name: name, sig: sig});
			}
		return r;
	}

	// a native method's JNI signature: the handle (long) first
	public static function nativeSig(sig:String):String
		return "(J" + sig.substr(1);

	// the C type of a value in a native method's C signature
	public static function ctypeOf(v:JniValue):CTy
		return switch v {
			case JPrim(_, ct): ct;
			case JVoid: CVoid;
			case _: CPtr;
		}

	// ---- the manifest (docs/plans/jni.md, "The glue"): the proxies the
	// program's live classes need, for the packager that writes their Java

	public static function manifest(classes:Array<ClassInfo>):Null<String> {
		var list = [for (ci in classes) if (ci.jniProxy != null) ci.jniProxy];
		if (list.length == 0) return null;
		list.sort((a, b) -> a.proxy < b.proxy ? -1 : a.proxy > b.proxy ? 1 : 0);
		var b = new StringBuf();
		b.add('{\n  "version": 1,\n  "peer": "org.hxmc.Peer",\n  "exception": "org.hxmc.HaxeException",\n  "proxies": [');
		for (i in 0...list.length) {
			var p = list[i];
			b.add(i == 0 ? "\n" : ",\n");
			b.add('    {\n      "class": ${str(p.proxy)},\n      "haxe": ${str(p.haxe)},\n      "interfaces": [${[for (x in p.interfaces) str(x)].join(", ")}],\n      "methods": [');
			for (j in 0...p.methods.length) {
				var m = p.methods[j];
				b.add(j == 0 ? "\n" : ",\n");
				b.add('        {"name": ${str(m.name)}, "signature": ${str(m.sig)}, "native": ${str(m.native)}, "nativeSignature": ${str(nativeSig(m.sig))}}');
			}
			b.add("\n      ]\n    }");
		}
		b.add("\n  ]\n}\n");
		return b.toString();
	}

	static function str(s:String):String
		return haxe.Json.stringify(s);
}

// how a Haxe type crosses to Java
enum JniValue {
	JPrim(code:Int, ct:CTy); // a primitive: its type code, its C type in a jvalue
	JRef(how:Int, cls:Null<String>, desc:String); // a reference: its conversion (JniKind.R_*), an object array's element class, its descriptor
	JVoid;
	JNone(why:String);
}
