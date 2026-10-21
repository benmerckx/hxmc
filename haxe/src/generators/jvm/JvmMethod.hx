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

package generators.jvm;

import haxe.io.Bytes;
import core.ds.OcamlHashtbl;
import generators.jvm.JvmGlobals;
import generators.jvm.JvmData;
import generators.jvm.JvmAttribute;
import generators.jvm.JvmSignature;
import generators.jvm.JvmSignature.NativeSignatures.*;
import generators.jvm.JvmBuilder;
import generators.jvm.JvmCode;
import generators.jvm.JvmClass;
import generators.jvm.JvmVerificationTypeInfo;
import haxe.ds.Vector;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

/* High-level method builder. */
enum VarInitState {
	VarArgument;
	VarWillInit;
	VarNeedDefault;
}

enum ConstructionKind {
	ConstructInitPlusNew;
	ConstructInit;
}

enum LabelState {
	LabelSet(fp:JBranchOffset);
	LabelNotSet(l:Array<JBranchOffsetRef>);
}

// port: `int * (unit -> unit) * (unit -> unit)`: slot, load and store of a local.
@:structInit class LocalRef {
	public final slot:Int;
	public final load:Void->Void;
	public final store:Void->Void;
}

// port: a local of a frame: `(int option ref * string * jsignature)`.
@:structInit class FrameLocal {
	public final init:{v:Null<Int>};
	public final name:String;
	public final jsig:JSignature;
}

@:structInit class StackFrame {
	public final offset:Int;
	public final locals:Array<VerificationTypeInfo>;
	public final stack:Array<VerificationTypeInfo>;
}

class JvmMethod {
	public static function pow(a:Int, b:Int):Int return switch b {
		case 0: 1;
		case 1: a;
		case _: OcamlMath.mul32(a, pow(a, b - 1));
	}

	// port: extlib's UTF8.validate on the UTF-8 bytes of the string.
	static function validateUtf8(b:Bytes):Bool {
		var len = b.length;
		function trail(c:Int, i:Int, a:Int):Int {
			while (c > 0) {
				if (i >= len) return -1;
				var n = b.get(i);
				if (n < 0x80 || n >= 0xc0) return -1;
				a = (a << 6) | (n - 0x80);
				c--;
				i++;
			}
			return a;
		}
		var i = 0;
		while (i < len) {
			var n = b.get(i);
			if (n < 0x80) i += 1 else if (n < 0xc2) return false else if (n <= 0xdf) {
				var t = trail(1, i + 1, n - 0xc0);
				if (t < 0x80) return false;
				i += 2;
			} else if (n <= 0xef) {
				var t = trail(2, i + 1, n - 0xe0);
				if (t < 0x800) return false;
				i += 3;
			} else if (n <= 0xf7) {
				var t = trail(3, i + 1, n - 0xf0);
				if (t < 0x10000) return false;
				i += 4;
			} else if (n <= 0xfb) {
				var t = trail(4, i + 1, n - 0xf8);
				if (t < 0x200000) return false;
				i += 5;
			} else if (n <= 0xfd) {
				var t = trail(5, i + 1, n - 0xfc);
				if (t < 0 || (t >>> 16) < 0x400) return false;
				i += 6;
			} else return false;
		}
		return true;
	}

	// port: extlib's UTF8.iter (UTF8.look) on valid UTF-8 bytes.
	static function decodeUtf8(b:Bytes):Array<Int> {
		var codes = [];
		var i = 0;
		var len = b.length;
		while (i < len) {
			var n = b.get(i);
			if (n < 0x80) {
				codes.push(n);
				i += 1;
			} else if (n <= 0xdf) {
				codes.push(((n - 0xc0) << 6) | (0x7f & b.get(i + 1)));
				i += 2;
			} else if (n <= 0xef) {
				codes.push(((((n - 0xe0) << 6) | (0x7f & b.get(i + 1))) << 6) | (0x7f & b.get(i + 2)));
				i += 3;
			} else {
				codes.push(((((((n - 0xf0) << 6) | (0x7f & b.get(i + 1))) << 6) | (0x7f & b.get(i + 2))) << 6) | (0x7f & b.get(i + 3)));
				i += 4;
			}
		}
		return codes;
	}

	public static function javaHash(s:String):Int {
		inline function highSurrogate(c:Int):Int return (c >>> 10) + 0xD7C0;
		inline function lowSurrogate(c:Int):Int return (c & 0x3FF) | 0xDC00;
		var h = 0;
		var thirtyone = 31;
		var b = Bytes.ofString(s);
		if (validateUtf8(b)) {
			for (c in decodeUtf8(b)) {
				if (c > 0xFFFF) {
					h = (OcamlMath.mul32(thirtyone, h) + highSurrogate(c)) | 0;
					h = (OcamlMath.mul32(thirtyone, h) + lowSurrogate(c)) | 0;
				} else
					h = (OcamlMath.mul32(thirtyone, h) + c) | 0;
			}
		} else {
			for (i in 0...b.length) h = (OcamlMath.mul32(thirtyone, h) + b.get(i)) | 0;
		}
		return h;
	}
}

// port: 32-bit wrapping multiplication (Int32.mul).
class OcamlMath {
	public static inline function mul32(a:Int, b:Int):Int return ((a & 0xFFFF) * b + ((((a >>> 16) * b) & 0xFFFF) << 16)) | 0;
}

class HashtblList<V> {
	// port: `values` is a Hashtbl only used through mem and find_all; `keys` is
	// prepended to, as upstream's list.
	final values:haxe.ds.IntMap<Array<V>> = new haxe.ds.IntMap();
	var keys:Array<Int> = [];

	public function new() {}

	public function add(key:Int, value:V):Void {
		var l = values.get(key);
		if (l == null) {
			keys.unshift(key);
			l = [];
			values.set(key, l);
		}
		l.unshift(value);
	}

	public function asList():Array<{key:Int, values:Array<V>}> {
		return keys.map(function(key) return {key: key, values: values.get(key).copy()});
	}
}

class NativeArray {
	public static function read(code:JvmCodeBuilder, ja:JSignature, je:JSignature):Void {
		switch je {
			case JBool: code.baload(JBool, ja);
			case JByte: code.baload(JByte, ja);
			case JChar: code.caload(ja);
			case JDouble: code.daload(ja);
			case JFloat: code.faload(ja);
			case JInt: code.iaload(ja);
			case JLong: code.laload(ja);
			case JShort: code.saload(ja);
			case _: code.aaload(ja, je);
		}
	}

	public static function write(code:JvmCodeBuilder, ja:JSignature, je:JSignature):Void {
		switch je {
			case JBool: code.bastore(JBool, ja);
			case JByte: code.bastore(JByte, ja);
			case JChar: code.castore(ja);
			case JDouble: code.dastore(ja);
			case JFloat: code.fastore(ja);
			case JInt: code.iastore(ja);
			case JLong: code.lastore(ja);
			case JShort: code.sastore(ja);
			case _: code.aastore(ja, je);
		}
	}

	public static function create(code:JvmCodeBuilder, pool:JvmConstantPool, je:JSignature):JSignature {
		var ja = JArray(je, null);
		function primitive(i:Int) code.newarray(ja, i);
		function reference(path:JPath) {
			var offset = pool.addPath(path);
			code.anewarray(ja, offset);
		}
		switch je {
			case JBool: primitive(4);
			case JChar: primitive(5);
			case JFloat: primitive(6);
			case JDouble: primitive(7);
			case JByte: primitive(8);
			case JShort: primitive(9);
			case JInt: primitive(10);
			case JLong: primitive(11);
			case JObject(path, _): reference(path);
			case JMethod(_): reference(NativeSignatures.haxeFunctionPath);
			case JTypeParameter(_): reference(NativeSignatures.objectPath);
			case JArray(_):
				var offset = pool.addType(JvmSignature.generateSignature(false, je));
				code.anewarray(ja, offset);
			case JObjectInner(_) | JUninitialized(_): core.Globals.die("", "generators/jvm/jvmMethod.ml");
		}
		return ja;
	}
}

class JvmMethodBuilder extends BaseBuilder {
	final jc:JvmClassBuilder;
	final name:String;
	final jsig:JSignature;
	final code:JvmCodeBuilder;

	final descriptor:String;
	var maxNumLocals = 0;
	// port: OCaml lists built by prepending; index 0 is the head.
	var debugLocals:Array<{fp:Int, length:Int, name:String, jsig:JSignature, index:Int}> = [];
	var stackFrames:Array<StackFrame> = [];
	var exceptions:Array<JvmException> = [];
	var argumentLocals:Array<FrameLocal> = [];
	var runtimeVisibleArgumentAnnotations:haxe.ds.IntMap<Array<{jsig:JSignature, a:Annotation}>> = new haxe.ds.IntMap();
	var runtimeInvisibleArgumentAnnotations:haxe.ds.IntMap<Array<{jsig:JSignature, a:Annotation}>> = new haxe.ds.IntMap();
	var thrownExceptions:OcamlHashtbl<Int, Bool> = new OcamlHashtbl(OcamlHashtbl.hashInt, function(a:Int, b:Int) return a == b);
	var regexCount = 0;

	/* per-frame */
	var locals:Array<FrameLocal> = [];
	var localOffset = 0;

	public function new(jc:JvmClassBuilder, name:String, jsig:JSignature) {
		super();
		this.jc = jc;
		this.name = name;
		this.jsig = jsig;
		code = new JvmCodeBuilder(jc.getPool());
		descriptor = JvmSignature.generateMethodSignature(false, jsig);
	}

	public function hasMethodFlag(flag:MethodAccessFlags):Bool return MethodAccessFlagsTools.hasFlag(accessFlags, flag);

	/** Pushes a new scope onto the stack. Returns a function which when called reverts to the previous state. **/
	public function pushScope():Void->Void {
		var oldLocals = locals;
		var oldOffset = localOffset;
		return function() {
			var delta = localOffset - oldOffset;
			var fpEnd = code.getFp();
			function loop(i:Int, l:Array<FrameLocal>, idx:Int):Void {
				if (i == 0) {} else {
					if (idx >= l.length) core.Globals.die("", "generators/jvm/jvmMethod.ml");
					var e = l[idx];
					var fp = switch e.init.v {
						case null: throw new core.ds.Failure("Uninitialized local " + e.name);
						case fp: fp;
					}
					var t = switch e.jsig {
						case JUninitialized(null): JObject(jc.getThisPath(), []);
						case t: t;
					}
					var ld = {
						fp: fp,
						length: fpEnd - fp,
						name: e.name,
						jsig: t,
						index: oldOffset + i - JvmSignature.signatureSize(t)
					};
					debugLocals.unshift(ld);
					loop(i - JvmSignature.signatureSize(t), l, idx + 1);
				}
			}
			loop(delta, locals, 0);
			locals = oldLocals;
			localOffset = oldOffset;
		};
	}

	function getLocalsForStackFrame(locals:Array<FrameLocal>):Array<VerificationTypeInfo> {
		return locals.map(function(l) return switch l.init.v {
			case null: VTop;
			case _: JvmVerificationTypeInfo.ofSignature(jc.getPool(), l.jsig);
		});
	}

	public function getNextRegexId():Int {
		var id = regexCount;
		regexCount = regexCount + 1;
		return id;
	}

	/** Adds the current state of locals and stack as a stack frame. This has to be called on every branch target. **/
	public function addStackFrame():Void {
		var locals = getLocalsForStackFrame(locals);
		var astack = code.getStack().getStack().map(JvmVerificationTypeInfo.ofSignature.bind(jc.getPool()));
		var r = code.getFp();
		var ff:StackFrame = {offset: r, locals: locals, stack: astack};
		/* If we already have a frame at the same position, overwrite it. This can happen in the case of nested branches. */
		if (stackFrames.length > 0 && stackFrames[0].offset == r) stackFrames = [ff].concat(stackFrames.slice(1)) else
			stackFrames = [ff].concat(stackFrames);
	}

	/** Adds [exc] as an exception. This will be added to the Code attribute. **/
	public function addException(exc:JvmException):Void {
		exceptions.unshift(exc);
	}

	/** Adds [path] as a thrown exception for this method. Deals with duplicates. **/
	public function addThrownException(path:JPath):Void {
		thrownExceptions.replace(jc.getPool().addPath(path), true);
	}

	/* Convenience */
	/** Adds [s] as a string constant to the constant pool and emits an instruction to load it. **/
	public function string(s:String):Void {
		var offset = jc.getPool().addConstString(s);
		code.sconst(stringSig, offset);
	}

	/** Emits an invokevirtual instruction to invoke method [name] on [path] with signature [jsigm]. **/
	public function invokevirtual(path:JPath, name:String, jsigm:JSignature):Void {
		switch jsigm {
			case JMethod(tl, tr):
				var offset = code.getPool().addField(path, name, jsigm, FKMethod);
				code.invokevirtual(offset, objectPathSig(path), tl, tr == null ? [] : [tr]);
			case _:
				core.Globals.die("", "generators/jvm/jvmMethod.ml");
		}
	}

	/** Emits an invokeinterface instruction to invoke method [name] on [path] with signature [jsigm]. **/
	public function invokeinterface(path:JPath, name:String, jsigm:JSignature):Void {
		switch jsigm {
			case JMethod(tl, tr):
				var offset = code.getPool().addField(path, name, jsigm, FKInterfaceMethod);
				code.invokeinterface(offset, objectPathSig(path), tl, tr == null ? [] : [tr]);
			case _:
				core.Globals.die("", "generators/jvm/jvmMethod.ml");
		}
	}

	/** Emits an invokespecial instruction to invoke method [name] on [path] with signature [jsigm]. **/
	public function invokespecial(path:JPath, name:String, jsigm:JSignature):Void {
		switch jsigm {
			case JMethod(tl, tr):
				var offset = code.getPool().addField(path, name, jsigm, FKMethod);
				code.invokespecial(offset, objectPathSig(path), tl, tr == null ? [] : [tr]);
			case _:
				core.Globals.die("", "generators/jvm/jvmMethod.ml");
		}
	}

	/** Emits an invokestatic instruction to invoke method [name] on [path] with signature [jsigm]. **/
	public function invokestatic(path:JPath, name:String, ?kind:FieldKind, jsigm:JSignature):Void {
		if (kind == null) kind = FKMethod;
		switch jsigm {
			case JMethod(tl, tr):
				var offset = code.getPool().addField(path, name, jsigm, kind);
				code.invokestatic(offset, tl, tr == null ? [] : [tr]);
			case _:
				core.Globals.die("", "generators/jvm/jvmMethod.ml");
		}
	}

	/** Emits a getfield instruction to get the value of field [name] on object [path] with signature [jsigf]. **/
	public function getfield(path:JPath, name:String, jsigf:JSignature):Void {
		var offset = code.getPool().addField(path, name, jsigf, FKField);
		code.getfield(offset, objectPathSig(path), jsigf);
	}

	/** Emits a putfield instruction to set the value of field [name] on object [path] with signature [jsigf]. **/
	public function putfield(path:JPath, name:String, jsigf:JSignature):Void {
		var offset = code.getPool().addField(path, name, jsigf, FKField);
		code.putfield(offset, objectPathSig(path), jsigf);
	}

	/** Emits a getstatic instruction to get the value of field [name] on Class [path] with signature [jsigf]. **/
	public function getstatic(path:JPath, name:String, jsigf:JSignature):Void {
		var offset = code.getPool().addField(path, name, jsigf, FKField);
		code.getstatic(offset, jsigf);
	}

	/** Emits a putstatic instruction to set the value of field [name] on Class [path] with signature [jsigf]. **/
	public function putstatic(path:JPath, name:String, jsigf:JSignature):Void {
		var offset = code.getPool().addField(path, name, jsigf, FKField);
		code.putstatic(offset, jsigf);
	}

	public function getBasicTypeClass(name:String):Void {
		getstatic({pack: ["java", "lang"], name: name}, "TYPE", javaClassSig);
	}

	public function getClass(jsig:JSignature):Void {
		switch jsig {
			case JByte: getBasicTypeClass("Byte");
			case JChar: getBasicTypeClass("Character");
			case JDouble: getBasicTypeClass("Double");
			case JFloat: getBasicTypeClass("Float");
			case JInt: getBasicTypeClass("Integer");
			case JLong: getBasicTypeClass("Long");
			case JShort: getBasicTypeClass("Short");
			case JBool: getBasicTypeClass("Boolean");
			case JObject(path, _):
				var offset = code.getPool().addPath(path);
				var t = objectPathSig(path);
				code.ldc(offset, JObject(javaClassPath, [JTType(WNone, t)]));
			case JTypeParameter(_):
				var offset = code.getPool().addPath(objectPath);
				code.ldc(offset, JObject(javaClassPath, [JTType(WNone, objectSig)]));
			case JArray(_):
				var t = jsig;
				/* TODO: this seems hacky */
				var offset = code.getPool().addPath({pack: [], name: JvmSignature.generateSignature(false, t)});
				code.ldc(offset, JObject(javaClassPath, [JTType(WNone, objectSig)]));
			case JMethod(_):
				var offset = code.getPool().addPath(haxeFunctionPath);
				code.ldc(offset, JObject(javaClassPath, [JTType(WNone, objectSig)]));
			case jsig:
				Sys.println(JvmSignature.generateSignature(false, jsig));
				core.Globals.die("", "generators/jvm/jvmMethod.ml");
		}
	}

	/** Loads `this` **/
	public function loadThis():Void {
		code.aload(getThisSig(), 0);
	}

	/** Calls the parent constructor with signature [jsig_method] using the specified construction_kind [kind]. **/
	public function callSuperCtor(kind:ConstructionKind, jsigMethod:JSignature):Void {
		if (hasMethodFlag(MStatic)) throw new core.ds.Failure("assert");
		switch kind {
			case ConstructInitPlusNew:
				invokespecial(jc.getSuperPath(), "new", jsigMethod);
			case ConstructInit:
				invokespecial(jc.getSuperPath(), "<init>", jsigMethod);
				setThisInitialized();
		}
	}

	/** Adds a field named [name] with signature [jsig_field] to the enclosing class, and adds an argument with the same name
		to this method. The argument value is loaded and stored into the field immediately. **/
	public function addArgumentAndField(name:String, jsigField:JSignature, flags:Array<FieldAccessFlags>):Void {
		if (hasMethodFlag(MStatic)) throw new core.ds.Failure("assert");
		jc.spawnField(name, jsigField, flags);
		var load = addLocal(name, jsigField, VarArgument).load;
		loadThis();
		load();
		putfield(jc.getThisPath(), name, jsigField);
	}

	/** Constructs a [path] object using the specified construction_kind [kind].

		The function [f] is invokved to handle the call arguments. Its returned jsignature list is then used as the
		method type of the constructor to invoke.

		If [no_value] is true, this function ensures that the stack is neutral. Otherwise, the created object is pushed
		onto the stack.
	**/
	public function construct(?noValue:Bool = false, kind:ConstructionKind, path:JPath, f:Void->Array<JSignature>):Void {
		var pool = code.getPool();
		var offset = pool.addPath(path);
		code.new_(offset);
		switch kind {
			case ConstructInitPlusNew:
				code.dup();
				code.aconstNull(haxeEmptyConstructorSig);
				invokespecial(path, "<init>", methodSig([haxeEmptyConstructorSig], null));
				if (!noValue) replaceTop(objectPathSig(path));
				if (!noValue) code.dup();
				var jsigs = f();
				invokevirtual(path, "new", methodSig(jsigs, null));
			case ConstructInit:
				if (!noValue) code.dup();
				var jsigs = f();
				invokespecial(path, "<init>", methodSig(jsigs, null));
				if (!noValue) replaceTop(objectPathSig(path));
		}
	}

	/** Loads the default value corresponding to a given signature. **/
	public function loadDefaultValue(jsig:JSignature):Void {
		switch jsig {
			case JByte | JBool | JChar | JShort | JInt:
				code.iconst(0);
			case JFloat: code.fconst(0.);
			case JDouble: code.dconst(0.);
			case JLong: code.lconst(haxe.Int64.ofInt(0));
			case jsig: code.aconstNull(jsig);
		}
	}

	/** Constructs a new native array with element type [jsig].

		Iterates over [fl] and invokes the functions to handle the array elements.
	**/
	public function newNativeArray(jsig:JSignature, fl:Array<Void->Void>):Void {
		code.iconst(fl.length);
		var jasig = NativeArray.create(code, jc.getPool(), jsig);
		for (i in 0...fl.length) {
			var f = fl[i];
			code.dup();
			code.iconst(i);
			f();
			cast_(jsig);
			NativeArray.write(code, jasig, jsig);
		}
	}

	/**
		Emits a return instruction.
	**/
	public function return_():Void {
		switch jsig {
			case JMethod(_, tr):
				switch tr {
					case null:
						code.returnVoid();
					case jsig:
						code.returnValue(jsig);
				}
			case _:
				core.Globals.die("", "generators/jvm/jvmMethod.ml");
		}
	}

	/* casting */
	/** Checks if the stack top is a basic type and wraps accordingly. **/
	public function expectReferenceType():Void {
		function wrapNull(jsig:JSignature, name:String) {
			var path:JPath = {pack: ["java", "lang"], name: name};
			invokestatic(path, "valueOf", methodSig([jsig], objectPathSig(path)));
		}
		switch code.getStack().top() {
			case t = JByte: wrapNull(t, "Byte");
			case t = JChar: wrapNull(t, "Character");
			case t = JDouble: wrapNull(t, "Double");
			case t = JFloat: wrapNull(t, "Float");
			case t = JInt: wrapNull(t, "Integer");
			case t = JLong: wrapNull(t, "Long");
			case t = JShort: wrapNull(t, "Short");
			case t = JBool: wrapNull(t, "Boolean");
			case _:
		}
	}

	function expectBasicType(?notNull:Bool = false, jsig:JSignature):Void {
		if (notNull) {
			function unwrapNull(tname:String, name:String) {
				var path:JPath = {pack: ["java", "lang"], name: tname};
				cast_(getBoxedType(jsig));
				invokevirtual(path, name, methodSig([], jsig));
			}
			switch jsig {
				case JByte: unwrapNull("Number", "byteValue");
				case JChar: unwrapNull("Character", "charValue");
				case JDouble: unwrapNull("Number", "doubleValue");
				case JFloat: unwrapNull("Number", "floatValue");
				case JInt: unwrapNull("Number", "intValue");
				case JLong: unwrapNull("Number", "longValue");
				case JShort: unwrapNull("Number", "shortValue");
				case JBool: unwrapNull("Boolean", "booleanValue");
				case _:
			}
		} else {
			function unwrapNull(tname:String, name:String) {
				invokestatic({pack: ["haxe", "jvm"], name: "Jvm"}, name, methodSig([objectSig], jsig));
			}
			switch jsig {
				case JByte: unwrapNull("Byte", "toByte");
				case JChar: unwrapNull("Character", "toChar");
				case JDouble: unwrapNull("Double", "toDouble");
				case JFloat: unwrapNull("Float", "toFloat");
				case JInt: unwrapNull("Integer", "toInt");
				case JLong: unwrapNull("Long", "toLong");
				case JShort: unwrapNull("Short", "toShort");
				case JBool: unwrapNull("Boolean", "toBoolean");
				case _:
			}
		}
	}

	static function isJavaLangPath(path:JPath, name:String):Bool return path.pack.length == 2 && path.pack[0] == "java" && path.pack[1] == "lang"
		&& path.name == name;

	/** Casts the top of the stack to [jsig]. If [allow_to_string] is true, Jvm.toString is called. **/
	public function cast_(?notNull:Bool = false, ?allowToString:Bool = false, jsig:JSignature):Void {
		var jsig2 = code.getStack().top();
		function isNumberSig(except:String, s:JSignature):Bool return switch s {
			case JObject(path, _) if (path.pack.length == 2 && path.pack[0] == "java" && path.pack[1] == "lang"):
				switch path.name {
					case "Byte" | "Short" | "Integer" | "Long" | "Float" | "Double" if (path.name != except): true;
					case _: false;
				}
			case _:
				false;
		}
		function unboxedToByte():Void {
			switch code.getStack().top() {
				case JByte | JBool:
				case JChar | JShort | JInt:
					code.i2b(JByte);
				case JLong:
					code.l2i();
					unboxedToByte();
				case JFloat:
					code.f2i();
					unboxedToByte();
				case JDouble:
					code.d2i();
					unboxedToByte();
				case jsig:
					throw new core.ds.Failure(JvmSignature.sSignatureKind(jsig));
			}
		}
		function unboxedToShort():Void {
			switch code.getStack().top() {
				case JShort:
				case JBool | JByte | JChar | JInt:
					code.i2s();
				case JLong:
					code.l2i();
					unboxedToShort();
				case JFloat:
					code.f2i();
					unboxedToShort();
				case JDouble:
					code.d2i();
					unboxedToShort();
				case _:
					core.Globals.die("", "generators/jvm/jvmMethod.ml");
			}
		}
		function unboxedToInt():Void {
			switch code.getStack().top() {
				case JBool | JByte | JShort | JChar | JInt:
					replaceTop(JInt);
				case JLong:
					code.l2i();
				case JFloat:
					code.f2i();
				case JDouble:
					code.d2i();
				case _:
					core.Globals.die("", "generators/jvm/jvmMethod.ml");
			}
		}
		function unboxedToLong():Void {
			switch code.getStack().top() {
				case JBool | JByte | JShort | JChar | JInt:
					code.i2l();
				case JLong:
				case JFloat:
					code.f2l();
				case JDouble:
					code.d2l();
				case _:
					core.Globals.die("", "generators/jvm/jvmMethod.ml");
			}
		}
		function unboxedToFloat():Void {
			switch code.getStack().top() {
				case JBool | JByte | JShort | JChar | JInt:
					code.i2f();
				case JLong:
					code.l2f();
				case JFloat:
				case JDouble:
					code.d2f();
				case _:
					core.Globals.die("", "generators/jvm/jvmMethod.ml");
			}
		}
		function unboxedToDouble():Void {
			switch code.getStack().top() {
				case JBool | JByte | JShort | JChar | JInt:
					code.i2d();
				case JLong:
					code.l2d();
				case JFloat:
					code.f2d();
				case JDouble:
				case _:
					core.Globals.die("", "generators/jvm/jvmMethod.ml");
			}
		}
		function getConv(name:String):Void->Void return switch name {
			case "Byte": unboxedToByte;
			case "Short": unboxedToShort;
			case "Integer": unboxedToInt;
			case "Long": unboxedToLong;
			case "Float": unboxedToFloat;
			case "Double": unboxedToDouble;
			case _: core.Globals.die("", "generators/jvm/jvmMethod.ml");
		}
		function numberTo(name:String):Void {
			var boxedSig = JObject({pack: ["java", "lang"], name: name}, []);
			invokestatic({pack: ["haxe", "jvm"], name: "Jvm"}, "numberTo" + name, methodSig([numberSig], boxedSig));
		}
		function dynamicTo(name:String):Void {
			var boxedSig = JObject({pack: ["java", "lang"], name: name}, []);
			invokestatic({pack: ["haxe", "jvm"], name: "Jvm"}, "dynamicTo" + name, methodSig([objectSig], boxedSig));
		}
		function numericCastBoxed(name:String, jsig:JSignature):Void {
			if (isUnboxed(jsig)) {
				(getConv(name))();
				expectReferenceType();
			} else if (isNumberSig(name, jsig))
				numberTo(name)
			else if (isDynamicAtRuntime(jsig))
				dynamicTo(name)
			else
				code.checkcast({pack: ["java", "lang"], name: name});
		}
		function numericCastUnboxed(name:String, jsig:JSignature):Void {
			if (isUnboxed(jsig))
				(getConv(name))()
			else {
				var unboxedSig = getUnboxedType(JObject({pack: ["java", "lang"], name: name}, []));
				expectBasicType(unboxedSig);
				(getConv(name))();
			}
		}
		switch [jsig, jsig2] {
			case [JObject(p, _), jsig2] if (isJavaLangPath(p, "Byte")):
				numericCastBoxed("Byte", jsig2);
			case [JByte, jsig2]:
				numericCastUnboxed("Byte", jsig2);
			case [JObject(p, _), jsig2] if (isJavaLangPath(p, "Short")):
				numericCastBoxed("Short", jsig2);
			case [JShort, jsig2]:
				numericCastUnboxed("Short", jsig2);
			case [JObject(p, _), jsig2] if (isJavaLangPath(p, "Integer")):
				numericCastBoxed("Integer", jsig2);
			case [JInt, jsig2]:
				numericCastUnboxed("Integer", jsig2);
			case [JObject(p, _), jsig2] if (isJavaLangPath(p, "Long")):
				numericCastBoxed("Long", jsig2);
			case [JLong, jsig2]:
				numericCastUnboxed("Long", jsig2);
			case [JObject(p, _), jsig2] if (isJavaLangPath(p, "Float")):
				numericCastBoxed("Float", jsig2);
			case [JFloat, jsig2]:
				numericCastUnboxed("Float", jsig2);
			case [JObject(p, _), jsig2] if (isJavaLangPath(p, "Double")):
				numericCastBoxed("Double", jsig2);
			case [JDouble, jsig2]:
				numericCastUnboxed("Double", jsig2);
			case [JChar, JDouble]:
				code.d2i();
				code.i2c();
			case [JChar, JFloat]:
				code.f2i();
				code.i2c();
			case [JChar, (JByte | JShort | JInt)]:
				code.i2c();
			case [JChar, JLong]:
				code.l2i();
				code.i2c();
			case [JBool, JInt]:
				replaceTop(JBool);
			case [JObject(path1, _), JObject(path2, _)] if (JvmSignature.pathEq(path1, path2)):
			case [JObject(p, _), _] if (isJavaLangPath(p, "String") && allowToString):
				expectReferenceType();
				invokestatic({pack: ["haxe", "jvm"], name: "Jvm"}, "toString", methodSig([objectSig], stringSig));
			case [JObject(path1, _), t2]:
				if (isUnboxed(t2))
					expectReferenceType()
				else if (JvmSignature.pathEq(path1, objectPath)) {
					/* We should never need a checkcast to Object, but we should adjust the stack so stack maps are wide enough */
					replaceTop(objectSig);
				} else
					code.checkcast(path1);
			case [JMethod(_), JMethod(_)]:
			case [JMethod(_), _]:
				code.checkcast(NativeSignatures.haxeFunctionPath);
			case [JArray(jsig1, _), JArray(jsig2, _)] if (JvmSignature.jsigEq(jsig1, jsig2)):
			case [JArray(_), _]:
				code.checkcastSig(jsig);
			case [t1, t2]:
				switch [isUnboxed(t1), isUnboxed(t2)] {
					case [true, false]: expectBasicType(notNull, t1);
					case [false, true]: expectReferenceType();
					case _:
				}
		}
	}

	/* branches */
	/** Starts a branch. Returns a restore function which reverts the stack and termination status back
		to the previous state. The restore function can be called multiple times for multiple branches.

		This function has no effect on locals. Use [push_scope] for them.
	**/
	public function startBranch():Void->Void {
		var save = code.getStack().save();
		var oldTerminated = code.isTerminated();
		return function() {
			code.getStack().restore(save);
			code.setTerminated(oldTerminated);
		};
	}

	/** Generates code which executes [f_if()] and then branches into [f_then()] and [f_else()]. **/
	public function ifThenElse(fIf:JBranchOffsetRef->Void, fThen:Void->Void, fElse:Void->Void):Void {
		ifThenElseLabeled(function(labelThen, labelElse) {
			labelElse.apply(fIf);
		}, fThen, fElse);
	}

	public function ifThenElseLabeled(fIf:JvmLabel->JvmLabel->Void, fThen:Void->Void, fElse:Void->Void):Void {
		var labelThen = spawnLabel("then");
		var labelElse = spawnLabel("else");
		var labelExit = spawnLabel("exit");
		fIf(labelThen, labelElse);
		labelThen.here();
		var restore = startBranch();
		var pop = pushScope();
		fThen();
		pop();
		var termThen = isTerminated();
		if (!isTerminated()) labelExit.goto();
		restore();
		labelElse.here();
		fElse();
		if (termThen && isTerminated())
			setTerminated(true)
		else {
			setTerminated(false);
			labelExit.here();
		}
	}

	/** Generates code which executes [f_if()] and then branches into [f_then()], if the condition holds. **/
	public function ifThen(fIf:JBranchOffsetRef->Void, fThen:Void->Void):Void {
		ifThenLabeled(function(_, labelElse) labelElse.apply(fIf), fThen);
	}

	public function ifThenLabeled(fIf:JvmLabel->JvmLabel->Void, fThen:Void->Void):Void {
		var labelThen = spawnLabel("then");
		var labelElse = spawnLabel("else");
		fIf(labelThen, labelElse);
		labelThen.here();
		var restore = startBranch();
		var pop = pushScope();
		fThen();
		pop();
		restore();
		labelElse.here();
	}

	public function spawnLabel(name:String):JvmLabel {
		return new JvmLabel(this, name);
	}

	/**
		Returns an instruction offset and emits a goto instruction to it if this method isn't terminated.
	**/
	public function maybeMakeJump():JBranchOffsetRef {
		var r = new JBranchOffsetRef(code.getFp());
		if (!isTerminated()) code.goto(r);
		return r;
	}

	/**
		Closes the list of instruction offsets [rl], effectively making them jump to the current fp.

		Also generates a stack map frame unless [is_exhaustive] is true and all branches terminated.
	**/
	public function closeJumps(isExhaustive:Bool, rl:Array<{term:Bool, r:JBranchOffsetRef}>):Void {
		var fp2 = code.getFp();
		var term = true;
		for (e in rl) {
			e.r.v = fp2 - e.r.v;
			term = term && e.term;
		}
		var term = isExhaustive && term;
		setTerminated(term);
		if (!term) addStackFrame();
	}

	static function sortByKey(a:Vector<{key:Int, offset:JBranchOffsetRef}>):Void {
		// port: Array.sort (compare on the keys); the keys are distinct here.
		a.sort(function(x, y) return x.key < y.key ? -1 : (x.key > y.key ? 1 : 0));
	}

	public function stringSwitch(needVal:Bool, load:Void->Void, cases:Array<{sl:Array<String>, f:Void->Void}>, def:Null<Void->Void>):Void {
		var buckets = new HashtblList<{s:String, index:Int}>();
		// port: List.mapi, then Array.of_list: allocated at its length and filled in order
		var exprs = new Vector<{f:Void->Void, numJumps:Int}>(cases.length);
		for (index in 0...cases.length) {
			var c = cases[index];
			for (s in c.sl) buckets.add(JvmMethod.javaHash(s), {s: s, index: index});
			exprs[index] = {f: c.f, numJumps: c.sl.length};
		}
		var cases = buckets.asList();
		var def = switch def {
			case null if (needVal):
				function() {
					string("Match failure");
					invokestatic({pack: ["haxe", "jvm"], name: "Exception"}, "wrap", methodSig([objectSig], exceptionSig));
					getCode().athrow();
				};
			case _:
				def;
		}
		var labelDef = spawnLabel("default");
		var labelExit = spawnLabel("exit");
		/* all strings can be null and we're not supposed to cause NPEs here... */
		load();
		labelDef.apply(function(r) getCode().ifNull(stringSig, r));
		/* switch */
		load();
		invokevirtual(stringPath, "hashCode", methodSig([], JInt));
		var exprs = exprs.map(function(e) return {e: e, label: spawnLabel("case-expr")});
		var jumpTable = cases.map(function(c) return {hash: c.key, label: spawnLabel("hash-match")});
		var sortedJumpTable = jumpTable.mapToVector(function(j) return {key: j.hash, offset: j.label.mkOffset()});
		sortByKey(sortedJumpTable);
		code.lookupswitch(labelDef.mkOffset(), sortedJumpTable);
		var restore = startBranch();
		/* cases */
		for (ci in 0...cases.length) {
			var l = cases[ci].values;
			var label = jumpTable[ci].label;
			label.here();
			for (si in l) {
				restore();
				var popScope = pushScope();
				var e = exprs[si.index];
				var f = e.e.f, numJumps = e.e.numJumps, labelExpr = e.label;
				load();
				string(si.s);
				invokevirtual(stringPath, "equals", methodSig([objectSig], JBool));
				if (numJumps == 1) {
					ifThen(function(r) code.if_(CmpEq, r), function() {
						f();
						if (!isTerminated()) labelExit.goto();
					});
				} else
					labelExpr.apply(function(r) code.if_(CmpNe, r));
				popScope();
			}
			labelDef.goto();
		}
		/* exprs */
		for (e in exprs) {
			if (e.e.numJumps != 1) {
				restore();
				e.label.here();
				var popScope = pushScope();
				e.e.f();
				popScope();
				if (!isTerminated()) labelExit.goto();
			}
		}
		/* default */
		switch def {
			case null:
			case f:
				restore();
				labelDef.here();
				var popScope = pushScope();
				f();
				popScope();
				if (!isTerminated()) labelExit.goto();
		}
		if (labelExit.wasJumpedTo()) labelExit.here();
		if (def == null) {
			setTerminated(false);
			labelDef.here();
		} else if (labelExit.wasJumpedTo())
			setTerminated(false)
		else
			setTerminated(true);
	}

	/**
		Emits a tableswitch or lookupswitch instruction, depending on which one makes more sense.

		The switch subject is expected to be on the stack before calling this function.

		If [is_exhaustive] is true and [def] is None, the first case is used as the default case.
	**/
	public function intSwitch(needVal:Bool, cases:Array<{il:Array<Int>, f:Void->Void}>, def:Null<Void->Void>):Void {
		var def = switch def {
			case null if (needVal):
				function() {
					string("Match failure");
					invokestatic({pack: ["haxe", "jvm"], name: "Exception"}, "wrap", methodSig([objectSig], exceptionSig));
					getCode().athrow();
				};
			case _:
				def;
		}
		var flatCases:Array<{key:Int, offset:JBranchOffsetRef}> = [];
		var caseLut = new haxe.ds.IntMap<JvmLabel>();
		var imin = haxe.Int64.make(0x7FFFFFFF, 0xFFFFFFFF);
		var imax = haxe.Int64.make(0x80000000, 0);
		var cases = cases.map(function(c) {
			var rl = c.il.map(function(i32) {
				var r = spawnLabel("case");
				var i64 = haxe.Int64.ofInt(i32);
				if (i64 < imin) imin = i64;
				if (i64 > imax) imax = i64;
				flatCases.push({key: i32, offset: r.mkOffset()});
				caseLut.set(i32, r);
				return r;
			});
			return {rl: rl, f: c.f};
		});
		var labelDef = spawnLabel("default");
		/* No idea what's a good heuristic here... */
		var diff = haxe.Int64.sub(imax, imin);
		var useTableswitch = diff < haxe.Int64.ofInt(flatCases.length + 10) && diff >= haxe.Int64.ofInt(0) /* #8388 */;
		if (useTableswitch) {
			var imin = imin.low;
			var imax = imax.low;
			var offsets = new Vector<JvmLabel>(((imax - imin) | 0) + 1);
			for (i in 0...offsets.length) {
				var l = caseLut.get((i + imin) | 0);
				offsets[i] = l != null ? l : labelDef;
			}
			// port: OCaml evaluates the arguments right to left: the case offsets before the default's.
			var caseOffsets = offsets.map(function(label) return label.mkOffset());
			code.tableswitch(labelDef.mkOffset(), imin, imax, caseOffsets);
		} else {
			var a = Vector.fromArrayCopy(flatCases);
			sortByKey(a);
			code.lookupswitch(labelDef.mkOffset(), a);
		}
		var restore = startBranch();
		var labelExit = spawnLabel("exit");
		switch def {
			case null:
			case f:
				labelDef.here();
				var popScope = pushScope();
				f();
				popScope();
				if (!isTerminated()) labelExit.goto();
		}
		for (ci in 0...cases.length) {
			var c = cases[ci];
			restore();
			for (label in c.rl) label.here();
			var popScope = pushScope();
			c.f();
			popScope();
			if (ci < cases.length - 1 && !isTerminated()) labelExit.goto();
		}
		if (labelExit.wasJumpedTo()) labelExit.here();
		if (def == null) {
			setTerminated(false);
			labelDef.here();
		} else if (labelExit.wasJumpedTo())
			setTerminated(false);
	}

	/** Adds a local with a given [name], signature [jsig] and an [init_state].
		This function returns a tuple consisting of:

		  * The slot of the local
		  * The function to load the value
		  * The function to store a value

		If [init_state = VarNeedDefault], the local is initialized to a default value matching [jsig].
		If [init_state = VarArgument], the local is considered initialized.
		If [init_state = VarWillInit], this function assumes that the returned [store] function will be called appropriately.
	**/
	public function addLocal(name:String, jsig:JSignature, initState:VarInitState):LocalRef {
		var slot = localOffset;
		var load:Void->Void, store:Void->Void, d:Int;
		switch jsig {
			case JInt | JBool | JByte | JShort | JChar:
				if (initState == VarNeedDefault) {
					code.iconst(0);
					code.istore(slot);
				}
				load = function() code.iload(slot, jsig);
				store = function() code.istore(slot);
				d = 1;
			case JLong:
				if (initState == VarNeedDefault) {
					code.lconst(haxe.Int64.ofInt(0));
					code.lstore(slot);
				}
				load = function() code.lload(slot);
				store = function() code.lstore(slot);
				d = 2;
			case JFloat:
				if (initState == VarNeedDefault) {
					code.fconst(0.);
					code.fstore(slot);
				}
				load = function() code.fload(slot);
				store = function() code.fstore(slot);
				d = 1;
			case JDouble:
				if (initState == VarNeedDefault) {
					code.dconst(0.);
					code.dstore(slot);
				}
				load = function() code.dload(slot);
				store = function() code.dstore(slot);
				d = 2;
			case _:
				if (initState == VarNeedDefault) {
					code.aconstNull(jsig);
					code.astore(jsig, slot);
				}
				load = function() code.aload(jsig, slot);
				store = function() code.astore(jsig, slot);
				d = 1;
		}
		var init:{v:Null<Int>} = {v: null};
		locals = [({init: init, name: name, jsig: jsig} : FrameLocal)].concat(locals);
		localOffset = localOffset + d;
		if (localOffset > maxNumLocals) maxNumLocals = localOffset;
		var didStore = false;
		var checkStore = function() {
			if (!didStore) {
				didStore = true;
				init.v = code.getFp();
			}
		};
		switch initState {
			case VarArgument | VarNeedDefault: checkStore();
			case _:
		}
		return {
			slot: slot,
			load: load,
			store: function() {
				store();
				checkStore();
			}
		};
	}

	public function getThisSig():JSignature {
		if (locals.length == 0) core.Globals.die("", "generators/jvm/jvmMethod.ml");
		return locals[locals.length - 1].jsig;
	}

	public function setThisInitialized():Void {
		if (locals.length == 0) core.Globals.die("", "generators/jvm/jvmMethod.ml");
		var l = locals.copy();
		var last = l[l.length - 1];
		l[l.length - 1] = {init: last.init, name: last.name, jsig: jc.getJsig()};
		locals = l;
	}

	public function replaceTop(jsig:JSignature):Void {
		code.getStack().replace(jsig);
	}

	public function addArgumentAnnotation(slot:Int, path:JPath, a:Annotation, isRuntimeVisible:Bool):Void {
		var h = if (isRuntimeVisible) runtimeVisibleArgumentAnnotations else runtimeInvisibleArgumentAnnotations;
		var d = h.get(slot);
		if (d != null) d.push({jsig: JObject(path, []), a: a}) else {
			var d = [];
			d.push({jsig: JObject(path, []), a: a});
			h.set(slot, d);
		}
	}

	/** This function has to be called once all arguments are declared. */
	public function finalizeArguments():Void {
		argumentLocals = locals;
	}

	function getStackMapTable():Vector<JStackMapFrame> {
		var argumentLocals = getLocalsForStackFrame(argumentLocals);
		var lastOffset = -1, lastLocals = argumentLocals, lastLocalsLength = argumentLocals.length;
		// port: one entry per frame, in the order of `List.rev stack_frames` (stackFrames
		// is upstream's list: index 0 is the last frame), filled at its length
		var numFrames = stackFrames.length;
		var acc = new Vector<JStackMapFrame>(numFrames);
		inline function tail(l:Array<VerificationTypeInfo>, n:Int):Array<VerificationTypeInfo> return l.slice(n);
		for (fi in 0...numFrames) {
			var frame = stackFrames[numFrames - 1 - fi];
			var offset = frame.offset, locals = frame.locals, stack = frame.stack;
			var cur = offset - lastOffset - 1;
			var aLocals = VectorTools.ofArrayReversed(locals);
			var localsLength = aLocals.length;
			function default_():JStackMapFrame {
				return StackFull(cur, aLocals, VectorTools.ofArrayReversed(stack));
			}
			var eq = JvmVerificationTypeInfo.listEq;
			var entry = switch [stack.length, localsLength - lastLocalsLength] {
				case [0, 0]:
					if (eq(lastLocals, locals)) {
						if (cur < 64) StackSame(cur) else StackSameExtended(cur);
					} else
						default_();
				case [1, 0]:
					var vt = stack[0];
					if (eq(lastLocals, locals)) {
						if (cur < 64) Stack1StackItem(cur, vt) else Stack1StackItemExtended(cur, vt);
					} else
						default_();
				case [0, 1]:
					if (locals.length >= 1 && eq(tail(locals, 1), lastLocals)) StackAppend1(cur, locals[0]) else default_();
				case [0, 2]:
					if (locals.length >= 2 && eq(tail(locals, 2), lastLocals)) StackAppend2(cur, locals[1], locals[0]) else default_();
				case [0, 3]:
					if (locals.length >= 3
						&& eq(tail(locals, 3), lastLocals)) StackAppend3(cur, locals[2], locals[1], locals[0]) else default_();
				case [0, -1]:
					if (lastLocals.length >= 1 && eq(locals, tail(lastLocals, 1))) StackChop1(cur) else default_();
				case [0, -2]:
					if (lastLocals.length >= 2 && eq(locals, tail(lastLocals, 2))) StackChop2(cur) else default_();
				case [0, -3]:
					if (lastLocals.length >= 3 && eq(locals, tail(lastLocals, 3))) StackChop3(cur) else default_();
				case _:
					default_();
			}
			lastOffset = offset;
			lastLocals = locals;
			lastLocalsLength = localsLength;
			acc[fi] = entry;
		}
		return acc;
	}

	public function getCode():JvmCodeBuilder return code;

	public function isTerminated():Bool return code.isTerminated();

	public function getName():String return name;

	public function getJsig():JSignature return jsig;

	public function getDescriptor():String return descriptor;

	public function setTerminated(b:Bool):Void code.setTerminated(b);

	function getJcode(config:ExportConfig):JvmCodeData {
		var attributes:Array<JAttribute> = [];
		var lines = code.getLines();
		if (config.exportDebug && lines.length > 0) attributes.push(AttributeLineNumberTable(Vector.fromArrayCopy(lines)));
		var stackMapTable = getStackMapTable();
		if (stackMapTable.length > 0) attributes.push(AttributeStackMapTable(stackMapTable));
		var exceptions = VectorTools.ofArrayReversed(exceptions);
		if (config.exportDebug) {
			switch debugLocals {
				case []:
				case _:
					var typeLocals:Array<JvmLocalDebug> = [];
					function map(d:{fp:Int, length:Int, name:String, jsig:JSignature, index:Int}):JvmLocalDebug {
						// port: OCaml evaluates the record fields right to left: the descriptor before the name.
						var ldDescriptorIndex = jc.getPool().addString(JvmSignature.generateSignature(false, d.jsig));
						var ldNameIndex = jc.getPool().addString(d.name);
						var ld:JvmLocalDebug = {
							ldStartPc: d.fp,
							ldLength: d.length,
							ldNameIndex: ldNameIndex,
							ldDescriptorIndex: ldDescriptorIndex,
							ldIndex: d.index,
						};
						if (JvmSignature.hasTypeParameter(d.jsig)) typeLocals.push({
							ldStartPc: ld.ldStartPc,
							ldLength: ld.ldLength,
							ldNameIndex: ld.ldNameIndex,
							ldDescriptorIndex: jc.getPool().addString(JvmSignature.generateSignature(true, d.jsig)),
							ldIndex: ld.ldIndex,
						});
						return ld;
					}
					var locals = debugLocals.mapToVector(map);
					attributes.push(AttributeLocalVariableTable(locals));
					if (typeLocals.length > 0) {
						var locals = Vector.fromArrayCopy(typeLocals);
						attributes.push(AttributeLocalVariableTypeTable(locals));
					}
			}
		}
		var attributes = attributes.mapToVector(function(a) return JvmAttribute.writeAttribute(jc.getPool(), a));
		return {
			codeMaxStack: code.getMaxStackSize(),
			codeMaxLocals: maxNumLocals,
			codeCode: code.exportCode(),
			codeExceptions: exceptions,
			codeAttributes: attributes,
		};
	}

	/** Exports the method as a [jvm_field]. No other functions should be called on this object afterwards. */
	public function exportMethod(config:ExportConfig):JvmField {
		if (wasExported) throw new core.ds.Failure("assert");
		wasExported = true;
		commitAnnotations(jc.getPool());
		if (code.getFp() > 0) {
			var code = getJcode(config);
			addAttribute(AttributeCode(code));
		}
		if (thrownExceptions.length() > 0) {
			// port: Array.of_list of the fold consing each key: the keys in reverse visit
			// order, filled from the end
			var n = thrownExceptions.length();
			var a = new Vector<Int>(n);
			thrownExceptions.iter(function(k, _) a[--n] = k);
			addAttribute(AttributeExceptions(a));
		}
		function collectAnnotations(h:haxe.ds.IntMap<Array<{jsig:JSignature, a:Annotation}>>, f:Vector<Vector<JAnnotation>>->Void):Void {
			if (h.keys().hasNext()) {
				var l = argumentLocals.length;
				var offset = if (hasMethodFlag(MStatic)) 0 else 1;
				var a = new Vector<Vector<JAnnotation>>(l - offset);
				for (i in 0...a.length) {
					var d = h.get(i + offset);
					a[i] = if (d != null) JvmBuilder.convertAnnotations(jc.getPool(), d) else vector();
				}
				f(a);
			}
		}
		collectAnnotations(runtimeVisibleArgumentAnnotations, function(a) attributes.push(AttributeRuntimeVisibleParameterAnnotations(a)));
		collectAnnotations(runtimeInvisibleArgumentAnnotations, function(a) attributes.push(AttributeRuntimeInvisibleParameterAnnotations(a)));
		var attributes = exportAttributes(jc.getPool());
		var offsetName = jc.getPool().addString(name);
		var offsetDesc = jc.getPool().addString(descriptor);
		return {
			fieldAccessFlags: accessFlags,
			fieldNameIndex: offsetName,
			fieldDescriptorIndex: offsetDesc,
			fieldAttributes: attributes,
		};
	}

	/** Exports the method as a [jvm_field]. No other functions should be called on this object afterwards. */
	public function exportField():JvmField {
		if (code.getFp() != 0) throw new core.ds.Failure("assert");
		if (wasExported) throw new core.ds.Failure("assert");
		wasExported = true;
		commitAnnotations(jc.getPool());
		var attributes = exportAttributes(jc.getPool());
		var offsetName = jc.getPool().addString(name);
		var jsig = JvmSignature.generateSignature(false, jsig);
		var offsetDesc = jc.getPool().addString(jsig);
		return {
			fieldAccessFlags: accessFlags,
			fieldNameIndex: offsetName,
			fieldDescriptorIndex: offsetDesc,
			fieldAttributes: attributes,
		};
	}
}

class JvmLabel {
	final jm:JvmMethodBuilder;
	final name:String;
	final code:JvmCodeBuilder;

	var state:LabelState = LabelNotSet([]);
	var wasJumpedTo_ = false;

	public function new(jm:JvmMethodBuilder, name:String) {
		this.jm = jm;
		this.name = name;
		this.code = jm.getCode();
	}

	public function wasJumpedTo():Bool return wasJumpedTo_;

	public function getOffset():JBranchOffset return switch state {
		case LabelSet(fp): fp;
		case LabelNotSet(_): throw new core.ds.Failure('Trying to get offset of unset label $name');
	}

	public function mkOffset():JBranchOffsetRef {
		var r = new JBranchOffsetRef(code.getFp());
		wasJumpedTo_ = true;
		switch state {
			case LabelNotSet(l):
				l.unshift(r);
			case LabelSet(fp2):
				r.v = fp2 - r.v;
		}
		return r;
	}

	public function apply(f:JBranchOffsetRef->Void):Void {
		f(mkOffset());
	}

	public function if_(cmp:JCmp):Void {
		code.if_(cmp, mkOffset());
	}

	public function ifNull(jsig:JSignature):Void {
		code.ifNull(jsig, mkOffset());
	}

	public function ifNonnull(jsig:JSignature):Void {
		code.ifNonnull(jsig, mkOffset());
	}

	public function goto():Void {
		code.goto(mkOffset());
	}

	public function at(fp:Int):Void {
		switch state {
			case LabelNotSet(l):
				if (fp == code.getFp()) jm.addStackFrame();
				for (r in l) r.v = fp - r.v;
				state = LabelSet(fp);
			case LabelSet(_):
				if (fp != getOffset()) throw new core.ds.Failure('Trying to instantiate label $name again');
		}
	}

	public function here():Void {
		at(code.getFp());
	}
}
